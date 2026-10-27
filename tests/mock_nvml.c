// NVML simulado para probar uv4070.ps1 en Linux con PowerShell 7.
//
// Variables de entorno:
//   MOCK_NVML_STATE  fichero con el estado del "driver" entre procesos
//   MOCK_NVML_LOG    fichero donde se anotan las escrituras, en orden
//   MOCK_NVML_NAMES  nombres de GPU separados por ';'
//   MOCK_NVML_FAIL   fallos simulados separados por ',':
//                    lock, lock0 (rechaza mínimo 0), offset, offsetsnap, power
//                    (desde el propio proceso: mockSetFail, porque .NET no cambia
//                    el entorno que ve getenv)
//
// Compilado con -DLEGACY_ONLY no exporta la API moderna de offsets.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif

#define OK 0
#define INVALID_ARGUMENT 2
#define NOT_SUPPORTED 3
#define ARGUMENT_VERSION_MISMATCH 25

typedef struct { unsigned version, type, pstate; int offset, min, max; } ClockOffset;
typedef struct { unsigned gpu, memory; } Utilization;
typedef struct { int offset; unsigned lockMin, lockMax, powerLimit; } State;

static const char* env(const char* key, const char* fallback) {
    const char* v = getenv(key);
    return v && *v ? v : fallback;
}

static char failOverride[256];
static int failOverrideSet;

EXPORT void mockSetFail(const char* flags) {
    snprintf(failOverride, sizeof failOverride, "%s", flags ? flags : "");
    failOverrideSet = 1;
}

static int failing(const char* flag) {
    char list[300];
    snprintf(list, sizeof list, ",%s,", failOverrideSet ? failOverride : env("MOCK_NVML_FAIL", ""));
    char needle[64];
    snprintf(needle, sizeof needle, ",%s,", flag);
    return strstr(list, needle) != NULL;
}

static State load(void) {
    State s = { 0, 0, 0, 200000 };
    FILE* f = fopen(env("MOCK_NVML_STATE", "/tmp/mock_nvml_state"), "r");
    if (f) {
        if (fscanf(f, "%d %u %u %u", &s.offset, &s.lockMin, &s.lockMax, &s.powerLimit) != 4) {
            s.offset = 0; s.lockMin = 0; s.lockMax = 0; s.powerLimit = 200000;
        }
        fclose(f);
    }
    return s;
}

static void save(State s) {
    FILE* f = fopen(env("MOCK_NVML_STATE", "/tmp/mock_nvml_state"), "wb");
    if (f) { fprintf(f, "%d %u %u %u\n", s.offset, s.lockMin, s.lockMax, s.powerLimit); fclose(f); }
}

static void note(const char* fmt, ...) {
    FILE* f = fopen(env("MOCK_NVML_LOG", "/tmp/mock_nvml_log"), "ab");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static int set_offset(int mhz) {
    if (failing("offset")) return NOT_SUPPORTED;
    if (mhz < -1000 || mhz > 1000) return INVALID_ARGUMENT;
    State s = load();
    s.offset = failing("offsetsnap") && mhz ? mhz - 5 : mhz;
    save(s);
    return OK;
}

EXPORT int nvmlInit_v2(void) { return OK; }
EXPORT int nvmlShutdown(void) { return OK; }

EXPORT const char* nvmlErrorString(int r) {
    switch (r) {
        case OK: return "Success";
        case INVALID_ARGUMENT: return "Invalid Argument";
        case NOT_SUPPORTED: return "Not Supported";
        case ARGUMENT_VERSION_MISMATCH: return "Argument version mismatch";
        default: return "Unknown Error";
    }
}

EXPORT int nvmlSystemGetDriverVersion(char* out, unsigned len) { snprintf(out, len, "566.36"); return OK; }
EXPORT int nvmlSystemGetNVMLVersion(char* out, unsigned len) { snprintf(out, len, "12.566.36"); return OK; }

EXPORT int nvmlDeviceGetCount_v2(unsigned* count) {
    const char* names = env("MOCK_NVML_NAMES", "NVIDIA GeForce RTX 4070");
    *count = 1;
    for (const char* p = names; *p; p++) if (*p == ';') (*count)++;
    return OK;
}

EXPORT int nvmlDeviceGetHandleByIndex_v2(unsigned index, void** device) { *device = (void*)(size_t)(index + 1); return OK; }

EXPORT int nvmlDeviceGetName(void* device, char* out, unsigned len) {
    char names[512];
    snprintf(names, sizeof names, "%s", env("MOCK_NVML_NAMES", "NVIDIA GeForce RTX 4070"));
    char* name = strtok(names, ";");
    for (size_t i = 1; name && i < (size_t)device; i++) name = strtok(NULL, ";");
    snprintf(out, len, "%s", name ? name : "?");
    return OK;
}

EXPORT int nvmlDeviceGetClockInfo(void* d, unsigned type, unsigned* mhz) {
    State s = load();
    *mhz = type == 2 ? 10501 : (s.lockMax && s.lockMax < 2805 ? s.lockMax : 2805);
    return OK;
}

EXPORT int nvmlDeviceGetTemperature(void* d, unsigned sensor, unsigned* c) { *c = 58; return OK; }
EXPORT int nvmlDeviceGetPowerUsage(void* d, unsigned* mw) { *mw = 151234; return OK; }
EXPORT int nvmlDeviceGetEnforcedPowerLimit(void* d, unsigned* mw) { *mw = load().powerLimit; return OK; }
EXPORT int nvmlDeviceGetPowerManagementLimit(void* d, unsigned* mw) { *mw = load().powerLimit; return OK; }
EXPORT int nvmlDeviceGetPowerManagementDefaultLimit(void* d, unsigned* mw) { *mw = 200000; return OK; }
EXPORT int nvmlDeviceGetPowerManagementLimitConstraints(void* d, unsigned* mn, unsigned* mx) { *mn = 120000; *mx = 220000; return OK; }

EXPORT int nvmlDeviceSetPowerManagementLimit(void* d, unsigned mw) {
    note("power %u", mw);
    if (failing("power")) return NOT_SUPPORTED;
    if (mw < 120000 || mw > 220000) return INVALID_ARGUMENT;
    State s = load();
    s.powerLimit = mw;
    save(s);
    return OK;
}

EXPORT int nvmlDeviceGetUtilizationRates(void* d, Utilization* u) { u->gpu = 97; u->memory = 41; return OK; }
EXPORT int nvmlDeviceGetPerformanceState(void* d, unsigned* p) { *p = 0; return OK; }
// Limitada por potencia (0x4) solo de serie: con un tope de reloj se queda por debajo del límite.
EXPORT int nvmlDeviceGetCurrentClocksEventReasons(void* d, unsigned long long* r) { *r = load().lockMax ? 0 : 0x4; return OK; }

EXPORT int nvmlDeviceSetGpuLockedClocks(void* d, unsigned mn, unsigned mx) {
    note("lock %u %u", mn, mx);
    if (failing("lock") || (failing("lock0") && mn == 0)) return NOT_SUPPORTED;
    State s = load();
    s.lockMin = mn;
    s.lockMax = mx;
    save(s);
    return OK;
}

EXPORT int nvmlDeviceResetGpuLockedClocks(void* d) {
    note("unlock");
    State s = load();
    s.lockMin = s.lockMax = 0;
    save(s);
    return OK;
}

#ifndef LEGACY_ONLY
EXPORT int nvmlDeviceGetClockOffsets(void* d, ClockOffset* o) {
    if (o->version != (sizeof(ClockOffset) | (1u << 24))) return ARGUMENT_VERSION_MISMATCH;
    if (o->type != 0 || o->pstate != 0) return INVALID_ARGUMENT;
    o->offset = load().offset;
    o->min = -1000;
    o->max = 1000;
    return OK;
}

EXPORT int nvmlDeviceSetClockOffsets(void* d, ClockOffset* o) {
    if (o->version != (sizeof(ClockOffset) | (1u << 24))) return ARGUMENT_VERSION_MISMATCH;
    if (o->type != 0 || o->pstate != 0) return INVALID_ARGUMENT;
    note("offset %d", o->offset);
    return set_offset(o->offset);
}
#endif

EXPORT int nvmlDeviceGetGpcClkVfOffset(void* d, int* mhz) { *mhz = load().offset; return OK; }
EXPORT int nvmlDeviceGetGpcClkMinMaxVfOffset(void* d, int* mn, int* mx) { *mn = -1000; *mx = 1000; return OK; }

EXPORT int nvmlDeviceSetGpcClkVfOffset(void* d, int mhz) {
    note("legacy-offset %d", mhz);
    return set_offset(mhz);
}
