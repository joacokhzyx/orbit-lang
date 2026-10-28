#!/usr/bin/env python3
"""Runtime-module gate: `orbit build --runtime-module` makes a linkable object.

A runtime module is an Orbit file with no `main` whose `export fn` functions
keep their C names (docs/IR_SPEC.md). This gate builds tests/runtime_module/
upper.orb to an object, links tests/runtime_module/main.orb against it through
its `extern fn` declarations, runs the program and compares its stdout with
tests/runtime_module/expected.txt.

  --backend c       the object comes from the C backend.
  --backend native  the object comes from R6 (`r6 build --object`); needs
                    ORBIT_R6, else the run is SKIPPED with exit 77.

The program is always built by the C backend: R6 does not link foreign
objects. arena.orb (an RtArena parameter) is built on both lanes. A file with a `main` must be refused by `--runtime-module`, which
keeps the gate able to fail on the mode check as well as on the output.

Usage:
    python scripts/runtime_module_gate.py --compiler PATH [--cc CC]
                                          [--backend c|native]
"""

import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
import _common

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_RC = 77
CASES = os.path.join(ROOT, "tests", "runtime_module")


def run(argv, env):
    p = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                       text=True, errors="replace", timeout=300)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", required=True)
    ap.add_argument("--cc", default=None)
    ap.add_argument("--backend", choices=("c", "native"), default="c")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    tool = "runtime_module_native" if args.backend == "native" else "runtime_module"
    r6 = os.environ.get("ORBIT_R6", "")
    if args.backend == "native":
        if not r6:
            out.say(f"Skipped {tool}: ORBIT_R6 is not set. Point it at r6.exe "
                    "with ir-protocol 3 to run this lane.")
            return SKIP_RC
        if not os.path.isfile(r6):
            out.fail(f"Failed {tool}: ORBIT_R6 names {r6}, which is not a file")
            return 1

    compiler = os.path.abspath(args.compiler)
    cc = _common.resolve_cc(args.cc)
    work = str(_common.scratch("orbit_rtmod_"))
    exe = os.path.join(work, "probe.exe" if os.name == "nt" else "probe")
    obj = os.path.join(work, "upper.o")
    header = os.path.join(CASES, "probe.h").replace("\\", "/")
    rel = lambda name: os.path.relpath(os.path.join(CASES, name), ROOT)

    env = _common.build_env(work, cc=cc)
    env["ORBIT_CCACHE"] = "0"
    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        if ok:
            out.say(f"  ok   {name}")
        else:
            out.fail(f"  FAIL {name}\n    {detail}")

    obj_env = dict(env, ORBIT_BACKEND=args.backend)
    code, text = run([compiler, "build", "--runtime-module", rel("upper.orb"),
                      "-o", obj, "--quiet"], obj_env)
    check("object builds", code == 0 and os.path.isfile(obj), text.strip())
    if results[-1]:
        main_env = dict(env, ORBIT_BACKEND="c",
                        ORBIT_CCFLAGS_EXTRA='-include "%s" "%s"' % (header, obj.replace("\\", "/")))
        code, text = run([compiler, "build", rel("main.orb"), "-o", exe,
                          "--quiet"], main_env)
        check("program links the object", code == 0, text.strip())
        if results[-1]:
            p = subprocess.run([exe], cwd=work, capture_output=True, text=True,
                               errors="replace", timeout=60)
            with open(os.path.join(CASES, "expected.txt"), encoding="utf-8") as f:
                want = f.read()
            got = (p.stdout or "").replace("\r\n", "\n")
            check("program output", p.returncode == 0 and got == want,
                  f"exit {p.returncode}, stdout {got!r}, wanted {want!r}")

    arena_obj = os.path.join(work, "arena.o")
    code, text = run([compiler, "build", "--runtime-module", rel("arena.orb"),
                      "-o", arena_obj, "--quiet"], obj_env)
    check("RtArena export builds", code == 0 and os.path.isfile(arena_obj),
          text.strip())

    code, text = run([compiler, "check", "--runtime-module", rel("main.orb")], env)
    check("a file with main is refused", code != 0 and "no entry point" in text,
          f"exit {code}: {text.strip()}")

    n, total = sum(results), len(results)
    line = f"Finished {tool}: {n}/{total} pass"
    if n == total:
        out.say(line)
        return 0
    out.fail(line.replace("Finished", "Failed"))
    return 1


if __name__ == "__main__":
    sys.exit(main())
