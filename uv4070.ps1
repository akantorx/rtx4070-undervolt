<#
.SYNOPSIS
    Undervolt automático para la NVIDIA GeForce RTX 4070, sin MSI Afterburner.

.DESCRIPTION
    "tune" encuentra solo la configuración para tu tarjeta y la guarda: la que
    menos consume perdiendo como mucho un 3 % de reloj (-MaxLossPct). Mide la
    tarjeta de serie, pone el tope, baja la tensión hasta el límite estable de
    tu chip con un test de estrés propio, deja un margen de seguridad y lo
    confirma con unos 10 minutos más de estrés.

    El undervolt se hace con NVML (nvml.dll, la librería oficial del driver de
    NVIDIA): un tope al reloj del núcleo y un offset que sube toda la curva
    tensión/frecuencia. La GPU llega al tope con menos tensión que de serie y
    no sube más. Es lo mismo que "subir la curva y aplanarla" en Afterburner,
    sin dejar nada en segundo plano.

    Comandos:
      status     Estado actual y configuración guardada (por defecto).
      tune       Busca la configuración ideal (unos 25 minutos) y la guarda.
      stress     Test de estrés de la configuración guardada (-Minutes, 10 por defecto).
      apply      Aplica la configuración guardada, o la de -MaxMHz y -OffsetMHz.
      reset      Vuelve a valores de fábrica.
      monitor    Reloj, consumo y temperatura cada segundo (Ctrl+C para salir).
      install    Aplica la configuración en cada inicio de sesión y al volver de suspensión.
      uninstall  Quita el arranque automático y vuelve a valores de fábrica.

.EXAMPLE
    .\uv4070.ps1 tune

.EXAMPLE
    .\uv4070.ps1 stress -Minutes 30

.EXAMPLE
    .\uv4070.ps1 apply -MaxMHz 2700 -OffsetMHz 150
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'tune', 'stress', 'apply', 'reset', 'monitor', 'install', 'uninstall')]
    [string]$Command = 'status',

    # Tope de reloj del núcleo. Sin él se usa el de la configuración guardada.
    [ValidateRange(1500, 3000)]
    [int]$MaxMHz,

    # Cuánto se sube la curva. Más offset = menos tensión en el tope, hasta que
    # deja de ser estable. Sin él se usa el de la configuración guardada.
    [ValidateRange(0, 300)]
    [int]$OffsetMHz,

    # Límite de potencia en % del de fábrica (200 W en la 4070 de referencia).
    [ValidateRange(50, 100)]
    [int]$PowerPct = 100,

    # Solo para tune: cuánto reloj máximo se puede perder frente a serie a cambio
    # de consumir menos. Más = más ahorro.
    [ValidateRange(0, 15)]
    [int]$MaxLossPct = 3,

    # Solo para stress: duración en minutos.
    [ValidateRange(1, 600)]
    [int]$Minutes = 10,

    # Solo para monitor: número de lecturas (0 = hasta Ctrl+C).
    [ValidateRange(0, 86400)]
    [int]$Samples = 0,

    # No preguntar: tune empieza sin confirmar y deja el resultado instalado.
    [switch]$Yes,

    # Lo usa la tarea programada: espera al driver y guarda un registro.
    [switch]$Unattended
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$GpuName = 'NVIDIA GeForce RTX 4070'
$TaskName = 'uv4070'
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$Bound = $PSBoundParameters

# Ajuste automático (tune). Los relojes van en múltiplos de 15 MHz, el paso de Ada.
$OffsetStep = 30       # búsqueda gruesa; después afina en pasos de 15
$OffsetMargin = 30     # margen de seguridad bajo el último offset estable
$ConfirmScale = 7      # la confirmación dura 7 rondas de búsqueda (unos 10 minutos)
$WarmupSeconds = 60
$SafeMHz = 1500        # reloj al que se calcula la referencia del test de estrés

if (-not ('Uv4070.Nvml' -as [type])) {
    # C# 5 como máximo: es lo que compila Windows PowerShell 5.1.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

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

    public class StressResult {
        public int Batches;
        public long Errors;
        public bool DeviceLost;
        public string Failure;
        public double Tflops;
        public double LowTflops;      // percentil 1 del rendimiento por lote
        public double Watts;
        public double ClockMHz;
        public uint MaxTempC;
        public double P0Pct = -1;
        public double PowerCappedPct = -1;
    }

    // Test de estrés en DirectX 11 (compute shader), sin librerías externas:
    // las interfaces COM se llaman por su posición en la tabla virtual.
    public sealed class Stress : IDisposable {
        // Modos de Run: carga máxima sostenida; 2 s de carga y 0,7 s de reposo
        // (cambios bruscos de carga y tensión); y carga ligera (un 25 % del
        // tiempo), con la que la GPU sube a su reloj máximo sin tocar el límite
        // de potencia, como en un juego.
        public const int Steady = 0, Pulses = 1, Light = 2;
        public const uint Groups = 4096;
        public const uint Threads = Groups * 256;
        const uint MaxIterations = 1u << 22;
        const double BatchMs = 50;
        const string LostMessage = "el driver se ha reiniciado";

        // Cada hilo itera 8 cadenas caóticas x = x*x + c (una FMA por paso) y
        // resume el recorrido en un hash. Un solo bit erróneo en cualquier paso
        // cambia el hash final, así que comparar con el hash de referencia detecta
        // errores de cálculo antes de que el driver llegue a colgarse.
        const string Shader = @"
cbuffer Params : register(b0) { uint Iterations; uint Verify; uint2 Unused; };
RWStructuredBuffer<uint> Reference : register(u0);
RWStructuredBuffer<uint> Errors : register(u1);

[numthreads(256, 1, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint k;
    uint seed = id.x * 2654435761u + 12345u;
    float x[8];
    [unroll] for (k = 0; k < 8; k++) {
        seed = seed * 1664525u + 1013904223u;
        x[k] = (seed >> 8) * (3.0 / 16777216.0) - 1.5;
    }
    uint h = seed;
    [loop] for (uint i = 0; i < Iterations; i++) {
        [unroll] for (k = 0; k < 8; k++) x[k] = mad(x[k], x[k], -1.8 - 0.0125 * k);
        h = (h ^ asuint(x[0])) * 16777619u;
    }
    [unroll] for (k = 1; k < 8; k++) h = (h ^ asuint(x[k])) * 16777619u;
    if (Verify == 0) Reference[id.x] = h;
    else if (Reference[id.x] != h) InterlockedAdd(Errors[0], 1);
}";

        [StructLayout(LayoutKind.Sequential)]
        struct BufferDesc { public uint ByteWidth, Usage, BindFlags, CpuAccessFlags, MiscFlags, StructureByteStride; }
        [StructLayout(LayoutKind.Sequential)]
        struct UavDesc { public uint Format, ViewDimension, FirstElement, NumElements, Flags; }
        [StructLayout(LayoutKind.Sequential)]
        struct Mapped { public IntPtr Data; public uint RowPitch, DepthPitch; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct AdapterDesc1 {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
            public uint VendorId, DeviceId, SubSysId, Revision;
            public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
            public uint LuidLow;
            public int LuidHigh;
            public uint Flags;
        }

        const uint UsageStaging = 3, BindConstantBuffer = 0x4, BindUnorderedAccess = 0x80;
        const uint CpuAccessRead = 0x20000, MiscStructured = 0x40;

        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint ReleaseFn(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int EnumAdapters1Fn(IntPtr self, uint index, out IntPtr adapter);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetDesc1Fn(IntPtr self, out AdapterDesc1 desc);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate IntPtr BlobPointerFn(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate UIntPtr BlobSizeFn(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateBufferFn(IntPtr self, ref BufferDesc desc, IntPtr initialData, out IntPtr buffer);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateUavFn(IntPtr self, IntPtr resource, ref UavDesc desc, out IntPtr view);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateComputeShaderFn(IntPtr self, IntPtr code, UIntPtr length, IntPtr linkage, out IntPtr shader);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetDeviceRemovedReasonFn(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int MapFn(IntPtr self, IntPtr resource, uint subresource, uint type, uint flags, out Mapped mapped);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void UnmapFn(IntPtr self, IntPtr resource, uint subresource);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void DispatchFn(IntPtr self, uint x, uint y, uint z);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void CopyResourceFn(IntPtr self, IntPtr destination, IntPtr source);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void UpdateSubresourceFn(IntPtr self, IntPtr destination, uint subresource, IntPtr box, uint[] data, uint rowPitch, uint depthPitch);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void ClearUavUintFn(IntPtr self, IntPtr view, uint[] values);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void CsSetUavsFn(IntPtr self, uint start, uint count, IntPtr[] views, uint[] initialCounts);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void CsSetShaderFn(IntPtr self, IntPtr shader, IntPtr instances, uint count);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void CsSetConstantBuffersFn(IntPtr self, uint start, uint count, IntPtr[] buffers);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void ContextFn(IntPtr self);

        [DllImport("dxgi.dll")]
        static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr factory);
        [DllImport("d3d11.dll")]
        static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, uint[] featureLevels,
            uint levels, uint sdkVersion, out IntPtr device, out uint featureLevel, out IntPtr context);
        [DllImport("d3dcompiler_47.dll", CharSet = CharSet.Ansi)]
        static extern int D3DCompile(byte[] source, UIntPtr size, string name, IntPtr defines, IntPtr include,
            string entryPoint, string target, uint flags1, uint flags2, out IntPtr code, out IntPtr messages);

        IntPtr device, context, shader, reference, referenceView, errors, errorsView, constants;
        readonly IntPtr[] staging = new IntPtr[2];
        MapFn map;
        UnmapFn unmap;
        DispatchFn dispatch;
        CopyResourceFn copyResource;
        UpdateSubresourceFn updateSubresource;
        ClearUavUintFn clearUav;
        ContextFn flush;
        GetDeviceRemovedReasonFn removedReason;

        public uint Iterations { get; set; }
        public double DispatchMs { get; private set; }
        // Tras un reinicio del driver el dispositivo ya no sirve: hay que abrir otro.
        public bool Lost { get; private set; }

        Stress() { }

        public static Stress Open(string adapterName) {
            Stress s = new Stress();
            try { s.Create(adapterName); } catch { s.Dispose(); throw; }
            return s;
        }

        static T Fn<T>(IntPtr obj, int index) where T : class {
            IntPtr method = Marshal.ReadIntPtr(Marshal.ReadIntPtr(obj), index * IntPtr.Size);
            return (T)(object)Marshal.GetDelegateForFunctionPointer(method, typeof(T));
        }

        static void Release(ref IntPtr obj) {
            if (obj == IntPtr.Zero) return;
            Fn<ReleaseFn>(obj, 2)(obj);
            obj = IntPtr.Zero;
        }

        static void Check(int hr, string what) {
            if (hr < 0) throw new InvalidOperationException(what + " ha fallado (0x" + hr.ToString("X8") + ")");
        }

        static IntPtr FindAdapter(string name) {
            Guid iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");  // IDXGIFactory1
            IntPtr factory;
            Check(CreateDXGIFactory1(ref iid, out factory), "CreateDXGIFactory1");
            List<string> seen = new List<string>();
            try {
                EnumAdapters1Fn enumAdapters = Fn<EnumAdapters1Fn>(factory, 12);
                IntPtr adapter;
                for (uint i = 0; enumAdapters(factory, i, out adapter) >= 0; i++) {
                    AdapterDesc1 desc;
                    if (Fn<GetDesc1Fn>(adapter, 10)(adapter, out desc) >= 0) {
                        string found = (desc.Description ?? "").Trim();
                        if (found == name) return adapter;
                        seen.Add(found);
                    }
                    Release(ref adapter);
                }
            } finally {
                Release(ref factory);
            }
            throw new InvalidOperationException("DirectX no encuentra la " + name + " (adaptadores: " + string.Join(", ", seen) + ")");
        }

        void Create(string adapterName) {
            IntPtr adapter = FindAdapter(adapterName);
            try {
                uint level;
                // Driver UNKNOWN (0) porque se indica el adaptador; nivel 11_0; SDK 7.
                Check(D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0, new uint[] { 0xb000 }, 1, 7,
                    out device, out level, out context), "D3D11CreateDevice");
            } finally {
                Release(ref adapter);
            }
            map = Fn<MapFn>(context, 14);
            unmap = Fn<UnmapFn>(context, 15);
            dispatch = Fn<DispatchFn>(context, 41);
            copyResource = Fn<CopyResourceFn>(context, 47);
            updateSubresource = Fn<UpdateSubresourceFn>(context, 48);
            clearUav = Fn<ClearUavUintFn>(context, 51);
            flush = Fn<ContextFn>(context, 111);
            removedReason = Fn<GetDeviceRemovedReasonFn>(device, 39);

            shader = CompileShader();
            reference = CreateBuffer(Threads * 4, 0, BindUnorderedAccess, 0, MiscStructured, 4);
            referenceView = CreateView(reference, Threads);
            errors = CreateBuffer(16, 0, BindUnorderedAccess, 0, MiscStructured, 4);
            errorsView = CreateView(errors, 4);
            for (int i = 0; i < staging.Length; i++) staging[i] = CreateBuffer(16, UsageStaging, 0, CpuAccessRead, MiscStructured, 4);
            constants = CreateBuffer(16, 0, BindConstantBuffer, 0, 0, 0);

            Fn<CsSetShaderFn>(context, 69)(context, shader, IntPtr.Zero, 0);
            Fn<CsSetUavsFn>(context, 68)(context, 0, 2, new IntPtr[] { referenceView, errorsView }, new uint[] { uint.MaxValue, uint.MaxValue });
            Fn<CsSetConstantBuffersFn>(context, 71)(context, 0, 1, new IntPtr[] { constants });
        }

        IntPtr CompileShader() {
            byte[] source = Encoding.ASCII.GetBytes(Shader);
            IntPtr code, messages;
            int hr = D3DCompile(source, (UIntPtr)(uint)source.Length, "uv4070", IntPtr.Zero, IntPtr.Zero,
                "main", "cs_5_0", 1u << 15 /* OPTIMIZATION_LEVEL3 */, 0, out code, out messages);
            string text = messages != IntPtr.Zero ? Marshal.PtrToStringAnsi(Fn<BlobPointerFn>(messages, 3)(messages)) : "";
            Release(ref messages);
            if (hr < 0) throw new InvalidOperationException("No se pudo compilar el test de estrés: " + text);
            try {
                IntPtr cs;
                Check(Fn<CreateComputeShaderFn>(device, 18)(device, Fn<BlobPointerFn>(code, 3)(code),
                    Fn<BlobSizeFn>(code, 4)(code), IntPtr.Zero, out cs), "CreateComputeShader");
                return cs;
            } finally {
                Release(ref code);
            }
        }

        IntPtr CreateBuffer(uint size, uint usage, uint bind, uint cpu, uint misc, uint stride) {
            BufferDesc d = new BufferDesc();
            d.ByteWidth = size; d.Usage = usage; d.BindFlags = bind;
            d.CpuAccessFlags = cpu; d.MiscFlags = misc; d.StructureByteStride = stride;
            IntPtr buffer;
            Check(Fn<CreateBufferFn>(device, 3)(device, ref d, IntPtr.Zero, out buffer), "CreateBuffer");
            return buffer;
        }

        IntPtr CreateView(IntPtr buffer, uint elements) {
            UavDesc d = new UavDesc();
            d.ViewDimension = 1;  // D3D11_UAV_DIMENSION_BUFFER; formato UNKNOWN por ser estructurado
            d.NumElements = elements;
            IntPtr view;
            Check(Fn<CreateUavFn>(device, 8)(device, buffer, ref d, out view), "CreateUnorderedAccessView");
            return view;
        }

        void SetParams(uint iterations, uint verify) {
            updateSubresource(context, constants, 0, IntPtr.Zero, new uint[] { iterations, verify, 0, 0 }, 0, 0);
        }

        void ClearErrors() {
            clearUav(context, errorsView, new uint[4]);
        }

        // Espera a que la GPU termine el lote que copió su contador en staging[slot].
        bool ReadErrors(int slot, out long count) {
            count = 0;
            Mapped m;
            if (map(context, staging[slot], 0, 1 /* MAP_READ */, 0, out m) < 0) { Lost = true; return false; }
            count = (uint)Marshal.ReadInt32(m.Data);
            unmap(context, staging[slot], 0);
            if (removedReason(device) < 0) { Lost = true; return false; }
            return true;
        }

        double TimeDispatch() {
            Stopwatch sw = Stopwatch.StartNew();
            dispatch(context, Groups, 1, 1);
            copyResource(context, staging[0], errors);
            long ignored;
            if (!ReadErrors(0, out ignored)) throw new InvalidOperationException("El driver se ha reiniciado durante la calibración.");
            return sw.Elapsed.TotalMilliseconds;
        }

        // Elige las iteraciones para que cada dispatch dure unos targetMs: lo
        // bastante corto para que Windows no lo tome por un cuelgue (2 s).
        public void Calibrate(double targetMs) {
            SetParams(256, 0);
            for (int i = 0; i < 5; i++) TimeDispatch();
            uint iterations = 256;
            for (;;) {
                SetParams(iterations, 0);
                double ms = double.MaxValue;
                for (int i = 0; i < 3; i++) ms = Math.Min(ms, TimeDispatch());
                if (ms >= targetMs / 4 || iterations >= MaxIterations) {
                    double scaled = iterations * targetMs / Math.Max(ms, 0.001);
                    Iterations = (uint)Math.Max(64, Math.Min(MaxIterations, scaled));
                    DispatchMs = ms * Iterations / iterations;
                    return;
                }
                iterations *= 4;
            }
        }

        // Calcula los hashes de referencia y comprueba que se repiten.
        public void CaptureReference() {
            SetParams(Iterations, 0);
            dispatch(context, Groups, 1, 1);
            ClearErrors();
            SetParams(Iterations, 1);
            for (int i = 0; i < 3; i++) dispatch(context, Groups, 1, 1);
            copyResource(context, staging[0], errors);
            long count;
            if (!ReadErrors(0, out count)) throw new InvalidOperationException("El driver se ha reiniciado al preparar el test.");
            if (count != 0) throw new InvalidOperationException("La GPU no repite sus resultados ni con reloj bajo y sin undervolt.");
        }

        public StressResult Run(double seconds, IntPtr nvmlDevice, int mode) {
            StressResult r = new StressResult();
            if (Lost) { r.DeviceLost = true; r.Failure = LostMessage; return r; }
            ClearErrors();
            SetParams(Iterations, 1);
            int perBatch = mode == Light ? 1 : Math.Max(1, (int)Math.Round(BatchMs / Math.Max(DispatchMs, 0.1)));
            int depth = mode == Light ? 1 : staging.Length;
            double flops = (double)Threads * Iterations * 16 * perBatch;
            List<double> tflops = new List<double>();
            List<int> queue = new List<int>();  // lotes en vuelo, el más antiguo primero
            Sampler sampler = new Sampler(nvmlDevice);
            Stopwatch total = Stopwatch.StartNew(), burst = Stopwatch.StartNew();
            double lastDone = 0;
            bool skip = true;  // el primer lote incluye el arranque desde reposo
            int next = 0;
            while (r.Failure == null && total.Elapsed.TotalSeconds < seconds) {
                // Dos lotes en vuelo para que la GPU no espere a la CPU.
                while (queue.Count < depth) {
                    for (int i = 0; i < perBatch; i++) dispatch(context, Groups, 1, 1);
                    copyResource(context, staging[next], errors);
                    flush(context);
                    queue.Add(next);
                    next ^= 1;
                }
                if (!Complete(Dequeue(queue), r)) break;
                double now = total.Elapsed.TotalMilliseconds;
                if (!skip) tflops.Add(flops / ((now - lastDone) / 1000) / 1e12);
                lastDone = now;
                skip = false;
                r.Batches++;
                sampler.Sample();
                if (mode == Light) {
                    Thread.Sleep((int)(3 * DispatchMs) + 1);
                    lastDone = total.Elapsed.TotalMilliseconds;
                    skip = true;
                }
                if (mode == Pulses && burst.Elapsed.TotalSeconds >= 2) {
                    while (queue.Count > 0 && Complete(Dequeue(queue), r)) { }
                    if (r.Failure != null) break;
                    Thread.Sleep(700);
                    burst.Restart();
                    lastDone = total.Elapsed.TotalMilliseconds;
                    skip = true;
                }
            }
            while (!Lost && queue.Count > 0 && Complete(Dequeue(queue), r)) { }
            if (tflops.Count > 0) {
                double sum = 0;
                foreach (double t in tflops) sum += t;
                r.Tflops = sum / tflops.Count;
                tflops.Sort();
                r.LowTflops = tflops[(int)(tflops.Count * 0.01)];
            }
            sampler.Fill(r);
            return r;
        }

        // Queue<T> está en System.dll en .NET Framework; List<T> en mscorlib.
        static int Dequeue(List<int> queue) {
            int slot = queue[0];
            queue.RemoveAt(0);
            return slot;
        }

        bool Complete(int slot, StressResult r) {
            long count;
            if (!ReadErrors(slot, out count)) {
                r.DeviceLost = true;
                r.Failure = LostMessage;
                return false;
            }
            if (count > 0) {
                r.Errors = count;
                if (r.Failure == null) r.Failure = "errores de cálculo";
            }
            return true;
        }

        public void Dispose() {
            if (context != IntPtr.Zero && !Lost) Fn<ContextFn>(context, 110)(context);  // ClearState
            Release(ref constants);
            for (int i = 0; i < staging.Length; i++) Release(ref staging[i]);
            Release(ref errorsView);
            Release(ref errors);
            Release(ref referenceView);
            Release(ref reference);
            Release(ref shader);
            Release(ref context);
            Release(ref device);
        }

        // Lecturas NVML durante la carga, cada 200 ms.
        sealed class Sampler {
            readonly IntPtr device;
            readonly Stopwatch clock = Stopwatch.StartNew();
            long nextMs;
            int count, pstates, p0, reasonReads, capped;
            double watts, mhz;
            uint maxTemp;

            public Sampler(IntPtr device) { this.device = device; }

            public void Sample() {
                if (device == IntPtr.Zero || clock.ElapsedMilliseconds < nextMs) return;
                nextMs = clock.ElapsedMilliseconds + 200;
                uint mw, clk, temp, ps;
                ulong reasons;
                if (Nvml.GetPowerUsage(device, out mw) == 0 && Nvml.GetClock(device, 0, out clk) == 0) {
                    watts += mw / 1000.0; mhz += clk; count++;
                }
                if (Nvml.GetTemperature(device, 0, out temp) == 0 && temp > maxTemp) maxTemp = temp;
                if (Nvml.GetPState(device, out ps) == 0) { pstates++; if (ps == 0) p0++; }
                if (Nvml.GetClockReasons(device, out reasons) == 0) {
                    reasonReads++;
                    if ((reasons & 0x84) != 0) capped++;  // SW power cap, HW power brake
                }
            }

            public void Fill(StressResult r) {
                if (count > 0) { r.Watts = watts / count; r.ClockMHz = mhz / count; }
                r.MaxTempC = maxTemp;
                if (pstates > 0) r.P0Pct = 100.0 * p0 / pstates;
                if (reasonReads > 0) r.PowerCappedPct = 100.0 * capped / reasonReads;
            }
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

# Aquí viven la copia instalada del script, la configuración y los registros:
# solo un administrador puede modificarlos.
function Get-DataDir { Join-Path $env:ProgramFiles 'uv4070' }

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

function Get-DriverVersion {
    $version = New-Object System.Text.StringBuilder 80
    if ([Uv4070.Nvml]::GetDriverVersion($version, 80) -eq 0) { $version.ToString() } else { 'n/d' }
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

# Tope y offset en un orden seguro: nunca queda un offset positivo sin tope (eso
# es un overclock), ni más offset del pedido mientras se mueve el tope.
function Set-Uv($Device, [int]$MaxMHz, [int]$OffsetMHz) {
    $current = Get-CoreOffset $Device
    if ($null -ne $current -and $current.Max -gt $current.Min -and
        ($OffsetMHz -lt $current.Min -or $OffsetMHz -gt $current.Max)) {
        throw "El driver solo admite offsets entre $($current.Min) y $($current.Max) MHz."
    }
    if ($null -ne $current -and $current.MHz -eq $OffsetMHz) {
        Set-ClockCap $Device $MaxMHz
    } elseif ($null -ne $current -and $current.MHz -gt $OffsetMHz) {
        Set-CoreOffset $Device $OffsetMHz
        Set-ClockCap $Device $MaxMHz
    } else {
        Set-ClockCap $Device $MaxMHz
        Set-CoreOffset $Device $OffsetMHz
    }
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

function Invoke-Apply($Device, $Config) {
    Write-Host ('Aplicando: tope {0} MHz, offset +{1} MHz, potencia {2} %' -f $Config.MaxMHz, $Config.OffsetMHz, $Config.PowerPct)
    try {
        Set-Uv $Device $Config.MaxMHz $Config.OffsetMHz
        Set-PowerPct $Device $Config.PowerPct
    } catch {
        Write-Warning 'Ha fallado un paso; se vuelve a valores de fábrica.'
        [void](Reset-Stock $Device)
        throw
    }
    Write-Host 'Hecho.' -ForegroundColor Green
}

# Devuelve $false si algo no se pudo restaurar.
function Reset-Stock($Device) {
    $ok = $true
    # Al revés que Set-Uv: primero el offset y luego el tope. Si el offset no
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

function Read-Config {
    $path = Join-Path (Get-DataDir) 'config.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    # La tarea programada la aplica como SYSTEM: se revisa aunque solo un administrador pueda escribirla.
    if ($config.MaxMHz -lt 1500 -or $config.MaxMHz -gt 3000 -or $config.OffsetMHz -lt 0 -or
        $config.OffsetMHz -gt 300 -or $config.PowerPct -lt 50 -or $config.PowerPct -gt 100) {
        throw "La configuración guardada en $path no es válida; vuelve a ejecutar tune."
    }
    $config
}

function Save-Config($Config) {
    $dir = Get-DataDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'config.json') -Encoding UTF8
}

# Configuración guardada, con -MaxMHz, -OffsetMHz y -PowerPct por encima.
function Resolve-Config([bool]$Required) {
    $saved = Read-Config
    $config = [pscustomobject]@{ MaxMHz = $null; OffsetMHz = $null; PowerPct = 100 }
    if ($saved) {
        $config.MaxMHz = [int]$saved.MaxMHz; $config.OffsetMHz = [int]$saved.OffsetMHz; $config.PowerPct = [int]$saved.PowerPct
    }
    if ($Bound.ContainsKey('MaxMHz')) { $config.MaxMHz = $MaxMHz }
    if ($Bound.ContainsKey('OffsetMHz')) { $config.OffsetMHz = $OffsetMHz }
    if ($Bound.ContainsKey('PowerPct')) { $config.PowerPct = $PowerPct }
    if (($null -eq $config.MaxMHz) -ne ($null -eq $config.OffsetMHz) -or ($Required -and $null -eq $config.MaxMHz)) {
        throw 'No hay configuración guardada: ejecuta "tune", o indica -MaxMHz y -OffsetMHz.'
    }
    $config
}

# ---------------------------------------------------------------------------
# Test de estrés y ajuste automático

$script:Engine = $null

function New-StressEngine { [Uv4070.Stress]::Open($GpuName) }

# Motor del test listo para usar. Al crearlo, la referencia se calcula a
# $SafeMHz y sin offset, donde cualquier 4070 es estable; después hay que volver
# a poner la configuración que se quiera probar.
function Get-Engine($Device) {
    if ($script:Engine -and -not $script:Engine.Lost) { return $script:Engine }
    Close-Engine
    Set-Uv $Device $SafeMHz 0
    $engine = New-StressEngine
    $engine.Calibrate(15)
    $engine.CaptureReference()
    $script:Engine = $engine
    $engine
}

function Close-Engine {
    if ($script:Engine) { $script:Engine.Dispose() }
    $script:Engine = $null
}

# Reinicios del driver (TDR) en el registro de eventos de Windows.
function Get-DriverResets([datetime]$Since) {
    if (-not (Get-Command Get-WinEvent -ErrorAction SilentlyContinue)) { return @() }
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'nvlddmkm', 'Display'; StartTime = $Since } -ErrorAction Stop
    } catch {
        return @()   # sin eventos, Get-WinEvent da error
    }
    @($events | Where-Object { ($_.ProviderName -eq 'nvlddmkm' -and $_.Level -le 2) -or $_.Id -eq 4101 })
}

# Una carga con un tope y offset concretos ($Cap 0 = de serie). $Mode es
# Steady, Pulses o Light de [Uv4070.Stress]. En tramos de 20 s como máximo para
# que Ctrl+C responda.
function Invoke-Step($Device, [int]$Cap, [int]$Offset, [double]$Seconds, [int]$Mode = 0) {
    $engine = Get-Engine $Device
    if ($Cap -gt 0) { Set-Uv $Device $Cap $Offset } else { [void](Reset-Stock $Device) }
    $since = Get-Date
    $left = $Seconds
    do {
        $chunk = [math]::Min($left, 20)
        $left -= $chunk
        $result = $engine.Run($chunk, $Device, $Mode)
    } while (-not $result.Failure -and $left -gt 0)
    if (-not $result.Failure -and @(Get-DriverResets $since).Count -gt 0) { $result.Failure = 'el driver se ha reiniciado' }
    $result
}

function Measure-Point($Device, [int]$Cap, [int]$Offset) {
    [void](Invoke-Step $Device $Cap $Offset 5)   # se estabiliza
    $r = Invoke-Step $Device $Cap $Offset 20
    if ($r.Failure) { throw "El test ha fallado midiendo con tope $Cap MHz y offset +$Offset MHz: $($r.Failure)." }
    [pscustomobject]@{
        Cap = $Cap; Offset = $Offset; Tflops = $r.Tflops; LowTflops = $r.LowTflops; Watts = $r.Watts
        ClockMHz = $r.ClockMHz; MaxTempC = $r.MaxTempC; P0Pct = $r.P0Pct; PowerCappedPct = $r.PowerCappedPct
    }
}

# Reloj máximo de serie con carga ligera, como en un juego que no llega al límite de potencia.
function Measure-Boost($Device) {
    $r = Invoke-Step $Device 0 0 10 ([Uv4070.Stress]::Light)
    if ($r.Failure) { throw "El test ha fallado de serie con carga ligera: $($r.Failure)." }
    $r.ClockMHz
}

# El tope que pierde $LossPct % frente al reloj máximo de serie, en pasos de 15 MHz.
function Get-TargetCap([double]$BoostMHz, [int]$LossPct) {
    [int]([math]::Floor($BoostMHz * (100 - $LossPct) / 100 / 15) * 15)
}

# Un ciclo de estabilidad: carga sostenida en el tope, la misma curva más abajo
# (cada reloj usa su propio punto de tensión) y pulsos de carga. $Scale alarga cada parte.
function Test-Stability($Device, [int]$Cap, [int]$Offset, [double]$Scale) {
    $steadyMode = [Uv4070.Stress]::Steady
    $plan = @(@{ Cap = $Cap; Seconds = 40; Mode = $steadyMode })
    if ($Cap -gt 0) {
        foreach ($f in ($Cap - 300), ($Cap - 600), ($Cap - 900)) {
            if ($f -ge $SafeMHz) { $plan += @{ Cap = $f; Seconds = 8; Mode = $steadyMode } }
        }
    }
    $plan += @{ Cap = $Cap; Seconds = 15; Mode = [Uv4070.Stress]::Pulses }
    $steady = $null
    foreach ($p in $plan) {
        $r = Invoke-Step $Device $p.Cap $Offset ($p.Seconds * $Scale) $p.Mode
        if ($null -eq $steady) { $steady = $r }
        if ($r.Failure) {
            $where = if ($p.Cap -gt 0) { " a $($p.Cap) MHz" } else { '' }
            return [pscustomobject]@{ Failure = "$($r.Failure)$where"; Steady = $steady }
        }
    }
    [pscustomobject]@{ Failure = $null; Steady = $steady }
}

# Siguiente offset a probar: de $OffsetStep en $OffsetStep hasta el primer fallo y
# luego un paso de 15 entre el último bueno y el primero malo. $null = terminado.
function Get-NextOffset($Passed, $Failed, [bool]$Plateau) {
    if ($Plateau) { return $null }
    $lowestFail = Get-LowestFail $Failed
    $highestPass = Get-HighestPass $Passed $Failed
    if ($null -eq $lowestFail) { return $highestPass + $OffsetStep }
    if ($lowestFail - $highestPass -gt 15) { return $highestPass + 15 }
    return $null
}

function Get-LowestFail($Failed) {
    $bad = @(@($Failed) | Where-Object { $null -ne $_ })
    if ($bad.Count) { [int]($bad | Measure-Object -Minimum).Minimum } else { $null }
}

# El offset estable más alto por debajo del primer fallo (0 si ninguno).
function Get-HighestPass($Passed, $Failed) {
    $lowestFail = Get-LowestFail $Failed
    $good = @(@($Passed) | Where-Object { $null -ne $_ -and ($null -eq $lowestFail -or $_ -lt $lowestFail) })
    if ($good.Count) { [int]($good | Measure-Object -Maximum).Maximum } else { 0 }
}

function Read-TuneState {
    $path = Join-Path (Get-DataDir) 'tune-state.json'
    if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } else { $null }
}

function Save-TuneState($State) {
    $dir = Get-DataDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dir 'tune-state.json') -Encoding UTF8
}

function Remove-TuneState {
    $path = Join-Path (Get-DataDir) 'tune-state.json'
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
}

function Write-Phase([string]$Text) {
    Write-Host ''
    Write-Host ('[{0:HH:mm}] {1}' -f (Get-Date), $Text) -ForegroundColor Cyan
}

function Format-Point($P) {
    $cap = if ($P.Cap -gt 0) { '{0} MHz' -f $P.Cap } else { 'de serie' }
    '  {0,-9} {1,5:N1} TFLOPS  1% low {2,5:N1}  {3,5:N0} W  {4,4:F0} MHz  {5,3} °C' -f
        $cap, $P.Tflops, $P.LowTflops, $P.Watts, $P.ClockMHz, $P.MaxTempC
}

function Invoke-Tune($Device) {
    Write-Host "tune busca la configuración que menos consume perdiendo como mucho un $MaxLossPct % de reloj (unos 25 minutos):"
    Write-Host '  1. Mide la tarjeta de serie: rendimiento, consumo y reloj máximo.'
    Write-Host "  2. Con el tope un $MaxLossPct % por debajo de ese reloj, sube la curva (menos tensión) hasta que"
    Write-Host "     el test de estrés falla, y deja $OffsetMargin MHz de margen."
    Write-Host '  3. Lo confirma con unos 10 minutos más de estrés y lo guarda.'
    Write-Host 'Cierra juegos, navegadores y todo lo que use la GPU. Puede que la pantalla parpadee o que'
    Write-Host 'el driver se reinicie: es normal y no daña la tarjeta. Si el PC se llega a colgar,'
    Write-Host 'reinícialo y vuelve a ejecutar tune: seguirá donde lo dejó.'
    if (-not $Yes -and (Read-Host '¿Empezar? (s/n)') -notmatch '^[sS]') { return }

    $driver = Get-DriverVersion
    $state = Read-TuneState
    if ($state -and ($state.Driver -ne $driver -or $state.LossPct -ne $MaxLossPct)) { $state = $null }
    if ($state) {
        Write-Host 'Continuando el ajuste anterior.'
        if ($null -ne $state.Testing) {
            # Si el estado aún marca una prueba en curso, el PC se colgó en ella.
            Write-Warning "El PC se colgó probando el offset +$($state.Testing) MHz: cuenta como inestable."
            if ($null -eq $state.Best) { $state.Failed = @($state.Failed) + [int]$state.Testing }
            else { $state.Best = [math]::Max(0, [int]$state.Testing - 15) }
            $state.Testing = $null
            Save-TuneState $state
        }
    } else {
        $state = [pscustomobject]@{
            Driver = $driver; LossPct = $MaxLossPct; Baseline = $null; BoostMHz = $null; Target = $null
            Passed = @(); Failed = @(); LastWatts = $null; Plateau = $false; Best = $null; Testing = $null
        }
    }

    $done = $false
    try {
        if ($null -eq $state.Target) {
            Write-Phase '1/3  La tarjeta de serie'
            $warm = Invoke-Step $Device 0 0 $WarmupSeconds
            if ($warm.Failure) {
                throw "La GPU falla el test incluso de serie ($($warm.Failure)). Revisa el driver o la tarjeta antes de hacer undervolt."
            }
            $base = Measure-Point $Device 0 0
            if ($base.P0Pct -ge 0 -and $base.P0Pct -lt 90) {
                throw "La carga de prueba no lleva la GPU a P0 (solo un $([int]$base.P0Pct) % del tiempo): los resultados no servirían."
            }
            Write-Host (Format-Point $base)
            $state.Baseline = $base
            $state.BoostMHz = Measure-Boost $Device
            $state.Target = Get-TargetCap $state.BoostMHz $MaxLossPct
            Save-TuneState $state
            Write-Host ('  Reloj máximo con carga ligera: {0:F0} MHz. Tope: {1} MHz.' -f $state.BoostMHz, $state.Target)
        }
        $target = [int]$state.Target

        if ($null -eq $state.Best) {
            Write-Phase "2/3  Tensión mínima estable a $target MHz (más offset = menos tensión)"
            while ($true) {
                $offset = Get-NextOffset $state.Passed $state.Failed $state.Plateau
                if ($null -eq $offset -or $offset -gt 300) { break }
                $state.Testing = $offset
                Save-TuneState $state
                $result = Test-Stability $Device $target $offset 1
                $state.Testing = $null
                if ($result.Failure) {
                    $state.Failed = @($state.Failed) + $offset
                    Write-Host ('  +{0,3} MHz  falla: {1}' -f $offset, $result.Failure) -ForegroundColor Yellow
                } else {
                    $watts = $result.Steady.Watts
                    # Por debajo de la tensión mínima de la curva, más offset ya no ahorra nada.
                    if ($null -eq (Get-LowestFail $state.Failed) -and $state.LastWatts -and $watts -ge 0.99 * $state.LastWatts) {
                        $state.Plateau = $true
                    }
                    $state.LastWatts = $watts
                    $state.Passed = @($state.Passed) + $offset
                    Write-Host ('  +{0,3} MHz  estable  {1,5:N0} W' -f $offset, $watts)
                }
                Save-TuneState $state
            }
            $highest = Get-HighestPass $state.Passed $state.Failed
            $state.Best = [math]::Max(0, $highest - $OffsetMargin)
            Save-TuneState $state
            if ($state.Plateau) { Write-Host 'Más offset ya no baja el consumo: la tensión ya está en el mínimo de la curva.' }
            Write-Host "Máximo estable: +$highest MHz. Con margen: +$($state.Best) MHz."
        }

        $offset = [int]$state.Best
        while ($true) {
            Write-Phase "3/3  Confirmación: tope $target MHz, offset +$offset MHz (unos 10 minutos)"
            $state.Testing = $offset
            Save-TuneState $state
            $result = Test-Stability $Device $target $offset $ConfirmScale
            $state.Testing = $null
            if (-not $result.Failure) { break }
            if ($offset -eq 0) { throw "Ni sin offset pasa la confirmación ($($result.Failure)). Revisa el driver o la tarjeta." }
            Write-Warning "Falla ($($result.Failure)): se baja 15 MHz."
            $offset = [math]::Max(0, $offset - 15)
            $state.Best = $offset
            Save-TuneState $state
        }

        Write-Phase 'Resultado'
        $final = Measure-Point $Device $target $offset
        $config = [pscustomobject]@{
            MaxMHz = $target; OffsetMHz = $offset; PowerPct = 100
            Tuned = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Driver = $driver
        }
        Save-Config $config
        $report = Format-TuneReport $state.Baseline $state.BoostMHz $final $config (Get-HighestPass $state.Passed $state.Failed)
        $report | Set-Content -LiteralPath (Join-Path (Get-DataDir) 'tune-report.txt') -Encoding UTF8
        $report | ForEach-Object { Write-Host $_ }
        Remove-TuneState
        $done = $true
    } finally {
        if ($null -ne $state.Testing) { $state.Testing = $null; Save-TuneState $state }   # Ctrl+C o error, no cuelgue
        Close-Engine
        if (-not $done) { [void](Reset-Stock $Device) }
    }

    if ($Yes -or (Read-Host '¿Aplicarlo siempre al iniciar Windows? (s/n)') -match '^[sS]') {
        Install-Autostart
    } else {
        Write-Host 'Está aplicado hasta que reinicies. Para dejarlo fijo: .\uv4070.cmd install'
    }
}

function Format-TuneReport($Base, [double]$BoostMHz, $Final, $Config, [int]$Highest) {
    $pct = { param($new, $old) if ($old) { '{0:+0.0;-0.0;0.0} %' -f (100 * ($new - $old) / $old) } else { '' } }
    $baseEff = if ($Base.Watts) { 1000 * $Base.Tflops / $Base.Watts } else { 0 }
    $finalEff = if ($Final.Watts) { 1000 * $Final.Tflops / $Final.Watts } else { 0 }
    "Resultado de tune ($($Config.Tuned), driver $($Config.Driver))"
    ''
    '                    De serie      uv4070        Cambio'
    '  Reloj máximo      {0,6:F0} MHz  {1,6} MHz  {2}' -f $BoostMHz, $Config.MaxMHz, (& $pct $Config.MaxMHz $BoostMHz)
    '  Con el test de estrés (carga máxima):'
    '  Rendimiento       {0,6:N1} TF   {1,6:N1} TF   {2}' -f $Base.Tflops, $Final.Tflops, (& $pct $Final.Tflops $Base.Tflops)
    '  1 % low           {0,6:N1} TF   {1,6:N1} TF   {2}' -f $Base.LowTflops, $Final.LowTflops, (& $pct $Final.LowTflops $Base.LowTflops)
    '  Consumo           {0,6:N0} W    {1,6:N0} W    {2}' -f $Base.Watts, $Final.Watts, (& $pct $Final.Watts $Base.Watts)
    '  Temperatura       {0,6} °C   {1,6} °C   {2:+0;-0;0} °C' -f $Base.MaxTempC, $Final.MaxTempC, ([int]$Final.MaxTempC - [int]$Base.MaxTempC)
    '  Eficiencia        {0,6:N0} GF/W {1,6:N0} GF/W {2}' -f $baseEff, $finalEff, (& $pct $finalEff $baseEff)
    ''
    "Configuración: tope $($Config.MaxMHz) MHz, offset +$($Config.OffsetMHz) MHz " +
        "(máximo estable +$Highest MHz, margen $($Highest - $Config.OffsetMHz) MHz)."
    'En juegos que no llegan al límite de potencia el reloj baja como mucho lo que indica "Reloj máximo".'
    'En los que sí llegan, como este test, el rendimiento se mantiene o sube y los 1 % low mejoran'
    'porque el reloj ya no oscila.'
}

function Invoke-StressTest($Device, $Config, [int]$Minutes) {
    $cap = 0; $offset = 0; $what = 'de serie'
    if ($null -ne $Config.MaxMHz) {
        $cap = $Config.MaxMHz; $offset = $Config.OffsetMHz
        $what = "tope $cap MHz, offset +$offset MHz"
    }
    Write-Host "Test de estrés de $Minutes min ($what). Ctrl+C para pararlo."
    # Cada ciclo de Test-Stability con $Scale = 1 dura unos 80 s.
    $result = $null
    try {
        $result = Test-Stability $Device $cap $offset ($Minutes * 60 / 80)
    } finally {
        Close-Engine
        if ($cap -gt 0) { Invoke-Apply $Device $Config } else { [void](Reset-Stock $Device) }
    }
    if ($result.Failure) {
        throw "INESTABLE: $($result.Failure). Baja el offset 15 MHz (apply -OffsetMHz $([math]::Max(0, $offset - 15))) o ejecuta tune."
    }
    $s = $result.Steady
    Write-Host ('ESTABLE: {0} min sin errores. {1:N1} TFLOPS, {2:N0} W, {3} °C como máximo.' -f $Minutes, $s.Tflops, $s.Watts, $s.MaxTempC) -ForegroundColor Green
}

# ---------------------------------------------------------------------------

function Show-Status($Device) {
    $core = Read-Nvml { param($out) [Uv4070.Nvml]::GetClock($Device, 0, $out) }
    $mem = Read-Nvml { param($out) [Uv4070.Nvml]::GetClock($Device, 2, $out) }
    $temp = Read-Nvml { param($out) [Uv4070.Nvml]::GetTemperature($Device, 0, $out) }
    $usage = Read-Nvml { param($out) [Uv4070.Nvml]::GetPowerUsage($Device, $out) }
    $limit = Read-Nvml { param($out) [Uv4070.Nvml]::GetPowerLimit($Device, $out) }
    $default = Read-Nvml { param($out) [Uv4070.Nvml]::GetDefaultPowerLimit($Device, $out) }
    $offset = Get-CoreOffset $Device

    Write-Host "GPU:          $GpuName (driver $(Get-DriverVersion))"
    Write-Host "Reloj:        núcleo $core MHz, memoria $mem MHz"
    Write-Host ('Offset:       {0}' -f $(if ($offset) { '{0:+0;-0;0} MHz' -f $offset.MHz } else { 'n/d' }))
    Write-Host 'Tope:         NVML no deja leerlo; con "monitor" en un juego se ve dónde se queda el reloj.'
    Write-Host ('Consumo:      {0:N1} W, límite {1:N0} W (fábrica {2:N0} W)' -f ($usage / 1000), ($limit / 1000), ($default / 1000))
    Write-Host "Temperatura:  $temp °C"
    $config = Read-Config
    $saved = if ($config) { "tope $($config.MaxMHz) MHz, offset +$($config.OffsetMHz) MHz, potencia $($config.PowerPct) %" } else { 'ninguna (usa "tune")' }
    Write-Host "Guardada:     $saved"
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $auto = if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { 'sí' } else { 'no (usa "install")' }
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

function Install-Autostart {
    # La tarea corre como SYSTEM, así que el script se copia a Program Files,
    # donde solo un administrador puede modificarlo, junto a config.json.
    $dir = Get-DataDir
    $target = Join-Path $dir 'uv4070.ps1'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ($PSCommandPath -ne $target) { Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force }

    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" apply -Unattended' -f $target
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
    Write-Host "Se aplicará solo al iniciar sesión y al volver de suspensión. Registro: $dir\uv4070.log"
}

function Uninstall-Autostart {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    $dir = Get-DataDir
    foreach ($file in 'uv4070.ps1', 'uv4070.log') {
        $path = Join-Path $dir $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Write-Host "Arranque automático eliminado. La configuración sigue en $dir\config.json."
}

# Al cargarlo con ". .\uv4070.ps1" solo se definen las funciones (lo usan las pruebas).
if ($MyInvocation.InvocationName -eq '.') { return }

$script:NvmlOpen = $false
$exitCode = 0
if ($Unattended) {
    $logDir = Get-DataDir
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Start-Transcript -Path (Join-Path $logDir 'uv4070.log') -Force | Out-Null
}
try {
    if ($Command -notin 'status', 'monitor') { Assert-Admin }
    # Antes de abrir la GPU, para que funcione aunque ya no haya una 4070.
    if ($Command -eq 'uninstall') { Uninstall-Autostart }

    $device = Open-Rtx4070 $Unattended.IsPresent
    switch ($Command) {
        'status'  { Show-Status $device }
        'monitor' { Show-Monitor $device $Samples }
        'tune' {
            Write-AfterburnerWarning
            Invoke-Tune $device
        }
        'stress' {
            Write-AfterburnerWarning
            Invoke-StressTest $device (Resolve-Config $false) $Minutes
        }
        'apply' {
            Write-AfterburnerWarning
            Invoke-Apply $device (Resolve-Config $true)
        }
        'install' {
            $config = Resolve-Config $true
            Invoke-Apply $device $config
            Save-Config $config
            Install-Autostart
        }
        { $_ -in 'reset', 'uninstall' } {
            if (-not (Reset-Stock $device)) { throw 'No se pudo restaurar todo; reinicia el PC para volver a fábrica.' }
            Write-Host 'Valores de fábrica restaurados.'
        }
    }
} catch {
    # El mensaje útil de una excepción .NET va en la más interna.
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    Write-Host ('ERROR: ' + $e.Message) -ForegroundColor Red
    $exitCode = 1
} finally {
    Close-Engine
    if ($script:NvmlOpen) { [void][Uv4070.Nvml]::Shutdown() }
    if ($Unattended) { Stop-Transcript | Out-Null }
}
exit $exitCode
