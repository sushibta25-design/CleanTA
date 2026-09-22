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
#endif
