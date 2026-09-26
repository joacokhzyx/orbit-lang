#!/usr/bin/env python3
"""Self-host stability gate.

The contract is stability against committed goldens:

    every probe compiled by the fixed-point self-host compiler must produce
    exactly the recorded outcome (generated-C hash or normalized diagnostics).

There is no second implementation to compare against, so the goldens are the
contract rather than a cross-check. An intentional compiler change requires an
explicit golden refresh (`--update`) committed in the same commit as the
canonical C, the sources and PUBLISHED_C.

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

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
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    probes = sorted(f for f in os.listdir(PROBES) if f.endswith(".orb"))
    if not probes:
        out.fail("Failed parity: no probes found")
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
            out.say(f"Updated golden for {name} ({kind})")
            ok += 1
            continue

        if not os.path.isfile(golden_path):
            failed.append(name)
            out.fail(f"Failed {name}: no golden recorded")
            out.tip("run with --update to record it, then commit the golden")
            continue
        with open(golden_path, "r", encoding="utf-8", newline="") as f:
            expected = f.read().replace("\r\n", "\n")
        if expected == golden:
            ok += 1
            out.say(f"Checking {name} ... match ({kind})")
        else:
            failed.append(name)
            exp_lines = expected.split("\n")
            got_lines = golden.split("\n")
            detail = ""
            for i in range(min(len(exp_lines), len(got_lines))):
                if exp_lines[i] != got_lines[i]:
                    detail = f"(line {i+1}: expected '{exp_lines[i][:40]}' got '{got_lines[i][:40]}')"
                    break
            out.fail(f"Failed {name}: mismatch {detail}")
            payload = f"golden={expected[:200]!r} got={golden[:200]!r}"
            out.ci_error(f"[parity {name}] {out.scrub_ci(payload, 3800)}")

    total = len(probes)
    out.finish("parity", ok, total, "match goldens" if not failed else "")
    if failed:
        out.fail("Failed: " + ", ".join(failed))
    if failed and not args.update:
        # One consolidated annotation: survives even if per-probe commands
        # are dropped, and carries the expected/got payloads verbatim.
        parts = []
        for pf in probes:
            name = pf[:-4]
            if name in failed:
                gp = os.path.join(args.goldens, name + ".txt")
                exp = open(gp, encoding="utf-8", newline="").read() if os.path.isfile(gp) else "<missing>"
                rc, kind, payload = probe_outcome(args.compiler, os.path.join(PROBES, pf), name, work, args.cc or "")
                parts.append(f"{name}: rc={rc} kind={kind} | GOLDEN={exp[:150]!r} | GOT={payload[:150]!r}")
        blob = " || ".join(parts)
        out.ci_error(f"[parity diffs] {out.scrub_ci(blob, 3500)}")
    if args.update:
        out.say("Goldens refreshed; commit them together with the compiler change.")
        return 0
    return 0 if not failed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception:
        import traceback
        tb = traceback.format_exc()[-2500:]
        print(tb, file=sys.stderr)
        out.ci_error("[parity crash] " + out.scrub_ci(tb, 2500))
        raise
