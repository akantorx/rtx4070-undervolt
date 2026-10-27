<#
.SYNOPSIS
    Undervolt para la NVIDIA GeForce RTX 4070, sin MSI Afterburner.

.DESCRIPTION
    Hace lo mismo que "subir la curva y aplanarla" en Afterburner, pero con
    NVML (nvml.dll), la librería oficial que instala el driver de NVIDIA:

      1. Pone un tope al reloj del núcleo (-MaxMHz).
      2. Sube toda la curva tensión/frecuencia un offset (-OffsetMHz).

    Con la curva subida, la GPU llega al tope con menos tensión que de serie y
    ya no sube más: menos consumo y temperatura por casi el mismo rendimiento.
    No deja ningún programa en segundo plano.

    Comandos:
      status     Estado actual (por defecto).
      apply      Aplica el undervolt ahora (se pierde al reiniciar).
      reset      Vuelve a valores de fábrica.
      monitor    Reloj, consumo y temperatura cada segundo (Ctrl+C para salir).
      install    Aplica ahora y en cada inicio de sesión y vuelta de suspensión.
      uninstall  Quita el arranque automático y vuelve a valores de fábrica.

.EXAMPLE
    .\uv4070.ps1 apply

.EXAMPLE
    .\uv4070.ps1 apply -Preset eco -PowerPct 85

.EXAMPLE
    .\uv4070.ps1 install -MaxMHz 2700 -OffsetMHz 150
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'apply', 'reset', 'monitor', 'install', 'uninstall')]
    [string]$Command = 'status',

    # Solo elige el tope de reloj; el offset es cosa de tu chip (ver -OffsetMHz).
    [ValidateSet('eco', 'balanced', 'performance')]
    [string]$Preset = 'balanced',

    # Tope de reloj del núcleo. Si se indica, manda sobre -Preset.
    [ValidateRange(1500, 2850)]
    [int]$MaxMHz,

    # Cuánto se sube la curva. Más offset = menos tensión en el tope = más
    # undervolt, hasta que deja de ser estable. Ajústalo en pasos de 15.
    [ValidateRange(0, 300)]
    [int]$OffsetMHz = 120,

    # Límite de potencia en % del de fábrica (200 W en la 4070 de referencia).
    [ValidateRange(50, 100)]
    [int]$PowerPct = 100,

    # Solo para monitor: número de lecturas (0 = hasta Ctrl+C).
    [ValidateRange(0, 86400)]
    [int]$Samples = 0,

    # Lo usa la tarea programada: espera al driver y guarda un registro.
    [switch]$Unattended
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$GpuName = 'NVIDIA GeForce RTX 4070'
# Múltiplos de 15 MHz, el paso de reloj de la curva en Ada.
$Presets = @{ eco = 2400; balanced = 2610; performance = 2745 }
$TaskName = 'uv4070'
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows

if (-not ('Uv4070.Nvml' -as [type])) {
    # C# 5 como máximo: es lo que compila Windows PowerShell 5.1.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Uv4070 {
    [StructLayout(LayoutKind.Sequential)]
    public struct ClockOffset {
        public uint Version;
        public uint Type;
        public uint PState;
        public int OffsetMHz;
        public int MinOffsetMHz;
        public int MaxOffsetMHz;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Utilization {
        public uint Gpu;
        public uint Memory;
    }

    // Llamadas a nvml.dll. Todas devuelven el código NVML (0 = correcto).
    public static class Nvml {
        public const int Success = 0;
        // Códigos propios: el driver no exporta la función / no hay nvml.dll.
        public const int Missing = -1;
        public const int NoLibrary = -2;

        const string Dll = "nvml.dll";
        const CallingConvention C = CallingConvention.Cdecl;

        [DllImport(Dll, CallingConvention = C)]
        static extern int nvmlInit_v2();
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlShutdown")]
        public static extern int Shutdown();
        [DllImport(Dll, CallingConvention = C)]
        static extern IntPtr nvmlErrorString(int result);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlSystemGetDriverVersion", CharSet = CharSet.Ansi)]
        public static extern int GetDriverVersion(StringBuilder version, uint length);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetCount_v2")]
        public static extern int GetCount(out uint count);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetHandleByIndex_v2")]
        public static extern int GetHandleByIndex(uint index, out IntPtr device);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetName", CharSet = CharSet.Ansi)]
        public static extern int GetName(IntPtr device, StringBuilder name, uint length);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetClockInfo")]
        public static extern int GetClock(IntPtr device, uint type, out uint mhz);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetTemperature")]
        public static extern int GetTemperature(IntPtr device, uint sensor, out uint celsius);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetPowerUsage")]
        public static extern int GetPowerUsage(IntPtr device, out uint milliwatts);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetEnforcedPowerLimit")]
        public static extern int GetPowerLimit(IntPtr device, out uint milliwatts);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetPowerManagementDefaultLimit")]
        public static extern int GetDefaultPowerLimit(IntPtr device, out uint milliwatts);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetPowerManagementLimitConstraints")]
        public static extern int GetPowerLimitRange(IntPtr device, out uint minMilliwatts, out uint maxMilliwatts);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceSetPowerManagementLimit")]
        public static extern int SetPowerLimit(IntPtr device, uint milliwatts);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetUtilizationRates")]
        public static extern int GetUtilization(IntPtr device, out Utilization utilization);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetPerformanceState")]
        public static extern int GetPState(IntPtr device, out uint pstate);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceSetGpuLockedClocks")]
        public static extern int SetLockedClocks(IntPtr device, uint minMHz, uint maxMHz);
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceResetGpuLockedClocks")]
        public static extern int ResetLockedClocks(IntPtr device);

        [DllImport(Dll, CallingConvention = C)]
        static extern int nvmlDeviceGetClockOffsets(IntPtr device, ref ClockOffset info);
        [DllImport(Dll, CallingConvention = C)]
        static extern int nvmlDeviceSetClockOffsets(IntPtr device, ref ClockOffset info);
        [DllImport(Dll, CallingConvention = C)]
        static extern int nvmlDeviceGetGpcClkVfOffset(IntPtr device, out int mhz);
        [DllImport(Dll, CallingConvention = C)]
        static extern int nvmlDeviceSetGpcClkVfOffset(IntPtr device, int mhz);
        [DllImport(Dll, CallingConvention = C)]
        static extern int nvmlDeviceGetGpcClkMinMaxVfOffset(IntPtr device, out int minMHz, out int maxMHz);
        [DllImport(Dll, CallingConvention = C)]
        static extern int nvmlDeviceGetCurrentClocksEventReasons(IntPtr device, out ulong reasons);
        [DllImport(Dll, CallingConvention = C)]
        static extern int nvmlDeviceGetCurrentClocksThrottleReasons(IntPtr device, out ulong reasons);

        static string loadError;

        // Cualquier excepción aquí es no poder cargar nvml.dll: según la versión
        // de .NET llega como DllNotFoundException u otra.
        public static int Init() {
            try { return nvmlInit_v2(); } catch (Exception e) { loadError = e.Message; return NoLibrary; }
        }

        public static string ErrorString(int result) {
            if (result == Missing) return "el driver no tiene esta función (actualízalo)";
            if (result == NoLibrary) return "no se puede cargar nvml.dll: " + loadError;
            return Marshal.PtrToStringAnsi(nvmlErrorString(result));
        }

        // Offset del reloj gráfico (Type 0) en P0 (PState 0), el estado de
        // rendimiento de los juegos.
        static ClockOffset GraphicsP0() {
            ClockOffset o = new ClockOffset();
            o.Version = (uint)Marshal.SizeOf(typeof(ClockOffset)) | (1u << 24);  // nvmlClockOffset_v1
            return o;
        }

        // API moderna (driver R555+) y, si no está o falla, la anterior.
        public static int SetGraphicsOffset(IntPtr device, int mhz) {
            int rc = Missing;
            try {
                ClockOffset o = GraphicsP0();
                o.OffsetMHz = mhz;
                rc = nvmlDeviceSetClockOffsets(device, ref o);
                if (rc == Success) return rc;
            } catch (EntryPointNotFoundException) { }
            try { rc = nvmlDeviceSetGpcClkVfOffset(device, mhz); } catch (EntryPointNotFoundException) { }
            return rc;
        }

        // minMHz y maxMHz quedan a 0 si el driver no informa del rango.
        public static int GetGraphicsOffset(IntPtr device, out int mhz, out int minMHz, out int maxMHz) {
            mhz = 0; minMHz = 0; maxMHz = 0;
            try {
                ClockOffset o = GraphicsP0();
                if (nvmlDeviceGetClockOffsets(device, ref o) == Success) {
                    mhz = o.OffsetMHz; minMHz = o.MinOffsetMHz; maxMHz = o.MaxOffsetMHz;
                    return Success;
                }
            } catch (EntryPointNotFoundException) { }
            int rc;
            try { rc = nvmlDeviceGetGpcClkVfOffset(device, out mhz); } catch (EntryPointNotFoundException) { return Missing; }
            if (rc != Success) return rc;
            try {
                if (nvmlDeviceGetGpcClkMinMaxVfOffset(device, out minMHz, out maxMHz) != Success) { minMHz = 0; maxMHz = 0; }
            } catch (EntryPointNotFoundException) { }
            return Success;
        }

        public static int GetClockReasons(IntPtr device, out ulong reasons) {
            try { return nvmlDeviceGetCurrentClocksEventReasons(device, out reasons); } catch (EntryPointNotFoundException) { }
            try { return nvmlDeviceGetCurrentClocksThrottleReasons(device, out reasons); } catch (EntryPointNotFoundException) { }
            reasons = 0;
            return Missing;
        }
    }
}
'@
}

function Assert-Nvml([int]$Result, [string]$What) {
    if ($Result -ne [Uv4070.Nvml]::Success) {
        throw ('{0}: {1} (código NVML {2})' -f $What, [Uv4070.Nvml]::ErrorString($Result), $Result)
    }
}

# Lectura NVML con un parámetro de salida: devuelve el valor, o $null si falla.
function Read-Nvml([scriptblock]$Call, $Value = [uint32]0) {
    if ((& $Call ([ref]$Value)) -eq 0) { $Value } else { $null }
}

function Assert-Admin {
    if (-not $OnWindows) { return }
    $me = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Hace falta PowerShell como administrador (clic derecho > Ejecutar como administrador).'
    }
}

function Open-Rtx4070([bool]$WaitForDriver) {
    if (-not [Environment]::Is64BitProcess) { throw 'Usa PowerShell de 64 bits: nvml.dll es de 64 bits.' }
    # Al iniciar sesión o volver de suspensión el driver puede tardar en estar listo.
    $attempts = if ($WaitForDriver) { 20 } else { 1 }
    for ($i = 1; ; $i++) {
        $rc = [Uv4070.Nvml]::Init()
        if ($rc -eq 0 -or $rc -eq [Uv4070.Nvml]::NoLibrary -or $i -ge $attempts) { break }
        Start-Sleep -Seconds 3
    }
    if ($rc -eq [Uv4070.Nvml]::NoLibrary) {
        throw ('{0}. Instala (o reinstala) el driver de NVIDIA.' -f [Uv4070.Nvml]::ErrorString($rc))
    }
    Assert-Nvml $rc 'No se pudo iniciar NVML'
    $script:NvmlOpen = $true

    $count = [uint32]0
    Assert-Nvml ([Uv4070.Nvml]::GetCount([ref]$count)) 'nvmlDeviceGetCount'
    $found = @()
    for ($i = 0; $i -lt $count; $i++) {
        $device = [IntPtr]::Zero
        Assert-Nvml ([Uv4070.Nvml]::GetHandleByIndex($i, [ref]$device)) 'nvmlDeviceGetHandleByIndex'
        $name = New-Object System.Text.StringBuilder 96
        Assert-Nvml ([Uv4070.Nvml]::GetName($device, $name, 96)) 'nvmlDeviceGetName'
        # Solo la RTX 4070 a secas: ni Super, ni Ti, ni la de portátil.
        if ($name.ToString() -eq $GpuName) { return $device }
        $found += $name.ToString()
    }
    $others = if ($found) { $found -join ', ' } else { 'ninguna' }
    throw "Este script es solo para la $GpuName. GPUs encontradas: $others."
}

function Get-CoreOffset($Device) {
    $mhz = 0; $min = 0; $max = 0
    if ([Uv4070.Nvml]::GetGraphicsOffset($Device, [ref]$mhz, [ref]$min, [ref]$max) -ne 0) { return $null }
    [pscustomobject]@{ MHz = $mhz; Min = $min; Max = $max }
}

function Set-CoreOffset($Device, [int]$MHz) {
    Assert-Nvml ([Uv4070.Nvml]::SetGraphicsOffset($Device, $MHz)) "No se pudo poner el offset a +$MHz MHz"
    $now = Get-CoreOffset $Device
    if ($null -ne $now -and $now.MHz -ne $MHz) {
        throw "El driver aceptó el offset de +$MHz MHz pero informa de $($now.MHz) MHz."
    }
}

function Set-ClockCap($Device, [int]$MaxMHz) {
    # Sin suelo (0) para que en escritorio siga bajando de reloj. Si el driver
    # no acepta 0, se usa 210 MHz, el reloj en reposo de la 4070.
    $rc = [Uv4070.Nvml]::SetLockedClocks($Device, 0, $MaxMHz)
    if ($rc -ne 0) { $rc = [Uv4070.Nvml]::SetLockedClocks($Device, 210, $MaxMHz) }
    Assert-Nvml $rc "No se pudo poner el tope de $MaxMHz MHz"
}

function Set-PowerPct($Device, [int]$Pct) {
    $default = [uint32]0
    $rc = [Uv4070.Nvml]::GetDefaultPowerLimit($Device, [ref]$default)
    if ($rc -ne 0) {
        if ($Pct -eq 100) { return }   # nada que cambiar
        Assert-Nvml $rc 'No se pudo leer el límite de potencia de fábrica'
    }
    $target = [uint32][math]::Round($default * $Pct / 100)
    $min = [uint32]0; $max = [uint32]0
    if ([Uv4070.Nvml]::GetPowerLimitRange($Device, [ref]$min, [ref]$max) -eq 0) {
        $target = [math]::Min([math]::Max($target, $min), $max)
    }
    $current = Read-Nvml { param($out) [Uv4070.Nvml]::GetPowerLimit($Device, $out) }
    if ($current -eq $target) { return }
    $watts = '{0:N0} W' -f ($target / 1000)
    Assert-Nvml ([Uv4070.Nvml]::SetPowerLimit($Device, $target)) "No se pudo poner el límite de potencia a $watts"
    Write-Host "Límite de potencia: $watts"
}

function Invoke-Apply($Device, [int]$MaxMHz, [int]$OffsetMHz, [int]$PowerPct) {
    $current = Get-CoreOffset $Device
    if ($null -ne $current -and $current.Max -gt $current.Min -and
        ($OffsetMHz -lt $current.Min -or $OffsetMHz -gt $current.Max)) {
        throw "El driver solo admite offsets entre $($current.Min) y $($current.Max) MHz."
    }
    Write-Host ('Aplicando: tope {0} MHz, offset +{1} MHz, potencia {2} %' -f $MaxMHz, $OffsetMHz, $PowerPct)
    try {
        # Nunca debe quedar un offset positivo sin tope (eso es un overclock), ni
        # más offset del pedido: si hay que bajarlo, se baja antes de mover el tope.
        if ($null -ne $current -and $current.MHz -gt $OffsetMHz) {
            Set-CoreOffset $Device $OffsetMHz
            Set-ClockCap $Device $MaxMHz
        } else {
            Set-ClockCap $Device $MaxMHz
            Set-CoreOffset $Device $OffsetMHz
        }
        Set-PowerPct $Device $PowerPct
    } catch {
        Write-Warning 'Ha fallado un paso; se vuelve a valores de fábrica.'
        [void](Reset-Stock $Device)
        throw
    }
    Write-Host 'Hecho. Si un juego se cierra o el driver se reinicia, baja -OffsetMHz en 15.' -ForegroundColor Green
}

# Devuelve $false si algo no se pudo restaurar.
function Reset-Stock($Device) {
    $ok = $true
    # Al revés que apply: primero el offset y luego el tope. Si el offset no
    # baja a 0, el tope se queda puesto para no convertirlo en un overclock.
    $rc = [Uv4070.Nvml]::SetGraphicsOffset($Device, 0)
    if ($rc -ne 0) {
        Write-Warning ('No se pudo poner el offset a 0 ({0}); el tope de reloj se queda puesto.' -f [Uv4070.Nvml]::ErrorString($rc))
        $ok = $false
    } else {
        $rc = [Uv4070.Nvml]::ResetLockedClocks($Device)
        if ($rc -ne 0) {
            Write-Warning ('No se pudo quitar el tope de reloj: {0}' -f [Uv4070.Nvml]::ErrorString($rc))
            $ok = $false
        }
    }
    try { Set-PowerPct $Device 100 } catch { Write-Warning $_.Exception.Message; $ok = $false }
    return $ok
}

function Show-Status($Device) {
    $driver = New-Object System.Text.StringBuilder 80
    if ([Uv4070.Nvml]::GetDriverVersion($driver, 80) -ne 0) { [void]$driver.Append('n/d') }
    $core = Read-Nvml { param($out) [Uv4070.Nvml]::GetClock($Device, 0, $out) }
    $mem = Read-Nvml { param($out) [Uv4070.Nvml]::GetClock($Device, 2, $out) }
    $temp = Read-Nvml { param($out) [Uv4070.Nvml]::GetTemperature($Device, 0, $out) }
    $usage = Read-Nvml { param($out) [Uv4070.Nvml]::GetPowerUsage($Device, $out) }
    $limit = Read-Nvml { param($out) [Uv4070.Nvml]::GetPowerLimit($Device, $out) }
    $default = Read-Nvml { param($out) [Uv4070.Nvml]::GetDefaultPowerLimit($Device, $out) }
    $offset = Get-CoreOffset $Device

    Write-Host "GPU:          $GpuName (driver $driver)"
    Write-Host "Reloj:        núcleo $core MHz, memoria $mem MHz"
    Write-Host ('Offset:       {0}' -f $(if ($offset) { '{0:+0;-0;0} MHz' -f $offset.MHz } else { 'n/d' }))
    Write-Host 'Tope:         NVML no deja leerlo; con "monitor" en un juego se ve dónde se queda el reloj.'
    Write-Host ('Consumo:      {0:N1} W, límite {1:N0} W (fábrica {2:N0} W)' -f ($usage / 1000), ($limit / 1000), ($default / 1000))
    Write-Host "Temperatura:  $temp °C"
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $auto = if ($task) { $task.Actions[0].Arguments -replace '^.*" apply', 'apply' -replace ' -Unattended$', '' } else { 'no (usa "install")' }
        Write-Host "Al iniciar:   $auto"
    }
}

function Show-Monitor($Device, [int]$Samples) {
    Write-Host 'Hora      Núcleo    Memoria   Consumo  Temp   Uso  Estado  Limitado por'
    for ($n = 1; $Samples -eq 0 -or $n -le $Samples; $n++) {
        $core = Read-Nvml { param($out) [Uv4070.Nvml]::GetClock($Device, 0, $out) }
        $mem = Read-Nvml { param($out) [Uv4070.Nvml]::GetClock($Device, 2, $out) }
        $usage = Read-Nvml { param($out) [Uv4070.Nvml]::GetPowerUsage($Device, $out) }
        $temp = Read-Nvml { param($out) [Uv4070.Nvml]::GetTemperature($Device, 0, $out) }
        $pstate = Read-Nvml { param($out) [Uv4070.Nvml]::GetPState($Device, $out) }
        $util = Read-Nvml { param($out) [Uv4070.Nvml]::GetUtilization($Device, $out) } (New-Object Uv4070.Utilization)
        $reasons = Read-Nvml { param($out) [Uv4070.Nvml]::GetClockReasons($Device, $out) } ([uint64]0)
        $why = @()
        if ($reasons -band 0x84) { $why += 'potencia' }      # SW power cap, HW power brake
        if ($reasons -band 0x60) { $why += 'temperatura' }   # SW/HW thermal slowdown
        if ($reasons -band 0x08) { $why += 'HW slowdown' }
        Write-Host ('{0:HH:mm:ss}  {1,4} MHz  {2,5} MHz  {3,5:N1} W  {4,3} °C  {5,3} %  P{6,-5}  {7}' -f
            (Get-Date), $core, $mem, ($usage / 1000), $temp, $(if ($util) { $util.Gpu }), $pstate, ($why -join ', '))
        if ($Samples -eq 0 -or $n -lt $Samples) { Start-Sleep -Seconds 1 }
    }
}

function Write-AfterburnerWarning {
    if (Get-Process -Name 'MSIAfterburner' -ErrorAction SilentlyContinue) {
        Write-Warning ('MSI Afterburner está abierto. Si aplica su propia curva u offset se mezcla con esto: ' +
            'ponlo en valores por defecto y desactiva "Apply overclocking at system startup", o ciérralo.')
    }
}

function Install-Autostart([int]$MaxMHz, [int]$OffsetMHz, [int]$PowerPct) {
    # La tarea corre como SYSTEM, así que el script se copia a Program Files,
    # donde solo un administrador puede modificarlo.
    $dir = Join-Path $env:ProgramFiles 'uv4070'
    $target = Join-Path $dir 'uv4070.ps1'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ($PSCommandPath -ne $target) { Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force }

    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" apply -MaxMHz {1} -OffsetMHz {2} -PowerPct {3} -Unattended' -f
        $target, $MaxMHz, $OffsetMHz, $PowerPct
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $logon = New-ScheduledTaskTrigger -AtLogOn
    # El driver vuelve a valores de fábrica al despertar de suspensión o hibernación.
    $eventTrigger = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
    $resume = New-CimInstance -CimClass $eventTrigger -ClientOnly
    $resume.Enabled = $true
    $resume.Delay = 'PT10S'
    $resume.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">' +
        "*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]" +
        '</Select></Query></QueryList>'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $logon, $resume -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Se aplicará solo al iniciar sesión y al volver de suspensión. Registro: $env:ProgramData\uv4070\uv4070.log"
}

function Uninstall-Autostart {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    foreach ($dir in (Join-Path $env:ProgramFiles 'uv4070'), (Join-Path $env:ProgramData 'uv4070')) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
    Write-Host 'Arranque automático eliminado.'
}

$script:NvmlOpen = $false
$exitCode = 0
if ($Unattended) {
    $logDir = Join-Path $env:ProgramData 'uv4070'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Start-Transcript -Path (Join-Path $logDir 'uv4070.log') -Force | Out-Null
}
try {
    if ($Command -in 'apply', 'reset', 'install', 'uninstall') { Assert-Admin }
    if (-not $PSBoundParameters.ContainsKey('MaxMHz')) { $MaxMHz = $Presets[$Preset] }
    # Antes de abrir la GPU, para que funcione aunque ya no haya una 4070.
    if ($Command -eq 'uninstall') { Uninstall-Autostart }

    $device = Open-Rtx4070 $Unattended.IsPresent
    switch ($Command) {
        'status'  { Show-Status $device }
        'monitor' { Show-Monitor $device $Samples }
        'apply' {
            Write-AfterburnerWarning
            Invoke-Apply $device $MaxMHz $OffsetMHz $PowerPct
        }
        'install' {
            Write-AfterburnerWarning
            Invoke-Apply $device $MaxMHz $OffsetMHz $PowerPct
            Install-Autostart $MaxMHz $OffsetMHz $PowerPct
        }
        { $_ -in 'reset', 'uninstall' } {
            if (-not (Reset-Stock $device)) { throw 'No se pudo restaurar todo; reinicia el PC para volver a fábrica.' }
            Write-Host 'Valores de fábrica restaurados.'
        }
    }
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    $exitCode = 1
} finally {
    if ($script:NvmlOpen) { [void][Uv4070.Nvml]::Shutdown() }
    if ($Unattended) { Stop-Transcript | Out-Null }
}
exit $exitCode
