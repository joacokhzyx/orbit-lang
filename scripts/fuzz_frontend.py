#!/usr/bin/env python3
"""Frontend fuzzer (R1.2): the compiler must never crash natively.

Contract: for ANY input file, `orbit build` exits 0 (accepted) or 1
(clean diagnostics). Any other exit code (native crash, access
violation, stack overflow) is a bug; the offending input is saved.

Mutations over the probe corpus: truncation, byte flips, deep nesting,
quote injection, identifier soup, NUL bytes.

Usage:
    python scripts/fuzz_frontend.py --compiler PATH [--iterations N] [--seed S]
Exit 0 iff no crash found.
"""

import argparse
import os
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBES = os.path.join(ROOT, "tests", "parity", "probes")
CRASH_DIR = os.path.join(ROOT, "fuzz_crashes")

DEEP_TOKENS = ["(", "{", "[", "match x { ", "if a { ", "while b { ", "\"", "$"]


def mutate(src: bytes, rng: random.Random) -> bytes:
    kind = rng.randrange(6)
    if kind == 0:  # truncate
        return src[: rng.randrange(0, max(1, len(src)))]
    if kind == 1:  # byte flips
        b = bytearray(src)
        for _ in range(rng.randrange(1, 8)):
            if b:
                b[rng.randrange(len(b))] = rng.randrange(256)
        return bytes(b)
    if kind == 2:  # deep nesting prefix
        tok = rng.choice(DEEP_TOKENS)
        depth = rng.randrange(50, 4000)
        return (tok * depth).encode() + src
    if kind == 3:  # quote injection
        return src + b'"' * rng.randrange(1, 200)
    if kind == 4:  # identifier soup
        junk = "".join(rng.choice("abcXYZ_09") for _ in range(rng.randrange(5, 60))).encode()
        i = rng.randrange(0, max(1, len(src)))
        return src[:i] + junk + src[i:]
    # 5: NUL / control bytes injection
    i = rng.randrange(0, max(1, len(src)))
    return src[:i] + bytes([0]) * rng.randrange(1, 20) + src[i:]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", required=True)
    ap.add_argument("--iterations", type=int, default=300)
    ap.add_argument("--seed", type=int, default=1337)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    corpus = []
    for f in sorted(os.listdir(PROBES)):
        if f.endswith(".orb"):
            corpus.append(open(os.path.join(PROBES, f), "rb").read())
    if not corpus:
        print("[fuzz] FAIL: empty corpus")
        return 1

    work = tempfile.mkdtemp(prefix="orbit_fuzz_")
    os.makedirs(CRASH_DIR, exist_ok=True)
    crashes = 0
    clean_rejects = 0
    accepted = 0
    for i in range(args.iterations):
        src = mutate(rng.choice(corpus), rng)
        inp = os.path.join(work, f"case_{i}.orb")
        with open(inp, "wb") as fh:
            fh.write(src)
        env = dict(os.environ)
        noop_cc = "cmd /c exit 0" if os.name == "nt" else "true"
        env.update({"TEMP": work, "TMP": work, "ORBIT_CC": noop_cc, "CC": noop_cc})
        try:
            proc = subprocess.run(
                [args.compiler, "build", inp, "-o", os.path.join(work, f"out_{i}.bin")],
                cwd=ROOT, env=env, capture_output=True, timeout=120,
            )
            rc = proc.returncode
        except subprocess.TimeoutExpired:
            rc = -999
        if rc == 0:
            accepted += 1
        elif rc == 1:
            clean_rejects += 1
        else:
            crashes += 1
            safe = os.path.join(CRASH_DIR, f"crash_rc{rc}_case{i}.orb")
            shutil.copyfile(inp, safe)
            print(f"[fuzz] CRASH rc={rc} -> {safe}")
    print(f"\n[fuzz] {args.iterations} iterations: accepted={accepted} "
          f"clean-reject={clean_rejects} CRASHES={crashes}")
    print(f"[fuzz] work dir: {work}")
    return 1 if crashes else 0


if __name__ == "__main__":
    raise SystemExit(main())
