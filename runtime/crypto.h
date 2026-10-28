/* Interface of runtime/crypto.c (generated split; edit by hand from here). */
#ifndef ORBIT_RT_CRYPTO_H
#define ORBIT_RT_CRYPTO_H

#include "module_prelude.h"

#include "types.h"
#include "arena.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "types.h"
#include "arena.h"
#include "crt_compat.h"
orbit_string orbit_base64url_encode(OrbitArena* arena, const uint8_t* data, size_t input_len);
orbit_string orbit_base64url_encode_str(OrbitArena* arena, const char* str);

/* ── SHA-256 Implementation ────────────────────────────────────────────────── */

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define SIG0(x) (ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22))
#define SIG1(x) (ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25))
#define sig0(x) (ROTR(x, 7) ^ ROTR(x, 18) ^ ((x) >> 3))
#define sig1(x) (ROTR(x, 17) ^ ROTR(x, 19) ^ ((x) >> 10))
void orbit_sha256(const uint8_t* data, size_t len, uint8_t hash[32]);
orbit_string orbit_sha256_hex(OrbitArena* arena, const char* str);
void orbit_hmac_sha256(const uint8_t* key, size_t key_len, const uint8_t* data, size_t data_len, uint8_t out[32]);
orbit_string orbit_hmac_sha256_base64url(OrbitArena* arena, const char* key, const char* data);
bool orbit_ct_equal(const char* a, const char* b);

#endif
