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
  steps         optional; shell commands run INSTEAD of one doctor run, one per
                line, with {orbit} replaced by the compiler. expected.txt is
                their concatenated stdout. This is the only way to test a cache:
                a cache bug is by definition invisible to a single run, because
                the wrong answer is the one already on disk.

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
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _common import build_env, scratch  # noqa: E402

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


def inject_repo_paths(args: list) -> list:
    """Point any path a case left implicit at the repository copy.

    Each case runs from a throwaway copy of its own directory, so a case that
    reads a file outside that directory -- ENGINEERING.md for the latency budget,
    which D033 enforces -- would find nothing. The fixtures must not depend on the
    runner's working directory, and the runner must not have to be run from the
    repo root to work.
    """
    out = []
    i = 0
    while i < len(args):
        if args[i] in ("--budget-doc",) and i + 1 < len(args):
            if args[i + 1] == "ENGINEERING.md":
                out.append(args[i])
                out.append(str(REPO / "ENGINEERING.md"))
                i = i + 2
                continue
        out.append(args[i])
        i = i + 1
    return out


def read_rc(case: pathlib.Path) -> int:
    rc_file = case / "expect_rc"
    if not rc_file.exists():
        return 1
    return int(rc_file.read_text().strip())


# Files that belong to the gate rather than to the scanned tree.
META = {"expected.txt", "args", "expect_rc", "expect_crlf", "expect_unchanged",
        "allow_stderr", "steps", "scan"}


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


def run_steps(compiler: str, case: pathlib.Path, work: str, env: dict) -> str:
    """Runs the case's step list and returns the concatenated stdout."""
    out = ""
    for line in (case / "steps").read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        proc = subprocess.run(line.replace("{orbit}", compiler), shell=True,
                              capture_output=True, text=True, cwd=work, env=env)
        out += strip_toolchain(proc.stdout)
    return out


def cases_needing_c_step(case: pathlib.Path) -> bool:
    """True when this case runs --fix, and so verifies through the C step."""
    args = read_args(case)
    return "--fix" in args


def stage_compiler_with_runtime(compiler: str):
    """A compiler invocation that sits beside the runtime headers, or None.

    The emitted C includes socket_compat.h by bare name, and the C backend
    resolves that next to the COMPILER binary. CI builds the fixed point into
    RUNNER_TEMP, so it is nowhere near runtime/ and every --fix case cannot
    compile its own result.

    The earlier answer to that was to skip those cases and say so. That is what
    made this gate fail in CI: doctor_gate.py then printed no
    "Finished doctor_gate: N case(s)" line, alive_check.py saw no marker, and
    reported the gate DEAD. A skipped check reported as a passed check, caught
    by the tool that watches the other tools.

    So the cases run. This makes a directory holding a link to the binary and
    copies of the headers that the include names resolve to, and hands that
    path back. The binary is linked, not copied: it is tens of megabytes and the
    gate already rebuilds it upstream.
    """
    shim = pathlib.Path(tempfile.mkdtemp(prefix="doctor_gate_shim_"))
    try:
        link = shim / ("orbit_fixed_point" + (".exe" if os.name == "nt" else ""))
        try:
            link.symlink_to(compiler)
        except OSError:
            shutil.copy2(compiler, link)
        # compilerRuntimeDir (compiler/host/pipeline.orb:205) resolves the runtime as
        # <dir of argv[0]>/runtime and falls back to the relative "runtime", so
        # the headers have to sit in a `runtime` SUBDIRECTORY next to the binary.
        # Copying them flat next to it does not work, and does so quietly: the
        # compile fails on socket_compat.h with no hint that the directory name
        # was the difference.
        # The whole tree, not just the headers: the generated C includes
        # "socket_compat.h" AND "thread_pool.c", because the runtime's own
        # sources are compiled into the unit. Copying *.h alone gets one step
        # further and then fails on the first .c include, which looks like a
        # different problem.
        shutil.copytree(REPO / "runtime", shim / "runtime",
                        ignore=shutil.ignore_patterns("__pycache__", "*.o", "*.exe"))
        return str(link)
    except OSError as exc:
        shutil.rmtree(shim, ignore_errors=True)
        print(f"  shim failed: {exc}")
        return None


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


# --------------------------------------------------------------------------
# --scope-only: doctor over the directories that must have no findings.
#
# The interesting thing this encodes is what it does NOT cover. `orbit doctor .`
# over this repository reports 196 findings, and nearly all of them are
# directories that are supposed to be broken:
#
#   57 D008  in tests/negative, tests/doctor and tests/parity -- fixtures that
#            must not compile, and whose whole purpose is to not compile
#  105 D002  route collisions inside those same corpora, plus 17 across
#            examples/, which is a directory of INDEPENDENT services and whose
#            five GET /health handlers are five services, not one bug
#
# Baselining those would mean a file of 196 lines vouching for a state nobody
# wants. Naming the directories that must be clean says what we actually mean,
# and says it in one screen instead of 196.
#
# examples/ is absent on purpose. A tree scan reads independent services as one
# program's route table, which is the correct analysis of the wrong input; scan it
# per service when that is the question. docs/DOCTOR.md documents this.
#
# This used to be scripts/doctor_scope_gate.py. It is a mode of this gate now
# because the two shared everything but the scan loop: the scratch environment,
# the compiler, and the finding-line parser. One file, one row.
# --------------------------------------------------------------------------

# Directories that must produce zero findings. Adding one here is a claim that
# the directory is clean, so it belongs in the same commit as whatever made it
# clean.
SCOPE_CLEAN_DIRS = ["compiler", "std", "tests/suite"]

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
SCOPE_ADVISORY_BY_FILE = {
    "tests/suite/call_arg_types.orb": {"D021"},
    # This file pins shadowing semantics: it declares `val v` inside an
    # `if` and reads the outer one after, on purpose. D023 finds exactly
    # those two declarations and nothing else in the tree. The clobber bug
    # behind the pin is fixed (distinct C symbol per declaration); the
    # exemption stays because the pattern is still in the file by design.
    "tests/suite/scope_shadow_clobbers_outer.orb": {"D023"},
    # These construct a `result` on purpose -- one ok, one err -- and call both
    # without handling them, because building the values is what the test is for.
    # `make_failure()` really does discard its error, which is D027's exact claim;
    # the code is right for the file's purpose and the check is right about it.
    "tests/suite/result_values.orb": {"D027"},
    "tests/suite/result_try.orb": {"D027"},
}

# Codes exempt in every directory.
SCOPE_GLOBAL_ADVISORY_CODES = {"D015", "D017", "D018"}


def scope_advisory_codes_for(rel_path: str) -> set:
    """Codes that do not fail this specific file."""
    out = set(SCOPE_GLOBAL_ADVISORY_CODES)
    out |= SCOPE_ADVISORY_BY_FILE.get(rel_path, set())
    return out


def run_scope(compiler: str) -> int:
    """Doctor over the clean dirs; fail on any non-advisory finding."""
    env, _scratch = scratch_env()

    failures = []
    for d in SCOPE_CLEAN_DIRS:
        target = REPO / d
        if not target.is_dir():
            print(f"doctor_gate --scope-only: {d} does not exist; the list is stale")
            return 1
        proc = subprocess.run(
            [compiler, "doctor", d, "--color", "never"],
            capture_output=True, text=True, cwd=REPO, env=env,
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
            exempt = scope_advisory_codes_for(f"{d}/{loc.split(':', 1)[0]}")
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
        print(f"doctor_gate --scope-only: {len(failures)} of {len(SCOPE_CLEAN_DIRS)} directory(ies) not clean")
        return 1
    print(f"Finished doctor_scope: {len(SCOPE_CLEAN_DIRS)} directories clean ({', '.join(SCOPE_CLEAN_DIRS)}).")
    return 0


def compiler_can_reach_runtime(compiler: str) -> bool:
    """Whether the C step can work for a compiler at this path.

    A case that runs --fix verifies its result by compiling it, and the emitted C
    includes "socket_compat.h" by bare name. compilerRuntimeDir resolves that
    against <dir of argv[0]>/runtime, so a compiler outside the repository cannot
    compile anything and every --fix golden fails with a confusing error about
    the user's file.

    Checked here, and reported as a broken environment rather than as 6 failing
    goldens: the two are very different things and only one of them is a bug in
    the tree.

    The predicate used to be `startswith(repo + os.sep)`, which was wrong and
    cost a confusing failure. It claims that ANY compiler inside the repository
    can reach the runtime, which is true of a binary at the repository root --
    `runtime/` sits beside it -- and false of everything deeper in the tree. A
    compiler at `.orbit/tmp/orbit-fp-...` is inside the repo, bindir is
    `<repo>/.orbit/tmp`, no runtime is beside it, and the lookup falls through to
    the relative "runtime", which for a --fix golden means the throwaway staged
    copy. Three goldens then failed with "the result does not compile", a message
    that says nothing about the cause, and the real cause was one directory level
    of this function. The predicate is now: a runtime beside the binary, or the
    binary at the repository root itself.
    """
    bindir = os.path.dirname(os.path.abspath(compiler))
    if os.path.isdir(os.path.join(bindir, "runtime")):
        return True
    return os.path.abspath(bindir) == str(REPO)


def run_case(compiler: str, case: pathlib.Path, env: dict) -> tuple:
    if (case / "steps").exists():
        # A steps case names its own commands; it does not need a scan target,
        # and the exit code it asserts is the last command's.
        with tempfile.TemporaryDirectory(prefix="doctor_gate_") as work:
            stage_case(case, work)
            combined = run_steps(compiler, case, work, env)
            if (case / "expect_crlf").exists():
                bad = check_crlf(case, work)
                if bad:
                    return None, f"{case.name}: {bad}"
            if (case / "expect_unchanged").exists():
                bad = check_unchanged(case, work)
                if bad:
                    return None, f"{case.name}: steps changed the tree: {bad}"
        proc = subprocess.CompletedProcess(["steps"], 0, combined, "")
        return proc, None
    scan_file = case / "scan"
    if not scan_file.exists():
        return None, f"{case.name}: missing scan"
    rel = scan_file.read_text().strip()
    if not rel:
        return None, f"{case.name}: empty scan"
    cmd = [compiler, "doctor", rel] + BASE_ARGS + inject_repo_paths(read_args(case))
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
    ap.add_argument("--scope-only", action="store_true",
                    help="only the clean-directories check over compiler, std "
                         "and tests/suite (was scripts/doctor_scope_gate.py)")
    args = ap.parse_args()

    compiler = os.path.abspath(args.compiler)
    if not os.path.exists(compiler):
        print(f"doctor_gate: no compiler at {compiler}")
        return 1

    if args.scope_only:
        return run_scope(compiler)

    if not GOLDEN.is_dir():
        print(f"doctor_gate: no goldens at {GOLDEN}")
        return 1

    cases = sorted(p for p in GOLDEN.iterdir() if p.is_dir())
    if not cases:
        print("doctor_gate: no cases found")
        return 1

    needs_c = [c for c in cases if cases_needing_c_step(c)]
    if needs_c and not compiler_can_reach_runtime(compiler):
        compiler = stage_compiler_with_runtime(compiler)
        if compiler is None:
            print(f"doctor_gate: {len(needs_c)} case(s) verify through the C step and "
                  f"{args.compiler} cannot resolve the runtime headers, and the shim "
                  f"could not be built either.")
            return 1

    failures = []

    def run_one(case):
        # Each case owns a TEMP dir: run_case already stages its own CWD
        # copy, but --fix cases verify through the C step and every build
        # writes orbit_selfhost_build.c to $TEMP, so a shared TEMP lets one
        # case's cc read another's half-written C. Returns (case, proc, err)
        # for ordered reporting below; only the main thread prints.
        env, _scratch = scratch_env()
        proc, err = run_case(compiler, case, env)
        return (case, proc, err)

    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        results = list(pool.map(run_one, cases))
    for case, proc, err in results:
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
        # Say WHICH assertion failed and where the two texts diverge, before
        # dumping either. A CI log that shows 1200 characters of "expected" and
        # then truncates answers no question; the first differing line answers
        # it. When the assertion is not a text comparison ("exit 1", "no stderr")
        # there is nothing to point at and the dump stands on its own.
        if want and got and "\n" in want and "\n" in got:
            wl, gl = want.splitlines(), got.splitlines()
            for n in range(max(len(wl), len(gl))):
                a = wl[n] if n < len(wl) else "<missing>"
                b = gl[n] if n < len(gl) else "<missing>"
                if a != b:
                    print(f"  first difference at output line {n + 1}:")
                    print(f"    expected: {a[:200]}")
                    print(f"    actual:   {b[:200]}")
                    break
        print("  expected: " + want.replace("\n", "\n  ")[:1200])
        print("  actual:   " + got.replace("\n", "\n  ")[:1200])
    if failures:
        print(f"doctor_gate: {len(failures)} failure(s) in {len(cases)} case(s)")
        return 1
    print(f"Finished doctor_gate: {len(cases)} case(s) matched their goldens.")
    return 0


if __name__ == "__main__":
    sys.exit(main())