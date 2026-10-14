# `vendor/tcc-shim/` — tcc 0.9.27 Windows support (shim v1, 2026-10-14)

tcc 0.9.27 ships no Winsock headers and no `ws2_32` import library, and its
bundled `kernel32`/`msvcrt` import libraries miss a handful of names the
Orbit runtime spells. This directory closes exactly those gaps, no more.
It is versioned alongside the tcc pin in `VERSION`; re-verify every entry
with `tcc -impdef` before widening the set.

## Layout

| File | What it is |
|---|---|
| `VERSION` | pinned tcc (0.9.27 + zip SHA-256) and shim version |
| `winsock2.h` | closed-set Winsock header: ABI-real structs, SDK values, 29 functions |
| `ws2tcpip.h` | closed-set resolution header: `addrinfo`, `getaddrinfo`/`freeaddrinfo`, `IN6_IS_ADDR_LOOPBACK` |
| `tcc_toolchain.h` | `-include` spellings: `GetTickCount64`→`GetTickCount`, `YieldProcessor`→`Sleep(0)`, `strtoll`→`_strtoi64`, `strtoull`→`_strtoui64` |
| `ws2_32.def` | minimal import library: exactly the 29 functions the headers declare |
| `sqlite3.def` | `.lib`→`.dll` wrapper: the 19 `sqlite3_*` symbols `runtime/database.c` + `tests/auth/auth_harness.c` use, bound to `sqlite3.dll` so tcc links without the MS COFF `sqlite3.lib` it cannot read |
| `probe_socket.c` | CI/self check: loopback socket exercise + toolchain mappings, must print `TCC-SHIM-SOCKET-PASS` |
| `probe_sqlite.c` | CI/self check: `:memory:` open/bind/select/close via the wrapper, must print `TCC-SHIM-SQLITE-PASS` |
| `README.md` | this file |

## Use

Acquire the toolchain once (portable, no admin):

```bash
python scripts/tcc_setup.py
```

Compile a translation unit with the shim (paths relative to the repo root):

```bash
tcc -I vendor/tcc-shim -include tcc_toolchain.h \
    -o prog.exe prog.c vendor/tcc-shim/ws2_32.def
```

Pass the `.def` file directly: it names `ws2_32.dll`, which the loader
resolves from the system at runtime. Do not pass `-lws2_32`; tcc ships no
such import library and the flag fails. DB programs add `vendor/tcc-shim/sqlite3.def` the same way and
keep `sqlite3.dll` beside the exe at runtime, exactly as the MSVC-linked
builds already do (`runtime/vendor/README.md`).

`scripts/tcc_setup.py --print-flags --repo <root>` prints these flags.

## What it covers

- Single-threaded socket code using only the 29 functions / constants in
  `winsock2.h` + `ws2tcpip.h`. Every name was confirmed as a real
  `ws2_32.dll` export with `tcc -impdef` on 2026-10-14.
- `GetTickCount64` call sites (32-bit wrap documented in
  `tcc_toolchain.h`), `YieldProcessor` spin sites, `strtoll`/`strtoull`
  call sites.
- DB translation units using only the 19 wrapped `sqlite3_*` symbols
  (confirmed as real exports of `runtime/vendor/win-x64/sqlite3.dll`).

## What it does NOT cover — and how each fails (loudly, never silently)

| Use | Failure under tcc | Why it stays out |
|---|---|---|
| Any Winsock name outside the 29 | `undefined symbol` at link (the `.def` is the closed set) | new uses must be added deliberately, header + `.def` + re-verify |
| Multithreaded server (`thread_pool.c`) | `__atomic_load_n` undeclared; `__thread` / `__declspec(thread)` rejected | tcc 0.9.27 has no `__atomic` builtins and no TLS on Windows |
| 64-bit interlocked (`performance.h`, `arena_pool.c`, `kynx.c` hot paths) | `undefined symbol '_InterlockedExchangeAdd64'` etc. (missing from tcc's `kernel32.def`) | needs a forked import lib; not worth it for a fast-build lane |
| `pthread.h` test helpers | include not found | POSIX-only shape; out of lane scope |
| Benchmarks / perf / energy numbers from a tcc binary | nonsensical by construction (`Sleep(0)` spins, 32-bit clock wraps, unoptimised codegen) | forbidden by rule, see `docs/TOOLCHAIN.md` |

The multithreaded server always builds with gcc: that is a rule in
`docs/TOOLCHAIN.md`, and the table above is its mechanical backing.

## Widening the set

1. Confirm the name is a real export: `tcc -impdef C:\Windows\System32\ws2_32.dll`.
2. Add the declaration to the header AND the name to the `.def` in the same change.
3. Rebuild the loopback + sqlite probes in `docs/TOOLCHAIN.md`.
4. Bump `SHIM_VERSION` in `VERSION`.
