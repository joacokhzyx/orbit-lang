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
import tempfile
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _common import build_env, scratch  # noqa: E402

# Directories that must produce zero findings. Adding one here is a claim that
# the directory is clean, so it belongs in the same commit as whatever made it
# clean.
def scratch_env(parent_env=None):
    """A copy of the environment with TEMP/TMP pointing at a directory that exists.

    Both used to default to /tmp/scent, which is a directory this machine
    happens to have because of how the compiler was built here, and which does
    not exist on a CI runner. The failure mode was silent and misattributed: the
    compiler could not write its intermediate C file, so every --fix golden
    reported "the result does not compile", which reads as a broken golden rather
    than a missing directory, and the three goldens that need the C step failed
    with nothing in the message about the actual cause.

    Created here rather than assumed, and never reused, because a stale
    orbit_selfhost_build.c from a previous run is worse than no directory.
    """
    tmp = scratch()
    return build_env(tmp, parent=parent_env), tmp


CLEAN_DIRS = ["compiler", "std", "tests/suite"]

# Codes that do NOT fail the scope gate even though the directories are clean.
#
# D015 is a performance observation, not a defect to fix. It fires on
# `joined = joined + tag` inside a loop, which is quadratic in the collection's
# length -- true, and correct in a five-element test whose whole purpose is to
# assert that the concatenation produces "red,blue,". A test that verifies a
# pattern cannot also be told to stop using it. It fired on real code too:
# std/string/string.orb had three quadratic loops, now fixed, and those fixes
# are worth more than the rule that found them.
#
# D017 joins it: a test whose main asserts fifteen separate behaviours IS a function
# of complexity 20, and telling it to extract sub-functions would be advice
# about the test, not the code.
#
# D021 joins them: tests/suite/call_arg_types.orb defines
# `fn takesFloat(f: float) -> int { return 1 }`. The parameter exists so the
# test can hand it a float and pin E1005 argument-type checking; the body
# deliberately ignores it, because a return value that depended on the argument
# would make `takesFloat(1.5)` and `takesFloat(2)` assert different things and
# the test would stop being about types. Removing the parameter would remove the
# coverage. The check is still true of that code, and it is not advisory
# anywhere else: compiler/ and std/ are clean under it.
#
# A code goes here only when "the code is right and the check is still true" is
# the normal case. That is not true of the other codes here, which is why this
# list has one entry.
# D021 is exempt from ONE file, not from the tree. It was listed in the plain set
# above first, which looked right and was not: the set is global, so exempting
# D021 for tests/suite/call_arg_types.orb also exempted it for compiler/, where
# it has eight true findings. A gate that cannot say "clean here, except there"
# will report clean everywhere the moment you exempt one file.
ADVISORY_BY_FILE = {
    "tests/suite/call_arg_types.orb": {"D021"},
    # This file exists to pin the shadowing bug: it declares `val v` inside an
    # `if` and reads the outer one after, on purpose, because that program
    # returns 20 where it means 10. D023 finds exactly those two clobbers and
    # nothing else in the tree, which is the check working. Exempting the file is
    # the same call as D021's: the code is wrong on purpose and the check is
    # right about it.
    "tests/suite/scope_shadow_clobbers_outer.orb": {"D023"},
    # These construct a `result` on purpose -- one ok, one err -- and call both
    # without handling them, because building the values is what the test is for.
    # `make_failure()` really does discard its error, which is D027's exact claim;
    # the code is right for the file's purpose and the check is right about it.
    "tests/suite/result_values.orb": {"D027"},
    "tests/suite/result_try.orb": {"D027"},
}

# Codes exempt in every directory.
GLOBAL_ADVISORY_CODES = {"D015", "D017", "D018"}


def advisory_codes_for(rel_path: str) -> set:
    """Codes that do not fail this specific file."""
    out = set(GLOBAL_ADVISORY_CODES)
    out |= ADVISORY_BY_FILE.get(rel_path, set())
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", required=True)
    args = ap.parse_args()

    repo = pathlib.Path(__file__).resolve().parent.parent
    compiler = os.path.abspath(args.compiler)
    if not os.path.exists(compiler):
        print(f"doctor_scope_gate: no compiler at {compiler}")
        return 1

    env, _scratch = scratch_env()

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
        # A doctor that was OOM-killed, or died on a signal, produces no
        # findings. Treating that as "clean" is the worst failure this gate can
        # have: it is green because it checked nothing. `doctor compiler` needs
        # ~1.4 GB on c_backend.orb alone, so on a loaded machine the process
        # really does get SIGTERMed, and it has already happened here.
        # doctor exits 1 when it has findings, which is the normal case here,
        # so only a code outside {0, 1} means the run is untrustworthy: a
        # negative code is a signal (OOM-killed or crashed), which is what turns
        # an empty report into a green gate.
        if proc.returncode not in (0, 1):
            how = "was killed by a signal" if proc.returncode < 0 else "exited"
            print(f"FAIL {d}: doctor {how} ({proc.returncode}), so its output "
                  f"cannot be read as 'clean'")
            if proc.stderr.strip():
                print("  stderr: " + proc.stderr.strip().splitlines()[-1])
            failures.append(d)
            continue

        # A finding line reads "<file>:<line> <severity> [Dnnn] ...". Doctor
        # prints paths RELATIVE TO THE SCANNED DIRECTORY, so a finding in
        # examples/ starts with "sqlite_notes.orb", not "examples/sqlite_notes.
        # orb" -- filtering on the directory prefix matches nothing at all, which
        # is how this gate would have passed forever while checking nothing. The
        # reliable signal is the shape: a colon, digits, then a severity word.
        findings = []
        advisory = 0
        for line in proc.stdout.splitlines():
            parts = line.split(None, 2)
            if len(parts) < 3:
                continue
            loc, severity = parts[0], parts[1]
            if severity not in ("error", "warning"):
                continue
            _, _, lineno = loc.rpartition(":")
            if not (lineno.isdigit() and "[D" in parts[2]):
                continue
            code = parts[2].split("[", 1)[1].split("]", 1)[0]
            exempt = advisory_codes_for(f"{d}/{loc.split(':', 1)[0]}")
            if code in exempt:
                advisory += 1
                continue
            findings.append(line)
        if advisory:
            print(f"note: {d}: {advisory} advisory finding(s) not counted")

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
