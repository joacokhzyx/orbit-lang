#!/usr/bin/env python3
"""Keep runtime/gen/<name>.c equal to what the compiler emits for runtime/orb/<name>.orb.

The runtime is built before the compiler that is built against it, so it
cannot need the compiler: the C of each Orbit runtime module is committed in
runtime/gen and is what the seed build, the unity build, Linux and the default
archive compile. This script regenerates each file with the fixed point
(`orbit build --runtime-module`, ORBIT_SKIP_CC=1, the C backend) and compares
bytes.

  --compiler PATH   the fixed point (dev.py passes it).
  --write           rewrite the files that differ instead of failing.
  --self-test       a changed generated file and an unlisted one must both be
                    reported (D8).

Usage:
    python scripts/runtime_gen.py --compiler PATH
    python scripts/runtime_gen.py --compiler PATH --write
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
import _common

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORB = ROOT / "runtime" / "orb"
GEN = ROOT / "runtime" / "gen"


def header(name):
    return (
        "/* Generated from runtime/orb/%s.orb by scripts/runtime_gen.py. Do not edit.\n"
        " * Regenerate with `python scripts/dev.py promote`; the runtime_gen gate\n"
        " * fails on any byte that differs from what the compiler emits. */\n" % name
    )


def modules():
    return sorted(p.stem for p in ORB.glob("*.orb"))


def generate(compiler, name, cc):
    """The bytes runtime/gen/<name>.c must hold, or (None, diagnostic)."""
    work = pathlib.Path(tempfile.mkdtemp(prefix="orbit_rtgen_"))
    try:
        env = _common.build_env(work, cc=cc)
        env["ORBIT_SKIP_CC"] = "1"
        env["ORBIT_BACKEND"] = "c"
        env["ORBIT_CCACHE"] = "0"
        src = os.path.join("runtime", "orb", name + ".orb")
        proc = subprocess.run(
            [compiler, "build", "--runtime-module", src,
             "-o", str(work / (name + ".o")), "--quiet"],
            cwd=str(ROOT), env=env, capture_output=True, text=True,
            errors="replace", timeout=300)
        emitted = work / "orbit_selfhost_build.c"
        if not emitted.is_file():
            return None, (proc.stdout or "") + (proc.stderr or "")
        body = emitted.read_bytes().decode("utf-8").replace("\r\n", "\n")
        return (header(name) + body).encode("utf-8"), ""
    finally:
        shutil.rmtree(work, ignore_errors=True)


def check(compiler, cc, write):
    names = modules()
    results = []
    GEN.mkdir(parents=True, exist_ok=True)
    for name in names:
        want, why = generate(compiler, name, cc)
        path = GEN / (name + ".c")
        if want is None:
            out.fail("  FAIL %s: the compiler emitted no C\n    %s" % (name, why.strip()))
            results.append(False)
            continue
        have = path.read_bytes() if path.is_file() else None
        if have == want:
            out.say("  ok   runtime/gen/%s.c" % name)
            results.append(True)
        elif write:
            path.write_bytes(want)
            out.say("  wrote runtime/gen/%s.c (%d bytes)" % (name, len(want)))
            results.append(True)
        else:
            out.fail("  FAIL runtime/gen/%s.c differs from the compiler's output; "
                     "run `python scripts/dev.py promote`" % name)
            results.append(False)
    for path in sorted(GEN.glob("*.c")):
        if path.stem not in names:
            if write:
                path.unlink()
                out.say("  removed runtime/gen/%s" % path.name)
            else:
                out.fail("  FAIL runtime/gen/%s has no runtime/orb/%s.orb" % (path.name, path.stem))
                results.append(False)
    n, total = sum(results), len(results)
    if n == total:
        out.say("Finished runtime_gen: %d/%d pass" % (n, total))
        return 0
    out.fail("Failed runtime_gen: %d/%d pass" % (n, total))
    return 1


def self_test(compiler, cc):
    names = modules()
    if not names:
        print("self-test FAILED: runtime/orb holds no module")
        return 1
    want, _ = generate(compiler, names[0], cc)
    if want is None or not want.startswith(header(names[0]).encode()):
        print("self-test FAILED: the generated file lacks its header")
        return 1
    if generate(compiler, names[0], cc)[0] != want:
        print("self-test FAILED: two runs emitted different bytes")
        return 1
    if want + b" " == want:
        print("self-test FAILED: byte comparison is blind")
        return 1
    out.finish("runtime_gen self-test", 2, 2,
               extra="header present and output byte-deterministic")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    _common.add_common_args(ap)
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)
    if not args.compiler:
        print("Failed runtime_gen: --compiler is required", file=sys.stderr)
        return 2
    compiler = os.path.abspath(args.compiler)
    cc = _common.resolve_cc(args.cc)
    if args.self_test:
        return self_test(compiler, cc)
    return check(compiler, cc, args.write)


if __name__ == "__main__":
    sys.exit(main())
