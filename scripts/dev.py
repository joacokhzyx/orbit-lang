#!/usr/bin/env python3
"""Developer entry point for local verification gates.

Owns the local gate configuration:

  * TEMP/TMP directory selection for gate scratch files.
  * ORBIT_CCACHE_DIR selection for compiler bootstrap caching.
  * Fixed-point binary path and freshness tracking.
  * Flags and tier assignment for each gate.

Tiers:

  T0  static, no compiler. Format check and Python syntax.
  T1  existing orbit binary. Doctor goldens, doctor scope, CLI contract.
  T2  freshly built fixed point. Language behaviour, negative corpus,
      parity, -Werror on generated C.
  T3  root of trust. build_selfhost --check-stale and verify_seed.

Tier selection: `dev` selects tiers from `git diff --name-only` and errs
toward running more. `check` runs T0..T2 unconditionally. `all` adds T3.

Make targets:

  make dev    tiers proportionate to what the working tree touched.
  make check  T0..T2 unconditionally.
  make all    T0..T3, including the root of trust.
  make fp     build only the fixed-point compiler and print its version.
  make list   show what dev would run, without running it.

Note: a green `make dev` is not a green CI.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _common import build_env, resolve_cc  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORBIT = ROOT / ".orbit"
FP_STAMP = ORBIT / "fp.stamp"
CANONICAL_C = ROOT / "compiler" / "selfhost" / "stage3.exe.c"
WITNESS_LOG = ORBIT / "last_run.log"

# Shared-chain contract (owner of the writers: agent F; dev.py only consumes).
# When build_selfhost.py and verify_seed.py accept `--shared-work <dir>`, that
# run writes exactly these four files and dev.py `all` runs ONE real chain:
#   <dir>/chain3.exe  the converged fixed-point compiler (copy source for fp)
#   <dir>/chain3.c    the converged C that must equal the canonical byte-for-byte
#   <dir>/seed.c      the seed-stage C snapshot (diagnostics, cache reuse)
#   <dir>/hashes.json {canonical_sha, seed_sha, chain3_sha, published}
# All hashes are lowercase hex of file bytes, except `published` which is the
# uppercase PUBLISHED_C from verify_seed.py. When the directory is absent or
# stale every helper below falls back to the current behaviour (rebuild per
# gate). The fallback is deliberate: dev.py must stay green on a tree where
# --shared-work is still unknown or no chain has been shared yet.
SHARED_DIR = ORBIT / "shared"
SHARED_CHAIN3_EXE = SHARED_DIR / ("chain3.exe" if os.name == "nt" else "chain3")
SHARED_CHAIN3_C = SHARED_DIR / "chain3.c"
SHARED_SEED_C = SHARED_DIR / "seed.c"
SHARED_HASHES = SHARED_DIR / "hashes.json"

# Parity composition contract (owner of the reader: agent B, parity_selfhost.py).
# Inside `dev.py all` the parity gate runs with ORBIT_PARITY_SKIP_CC=1, which
# tells parity to compare emitted C / diagnostics without invoking the C
# compiler. Standalone parity keeps the C step (no env var). Unknown env vars
# are ignored today, so exporting it before B delivers is a no-op.
PARITY_SKIP_CC_ENV = "ORBIT_PARITY_SKIP_CC"

# Witness contract (owner of the reader: agent E, alive_check.py). After every
# run dev.py writes WITNESS_LOG with one `Finished <gate>...` line per gate,
# in execution order, using each gate's own closing line verbatim when it has
# one. Gates with no closing line contribute a synthesized line:
#   fmt          -> "Finished fmt: <ok>/<total> pass"
#   check_stale  -> "Finished check_stale: match canonical" PLUS
#                   "Finished bootstrap: converged (shared bytes, no rebuild)"
#                   (the second line is the marker E greps for).
# E parses `Finished parity: 33/33 pass` and friends with regexes; the file is
# rewritten on every run (incrementally during the run, finally at the end),
# never appended to. The internal alive_check gate runs with
# `--witness <log>` when supported, so it verifies the ten heavy gates against
# this same run's log instead of re-executing them.
_SUPPORTS_CACHE: dict = {}

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
    set at all -- the fixed-point binary reads them, and every build writes its
    intermediate C to $TEMP/orbit_selfhost_build.c -- but the system temp is not
    where a compile cache or a 90k-line C file belongs: it is a different
    filesystem on some machines, and it is the first thing anyone cleans up. Two
    runnable compilers were lost that way in one session, and doctor_scope_gate
    was writing scratch to a different disk from the cache.
    """
    scratch_dir = ORBIT / "tmp"
    ccache = ORBIT / "ccache"
    scratch_dir.mkdir(parents=True, exist_ok=True)
    ccache.mkdir(parents=True, exist_ok=True)
    env = build_env(scratch_dir, ccache=ccache)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


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
    argv = [sys.executable, str(ROOT / "scripts" / "build_selfhost.py"),
            "--cc", cc, "--out", str(binary)]
    # Populate the shared snapshots on every real build: consumption is gated
    # on validity elsewhere, but without this no run ever writes the dir and
    # every `all` falls back forever (populate-always, consume-when-valid).
    if script_supports("build_selfhost.py", "--shared-work"):
        argv += ["--shared-work", str(SHARED_DIR)]
    proc = subprocess.run(argv, cwd=str(ROOT), env=child_env())
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


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def script_supports(script: str, flag: str) -> bool:
    """Whether scripts/<script> --help names <flag> (cached).

    The --shared-work / --witness wiring must not break on a tree where the
    flag is still unknown: passing it blindly would fail the gate, so callers
    check this first and fall back to the current argv when it is False.
    """
    key = (script, flag)
    if key not in _SUPPORTS_CACHE:
        try:
            proc = subprocess.run(
                [sys.executable, str(ROOT / "scripts" / script), "--help"],
                capture_output=True, text=True, timeout=30, cwd=str(ROOT),
            )
            _SUPPORTS_CACHE[key] = flag in (proc.stdout or "")
        except Exception:
            _SUPPORTS_CACHE[key] = False
    return _SUPPORTS_CACHE[key]


def shared_is_valid() -> tuple:
    """Whether .orbit/shared/ describes the current canonical (no rebuild needed).

    Valid means all four contract files exist, hashes.json parses with the four
    keys, and the stored canonical/seed/chain3 hashes match the bytes on disk.
    Anything else is (False, reason) and the caller falls back to rebuilding.
    """
    for p in (SHARED_CHAIN3_EXE, SHARED_CHAIN3_C, SHARED_SEED_C, SHARED_HASHES):
        if not p.exists():
            return False, f"missing {p.name}"
    try:
        doc = json.loads(SHARED_HASHES.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return False, f"hashes.json unreadable ({exc})"
    for key in ("canonical_sha", "seed_sha", "chain3_sha", "published"):
        if key not in doc:
            return False, f"hashes.json has no {key}"
    try:
        actual_canon = sha256_file(CANONICAL_C)
        actual_seed = sha256_file(SHARED_SEED_C)
        actual_chain3 = sha256_file(SHARED_CHAIN3_C)
    except OSError as exc:
        return False, f"hash read failed ({exc})"
    if doc["canonical_sha"].lower() != actual_canon.lower():
        return False, "canonical moved on"
    if doc["seed_sha"].lower() != actual_seed.lower():
        return False, "seed.c hash mismatch"
    if doc["chain3_sha"].lower() != actual_chain3.lower():
        return False, "chain3.c hash mismatch"
    return True, "ok"


def ensure_fp_for_all(cc: str, allow_build: bool) -> pathlib.Path:
    """fp for `dev.py all`: copy from the shared chain when valid, else build.

    Copy + stamp, no rebuild: the shared chain3.exe IS the converged compiler,
    so this is a file copy and a fingerprint write, not a bootstrap. Falls back
    to ensure_fp (today's behaviour) when the shared dir is absent or stale,
    which is the case until agent F delivers --shared-work.
    """
    ok, _reason = shared_is_valid()
    if ok:
        started = time.monotonic()
        binary = fp_path()
        ORBIT.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SHARED_CHAIN3_EXE, binary)
        mode = binary.stat().st_mode
        binary.chmod(mode | 0o111)
        FP_STAMP.write_text(compiler_fingerprint(cc) + "\n")
        say(f"  fp: copied from {short(SHARED_CHAIN3_EXE)} "
            f"({time.monotonic() - started:.0f}s, no rebuild)")
        return binary
    return ensure_fp(cc, allow_build=allow_build)


def check_stale_bytes() -> tuple:
    """check_stale without rebuilding: snapshot bytes vs canonical bytes.

    Returns (label, rc, elapsed, finished_text) shaped like run_gate so the
    caller treats both paths uniformly. rc 0 iff shared chain3.c is
    byte-identical to the committed canonical. hashes.json is a hint, bytes
    are the verdict. finished_text carries TWO lines: our own check_stale row
    plus the `Finished bootstrap: converged` marker agent E's alive_check
    greps for (qualified with "(shared bytes)" so nobody mistakes it for a
    rebuilt chain).
    """
    started = time.monotonic()
    try:
        same = SHARED_CHAIN3_C.read_bytes() == CANONICAL_C.read_bytes()
    except OSError as exc:
        elapsed = time.monotonic() - started
        return ("check_stale", 2, elapsed,
                f"Finished check_stale: unreadable ({exc})")
    elapsed = time.monotonic() - started
    if same:
        return ("check_stale", 0, elapsed,
                "Finished check_stale: match canonical\n"
                "Finished bootstrap: converged "
                "(shared bytes, no rebuild)")
    return ("check_stale", 1, elapsed,
            "Finished check_stale: stale "
            f"(chain3.c != {short(CANONICAL_C)})\n"
            "Finished bootstrap: diverged (shared bytes)")


def fmt_check_files() -> list:
    """Every file today's fmt gates verify, as an explicit sorted list.

    Matches `orbit fmt --check <dir>` byte-for-byte: that command lists
    recursive `*.orb` under the dir (25 under compiler/, 68 under
    tests/suite/ per --verbose), and examples are already per-file in dev.py
    minus orbit_full_expansion.orb. A file renamed out from under this list
    fails loudly (missing file -> gate failure), which is the point: the list
    is the contract, not a glob that silently follows.
    """
    files = [p for p in (ROOT / "compiler").rglob("*.orb")]
    files += [p for p in (ROOT / "tests" / "suite").rglob("*.orb")]
    files += [p for p in (ROOT / "examples").glob("*.orb")
              if p.name != "orbit_full_expansion.orb"]
    # Repo-relative, sorted, deduplicated: argv stability across platforms.
    seen = sorted({p.relative_to(ROOT).as_posix() for p in files})
    return [ROOT / rel for rel in seen]


def fmt_pool_workers() -> int:
    """Thread pool width for sharded fmt (same rule as parity_selfhost.py)."""
    try:
        return min(8, os.cpu_count() or 1)
    except Exception:
        return 4


def _fmt_one(args) -> tuple:
    exe, path, env = args
    proc = subprocess.run(
        [exe, "fmt", "--check", str(path)],
        cwd=str(ROOT), env=env, capture_output=True, text=True,
        errors="replace",
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    try:
        rel = str(pathlib.Path(path).relative_to(ROOT).as_posix())
    except ValueError:
        rel = str(path)
    return (rel, proc.returncode, out)


def run_fmt_sharded(exe: str, env: dict, wanted=None) -> tuple:
    """fmt --check per file in a thread pool; same files, one aggregated gate.

    Returns (label, rc, elapsed, finished_line, bad_files). Per-file outputs
    print only on failure (a clean check is silent, like the binary). The
    Finished line is synthesized -- the binary prints none on clean -- so the
    witness log still has one fmt row for agent E.
    """
    files = fmt_check_files()
    if wanted:
        files = [p for p in files if wanted in p.as_posix()]
    total = len(files)
    started = time.monotonic()
    bad: list = []
    outputs: dict = {}
    workers = fmt_pool_workers()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for rel, rc, out in pool.map(_fmt_one,
                                     [(exe, p, env) for p in files]):
            if rc != 0:
                bad.append(rel)
                outputs[rel] = out
    elapsed = time.monotonic() - started
    for rel in sorted(bad):
        sys.stdout.write(f"  unformatted: {rel}\n")
        tail = "\n".join((outputs.get(rel) or "").strip().splitlines()[-5:])
        if tail:
            sys.stdout.write(tail + "\n")
    sys.stdout.flush()
    ok = total - len(bad)
    finished = f"Finished fmt: {ok}/{total} pass"
    rc = 0 if not bad else 1
    return ("fmt", rc, elapsed, finished, bad)


def write_witness(lines: list) -> None:
    """Rewrite .orbit/last_run.log with one Finished line per gate, in order."""
    ORBIT.mkdir(parents=True, exist_ok=True)
    cleaned = [str(line).strip() for line in lines if str(line).strip()]
    WITNESS_LOG.write_text("\n".join(cleaned) + ("\n" if cleaned else ""),
                           encoding="utf-8", newline="\n")


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

    `examples/` stays at T1 and is a real gap, recorded in gate-sequence: nothing in T1
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
    """T0 static gates (no sharding here).

    fmt itself no longer lives in this list: it runs sharded per file via
    run_fmt_sharded (same 25 + 68 + 13 files `fmt --check <dir>` verifies,
    one pool, aggregated verdict). Checking only the touched files would pass
    locally on a file an earlier commit left unformatted, so the full list
    wins: being stricter than CI is free, being looser is not.
    """
    py = sys.executable
    s_dir = str(ROOT / "scripts")
    # schema_conformance belongs in T0 and not T1: it compares two files of text
    # and needs no compiler at all, so running it inside a tier that pays for a
    # bootstrap would be charging a second for the same check. It is the cheapest
    # gate in the repo and the one that catches a whole class of silent wrong
    # answers -- the schema declaring a field a list when the parser hands it a
    # node -- so it belongs where it runs every time, including for a clean tree.
    return [
        ("schema_conformance", [py, f"{s_dir}/schema_conformance.py"]),
        ("walk_coverage", [py, f"{s_dir}/walk_coverage.py"]),
    ]


def gate_spec(binary: pathlib.Path, cc: str, work: pathlib.Path):
    """Every gate, in the order ENGINEERING.md section 8 gives.

    Tier 0 needs the orbit binary for fmt, so the spec is built once the binary
    exists and T0 is folded in by the caller. fmt itself is not in this spec:
    it runs sharded (run_fmt_sharded) and `list` describes it as one line.

    T3 patching lives in main(), not here: when `all` runs with a valid shared
    dir, verify_seed gains `--shared-work <dir>` (if supported) and check_stale
    becomes a byte compare with no subprocess. This spec stays the fallback
    both show, so `list` never depends on whether the shared dir exists.
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
            ("doctor_scope", [py, f"{s}/doctor_gate.py", "--scope-only",
                             "--compiler", fp]),
            ("cli_probe", [py, f"{s}/cli_probe.py", "--compiler", fp,
                           "--work", str(work / "cli")]),
            # Needs a C compiler and nothing else -- no orbit binary, no
            # bootstrap. It was forty lines of shell inside ci-gate.yml, which
            # is why it was the one gate nobody could run locally.
            ("runtime_c", [py, f"{s}/runtime_c_tests.py", "--cc", cc]),
        ],
        2: [
            ("suite", [py, f"{s}/test_suite.py", "--cc", cc, "--compiler", fp]),
            ("suite_std", [py, f"{s}/test_suite.py", "--cc", cc, "--compiler", fp,
                           "--dir", "tests/std"]),
            ("negative", [py, f"{s}/negative_gate.py", "--cc", cc, "--compiler", fp]),
            ("frontend", [py, f"{s}/frontend_gate.py", "--cc", cc, "--compiler", fp]),
            ("dispatch", [py, f"{s}/dispatch_coverage.py"]),
            ("parity", [py, f"{s}/parity_selfhost.py", "--cc", cc, "--compiler", fp]),
            ("werror", [py, f"{s}/werror_gate.py", "--cc", cc, "--compiler", fp]),
            ("fuzz_frontend", [py, f"{s}/fuzz_frontend.py", "--compiler", fp]),
            # The only gate that builds a service and runs it. It was the other
            # shell block in CI, and being unable to run the gate that proves
            # the compiler produces a working server is how a compiler ends up
            # green on every unit test and broken in the way that matters.
            ("kynx_live", [py, f"{s}/kynx_gate.py", "live", "--cc", cc,
                           "--compiler", fp]),
        ],
        3: [
            ("check_stale", [py, f"{s}/build_selfhost.py", "--cc", cc, "--check-stale"]),
            ("verify_seed", [py, f"{s}/verify_seed.py", "--cc", cc]),
            ("alive_check", [py, f"{s}/alive_check.py", "--cc", cc, "--compiler", fp]),
        ],
    }


def run_gate(label: str, argv: list, env: dict) -> tuple:
    """Run one gate, streaming live and capturing for the witness log.

    Output streams line by line (stdout+stderr merged) so a minutes-long gate
    still shows progress; the merged text returns as the 4th element so main()
    can extract `Finished ...` lines for .orbit/last_run.log. Merging is
    deliberate: the witness only needs the closing line, which every gate
    prints to stdout, and two pipes with threads is machinery for no finding.
    """
    started = time.monotonic()
    sys.stdout.write(f"  {paint(label, BOLD)} ... \n")
    sys.stdout.flush()
    proc = subprocess.Popen(
        argv, cwd=str(ROOT), env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace", bufsize=1,
    )
    collected: list = []
    assert proc.stdout is not None
    for line in proc.stdout:
        sys.stdout.write("    " + line if line.strip() else line)
        collected.append(line)
    sys.stdout.flush()
    proc.wait()
    elapsed = time.monotonic() - started
    if proc.returncode == 0:
        say(paint(f"  {label} ok ({elapsed:.0f}s)", GREEN))
    else:
        say(paint(f"  {label} FAIL rc={proc.returncode} ({elapsed:.0f}s)", RED))
    return label, proc.returncode, elapsed, "".join(collected)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Developer loop for Orbit: one entry point for the gates."
    )
    ap.add_argument("target", nargs="?", default="dev",
                    choices=["dev", "check", "all", "fp", "fp-path", "promote", "promote-diff",
                             "report", "list"])
    ap.add_argument("--cc", default=None, help="C compiler (default: ORBIT_CC/CC/gcc/clang/cc)")
    ap.add_argument("--filter", default=None,
                    help="only run gates whose name contains this substring")
    ap.add_argument("--no-build", action="store_true",
                    help="fail instead of building a missing fixed point")
    args = ap.parse_args()

    cc = resolve_cc(args.cc)
    work = ORBIT / "work"

    if args.target == "fp":
        binary = ensure_fp_for_all(cc, allow_build=True)
        say(f"fixed point: {short(binary)} ({fp_stamp_line(binary)})")
        return 0

    if args.target == "fp-path":
        # The fixed point lives in the system temp under a hash of the repo path,
        # so nothing outside dev.py can be expected to know where it is. This is
        # how a Makefile target that wants to invoke one gate gets the path
        # without duplicating the naming rule -- which is the duplication that
        # produced fp2 through fp13.
        print(ensure_fp_for_all(cc, allow_build=not args.no_build))
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
        say("T0: fmt --check sharded per file (compiler 25 + tests/suite 68 + "
            "examples 13, minus orbit_full_expansion.orb) + schema + walk")
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

    if args.target == "promote-diff":
        # After `make promote`, before committing: what did the generated C
        # actually do, once the register renumbering is flattened. No compiler,
        # no bootstrap -- it reads git and a text file.
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "promote_diff.py")] +
            (["--expect-none"] if args.filter == "none" else []),
            cwd=str(ROOT),
        ).returncode

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

    if args.target == "all":
        binary = ensure_fp_for_all(cc, allow_build=not args.no_build)
    else:
        binary = ensure_fp(cc, allow_build=not args.no_build)
    say(f"  fp: {paint(fp_stamp_line(binary), DIM)}\n")

    env = child_env()
    work.mkdir(parents=True, exist_ok=True)
    specs = gate_spec(binary, cc, work)

    # Single-chain wiring for `all` (falls back silently until F delivers).
    # shared_ok means the four contract files exist and describe this canonical;
    # supports_* mean the scripts already accept --shared-work. verify_seed keeps
    # its four equality checks over real snapshot bytes in both paths -- the flag
    # only decides whether it rebuilds the chain or reuses the snapshots.
    shared_ok, shared_reason = (shared_is_valid() if args.target == "all"
                                else (False, "not all"))
    supports_build = script_supports("build_selfhost.py", "--shared-work")
    supports_verify = script_supports("verify_seed.py", "--shared-work")
    use_shared_chain = bool(shared_ok and (supports_build or supports_verify))
    use_stale_bytes = bool(shared_ok)
    if args.target == "all":
        if use_shared_chain:
            say(f"  shared chain: {short(SHARED_DIR)} valid "
                f"(1 real chain; check_stale=bytes, fp=copied)")
        elif shared_ok:
            say(f"  shared chain: {short(SHARED_DIR)} valid but scripts lack "
                f"--shared-work; check_stale=bytes, rest falls back")
        else:
            say(f"  shared chain: fallback (no valid snapshots: {shared_reason})")

    static_plan = list(fmt_gate(binary, changed))
    plan: list = []
    run_fmt_files: list | None = None
    if args.target == "report":
        py, s = sys.executable, str(ROOT / "scripts")
        plan = [
            ("routes_probe", [py, f"{s}/routes_probe.py"]),
            ("unknown_census", [py, f"{s}/unknown_census.py", "--cc", cc, "--compiler", str(binary.resolve())]),
            ("diff_fuzz", [py, f"{s}/diff_fuzz.py", "--cc", cc, "--compiler", str(binary.resolve())]),
        ]
    else:
        plan = list(static_plan)
        # fmt runs sharded, not as directory gates. Filter parity with the old
        # names: "fmt" runs everything, "compiler"/"suite"/a filename runs the
        # matching subset, anything else runs nothing.
        if not args.filter:
            run_fmt_files = fmt_check_files()
        elif args.filter in "fmt --check":
            run_fmt_files = fmt_check_files()
        else:
            subset = [p for p in fmt_check_files()
                      if args.filter in p.as_posix()]
            run_fmt_files = subset if subset else None
            if subset:
                say(f"  fmt filter '{args.filter}': {len(subset)} file(s)")
        for tier in tiers:
            for label, argv in specs.get(tier, []):
                # Populate shared snapshots on every real verify_seed run, even
                # when nothing is valid yet: validity gates consumption above,
                # never population, or the dir is never written (see build_fp).
                if label == "verify_seed" and args.target == "all" and supports_verify:
                    argv = list(argv) + ["--shared-work", str(SHARED_DIR)]
                if label == "check_stale" and use_stale_bytes:
                    # Replaced below by check_stale_bytes(); keep the slot so
                    # ordering and --filter behave, mark for substitution.
                    plan.append(("check_stale:bytes", []))
                    continue
                plan.append((label, argv))

    if args.filter:
        plan = [(n, a) for n, a in plan if args.filter in n
                or (n == "check_stale:bytes" and args.filter in "check_stale")]
        if run_fmt_files is not None and args.filter not in "fmt --check":
            # plan already filtered; fmt subset decided above, keep it only if
            # the filter named fmt files (not some other gate).
            if not any(args.filter in p.as_posix() for p in run_fmt_files):
                run_fmt_files = None

    if not plan and run_fmt_files is None:
        say("  nothing to run")
        return 0

    exe = str(binary.resolve())
    results: list = []
    witness: list = []

    def env_for(label: str) -> dict:
        """Per-gate env: parity composition + shared-chain handoff for T3."""
        e = dict(env)
        if label == "parity" and args.target == "all":
            e[PARITY_SKIP_CC_ENV] = "1"
        if args.target == "all" and use_shared_chain:
            e["ORBIT_SHARED_WORK"] = str(SHARED_DIR)
        return e

    def harvest(output: str) -> None:
        for line in (output or "").splitlines():
            if re.match(r"^Finished \S+", line.strip()):
                witness.append(line.strip())

    def flush_witness() -> None:
        # Incremental: alive_check --witness reads this file while this same
        # run is still going (it is the last T3 gate), so the log must already
        # hold every prior gate's closing line before alive starts. Cheap
        # (a dozen lines) and the final write below rewrites the same content.
        write_witness(witness)

    def argv_for(label: str, argv: list) -> list:
        # alive_check in witness mode verifies the ten heavy T1-T3 gates
        # against this run's own log instead of re-executing them (no +2
        # chain rebuilds). Standalone alive_check without --witness still
        # re-executes everything, which is E's own coverage. Detected, not
        # assumed: without E's flag this is today's full run.
        if label == "alive_check" and script_supports("alive_check.py",
                                                      "--witness"):
            return list(argv) + ["--witness", str(WITNESS_LOG)]
        return argv

    # T0 order is schema, walk, fmt (sharded pool), then tiers in spec order.
    static_labels = {n for n, _ in static_plan}
    static_part = [(n, a) for n, a in plan if n in static_labels]
    rest = [(n, a) for n, a in plan if n not in static_labels]

    for label, argv in static_part:
        gate_env = env_for(label)
        rlabel, rrc, relapsed, output = run_gate(label, argv, gate_env)
        results.append((rlabel, rrc, relapsed))
        harvest(output)
        flush_witness()

    if run_fmt_files is not None and args.target != "report":
        say(f"  {paint('fmt', BOLD)} ... ({len(run_fmt_files)} files, "
            f"{fmt_pool_workers()} workers)")
        sys.stdout.flush()
        # run_fmt_sharded enumerates the same contract list; when filtered we
        # intersect by re-checking wanted below: full list when unfiltered,
        # else the substring (old names: "compiler", "suite", a filename).
        if args.filter and args.filter not in "fmt --check":
            wanted = args.filter
        else:
            wanted = None
        _flabel, frc, felapsed, ffinished, _fbad = run_fmt_sharded(
            exe, env, wanted=wanted)
        if frc == 0:
            say(paint(f"  fmt ok ({felapsed:.0f}s)", GREEN))
        else:
            say(paint(f"  fmt FAIL rc={frc} ({felapsed:.0f}s)", RED))
        results.append(("fmt", frc, felapsed))
        witness.append(ffinished)
        flush_witness()

    for label, argv in rest:
        if label == "check_stale:bytes":
            say(f"  {paint('check_stale', BOLD)} ... (bytes, no rebuild)")
            sys.stdout.flush()
            _blabel, brc, belapsed, bfinished = check_stale_bytes()
            if brc == 0:
                say(paint(f"  check_stale ok ({belapsed:.0f}s)", GREEN))
            else:
                say(paint(f"  check_stale FAIL rc={brc} ({belapsed:.0f}s)", RED))
            results.append(("check_stale", brc, belapsed))
            witness.extend(bfinished.splitlines())
            flush_witness()
            continue
        argv = argv_for(label, argv)
        gate_env = env_for(label)
        rlabel, rrc, relapsed, output = run_gate(label, argv, gate_env)
        results.append((rlabel, rrc, relapsed))
        harvest(output)
        flush_witness()

    write_witness(witness)
    say(f"  witness: {short(WITNESS_LOG)} ({len(witness)} Finished line(s))")

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
    if missing and args.target != "report":
        names = ", ".join(f"T{t}" for t in missing)
        want = "make check" if missing == [3] else "make all"
        say(paint(f"  {names} did not run, so this is not a green CI. `{want}`.",
                  YELLOW))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())