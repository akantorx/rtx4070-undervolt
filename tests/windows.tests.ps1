# Pruebas que necesitan un Windows de verdad, aunque no tenga GPU NVIDIA:
#  - el C# compilado por el Add-Type de este PowerShell (5.1 o 7);
#  - el test de estrés sobre el D3D11 de Windows por software (WARP);
#  - la consulta del registro de eventos;
#  - selftest y tune completos con ese motor real y el NVML simulado;
#  - install, la tarea de arranque ejecutándose como SYSTEM, y uninstall.
# Necesita administrador. Lo lanza .github/workflows/tests.yml, que deja ya en el
# entorno MOCK_NVML_STATE=C:\tmp\mock_nvml_state (el NVML simulado lo lee con getenv
# al arrancar; como SYSTEM, sin esa variable, usa la misma ruta por defecto).
param(
    [Parameter(Mandatory = $true)] [string]$MockDir,   # carpeta con el nvml.dll simulado
    [string]$ArtifactsDir                              # aquí se copian registros e informe
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$uv = Join-Path $root 'uv4070.ps1'
$realProgramFiles = $env:ProgramFiles
$env:PATH = "$MockDir;$env:PATH"
. $uv

$Yes = $true
$MaxLossPct = 3   # las cifras de estas pruebas están calculadas con un 3 %
$script:Failures = 0
$warp = 'Microsoft Basic Render Driver'

function Check([string]$Name, [bool]$Ok, $Detail) {
    if ($Ok) { Write-Host "ok    $Name" } else {
        Write-Host "FALLO $Name"
        if ($null -ne $Detail) { Write-Host "  | $Detail" }
        $script:Failures++
    }
}

function Get-Statuses {
    $status = @{}
    foreach ($r in $script:SelfTestResults) { $status[$r.Name] = $r.Status }
    $status
}

Check "Add-Type compila el C# en PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)" ([bool]('Uv4070.Stress' -as [type]))

# --- Test de estrés sobre WARP ---
# Ojo: no llamar $engine a nada aquí; es la misma variable que $script:Engine del script.
$warpEngine = [Uv4070.Stress]::Open($warp)
try {
    $warpEngine.Calibrate(15)
    $warpEngine.CaptureReference()
    Check ('WARP: calibración y referencia ({0} iteraciones, {1:N1} ms por dispatch)' -f $warpEngine.Iterations, $warpEngine.DispatchMs) ($warpEngine.Iterations -ge 64)
    $r = $warpEngine.Run(3, [IntPtr]::Zero, [Uv4070.Stress]::Steady)
    Check 'WARP: carga sostenida sin errores' (-not $r.Failure -and $r.Batches -gt 2 -and $r.Tflops -gt 0 -and $r.LowTflops -le $r.Tflops) (ConvertTo-LogResult $r | ConvertTo-Json -Compress)
    $r = $warpEngine.Run(4, [IntPtr]::Zero, [Uv4070.Stress]::Pulses)
    Check 'WARP: pulsos de carga sin errores' (-not $r.Failure -and $r.Batches -gt 0) (ConvertTo-LogResult $r | ConvertTo-Json -Compress)
    $r = $warpEngine.Run(2, [IntPtr]::Zero, [Uv4070.Stress]::Light)
    Check 'WARP: carga ligera sin errores' (-not $r.Failure -and $r.Batches -gt 0) (ConvertTo-LogResult $r | ConvertTo-Json -Compress)
    $warpEngine.Iterations += 8
    $r = $warpEngine.Run(1, [IntPtr]::Zero, [Uv4070.Stress]::Steady)
    Check 'WARP: detecta resultados erróneos' ($r.Failure -eq 'errores de cálculo' -and $r.Errors -ge [Uv4070.Stress]::Threads) (ConvertTo-LogResult $r | ConvertTo-Json -Compress)
} finally {
    $warpEngine.Dispose()
}
$message = try { [Uv4070.Stress]::Open($GpuName).Dispose(); 'abrió' } catch { $_.Exception.InnerException.Message }
Check 'DirectX: sin la 4070 lo dice y lista los adaptadores' ($message -match 'DirectX no encuentra' -and $message -match [regex]::Escape($warp)) $message

# --- Test de ray tracing (DirectX 12, DXR 1.1) sobre WARP ---
$warpRt = [Uv4070.RtStress]::Open($warp)
try {
    $warpRt.Calibrate(15)
    $warpRt.CaptureReference()
    Check ('WARP RT: calibración y referencia ({0} rayos por hilo, {1:N1} ms por dispatch)' -f $warpRt.Iterations, $warpRt.DispatchMs) ($warpRt.Iterations -ge 1 -and $warpRt.DispatchMs -gt 0)
    # Sin núcleos RT cada dispatch tarda varios segundos: en 3 s puede completarse un solo lote.
    $r = $warpRt.Run(3, [IntPtr]::Zero, [Uv4070.Stress]::Steady)
    Check 'WARP RT: carga sostenida sin errores' (-not $r.Failure -and $r.Batches -ge 1) (ConvertTo-LogResult $r | ConvertTo-Json -Compress)
    $warpRt.Iterations += 1
    $r = $warpRt.Run(1, [IntPtr]::Zero, [Uv4070.Stress]::Steady)
    Check 'WARP RT: detecta resultados erróneos' ($r.Failure -eq 'errores de cálculo' -and $r.Errors -ge [Uv4070.RtStress]::Threads) (ConvertTo-LogResult $r | ConvertTo-Json -Compress)
} finally {
    $warpRt.Dispose()
}

# --- Registro de eventos ---
$search = Search-DriverResets (Get-Date).AddDays(-30)
Check 'registro de eventos: la consulta de nvlddmkm y Display funciona' $search.Ok $search.Error

# --- selftest y tune con el motor real (WARP) y el NVML simulado ---
function New-StressEngine { [Uv4070.Stress]::Open($warp) }
function New-RtStressEngine { [Uv4070.RtStress]::Open($warp) }
function Install-Autostart { }
$TestScale = 0.05
$env:ProgramFiles = Join-Path ([IO.Path]::GetTempPath()) ('uv4070-ci-' + [guid]::NewGuid())
$device = Open-Rtx4070 $false

Set-Content -LiteralPath $env:MOCK_NVML_STATE -Value '0 0 0 200000'
Start-Log 'selftest'
$out = try { Invoke-SelfTest $device *>&1 | Out-String } catch { 'EXCEPCION: ' + $_.Exception.Message }
$status = Get-Statuses
$failed = @($status.Keys | Where-Object { $status[$_] -ne 'ok' -and $status[$_] -ne 'info' })
Check 'selftest en Windows: todas las comprobaciones OK' ($out -notmatch 'EXCEPCION' -and $failed.Count -eq 0) $out
Check 'selftest en Windows: registro de eventos y tarea programada probados' ($status['registro-eventos'] -eq 'ok' -and $status['tarea-programada'] -eq 'ok') $out
Check 'selftest: no deja la tarea temporal' ($null -eq (Get-ScheduledTask -TaskName 'uv4070-selftest' -ErrorAction SilentlyContinue))

Set-Content -LiteralPath $env:MOCK_NVML_STATE -Value '0 0 0 200000'
Start-Log 'tune'
$out = try { Invoke-Tune $device *>&1 | Out-String } catch { 'EXCEPCION: ' + $_.Exception.Message }
$config = Read-Config
# El NVML simulado da siempre el mismo consumo y, con tope, no está limitado por potencia: tune
# para en la meseta tras dos pasos sin bajar (+60 y +90) y deja +60.
Check 'tune con el motor real (WARP): termina y guarda la configuración' ($out -notmatch 'EXCEPCION' -and $config.MaxMHz -eq 2715 -and $config.OffsetMHz -eq 60) $out
$events = @(Get-Content -LiteralPath $script:LogPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
Check 'registro de tune: JSON válido con los resultados reales del motor' (@($events | Where-Object { $_.event -eq 'load' -and $_.result.batches -gt 0 }).Count -gt 5) ($events.Count)
Close-Engine
[void][Uv4070.Nvml]::Shutdown()
$script:NvmlOpen = $false
$ciData = $env:ProgramFiles

# --- install, la tarea como SYSTEM y uninstall, con el CLI de Windows PowerShell ---
$env:ProgramFiles = $realProgramFiles
$dataDir = Join-Path $realProgramFiles 'uv4070'
$system32Mock = Join-Path $env:SystemRoot 'System32\nvml.dll'
Copy-Item -LiteralPath (Join-Path $MockDir 'nvml.dll') -Destination $system32Mock -Force
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uv install -MaxMHz 2600 -OffsetMHz 100 | Out-Host
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Check 'install: termina bien y crea la tarea con sus dos disparadores' ($LASTEXITCODE -eq 0 -and $task -and @($task.Triggers).Count -eq 2 -and $task.Principal.UserId -eq 'SYSTEM')

    Set-Content -LiteralPath $env:MOCK_NVML_STATE -Value '0 0 0 200000'
    $before = (Get-ScheduledTaskInfo -TaskName $TaskName).LastRunTime
    Start-ScheduledTask -TaskName $TaskName
    $deadline = (Get-Date).AddSeconds(120)
    do {
        Start-Sleep -Seconds 2
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        $running = (Get-ScheduledTask -TaskName $TaskName).State -eq 'Running'
    } while (($running -or $info.LastRunTime -eq $before) -and (Get-Date) -lt $deadline)
    $state = Get-Content -LiteralPath $env:MOCK_NVML_STATE
    $log = Get-Content -LiteralPath (Join-Path $dataDir 'uv4070.log') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    Check 'la tarea de arranque, como SYSTEM, aplica la configuración guardada' ($info.LastTaskResult -eq 0 -and $state -eq '100 0 2600 200000' -and $log -match 'Hecho') "resultado=$($info.LastTaskResult) estado=$state`n$log"
    $applyLog = Get-ChildItem -LiteralPath (Join-Path $dataDir 'logs') -Filter '*-apply.jsonl' | Sort-Object Name -Descending | Select-Object -First 1
    $session = if ($applyLog) { Get-Content -LiteralPath $applyLog.FullName -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'session' } }
    Check 'la tarea deja su registro JSON Lines (Windows PowerShell)' ($session -and $session.edition -eq 'Desktop' -and $session.arguments.Unattended -eq 'True') ($session | ConvertTo-Json -Compress)

    if ($ArtifactsDir) {
        New-Item -ItemType Directory -Force -Path $ArtifactsDir | Out-Null
        Push-Location $ArtifactsDir
        try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uv report | Out-Host } finally { Pop-Location }
        $report = Get-ChildItem -LiteralPath $ArtifactsDir -Filter 'uv4070-report-*.json' | Select-Object -First 1
        $parsed = if ($report) { Get-Content -LiteralPath $report.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
        Check 'report: JSON válido con el registro de la tarea de arranque' ($parsed -and $parsed.autostartLog -match 'Hecho' -and @($parsed.logs).Count -gt 0) $report
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uv uninstall | Out-Host
    Check 'uninstall: quita la tarea y la copia del script y conserva la configuración' ($null -eq (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath (Join-Path $dataDir 'uv4070.ps1')) -and (Test-Path -LiteralPath (Join-Path $dataDir 'config.json')))
} finally {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $system32Mock -Force -ErrorAction SilentlyContinue
    if ($ArtifactsDir) {
        foreach ($source in (Join-Path $ciData 'uv4070'), $dataDir) {
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $ArtifactsDir ('data-' + [guid]::NewGuid())) -Recurse }
        }
    }
}

Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) prueba(s) fallida(s)"; exit 1 }
Write-Host 'Todas las pruebas de Windows pasan.'
