#!/usr/bin/env python3
"""Exact-output gate for `orbit doctor`.

The point of this gate is that a check which changes how it phrases itself is a
BREAKING change, not a cosmetic one. `cli_probe.py` proves the command runs and
exits right; this proves the words it prints are the words we agreed to print,
character for character. A new check can only be added here by adding its
golden, which is the moment someone has to decide what it is supposed to say.

Each case in tests/doctor/golden/ is a directory holding:

  scan          the path, relative to the case, that doctor is pointed at
  *.orb         the fixtures that scan refers to
  expected.txt  the exact stdout of `doctor <scan> --format text --color never`
  args          optional extra flags, one per line
  expect_rc     optional expected exit code (default 1: the case has findings)
  expect_crlf   optional; asserts every LF in the fixtures is part of a CRLF
  expect_unchanged  optional; asserts --dry-run really wrote nothing
  allow_stderr  optional; permits stderr, for cases whose finding IS a
                compiler diagnostic printed by the compiler

Each case runs against a throwaway COPY of its own directory. That is what lets
a case pass --fix or --dry-run and still mean the same thing tomorrow: the
fixtures in git are the pristine "before" state, and a fix case that mutated
them would silently become a no-op case the second time it ran.

`--update` rewrites every expected.txt from a live run. Deliberately: it is the
only way a golden changes, and it must be reviewed as a diff.
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
GOLDEN = REPO / "tests" / "doctor" / "golden"
# Color is forced off and the format is pinned: the golden is about the finding
# text, and on a terminal with color the escape codes would be part of it.
BASE_ARGS = ["--format", "text", "--color", "never"]


def read_args(case: pathlib.Path) -> list:
    """The flags for one case, as individual arguments.

    Split on whitespace: `args` is edited by hand in a review, and a whole line
    arriving as one argv entry would be an unknown flag, which is a confusing way
    to learn that a fixture has two flags on it.
    """
    args_file = case / "args"
    if not args_file.exists():
        return []
    return args_file.read_text().split()


def read_rc(case: pathlib.Path) -> int:
    rc_file = case / "expect_rc"
    if not rc_file.exists():
        return 1
    return int(rc_file.read_text().strip())


# Files that belong to the gate rather than to the scanned tree.
META = {"expected.txt", "args", "expect_rc", "expect_crlf", "expect_unchanged",
        "allow_stderr", "scan"}


def stage_case(case: pathlib.Path, work: str) -> None:
    """Copies the case's fixtures, and only its fixtures, into `work`."""
    for item in case.iterdir():
        if item.name in META:
            continue
        target = pathlib.Path(work) / item.name
        if item.is_dir():
            shutil.copytree(item, target)
        else:
            shutil.copy2(item, target)


def check_unchanged(case: pathlib.Path, work: str) -> str:
    """Returns a failure description, or "" when the staged tree is untouched."""
    for path in sorted(case.rglob("*.orb")):
        if path.name in META:
            continue
        staged = pathlib.Path(work) / path.relative_to(case)
        if not staged.exists():
            return f"{path.relative_to(case)}: disappeared"
        if staged.read_bytes() != path.read_bytes():
            return f"{path.relative_to(case)}: changed"
    return ""


def check_crlf(case: pathlib.Path, work: str) -> str:
    """Returns a failure description, or "" when the tree is all-CRLF."""
    for path in sorted(pathlib.Path(work).rglob("*.orb")):
        data = path.read_bytes()
        for i, byte in enumerate(data):
            if byte == 10 and (i == 0 or data[i - 1] != 13):
                rel = path.relative_to(work)
                return f"{rel}: lone LF at byte {i}; expected CRLF throughout"
    return ""


def run_case(compiler: str, case: pathlib.Path, env: dict) -> tuple:
    scan_file = case / "scan"
    if not scan_file.exists():
        return None, f"{case.name}: missing scan"
    rel = scan_file.read_text().strip()
    if not rel:
        return None, f"{case.name}: empty scan"
    cmd = [compiler, "doctor", rel] + BASE_ARGS + read_args(case)
    with tempfile.TemporaryDirectory(prefix="doctor_gate_") as work:
        stage_case(case, work)
        # cwd is the staged copy so the paths doctor prints -- and therefore the
        # goldens -- stay relative and identical on every machine.
        proc = subprocess.run(cmd, capture_output=True, text=True, cwd=work, env=env)
        proc.stdout = strip_toolchain(proc.stdout)
        if (case / "expect_crlf").exists():
            bad = check_crlf(case, work)
            if bad:
                return None, f"{case.name}: {bad}"
        if (case / "expect_unchanged").exists():
            bad = check_unchanged(case, work)
            if bad:
                return None, f"{case.name}: --dry-run changed the tree: {bad}"
    return proc, None


def strip_toolchain(out: str) -> str:
    """Drops the compiler probe line.

    It names the host C compiler and its version, so it is machine-specific by
    construction; a golden containing one would fail on every machine but this
    one. It is a probe, not a finding, and the gate is about findings.
    """
    return "".join(
        line + "\n"
        for line in out.splitlines()
        if not line.startswith("toolchain:")
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", required=True)
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--cc", default=None)
    args = ap.parse_args()

    compiler = os.path.abspath(args.compiler)
    if not os.path.exists(compiler):
        print(f"doctor_gate: no compiler at {compiler}")
        return 1

    env = dict(os.environ)
    env.setdefault("TEMP", "/tmp/scent")
    env.setdefault("TMP", "/tmp/scent")

    if not GOLDEN.is_dir():
        print(f"doctor_gate: no goldens at {GOLDEN}")
        return 1

    cases = sorted(p for p in GOLDEN.iterdir() if p.is_dir())
    if not cases:
        print("doctor_gate: no cases found")
        return 1

    failures = []
    for case in cases:
        proc, err = run_case(compiler, case, env)
        if err:
            failures.append((case.name, err, ""))
            continue
        expected = (case / "expected.txt")
        if args.update:
            expected.write_text(proc.stdout)
            print(f"updated {expected.relative_to(REPO)}")
            continue
        if not expected.exists():
            failures.append((case.name, f"no expected.txt (run with --update)", ""))
            continue
        want = expected.read_text()
        if proc.stdout != want:
            failures.append((case.name, want, proc.stdout))
        if proc.returncode != read_rc(case):
            failures.append(
                (case.name, f"exit {read_rc(case)}", f"exit {proc.returncode}")
            )
        # A D008 case points doctor at a file that does not compile, and the
        # compiler prints its own diagnostic while doctor is looking. That
        # output is the evidence behind the finding, not noise from doctor, so
        # such a case opts in with allow_stderr.
        if proc.stderr.strip() and not (case / "allow_stderr").exists():
            failures.append((case.name, "no stderr", proc.stderr.strip()[:400]))

    if args.update:
        print(f"doctor_gate: updated {len(cases)} golden(s)")
        return 0

    for name, want, got in failures:
        print(f"FAIL {name}")
        print("  expected: " + want.replace("\n", "\n  ")[:1200])
        print("  actual:   " + got.replace("\n", "\n  ")[:1200])
    if failures:
        print(f"doctor_gate: {len(failures)} failure(s) in {len(cases)} case(s)")
        return 1
    print(f"Finished doctor_gate: {len(cases)} case(s) matched their goldens.")
    return 0


if __name__ == "__main__":
    sys.exit(main())