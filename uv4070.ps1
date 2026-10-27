<#
.SYNOPSIS
    Undervolt automático para la NVIDIA GeForce RTX 4070, sin MSI Afterburner.

.DESCRIPTION
    "tune" encuentra solo la configuración para tu tarjeta y la guarda: la que
    menos consume perdiendo como mucho un 1 % de reloj (-MaxLossPct). Mide la
    tarjeta de serie, pone el tope, baja la tensión hasta el límite estable de
    tu chip con un test de estrés propio, deja un margen de seguridad
    (-MarginMHz, 30 por defecto) y lo confirma con unos 10 minutos más de estrés.

    La estabilidad se comprueba con dos tests propios: uno de cálculo (DirectX 11)
    y otro de ray tracing (DirectX 12), y en cada uno se comparan los resultados
    con una referencia calculada a 1500 MHz y sin offset.

    El undervolt se hace con NVML (nvml.dll, la librería oficial del driver de
    NVIDIA): un tope al reloj del núcleo y un offset que sube toda la curva
    tensión/frecuencia. La GPU llega al tope con menos tensión que de serie y
    no sube más. Es lo mismo que "subir la curva y aplanarla" en Afterburner,
    sin dejar nada en segundo plano.

    Comandos:
      status     Estado actual y configuración guardada (por defecto).
      tune       Busca la configuración ideal (unos 30 minutos) y la guarda.
      stress     Test de estrés de la configuración guardada (-Minutes, 10 por defecto).
      apply      Aplica la configuración guardada, o la de -MaxMHz y -OffsetMHz.
      reset      Vuelve a valores de fábrica.
      monitor    Reloj, consumo y temperatura cada segundo (Ctrl+C para salir).
      install    Aplica la configuración en cada inicio de sesión y al volver de suspensión.
      uninstall  Quita el arranque automático y vuelve a valores de fábrica.
      selftest   Comprueba en este PC el driver, DirectX y Windows (unos 2 minutos).
      report     Junta estado, último tune y registros en un JSON para revisarlo (también con una IA).

    Cada comando que cambia algo deja un registro JSON Lines en
    C:\Program Files\uv4070\logs: una línea por evento, con claves en inglés.

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
    [ValidateSet('status', 'tune', 'stress', 'apply', 'reset', 'monitor', 'install', 'uninstall', 'selftest', 'report')]
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
    # de consumir menos. Más = más ahorro; 0 = todo el rendimiento.
    [ValidateRange(0, 15)]
    [int]$MaxLossPct = 1,

    # Solo para tune: margen bajo el último offset estable. 45 si juegas mucho con
    # ray tracing y no quieres iterar.
    [ValidateSet(0, 15, 30, 45, 60, 75, 90)]
    [int]$MarginMHz = 30,

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

$ScriptVersion = '2026.10.27'
$GpuName = 'NVIDIA GeForce RTX 4070'
$TaskName = 'uv4070'
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
$Bound = $PSBoundParameters

# Ajuste automático (tune). Los relojes van en múltiplos de 15 MHz, el paso de Ada.
$OffsetStep = 30       # búsqueda gruesa; después afina en pasos de 15
$ConfirmScale = 7      # la confirmación dura 7 rondas de búsqueda (unos 10 minutos)
$WarmupSeconds = 60
$SafeMHz = 1500        # reloj al que se calcula la referencia del test de estrés
$TestScale = 1         # multiplica la duración de todas las cargas (las pruebas automáticas lo reducen)

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
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlSystemGetNVMLVersion", CharSet = CharSet.Ansi)]
        public static extern int GetNvmlVersion(StringBuilder version, uint length);
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
        // El límite configurado: el "en vigor" (GetPowerLimit) tarda en reflejar una escritura.
        [DllImport(Dll, CallingConvention = C, EntryPoint = "nvmlDeviceGetPowerManagementLimit")]
        public static extern int GetPowerManagementLimit(IntPtr device, out uint milliwatts);
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

        // Las dos API de offset por separado: la moderna (driver R555+), por
        // P-state, y la anterior, global. selftest las prueba una a una.
        public static int GetOffsetModern(IntPtr device, out int mhz, out int minMHz, out int maxMHz) {
            mhz = 0; minMHz = 0; maxMHz = 0;
            try {
                ClockOffset o = GraphicsP0();
                int rc = nvmlDeviceGetClockOffsets(device, ref o);
                if (rc == Success) { mhz = o.OffsetMHz; minMHz = o.MinOffsetMHz; maxMHz = o.MaxOffsetMHz; }
                return rc;
            } catch (EntryPointNotFoundException) { return Missing; }
        }

        public static int SetOffsetModern(IntPtr device, int mhz) {
            try {
                ClockOffset o = GraphicsP0();
                o.OffsetMHz = mhz;
                return nvmlDeviceSetClockOffsets(device, ref o);
            } catch (EntryPointNotFoundException) { return Missing; }
        }

        // minMHz y maxMHz quedan a 0 si el driver no informa del rango.
        public static int GetOffsetLegacy(IntPtr device, out int mhz, out int minMHz, out int maxMHz) {
            mhz = 0; minMHz = 0; maxMHz = 0;
            int rc;
            try { rc = nvmlDeviceGetGpcClkVfOffset(device, out mhz); } catch (EntryPointNotFoundException) { return Missing; }
            if (rc != Success) return rc;
            try {
                if (nvmlDeviceGetGpcClkMinMaxVfOffset(device, out minMHz, out maxMHz) != Success) { minMHz = 0; maxMHz = 0; }
            } catch (EntryPointNotFoundException) { }
            return Success;
        }

        public static int SetOffsetLegacy(IntPtr device, int mhz) {
            try { return nvmlDeviceSetGpcClkVfOffset(device, mhz); } catch (EntryPointNotFoundException) { return Missing; }
        }

        // La API moderna y, si no está o falla, la anterior.
        public static int SetGraphicsOffset(IntPtr device, int mhz) {
            int rc = SetOffsetModern(device, mhz);
            if (rc == Success) return rc;
            int legacy = SetOffsetLegacy(device, mhz);
            return legacy == Missing ? rc : legacy;
        }

        public static int GetGraphicsOffset(IntPtr device, out int mhz, out int minMHz, out int maxMHz) {
            if (GetOffsetModern(device, out mhz, out minMHz, out maxMHz) == Success) return Success;
            return GetOffsetLegacy(device, out mhz, out minMHz, out maxMHz);
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

    // Utilidades COM sin librerías externas: las interfaces se llaman por su
    // posición en la tabla virtual.
    static class Com {
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint ReleaseFn(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int EnumAdapters1Fn(IntPtr self, uint index, out IntPtr adapter);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetDesc1Fn(IntPtr self, out AdapterDesc1 desc);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct AdapterDesc1 {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
            public uint VendorId, DeviceId, SubSysId, Revision;
            public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
            public uint LuidLow;
            public int LuidHigh;
            public uint Flags;
        }

        [DllImport("dxgi.dll")]
        static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr factory);

        public static T Fn<T>(IntPtr obj, int index) where T : class {
            IntPtr method = Marshal.ReadIntPtr(Marshal.ReadIntPtr(obj), index * IntPtr.Size);
            return (T)(object)Marshal.GetDelegateForFunctionPointer(method, typeof(T));
        }

        public static void Release(ref IntPtr obj) {
            if (obj == IntPtr.Zero) return;
            Fn<ReleaseFn>(obj, 2)(obj);
            obj = IntPtr.Zero;
        }

        public static void Check(int hr, string what) {
            if (hr < 0) throw new InvalidOperationException(what + " ha fallado (0x" + hr.ToString("X8") + ")");
        }

        // El adaptador DXGI con ese nombre exacto (el llamador lo libera).
        public static IntPtr FindAdapter(string name) {
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
    }

    // Lo común a los dos tests: calibración, referencia, el bucle de carga con
    // lotes en vuelo, la detección de errores y las lecturas NVML. Cada motor
    // pone los dispatches y la lectura del contador de errores.
    public abstract class Engine : IDisposable {
        // Modos de Run: carga máxima sostenida; 2 s de carga y 0,7 s de reposo
        // (cambios bruscos de carga y tensión); y carga ligera: ráfagas de carga
        // máxima con un goteo de trabajo entre ellas, para que la GPU siga ocupada
        // (si se queda vacía el driver sale de P0) pero consuma poco y suba a su
        // reloj máximo sin tocar el límite de potencia, como en un juego.
        public const int Steady = 0, Pulses = 1, Light = 2;
        public const uint MaxIterations = 1u << 22;
        const double BatchMs = 50;
        const string LostMessage = "el driver se ha reiniciado";

        public uint Iterations { get; set; }
        public double DispatchMs { get; private set; }
        // Tras un reinicio del driver el dispositivo ya no sirve: hay que abrir otro.
        public bool Lost { get; protected set; }

        public abstract uint ThreadCount { get; }
        protected abstract int Slots { get; }                 // lotes en vuelo
        protected abstract double FlopsPerIteration { get; }  // por hilo; 0 si no procede
        protected virtual uint FirstIterations { get { return 256; } }
        protected virtual uint MinIterations { get { return 64; } }
        protected abstract void SetParams(uint iterations, uint verify);
        protected abstract void ClearErrors();
        // Encola perBatch dispatches y la copia del contador de errores al slot.
        // Con light, además el goteo de trabajo que sigue a la ráfaga.
        protected abstract void Submit(int slot, int perBatch, bool light);
        // Ajusta el goteo de la carga ligera, si el motor lo tiene.
        protected virtual void CalibrateLight(double targetMs) { }
        // Espera al lote del slot y lee su contador; false si el dispositivo se ha perdido.
        protected abstract bool ReadErrors(int slot, out long count);
        protected abstract void ReleaseAll(bool wasLost);

        double TimeDispatch() {
            Stopwatch sw = Stopwatch.StartNew();
            Submit(0, 1, false);
            long ignored;
            if (!ReadErrors(0, out ignored)) throw new InvalidOperationException("El driver se ha reiniciado durante la calibración.");
            return sw.Elapsed.TotalMilliseconds;
        }

        // Elige las iteraciones para que cada dispatch dure unos targetMs: lo
        // bastante corto para que Windows no lo tome por un cuelgue (2 s).
        public void Calibrate(double targetMs) {
            SetParams(FirstIterations, 0);
            for (int i = 0; i < 5; i++) TimeDispatch();
            uint iterations = FirstIterations;
            for (;;) {
                SetParams(iterations, 0);
                double ms = double.MaxValue;
                for (int i = 0; i < 3; i++) ms = Math.Min(ms, TimeDispatch());
                if (ms >= targetMs / 4 || iterations >= MaxIterations) {
                    double scaled = iterations * targetMs / Math.Max(ms, 0.001);
                    Iterations = (uint)Math.Max(MinIterations, Math.Min(MaxIterations, scaled));
                    DispatchMs = ms * Iterations / iterations;
                    CalibrateLight(targetMs);
                    return;
                }
                iterations *= 4;
            }
        }

        // Calcula los hashes de referencia y comprueba que se repiten.
        public void CaptureReference() {
            SetParams(Iterations, 0);
            Submit(0, 1, false);
            long ignored;
            if (!ReadErrors(0, out ignored)) throw new InvalidOperationException("El driver se ha reiniciado al preparar el test.");
            ClearErrors();
            SetParams(Iterations, 1);
            Submit(0, 3, false);
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
            int depth = mode == Light ? 1 : Slots;
            double flops = (double)ThreadCount * Iterations * FlopsPerIteration * perBatch;
            List<double> tflops = new List<double>();
            List<int> queue = new List<int>();  // lotes en vuelo, el más antiguo primero
            Sampler sampler = new Sampler(nvmlDevice);
            Stopwatch total = Stopwatch.StartNew(), burst = Stopwatch.StartNew();
            double lastDone = 0;
            bool skip = true;  // el primer lote incluye el arranque desde reposo
            int next = 0;
            while (r.Failure == null && total.Elapsed.TotalSeconds < seconds) {
                // Varios lotes en vuelo para que la GPU no espere a la CPU.
                while (queue.Count < depth) {
                    Submit(next, perBatch, mode == Light);
                    queue.Add(next);
                    next = (next + 1) % Slots;
                }
                if (!Complete(Dequeue(queue), r)) break;
                double now = total.Elapsed.TotalMilliseconds;
                if (!skip && flops > 0) tflops.Add(flops / ((now - lastDone) / 1000) / 1e12);
                lastDone = now;
                skip = false;
                r.Batches++;
                sampler.Sample();
                if (mode == Light) skip = true;  // el lote lleva el goteo: el rendimiento no es comparable
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

        // Después de Dispose el motor cuenta como perdido: Run devuelve un fallo en vez de
        // usar punteros ya liberados.
        public void Dispose() {
            bool wasLost = Lost;
            Lost = true;
            ReleaseAll(wasLost);
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

    // Test de cálculo en DirectX 11 (compute shader): carga todas las unidades FP32.
    public sealed class Stress : Engine {
        public new const int Steady = Engine.Steady, Pulses = Engine.Pulses, Light = Engine.Light;
        public const uint Groups = 4096;
        public const uint Threads = Groups * 256;

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
    else if (Verify == 1) { if (Reference[id.x] != h) InterlockedAdd(Errors[0], 1); }
    else if (h == 0x9e3779b9u) InterlockedAdd(Errors[1], 1);  // relleno: solo evita que se elimine el cálculo
}";

        // Goteo de la carga ligera: unos pocos grupos (pocos SM) entre ráfaga y ráfaga.
        const uint TrickleGroups = 4;
        uint trickleIterations = 64;
        int trickleCount = 1;

        [StructLayout(LayoutKind.Sequential)]
        struct BufferDesc { public uint ByteWidth, Usage, BindFlags, CpuAccessFlags, MiscFlags, StructureByteStride; }
        [StructLayout(LayoutKind.Sequential)]
        struct UavDesc { public uint Format, ViewDimension, FirstElement, NumElements, Flags; }
        [StructLayout(LayoutKind.Sequential)]
        struct Mapped { public IntPtr Data; public uint RowPitch, DepthPitch; }

        const uint UsageStaging = 3, BindConstantBuffer = 0x4, BindUnorderedAccess = 0x80;
        const uint CpuAccessRead = 0x20000, MiscStructured = 0x40;

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

        public override uint ThreadCount { get { return Threads; } }
        protected override int Slots { get { return staging.Length; } }
        protected override double FlopsPerIteration { get { return 16; } }

        Stress() { }

        public static Stress Open(string adapterName) {
            Stress s = new Stress();
            try { s.Create(adapterName); } catch { s.Dispose(); throw; }
            return s;
        }

        void Create(string adapterName) {
            IntPtr adapter = Com.FindAdapter(adapterName);
            try {
                uint level;
                // Driver UNKNOWN (0) porque se indica el adaptador; nivel 11_0; SDK 7.
                Com.Check(D3D11CreateDevice(adapter, 0, IntPtr.Zero, 0, new uint[] { 0xb000 }, 1, 7,
                    out device, out level, out context), "D3D11CreateDevice");
            } finally {
                Com.Release(ref adapter);
            }
            map = Com.Fn<MapFn>(context, 14);
            unmap = Com.Fn<UnmapFn>(context, 15);
            dispatch = Com.Fn<DispatchFn>(context, 41);
            copyResource = Com.Fn<CopyResourceFn>(context, 47);
            updateSubresource = Com.Fn<UpdateSubresourceFn>(context, 48);
            clearUav = Com.Fn<ClearUavUintFn>(context, 51);
            flush = Com.Fn<ContextFn>(context, 111);
            removedReason = Com.Fn<GetDeviceRemovedReasonFn>(device, 39);

            shader = CompileShader();
            reference = CreateBuffer(Threads * 4, 0, BindUnorderedAccess, 0, MiscStructured, 4);
            referenceView = CreateView(reference, Threads);
            errors = CreateBuffer(16, 0, BindUnorderedAccess, 0, MiscStructured, 4);
            errorsView = CreateView(errors, 4);
            for (int i = 0; i < staging.Length; i++) staging[i] = CreateBuffer(16, UsageStaging, 0, CpuAccessRead, MiscStructured, 4);
            constants = CreateBuffer(16, 0, BindConstantBuffer, 0, 0, 0);

            Com.Fn<CsSetShaderFn>(context, 69)(context, shader, IntPtr.Zero, 0);
            Com.Fn<CsSetUavsFn>(context, 68)(context, 0, 2, new IntPtr[] { referenceView, errorsView }, new uint[] { uint.MaxValue, uint.MaxValue });
            Com.Fn<CsSetConstantBuffersFn>(context, 71)(context, 0, 1, new IntPtr[] { constants });
        }

        IntPtr CompileShader() {
            byte[] source = Encoding.ASCII.GetBytes(Shader);
            IntPtr code, messages;
            int hr = D3DCompile(source, (UIntPtr)(uint)source.Length, "uv4070", IntPtr.Zero, IntPtr.Zero,
                "main", "cs_5_0", 1u << 15 /* OPTIMIZATION_LEVEL3 */, 0, out code, out messages);
            string text = messages != IntPtr.Zero ? Marshal.PtrToStringAnsi(Com.Fn<BlobPointerFn>(messages, 3)(messages)) : "";
            Com.Release(ref messages);
            if (hr < 0) throw new InvalidOperationException("No se pudo compilar el test de estrés: " + text);
            try {
                IntPtr cs;
                Com.Check(Com.Fn<CreateComputeShaderFn>(device, 18)(device, Com.Fn<BlobPointerFn>(code, 3)(code),
                    Com.Fn<BlobSizeFn>(code, 4)(code), IntPtr.Zero, out cs), "CreateComputeShader");
                return cs;
            } finally {
                Com.Release(ref code);
            }
        }

        IntPtr CreateBuffer(uint size, uint usage, uint bind, uint cpu, uint misc, uint stride) {
            BufferDesc d = new BufferDesc();
            d.ByteWidth = size; d.Usage = usage; d.BindFlags = bind;
            d.CpuAccessFlags = cpu; d.MiscFlags = misc; d.StructureByteStride = stride;
            IntPtr buffer;
            Com.Check(Com.Fn<CreateBufferFn>(device, 3)(device, ref d, IntPtr.Zero, out buffer), "CreateBuffer");
            return buffer;
        }

        IntPtr CreateView(IntPtr buffer, uint elements) {
            UavDesc d = new UavDesc();
            d.ViewDimension = 1;  // D3D11_UAV_DIMENSION_BUFFER; formato UNKNOWN por ser estructurado
            d.NumElements = elements;
            IntPtr view;
            Com.Check(Com.Fn<CreateUavFn>(device, 8)(device, buffer, ref d, out view), "CreateUnorderedAccessView");
            return view;
        }

        protected override void SetParams(uint iterations, uint verify) {
            updateSubresource(context, constants, 0, IntPtr.Zero, new uint[] { iterations, verify, 0, 0 }, 0, 0);
        }

        protected override void ClearErrors() {
            clearUav(context, errorsView, new uint[4]);
        }

        protected override void Submit(int slot, int perBatch, bool light) {
            for (int i = 0; i < perBatch; i++) dispatch(context, Groups, 1, 1);
            if (light) {
                SetParams(trickleIterations, 2);
                for (int i = 0; i < trickleCount; i++) dispatch(context, TrickleGroups, 1, 1);
                SetParams(Iterations, 1);
            }
            copyResource(context, staging[slot], errors);
            flush(context);
        }

        // El goteo dura unas 3 veces la ráfaga: la GPU está ocupada todo el tiempo
        // pero a un cuarto de su consumo. Se mide con un bloque solo en un SM.
        protected override void CalibrateLight(double targetMs) {
            uint probe = Math.Min(MaxIterations, Iterations * 16);
            SetParams(probe, 2);
            double ms = double.MaxValue;
            for (int i = 0; i < 3; i++) {
                Stopwatch sw = Stopwatch.StartNew();
                dispatch(context, TrickleGroups, 1, 1);
                copyResource(context, staging[0], errors);
                flush(context);
                long ignored;
                if (!ReadErrors(0, out ignored)) throw new InvalidOperationException("El driver se ha reiniciado durante la calibración.");
                ms = Math.Min(ms, sw.Elapsed.TotalMilliseconds);
            }
            double needed = probe * 3 * targetMs / Math.Max(ms, 0.001);
            trickleIterations = (uint)Math.Max(64, Math.Min(MaxIterations, needed));
            trickleCount = (int)Math.Max(1, Math.Ceiling(needed / trickleIterations));
            SetParams(Iterations, 0);
        }

        // Espera a que la GPU termine el lote que copió su contador en staging[slot].
        protected override bool ReadErrors(int slot, out long count) {
            count = 0;
            Mapped m;
            if (map(context, staging[slot], 0, 1 /* MAP_READ */, 0, out m) < 0) { Lost = true; return false; }
            count = (uint)Marshal.ReadInt32(m.Data);
            unmap(context, staging[slot], 0);
            if (removedReason(device) < 0) { Lost = true; return false; }
            return true;
        }

        protected override void ReleaseAll(bool wasLost) {
            if (context != IntPtr.Zero && !wasLost) Com.Fn<ContextFn>(context, 110)(context);  // ClearState
            Com.Release(ref constants);
            for (int i = 0; i < staging.Length; i++) Com.Release(ref staging[i]);
            Com.Release(ref errorsView);
            Com.Release(ref errors);
            Com.Release(ref referenceView);
            Com.Release(ref reference);
            Com.Release(ref shader);
            Com.Release(ref context);
            Com.Release(ref device);
        }
    }

    // Test de ray tracing en DirectX 12 (RayQuery, DXR 1.1): cada hilo lanza rayos
    // dependientes contra una nube de triángulos y resume los impactos (primitiva y
    // distancia) en un hash, comparado con la referencia como en el test de cálculo.
    // Carga los núcleos RT, que consumen con otro patrón que los de cálculo.
    public sealed class RtStress : Engine {
        public const uint Groups = 1024;
        public const uint Threads = Groups * 64;
        const uint TriangleCount = 32768;

        // HLSL (cs_6_5). El compilador que trae Windows no genera shader model 6, así
        // que se compila una vez con dxc (tests/build-rt-shader.ps1) y el DXIL va
        // embebido más abajo. Si cambias el HLSL, vuelve a ejecutar ese script.
        // RT-HLSL-BEGIN
        public const string Shader = @"
#define RS ""RootConstants(num32BitConstants=4, b0), SRV(t0), UAV(u0), UAV(u1)""
cbuffer Params : register(b0) { uint Iterations; uint Verify; uint2 Unused; };
RaytracingAccelerationStructure Scene : register(t0);
RWStructuredBuffer<uint> Reference : register(u0);
RWStructuredBuffer<uint> Errors : register(u1);

float Next(inout uint seed)
{
    seed = seed * 1664525u + 1013904223u;
    return (seed >> 8) * (2.0 / 16777216.0) - 1.0;
}

[RootSignature(RS)]
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint seed = id.x * 2654435761u + 12345u;
    uint h = seed;
    float3 origin = float3(0, 0, -3);
    float3 dir = normalize(float3(Next(seed), Next(seed), 2.0));
    [loop] for (uint i = 0; i < Iterations; i++) {
        RayDesc ray;
        ray.Origin = origin;
        ray.Direction = dir;
        ray.TMin = 0.001;
        ray.TMax = 100.0;
        RayQuery<RAY_FLAG_FORCE_OPAQUE> q;
        q.TraceRayInline(Scene, RAY_FLAG_NONE, 0xFF, ray);
        q.Proceed();
        if (q.CommittedStatus() == COMMITTED_TRIANGLE_HIT) {
            float t = q.CommittedRayT();
            h = (h ^ q.CommittedPrimitiveIndex()) * 16777619u;
            h = (h ^ asuint(t)) * 16777619u;
            // Rebota en una dirección que depende del impacto: el siguiente rayo
            // solo es correcto si este lo fue.
            origin = origin + dir * t;
            seed ^= h;
            dir = normalize(float3(Next(seed), Next(seed), Next(seed)));
        } else {
            h = (h ^ 0x9e3779b9u) * 16777619u;
            origin = float3(0, 0, -3);
            dir = normalize(float3(Next(seed), Next(seed), 2.0));
        }
    }
    if (Verify == 0) Reference[id.x] = h;
    else if (Reference[id.x] != h) InterlockedAdd(Errors[0], 1);
}";
        // RT-HLSL-END

        // RT-DXIL-BEGIN: DXIL del shader en base64 y hash SHA-256 del HLSL con el que se generó
        const string ShaderHash = "60a1abc17ca6005c5a2a6909e5bdcfd095d4eb3e9d617ac90c86ad03c75faead";
        const string Dxil =
            "RFhCQ13i1WuxdEcPB1nLH2jnT1IBAAAAmBQAAAgAAABAAAAAUAAAAGAAAABwAAAAKAEAAKgBAAAI" +
            "CgAAJAoAAFNGSTAIAAAAAAAQAAAAAABJU0cxCAAAAAAAAAAIAAAAT1NHMQgAAAAAAAAACAAAAFBT" +
            "VjCwAAAANAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/////wUAAAAAAAAAAAAAAEAAAAABAAAAAQAA" +
            "AAEAAAAEAAAAGAAAAAIAAAAAAAAAAAAAAAAAAAANAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAQAAAA" +
            "AAAAAAgAAAAAAAAAAAAAAAAAAAAMAAAAAAAAAAgAAAAAAAAAAQAAAAEAAAAMAAAAAAAAAAgAAAAA" +
            "bWFpbgAAAAAAAABSVFMweAAAAAIAAAAEAAAAGAAAAAAAAAB4AAAAAAAAAAEAAAAAAAAASAAAAAMA" +
            "AAAAAAAAVAAAAAQAAAAAAAAAYAAAAAQAAAAAAAAAbAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAA" +
            "AAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAFNUQVRYCAAAZQAFABYCAABEWElMBQEAABAAAABACAAA" +
            "QkPA3iEMAAANAgAAC4IgAAIAAAATAAAAB4EjkUHIBEkGEDI5kgGEDCUFCBkeBItigBhFAkKSC0LE" +
            "EDIUOAgYSwoyYohIkBQgQ0aIpQAZMkLkSA6QESPEUEFRgYzhg+WKBDFGBlEYAAAIAAAAG4zg////" +
            "/wdAAqgNhPD/////AyBtMIb/////HwAJqABJGAAAAwAAABOCYEIgTAgGAAAAAIkgAABMAAAAMiKI" +
            "CSBkhQQTI6SEBBMj44ShkBQSTIyMC4TETBCowQhACQAK5gjAoAzDMBAxA1AQYzAMwzAMOspgDAYl" +
            "cwQILfcMlz9hDyH5IdAMC4ECpizA0AzDMAzDMpBz03D5E/YQkr8S0kpMPnLbqBiGYRjKAQ3NMCwD" +
            "RQUZhmYYhmGg6ajh8ifsISSf26hiJSYfuW1EDMMwFKIamoGs4gDD0AyDYRiGYRgGYWUwhoG0OYKg" +
            "DNwwUFeMZliGgaNvIODMQJoiSpj8FcCmCBCQxtAEgViICJgQp2GniBImKiJQMJA4kxmMAzuEwzzM" +
            "gxvIwi3MAj3IQz2MAz3UgzyUAzmIQj2YgzmUgzzwQT24wzykwzm4QzmQAxikgzvQgx+gYCByGEEY" +
            "zkiBCGAkNAyDSeccASgAABMUcsCHdGCHNmiHeWgDcsCHDa9QDm3QDnpQDm0AD3owB3KgB3MgB22Q" +
            "DnGgB3MgB22QDnigB3MgB22QDnFgB3owB3LQBukwB3KgB3MgB22QDnZAB3pgB3TQBuYQB3agB3Mg" +
            "B21gDnMgB3owB3LQBuZgB3SgB3ZAB23gDnigB3FgB3owB3KgB3ZAB0OeAAgAAAAAAAAAAACGPAQQ" +
            "AAEAAAAAAAAADHkOIAACAAAAAAAAABjyJEAABAAAAAAAAAAw5HGAABAAAAAAAAAAYMgTAQEwAAAA" +
            "AAAAAMCQZwICQAAAAAAAAACAIY8FBMAAAAAAAAAAAEMeAggAAQAAAAAAAACGPBgQAAIAAAAAAAAA" +
            "DHkIIAAGAAAAAAAAABjyaEAADAAAAAAAAAAw5OmAABAAAAAAAAAAYMjzAQEwAAAAAAAAAEAWCBMA" +
            "AAAyHpgYGRFMkIwJJkfGBEMaSqAURgCKoUAKoTDKoBxmAEqiIEqjCAowoHxKPaBkiBsBqAFKCxQQ" +
            "EITIGQAqZwDonAEgdAaAxhkAAAAAeRgAAJgAAAAaA0yQRgITRI8Mb+ztTQwkxiXHRcYGRsYl5gYE" +
            "RSaGTAbH7EbmJmVDEEwQBmeCMDwbhIGYIAzQBsEwKIzNTRCGaMOAJMQEYQzOgMXUWJlb2QRhkCYI" +
            "w7RBMJwNibEwhjE0xrMhgCYIZUAGTKTKzMrkytzGyiYIAzVB4MBggzA4GxZDmgxjoKqqsmgUycm9" +
            "yc1tWAYJM4aBqqrK2iBc2QQBDcyABlSYXFjb3AbE2DjDGBpgQ9BtICLNAyYIZDAGDNAmCEM1QRis" +
            "DUYSBmJgjAExQRiuDYJRBhsCM9ggGGewYXDIAA0mCGdQBlSS6MrkwujS3tzmJggDNkHgwmADkqyB" +
            "GBhjQLBBG9CwKpNLM8vbgCRvIAbOGBBs0AY0qtzq5srIJghDNkEYtAnCsG1AkjgQAzkYA2IO6GAD" +
            "0bgBHNTBhsIAgzRQAzuYIAjABmDDYORBHmwI9GDDMODBHpBoC0tzmyCkgRhMEAZuw/AHw7CBMPzA" +
            "AYUNBR70AfCFAo0wure2tDEiYnJhbmNoZXM0zNjewujmJghDxyLNbY5uboIweCTS3OjmJgjDR4Su" +
            "DO+L7S2MjAldGd7XHN2bXBmLujQ3urkN0CgMpECUgimcAiqkgiqswsAKQyuwQRU2Nrs2lzSyMje6" +
            "KUFQhQzPxa5Mbi7tzW1KQDQhw3OxC2OzK5ObEhh1yPBc5tDCyMrkmt7IytimBEkZMjwXubK5tzq5" +
            "sbK5KYFXiQzPhS4PrizIze2NLowu7c1tbopgB3tQhwzPpcyNTi4P6i3NjW5uShAKXcjwXMbe6tzo" +
            "yuTmpgStAAAAAHkYAABVAAAAMwiAHMThHGYUAT2IQziEw4xCgAd5eAdzmHEM5gAP7RAO9IAOMwxC" +
            "HsLBHc6hHGYwBT2IQziEgxvMAz3IQz2MAz3MeIx0cAd7CAd5SIdwcAd6cAN2eIdwIIcZzBEO7JAO" +
            "4TAPbjAP4/AO8FAOMxDEHd4hHNghHcJhHmYwiTu8gzvQQzm0Azy8gzyEAzvM8BR2YAd7aAc3aIdy" +
            "aAc3gIdwkIdwYAd2KAd2+AV2eId3gIdfCIdxGIdymId5mIEs7vAO7uAO9cAO7DADYsihHOShHMyh" +
            "HOShHNxhHMohHMSBHcphBtaQQznIQzmYQznIQzm4wziUQziIAzuUwy+8gzz8gjvUAzuwwwzEIQd8" +
            "cAN6KId2gIcZysMO7GAP7eAG7PAO7wAPMyKIHPDBDchBHM7BDewhHOSBHcIhH96hHuhhBhORAz64" +
            "gTjIQzmEwzq4gTjIAwAAAHEgAABBAAAAhmANl+88PrAsjgBMxApgKkVEmBlUw+U7jw9MDoMIG9Kg" +
            "j4/cth1sw+U7jy8EVFEQUekAQ0kYgID5yG1bgzRcvvP4QkQAExECzbAQJuAMl+88/uBMt1/cthVc" +
            "w+U7jx8B1kYVBRGVDjD4yG0bATZcvvP4EWBtVFEQETs5EeEjt20M2XD5zuNHAKZSRIT9aeQIBDH4" +
            "SG0L3nD5zuNHAKZSRIT97ARMBCsACxD5xW2bgjdcvvP4EYCpFBFhPzsBE8EKwAJEPnLbltANl+88" +
            "fgRgKkVE2N9GgECsACY2C9IQFiANl+88/nREBDCIg4/ctg08w+U7j081QIT5xW0bAMEASAMAAAAA" +
            "AAAASEFTSBQAAAAAAAAAaPcyOoLgfBkjOH5swxEHakRYSUxsCgAAZQAFAJsCAABEWElMBQEAABAA" +
            "AABUCgAAQkPA3iEMAACSAgAAC4IgAAIAAAATAAAAB4EjkUHIBEkGEDI5kgGEDCUFCBkeBItigBhF" +
            "AkKSC0LEEDIUOAgYSwoyYohIkBQgQ0aIpQAZMkLkSA6QESPEUEFRgYzhg+WKBDFGBlEYAAAIAAAA" +
            "G4zg/////wdAAqgNhPD/////AyBtMIb/////HwAJqABJGAAAAwAAABOCYEIgTAgGAAAAAIkgAABN" +
            "AAAAMiKICSBkhQQTI6SEBBMj44ShkBQSTIyMC4TETBCswQhACQAK5gjAoAzDMBAxA1AQYzAMwzAM" +
            "OspgDAYlcwQILfcMlz9hDyH5IdAMC4ECpizA0AzDMAzDMpBz03D5E/YQkr8S0kpMPnLbqBiGYRjK" +
            "AQ3NMCwDRQUZhmYYhmGg6ajh8ifsISSf26hiJSYfuW1EDMMwFKIamoGs4gDD0AyDYRiGYRgGYWUw" +
            "hoG0OYKgDNwwUFeMZliGgaNvIODMQJoiSpj8FcCmCBCQxtAEgViICJgQp2GniBImKiJQMJA4kxmM" +
            "AzuEwzzMgxvIwi3MAj3IQz2MAz3UgzyUAzmIQj2YgzmUgzzwQT24wzykwzm4QzmQAxikgzvQgx+g" +
            "YCByGEEYzkiBCGAkNAyDSeccAShMAQAAAAATFHLAh3RghzZoh3loA3LAhw2vUA5t0A56UA5tAA96" +
            "MAdyoAdzIAdtkA5xoAdzIAdtkA54oAdzIAdtkA5xYAd6MAdy0AbpMAdyoAdzIAdtkA52QAd6YAd0" +
            "0AbmEAd2oAdzIAdtYA5zIAd6MAdy0AbmYAd0oAd2QAdt4A54oAdxYAd6MAdyoAd2QAdDngAAAAAA" +
            "AAAAAAAAhjwEEAABAAAAAAAAAAx5DiAAAgAAAAAAAAAY8iRAAAQAAAAAAAAAMORxgAAQAAAAAAAA" +
            "AGDIEwEBMAAAAAAAAADAkGcCAkAAAAAAAAAAgCGPBQTAAAAAAAAAAABDHgIIAAEAAAAAAAAAhjwY" +
            "EAACAAAAAAAAAAx5CCAABgAAAAAAAAAY8mhAAAwAAAAAAAAAMOTpgAAQAAAAAAAAAGDI8wEBMAAA" +
            "AAAAAABAFggNAAAAMh6YFBkRTJCMCSZHxgRDGkqgFEqiGEYACqQQCqMAA4gbAaC0QAEBQaicASB0" +
            "BoDGGQAAAHkYAABPAAAAGgNMkEYCE0SPDG/s7U0MJMYlx0XGBkbGJeYGBEUmhkwGx+xG5iZlQxBM" +
            "EAZngjA8G4SBmCAM0AZhMCiMzU0QhmjDgCTEBGGQJghjsBGYIAzTBGGgNgjLsyFZmGZZBmeBNgTR" +
            "BKEMsgnCUE0QuGuDMDwblmVqlmWgqqqyNizD1CzDQFVVZW0QLmyCgAbaBmTRmmUZHGBDsG0gpIwD" +
            "JggCQKItLM1tgpAG2ARhsDYMYTAMG4gFDB4x2FB4H9CNATE2Nrs2F7a3NziXOje5NzY2F7K0uTAx" +
            "trINQRmsEM7ADKqwsdm1uaSRlbnRTQmCKmR4LnZlcnNpb25TAqIJGZ6LXRibXZnclMCoQ4bnMocW" +
            "RlYm1/RGVsY2JUjKkOG5yJXNvdXJjZXNTQm4OmR4LmVudHJ5UG9pbnRzU4IxAHkYAABVAAAAMwiA" +
            "HMThHGYUAT2IQziEw4xCgAd5eAdzmHEM5gAP7RAO9IAOMwxCHsLBHc6hHGYwBT2IQziEgxvMAz3I" +
            "Qz2MAz3MeIx0cAd7CAd5SIdwcAd6cAN2eIdwIIcZzBEO7JAO4TAPbjAP4/AO8FAOMxDEHd4hHNgh" +
            "HcJhHmYwiTu8gzvQQzm0Azy8gzyEAzvM8BR2YAd7aAc3aIdyaAc3gIdwkIdwYAd2KAd2+AV2eId3" +
            "gIdfCIdxGIdymId5mIEs7vAO7uAO9cAO7DADYsihHOShHMyhHOShHNxhHMohHMSBHcphBtaQQznI" +
            "QzmYQznIQzm4wziUQziIAzuUwy+8gzz8gjvUAzuwwwzEIQd8cAN6KId2gIcZysMO7GAP7eAG7PAO" +
            "7wAPMyKIHPDBDchBHM7BDewhHOSBHcIhH96hHuhhBhORAz64gTjIQzmEwzq4gTjIAwAAAHEgAABB" +
            "AAAAhmANl+88PrAsjgBMxApgKkVEmBlUw+U7jw9MDoMIG9Kgj4/cth1sw+U7jy8EVFEQUekAQ0kY" +
            "gID5yG1bgzRcvvP4QkQAExECzbAQJuAMl+88/uBMt1/cthVcw+U7jx8B1kYVBRGVDjD4yG0bATZc" +
            "vvP4EWBtVFEQETs5EeEjt20M2XD5zuNHAKZSRIT9aeQIBDH4SG0L3nD5zuNHAKZSRIT97ARMBCsA" +
            "CxD5xW2bgjdcvvP4EYCpFBFhPzsBE8EKwAJEPnLbltANl+88fgRgKkVE2N9GgECsACY2C9IQFiAN" +
            "l+88/nREBDCIg4/ctg08w+U7j081QIT5xW0bAMEASAMAAABhIAAA0QAAABMETCwQAAAAHgAAADSU" +
            "JuZyQPk23xsfFETJzQCUXZkaAkKUW8mUbkB9ZhJzMpQ8cECRC5S5QPkPFLpAwQsU5ECRDtRjJjEn" +
            "Q2EKlKVAcQbQUgQjACVAxgjAGAEIgiAJDmME70yaaDdGAIIgzIbBGAEIgiAIBmMEIAiC+C+MEYAg" +
            "CIIaACMGCQCCYPDBgYe8wRuYwYhBAoAgGHxx8CVswAZnMGKQACAIBp8cgMHSBm2ABiMGCQCCYPDN" +
            "QRg0buAGaTBiYAAgCAYEKHBvUAEnFXBQARpIBWgAFaABXmCUBYx8LHDgU4UbSAVuABW4AV5glAWS" +
            "fCyg4DNisAAgCAaHK7TBEVhHYI0YGAAIgkHiCm0QjBgcAAiCgbUKcSCBwmhCAAw3BKIABrMMRxAY" +
            "scnHjkI+5hjymSUQBiqGXii0YKBi6IWCDYKBCqMXClQIBiqMXihUIRioMHqhUIVgoMKIh4IJBiqM" +
            "eCigYKDCiIeCCgYqhngoeCIYMTAAEAQDIhfyYBZGDCIABMEAy4U8CMYAFvAAOQw1KIghDUYMDAAE" +
            "waCzhTsIRgwMAATBgMiFOxCGGwJbAINZhoEIRgwMAATBQNMFPCBGDAwABMGA4AU8KCpwuAJTkCOG" +
            "LSHgClJB7HjkY8gjH0se+dhQwceGCj42VPCpQ+MKbkEquAWoIBekglyACnZBKtgFqGAX8AKjLPgD" +
            "+VgQCvCZJSiKDFyBK+AFqTMYB6lgHKCCcpAKygFmCYqBisEbDGKgYuAGghioMKTBJoiBioEbEGKg" +
            "YsCDQSIGKgw5GMiCGKgw5GAwC2KgwpCDwSyIOtoBK3EHPMGoE4wqYRakBFqQEmwBSrgFGDFYABAE" +
            "gyMm4CEQnEBwRgwMAATBIIkJeAgsGORjQiEfGyT5FB6oBIwYHAAIgoElE/iQCycxmhAAww1DQAaz" +
            "DIIRzBIcAxWDXABqYIwYHAAIgoFlE/zQCysxmhAEww1BS4DBLAOSBCMGDgCCYODwBDyIwy+4BAES" +
            "IAES68ASswTLiIECgCAYRDvxDuLwCy6xDiwxmhAAww2BAQazDIsSjBgsAAiCwdQT8WAOMRETMTES" +
            "NTFLsGBADAACAAAAW4ZyeMwAAAAAAAAAAAAAAA==";
        // RT-DXIL-END

        [StructLayout(LayoutKind.Sequential)] struct QueueDesc { public uint Type; public int Priority; public uint Flags, NodeMask; }
        [StructLayout(LayoutKind.Sequential)] struct HeapProperties { public uint Type, CpuPageProperty, MemoryPool, CreationNodeMask, VisibleNodeMask; }
        [StructLayout(LayoutKind.Sequential)]
        struct ResourceDesc {
            public uint Dimension, Pad;
            public ulong Alignment, Width;
            public uint Height;
            public ushort DepthOrArraySize, MipLevels;
            public uint Format, SampleCount, SampleQuality, Layout, Flags;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ComputePsoDesc {
            public IntPtr RootSignature, CsPointer;
            public UIntPtr CsLength;
            public uint NodeMask, Pad;
            public IntPtr CachedPointer;
            public UIntPtr CachedLength;
            public uint Flags, Pad2;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct Barrier { public uint Type, Flags; public IntPtr Resource; public uint Subresource, Before, After, Pad; }
        [StructLayout(LayoutKind.Sequential)]
        struct GeometryDesc {
            public uint Type, Flags;
            public ulong Transform;
            public uint IndexFormat, VertexFormat, IndexCount, VertexCount;
            public ulong IndexBuffer, VertexAddress, VertexStride;
        }
        [StructLayout(LayoutKind.Sequential)] struct BuildInputs { public uint Type, Flags, NumDescs, DescsLayout; public ulong Descs; }
        [StructLayout(LayoutKind.Sequential)] struct BuildDesc { public ulong Dest; public BuildInputs Inputs; public ulong Source, Scratch; }
        [StructLayout(LayoutKind.Sequential)] struct PrebuildInfo { public ulong ResultSize, ScratchSize, UpdateScratchSize; }
        [StructLayout(LayoutKind.Sequential)] struct Options5 { public int SrvOnlyTiledResourceTier3; public uint RenderPassesTier, RaytracingTier; }  // 12 bytes

        const uint HeapDefault = 1, HeapUpload = 2, HeapReadback = 3;
        const uint FlagAllowUav = 0x4;  // D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS
        const uint StateCommon = 0, StateUav = 0x8, StateCopyDest = 0x400, StateCopySource = 0x800, StateGenericRead = 0xAC3, StateAccelerationStructure = 0x400000;

        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateCommandQueueFn(IntPtr self, ref QueueDesc desc, ref Guid riid, out IntPtr queue);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateCommandAllocatorFn(IntPtr self, uint type, ref Guid riid, out IntPtr allocator);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateComputePsoFn(IntPtr self, ref ComputePsoDesc desc, ref Guid riid, out IntPtr pso);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateCommandListFn(IntPtr self, uint node, uint type, IntPtr allocator, IntPtr pso, ref Guid riid, out IntPtr list);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CheckFeatureSupportFn(IntPtr self, uint feature, ref Options5 data, uint size);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateRootSignatureFn(IntPtr self, uint node, IntPtr blob, UIntPtr length, ref Guid riid, out IntPtr signature);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateCommittedResourceFn(IntPtr self, ref HeapProperties heap, uint heapFlags, ref ResourceDesc desc, uint state, IntPtr clear, ref Guid riid, out IntPtr resource);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CreateFenceFn(IntPtr self, ulong initial, uint flags, ref Guid riid, out IntPtr fence);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DeviceRemovedReasonFn(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void GetPrebuildInfoFn(IntPtr self, ref BuildInputs inputs, out PrebuildInfo info);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void ExecuteCommandListsFn(IntPtr self, uint count, IntPtr[] lists);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int QueueSignalFn(IntPtr self, IntPtr fence, ulong value);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int ResetFn(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate ulong GetCompletedValueFn(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int SetEventOnCompletionFn(IntPtr self, ulong value, IntPtr handle);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int MapFn(IntPtr self, uint subresource, IntPtr range, out IntPtr data);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void UnmapFn(IntPtr self, uint subresource, IntPtr range);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate ulong GetGpuAddressFn(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int CloseFn(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int ListResetFn(IntPtr self, IntPtr allocator, IntPtr pso);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void DispatchFn(IntPtr self, uint x, uint y, uint z);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void CopyBufferRegionFn(IntPtr self, IntPtr destination, ulong destinationOffset, IntPtr source, ulong sourceOffset, ulong bytes);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void ResourceBarrierFn(IntPtr self, uint count, ref Barrier barrier);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void SetRootSignatureFn(IntPtr self, IntPtr signature);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void SetRootConstantsFn(IntPtr self, uint index, uint count, uint[] data, uint offset);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void SetRootViewFn(IntPtr self, uint index, ulong address);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void BuildAccelerationStructureFn(IntPtr self, ref BuildDesc desc, uint postbuildCount, IntPtr postbuild);

        [DllImport("d3d12.dll")]
        static extern int D3D12CreateDevice(IntPtr adapter, uint featureLevel, ref Guid riid, out IntPtr device);

        static Guid IidDevice5 = new Guid("8b4f173b-2fea-4b80-8f58-4307191ab95d");
        static Guid IidCommandQueue = new Guid("0ec870a6-5d7e-4c22-8cfc-5baae07616ed");
        static Guid IidCommandAllocator = new Guid("6102dee4-af59-4b09-b999-b44d73f09b24");
        static Guid IidCommandList4 = new Guid("8754318e-d3a9-4541-98cf-645b50dc4874");
        static Guid IidFence = new Guid("0a753dcf-c4d8-4b91-adf6-be5a60d95a76");
        static Guid IidResource = new Guid("696442be-a72e-4059-bc79-5b5c98040fad");
        static Guid IidRootSignature = new Guid("c54a6b66-72df-4ee8-8be5-a946a1429214");
        static Guid IidPipelineState = new Guid("765a30f3-f624-4c6f-a828-ace948622445");

        IntPtr device, queue, list, fence, rootSignature, pso;
        IntPtr reference, errors, zero, vertices, instance, blas, tlas, scratch;
        readonly IntPtr[] allocators = new IntPtr[2];
        readonly IntPtr[] readback = new IntPtr[2];
        readonly ulong[] slotFence = new ulong[2];
        ulong fenceValue;
        ulong referenceAddress, errorsAddress, tlasAddress;
        uint[] parameters = new uint[4];

        ExecuteCommandListsFn execute;
        QueueSignalFn signal;
        SetEventOnCompletionFn waitFence;
        GetCompletedValueFn completedValue;
        DeviceRemovedReasonFn removedReason;
        CloseFn close;
        ListResetFn resetList;
        DispatchFn dispatch;
        CopyBufferRegionFn copyRegion;
        ResourceBarrierFn barrier;
        SetRootSignatureFn setRootSignature;
        SetRootConstantsFn setRootConstants;
        SetRootViewFn setRootSrv, setRootUav;

        public override uint ThreadCount { get { return Threads; } }
        protected override int Slots { get { return readback.Length; } }
        protected override double FlopsPerIteration { get { return 0; } }
        // Un rayo por iteración: se empieza por 1 porque sin núcleos RT (WARP) son muy lentos.
        protected override uint FirstIterations { get { return 1; } }
        protected override uint MinIterations { get { return 1; } }

        RtStress() { }

        public static RtStress Open(string adapterName) {
            RtStress s = new RtStress();
            try { s.Create(adapterName); } catch { s.Dispose(); throw; }
            return s;
        }

        void Create(string adapterName) {
            if (Dxil.Length == 0) throw new InvalidOperationException("El shader de ray tracing no está embebido en el script (tests/build-rt-shader.ps1 -Embed).");
            IntPtr adapter = Com.FindAdapter(adapterName);
            try {
                Com.Check(D3D12CreateDevice(adapter, 0xb000, ref IidDevice5, out device), "D3D12CreateDevice");
            } finally {
                Com.Release(ref adapter);
            }
            Options5 options = new Options5();
            Com.Check(Com.Fn<CheckFeatureSupportFn>(device, 13)(device, 27 /* D3D12_OPTIONS5 */, ref options, 12), "CheckFeatureSupport");
            if (options.RaytracingTier < 11) throw new InvalidOperationException("Este adaptador no admite ray tracing en línea (DXR 1.1): nivel " + options.RaytracingTier);
            removedReason = Com.Fn<DeviceRemovedReasonFn>(device, 37);

            QueueDesc qd = new QueueDesc();  // DIRECT, prioridad normal
            Com.Check(Com.Fn<CreateCommandQueueFn>(device, 8)(device, ref qd, ref IidCommandQueue, out queue), "CreateCommandQueue");
            execute = Com.Fn<ExecuteCommandListsFn>(queue, 10);
            signal = Com.Fn<QueueSignalFn>(queue, 14);
            for (int i = 0; i < allocators.Length; i++) {
                Com.Check(Com.Fn<CreateCommandAllocatorFn>(device, 9)(device, 0, ref IidCommandAllocator, out allocators[i]), "CreateCommandAllocator");
            }
            Com.Check(Com.Fn<CreateFenceFn>(device, 36)(device, 0, 0, ref IidFence, out fence), "CreateFence");
            completedValue = Com.Fn<GetCompletedValueFn>(fence, 8);
            waitFence = Com.Fn<SetEventOnCompletionFn>(fence, 9);

            // La firma raíz va dentro del DXIL ([RootSignature] en el HLSL).
            byte[] dxil = Convert.FromBase64String(Dxil);
            GCHandle pin = GCHandle.Alloc(dxil, GCHandleType.Pinned);
            try {
                Com.Check(Com.Fn<CreateRootSignatureFn>(device, 16)(device, 0, pin.AddrOfPinnedObject(), (UIntPtr)(uint)dxil.Length, ref IidRootSignature, out rootSignature), "CreateRootSignature");
                ComputePsoDesc pd = new ComputePsoDesc();
                pd.RootSignature = rootSignature;
                pd.CsPointer = pin.AddrOfPinnedObject();
                pd.CsLength = (UIntPtr)(uint)dxil.Length;
                Com.Check(Com.Fn<CreateComputePsoFn>(device, 11)(device, ref pd, ref IidPipelineState, out pso), "CreateComputePipelineState");
            } finally {
                pin.Free();
            }
            Com.Check(Com.Fn<CreateCommandListFn>(device, 12)(device, 0, 0, allocators[0], pso, ref IidCommandList4, out list), "CreateCommandList");
            close = Com.Fn<CloseFn>(list, 9);
            resetList = Com.Fn<ListResetFn>(list, 10);
            dispatch = Com.Fn<DispatchFn>(list, 14);
            copyRegion = Com.Fn<CopyBufferRegionFn>(list, 15);
            barrier = Com.Fn<ResourceBarrierFn>(list, 26);
            setRootSignature = Com.Fn<SetRootSignatureFn>(list, 29);
            setRootConstants = Com.Fn<SetRootConstantsFn>(list, 35);
            setRootSrv = Com.Fn<SetRootViewFn>(list, 39);
            setRootUav = Com.Fn<SetRootViewFn>(list, 41);
            Com.Check(close(list), "Close");

            reference = CreateBuffer(Threads * 4, HeapDefault, FlagAllowUav, StateUav);
            errors = CreateBuffer(16, HeapDefault, FlagAllowUav, StateUav);
            zero = CreateBuffer(16, HeapUpload, 0, StateGenericRead);
            Fill(zero, new byte[16]);
            for (int i = 0; i < readback.Length; i++) readback[i] = CreateBuffer(16, HeapReadback, 0, StateCopyDest);
            referenceAddress = Com.Fn<GetGpuAddressFn>(reference, 11)(reference);
            errorsAddress = Com.Fn<GetGpuAddressFn>(errors, 11)(errors);
            BuildScene();
        }

        IntPtr CreateBuffer(ulong size, uint heapType, uint flags, uint state) {
            HeapProperties heap = new HeapProperties();
            heap.Type = heapType; heap.CreationNodeMask = 1; heap.VisibleNodeMask = 1;
            ResourceDesc d = new ResourceDesc();
            d.Dimension = 1;  // BUFFER
            d.Width = size; d.Height = 1; d.DepthOrArraySize = 1; d.MipLevels = 1;
            d.SampleCount = 1; d.Layout = 1 /* ROW_MAJOR */; d.Flags = flags;
            IntPtr resource;
            Com.Check(Com.Fn<CreateCommittedResourceFn>(device, 27)(device, ref heap, 0, ref d, state, IntPtr.Zero, ref IidResource, out resource),
                "CreateCommittedResource (" + size + " bytes, heap " + heapType + ", flags 0x" + flags.ToString("X") + ", estado 0x" + state.ToString("X") + ")");
            return resource;
        }

        void Fill(IntPtr resource, byte[] data) {
            IntPtr p;
            Com.Check(Com.Fn<MapFn>(resource, 8)(resource, 0, IntPtr.Zero, out p), "Map");
            Marshal.Copy(data, 0, p, data.Length);
            Com.Fn<UnmapFn>(resource, 9)(resource, 0, IntPtr.Zero);
        }

        // Una nube de triángulos pequeños, siempre la misma, delante del origen de los rayos.
        void BuildScene() {
            float[] v = new float[TriangleCount * 9];
            uint seed = 7;
            for (int i = 0; i < v.Length; i += 9) {
                float[] c = new float[3];
                for (int k = 0; k < 3; k++) { seed = seed * 1664525u + 1013904223u; c[k] = (seed >> 8) * (4.0f / 16777216.0f) - 2.0f; }
                c[2] += 1.0f;  // z en [-1, 3]
                for (int k = 0; k < 9; k++) { seed = seed * 1664525u + 1013904223u; v[i + k] = c[k % 3] + (seed >> 8) * (0.3f / 16777216.0f) - 0.15f; }
            }
            byte[] bytes = new byte[v.Length * 4];
            Buffer.BlockCopy(v, 0, bytes, 0, bytes.Length);
            vertices = CreateBuffer((ulong)bytes.Length, HeapUpload, 0, StateGenericRead);
            Fill(vertices, bytes);

            GeometryDesc geometry = new GeometryDesc();
            geometry.Flags = 1;         // OPAQUE
            geometry.VertexFormat = 6;  // R32G32B32_FLOAT
            geometry.VertexCount = TriangleCount * 3;
            geometry.VertexAddress = Com.Fn<GetGpuAddressFn>(vertices, 11)(vertices);
            geometry.VertexStride = 12;
            GCHandle pin = GCHandle.Alloc(geometry, GCHandleType.Pinned);
            try {
                BuildInputs blasInputs = new BuildInputs();
                blasInputs.Type = 1;  // BOTTOM_LEVEL
                blasInputs.NumDescs = 1;
                blasInputs.Descs = (ulong)pin.AddrOfPinnedObject().ToInt64();
                PrebuildInfo blasInfo;
                GetPrebuildInfoFn prebuild = Com.Fn<GetPrebuildInfoFn>(device, 63);
                prebuild(device, ref blasInputs, out blasInfo);
                blas = CreateBuffer(blasInfo.ResultSize, HeapDefault, FlagAllowUav, StateAccelerationStructure);
                ulong blasAddress = Com.Fn<GetGpuAddressFn>(blas, 11)(blas);

                // Una instancia con la transformación identidad y máscara 0xFF.
                byte[] inst = new byte[64];
                Buffer.BlockCopy(new float[] { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 }, 0, inst, 0, 48);
                Buffer.BlockCopy(BitConverter.GetBytes(0xFF000000u), 0, inst, 48, 4);
                Buffer.BlockCopy(BitConverter.GetBytes(blasAddress), 0, inst, 56, 8);
                instance = CreateBuffer(64, HeapUpload, 0, StateGenericRead);
                Fill(instance, inst);
                BuildInputs tlasInputs = new BuildInputs();
                tlasInputs.NumDescs = 1;  // TOP_LEVEL
                tlasInputs.Descs = Com.Fn<GetGpuAddressFn>(instance, 11)(instance);
                PrebuildInfo tlasInfo;
                prebuild(device, ref tlasInputs, out tlasInfo);
                tlas = CreateBuffer(tlasInfo.ResultSize, HeapDefault, FlagAllowUav, StateAccelerationStructure);
                tlasAddress = Com.Fn<GetGpuAddressFn>(tlas, 11)(tlas);
                scratch = CreateBuffer(Math.Max(blasInfo.ScratchSize, tlasInfo.ScratchSize), HeapDefault, FlagAllowUav, StateUav);
                ulong scratchAddress = Com.Fn<GetGpuAddressFn>(scratch, 11)(scratch);

                Begin(0);
                BuildDesc build = new BuildDesc();
                build.Dest = blasAddress; build.Inputs = blasInputs; build.Scratch = scratchAddress;
                Com.Fn<BuildAccelerationStructureFn>(list, 72)(list, ref build, 0, IntPtr.Zero);
                UavBarrier(blas);
                build.Dest = tlasAddress; build.Inputs = tlasInputs;
                Com.Fn<BuildAccelerationStructureFn>(list, 72)(list, ref build, 0, IntPtr.Zero);
                UavBarrier(tlas);
                End(0);
                Wait(slotFence[0]);
                if (removedReason(device) < 0) throw new InvalidOperationException("El driver se ha reiniciado al construir la escena de ray tracing.");
            } finally {
                pin.Free();
            }
        }

        void Begin(int slot) {
            Wait(slotFence[slot]);
            Com.Check(Com.Fn<ResetFn>(allocators[slot], 8)(allocators[slot]), "CommandAllocator.Reset");
            Com.Check(resetList(list, allocators[slot], pso), "CommandList.Reset");
        }

        void End(int slot) {
            Com.Check(close(list), "Close");
            execute(queue, 1, new IntPtr[] { list });
            fenceValue++;
            Com.Check(signal(queue, fence, fenceValue), "Signal");
            slotFence[slot] = fenceValue;
        }

        void Wait(ulong value) {
            if (completedValue(fence) < value) Com.Check(waitFence(fence, value, IntPtr.Zero), "SetEventOnCompletion");
        }

        void UavBarrier(IntPtr resource) {
            Barrier b = new Barrier();
            b.Type = 2;  // UAV
            b.Resource = resource;
            barrier(list, 1, ref b);
        }

        void Transition(IntPtr resource, uint before, uint after) {
            Barrier b = new Barrier();
            b.Resource = resource; b.Subresource = 0xffffffff; b.Before = before; b.After = after;
            barrier(list, 1, ref b);
        }

        protected override void SetParams(uint iterations, uint verify) {
            parameters = new uint[] { iterations, verify, 0, 0 };
        }

        protected override void ClearErrors() {
            if (Lost) return;
            Begin(0);
            Transition(errors, StateUav, StateCopyDest);
            copyRegion(list, errors, 0, zero, 0, 16);
            Transition(errors, StateCopyDest, StateUav);
            End(0);
            Wait(slotFence[0]);
        }

        protected override void Submit(int slot, int perBatch, bool light) {
            if (Lost) return;
            Begin(slot);
            setRootSignature(list, rootSignature);
            setRootConstants(list, 0, 4, parameters, 0);
            setRootSrv(list, 1, tlasAddress);
            setRootUav(list, 2, referenceAddress);
            setRootUav(list, 3, errorsAddress);
            for (int i = 0; i < perBatch; i++) {
                UavBarrier(errors);
                UavBarrier(reference);
                dispatch(list, Groups, 1, 1);
            }
            Transition(errors, StateUav, StateCopySource);
            copyRegion(list, readback[slot], 0, errors, 0, 16);
            Transition(errors, StateCopySource, StateUav);
            End(slot);
        }

        protected override bool ReadErrors(int slot, out long count) {
            count = 0;
            if (Lost) return false;
            Wait(slotFence[slot]);
            if (removedReason(device) < 0) { Lost = true; return false; }
            IntPtr p;
            if (Com.Fn<MapFn>(readback[slot], 8)(readback[slot], 0, IntPtr.Zero, out p) < 0) { Lost = true; return false; }
            count = (uint)Marshal.ReadInt32(p);
            Com.Fn<UnmapFn>(readback[slot], 9)(readback[slot], 0, IntPtr.Zero);
            return true;
        }

        protected override void ReleaseAll(bool wasLost) {
            if (!wasLost && queue != IntPtr.Zero && fence != IntPtr.Zero) {
                try { Wait(fenceValue); } catch (InvalidOperationException) { }
            }
            Com.Release(ref scratch);
            Com.Release(ref tlas);
            Com.Release(ref blas);
            Com.Release(ref instance);
            Com.Release(ref vertices);
            for (int i = 0; i < readback.Length; i++) Com.Release(ref readback[i]);
            Com.Release(ref zero);
            Com.Release(ref errors);
            Com.Release(ref reference);
            Com.Release(ref list);
            Com.Release(ref pso);
            Com.Release(ref rootSignature);
            Com.Release(ref fence);
            for (int i = 0; i < allocators.Length; i++) Com.Release(ref allocators[i]);
            Com.Release(ref queue);
            Com.Release(ref device);
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

# Registro estructurado: un archivo JSON Lines por ejecución en <datos>\logs (se
# guardan los 10 últimos de cada comando). Cada línea es un objeto con "t" (hora ISO 8601),
# "event" y sus datos, con claves en inglés, pensado para que lo analice una
# persona o una IA. El comando report los junta en un solo archivo.
$script:LogPath = $null

function Start-Log([string]$Name) {
    try {
        $dir = Join-Path (Get-DataDir) 'logs'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # Los 10 últimos de cada comando: los apply del arranque no borran los de tune.
        Get-ChildItem -LiteralPath $dir -Filter "*-$Name.jsonl" | Sort-Object Name -Descending | Select-Object -Skip 9 | Remove-Item -Force
        $script:LogPath = Join-Path $dir ('{0:yyyyMMdd-HHmmss}-{1}.jsonl' -f (Get-Date), $Name)
    } catch {
        Write-Warning "No se puede crear el registro: $($_.Exception.Message)"
    }
}

# Un fallo al escribir el registro nunca interrumpe el comando.
function Write-Log([string]$Event, [hashtable]$Data = @{}) {
    if (-not $script:LogPath) { return }
    $record = [ordered]@{ t = (Get-Date).ToString('o'); event = $Event }
    foreach ($key in ($Data.Keys | Sort-Object)) { $record[$key] = $Data[$key] }   # orden estable
    try {
        $line = ($record | ConvertTo-Json -Compress -Depth 6) + "`n"
        [IO.File]::AppendAllText($script:LogPath, $line, (New-Object Text.UTF8Encoding $false))
    } catch { }
}

# Las claves de un resultado del test de estrés, redondeadas, para el registro.
function ConvertTo-LogResult($Result) {
    if ($null -eq $Result) { return $null }
    [ordered]@{
        failure = $Result.Failure; errors = $Result.Errors; deviceLost = $Result.DeviceLost; batches = $Result.Batches
        tflops = [math]::Round($Result.Tflops, 3); lowTflops = [math]::Round($Result.LowTflops, 3)
        watts = [math]::Round($Result.Watts, 1); clockMHz = [math]::Round($Result.ClockMHz); maxTempC = $Result.MaxTempC
        p0Pct = [math]::Round($Result.P0Pct, 1); powerCappedPct = [math]::Round($Result.PowerCappedPct, 1)
    }
}

function Get-OsDescription {
    try {
        $v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        '{0} {1} (build {2}.{3})' -f $v.ProductName, $v.DisplayVersion, $v.CurrentBuild, $v.UBR
    } catch {
        [Environment]::OSVersion.VersionString
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
    $rc = [Uv4070.Nvml]::SetGraphicsOffset($Device, $MHz)
    $now = if ($rc -eq 0) { Get-CoreOffset $Device } else { $null }
    Write-Log 'nvml' @{ op = 'set-offset'; mhz = $MHz; rc = $rc; readback = $(if ($now) { $now.MHz }) }
    Assert-Nvml $rc "No se pudo poner el offset a +$MHz MHz"
    if ($null -ne $now -and $now.MHz -ne $MHz) {
        throw "El driver aceptó el offset de +$MHz MHz pero informa de $($now.MHz) MHz."
    }
}

function Set-ClockCap($Device, [int]$MaxMHz) {
    # Sin suelo (0) para que en escritorio siga bajando de reloj. Si el driver
    # no acepta 0, se usa 210 MHz, el reloj en reposo de la 4070.
    $rc = [Uv4070.Nvml]::SetLockedClocks($Device, 0, $MaxMHz)
    $floor = 0
    if ($rc -ne 0) { $floor = 210; $rc = [Uv4070.Nvml]::SetLockedClocks($Device, $floor, $MaxMHz) }
    Write-Log 'nvml' @{ op = 'set-cap'; minMHz = $floor; maxMHz = $MaxMHz; rc = $rc }
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

function Set-PowerPct($Device, [int]$Pct, [switch]$Quiet) {
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
    $current = Read-Nvml { param($out) [Uv4070.Nvml]::GetPowerManagementLimit($Device, $out) }
    if ($current -eq $target) { return }
    $watts = '{0:N0} W' -f ($target / 1000)
    $rc = [Uv4070.Nvml]::SetPowerLimit($Device, $target)
    Write-Log 'nvml' @{ op = 'set-power'; pct = $Pct; milliwatts = $target; rc = $rc }
    Assert-Nvml $rc "No se pudo poner el límite de potencia a $watts"
    if (-not $Quiet) { Write-Host "Límite de potencia: $watts" }
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

function Invoke-Reset($Device) {
    if (-not (Reset-Stock $Device)) { throw 'No se pudo restaurar todo; reinicia el PC para volver a fábrica.' }
    Write-Host 'Valores de fábrica restaurados.'
}

# Devuelve $false si algo no se pudo restaurar.
function Reset-Stock($Device, [switch]$Quiet) {
    $ok = $true
    # Al revés que Set-Uv: primero el offset y luego el tope. Si el offset no
    # baja a 0, el tope se queda puesto para no convertirlo en un overclock.
    $rc = [Uv4070.Nvml]::SetGraphicsOffset($Device, 0)
    Write-Log 'nvml' @{ op = 'reset-offset'; rc = $rc }
    if ($rc -ne 0) {
        Write-Warning ('No se pudo poner el offset a 0 ({0}); el tope de reloj se queda puesto.' -f [Uv4070.Nvml]::ErrorString($rc))
        $ok = $false
    } else {
        $rc = [Uv4070.Nvml]::ResetLockedClocks($Device)
        Write-Log 'nvml' @{ op = 'reset-cap'; rc = $rc }
        if ($rc -ne 0) {
            Write-Warning ('No se pudo quitar el tope de reloj: {0}' -f [Uv4070.Nvml]::ErrorString($rc))
            $ok = $false
        }
    }
    try { Set-PowerPct $Device 100 -Quiet:$Quiet } catch { Write-Warning $_.Exception.Message; $ok = $false }
    return $ok
}

function Read-Config {
    $path = Join-Path (Get-DataDir) 'config.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
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
    $config = [ordered]@{ MaxMHz = $null; OffsetMHz = $null; PowerPct = 100 }
    if ($saved) {
        $config.MaxMHz = [int]$saved.MaxMHz; $config.OffsetMHz = [int]$saved.OffsetMHz; $config.PowerPct = [int]$saved.PowerPct
        # La fecha y el driver del tune solo valen para el tope y el offset que encontró.
        if (-not $Bound.ContainsKey('MaxMHz') -and -not $Bound.ContainsKey('OffsetMHz')) {
            foreach ($key in 'Tuned', 'Driver') {
                if ($saved.PSObject.Properties[$key]) { $config[$key] = $saved.$key }
            }
        }
    }
    if ($Bound.ContainsKey('MaxMHz')) { $config.MaxMHz = $MaxMHz }
    if ($Bound.ContainsKey('OffsetMHz')) { $config.OffsetMHz = $OffsetMHz }
    if ($Bound.ContainsKey('PowerPct')) { $config.PowerPct = $PowerPct }
    if (($null -eq $config.MaxMHz) -ne ($null -eq $config.OffsetMHz) -or ($Required -and $null -eq $config.MaxMHz)) {
        throw 'No hay configuración guardada: ejecuta "tune", o indica -MaxMHz y -OffsetMHz.'
    }
    [pscustomobject]$config
}

# ---------------------------------------------------------------------------
# Test de estrés y ajuste automático

$script:Engine = $null
$script:RtEngine = $null
$RtMode = 3   # modo de Invoke-Step: el test de ray tracing (carga sostenida)

function New-StressEngine { [Uv4070.Stress]::Open($GpuName) }
function New-RtStressEngine { [Uv4070.RtStress]::Open($GpuName) }

# Motor del test listo para usar. Al crearlo, la referencia se calcula a
# $SafeMHz y sin offset, donde cualquier 4070 es estable; después hay que volver
# a poner la configuración que se quiera probar.
function Get-Engine($Device) {
    if ($script:Engine -and -not $script:Engine.Lost) { return $script:Engine }
    if ($script:Engine) { $script:Engine.Dispose(); $script:Engine = $null }
    $script:Engine = New-Engine $Device 'compute' { New-StressEngine }
    $script:Engine
}

# El test de ray tracing, con su propia referencia.
function Get-RtEngine($Device) {
    if ($script:RtEngine -and -not $script:RtEngine.Lost) { return $script:RtEngine }
    if ($script:RtEngine) { $script:RtEngine.Dispose(); $script:RtEngine = $null }
    $script:RtEngine = New-Engine $Device 'raytracing' { New-RtStressEngine }
    $script:RtEngine
}

function New-Engine($Device, [string]$Kind, [scriptblock]$Open) {
    Set-Uv $Device $SafeMHz 0
    $engine = & $Open
    try {
        $engine.Calibrate(15)
        $engine.CaptureReference()
    } catch {
        $engine.Dispose()
        throw
    }
    Write-Log 'engine' @{ kind = $Kind; iterations = $engine.Iterations; dispatchMs = [math]::Round($engine.DispatchMs, 2) }
    $engine
}

function Close-Engine {
    if ($script:Engine) { $script:Engine.Dispose() }
    if ($script:RtEngine) { $script:RtEngine.Dispose() }
    $script:Engine = $null
    $script:RtEngine = $null
}

# Reinicios del driver (TDR) en el registro de eventos de Windows desde $Since.
# Sin acceso al registro devuelve una lista vacía; Search-DriverResets da el motivo.
function Get-DriverResets([datetime]$Since) {
    $search = Search-DriverResets $Since
    $search.Events
}

function Search-DriverResets([datetime]$Since) {
    if (-not (Get-Command Get-WinEvent -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Ok = $false; Error = 'Get-WinEvent no existe aquí'; Events = @() }
    }
    $resets = @()
    # Un proveedor cada vez: sin driver de NVIDIA no existe nvlddmkm, y eso no debe tapar Display.
    foreach ($provider in 'nvlddmkm', 'Display') {
        try {
            $events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $provider; StartTime = $Since } -ErrorAction Stop
        } catch {
            # Sin eventos que coincidan, o sin ese proveedor, Get-WinEvent da error: no es un fallo.
            if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound|NoMatchingProvider') { continue }
            return [pscustomobject]@{ Ok = $false; Error = "$($_.FullyQualifiedErrorId): $($_.Exception.Message)"; Events = @() }
        }
        $resets += @($events | Where-Object { ($_.ProviderName -eq 'nvlddmkm' -and $_.Level -le 2) -or $_.Id -eq 4101 })
    }
    [pscustomobject]@{ Ok = $true; Error = $null; Events = $resets }
}

# Una carga con un tope y offset concretos ($Cap 0 = de serie). $Mode es
# Steady, Pulses o Light de [Uv4070.Stress], o $RtMode (ray tracing). En tramos
# de 20 s como máximo para que Ctrl+C responda.
function Invoke-Step($Device, [int]$Cap, [int]$Offset, [double]$Seconds, [int]$Mode = 0) {
    $runMode = $Mode
    if ($Mode -eq $RtMode) { $engine = Get-RtEngine $Device; $runMode = [Uv4070.Stress]::Steady } else { $engine = Get-Engine $Device }
    if ($Cap -gt 0) { Set-Uv $Device $Cap $Offset } else { [void](Reset-Stock $Device -Quiet) }
    $since = Get-Date
    $left = $Seconds * $TestScale
    do {
        $chunk = [math]::Min($left, 20)
        $left -= $chunk
        $result = $engine.Run($chunk, $Device, $runMode)
    } while (-not $result.Failure -and $left -gt 0)
    $resets = @(Get-DriverResets $since).Count
    if (-not $result.Failure -and $resets -gt 0) { $result.Failure = 'el driver se ha reiniciado' }
    Write-Log 'load' @{
        cap = $Cap; offset = $Offset; seconds = $Seconds * $TestScale; mode = @('steady', 'pulses', 'light', 'rt')[$Mode]
        driverResets = $resets; result = (ConvertTo-LogResult $result)
    }
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
    # Si la GPU sale de P0 entre ráfagas, el reloj medio queda corto y el tope saldría demasiado bajo.
    if ($r.P0Pct -ge 0 -and $r.P0Pct -lt 90) {
        throw "La carga ligera no mantiene la GPU en P0 (solo un $([int]$r.P0Pct) % del tiempo): el reloj máximo no sería fiable."
    }
    $r.ClockMHz
}

# El tope que pierde $LossPct % frente al reloj máximo de serie, en pasos de 15 MHz.
function Get-TargetCap([double]$BoostMHz, [int]$LossPct) {
    [int]([math]::Floor($BoostMHz * (100 - $LossPct) / 100 / 15) * 15)
}

# Un ciclo de estabilidad: carga sostenida en el tope, la misma curva más abajo
# (cada reloj usa su propio punto de tensión), carga ligera en el tope (con la
# carga máxima la GPU se queda en el límite de potencia y no llega al tope; con
# la ligera sí, como en un juego), ray tracing y pulsos de carga. $Scale alarga cada parte.
function Get-StabilityPlan([int]$Cap) {
    $steadyMode = [Uv4070.Stress]::Steady
    $plan = @(@{ Cap = $Cap; Seconds = 40; Mode = $steadyMode })
    if ($Cap -gt 0) {
        foreach ($f in ($Cap - 300), ($Cap - 600), ($Cap - 900)) {
            if ($f -ge $SafeMHz) { $plan += @{ Cap = $f; Seconds = 8; Mode = $steadyMode } }
        }
        $plan += @{ Cap = $Cap; Seconds = 10; Mode = [Uv4070.Stress]::Light }
        $plan += @{ Cap = $Cap; Seconds = 12; Mode = $RtMode }
    }
    $plan += @{ Cap = $Cap; Seconds = 15; Mode = [Uv4070.Stress]::Pulses }
    $plan
}

# Segundos de un ciclo con $Scale = 1: unos 100 con tope y 55 de serie.
function Get-StabilityCycleSeconds([int]$Cap) {
    [int]((Get-StabilityPlan $Cap | ForEach-Object { $_.Seconds } | Measure-Object -Sum).Sum)
}

function Test-Stability($Device, [int]$Cap, [int]$Offset, [double]$Scale) {
    $steady = $null
    foreach ($p in (Get-StabilityPlan $Cap)) {
        $r = Invoke-Step $Device $p.Cap $Offset ($p.Seconds * $Scale) $p.Mode
        if ($null -eq $steady) { $steady = $r }
        if ($r.Failure) {
            $where = if ($p.Cap -gt 0) { " a $($p.Cap) MHz" } else { '' }
            $how = @('', ' en pulsos', ' con carga ligera', ' con ray tracing')[$p.Mode]
            return [pscustomobject]@{ Failure = "$($r.Failure)$where$how"; Steady = $steady }
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
    if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
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
    Write-Host "tune busca la configuración que menos consume perdiendo como mucho un $MaxLossPct % de reloj (unos 30 minutos):"
    Write-Host '  1. Mide la tarjeta de serie: rendimiento, consumo y reloj máximo.'
    Write-Host "  2. Con el tope un $MaxLossPct % por debajo de ese reloj, sube la curva (menos tensión) hasta que"
    Write-Host "     el test de estrés falla, y deja $MarginMHz MHz de margen."
    Write-Host '  3. Lo confirma con unos 10 minutos más de estrés y lo guarda.'
    Write-Host 'Cierra juegos, navegadores y todo lo que use la GPU. Puede que la pantalla parpadee o que'
    Write-Host 'el driver se reinicie: es normal y no daña la tarjeta. Si el PC se llega a colgar,'
    Write-Host 'reinícialo y vuelve a ejecutar tune: seguirá donde lo dejó.'
    if (-not $Yes -and (Read-Host '¿Empezar? (s/n)') -notmatch '^[sS]') { return }

    $driver = Get-DriverVersion
    # El límite de potencia guardado (install -PowerPct) se conserva en la configuración nueva.
    $savedPowerPct = 100
    try { $saved = Read-Config; if ($saved) { $savedPowerPct = [int]$saved.PowerPct } } catch { }
    $state = Read-TuneState
    if ($state) {   # claves de versiones anteriores del estado
        foreach ($missing in @{ FlatSteps = 0; MarginMHz = 30 }.GetEnumerator()) {
            if ($null -eq $state.PSObject.Properties[$missing.Key]) { $state | Add-Member -NotePropertyName $missing.Key -NotePropertyValue $missing.Value }
        }
    }
    if ($state -and ($state.Driver -ne $driver -or $state.LossPct -ne $MaxLossPct -or $state.MarginMHz -ne $MarginMHz)) { $state = $null }
    if ($state) {
        Write-Host 'Continuando el ajuste anterior.'
        Write-Log 'tune-resume' @{ state = $state }
        if ($null -ne $state.Testing) {
            Write-Log 'tune-hang' @{ offset = $state.Testing; duringConfirm = ($null -ne $state.Best) }
            # Si el estado aún marca una prueba en curso, el PC se colgó en ella.
            Write-Warning "El PC se colgó probando el offset +$($state.Testing) MHz: cuenta como inestable."
            if ($null -eq $state.Best) { $state.Failed = @($state.Failed) + [int]$state.Testing }
            else { $state.Best = [math]::Max(0, [int]$state.Testing - 15) }
            $state.Testing = $null
            Save-TuneState $state
        }
    } else {
        $state = [pscustomobject]@{
            Driver = $driver; LossPct = $MaxLossPct; MarginMHz = $MarginMHz; Baseline = $null; BoostMHz = $null; Target = $null
            Passed = @(); Failed = @(); LastWatts = $null; FlatSteps = 0; Plateau = $false; Best = $null; Testing = $null
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
            Write-Log 'tune-baseline' @{ stock = $base; boostMHz = $state.BoostMHz; lossPct = $MaxLossPct; target = $state.Target }
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
                Write-Log 'tune-step' @{
                    target = $target; offset = $offset; failure = $result.Failure
                    watts = [math]::Round($result.Steady.Watts, 1); powerCappedPct = [math]::Round($result.Steady.PowerCappedPct, 1)
                }
                if ($result.Failure) {
                    $state.Failed = @($state.Failed) + $offset
                    Write-Host ('  +{0,3} MHz  falla: {1}' -f $offset, $result.Failure) -ForegroundColor Yellow
                } else {
                    $watts = $result.Steady.Watts
                    # Por debajo de la tensión mínima de la curva, más offset ya no ahorra nada. Solo
                    # cuenta si la GPU no está pegada al límite de potencia (ahí el consumo es el
                    # límite, aunque el undervolt siga avanzando) y se repite dos pasos seguidos, por
                    # el ruido de la medida y porque la GPU, al calentarse, consume algo más.
                    $capped = $result.Steady.PowerCappedPct -ge 10
                    if ($null -eq (Get-LowestFail $state.Failed) -and $state.LastWatts -and $watts -ge 0.99 * $state.LastWatts -and -not $capped) {
                        $state.FlatSteps = [int]$state.FlatSteps + 1
                        if ($state.FlatSteps -ge 2) { $state.Plateau = $true }
                    } else {
                        $state.FlatSteps = 0
                    }
                    $state.LastWatts = $watts
                    $state.Passed = @($state.Passed) + $offset
                    $limited = if ($capped) { '  (al límite de potencia)' } else { '' }
                    Write-Host ('  +{0,3} MHz  estable  {1,5:N0} W{2}' -f $offset, $watts, $limited)
                }
                Save-TuneState $state
            }
            $highest = Get-HighestPass $state.Passed $state.Failed
            $state.Best = [math]::Max(0, $highest - $MarginMHz)
            Save-TuneState $state
            Write-Log 'tune-best' @{ highest = $highest; best = $state.Best; plateau = $state.Plateau; passed = $state.Passed; failed = $state.Failed }
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
            Write-Log 'tune-confirm' @{ target = $target; offset = $offset; failure = $result.Failure }
            if (-not $result.Failure) { break }
            if ($offset -eq 0) { throw "Ni sin offset pasa la confirmación ($($result.Failure)). Revisa el driver o la tarjeta." }
            Write-Warning "Falla ($($result.Failure)): se baja 15 MHz."
            $offset = [math]::Max(0, $offset - 15)
            $state.Best = $offset
            Save-TuneState $state
        }

        Write-Phase 'Resultado'
        # La tarjeta de serie se mide otra vez, ya caliente, para compararla en igualdad con la nueva
        # configuración (la primera medida, con la GPU fría, consume menos por las fugas).
        $stock = Measure-Point $Device 0 0
        $final = Measure-Point $Device $target $offset
        $config = [pscustomobject]@{
            MaxMHz = $target; OffsetMHz = $offset; PowerPct = $savedPowerPct
            Tuned = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Driver = $driver
        }
        Save-Config $config
        if ($config.PowerPct -ne 100) { Set-PowerPct $Device $config.PowerPct }
        $highest = Get-HighestPass $state.Passed $state.Failed
        $summary = [ordered]@{
            version = $ScriptVersion; tuned = $config.Tuned; driver = $driver; lossPct = $MaxLossPct; requestedMarginMHz = $MarginMHz
            config = $config; boostMHz = $state.BoostMHz; stock = $stock; stockCold = $state.Baseline; final = $final
            highestStableOffset = $highest; marginMHz = $highest - $offset; passed = $state.Passed; failed = $state.Failed; plateau = $state.Plateau
        }
        Write-Log 'tune-result' @{ summary = $summary }
        $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path (Get-DataDir) 'tune-report.json') -Encoding UTF8
        $report = Format-TuneReport $stock $state.BoostMHz $final $config $highest
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
    $result = $null
    try {
        $result = Test-Stability $Device $cap $offset ($Minutes * 60 / (Get-StabilityCycleSeconds $cap))
    } finally {
        Close-Engine
        # Solo se deja puesta una configuración que ha pasado el test; si falla, o al cancelar, vuelve a fábrica.
        if ($cap -gt 0 -and $result -and -not $result.Failure) { Invoke-Apply $Device $Config } else { [void](Reset-Stock $Device) }
    }
    if ($result.Failure) {
        throw ("INESTABLE: $($result.Failure). La GPU queda de fábrica hasta el próximo apply o reinicio. " +
            "Baja el offset 15 MHz (install -OffsetMHz $([math]::Max(0, $offset - 15))) o ejecuta tune.")
    }
    $s = $result.Steady
    Write-Host ('ESTABLE: {0} min sin errores. {1:N1} TFLOPS, {2:N0} W, {3} °C como máximo.' -f $Minutes, $s.Tflops, $s.Watts, $s.MaxTempC) -ForegroundColor Green
}

# ---------------------------------------------------------------------------

# Estado actual como objeto (lo usan status y report).
function Get-StatusInfo($Device) {
    $info = [ordered]@{ gpu = $GpuName; version = $ScriptVersion }
    if ($Device) {
        $usage = Read-Nvml { param($out) [Uv4070.Nvml]::GetPowerUsage($Device, $out) }
        $limit = Read-Nvml { param($out) [Uv4070.Nvml]::GetPowerLimit($Device, $out) }
        $default = Read-Nvml { param($out) [Uv4070.Nvml]::GetDefaultPowerLimit($Device, $out) }
        $offset = Get-CoreOffset $Device
        $info.driver = Get-DriverVersion
        $info.coreMHz = Read-Nvml { param($out) [Uv4070.Nvml]::GetClock($Device, 0, $out) }
        $info.memMHz = Read-Nvml { param($out) [Uv4070.Nvml]::GetClock($Device, 2, $out) }
        $info.tempC = Read-Nvml { param($out) [Uv4070.Nvml]::GetTemperature($Device, 0, $out) }
        $info.powerW = $(if ($null -ne $usage) { [math]::Round($usage / 1000, 1) })
        $info.powerLimitW = $(if ($null -ne $limit) { [math]::Round($limit / 1000) })
        $info.defaultPowerLimitW = $(if ($null -ne $default) { [math]::Round($default / 1000) })
        $info.offsetMHz = $(if ($offset) { $offset.MHz })
    }
    try { $info.savedConfig = Read-Config } catch { $info.savedConfig = "no válida: $($_.Exception.Message)" }
    $info.autostart = $null
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $info.autostart = [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    }
    $info
}

function Show-Status($Device) {
    $s = Get-StatusInfo $Device
    Write-Host "GPU:          $GpuName (driver $($s.driver))"
    Write-Host "Reloj:        núcleo $($s.coreMHz) MHz, memoria $($s.memMHz) MHz"
    Write-Host ('Offset:       {0}' -f $(if ($null -ne $s.offsetMHz) { '{0:+0;-0;0} MHz' -f $s.offsetMHz } else { 'n/d' }))
    Write-Host 'Tope:         NVML no deja leerlo; con "monitor" en un juego se ve dónde se queda el reloj.'
    Write-Host ('Consumo:      {0:N1} W, límite {1:N0} W (fábrica {2:N0} W)' -f $s.powerW, $s.powerLimitW, $s.defaultPowerLimitW)
    Write-Host "Temperatura:  $($s.tempC) °C"
    $c = $s.savedConfig
    $saved = if ($c -is [string]) { $c } elseif ($c) { "tope $($c.MaxMHz) MHz, offset +$($c.OffsetMHz) MHz, potencia $($c.PowerPct) %" } else { 'ninguna (usa "tune")' }
    Write-Host "Guardada:     $saved"
    if ($null -ne $s.autostart) { Write-Host ('Al iniciar:   {0}' -f $(if ($s.autostart) { 'sí' } else { 'no (usa "install")' })) }
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

# Tarea programada que aplica la configuración como SYSTEM al iniciar sesión y al
# volver de suspensión o hibernación (el driver vuelve entonces a valores de fábrica).
function Register-AutostartTask([string]$Name, [string]$ScriptPath, [bool]$Disabled) {
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" apply -Unattended' -f $ScriptPath
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $logon = New-ScheduledTaskTrigger -AtLogOn
    $eventTrigger = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
    $resume = New-CimInstance -CimClass $eventTrigger -ClientOnly
    $resume.Enabled = $true
    $resume.Delay = 'PT10S'
    $resume.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">' +
        "*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]" +
        '</Select></Query></QueryList>'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Disable:$Disabled `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $logon, $resume -Principal $principal -Settings $settings -Force
}

function Install-Autostart {
    # La tarea corre como SYSTEM, así que el script se copia a Program Files,
    # donde solo un administrador puede modificarlo, junto a config.json.
    $dir = Get-DataDir
    $target = Join-Path $dir 'uv4070.ps1'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ($PSCommandPath -ne $target) { Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force }
    Register-AutostartTask $TaskName $target $false | Out-Null
    Write-Log 'autostart' @{ op = 'install'; script = $target }
    Write-Host "Se aplicará solo al iniciar sesión y al volver de suspensión. Registro: $dir\uv4070.log"
}

function Uninstall-Autostart {
    if ((Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) -and (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    $dir = Get-DataDir
    foreach ($file in 'uv4070.ps1', 'uv4070.log') {
        $path = Join-Path $dir $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Write-Log 'autostart' @{ op = 'uninstall' }
    Write-Host "Arranque automático eliminado. La configuración sigue en $dir\config.json."
}

# Prueba en este PC, una a una, las piezas que dependen del driver y de Windows.
# Los cambios son mínimos (tope de $SafeMHz MHz, +15 MHz de offset con ese tope,
# 95 % de potencia) y se deshacen al terminar.
function Invoke-SelfTest($Device) {
    $results = New-Object System.Collections.ArrayList
    $add = {
        param([string]$Name, [string]$Status, [string]$Detail, $Data)
        [void]$results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
        Write-Log 'selftest' @{ check = $Name; status = $Status; detail = $Detail; data = $Data }
        $label = @{ ok = 'OK'; fail = 'FALLO'; info = 'INFO' }[$Status]
        $color = @{ ok = 'Green'; fail = 'Red'; info = 'Gray' }[$Status]
        Write-Host ('  {0,-6} {1,-17} {2}' -f $label, $Name, $Detail) -ForegroundColor $color
    }
    $nvmlName = { param($rc) if ($rc -eq 0) { 'correcto' } else { [Uv4070.Nvml]::ErrorString($rc) } }
    Write-Host 'selftest: comprueba el driver, DirectX y Windows en este PC (unos 2 minutos).'
    Write-Host 'Cierra juegos y programas que usen la GPU. Al terminar todo vuelve a como estaba.'
    Write-Host ''

    try {
        $os = Get-OsDescription
        & $add 'entorno' 'info' ('PowerShell {0} {1}, {2}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $os) @{
            ps = $PSVersionTable.PSVersion.ToString(); edition = $PSVersionTable.PSEdition; os = $os; culture = (Get-Culture).Name
        }
        $nvmlVersion = New-Object System.Text.StringBuilder 80
        [void][Uv4070.Nvml]::GetNvmlVersion($nvmlVersion, 80)
        $driver = Get-DriverVersion
        & $add 'driver' 'info' "driver $driver, NVML $nvmlVersion" @{ driver = $driver; nvml = $nvmlVersion.ToString() }

        # Lecturas básicas.
        $reads = [ordered]@{}
        $failedReads = @()
        $readers = [ordered]@{
            coreMHz = { param($o) [Uv4070.Nvml]::GetClock($Device, 0, $o) }
            memMHz = { param($o) [Uv4070.Nvml]::GetClock($Device, 2, $o) }
            tempC = { param($o) [Uv4070.Nvml]::GetTemperature($Device, 0, $o) }
            powerMilliwatts = { param($o) [Uv4070.Nvml]::GetPowerUsage($Device, $o) }
            powerLimitMilliwatts = { param($o) [Uv4070.Nvml]::GetPowerLimit($Device, $o) }
            powerManagementLimitMilliwatts = { param($o) [Uv4070.Nvml]::GetPowerManagementLimit($Device, $o) }
            defaultPowerLimitMilliwatts = { param($o) [Uv4070.Nvml]::GetDefaultPowerLimit($Device, $o) }
            pstate = { param($o) [Uv4070.Nvml]::GetPState($Device, $o) }
        }
        foreach ($name in $readers.Keys) {
            $value = [uint32]0
            $rc = & $readers[$name] ([ref]$value)
            $reads[$name] = [ordered]@{ rc = $rc; value = $(if ($rc -eq 0) { $value }) }
            if ($rc -ne 0) { $failedReads += "$name ($(& $nvmlName $rc))" }
        }
        $reasons = [uint64]0
        $reads.clockReasons = [ordered]@{ rc = [Uv4070.Nvml]::GetClockReasons($Device, [ref]$reasons); value = $reasons }
        if ($failedReads) {
            & $add 'lecturas' 'fail' ('fallan: ' + ($failedReads -join ', ')) $reads
        } else {
            & $add 'lecturas' 'ok' ('núcleo {0} MHz, {1} °C, {2:N1} W' -f $reads.coreMHz.value, $reads.tempC.value, ($reads.powerMilliwatts.value / 1000)) $reads
        }

        # Las dos API de offset, por separado.
        $m = 0; $mMin = 0; $mMax = 0; $l = 0; $lMin = 0; $lMax = 0
        $modernRc = [Uv4070.Nvml]::GetOffsetModern($Device, [ref]$m, [ref]$mMin, [ref]$mMax)
        $legacyRc = [Uv4070.Nvml]::GetOffsetLegacy($Device, [ref]$l, [ref]$lMin, [ref]$lMax)
        $offsetData = [ordered]@{
            modern = [ordered]@{ rc = $modernRc; mhz = $m; min = $mMin; max = $mMax }
            legacy = [ordered]@{ rc = $legacyRc; mhz = $l; min = $lMin; max = $lMax }
        }
        $offsetDetail = 'API moderna: {0}; anterior: {1}' -f
            $(if ($modernRc -eq 0) { "+$m MHz (rango $mMin..$mMax)" } else { & $nvmlName $modernRc }),
            $(if ($legacyRc -eq 0) { "+$l MHz (rango $lMin..$lMax)" } else { & $nvmlName $legacyRc })
        & $add 'lectura-offset' $(if ($modernRc -eq 0 -or $legacyRc -eq 0) { 'ok' } else { 'fail' }) $offsetDetail $offsetData

        # Tope de reloj: sin suelo (0) o con el de 210 MHz.
        $rc0 = [Uv4070.Nvml]::SetLockedClocks($Device, 0, $SafeMHz)
        $rc210 = $null
        if ($rc0 -ne 0) { $rc210 = [Uv4070.Nvml]::SetLockedClocks($Device, 210, $SafeMHz) }
        $capOk = $rc0 -eq 0 -or $rc210 -eq 0
        $capDetail = if ($rc0 -eq 0) { "acepta tope sin suelo (0-$SafeMHz MHz)" } elseif ($rc210 -eq 0) { "necesita suelo de 210 MHz ($(& $nvmlName $rc0) sin él)" } else { 'no acepta topes: ' + (& $nvmlName $rc210) }
        & $add 'tope-reloj' $(if ($capOk) { 'ok' } else { 'fail' }) $capDetail @{ rcNoFloor = $rc0; rcFloor210 = $rc210 }

        # Offset de +15 MHz, solo con el tope puesto (sin tope sería un overclock).
        if ($capOk) {
            $setModern = [Uv4070.Nvml]::SetOffsetModern($Device, 15)
            $setLegacy = $null
            if ($setModern -ne 0) { $setLegacy = [Uv4070.Nvml]::SetOffsetLegacy($Device, 15) }
            $after = Get-CoreOffset $Device
            $back = [Uv4070.Nvml]::SetGraphicsOffset($Device, 0)
            $final = Get-CoreOffset $Device
            $applied = $null -ne $after -and $after.MHz -eq 15
            $restored = $back -eq 0 -and $null -ne $final -and $final.MHz -eq 0
            $via = if ($setModern -eq 0) { 'API moderna' } elseif ($setLegacy -eq 0) { "API anterior (moderna: $(& $nvmlName $setModern))" } else { 'ninguna' }
            $detail = '+15 MHz por {0}, lectura {1}, vuelta a 0: {2}' -f $via, $(if ($after) { "+$($after.MHz) MHz" } else { 'n/d' }), $(if ($restored) { 'sí' } else { 'no' })
            & $add 'escritura-offset' $(if ($applied -and $restored) { 'ok' } else { 'fail' }) $detail @{
                setModern = $setModern; setLegacy = $setLegacy; readback = $(if ($after) { $after.MHz }); reset = $back; readbackAfterReset = $(if ($final) { $final.MHz })
            }
        } else {
            & $add 'escritura-offset' 'fail' 'no se prueba: sin tope de reloj sería un overclock' $null
        }

        # Límite de potencia al 95 % y de vuelta.
        $default = $reads.defaultPowerLimitMilliwatts.value
        if ($null -eq $default) {
            & $add 'potencia' 'info' 'el driver no da el límite de fábrica: -PowerPct no funcionará (tune no lo usa)' $null
        } else {
            try {
                # Se lee el límite configurado: el "en vigor" tarda en reflejar la escritura.
                Set-PowerPct $Device 95 -Quiet
                $at95 = Read-Nvml { param($out) [Uv4070.Nvml]::GetPowerManagementLimit($Device, $out) }
                Set-PowerPct $Device 100 -Quiet
                $at100 = Read-Nvml { param($out) [Uv4070.Nvml]::GetPowerManagementLimit($Device, $out) }
                $ok = $null -ne $at95 -and [math]::Abs($at95 - 0.95 * $default) -le 1000 -and $at100 -eq $default
                & $add 'potencia' $(if ($ok) { 'ok' } else { 'fail' }) ('95 %: {0:N0} W, 100 %: {1:N0} W' -f ($at95 / 1000), ($at100 / 1000)) @{ at95 = $at95; at100 = $at100; default = $default }
            } catch {
                & $add 'potencia' 'fail' $_.Exception.Message $null
            }
        }

        # Test de estrés DirectX 11.
        $engine = $null
        try {
            $engine = Get-Engine $Device
            & $add 'directx11' 'ok' ('{0} iteraciones, {1:N1} ms por dispatch' -f $engine.Iterations, $engine.DispatchMs) @{ iterations = $engine.Iterations; dispatchMs = $engine.DispatchMs }
        } catch {
            $e = $_.Exception
            while ($e.InnerException) { $e = $e.InnerException }
            & $add 'directx11' 'fail' $e.Message $null
        }
        if ($engine) {
            $r = Invoke-Step $Device $SafeMHz 0 5
            $capHolds = -not $r.Failure -and $r.ClockMHz -le $SafeMHz + 15
            & $add 'tope-efectivo' $(if ($capHolds) { 'ok' } else { 'fail' }) ('con tope {0} MHz y carga máxima: {1:N0} MHz' -f $SafeMHz, $r.ClockMHz) (ConvertTo-LogResult $r)

            $r = Invoke-Step $Device 0 0 10
            $p0 = -not $r.Failure -and ($r.P0Pct -lt 0 -or $r.P0Pct -ge 90)
            $detail = if ($r.Failure) { "de serie: $($r.Failure)" } else {
                'P0 {0:N0} %, {1:N0} MHz, {2:N0} W, {3} °C, limitado por potencia {4:N0} %, {5:N1} TFLOPS' -f
                    $r.P0Pct, $r.ClockMHz, $r.Watts, $r.MaxTempC, $r.PowerCappedPct, $r.Tflops
            }
            & $add 'carga-de-serie' $(if ($p0) { 'ok' } else { 'fail' }) $detail (ConvertTo-LogResult $r)

            $r = Invoke-Step $Device 0 0 6 ([Uv4070.Stress]::Light)
            # tune saca el tope de este reloj: si la GPU no se queda en P0 con carga ligera, no sirve.
            $boostOk = -not $r.Failure -and ($r.P0Pct -lt 0 -or $r.P0Pct -ge 90)
            $boostDetail = if ($r.Failure) { $r.Failure } else { '{0:N0} MHz con carga ligera (P0 {1:N0} %)' -f $r.ClockMHz, $r.P0Pct }
            & $add 'reloj-maximo' $(if ($boostOk) { 'ok' } else { 'fail' }) $boostDetail (ConvertTo-LogResult $r)

            $r = Invoke-Step $Device 0 0 6 ([Uv4070.Stress]::Pulses)
            & $add 'pulsos' $(if ($r.Failure) { 'fail' } else { 'ok' }) $(if ($r.Failure) { $r.Failure } else { 'carga y reposo sin errores' }) (ConvertTo-LogResult $r)

            # El detector tiene que ver un fallo cuando los resultados no cuadran.
            $engine.Iterations += 8
            $bad = $engine.Run(1, $Device, [Uv4070.Stress]::Steady)
            $engine.Iterations -= 8
            $good = $engine.Run(1, $Device, [Uv4070.Stress]::Steady)
            $detects = $bad.Errors -gt 0 -and -not $good.Failure
            & $add 'deteccion-errores' $(if ($detects) { 'ok' } else { 'fail' }) ('fallo simulado: {0} hilos erróneos; después: {1}' -f $bad.Errors, $(if ($good.Failure) { $good.Failure } else { 'sin errores' })) @{
                simulated = (ConvertTo-LogResult $bad); after = (ConvertTo-LogResult $good)
            }
        }

        # Test de ray tracing (DirectX 12, DXR 1.1).
        $rt = $null
        try {
            $rt = Get-RtEngine $Device
            & $add 'raytracing' 'ok' ('{0} rayos por hilo, {1:N1} ms por dispatch' -f $rt.Iterations, $rt.DispatchMs) @{ iterations = $rt.Iterations; dispatchMs = $rt.DispatchMs }
        } catch {
            $e = $_.Exception
            while ($e.InnerException) { $e = $e.InnerException }
            & $add 'raytracing' 'fail' $e.Message $null
        }
        if ($rt) {
            $r = Invoke-Step $Device $SafeMHz 0 4 $RtMode
            & $add 'carga-rt' $(if ($r.Failure) { 'fail' } else { 'ok' }) $(if ($r.Failure) { $r.Failure } else { 'con tope {0} MHz: {1:N0} MHz, {2:N0} W, sin errores' -f $SafeMHz, $r.ClockMHz, $r.Watts }) (ConvertTo-LogResult $r)
            $rt.Iterations += 1
            $bad = $rt.Run(1, $Device, [Uv4070.Stress]::Steady)
            $rt.Iterations -= 1
            $good = $rt.Run(1, $Device, [Uv4070.Stress]::Steady)
            $detects = $bad.Errors -gt 0 -and -not $good.Failure
            & $add 'deteccion-rt' $(if ($detects) { 'ok' } else { 'fail' }) ('fallo simulado: {0} hilos erróneos; después: {1}' -f $bad.Errors, $(if ($good.Failure) { $good.Failure } else { 'sin errores' })) @{
                simulated = (ConvertTo-LogResult $bad); after = (ConvertTo-LogResult $good)
            }
        }

        # Registro de eventos de Windows (reinicios del driver).
        $search = Search-DriverResets (Get-Date).AddDays(-30)
        if ($search.Ok) {
            $recent = @($search.Events | Select-Object -First 10 | ForEach-Object { [ordered]@{ time = $_.TimeCreated.ToString('o'); provider = $_.ProviderName; id = $_.Id } })
            & $add 'registro-eventos' 'ok' ('{0} reinicios del driver en los últimos 30 días' -f @($search.Events).Count) @{ resets = $recent }
        } else {
            & $add 'registro-eventos' $(if ($OnWindows) { 'fail' } else { 'info' }) $search.Error $null
        }

        # Tarea programada como la de install, pero desactivada y temporal. Apunta a la copia de
        # Program Files (exista o no): una tarea SYSTEM nunca debe señalar a una carpeta del usuario.
        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
            try {
                $task = Register-AutostartTask 'uv4070-selftest' (Join-Path (Get-DataDir) 'uv4070.ps1') $true
                $ok = @($task.Triggers).Count -eq 2 -and $task.Principal.UserId -eq 'SYSTEM'
                & $add 'tarea-programada' $(if ($ok) { 'ok' } else { 'fail' }) ('{0} disparadores, usuario {1}' -f @($task.Triggers).Count, $task.Principal.UserId) $null
            } catch {
                & $add 'tarea-programada' 'fail' $_.Exception.Message $null
            } finally {
                Unregister-ScheduledTask -TaskName 'uv4070-selftest' -Confirm:$false -ErrorAction SilentlyContinue
            }
        } else {
            & $add 'tarea-programada' 'info' 'no disponible fuera de Windows' $null
        }
    } finally {
        Close-Engine
        $saved = $null
        try { $saved = Read-Config } catch { }
        if ($saved) { Invoke-Apply $Device $saved } else { [void](Reset-Stock $Device) }
    }

    $script:SelfTestResults = $results
    $fails = @($results | Where-Object Status -eq 'fail')
    Write-Log 'selftest-summary' @{ ok = @($results | Where-Object Status -eq 'ok').Count; fail = $fails.Count; checks = @($results) }
    Write-Host ''
    if ($fails.Count) {
        throw "$($fails.Count) comprobación(es) con FALLO. Ejecuta .\uv4070.cmd report y comparte el archivo para revisarlo."
    }
    Write-Host 'Todo correcto: tune, stress y apply deberían funcionar en este PC.' -ForegroundColor Green
}

# Junta en un archivo JSON el estado, la configuración, el último tune y los
# registros más recientes, para revisarlo o refinar el ajuste (también con una IA).
function Export-Report($Device, [string]$OpenError) {
    $dir = Get-DataDir
    $readJson = { param($name) $path = Join-Path $dir $name; if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } }
    $logs = @()
    $logDir = Join-Path $dir 'logs'
    if (Test-Path -LiteralPath $logDir) {
        # Los 3 últimos de cada comando (el nombre es yyyyMMdd-HHmmss-<comando>.jsonl), para que
        # los apply del arranque no dejen fuera el último tune.
        $recent = Get-ChildItem -LiteralPath $logDir -Filter '*.jsonl' | Where-Object { $_.BaseName -match '^\d{8}-\d{6}-.' } |
            Group-Object { $_.BaseName -replace '^\d{8}-\d{6}-', '' } |
            ForEach-Object { $_.Group | Sort-Object Name -Descending | Select-Object -First 3 }
        foreach ($file in ($recent | Sort-Object Name)) {
            $events = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 | Where-Object { $_ } | ForEach-Object {
                try { $_ | ConvertFrom-Json } catch { [pscustomobject]@{ unparsed = $_ } }
            })
            $logs += [ordered]@{ file = $file.Name; events = $events }
        }
    }
    $transcript = Join-Path $dir 'uv4070.log'
    $autostartLog = $null
    if (Test-Path -LiteralPath $transcript) {
        # Sin la cabecera ni el pie de Start-Transcript, que traen usuario y nombre del equipo con
        # etiquetas en el idioma de Windows: son los bloques entre líneas de asteriscos.
        $kept = @()
        $inBlock = $false
        foreach ($line in @(Get-Content -LiteralPath $transcript -Encoding UTF8)) {
            if ($line -match '^\*{10,}\s*$') { $inBlock = -not $inBlock; continue }
            if (-not $inBlock) { $kept += $line }
        }
        $autostartLog = $kept -join "`n"
    }
    $report = [ordered]@{
        about = ('Informe de uv4070 ' + $ScriptVersion + ', undervolt de una RTX 4070 por NVML: tope de reloj (cap, MHz) + ' +
            'offset de la curva V/F (offset, MHz). status = estado actual; tuneReport = resultado del último tune ' +
            '(stock = de serie, final = configuración elegida); tuneState = tune a medias; autostartLog = última ' +
            'ejecución de la tarea de inicio; logs = registros JSONL recientes, uno por comando. Eventos: session, gpu, ' +
            'nvml (escrituras: op, rc 0 = correcto, readback), engine, load (cap 0 = de serie, mode steady/pulses/light, ' +
            'result.failure null = estable, p0Pct, powerCappedPct = % del tiempo limitado por potencia), tune-* ' +
            '(decisiones del ajuste), selftest, error y end.')
        generated = (Get-Date).ToString('o')
        environment = [ordered]@{ ps = $PSVersionTable.PSVersion.ToString(); edition = $PSVersionTable.PSEdition; os = (Get-OsDescription) }
        status = $(if ($Device) { Get-StatusInfo $Device } else { [ordered]@{ error = $OpenError } })
        tuneReport = (& $readJson 'tune-report.json')
        tuneState = (& $readJson 'tune-state.json')
        autostartLog = $autostartLog
        logs = $logs
    }
    $json = $report | ConvertTo-Json -Depth 10
    # Sin el nombre de usuario en las rutas (p. ej. en los errores), ni el nombre del equipo o del
    # usuario sueltos (p. ej. en mensajes). Los nombres de menos de 3 letras se dejan: serían falsos positivos.
    if ($env:USERNAME) { $json = $json -replace ('(?i)(\\\\Users\\\\)' + [regex]::Escape($env:USERNAME)), '$1%USERNAME%' }
    foreach ($name in 'COMPUTERNAME', 'USERNAME') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value -and $value.Length -ge 3) { $json = $json -replace ('(?i)\b' + [regex]::Escape($value) + '\b'), "%$name%" }
    }
    $path = Join-Path (Get-Location).Path ('uv4070-report-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))
    Write-Host "Informe guardado en: $path"
    Write-Host 'Lleva el estado, la configuración, el último tune y los registros recientes, sin tu usuario ni el nombre'
    Write-Host 'del equipo. Puedes adjuntarlo tal cual a una IA o a quien te ayude a revisar o afinar el ajuste.'
}

# Al cargarlo con ". .\uv4070.ps1" solo se definen las funciones (lo usan las pruebas).
if ($MyInvocation.InvocationName -eq '.') { return }

$script:NvmlOpen = $false
$exitCode = 0
$started = Get-Date
$readOnly = $Command -in 'status', 'monitor', 'report'
if ($Unattended) {
    $logDir = Get-DataDir
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Start-Transcript -Path (Join-Path $logDir 'uv4070.log') -Force | Out-Null
}
try {
    if (-not $readOnly) {
        Assert-Admin
        Start-Log $Command
        $arguments = @{}
        foreach ($key in $Bound.Keys) { $arguments[$key] = "$($Bound[$key])" }
        Write-Log 'session' @{
            version = $ScriptVersion; command = $Command; arguments = $arguments
            ps = $PSVersionTable.PSVersion.ToString(); edition = $PSVersionTable.PSEdition; os = (Get-OsDescription)
        }
    }
    # Antes de abrir la GPU, para que funcione aunque ya no haya una 4070.
    if ($Command -eq 'uninstall') {
        Uninstall-Autostart
        # Sin la 4070 (por ejemplo tras cambiar de tarjeta) no queda nada que restaurar.
        $device = $null
        try { $device = Open-Rtx4070 $false } catch { Write-Warning "No se restauran valores de fábrica: $($_.Exception.Message)" }
        if ($device) { Invoke-Reset $device }
    } elseif ($Command -eq 'report') {
        $device = $null
        $openError = $null
        try { $device = Open-Rtx4070 $false } catch { $openError = $_.Exception.Message }
        Export-Report $device $openError
    } else {
        $device = Open-Rtx4070 $Unattended.IsPresent
        Write-Log 'gpu' @{ name = $GpuName; driver = (Get-DriverVersion) }
        switch ($Command) {
            'status'   { Show-Status $device }
            'monitor'  { Show-Monitor $device $Samples }
            'selftest' { Invoke-SelfTest $device }
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
            'reset'    { Invoke-Reset $device }
        }
    }
} catch {
    # El mensaje útil de una excepción .NET va en la más interna.
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    Write-Host ('ERROR: ' + $e.Message) -ForegroundColor Red
    Write-Log 'error' @{ message = $e.Message; type = $e.GetType().FullName; at = $_.InvocationInfo.PositionMessage; stack = $_.ScriptStackTrace }
    $exitCode = 1
} finally {
    Close-Engine
    if ($script:NvmlOpen) { [void][Uv4070.Nvml]::Shutdown() }
    Write-Log 'end' @{ exitCode = $exitCode; seconds = [math]::Round(((Get-Date) - $started).TotalSeconds) }
    if ($script:LogPath -and -not $Unattended) { Write-Host "Registro (JSON Lines): $script:LogPath" }
    if ($Unattended) { Stop-Transcript | Out-Null }
}
exit $exitCode
