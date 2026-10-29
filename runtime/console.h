/**
 * @file  console.h
 * @brief Console setup and string output for programs that print.
 */
#ifndef ORBIT_RT_CONSOLE_H
#define ORBIT_RT_CONSOLE_H

#include "module_prelude.h"
#include "types.h"

/* Windows: UTF-8 output code page and ANSI escape processing when stdout is a
 * console (best effort; GetConsoleMode fails on pipes). A no-op elsewhere.
 * Emitted only for programs that write to the console. */
void orbit_console_init(void);

/* What the compiler's terminal UI asks of the OS. Stream numbers are 1 for
 * stdout and 2 for stderr. */

/* Bit 1: console. Bit 2: ANSI escapes enabled on that handle. Bit 4: UTF-8 output. */
orbit_int orbit_ui_caps(orbit_int fd);

/* Columns of the console, 0 when the stream is not one. */
orbit_int orbit_ui_width(orbit_int fd);

/* .text size of the PE image at path, -1 when it is not one. */
orbit_int orbit_ui_text_size(orbit_string path);

/* Repaint thread on stderr. A block uses byte 0x01 for the orbital frame and
 * byte 0x02 for the active stage's milliseconds. flags bit 0: ASCII frames. */
orbit_int orbit_ui_anim_start(orbit_string block, orbit_int flags);
orbit_int orbit_ui_anim_stage(orbit_string block);
orbit_int orbit_ui_anim_stop(orbit_string final_block);

/* print("%s", s) without the format engine: s, a newline, a flush. */
void orbit_print_string(const char* s);

#endif
