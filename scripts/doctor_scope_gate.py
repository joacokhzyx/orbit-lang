#!/usr/bin/env python3
"""Doctor over the directories that must have no findings.

The interesting thing this encodes is what it does NOT cover. `orbit doctor .`
over this repository reports 196 findings, and nearly all of them are
directories that are supposed to be broken:

  57 D008  in tests/negative, tests/doctor and tests/parity -- fixtures that
           must not compile, and whose whole purpose is to not compile
 105 D002  route collisions inside those same corpora, plus 17 across
           examples/, which is a directory of INDEPENDENT services and whose
           five GET /health handlers are five services, not one bug

Baselining those would mean a file of 196 lines vouching for a state nobody
wants. Naming the directories that must be clean says what we actually mean, and
says it in one screen instead of 196.

examples/ is absent on purpose. A tree scan reads independent services as one
program's route table, which is the correct analysis of the wrong input; scan it
per service when that is the question. docs/DOCTOR.md documents this.
"""

import argparse
import os
import pathlib
import subprocess
import sys

# Directories that must produce zero findings. Adding one here is a claim that
# the directory is clean, so it belongs in the same commit as whatever made it
# clean.
CLEAN_DIRS = ["compiler", "std", "tests/suite"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", required=True)
    args = ap.parse_args()

    repo = pathlib.Path(__file__).resolve().parent.parent
    compiler = os.path.abspath(args.compiler)
    if not os.path.exists(compiler):
        print(f"doctor_scope_gate: no compiler at {compiler}")
        return 1

    env = dict(os.environ)
    env.setdefault("TEMP", "/tmp/scent")
    env.setdefault("TMP", "/tmp/scent")

    failures = []
    for d in CLEAN_DIRS:
        target = repo / d
        if not target.is_dir():
            print(f"doctor_scope_gate: {d} does not exist; the list is stale")
            return 1
        proc = subprocess.run(
            [compiler, "doctor", d, "--color", "never"],
            capture_output=True, text=True, cwd=repo, env=env,
        )
        # A finding line reads "<file>:<line> <severity> [Dnnn] ...". Doctor
        # prints paths RELATIVE TO THE SCANNED DIRECTORY, so a finding in
        # examples/ starts with "sqlite_notes.orb", not "examples/sqlite_notes.
        # orb" -- filtering on the directory prefix matches nothing at all, which
        # is how this gate would have passed forever while checking nothing. The
        # reliable signal is the shape: a colon, digits, then a severity word.
        findings = []
        for line in proc.stdout.splitlines():
            parts = line.split(None, 2)
            if len(parts) < 3:
                continue
            loc, severity = parts[0], parts[1]
            if severity not in ("error", "warning"):
                continue
            _, _, lineno = loc.rpartition(":")
            if lineno.isdigit() and "[D" in parts[2]:
                findings.append(line)

        if findings:
            print(f"FAIL {d}: {len(findings)} finding(s) in a directory that must be clean")
            for line in findings:
                print("  " + line)
            failures.append(d)

    if failures:
        print(f"doctor_scope_gate: {len(failures)} of {len(CLEAN_DIRS)} directory(ies) not clean")
        return 1
    print(f"Finished doctor_scope: {len(CLEAN_DIRS)} directories clean ({', '.join(CLEAN_DIRS)}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
