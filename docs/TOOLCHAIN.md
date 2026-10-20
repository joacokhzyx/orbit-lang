# Toolchain policy: tcc and the reference compilers

tcc 0.9.27 is the fast-build toolchain: it compiles a translation unit in a
fraction of gcc's time and is therefore the right tool for single-file
probes and edit-compile-run loops. It is not a reference toolchain. Two
rules draw that boundary, and both are mechanical consequences of what
tcc 0.9.27 can and cannot do, measured on 2026-10-14 (Windows 10
19045, AMD Ryzen 5 2400G, gcc 16.2.0 w64devkit, tcc 0.9.27 x86_64
Windows portable). Nothing below is a guess: every gap has a probe that
fails without the shim and passes with it.

## Rule 1 — tcc never produces a quoted number

No benchmark, performance comparison, latency percentile, or energy /
power figure may come from a tcc-built binary. Not as a headline, not
as a baseline, not "just to see". Three independent reasons:

1. Its codegen is unoptimised by design. A timing compares tcc's
   codegen against the other toolchain's, not the two programs.
2. The shim's `YieldProcessor` is `Sleep(0)`, a timeslice yield, not a
   pause hint — spin behaviour under tcc is not the shipped behaviour.
3. The shim's `GetTickCount64` is the 32-bit `GetTickCount` and wraps
   every ~49 days. Any clock arithmetic past a restart is wrong.

Instruments that stay on the reference toolchain: `scripts/kynx_gate.py
load`, `scripts/measure_selfhost.py`, the `/_ledger` energy columns.
`docs/PERF.md` and `docs/ENERGY.md` record what those instruments say.
A tcc timing belongs in neither file.

## Rule 2 — the multithreaded server always builds with gcc

`runtime/thread_pool.c` needs `__atomic` builtins, `performance.h`
needs 64-bit interlocked imports, and several runtime TUs need
thread-local storage. tcc 0.9.27 on Windows has none of the three:

| Need | Under tcc 0.9.27 | Appears in |
|---|---|---|
| `__atomic_load_n` / `__atomic_store_n` | undeclared, hard compile error | `thread_pool.c` acceptor/worker rings |
| `InterlockedIncrement64` / `InterlockedExchangeAdd64` | declared by tcc's `winbase.h`, missing from its `kernel32.def`: `undefined symbol` at link | `performance.h` counters, `arena_pool.c`, `kynx.c` |
| `__thread` / `__declspec(thread)` | rejected by the parser | `ORBIT_THREAD_LOCAL` (`performance.h`), `crt_compat.h` env slot |
| `pthread.h` | include not found | POSIX-only test helpers |

So a tcc build of any threaded TU fails loudly at compile or link
time, and the server build stays gcc (Linux) / clang (Windows CI).
`tcc_setup.py` and the shim never try to close these gaps: a forked
import lib for the 64-bit interlocked calls would make tcc build code
whose atomics no gate verifies, which is worse than a loud failure.

## Platform matrix

| Platform | tcc story | How |
|---|---|---|
| Windows x64 | portable 0.9.27 + `vendor/tcc-shim/` | `python scripts/tcc_setup.py` (zip pinned by SHA-256, no admin); `-I vendor/tcc-shim -include tcc_toolchain.h` + `ws2_32.def` / `sqlite3.def` |
| Linux x64 | system tcc, no shim (system headers are complete) | package manager (`sudo apt-get install -y tcc`, …); `tcc_setup.py --check` enforces the 0.9.27 pin and refuses anything else |
| macOS ARM64 | no stable tcc (0.9.27 has no ARM64 backend; the mob branch is unpinned) | documented fallback: gcc/clang. `tcc_setup.py` exits SKIP saying so |

## What the shim covers (and how it was verified)

- `winsock2.h` / `ws2tcpip.h`: 29 functions with ABI-real structs and
  SDK values. Every import name confirmed as a real `ws2_32.dll`
  export via `tcc -impdef` (197-export dump, same date).
- `tcc_toolchain.h` (`-include`): `GetTickCount64`→`GetTickCount`
  (tcc neither declares nor imports the 64-bit one),
  `YieldProcessor`→`Sleep(0)` (tcc's spelling resolves to an
  unimplemented `_mm_pause`), `strtoll`→`_strtoi64` /
  `strtoull`→`_strtoui64` (tcc declares the former pair but imports
  only the latter). All `__TINYC__`-guarded so gcc/clang builds are
  unaffected.
- `ws2_32.def` / `sqlite3.def`: minimal import libraries. The ws2 set
  is exactly the 29 header functions. The sqlite set is exactly the 19
  `sqlite3_*` symbols `runtime/database.c` and
  `tests/auth/auth_harness.c` use, each confirmed as a real export of
  `runtime/vendor/win-x64/sqlite3.dll`.

Verification, all in throwaway dirs (never in the repo):

| Build | Command form | Result |
|---|---|---|
| socket + toolchain mappings | `tcc -I vendor/tcc-shim -include tcc_toolchain.h probe_socket.c ws2_32.def` | clean compile, `TCC-SHIM-SOCKET-PASS` at runtime (ephemeral-port loopback: non-blocking connect, select, `SO_ERROR`, accept, send/recv) |
| same probe, gcc + real SDK headers | `gcc probe_socket.c -lws2_32` | same `TCC-SHIM-SOCKET-PASS`: behavioural equivalence, not just "it links" |
| sqlite wrapper | `tcc -I runtime/vendor probe_sqlite.c sqlite3.def`, `sqlite3.dll` beside the exe | `TCC-SHIM-SQLITE-PASS` (`:memory:` create/bind/select/close) |
| negative: `gethostname` (real export, outside the 29) | same flags | `undefined symbol` at link — the closed set holds |
| negative: `__atomic_load_n` | bare tcc | undeclared, hard error — Rule 2's backing |

Re-run the two positive probes after any shim change. They live at
`vendor/tcc-shim/probe_socket.c` and `vendor/tcc-shim/probe_sqlite.c`.
CI runs them on Windows and skips this step cleanly (visible `TCC-SKIP`,
never a silent pass) where tcc is unavailable.

One near-miss worth recording: during validation the shim briefly
defined `WSAEWOULDBLOCK` as 14035 from memory, and the loopback probe
failed. The DLL, MinGW-w64's `winerror.h` (`WSABASEERR+35`), and tcc's
own `winerror.h` all say 10035 — three sources agree.
The shim carries 10035, and the memory lost.
