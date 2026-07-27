/**
 * @file  crypto.c
 * @brief Sovereign Cryptographic Primitives (SHA-256, HMAC-SHA256, Base64URL) for Orbit Runtime.
 */
#ifndef ORBIT_CRYPTO_C
#define ORBIT_CRYPTO_C

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "types.c"
#include "arena.c"

/* ── Base64URL Encoding & Decoding ────────────────────────────────────────── */

static const char BASE64_CHARS[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static const char BASE64URL_CHARS[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

orbit_string orbit_base64url_encode(OrbitArena* arena, const uint8_t* data, size_t input_len) {
    size_t output_len = 4 * ((input_len + 2) / 3);
    char* encoded = (char*)orbit_alloc(arena, output_len + 1);
    if (!encoded) return "";

    size_t i = 0, j = 0;
    while (i < input_len) {
        uint32_t octet_a = i < input_len ? data[i++] : 0;
        uint32_t octet_b = i < input_len ? data[i++] : 0;
        uint32_t octet_c = i < input_len ? data[i++] : 0;

        uint32_t triple = (octet_a << 16) + (octet_b << 8) + octet_c;

        encoded[j++] = BASE64URL_CHARS[(triple >> 18) & 0x3F];
        encoded[j++] = BASE64URL_CHARS[(triple >> 12) & 0x3F];
        encoded[j++] = BASE64URL_CHARS[(triple >> 6) & 0x3F];
        encoded[j++] = BASE64URL_CHARS[triple & 0x3F];
    }

    size_t mod = input_len % 3;
    if (mod == 1) j -= 2;
    else if (mod == 2) j -= 1;

    encoded[j] = '\0';
    return encoded;
}

/* ── SHA-256 Implementation ────────────────────────────────────────────────── */

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define SIG0(x) (ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22))
#define SIG1(x) (ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25))
#define sig0(x) (ROTR(x, 7) ^ ROTR(x, 18) ^ ((x) >> 3))
#define sig1(x) (ROTR(x, 17) ^ ROTR(x, 19) ^ ((x) >> 10))

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

void orbit_sha256(const uint8_t* data, size_t len, uint8_t hash[32]) {
    uint32_t h[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    };

    size_t padded_len = len + 1 + 8;
    while (padded_len % 64 != 0) padded_len++;

    uint8_t* msg = (uint8_t*)calloc(padded_len, 1);
    memcpy(msg, data, len);
    msg[len] = 0x80;

    uint64_t bits = (uint64_t)len * 8;
    for (int i = 0; i < 8; i++) {
        msg[padded_len - 1 - i] = (uint8_t)(bits >> (i * 8));
    }

    uint32_t w[64];
    for (size_t chunk = 0; chunk < padded_len; chunk += 64) {
        for (int i = 0; i < 16; i++) {
            w[i] = ((uint32_t)msg[chunk + i * 4] << 24) |
                   ((uint32_t)msg[chunk + i * 4 + 1] << 16) |
                   ((uint32_t)msg[chunk + i * 4 + 2] << 8) |
                   ((uint32_t)msg[chunk + i * 4 + 3]);
        }
        for (int i = 16; i < 64; i++) {
            w[i] = sig1(w[i - 2]) + w[i - 7] + sig0(w[i - 15]) + w[i - 16];
        }

        uint32_t a = h[0], b = h[1], c = h[2], d = h[3];
        uint32_t e = h[4], f = h[5], g = h[6], h_val = h[7];

        for (int i = 0; i < 64; i++) {
            uint32_t temp1 = h_val + SIG1(e) + CH(e, f, g) + K256[i] + w[i];
            uint32_t temp2 = SIG0(a) + MAJ(a, b, c);
            h_val = g; g = f; f = e; e = d + temp1;
            d = c; c = b; b = a; a = temp1 + temp2;
        }

        h[0] += a; h[1] += b; h[2] += c; h[3] += d;
        h[4] += e; h[5] += f; h[6] += g; h[7] += h_val;
    }

    free(msg);

    for (int i = 0; i < 8; i++) {
        hash[i * 4]     = (uint8_t)(h[i] >> 24);
        hash[i * 4 + 1] = (uint8_t)(h[i] >> 16);
        hash[i * 4 + 2] = (uint8_t)(h[i] >> 8);
        hash[i * 4 + 3] = (uint8_t)(h[i]);
    }
}

orbit_string orbit_sha256_hex(OrbitArena* arena, const char* str) {
    uint8_t hash[32];
    orbit_sha256((const uint8_t*)str, strlen(str), hash);
    char* hex = (char*)orbit_alloc(arena, 65);
    for (int i = 0; i < 32; i++) {
        sprintf(hex + i * 2, "%02x", hash[i]);
    }
    hex[64] = '\0';
    return hex;
}

/* ── HMAC-SHA256 Implementation ────────────────────────────────────────────── */

void orbit_hmac_sha256(const uint8_t* key, size_t key_len, const uint8_t* data, size_t data_len, uint8_t out[32]) {
    uint8_t k0[64];
    memset(k0, 0, 64);

    if (key_len > 64) {
        orbit_sha256(key, key_len, k0);
    } else {
        memcpy(k0, key, key_len);
    }

    uint8_t i_key_pad[64];
    uint8_t o_key_pad[64];

    for (int i = 0; i < 64; i++) {
        i_key_pad[i] = k0[i] ^ 0x36;
        o_key_pad[i] = k0[i] ^ 0x5c;
    }

    uint8_t* inner_msg = (uint8_t*)malloc(64 + data_len);
    memcpy(inner_msg, i_key_pad, 64);
    memcpy(inner_msg + 64, data, data_len);

    uint8_t inner_hash[32];
    orbit_sha256(inner_msg, 64 + data_len, inner_hash);
    free(inner_msg);

    uint8_t outer_msg[64 + 32];
    memcpy(outer_msg, o_key_pad, 64);
    memcpy(outer_msg + 64, inner_hash, 32);

    orbit_sha256(outer_msg, 64 + 32, out);
}

orbit_string orbit_hmac_sha256_base64url(OrbitArena* arena, const char* key, const char* data) {
    uint8_t mac[32];
    orbit_hmac_sha256((const uint8_t*)key, strlen(key), (const uint8_t*)data, strlen(data), mac);
    return orbit_base64url_encode(arena, mac, 32);
}

#endif
