#!/usr/bin/env python3
"""Amalgamate the self-hosted Orbit compiler into a single self-contained C file.

Phase S1 (SOVER-0): produce `dist/orbit_bootstrap.c` by inlining every
project-relative `#include "..."` reachable from `compiler/selfhost/stage3.exe.c`.
System includes (`#include <...>`) are left untouched.

Strategy: inline *every* occurrence of a project include, wrapping each file in
its own include guard named after its relative path.  Because the guards are per
file, an occurrence inside an `#ifdef` branch that is inactive at compile time
does not mask a later unconditional occurrence, and two active occurrences of the
same file collapse to one compiled copy.  This mirrors the preprocessor's own
include-guard semantics without depending on the runtime files having guards.

Usage:
    python3 scripts/amalgamate.py [--entry compiler/selfhost/stage3.exe.c] [--out dist/orbit_bootstrap.c]
"""

import os
import re
import sys

INCLUDE_RE = re.compile(r'^(.*#\s*include\s*"([^"]+)"\s*)$', re.M)
MARKER = r'/* seed: #include "{name}" inlined below */'


def guard_for(relpath: str) -> str:
    ident = re.sub(r'[^A-Za-z0-9]', '_', relpath).strip('_').upper()
    return f"ORBIT_SEED_FILE_{ident}"


def amalgamate(entry_path: str, runtime_root: str, out_path: str) -> None:
    def resolve(from_dir: str, name: str) -> str:
        cand = os.path.normpath(os.path.join(from_dir, name))
        if os.path.isfile(cand):
            return cand
        fallback = os.path.normpath(os.path.join(runtime_root, name))
        if os.path.isfile(fallback):
            return fallback
        raise FileNotFoundError(f"cannot resolve include {name!r} from {from_dir!r}")

    def inline(path: str) -> str:
        path = os.path.normpath(path)
        with open(path, encoding="utf-8", errors="replace") as f:
            content = f.read()
        rel = os.path.relpath(path, runtime_root)
        content = INCLUDE_RE.sub(
            lambda m: MARKER.format(name=m.group(2)) + "\n" + inline(resolve(os.path.dirname(path), m.group(2))),
            content,
        )
        guard = guard_for(rel)
        return (
            f"\n/* BEGIN SEED FILE: {rel} */\n"
            f"#ifndef {guard}\n#define {guard}\n"
            f"{content}\n"
            f"#endif /* {guard} */\n"
            f"/* END SEED FILE: {rel} */\n"
        )

    with open(entry_path, encoding="utf-8", errors="replace") as f:
        main = f.read()
    entry_dir = os.path.dirname(os.path.abspath(entry_path))
    main = INCLUDE_RE.sub(
        lambda m: MARKER.format(name=m.group(2)) + "\n" + inline(resolve(entry_dir, m.group(2))),
        main,
    )
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(main)


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    entry = os.path.join(root, "compiler", "selfhost", "stage3.exe.c")
    runtime_root = os.path.join(root, "src", "runtime")
    out = os.path.join(root, "dist", "orbit_bootstrap.c")
    args = sys.argv[1:]
    if "--entry" in args:
        entry = os.path.normpath(args[args.index("--entry") + 1])
    if "--out" in args:
        out = os.path.normpath(args[args.index("--out") + 1])
    amalgamate(entry, runtime_root, out)
    size = os.path.getsize(out)
    print(f"wrote {out} ({size / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())