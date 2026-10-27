// NVML simulado para probar uv4070.ps1 en Linux con PowerShell 7.
//
// Variables de entorno:
//   MOCK_NVML_STATE  fichero con el estado del "driver" entre procesos
//   MOCK_NVML_LOG    fichero donde se anotan las escrituras, en orden
//   MOCK_NVML_NAMES  nombres de GPU separados por ';'
//   MOCK_NVML_FAIL   fallos simulados separados por ',':
//                    lock, lock0 (rechaza mínimo 0), offset, offsetsnap, power
//
// Compilado con -DLEGACY_ONLY no exporta la API moderna de offsets.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

static int failing(const char* flag) {
    char list[256];
    snprintf(list, sizeof list, ",%s,", env("MOCK_NVML_FAIL", ""));
    char needle[64];
    snprintf(needle, sizeof needle, ",%s,", flag);
    return strstr(list, needle) != NULL;
}

static State load(void) {
    State s = { 0, 0, 0, 200000 };
    FILE* f = fopen(env("MOCK_NVML_STATE", "/tmp/mock_nvml_state"), "r");
    if (f) {
        if (fscanf(f, "%d %u %u %u", &s.offset, &s.lockMin, &s.lockMax, &s.powerLimit) != 4) s = (State){ 0, 0, 0, 200000 };
        fclose(f);
    }
    return s;
}

static void save(State s) {
    FILE* f = fopen(env("MOCK_NVML_STATE", "/tmp/mock_nvml_state"), "w");
    if (f) { fprintf(f, "%d %u %u %u\n", s.offset, s.lockMin, s.lockMax, s.powerLimit); fclose(f); }
}

static void note(const char* fmt, ...) {
    FILE* f = fopen(env("MOCK_NVML_LOG", "/tmp/mock_nvml_log"), "a");
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

int nvmlInit_v2(void) { return OK; }
int nvmlShutdown(void) { return OK; }

const char* nvmlErrorString(int r) {
    switch (r) {
        case OK: return "Success";
        case INVALID_ARGUMENT: return "Invalid Argument";
        case NOT_SUPPORTED: return "Not Supported";
        case ARGUMENT_VERSION_MISMATCH: return "Argument version mismatch";
        default: return "Unknown Error";
    }
}

int nvmlSystemGetDriverVersion(char* out, unsigned len) { snprintf(out, len, "566.36"); return OK; }

int nvmlDeviceGetCount_v2(unsigned* count) {
    const char* names = env("MOCK_NVML_NAMES", "NVIDIA GeForce RTX 4070");
    *count = 1;
    for (const char* p = names; *p; p++) if (*p == ';') (*count)++;
    return OK;
}

int nvmlDeviceGetHandleByIndex_v2(unsigned index, void** device) { *device = (void*)(size_t)(index + 1); return OK; }

int nvmlDeviceGetName(void* device, char* out, unsigned len) {
    char names[512];
    snprintf(names, sizeof names, "%s", env("MOCK_NVML_NAMES", "NVIDIA GeForce RTX 4070"));
    char* name = strtok(names, ";");
    for (size_t i = 1; name && i < (size_t)device; i++) name = strtok(NULL, ";");
    snprintf(out, len, "%s", name ? name : "?");
    return OK;
}

int nvmlDeviceGetClockInfo(void* d, unsigned type, unsigned* mhz) {
    State s = load();
    *mhz = type == 2 ? 10501 : (s.lockMax && s.lockMax < 2805 ? s.lockMax : 2805);
    return OK;
}

int nvmlDeviceGetTemperature(void* d, unsigned sensor, unsigned* c) { *c = 58; return OK; }
int nvmlDeviceGetPowerUsage(void* d, unsigned* mw) { *mw = 151234; return OK; }
int nvmlDeviceGetEnforcedPowerLimit(void* d, unsigned* mw) { *mw = load().powerLimit; return OK; }
int nvmlDeviceGetPowerManagementDefaultLimit(void* d, unsigned* mw) { *mw = 200000; return OK; }
int nvmlDeviceGetPowerManagementLimitConstraints(void* d, unsigned* mn, unsigned* mx) { *mn = 120000; *mx = 220000; return OK; }

int nvmlDeviceSetPowerManagementLimit(void* d, unsigned mw) {
    note("power %u", mw);
    if (failing("power")) return NOT_SUPPORTED;
    if (mw < 120000 || mw > 220000) return INVALID_ARGUMENT;
    State s = load();
    s.powerLimit = mw;
    save(s);
    return OK;
}

int nvmlDeviceGetUtilizationRates(void* d, Utilization* u) { u->gpu = 97; u->memory = 41; return OK; }
int nvmlDeviceGetPerformanceState(void* d, unsigned* p) { *p = 0; return OK; }
int nvmlDeviceGetCurrentClocksEventReasons(void* d, unsigned long long* r) { *r = 0x4; return OK; }

int nvmlDeviceSetGpuLockedClocks(void* d, unsigned mn, unsigned mx) {
    note("lock %u %u", mn, mx);
    if (failing("lock") || (failing("lock0") && mn == 0)) return NOT_SUPPORTED;
    State s = load();
    s.lockMin = mn;
    s.lockMax = mx;
    save(s);
    return OK;
}

int nvmlDeviceResetGpuLockedClocks(void* d) {
    note("unlock");
    State s = load();
    s.lockMin = s.lockMax = 0;
    save(s);
    return OK;
}

#ifndef LEGACY_ONLY
int nvmlDeviceGetClockOffsets(void* d, ClockOffset* o) {
    if (o->version != (sizeof(ClockOffset) | (1u << 24))) return ARGUMENT_VERSION_MISMATCH;
    if (o->type != 0 || o->pstate != 0) return INVALID_ARGUMENT;
    o->offset = load().offset;
    o->min = -1000;
    o->max = 1000;
    return OK;
}

int nvmlDeviceSetClockOffsets(void* d, ClockOffset* o) {
    if (o->version != (sizeof(ClockOffset) | (1u << 24))) return ARGUMENT_VERSION_MISMATCH;
    if (o->type != 0 || o->pstate != 0) return INVALID_ARGUMENT;
    note("offset %d", o->offset);
    return set_offset(o->offset);
}
#endif

int nvmlDeviceGetGpcClkVfOffset(void* d, int* mhz) { *mhz = load().offset; return OK; }
int nvmlDeviceGetGpcClkMinMaxVfOffset(void* d, int* mn, int* mx) { *mn = -1000; *mx = 1000; return OK; }

int nvmlDeviceSetGpcClkVfOffset(void* d, int mhz) {
    note("legacy-offset %d", mhz);
    return set_offset(mhz);
}
