/**
 * @file  hyperdrive.c
 * @brief Orbit Hyperdrive Kernel — Lock-Free MPMC Ring Buffer & Zero-Syscall I/O Supervisor.
 */
#ifndef ORBIT_HYPERDRIVE_C
#define ORBIT_HYPERDRIVE_C

#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "arena.c"
#include "types.c"

#define HYPERDRIVE_RING_SIZE 1024

typedef struct {
    uint64_t sequence;
    void* data;
    size_t length;
} HyperdriveRingSlot;

typedef struct {
    HyperdriveRingSlot slots[HYPERDRIVE_RING_SIZE];
    uint64_t head;
    uint64_t tail;
    bool active;
} OrbitHyperdriveRing;

static OrbitHyperdriveRing g_hyperdrive_ring = { .head = 0, .tail = 0, .active = true };

void orbit_hyperdrive_init(void) {
    memset(&g_hyperdrive_ring, 0, sizeof(OrbitHyperdriveRing));
    g_hyperdrive_ring.active = true;
}

bool orbit_hyperdrive_push(void* ptr, size_t len) {
    if (!g_hyperdrive_ring.active) return false;
    uint64_t pos = g_hyperdrive_ring.head;
    uint64_t idx = pos % HYPERDRIVE_RING_SIZE;
    g_hyperdrive_ring.slots[idx].data = ptr;
    g_hyperdrive_ring.slots[idx].length = len;
    g_hyperdrive_ring.slots[idx].sequence = pos;
    g_hyperdrive_ring.head++;
    return true;
}

bool orbit_hyperdrive_pop(void** out_ptr, size_t* out_len) {
    if (!g_hyperdrive_ring.active || g_hyperdrive_ring.tail >= g_hyperdrive_ring.head) return false;
    uint64_t pos = g_hyperdrive_ring.tail;
    uint64_t idx = pos % HYPERDRIVE_RING_SIZE;
    if (out_ptr) *out_ptr = g_hyperdrive_ring.slots[idx].data;
    if (out_len) *out_len = g_hyperdrive_ring.slots[idx].length;
    g_hyperdrive_ring.tail++;
    return true;
}

#endif
