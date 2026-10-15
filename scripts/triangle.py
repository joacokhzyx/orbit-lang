#!/usr/bin/env python3
"""Diverse double-compilation triangle (carril T2, DDC): three toolchains, one emission.

The committed canonical ``compiler/selfhost/stage3.exe.c`` is compiled three
times -- with tcc, with gcc -O0 and with gcc -O2 -- and each resulting judge
binary re-emits the compiler's C (``build compiler/main.orb`` with
ORBIT_SKIP_CC=1, same as scripts/verify_seed.py's orb_build). The gate
requires the three SHA-256 digests to be identical.

This is an ADDITIONAL gate: it replaces neither scripts/verify_seed.py (the
C fixed point against the canonical, the root of trust) nor the seed chain
(seed2 -> chain2 -> chain3). What it adds is toolchain diversity -- proof
that the canonical C means the same thing under three compilers, so a gcc
miscompile (or a tcc misread) cannot hide behind a self-consistent chain.
A mismatch is SIGNAL: the digests plus the first differing offset fail the
gate, and the three emissions stay in the work dir for inspection.

Per-arm wall times (cc build + C emission) are measured and printed; tcc is
a correctness judge here, never a benchmark, so the times are process
evidence, not a ranking. The judge binaries are disposable (no windres brand
stamp, no compile cache): branding is the bootstrap path's job, and the cache
is bypassed so the timings are real builds.

The tcc arm carries the same toolchain gaps as scripts/dual_judge.py
(carril-T winsock shim + a generated force-include + advapi32; see that
module for why each exists). Pass --tcc <gcc> to run the logic in
gcc-vs-gcc substitute mode (must go green; proves the harness, not tcc).

Usage:
    python scripts/triangle.py [--cc GCC] [--tcc TCC] [--tcc-shim DIR]
                               [--timeout S] [--work DIR] [--keep]
    python scripts/triangle.py --self-test

Exit code 0 iff all three emissions are byte-identical.
"""

import argparse
import hashlib
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
import _common
from dual_judge import (TCC_DUAL_HEADER, resolve_tcc, resolve_tcc_shim,
                        shim_header, ADVAPI32)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANONICAL_C = os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c")
MAIN_ORB = os.path.join("compiler", "main.orb")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_logged(argv, cwd, env, timeout, label):
    """Run one step; fail-hard with the tail, like verify_seed.run."""
    t0 = time.monotonic()
    try:
        proc = subprocess.run(argv, cwd=cwd, env=env, capture_output=True,
                              text=True, errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        out.fail("Failed %s: hung after %ds" % (label, timeout))
        raise SystemExit(1)
    dt = time.monotonic() - t0
    combined = (proc.stdout or "") + (proc.stderr or "")
    if combined.strip():
        print(combined.rstrip())
    if proc.returncode != 0:
        tail = "\n".join(combined.strip().splitlines()[-15:])
        out.ci_error("[%s] rc=%d :: %s" % (label, proc.returncode,
                                           out.scrub_ci(tail)))
        out.fail("Failed %s (rc=%d)" % (label, proc.returncode))
        raise SystemExit(1)
    return dt


def compare_emissions(digests):
    """Pure agreement check so --self-test needs no toolchain.

    Returns None when all three agree, else a description of the split.
    """
    if digests[0] == digests[1] == digests[2]:
        return None
    uniq = sorted(set(digests))
    return "emission split: %d distinct SHA-256 (%s)" % (len(uniq),
                                                         ", ".join(u[:12] for u in uniq))


def first_diff(path_a, path_b, context=120):
    """First differing offset between two files, with surrounding bytes."""
    with open(path_a, "rb") as fa, open(path_b, "rb") as fb:
        a = fa.read()
        b = fb.read()
    off = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y),
               min(len(a), len(b)))
    return ("first difference at byte %d (len %d vs %d)" % (off, len(a), len(b)),
            repr(a[max(0, off - context):off + context][:240]),
            repr(b[max(0, off - context):off + context][:240]))


def self_test():
    cases = [
        ("three identical digests agree",
         ("a" * 64, "a" * 64, "a" * 64), None),
        ("one different digest is signal",
         ("a" * 64, "b" * 64, "a" * 64), "2 distinct"),
        ("three-way split names all three",
         ("a" * 64, "b" * 64, "c" * 64), "3 distinct"),
    ]
    passed = 0
    for title, digests, want in cases:
        got = compare_emissions(digests)
        good = (got is None) if want is None else (got and want in got)
        if good:
            passed += 1
            print("  ok    %-42s -> %s" % (title, got or "agree"))
        else:
            out.fail("  WRONG %-39s -> %s (wanted %s)"
                     % (title, got or "agree", want or "agree"))
    # first_diff on synthetic files: same bytes agree at the length.
    tmp = tempfile.mkdtemp(prefix="orbit_triangle_selftest_")
    try:
        pa = os.path.join(tmp, "a.c")
        pb = os.path.join(tmp, "b.c")
        open(pa, "wb").write(b"int x = 1;\n")
        open(pb, "wb").write(b"int x = 2;\n")
        desc, ra, rb = first_diff(pa, pb)
        good = "byte 8" in desc and "1" in ra and "2" in rb
        if good:
            passed += 1
            print("  ok    %-42s -> %s" % ("first_diff locates the byte", desc))
        else:
            out.fail("  WRONG first_diff -> %s" % desc)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    out.finish("triangle self-test", passed, len(cases) + 1)
    return 0 if passed == len(cases) + 1 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="DDC triangle: tcc vs gcc-O0 vs gcc-O2 on the canonical")
    ap.add_argument("--cc", default=None,
                    help="gcc-side C driver (default: ORBIT_CC/CC/gcc)")
    ap.add_argument("--tcc", default=None,
                    help="tcc driver (default: ORBIT_TCC/which tcc/carril-T portable)")
    ap.add_argument("--tcc-shim", default=None)
    ap.add_argument("--timeout", type=int, default=900,
                    help="seconds per step (default: 900)")
    ap.add_argument("--work", default=None)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    if args.self_test:
        return self_test()

    gcc = args.cc or _common.resolve_cc()
    tcc = resolve_tcc(args.tcc)
    if not tcc:
        out.fail("Failed triangle: no tcc driver found (pass --tcc PATH or "
                 "set ORBIT_TCC). Substitute mode --tcc <gcc> validates the "
                 "harness without tcc.")
        return 2
    substitute = tcc == gcc
    shimdir = None
    if not substitute and os.name == "nt":
        shimdir = resolve_tcc_shim(args.tcc_shim, tcc)
        if not shimdir or not os.path.isdir(shimdir):
            out.fail("Failed triangle: tcc on Windows needs a winsock shim "
                     "(pass --tcc-shim DIR).")
            return 2
        if shim_header(shimdir) is None:
            out.fail("Failed triangle: shim dir %s has neither tccenv.h nor "
                     "tcc_toolchain.h." % shimdir)
            return 2

    if not os.path.isfile(CANONICAL_C):
        out.fail("Failed triangle: %s is missing; it is the root of trust." % CANONICAL_C)
        return 1

    if args.work:
        work = os.path.abspath(args.work)
        os.makedirs(work, exist_ok=True)
    else:
        work = tempfile.mkdtemp(prefix="orbit_triangle_")
    if not args.keep and not args.work:
        import atexit
        atexit.register(lambda: shutil.rmtree(work, ignore_errors=True))

    exe = ".exe" if os.name == "nt" else ""
    link_flags = ["-lws2_32"] if os.name == "nt" else []

    # 1. Amalgamate once: same invocation verify_seed.py uses, so the input
    #    TU is byte-identical to the seed build's by construction.
    amal = os.path.join(work, "triangle_unit.c")
    out.say("Amalgamating the canonical ...")
    run_logged([sys.executable, os.path.join(ROOT, "scripts", "amalgamate.py"),
                "--entry", CANONICAL_C, "--out", amal],
               ROOT, dict(os.environ), args.timeout, "amalgamate")
    out.say("Unit: %s (%d bytes)" % (amal, os.path.getsize(amal)))

    # 2. One judge binary per arm. No ccache and no brand stamp: disposable
    #    judges, timed as real builds.
    workshim = os.path.join(work, "tcc_shim")
    os.makedirs(workshim, exist_ok=True)
    with open(os.path.join(workshim, "tcc_dual.h"), "w",
              encoding="utf-8", newline="\n") as fh:
        fh.write(TCC_DUAL_HEADER)
    tcc_extras = []
    if not substitute:
        if os.name == "nt":
            tcc_extras += ["-I" + shimdir, "-include", shim_header(shimdir) or "tccenv.h"]
        tcc_extras += ["-I" + workshim, "-include", "tcc_dual.h"]
        if os.name == "nt":
            tcc_extras += [ADVAPI32]
    arms = [
        ("tcc", tcc, ["-DORBIT_WITH_EXEC"] + tcc_extras),
        ("gcc-O0", gcc, ["-s", "-O0", "-DORBIT_WITH_EXEC"]),
        ("gcc-O2", gcc, ["-s", "-O2", "-DORBIT_WITH_EXEC"]),
    ]
    if substitute:
        arms[0] = ("tcc(=gcc)", gcc, ["-s", "-O0", "-DORBIT_WITH_EXEC"])
    judges = {}
    cc_secs = {}
    for tag, driver, flags in arms:
        judge = os.path.join(work, "judge_" + tag.replace("(", "").replace(")", "").replace("=", "") + exe)
        # shlex, not split: a driver may be a wrapper with args ("ccache gcc")
        # or a quoted path with spaces.
        argv = shlex.split(driver, posix=False) + flags + ["-o", judge, amal] + link_flags
        out.say("Building judge %s ..." % tag)
        cc_secs[tag] = run_logged(argv, ROOT, dict(os.environ),
                                  args.timeout, "cc %s" % tag)
        judges[tag] = judge
        out.say("Judge %s built in %.1fs" % (tag, cc_secs[tag]))

    # 3. Each judge emits the compiler C. ORBIT_SKIP_CC=1: the judge writes
    #    its intermediate C and stops; its inner cc is never invoked, so the
    #    driver named here is irrelevant and gcc is the honest default.
    emits = {}
    emit_secs = {}
    for tag, judge in judges.items():
        armtmp = os.path.join(work, "emit_" + tag.replace("(", "").replace(")", "").replace("=", ""))
        os.makedirs(armtmp, exist_ok=True)
        env = dict(os.environ)
        env.update({"TEMP": armtmp, "TMP": armtmp, "TMPDIR": armtmp,
                    "ORBIT_CC": gcc, "CC": gcc, "ORBIT_SKIP_CC": "1",
                    "ORBIT_WARNINGS": "0", "ORBIT_CCFLAGS_EXTRA": ""})
        out_exe = os.path.join(work, "prog_" + tag + exe)
        label = "emit %s" % tag
        out.say("Emitting with judge %s ..." % tag)
        t0 = time.monotonic()
        proc = subprocess.run([judge, "build", MAIN_ORB, "-o", out_exe],
                              cwd=ROOT, env=env, capture_output=True,
                              text=True, errors="replace",
                              timeout=args.timeout)
        emit_secs[tag] = time.monotonic() - t0
        combined = (proc.stdout or "") + (proc.stderr or "")
        if combined.strip():
            print(combined.rstrip())
        # Tolerated non-zero exit, same as verify_seed.py's orb_build: the
        # contract is the emitted C, and the inner cc never ran. Missing C
        # is the failure, not the exit code.
        src_c = os.path.join(armtmp, "orbit_selfhost_build.c")
        if not os.path.isfile(src_c):
            out.fail("Failed %s (rc=%d): no C emitted" % (label, proc.returncode))
            return 1
        snap = os.path.join(work, "emit_%s.c" % tag.replace("(", "").replace(")", "").replace("=", ""))
        shutil.copyfile(src_c, snap)
        emits[tag] = snap
        out.say("Judge %s emitted %d bytes in %.1fs (rc=%d)" %
                (tag, os.path.getsize(snap), emit_secs[tag], proc.returncode))

    # 4. The gate: three identical digests.
    tags = list(judges.keys())
    digests = [sha256(emits[t]) for t in tags]
    for t, d in zip(tags, digests):
        out.say("  %s: %s" % (t, d))
    desc = compare_emissions(digests)
    for t in tags:
        out.say("  time %-10s cc=%.1fs emit=%.1fs" % (t, cc_secs[t], emit_secs[t]))
    if desc is not None:
        out.fail("Failed triangle: TOOLCHAIN SIGNAL -- %s" % desc)
        shown = set()
        for i in range(len(tags)):
            for j in range(i + 1, len(tags)):
                if digests[i] != digests[j]:
                    key = tuple(sorted((digests[i], digests[j])))
                    if key not in shown:
                        shown.add(key)
                        d, ra, rb = first_diff(emits[tags[i]], emits[tags[j]])
                        out.fail("  %s vs %s: %s" % (tags[i], tags[j], d))
                        print("    %s: %s" % (tags[i], ra), file=sys.stderr)
                        print("    %s: %s" % (tags[j], rb), file=sys.stderr)
        out.ci_error("[orbit-triangle] %s" % out.scrub_ci(desc))
        return 1
    out.finish("triangle", 3, 3, extra="(SHA-256 %s...)" % digests[0][:16])
    out.say("Triangle agrees on %s" % digests[0])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
