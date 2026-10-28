/* Virtual-memory and alignment helpers shared by the arena members.
 * Internal: not part of the interface in arena.h. Static inline, so each
 * member that includes it carries only the helpers it calls. */
#ifndef ORBIT_RT_ARENA_VM_H
#define ORBIT_RT_ARENA_VM_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <sys/mman.h>
#include <unistd.h>
#endif

/* ── Virtual Memory Abstraction ──────────────────────────────────────── */

static inline size_t orbit_get_page_size(void) {
#ifdef _WIN32
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (size_t)si.dwPageSize;
#else
    long sz = sysconf(_SC_PAGESIZE);
    return sz > 0 ? (size_t)sz : 4096;
#endif
}

static inline void* orbit_virtual_reserve(size_t size) {
#ifdef _WIN32
    return VirtualAlloc(NULL, size, MEM_RESERVE, PAGE_NOACCESS);
#else
    void* addr = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return (addr == MAP_FAILED) ? NULL : addr;
#endif
}

static inline bool orbit_virtual_commit(void* addr, size_t size) {
    if (!addr || size == 0) return true;
#ifdef _WIN32
    return VirtualAlloc(addr, size, MEM_COMMIT, PAGE_READWRITE) != NULL;
#else
    return mprotect(addr, size, PROT_READ | PROT_WRITE) == 0;
#endif
}

static inline void orbit_virtual_decommit(void* addr, size_t size) {
    if (!addr || size == 0) return;
#ifdef _WIN32
    VirtualFree(addr, size, MEM_DECOMMIT);
#else
#ifdef MADV_DONTNEED
    madvise(addr, size, MADV_DONTNEED);
#endif
    mprotect(addr, size, PROT_NONE);
#endif
}

static inline void orbit_virtual_release(void* addr, size_t size) {
    if (!addr || size == 0) return;
#ifdef _WIN32
    VirtualFree(addr, 0, MEM_RELEASE);
#else
    munmap(addr, size);
#endif
}

/* ── Safe Overflow Checked Helpers ───────────────────────────────────── */

static inline size_t orbit_align_up(size_t size, size_t alignment) {
    if (size > SIZE_MAX - (alignment - 1)) {
        return 0; // Overflow
    }
    return (size + (alignment - 1)) & ~(alignment - 1);
}

#endif
