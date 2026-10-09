#!/usr/bin/env python3
"""One entry point for the developer loop.

The gate sequence used to live in three places at once: prose in ENGINEERING.md
section 8, twenty-four inline steps in .github/workflows/ci-gate.yml, and what
the author of the day could remember. They disagreed -- section 8 step 10 ran
`orbit doctor tests/suite` while CI ran doctor_scope_gate.py, and ENGINEERING.md
records that the two "disagreed" and one of them went red. This script is the
fourth thing that knows the sequence, and the only one meant to be authoritative
for local work.

What it owns, because it used to be tribal knowledge:

  * TEMP/TMP. The fixed-point binary reads them at run time, and doctor_scope_gate
    created its scratch under the system temp. On a machine where the system temp
    is a different disk from /tmp, that both splits the compile cache across two
    filesystems and leaves runnable compilers behind when /tmp is cleaned.
  * ORBIT_CCACHE_DIR. Without it every bootstrap recompiles the 3.9 MB compiler
    unit from scratch: 24 s, versus a file copy.
  * The fixed-point binary path, and whether it is still fresh. Hand-named fp2,
    fp3, ... fp13 in the repository root were the previous mechanism.
  * Which flags each gate takes. Fourteen scripts accept --cc, fifteen accept
    --compiler, three accept neither, and doctor_gate.py accepts --cc and
    ignores it.

What it deliberately does not do, in this cut: drive the runtime C tests, the
Kynx live gate, routes_probe, the census, the differential fuzzer or the gate
self-tests. Those still live only in ci-gate.yml. Until they move here, `make
all` is NOT the same set CI runs, and this script says so on every run.

Tiers, and the reasoning behind the split:

  T0  static, no compiler. fmt on the checked-in form, Python syntax.
  T1  an existing orbit binary. Doctor goldens, doctor scope, CLI contract.
      These are the gates that caught the D028 false positives.
  T2  a freshly built fixed point. Language behaviour, negative corpus, parity,
      -Werror on generated C.
  T3  the root of trust. build_selfhost --check-stale and verify_seed.

`dev` picks a tier from what the working tree touched and always errs toward
running more. `check` runs T0..T2 unconditionally. `all` adds T3.

Consequence stated once, here, because it is the thing most likely to be
misread: a green `make dev` is NOT a green CI. dev runs T0+T1 by default and
says so at the end of every run.
"""

import argparse
import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORBIT = ROOT / ".orbit"
FP_STAMP = ORBIT / "fp.stamp"

# The repository has no Makefile and no task runner; this is the first of either.
# It is intentionally thin. Anything it knows, scripts/dev.py knows better, and
# a target that needed logic of its own would be logic with two copies.
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
OFF = "\033[0m"


def colour_enabled() -> bool:
    return sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def paint(text: str, code: str) -> str:
    return f"{code}{text}{OFF}" if colour_enabled() else text


def say(text: str) -> None:
    print(text, flush=True)


def child_env() -> dict:
    """The environment every gate runs under.

    TEMP and TMP are pointed inside the repository on purpose. They have to be
    set at all -- the fixed-point binary reads them -- but the system temp is
    not where a compile cache or a 90k-line C file belongs: it is a different
    filesystem on some machines, and it is the first thing anyone cleans up.
    """
    env = dict(os.environ)
    scratch = ORBIT / "tmp"
    scratch.mkdir(parents=True, exist_ok=True)
    ccache = ORBIT / "ccache"
    ccache.mkdir(parents=True, exist_ok=True)
    env["TEMP"] = str(scratch)
    env["TMP"] = str(scratch)
    env["ORBIT_CCACHE_DIR"] = str(ccache)
    env.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    return env


def resolve_cc(explicit: str = None) -> str:
    """The C compiler, in the order the bootstrap itself uses.

    ORBIT_CC, then CC, then the usual names. Duplicated from
    build_selfhost.py on purpose rather than imported: importing a bootstrap
    script from the tool that drives it couples the tool's lifetime to the
    script's import-time behaviour, and the order here is three lines.
    """
    for candidate in (explicit, os.environ.get("ORBIT_CC"), os.environ.get("CC")):
        if candidate:
            name = candidate.split()[0]
            if shutil.which(name):
                return candidate
    for name in ("gcc", "clang", "cc"):
        if shutil.which(name):
            return name
    print(
        "Failed: no C compiler found; set ORBIT_CC or pass --cc (gcc/clang/cc).",
        file=sys.stderr,
    )
    raise SystemExit(2)


def cc_identity(cc: str) -> str:
    """Enough of the C compiler's identity to invalidate a stale binary.

    A fixed point built by gcc is not the same artifact as one built by clang,
    and the difference shows up in emitted C, so the stamp has to notice.
    """
    try:
        out = subprocess.run(
            [cc.split()[0], "--version"],
            capture_output=True, text=True, timeout=30,
        ).stdout
        return out.splitlines()[0].strip() if out else cc
    except Exception:
        return cc


def compiler_fingerprint(cc: str) -> str:
    """Content hash of compiler/*.orb plus the C compiler identity.

    Content, not mtime, for the same reason the doctor cache is keyed on
    content: `touch compiler/doctor.orb` must not invalidate anything, and a
    file restored from a backup with a new mtime must.
    """
    digest = hashlib.sha256()
    for path in sorted(ROOT.glob("compiler/*.orb")):
        digest.update(path.relative_to(ROOT).as_posix().encode())
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    digest.update(cc_identity(cc).encode())
    return digest.hexdigest()


def short(path: pathlib.Path) -> str:
    """Repo-relative when it can be, absolute when it cannot."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def fp_path() -> pathlib.Path:
    """Where the fixed point lives: OUTSIDE the repository tree.

    Both plausible alternatives break something real, and both were tried.

    At the repository root, next to runtime/: compilerRuntimeDir
    (compiler/pipeline.orb:205) resolves the runtime as <dir of argv[0]>/runtime,
    so doctor_gate's three --fix goldens work with no shim. But cli_probe's
    `cc-include-failure-is-not-a-missing-toolchain` asserts that a C step which
    cannot find socket_compat.h is reported as "the C compiler rejected my
    output" and NOT as "was not found" -- and it runs in an empty work directory
    precisely because the include is expected to fail. A compiler that can see
    runtime/ makes that probe pass for the wrong reason: the build succeeds, rc
    is 0 where 1 is wanted, and the probe about toolchain misreporting stops
    testing anything.

    Under .orbit/: same failure from the other side. bindir becomes <repo>/.orbit,
    the lookup falls through to the relative "runtime", and for a --fix golden
    the CWD is a throwaway staged copy in a temp directory, so every one of them
    reports "the result does not compile" over a missing header.

    So the compiler stays outside the tree, where doctor_gate builds the shim it
    already knows how to build, and cli_probe keeps a genuine failure to report.
    The suffix is the repo path hashed, so two checkouts do not share a binary.
    The stamp lives in .orbit/ and NOT beside the binary: when the system temp is
    cleaned the binary goes missing, the freshness check fails, and the compiler
    is rebuilt. Being disposable is the point; nothing depends on it surviving.
    """
    tag = hashlib.sha256(str(ROOT).encode()).hexdigest()[:10]
    name = f"orbit-fp-{tag}" + (".exe" if os.name == "nt" else "")
    return system_temp() / name


def system_temp() -> pathlib.Path:
    """The system temp, ignoring TEMP/TMP.

    tempfile.gettempdir() reads TMPDIR, TEMP and TMP from the environment, and
    dev.py exports TEMP and TMP to `.orbit/tmp` for every child it runs. So
    consulting it here put the fixed-point binary INSIDE the repository, at
    `.orbit/tmp/orbit-fp-...`, which is exactly the placement the docstring above
    explains breaks things: bindir became `<repo>/.orbit/tmp`, the runtime lookup
    fell through to the relative "runtime", and doctor_gate's three --fix
    goldens reported "the result does not compile" over a missing
    socket_compat.h. It looked exactly like a broken golden.

    So the temp this uses must be the one dev.py does not control. On POSIX that
    is /tmp. On Windows there is no such guarantee, so it falls back to the
    ambient value and accepts the risk rather than inventing a path that may not
    exist; the doctor_gate predicate below is what makes the failure legible
    rather than silent if it ever goes wrong there too.
    """
    if os.name != "nt":
        return pathlib.Path("/tmp")
    drive = os.environ.get("SYSTEMDRIVE", "C:")
    return pathlib.Path(f"{drive}\\Temp")


def fp_is_fresh(cc: str) -> bool:
    binary, stamp = fp_path(), FP_STAMP
    if not binary.exists() or not stamp.exists():
        return False
    if not os.access(binary, os.X_OK):
        return False
    try:
        return stamp.read_text().strip() == compiler_fingerprint(cc)
    except OSError:
        return False


def build_fp(cc: str) -> pathlib.Path:
    """Converge the chain and leave the compiler where the runtime lookup finds it.

    This is `build_selfhost.py --out`, not `verify_seed.py --emit-fixed-point`,
    and the difference is deliberate: --out stops as soon as the chain has
    converged, and does not also run the four equality checks. Those checks are
    T3's job. Running them on every inner-loop iteration would be paying for the
    root of trust to answer a question you did not ask yet.
    """
    binary = fp_path()
    ORBIT.mkdir(parents=True, exist_ok=True)
    say(f"  building the fixed point into {short(binary)} ...")
    proc = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "build_selfhost.py"),
         "--cc", cc, "--out", str(binary)],
        cwd=str(ROOT), env=child_env(),
    )
    if proc.returncode != 0:
        print("Failed: the bootstrap did not converge.", file=sys.stderr)
        raise SystemExit(proc.returncode)
    # build_selfhost.py copies the binary without setting the exec bit, which is
    # why every hand-built fp2..fp13 needed a `chmod +x` afterwards. Do it here
    # so the thing that owns the binary is also the thing that makes it runnable.
    mode = binary.stat().st_mode
    binary.chmod(mode | 0o111)
    FP_STAMP.write_text(compiler_fingerprint(cc) + "\n")
    return binary


def ensure_fp(cc: str, allow_build: bool = True) -> pathlib.Path:
    if fp_is_fresh(cc):
        return fp_path()
    if not allow_build:
        print(
            "Failed: no fresh fixed point at "
            f"{short(fp_path())}. Run `make fp`.",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return build_fp(cc)


def fp_stamp_line(binary: pathlib.Path) -> str:
    """Which compiler is being tested, on every run.

    A gate result is only interpretable against the binary that produced it,
    and the previous mechanism (fp2 through fp13) made that a guess.
    """
    try:
        version = subprocess.run(
            [str(binary), "--version"], capture_output=True, text=True, timeout=60,
        ).stdout.strip().splitlines()[0]
    except Exception:
        version = "version unavailable"
    return version


def touched_files() -> list:
    """Paths the working tree differs on, including new untracked files.

    `git diff HEAD` covers staged and unstaged against the last commit. Untracked
    files are added separately because a brand new test file is exactly the kind
    of thing that must reach T1, and it is invisible to `git diff`.
    """
    def run(args):
        proc = subprocess.run(
            ["git", "-C", str(ROOT)] + args, capture_output=True, text=True,
        )
        return proc.stdout.splitlines() if proc.returncode == 0 else []

    paths = set(run(["diff", "--name-only", "HEAD"]))
    paths.update(run(["ls-files", "--others", "--exclude-standard"]))
    return sorted(p for p in paths if (ROOT / p).exists())


def classify(changed: list) -> list:
    """Which tiers this change needs.

    The mapping errs toward running more. `tests/` maps to T2, not T1: the suite
    lives there, so an edit to a test that only ran the doctor and CLI gates
    would never find out whether the test still passes. That was a hole in the
    table this was first written from, found by using it.

    `examples/` stays at T1 and is a real gap, recorded in DX-1: nothing in T1
    or T2 compiles an example, so an edit to one is checked for formatting and
    nothing else until the Kynx live gate runs, and that gate does not live in
    dev.py yet.
    """
    areas = {"docs": 0, "scripts": 1, "examples": 1, "tests": 2,
             "compiler": 2, "std": 2, "runtime": 2, "editors": 0, "assets": 0}
    highest = 0
    for rel in changed:
        top = rel.split("/", 1)[0]
        highest = max(highest, areas.get(top, 1))
    if not changed:
        # Nothing to do is not the same as nothing to check. A smoke T1 is the
        # right reading of `make dev` on a clean tree.
        return [1]
    return sorted(set(range(1, highest + 1)))


def fmt_gate(binary: pathlib.Path, changed: list):
    """fmt --check over exactly what CI gates.

    CI checks the whole `compiler` directory and `tests/suite`, plus each
    example individually. Checking only the touched files would pass locally on
    a file an earlier commit left unformatted, so the directories win: being
    stricter than CI is free, being looser is not.
    """
    exe = str(binary.resolve())
    py = sys.executable
    s_dir = str(ROOT / "scripts")
    # schema_conformance belongs in T0 and not T1: it compares two files of text
    # and needs no compiler at all, so running it inside a tier that pays for a
    # bootstrap would be charging a second for the same check. It is the cheapest
    # gate in the repo and the one that catches a whole class of silent wrong
    # answers -- the schema declaring a field a list when the parser hands it a
    # node -- so it belongs where it runs every time, including for a clean tree.
    cmds = [
        ("schema_conformance", [py, f"{s_dir}/schema_conformance.py"]),
    ]
    for target in ("compiler", "tests/suite"):
        cmds.append((f"fmt --check {target}", [exe, "fmt", "--check", target]))
    for path in sorted(ROOT.glob("examples/*.orb")):
        if path.name == "orbit_full_expansion.orb":
            continue
        cmds.append((f"fmt --check examples/{path.name}",
                     [exe, "fmt", "--check", str(path)]))
    return cmds


def gate_spec(binary: pathlib.Path, cc: str, work: pathlib.Path):
    """Every gate, in the order ENGINEERING.md section 8 gives.

    Tier 0 needs the orbit binary for fmt, so the spec is built once the binary
    exists and T0 is folded in by the caller.
    """
    py = sys.executable
    s = str(ROOT / "scripts")
    # Absolute, always. cli_probe.py runs the compiler with cwd=<its work dir>,
    # so a relative path handed to it resolves against the wrong directory and
    # the failure is FileNotFoundError on the gate's own argument.
    fp = str(binary.resolve())
    return {
        1: [
            ("doctor_gate", [py, f"{s}/doctor_gate.py", "--compiler", fp]),
            ("doctor_scope", [py, f"{s}/doctor_scope_gate.py", "--compiler", fp]),
            ("cli_probe", [py, f"{s}/cli_probe.py", "--compiler", fp,
                           "--work", str(work / "cli")]),
        ],
        2: [
            ("suite", [py, f"{s}/test_suite.py", "--cc", cc, "--compiler", fp]),
            ("suite_std", [py, f"{s}/test_suite.py", "--cc", cc, "--compiler", fp,
                           "--dir", "tests/std"]),
            ("negative", [py, f"{s}/negative_gate.py", "--cc", cc, "--compiler", fp]),
            ("frontend", [py, f"{s}/frontend_gate.py", "--cc", cc, "--compiler", fp]),
            ("parity", [py, f"{s}/parity_selfhost.py", "--cc", cc, "--compiler", fp]),
            ("werror", [py, f"{s}/werror_gate.py", "--cc", cc, "--compiler", fp]),
            ("fuzz_frontend", [py, f"{s}/fuzz_frontend.py", "--compiler", fp]),
        ],
        3: [
            ("check_stale", [py, f"{s}/build_selfhost.py", "--cc", cc, "--check-stale"]),
            ("verify_seed", [py, f"{s}/verify_seed.py", "--cc", cc]),
            ("alive_check", [py, f"{s}/alive_check.py", "--cc", cc, "--compiler", fp]),
        ],
    }


def run_gate(label: str, argv: list, env: dict) -> tuple:
    started = time.monotonic()
    sys.stdout.write(f"  {paint(label, BOLD)} ... ")
    sys.stdout.flush()
    proc = subprocess.run(argv, cwd=str(ROOT), env=env)
    elapsed = time.monotonic() - started
    if proc.returncode == 0:
        say(paint(f"ok ({elapsed:.0f}s)", GREEN))
    else:
        say(paint(f"FAIL rc={proc.returncode} ({elapsed:.0f}s)", RED))
    return label, proc.returncode, elapsed


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Developer loop for Orbit: one entry point for the gates."
    )
    ap.add_argument("target", nargs="?", default="dev",
                    choices=["dev", "check", "all", "fp", "fp-path", "promote", "report", "list"])
    ap.add_argument("--cc", default=None, help="C compiler (default: ORBIT_CC/CC/gcc/clang/cc)")
    ap.add_argument("--filter", default=None,
                    help="only run gates whose name contains this substring")
    ap.add_argument("--no-build", action="store_true",
                    help="fail instead of building a missing fixed point")
    args = ap.parse_args()

    cc = resolve_cc(args.cc)
    work = ORBIT / "work"

    if args.target == "fp":
        binary = ensure_fp(cc)
        say(f"fixed point: {short(binary)} ({fp_stamp_line(binary)})")
        return 0

    if args.target == "fp-path":
        # The fixed point lives in the system temp under a hash of the repo path,
        # so nothing outside dev.py can be expected to know where it is. This is
        # how a Makefile target that wants to invoke one gate gets the path
        # without duplicating the naming rule -- which is the duplication that
        # produced fp2 through fp13.
        print(ensure_fp(cc, allow_build=not args.no_build))
        return 0

    changed = touched_files()

    # `list` classifies the same way `dev` does, because "show what dev would
    # run, without running it" is the entire contract of the target. Hardcoding
    # T1 here made it report the smoke tier for every tree, which is a lie that
    # is only visible when you touch compiler/.
    tiers = classify(changed) if args.target in ("list", "dev") else {
        "check": [1, 2],
        "all": [1, 2, 3],
    }.get(args.target, [])

    if args.target == "list":
        say(f"changed files: {len(changed)}")
        for rel in changed[:40]:
            say(f"  {rel}")
        if len(changed) > 40:
            say(f"  ... and {len(changed) - 40} more")
        # The tiers are listed whether or not the binary is there. gate_spec only
        # interpolates a path; it does not need the file to exist, and gating the
        # listing on that made `list` print less on a CI runner -- where the
        # compiler is at $RUNNER_TEMP/fixed_point, not at fp_path() -- than on a
        # developer's machine. A "what would run" query that depends on whether
        # something is already built is not a query.
        binary = fp_path()
        specs = gate_spec(binary, cc, work)
        say(f"\nfp: {short(binary)}" +
            (f" ({fp_stamp_line(binary)})" if binary.exists() else " (not built)"))
        say("T0: fmt --check (compiler, tests/suite, examples/*.orb)")
        for tier in sorted(specs):
            names = ", ".join(n for n, _ in specs[tier])
            line = f"T{tier}: {names}"
            say(f" {line}" if tier in tiers else f" {line}   -- not selected")
        skipped = [t for t in (1, 2, 3) if t not in tiers]
        if skipped:
            say("  (skipped: " +
                ", ".join(f"T{t}" for t in skipped) +
                " -- so this is not a green CI)")
        return 0

    if args.target == "promote":
        # The stamp is deliberately left alone. --promote rewrites
        # compiler/selfhost/stage3.exe.c, which is a .c and not one of the
        # compiler/*.orb the fingerprint hashes, so the binary at fp_path() still
        # describes exactly the sources it was built from. Deleting the stamp
        # here cost a needless 20 s rebuild and was wrong.
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "build_selfhost.py"),
             "--cc", cc, "--promote"],
            cwd=str(ROOT), env=child_env(),
        ).returncode

    say(paint("orbit dev", BOLD))
    if changed:
        say(f"  {len(changed)} changed file(s): " +
            ", ".join(c.split("/")[-1] for c in changed[:6]) +
            (" ..." if len(changed) > 6 else ""))
    else:
        say("  clean tree")
    say(f"  tiers: T{'+T'.join(str(t) for t in tiers)}" +
        ("  (smoke: nothing touched)" if not changed else ""))
    say("")

    if args.target == "report":
        say(paint("report-only measurements (CI runs these; they cannot fail the build)", DIM))
        say("")

    binary = ensure_fp(cc, allow_build=not args.no_build)
    say(f"  fp: {paint(fp_stamp_line(binary), DIM)}\n")

    env = child_env()
    work.mkdir(parents=True, exist_ok=True)
    specs = gate_spec(binary, cc, work)

    plan = list(fmt_gate(binary, changed))
    if args.target == "report":
        plan = []
        py, s = sys.executable, str(ROOT / "scripts")
        plan = [
            ("routes_probe", [py, f"{s}/routes_probe.py"]),
            ("unknown_census", [py, f"{s}/unknown_census.py", "--cc", cc, "--compiler", str(binary.resolve())]),
            ("diff_fuzz", [py, f"{s}/diff_fuzz.py", "--cc", cc, "--compiler", str(binary.resolve())]),
        ]
    else:
        for tier in tiers:
            plan.extend(specs.get(tier, []))

    if args.filter:
        plan = [(n, a) for n, a in plan if args.filter in n]

    if not plan:
        say("  nothing to run")
        return 0

    results = [run_gate(label, argv, env) for label, argv in plan]

    say("")
    failed = [r for r in results if r[1] != 0]
    total = sum(r[2] for r in results)
    if failed:
        say(paint(f"{len(failed)} of {len(results)} gate(s) failed: " +
                   ", ".join(r[0] for r in failed), RED))
        say(paint(f"total {total:.0f}s", DIM))
        return 1

    say(paint(f"all {len(results)} gate(s) passed in {total:.0f}s", GREEN))
    missing = [t for t in (1, 2, 3) if t not in tiers]
    if missing:
        names = ", ".join(f"T{t}" for t in missing)
        want = "make check" if missing == [3] else "make all"
        say(paint(f"  {names} did not run, so this is not a green CI. `{want}`.",
                  YELLOW))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())