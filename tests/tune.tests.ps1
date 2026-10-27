# Prueba la lógica de tune y stress de uv4070.ps1 con el NVML simulado y un motor
# de estrés falso que imita una 4070: curva de tensión, consumo y un chip que deja
# de ser estable con +180 MHz de offset. Lo lanza tests/run.sh.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'uv4070.ps1')
# Fallos del NVML simulado desde este proceso (el entorno no sirve: .NET no cambia el que ve getenv).
Add-Type -Namespace Uv4070Tests -Name Mock -MemberDefinition '[DllImport("nvml.dll")] public static extern void mockSetFail(string flags);'

$Yes = $true
$script:Failures = 0
$script:Installs = 0
$script:EnginesCreated = 0

function Check([string]$Name, [bool]$Ok, $Detail) {
    if ($Ok) { Write-Host "ok    $Name" } else {
        Write-Host "FALLO $Name"
        if ($null -ne $Detail) { Write-Host "  | $Detail" }
        $script:Failures++
    }
}

function Install-Autostart { $script:Installs++ }

function Get-FakeResult {
    $clock = [uint32]0
    [void][Uv4070.Nvml]::GetClock($script:Dev, 0, [ref]$clock)
    $offset = (Get-CoreOffset $script:Dev).MHz
    # Curva de serie de la 4070 simulada: 0,89 V hasta 2250 MHz y 0,35 mV más por MHz.
    $volts = { param($mhz) [math]::Max(0.89, 0.89 + ($mhz - $script:FakeVminMHz) * 0.21 / 600) }
    $power = { param($mhz) 30 + 175 * ($mhz / 2800) * [math]::Pow((& $volts ($mhz - $offset)) / 1.05, 2) }
    $f = [double]$clock
    $limited = $false
    # Con carga ligera la GPU llega a su reloj máximo sin tocar el límite de potencia.
    while ($script:Mode -ne [Uv4070.Stress]::Light -and (& $power $f) -gt $script:FakeLimitW) { $f -= 15; $limited = $true }
    $r = New-Object Uv4070.StressResult
    $r.Batches = 100
    $r.Tflops = $f * 5888 * 2 / 1e6
    $r.LowTflops = $r.Tflops * $(if ($limited) { 0.85 } else { 0.98 })
    $r.Watts = & $power $f
    $r.ClockMHz = $f
    $r.MaxTempC = [uint32](40 + $r.Watts / 5)
    $r.P0Pct = $script:FakeP0
    $r.PowerCappedPct = $(if ($limited) { 100 } else { 0 })
    if ($offset -ge $script:FakeLimit -or ($offset -eq 0 -and $script:FailAtStock)) { $r.Failure = 'errores de cálculo'; $r.Errors = 5 }
    if ($offset -eq $script:LoseAtOffset -and -not $script:Lost) {
        $script:Lost = $true
        $r.Failure = 'el driver se ha reiniciado'; $r.DeviceLost = $true
        $script:Engine.Lost = $true
    }
    $r
}

function New-StressEngine {
    $script:EnginesCreated++
    $engine = [pscustomobject]@{ Lost = $false; Iterations = 1000; DispatchMs = 10.0 }
    $engine | Add-Member ScriptMethod Calibrate { param($ms) }
    $engine | Add-Member ScriptMethod CaptureReference { }
    $engine | Add-Member ScriptMethod Run {
        param($seconds, $device, $mode)
        $script:Mode = $mode
        $r = Get-FakeResult
        # Con otras iteraciones ningún hash coincide con la referencia, como en el motor real.
        if ($this.Iterations -ne 1000) { $r.Failure = 'errores de cálculo'; $r.Errors = 1048576 }
        $r
    }
    $engine | Add-Member ScriptMethod Dispose { }
    $engine
}

function Start-Case([string]$StateJson) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('uv4070-test-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $dir | Out-Null
    $env:ProgramFiles = $dir
    New-Item -ItemType Directory -Path (Get-DataDir) | Out-Null
    Set-Content -LiteralPath $env:MOCK_NVML_STATE -Value '0 0 0 200000'
    if (Test-Path -LiteralPath $env:MOCK_NVML_LOG) { Remove-Item -LiteralPath $env:MOCK_NVML_LOG }
    [Uv4070Tests.Mock]::mockSetFail('')
    $script:LogPath = $null
    $script:SelfTestResults = @()
    if ($StateJson) { Set-Content -LiteralPath (Join-Path (Get-DataDir) 'tune-state.json') -Value $StateJson }
    $script:FakeLimit = 180; $script:FakeP0 = 100; $script:FailAtStock = $false; $script:FakeVminMHz = 2250; $script:FakeLimitW = 200
    $script:LoseAtOffset = -1; $script:Lost = $false
    $script:Installs = 0; $script:EnginesCreated = 0
    $script:Engine = $null
}

function Invoke-Case {
    try { Invoke-Tune $script:Dev *>&1 | Out-String } catch { 'EXCEPCION: ' + $_.Exception.Message }
}

$script:Dev = Open-Rtx4070 $false

# --- Funciones puras ---
Check 'tope: 3 % por debajo del reloj máximo, en pasos de 15' ((Get-TargetCap 2805 3) -eq 2715 -and (Get-TargetCap 2790 3) -eq 2700) (Get-TargetCap 2805 3)
Check 'tope: sin pérdida, el reloj máximo' ((Get-TargetCap 2805 0) -eq 2805)
Check 'búsqueda: empieza en +30' ((Get-NextOffset @() @() $false) -eq 30)
Check 'búsqueda: sube de 30 en 30' ((Get-NextOffset @(30, 60) @() $false) -eq 90)
Check 'búsqueda: afina 15 tras el primer fallo' ((Get-NextOffset @(30, 60) @(90) $false) -eq 75)
Check 'búsqueda: termina con 15 de diferencia' ($null -eq (Get-NextOffset @(30, 60, 75) @(90) $false))
Check 'búsqueda: termina en la meseta de consumo' ($null -eq (Get-NextOffset @(30, 60) @() $true))
Check 'búsqueda: listas vacías tras pasar por JSON' ((Get-NextOffset $null $null $false) -eq 30)
Check 'último estable: ignora aprobados por encima de un fallo' ((Get-HighestPass @(30, 60, 120) @(90)) -eq 60)

# --- tune completo ---
Start-Case
Start-Log 'tune'
$out = Invoke-Case
$config = Read-Config
Check 'tune: termina sin errores' ($out -notmatch 'EXCEPCION') $out
Check 'tune: tope 2715 (-3 % de 2805) y máximo estable 165 - margen 30' ($config.MaxMHz -eq 2715 -and $config.OffsetMHz -eq 135) ($config | ConvertTo-Json -Compress)
Check 'tune: deja aplicada la configuración' ((Get-Content $env:MOCK_NVML_STATE) -eq '135 0 2715 200000') (Get-Content $env:MOCK_NVML_STATE)
Check 'tune: informe guardado y con comparación' ((Get-Content (Join-Path (Get-DataDir) 'tune-report.txt') -Raw -Encoding UTF8) -match 'Consumo.*-\d') $out
Check 'tune: borra el estado y lo instala con -Yes' (-not (Test-Path (Join-Path (Get-DataDir) 'tune-state.json')) -and $script:Installs -eq 1)
$summary = Get-Content (Join-Path (Get-DataDir) 'tune-report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Check 'tune: tune-report.json con la configuración y la búsqueda' ($summary.config.MaxMHz -eq 2715 -and $summary.highestStableOffset -eq 165 -and @($summary.failed) -contains 180 -and $summary.stock.Watts -gt $summary.final.Watts -and $summary.stockCold.Watts -eq $summary.stock.Watts) ($summary | ConvertTo-Json -Compress -Depth 4)
$steps = @($events | Where-Object { $_.event -eq 'tune-step' })
Check 'registro: cada paso lleva si la GPU estaba al límite de potencia' (@($steps | Where-Object { $null -ne $_.powerCappedPct }).Count -eq $steps.Count) ($steps | ConvertTo-Json -Compress)
$events = @(Get-Content -LiteralPath $script:LogPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
$names = @($events | ForEach-Object { $_.event })
Check 'registro: cada línea es JSON y lleva las decisiones de tune' (@($names | Where-Object { $_ -eq 'tune-step' }).Count -eq 7 -and
    $names -contains 'tune-baseline' -and $names -contains 'tune-best' -and $names -contains 'tune-confirm' -and $names -contains 'tune-result' -and
    $names -contains 'load' -and $names -contains 'nvml' -and $names -contains 'engine') ($names -join ',')
$failedStep = @($events | Where-Object { $_.event -eq 'tune-step' -and $_.offset -eq 180 })
Check 'registro: el paso que falla lleva el motivo y el consumo' ($failedStep.Count -eq 1 -and $failedStep[0].failure -match 'errores de cálculo a 2715 MHz') ($failedStep | ConvertTo-Json -Compress)
$load = @($events | Where-Object { $_.event -eq 'load' })[0]
Check 'registro: las cargas llevan tope, offset, modo y resultado' ($null -ne $load.result.watts -and $load.mode -in 'steady', 'pulses', 'light' -and $null -ne $load.cap) ($load | ConvertTo-Json -Compress)
Check 'tune: un solo motor de estrés' ($script:EnginesCreated -eq 1) $script:EnginesCreated
Check 'tune: muestra la búsqueda con el consumo' ($out -match '\+180 MHz  falla: errores de cálculo a 2715 MHz' -and $out -match '\+165 MHz  estable +\d+ W') $out
Check 'tune: el informe compara reloj máximo y consumo' ($out -match 'Reloj máximo +2805 MHz +2715 MHz +-3\.2 %' -and $out -match 'Consumo +198 W +\d+ W +-') $out

# --- Reanudar tras un cuelgue del PC durante la búsqueda ---
Start-Case '{"Driver":"566.36","LossPct":3,"Baseline":{"Cap":0,"Offset":0,"Tflops":31.8,"LowTflops":27,"Watts":198,"ClockMHz":2700,"MaxTempC":79,"P0Pct":100,"PowerCappedPct":100},"BoostMHz":2805,"Target":2715,"Passed":[30,60,90],"Failed":[],"LastWatts":190,"Plateau":false,"Best":null,"Testing":120}'
$out = Invoke-Case
$config = Read-Config
Check 'reanuda: el offset que colgó el PC cuenta como fallo' ($config.OffsetMHz -eq 75 -and $config.MaxMHz -eq 2715) "$out $($config | ConvertTo-Json -Compress)"

# --- Reanudar tras un cuelgue durante la confirmación ---
Start-Case '{"Driver":"566.36","LossPct":3,"Baseline":{"Cap":0,"Offset":0,"Tflops":31.8,"LowTflops":27,"Watts":198,"ClockMHz":2700,"MaxTempC":79,"P0Pct":100,"PowerCappedPct":100},"BoostMHz":2805,"Target":2715,"Passed":[30,60,90,120,150,165],"Failed":[180],"LastWatts":182,"Plateau":false,"Best":135,"Testing":135}'
$out = Invoke-Case
$config = Read-Config
Check 'reanuda: si cuelga en la confirmación, baja 15' ($config.OffsetMHz -eq 120) "$out $($config | ConvertTo-Json -Compress)"

# --- Estado de otro driver: empieza de cero ---
Start-Case '{"Driver":"999.99","LossPct":3,"Baseline":null,"BoostMHz":2500,"Target":2400,"Passed":[30],"Failed":[60],"LastWatts":150,"Plateau":false,"Best":0,"Testing":null}'
$out = Invoke-Case
Check 'driver distinto: descarta el estado guardado' ((Read-Config).OffsetMHz -eq 135) $out

# --- Meseta: con la tensión en el mínimo de la curva, más offset ya no ahorra ---
# Desde +120 la tensión ya es la mínima: +150 y +180 consumen lo mismo y la búsqueda para ahí.
Start-Case
$script:FakeVminMHz = 2600
$script:FakeLimit = 300
$out = Invoke-Case
Check 'meseta: para tras dos pasos seguidos sin bajar el consumo' ((Read-Config).OffsetMHz -eq 150 -and $out -notmatch '\+210 MHz' -and $out -match 'mínimo de la curva') $out

# --- Al límite de potencia el consumo es constante aunque el undervolt avance: no es una meseta ---
Start-Case
$script:FakeLimitW = 150
$out = Invoke-Case
Check 'límite de potencia: sigue buscando aunque el consumo no baje' ((Read-Config).OffsetMHz -eq 135 -and $out -match 'al límite de potencia' -and $out -notmatch 'mínimo de la curva') $out

# --- El límite de potencia guardado (install -PowerPct) se conserva y se aplica ---
Start-Case
Save-Config ([pscustomobject]@{ MaxMHz = 2600; OffsetMHz = 60; PowerPct = 80 })
$out = Invoke-Case
Check 'tune conserva el límite de potencia guardado' ((Read-Config).PowerPct -eq 80 -and (Get-Content $env:MOCK_NVML_STATE) -eq '135 0 2715 160000') "$out $(Get-Content $env:MOCK_NVML_STATE)"

# --- install tras tune conserva la fecha y el driver del ajuste ---
Start-Case
Save-Config ([pscustomobject]@{ MaxMHz = 2715; OffsetMHz = 135; PowerPct = 100; Tuned = '2026-10-27 12:00'; Driver = '566.36' })
$resolved = Resolve-Config $true
Check 'la configuración resuelta conserva Tuned y Driver' ($resolved.MaxMHz -eq 2715 -and $resolved.Tuned -eq '2026-10-27 12:00' -and $resolved.Driver -eq '566.36') ($resolved | ConvertTo-Json -Compress)

# --- -MaxLossPct cambia el tope ---
Start-Case
$MaxLossPct = 10
$out = Invoke-Case
Check '-MaxLossPct 10: tope 2520' ((Read-Config).MaxMHz -eq 2520) $out
$MaxLossPct = 3

# --- Reinicio del driver: se abre otro motor y cuenta como fallo ---
Start-Case
$script:LoseAtOffset = 90
$out = Invoke-Case
$config = Read-Config
Check 'reinicio del driver: nuevo motor y offset inestable' ($script:EnginesCreated -eq 2 -and $config.OffsetMHz -eq 45) "motores=$($script:EnginesCreated) $out"

# --- Casos en los que tune se niega ---
Start-Case
$script:FakeP0 = 40
$out = Invoke-Case
Check 'sin P0 durante la carga: se niega' ($out -match 'EXCEPCION.*P0' -and $null -eq (Read-Config)) $out
Check 'al abortar vuelve a fábrica' ((Get-Content $env:MOCK_NVML_STATE) -eq '0 0 0 200000') (Get-Content $env:MOCK_NVML_STATE)

Start-Case
$script:FailAtStock = $true
$out = Invoke-Case
Check 'errores de serie: se niega' ($out -match 'EXCEPCION.*incluso de serie') $out

# --- stress ---
Start-Case
$out = try { Invoke-StressTest $script:Dev ([pscustomobject]@{ MaxMHz = 2745; OffsetMHz = 135; PowerPct = 100 }) 10 *>&1 | Out-String } catch { 'EXCEPCION: ' + $_.Exception.Message }
Check 'stress: configuración estable' ($out -match 'ESTABLE: 10 min' -and (Get-Content $env:MOCK_NVML_STATE) -eq '135 0 2745 200000') $out

Start-Case
$out = try { Invoke-StressTest $script:Dev ([pscustomobject]@{ MaxMHz = 2800; OffsetMHz = 195; PowerPct = 100 }) 10 *>&1 | Out-String } catch { 'EXCEPCION: ' + $_.Exception.Message }
Check 'stress: configuración inestable, y la GPU vuelve a fábrica' ($out -match 'INESTABLE: errores de cálculo a 2800 MHz.*-OffsetMHz 180' -and (Get-Content $env:MOCK_NVML_STATE) -eq '0 0 0 200000') "$out $(Get-Content $env:MOCK_NVML_STATE)"

Start-Case
$out = try { Invoke-StressTest $script:Dev ([pscustomobject]@{ MaxMHz = $null; OffsetMHz = $null; PowerPct = 100 }) 1 *>&1 | Out-String } catch { 'EXCEPCION: ' + $_.Exception.Message }
Check 'stress: sin configuración prueba de serie' ($out -match 'de serie' -and $out -match 'ESTABLE') $out

# --- selftest ---
Start-Case
$out = try { Invoke-SelfTest $script:Dev *>&1 | Out-String } catch { 'EXCEPCION: ' + $_.Exception.Message }
$status = @{}
foreach ($r in $script:SelfTestResults) { $status[$r.Name] = $r.Status }
$expected = 'lecturas', 'lectura-offset', 'tope-reloj', 'escritura-offset', 'potencia', 'directx11', 'tope-efectivo', 'carga-de-serie', 'reloj-maximo', 'pulsos', 'deteccion-errores'
Check 'selftest: todo correcto con el NVML simulado' ($out -notmatch 'EXCEPCION' -and @($expected | Where-Object { $status[$_] -ne 'ok' }).Count -eq 0) $out
Check 'selftest: deja la GPU de fábrica' ((Get-Content $env:MOCK_NVML_STATE) -eq '0 0 0 200000') (Get-Content $env:MOCK_NVML_STATE)

Start-Case
[Uv4070Tests.Mock]::mockSetFail('lock')
$out = try { Invoke-SelfTest $script:Dev *>&1 | Out-String } catch { 'EXCEPCION: ' + $_.Exception.Message }
$status = @{}
foreach ($r in $script:SelfTestResults) { $status[$r.Name] = $r.Status }
$wrote = if (Test-Path $env:MOCK_NVML_LOG) { Get-Content $env:MOCK_NVML_LOG -Raw } else { '' }
Check 'selftest: sin tope no prueba el offset y lo cuenta como fallo' ($out -match 'EXCEPCION.*FALLO' -and $status['tope-reloj'] -eq 'fail' -and
    $status['escritura-offset'] -eq 'fail' -and $wrote -notmatch 'offset 15') "$out $wrote"
[Uv4070Tests.Mock]::mockSetFail('')

[void][Uv4070.Nvml]::Shutdown()
Write-Host ''
if ($script:Failures) { Write-Host "$($script:Failures) prueba(s) fallida(s)"; exit 1 }
Write-Host 'Todas las pruebas de tune pasan.'
