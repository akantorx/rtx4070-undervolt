// Prueba el test de estrés (clase Uv4070.Stress de uv4070.ps1) bajo Wine.
// Uso: stress_harness.exe "<nombre del adaptador DirectX>" [nvml]
using System;
using Uv4070;

static class Harness {
    static int failures;

    static void Check(bool ok, string what) {
        Console.WriteLine((ok ? "ok    " : "FALLO ") + what);
        if (!ok) failures++;
    }

    static string Describe(StressResult r) {
        return string.Format("lotes={0} errores={1} perdido={2} fallo={3} tflops={4:F3} low={5:F3} W={6:F1} MHz={7:F0} P0={8:F0}%",
            r.Batches, r.Errors, r.DeviceLost, r.Failure ?? "-", r.Tflops, r.LowTflops, r.Watts, r.ClockMHz, r.P0Pct);
    }

    static int Main(string[] args) {
        IntPtr nvml = IntPtr.Zero;
        if (args.Length > 1 && args[1] == "nvml") {
            uint count;
            Check(Nvml.Init() == 0 && Nvml.GetCount(out count) == 0 && Nvml.GetHandleByIndex(0, out nvml) == 0, "NVML simulado abierto");
        }

        try {
            Stress.Open("NVIDIA GeForce RTX 4070 SUPER").Dispose();
            Check(false, "un adaptador que no existe se rechaza");
        } catch (InvalidOperationException e) {
            Check(e.Message.Contains("DirectX no encuentra") && e.Message.Contains(args[0]), "un adaptador que no existe se rechaza: " + e.Message);
        }

        using (Stress s = Stress.Open(args[0])) {
            s.Calibrate(15);
            Console.WriteLine("      iteraciones=" + s.Iterations + " ms/dispatch=" + s.DispatchMs.ToString("F1"));
            Check(s.Iterations >= 64 && s.DispatchMs > 0, "calibración");
            s.CaptureReference();
            Check(true, "referencia repetible");

            StressResult r = s.Run(3, nvml, Stress.Steady);
            Console.WriteLine("      " + Describe(r));
            Check(r.Failure == null && r.Errors == 0 && r.Batches > 2 && r.Tflops > 0 && r.LowTflops > 0 && r.LowTflops <= r.Tflops,
                "carga sostenida sin errores");
            if (nvml != IntPtr.Zero) Check(Math.Abs(r.Watts - 151.234) < 0.01 && r.P0Pct == 100 && r.PowerCappedPct == 100, "lecturas NVML durante la carga");

            r = s.Run(4, nvml, Stress.Pulses);
            Console.WriteLine("      " + Describe(r));
            Check(r.Failure == null && r.Batches > 0, "modo pulsos sin errores");

            r = s.Run(3, nvml, Stress.Light);
            Console.WriteLine("      " + Describe(r));
            Check(r.Failure == null && r.Batches > 0, "modo carga ligera sin errores");

            // Fallo simulado: con una iteración más, ningún hash coincide con la referencia.
            s.Iterations += 1;
            r = s.Run(2, nvml, Stress.Steady);
            Console.WriteLine("      " + Describe(r));
            Check(r.Failure == "errores de cálculo" && r.Errors >= Stress.Threads, "detecta resultados erróneos");
            s.Iterations -= 1;
            r = s.Run(2, nvml, Stress.Steady);
            Check(r.Failure == null, "vuelve a pasar con los parámetros correctos");
            s.Dispose();
            r = s.Run(1, nvml, Stress.Steady);
            Check(s.Lost && r.Failure != null, "tras Dispose, Run da un fallo en vez de usar punteros liberados");
        }

        Console.WriteLine(failures == 0 ? "Todas las pruebas del test de estrés pasan." : failures + " prueba(s) fallida(s)");
        return failures == 0 ? 0 : 1;
    }
}
