#!/usr/bin/env python3
"""Self-host parity/stability gate (W2).

The original W1 battery proved byte-identity between the Zig FE lineage and
the self-host lineage across 25 probes. With the Zig seed retired (SOVER-1),
that contract becomes a STABILITY contract against committed goldens:

    every probe compiled by the fixed-point self-host compiler must produce
    exactly the recorded outcome (generated-C hash or normalized diagnostics).

Goldens were seeded from the W1-validated 25/25 state, so the historical
assurance carries over. Intentional compiler changes require an explicit
golden refresh (`--update`) committed alongside the change.

Probe outcomes:
  exit == 0  -> golden records the SHA-256 of the generated C
  exit != 0  -> golden records the normalized compiler diagnostics

Usage:
    python scripts/parity_selfhost.py --compiler PATH [--cc CC] [--update]
                                      [--goldens DIR] [--work DIR]

Exit code 0 iff every probe matches its golden.
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBES = os.path.join(ROOT, "tests", "parity", "probes")
GOLDENS = os.path.join(ROOT, "tests", "parity", "golden")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def normalize_diag(text: str) -> str:
    """Make diagnostics machine-independent: LF endings and forward slashes."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = text.replace("\\", "/")
    return text


def scrub_work_paths(text: str, work: str) -> str:
    """Replace the run's work/temp directories with <TMP> (longest first)."""
    needles = []
    for raw in (work, os.path.dirname(work), tempfile.gettempdir()):
        if raw:
            needles.append(raw)
            needles.append(raw.replace("\\", "/"))
    for n in sorted(set(needles), key=len, reverse=True):
        if n:
            text = text.replace(n, "<TMP>")
    return text


def probe_outcome(compiler: str, probe_path: str, name: str, work: str, cc: str):
    tmp = os.path.join(work, name)
    if os.path.isdir(tmp):
        shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp, exist_ok=True)
    env = dict(os.environ)
    env.update({"TEMP": tmp, "TMP": tmp, "ORBIT_CC": cc, "CC": cc})
    rel_probe = os.path.relpath(probe_path, ROOT)
    proc = subprocess.run(
        [compiler, "build", rel_probe, "-o", os.path.join(tmp, name + ".exe")],
        cwd=ROOT, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        errors="replace",
    )
    inter_c = os.path.join(tmp, "orbit_selfhost_build.c")
    if proc.returncode == 0 and os.path.isfile(inter_c):
        with open(inter_c, "rb") as f:
            return proc.returncode, "C", sha256_bytes(f.read())
    return proc.returncode, "DIAG", scrub_work_paths(normalize_diag(proc.stdout or ""), work)


def main() -> int:
    ap = argparse.ArgumentParser(description="Self-host stability gate vs goldens")
    ap.add_argument("--compiler", required=True, help="fixed-point orbit compiler executable")
    ap.add_argument("--cc", default=None, help="C compiler passed via ORBIT_CC/CC")
    ap.add_argument("--update", action="store_true", help="regenerate goldens instead of comparing")
    ap.add_argument("--goldens", default=GOLDENS, help="golden directory")
    ap.add_argument("--work", default=None, help="work directory (default: temp)")
    args = ap.parse_args()

    probes = sorted(f for f in os.listdir(PROBES) if f.endswith(".orb"))
    if not probes:
        print("[parity] FAIL: no probes found")
        return 1

    work = args.work or tempfile.mkdtemp(prefix="orbit_parity_")
    os.makedirs(args.goldens, exist_ok=True)

    ok = 0
    failed = []
    for pf in probes:
        name = pf[:-4]
        probe_path = os.path.join(PROBES, pf)
        rc, kind, payload = probe_outcome(args.compiler, probe_path, name, work, args.cc or "")
        golden_path = os.path.join(args.goldens, name + ".txt")
        golden = f"exit={rc}\nkind={kind}\n{payload}"

        if args.update:
            with open(golden_path, "w", encoding="utf-8", newline="\n") as f:
                f.write(golden)
            print(f"[parity] UPDATE {name:<24} {kind}")
            ok += 1
            continue

        if not os.path.isfile(golden_path):
            failed.append(name)
            print(f"[parity] MISSING-GOLDEN {name}")
            continue
        with open(golden_path, "r", encoding="utf-8", newline="") as f:
            expected = f.read()
        if expected == golden:
            ok += 1
            print(f"[parity] OK       {name:<24} {kind}")
        else:
            failed.append(name)
            exp_lines = expected.split("\n")
            got_lines = golden.split("\n")
            detail = ""
            for i in range(min(len(exp_lines), len(got_lines))):
                if exp_lines[i] != got_lines[i]:
                    detail = f"(line {i+1}: expected '{exp_lines[i][:40]}' got '{got_lines[i][:40]}')"
                    break
            print(f"[parity] DIFF     {name:<24} {detail}")
            payload = f"golden={expected[:200]!r} got={golden[:200]!r}".replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::error::[parity {name}] {payload}")

    total = len(probes)
    print(f"\n[parity] RESULT: {ok}/{total} match goldens"
          + ("" if not failed else "; FAILED: " + ", ".join(failed)))
    if args.update:
        print("[parity] goldens refreshed; commit them together with the compiler change.")
        return 0
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
