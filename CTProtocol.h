#ifndef CT_PROTOCOL_H
#define CT_PROTOCOL_H
#include <stdint.h>
// Upper 30 bits identify the bundle; next 32 bits bind its process;
// low 2 bits are reserved for the server result. Not an authentication token.
static inline uint64_t CTKey(const char *bundle, int pid) {
    if (!bundle || !*bundle || pid <= 1) return 0;
    uint32_t hash = 2166136261u;
    for (const unsigned char *p = (const unsigned char *)bundle; *p; ++p) hash = (hash ^ *p) * 16777619u;
    return ((uint64_t)(hash & 0x3fffffffu) << 34) | ((uint64_t)(uint32_t)pid << 2);
}
static inline int CTValidKey(uint64_t key) { return !(key & 3) && (uint32_t)(key >> 2) > 1 && (uint32_t)(key >> 2) <= INT32_MAX; }
// Sample: signed API PID + kernel existence of original/current PID.
// States: 0 absent (ESRCH), 1 exists (including EPERM), 2 unknown.
static inline uint64_t CTMakeSample(int pid, unsigned oldState, unsigned currentState) {
    return ((uint64_t)(uint32_t)pid << 32) | 16 | (oldState & 3) | ((currentState & 3) << 2);
}
static inline int CTSampleStopped(uint64_t value) {
    int pid = (int32_t)(value >> 32);
    return (value & 16) && (value & 3) == 0 &&
        (pid == 0 || (pid > 1 && ((value >> 2) & 3) == 0));
}
// UI evidence is separate from full-stop success: an API error must not
// hide a confirmed old-process exit, nor be promoted to proof of no new process.
enum { CTOutcomeUnknown, CTOutcomeStopped, CTOutcomeNewProcess, CTOutcomeOldExited };
static inline int CTOutcome(uint64_t sample, int original) {
    if (!(sample & 16)) return CTOutcomeUnknown;
    int pid = (int32_t)(sample >> 32);
    if (pid > 1 && pid != original && ((sample >> 2) & 3) == 1) return CTOutcomeNewProcess;
    if (CTSampleStopped(sample)) return CTOutcomeStopped;
    if ((sample & 3) == 0) return CTOutcomeOldExited;
    return CTOutcomeUnknown;
}
#endif
