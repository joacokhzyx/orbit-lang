#ifndef ORBIT_RT_TYPES_C
#define ORBIT_RT_TYPES_C

#include "module_prelude.h"
#include "types.h"
#include "ledger.h"
#include "kynx.h"
#ifdef __TINYC__
#ifndef ORBIT_TINYC_SHIM
#ifndef __ATOMIC_RELAXED
#endif
#endif
#endif
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "inline.h"

/** @brief Construct a successful Result carrying @p value. */
OrbitResult orbit_result_ok(void* value) {
    OrbitResult r;
    r.ok         = true;
    r.error_code = ORBIT_ERR_NONE;
    r.error_msg  = NULL;
    r.value      = value;
    return r;
}

/** @brief Construct a successful Result carrying a 64-bit element word.
 *
 * The transport form for a value that is not a pointer: an int, a bool, or a
 * double's bit pattern. memcpy rather than a cast, so no int-to-pointer
 * conversion is invented. */
ORBIT_UNUSED OrbitResult orbit_result_ok_word(uintptr_t word) {
    OrbitResult r;
    r.ok         = true;
    r.error_code = ORBIT_ERR_NONE;
    r.error_msg  = NULL;
    r.value      = NULL;
    memcpy(&r.value, &word, sizeof(uintptr_t));
    return r;
}

/** @brief Construct a successful Result carrying a double.
 *
 * The list element table (runtime/collections.c) already established that a
 * double cannot travel through uintptr_t -- 1.5 becomes 1 -- so this boxes
 * the IEEE-754 bit pattern the way orbit_list_push_float does, not the
 * numeric value. Read it back with orbit_result_get_float, never with a
 * numeric cast of the word. */
ORBIT_UNUSED OrbitResult orbit_result_ok_float(orbit_float value) {
    uintptr_t word = 0;
    memcpy(&word, &value, sizeof(uintptr_t));
    return orbit_result_ok_word(word);
}

/** @brief Read the double out of an ok Result, or 0.0.
 *
 * Call only on results known ok: the emitter checks .ok before unwrapping,
 * and an err result carries NULL, which decodes as 0.0 without saying so.
 * memcpy rather than a cast, for the same reason as the box above: the word
 * holds bits, and converting them to a number answers the address of the
 * value instead of the value. */
ORBIT_UNUSED orbit_float orbit_result_get_float(OrbitResult r) {
    orbit_float value = 0.0;
    memcpy(&value, &r.value, sizeof(orbit_float));
    return value;
}


/** @brief Construct a failed Result with the given error @p code and human-readable @p msg. */
OrbitResult orbit_result_err(OrbitErrorCode code, const char* msg) {
    OrbitResult r;
    r.ok         = false;
    r.error_code = code;
    r.error_msg  = msg;
    r.value      = NULL;
    return r;
}

#endif
