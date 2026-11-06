#!/usr/bin/env python3
"""The root of trust: build, verify, shard, promote-diff, amalgamate.

Five tools own the committed canonical C, one entry point:

    build           converge compiler/**/*.orb against the canonical
                    (--check-stale, --promote, --out, --shared-work); closes
                    with "Finished bootstrap: converged (...)"
    verify          the hermetic seed-chain equality checks; closes through
                    out.finish("verify", ...)
    shard           split a compiler-emitted TU into shards, compile and link
                    them; --self-test closes "Finished shard-selfhost
                    self-test: N/N"
    promote-diff    the canonical's diff against HEAD with the generated
                    register and label numbering flattened; --self-test
                    closes "Finished promote-diff self-test:"
    amalgamate      inline every project-relative include of a C file; closes
                    with "Wrote <path> (<n> MB)"

The gate labels in `scripts/gate_registry.py` (`check_stale`, `verify_seed`,
`shard_split`) do not change here, and neither do the closing lines
`scripts/alive_check.py` matches: `python scripts/trust.py build --cc gcc
--check-stale` prints what `python scripts/build_selfhost.py --cc gcc
--check-stale` printed.

Exit codes are unchanged: `shard` still distinguishes 0, 1, 2, 3, 4 and 5;
`build` and `verify` still exit 2 on a subprocess they cannot recover from;
`promote-diff` exits 0 or 1 (2 when the canonical is not in HEAD); `amalgamate`
fails the way the inline pass fails, on an include it cannot resolve.

Names that collided when the five became one file. Each was resolved at its
first occurrence below, and the resolution never merged two behaviours:

  `run`           build and verify each had one, with different signatures
                  and different failure labels: `bs_run` and `vs_run`.
  `detect_cc`     build exits 2 when no C compiler is on PATH; verify answers
                  "cc" instead. Both stay: `bs_detect_cc` and `vs_detect_cc`.
  `ROOT`, `CANONICAL_C`, `MAIN_ORB`, `SUPPRESS_FLAGS`,
  `PLATFORM_LINK_FLAGS`, `sha256`
                  the two bootstrap scripts repeated these verbatim, which is
                  what let their cc cache entries disagree; one definition
                  each here.
  `VERIFY_SEED`   `build --promote` rewrites PUBLISHED_C in the other script.
                  There is no other script now: it rewrites `TRUST`, this
                  file's own path, and the verify section's degraded import
                  fallback is gone because the names it mirrored are defined
                  above it.
  `PUBLISHED_C`   stays a top-level constant, so
                  `published_c_contract()` still reads it out of the file
                  text and `update_published_c` still rewrites it.
  `main`          one per tool, so it is now `cmd_<subcommand>(args)`.
  `ROOT`/`self_test` (promote_diff)
                  promote_diff built its ROOT with pathlib against the
                  string the others build with os.path; it is `PD_ROOT`
                  there, and its self-test is `self_test_promote_diff`.

The `Usage:` lines inside each section header comment name the current entry
point: `python scripts/trust.py <subcommand> [flags]`. The rest of that prose
is the reason each tool exists, and it moved with the code.
"""

import argparse
import concurrent.futures
import difflib
import hashlib
import json
import os
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
import orbit_ccache  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRUST = os.path.abspath(__file__)
CANONICAL_C = os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c")
MAIN_ORB = os.path.join("compiler", "host", "main.orb")

# The bootstrap builds at -O1, or at -O0 under the low-memory profile; both
# the build and the verify subcommands splice SUPPRESS_FLAGS and
# PLATFORM_LINK_FLAGS into every cc argv through bootstrap_cc_middle, so one
# definition each is what keeps identical inputs hashing to one cache entry.
SUPPRESS_FLAGS = ["-DORBIT_WITH_EXEC"] + (
    ["-Wall"] if os.environ.get("ORBIT_BOOTSTRAP_WARNINGS", "").strip() not in ("", "0") else [])
PLATFORM_LINK_FLAGS = ["-lws2_32", "-Wl,--stack,16777216"] if os.name == "nt" else []


# ---- from scripts/build_selfhost.py ----
# Rebuild the self-hosted Orbit compiler from the committed canonical C.
#
# The root of trust is the committed canonical C source
# (``compiler/selfhost/stage3.exe.c``). Any conforming C compiler can turn it
# into a working Orbit compiler; that compiler rebuilds the sources from
# ``compiler/host/main.orb`` and the loop is repeated until the emitted C reaches a
# new fixed point. No toolchain beyond a C compiler is involved at any point.
#
# Modes:
#   default        Rebuild from the committed canonical C and verify that the
#                  current ``compiler/**/*.orb`` sources converge to a fixed point.
#   --check-stale  Additionally require the converged C to equal the committed
#                  canonical byte-for-byte (CI mode: fails when the canonical
#                  was not refreshed after a compiler change).
#   --promote      Replace the committed canonical with the newly converged C
#                  and update PUBLISHED_C in scripts/trust.py. Use after
#                  an intentional compiler change.
#   --out PATH     Copy the converged fixed-point compiler binary to PATH.
#   --shared-work DIR  After converging, write chain3.c / chain3.exe / seed.c /
#                      hashes.json under DIR (see SHARED_* below; without the
#                      flag nothing is written).
#
# Usage:
#     python scripts/trust.py build [--cc CC] [--work DIR] [--keep]
#                                      [--check-stale] [--promote] [--out PATH]
#                                      [--shared-work DIR]
#
# Exit code 0 iff the chain converged (and, with --check-stale, matches the
# committed canonical).
#!/usr/bin/env python3




# The bootstrap builds at -O1, or at -O0 under the low-memory profile
# (--low-mem, auto-enabled below 4 GB of free commit): low-RAM machines (4 GB)
# were OOMing inside LLVM/lld during -O2 links. pipeline.orb builds user
# programs at -O1 (-O2 with --release).
# -DORBIT_WITH_EXEC enables the
# compiler's own process spawning (its cc invocations) -- trusted infrastructure.
# No blanket suppressions: generated C must compile warning-free under -Werror
# on the supported toolchains. -Werror itself stays out of the bootstrap path
# (exotic toolchains must never brick the build); it runs as an explicit CI gate
# step instead (the clean-emission work, scripts/werror_gate.py).
# The two -Wno-error= downgrades below are load-bearing, not cruft: GCC 14+
# raises int-conversion / incompatible-pointer-types as ERRORS by default,
# so without them any remaining instance bricks the bootstrap (and user
# builds) instead of warning. They stay until the generated C is fully
# -Werror clean, tracked by scripts/werror_gate.py.
# -Wall is deliberately NOT in the bootstrap flags. Measured on the 3.9 MB
# compiler unit (2-core runner, gcc 13.3): -O0 -Wall costs 23.8 s against 3.7 s
# without it, a 5.7x penalty, and it surfaces 89 warnings on a unit this size --
# the analysis it enables is superlinear in emitted size. The bootstrap is a
# verification harness that recompiles this unit dozens of times per gate;
# warnings are the business of scripts/werror_gate.py, which is the strict gate
# and runs in CI. Set ORBIT_BOOTSTRAP_WARNINGS=1 to restore -Wall locally.
# No -Wno-error= downgrades: the emitted C is clean for both classes they used
# to cover (int-conversion, incompatible-pointer-types) across the whole corpus,
# so GCC 14+ compiling these as errors is no longer a hazard. A regression now
# fails loudly here instead of being silently downgraded to a warning.

# Low-memory profile: drop unwind tables and debug info so the multi-MB
# compiler TU links with less peak commit. GCC/Clang only; MSVC-style
# drivers (cl) do not accept these flags.
LOWMEM_C_FLAGS = ["-g0", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables"]
LOWMEM_AUTO_MB = 4096
MAX_ITERATIONS = 4


def avail_commit_mb():
    """Available commit (physical + pagefile) in MB, or None when unknown."""
    try:
        import psutil  # type: ignore
        return psutil.virtual_memory().available // (1 << 20)
    except Exception:
        pass
    if sys.platform == "win32":
        try:
            import ctypes

            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]

            stat = MEMORYSTATUSEX()
            stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
                return int((stat.ullAvailPhys + stat.ullAvailPageFile) >> 20)
        except Exception:
            return None
    return None


def lowmem_cc_flags(cc: str) -> list:
    """Extra C flags for the low-memory profile (empty for non-GCC drivers)."""
    low = cc.lower()
    if "cl" in low.split() or low.strip() == "cl":
        return []
    if any(t in low for t in ("gcc", "clang", "cc")):
        return list(LOWMEM_C_FLAGS)
    return []


def cc_strip_flags(cc: str) -> list:
    """`-s` for GCC/Clang-like drivers, [] for anything else.

    Stripping changes bytes, never behaviour. `cl` rejects `-s`, hence the
    same driver guard as lowmem_cc_flags. Part of the unified flag set below.
    """
    low = cc.lower()
    if "cl" in low.split() or low.strip() == "cl":
        return []
    if any(t in low for t in ("gcc", "clang", "cc")):
        return ["-s"]
    return []


def resolve_low_mem(setting, log=None) -> bool:
    """None/True/False -> bool through the one auto-detection both scripts use."""
    if setting is not None:
        return bool(setting)
    free_mb = avail_commit_mb()
    auto = free_mb is not None and free_mb < LOWMEM_AUTO_MB
    if auto and log is not None:
        log(f"Low-memory profile auto-enabled ({free_mb} MB commit available).")
    return auto


def bootstrap_opt_flag(low_mem: bool) -> str:
    """-O1 by default, -O0 under the low-memory profile.

    On the 5.9 MB compiler unit with gcc 16.2.0 (8 cores) -O1 makes the
    compiler 4x faster at emitting itself (2.5 s against 10.8 s at -O0) for
    6 s more of gcc time. -O0 stays for machines where -O1 does not fit.
    """
    return "-O0" if low_mem else "-O1"


def bootstrap_cc_middle(cc: str, low_mem: bool) -> list:
    """The unified middle of every bootstrap cc argv (Fase A, pieza F).

    the build and verify subcommands both splice this in the same place:
    right after cc_cmd, before -I/-o/sources/link flags -- so identical inputs
    hash to one orbit_ccache entry no matter which script stored it first.
    Order is pinned: the cache key hashes argv tokens in order.
    """
    return [*cc_strip_flags(cc), bootstrap_opt_flag(low_mem), *SUPPRESS_FLAGS,
            *(lowmem_cc_flags(cc) if low_mem else [])]


def warn_low_memory() -> None:
    """LLVM/lld peak usage on the multi-MB compiler TU can exceed what
    low-RAM machines have free; warn early instead of dying cryptically."""
    free_mb = None
    try:
        import psutil  # type: ignore
        free_mb = psutil.virtual_memory().available // (1 << 20)
    except Exception:
        if sys.platform == "win32":
            try:
                import ctypes

                class MEMORYSTATUSEX(ctypes.Structure):
                    _fields_ = [
                        ("dwLength", ctypes.c_ulong),
                        ("dwMemoryLoad", ctypes.c_ulong),
                        ("ullTotalPhys", ctypes.c_ulonglong),
                        ("ullAvailPhys", ctypes.c_ulonglong),
                        ("ullTotalPageFile", ctypes.c_ulonglong),
                        ("ullAvailPageFile", ctypes.c_ulonglong),
                        ("ullTotalVirtual", ctypes.c_ulonglong),
                        ("ullAvailVirtual", ctypes.c_ulonglong),
                        ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
                    ]

                stat = MEMORYSTATUSEX()
                stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
                if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
                    # Commit headroom is what matters: physical + pagefile.
                    free_mb = ((stat.ullAvailPhys + stat.ullAvailPageFile) >> 20)
            except Exception:
                return
    if free_mb is not None and free_mb < 2048:
        print(f"Warning: only ~{free_mb} MB commit available; LLVM/lld links of "
              "the compiler TU may OOM. Close applications or expect slower retried builds.",
              file=sys.stderr)


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def bs_detect_cc() -> str:
    env_cc = os.environ.get("ORBIT_CC")
    if env_cc:
        return env_cc
    for cand in ("gcc", "clang", "cc"):
        if shutil.which(cand):
            return cand
    out.fail("Failed: no C compiler found; set ORBIT_CC (gcc/clang/cc).")
    raise SystemExit(2)


def bs_run(argv, cwd=ROOT, env_extra=None, label=""):
    import gc
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    out.say(f"Running {label or ' '.join(argv)}")
    proc = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, errors="replace")
    combined = (proc.stdout or "") + (proc.stderr or "")
    if combined.strip():
        print(combined.rstrip())
    rc = proc.returncode
    # Keep only the failure tail for the annotation, then release the
    # subprocess buffers eagerly so long bootstrap chains stay lean.
    tail = "\n".join(combined.strip().splitlines()[-30:])
    del proc
    del combined
    gc.collect()
    if rc != 0:
        # Emit as a GitHub error annotation: check-run annotations are public
        # API-readable even when job logs require authentication.
        out.ci_error(f"[{label}] rc={rc} :: {out.scrub_ci(tail)}")
        out.fail(f"Failed {label} (rc={rc})")
        raise SystemExit(2)


def orb_build(compiler, out_exe, work, cc, snapshot_path, extra_cc_flags=None) -> str:
    """Compile compiler/host/main.orb with `compiler`; snapshot the intermediate C.

    The compiler's own final cc invocation is redundant here (we recompile the
    snapshot ourselves with known-good flags). If it fails -- e.g. because an
    older compiler bakes a stale runtime include path -- we continue as long
    as the C was emitted. extra_cc_flags reach the compiler's inner cc via
    ORBIT_CCFLAGS_EXTRA (newer compilers; older ones ignore the variable).
    """
    tmp = os.path.join(work, "tmp_build")
    os.makedirs(tmp, exist_ok=True)
    inter_c = os.path.join(tmp, "orbit_selfhost_build.c")
    if os.path.isfile(inter_c):
        os.remove(inter_c)
    # ORBIT_SKIP_CC: the compiler emits the C and stops. This script compiles
    # that C itself right afterwards with known-good flags, so letting the
    # compiler also run its own cc is a redundant compile of the same
    # multi-megabyte unit. ORBIT_WARNINGS=0 drops -Wall from the compiler's
    # internal invocation for the same reason the bootstrap flags do.
    env = dict(os.environ)
    env.update({"TEMP": tmp, "TMP": tmp, "TMPDIR": tmp, "ORBIT_CC": cc, "CC": cc,
                "ORBIT_SKIP_CC": "1", "ORBIT_WARNINGS": "0",
                "ORBIT_CCFLAGS_EXTRA": " ".join(extra_cc_flags or [])})
    label = f"{os.path.basename(compiler)} build main.orb -> {out_exe}"
    out.say(f"Building {label}")
    proc = subprocess.run([compiler, "build", MAIN_ORB, "-o", os.path.join(work, out_exe)],
                          cwd=ROOT, env=env)
    if proc.returncode != 0:
        if not os.path.isfile(inter_c):
            out.fail(f"Failed ({proc.returncode}): {label} (no C emitted)")
            raise SystemExit(2)
        out.say(f"note: compiler exited {proc.returncode} but emitted C "
                "(stale baked-in flags?); continuing with our own cc invocation.")
    shutil.copyfile(inter_c, snapshot_path)
    # The shard header travels with the snapshot: sharded TU compiles
    # (sharding is on by default) resolve it as the sibling <base>.h.
    inter_h = os.path.splitext(inter_c)[0] + ".h"
    if os.path.isfile(inter_h):
        shutil.copyfile(inter_h, os.path.splitext(snapshot_path)[0] + ".h")
    return snapshot_path


def update_published_c(new_hash: str) -> None:
    with open(TRUST, "r", encoding="utf-8") as f:
        content = f.read()
    new_content, n = re.subn(
        r'PUBLISHED_C = "[0-9A-Fa-f]{64}"',
        f'PUBLISHED_C = "{new_hash.upper()}"',
        content,
    )
    if n != 1:
        print("Warning: could not update PUBLISHED_C in trust.py", file=sys.stderr)
        return
    with open(TRUST, "w", encoding="utf-8", newline="\n") as f:
        f.write(new_content)
    out.say(f"Updated PUBLISHED_C in trust.py -> {new_hash.upper()}")


# Shared-work snapshots (Fase A, pieza F): after converging, both scripts can
# write these four paths under --shared-work DIR for the dev.py driver to
# consume without rerunning the chain -- check_stale as a byte comparison of
# chain3.c against the canonical, fp as a copy of the chain3 binary:
#
#   <dir>/chain3.c    converged fixed-point C
#   <dir>/chain3.exe  converged compiler binary (chain3, no suffix, off Windows)
#   <dir>/seed.c      seed-stage emitted C
#   <dir>/hashes.json {"canonical_sha":..,"seed_sha":..,"chain3_sha":..,"published":..,"runtime_sha":..}
#
# The four _sha values are lowercase hex of the bytes as written; published is
# PUBLISHED_C verbatim (uppercase): compare case-insensitively. runtime_sha
# covers runtime/**/*.c and *.h, which the canonical C includes textually, so a
# snapshot is not reused after a runtime edit that leaves the canonical text
# unchanged. Presence of hashes.json means THIS run converged; absence means it
# did not -- the writer deletes a stale manifest at startup and writes the
# manifest last (tmp+rename), so a failed run can never leave a fresh-looking
# manifest.
# The writer never touches the canonical or PUBLISHED_C; --promote stays the
# single writer of the root of trust. Concurrent writers to one dir must be
# serialized by the driver; at a true fixed point both scripts write identical
# bytes anyway, so last-writer-wins is benign.
SHARED_CHAIN_C = "chain3.c"
SHARED_SEED_C = "seed.c"
SHARED_MANIFEST = "hashes.json"


def shared_chain_bin() -> str:
    return "chain3.exe" if sys.platform == "win32" else "chain3"


def published_c_contract() -> str:
    """PUBLISHED_C verbatim from the verify section of this file (read-only)."""
    try:
        with open(TRUST, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return ""
    m = re.search(r'PUBLISHED_C = "([0-9A-Fa-f]{64})"', text)
    return m.group(1).upper() if m else ""


def runtime_tree_sha() -> str:
    """Content hash of the runtime sources the fixed point is compiled with.

    The canonical C includes runtime/runtime.h, so the binary is a function of
    these files as much as of `compiler/**/*.orb`. Hashing them here is what
    stops a snapshot from being reused after a runtime edit: the binary
    predates the edit, the canonical text has not moved, and nothing else in
    the manifest notices.
    """
    runtime = os.path.join(ROOT, "runtime")
    digest = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(runtime):
        dirnames.sort()
        for name in sorted(filenames):
            if not name.endswith((".c", ".h")):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, runtime).replace(os.sep, "/")
            digest.update(rel.encode())
            with open(path, "rb") as f:
                digest.update(hashlib.sha256(f.read()).digest())
    return digest.hexdigest()


def claim_shared_work(path: str) -> str:
    """Create DIR and retire any manifest a previous run left (best effort)."""
    absd = os.path.abspath(path)
    os.makedirs(absd, exist_ok=True)
    try:
        manifest = os.path.join(absd, SHARED_MANIFEST)
        if os.path.isfile(manifest):
            os.remove(manifest)
    except OSError as e:
        out.say(f"note: cannot clear stale {SHARED_MANIFEST} in {absd} ({e}); continuing.")
    return absd


def write_shared_work(shared_dir: str, *, canonical_c: str, seed_c: str,
                      chain_c: str, chain_exe: str) -> str:
    """Copy snapshots + binary into shared_dir and publish hashes.json."""
    os.makedirs(shared_dir, exist_ok=True)
    dst_seed = os.path.join(shared_dir, SHARED_SEED_C)
    dst_chain = os.path.join(shared_dir, SHARED_CHAIN_C)
    dst_bin = os.path.join(shared_dir, shared_chain_bin())
    shutil.copyfile(seed_c, dst_seed)
    shutil.copyfile(chain_c, dst_chain)
    shutil.copyfile(chain_exe, dst_bin)
    if os.name != "nt":
        try:
            os.chmod(dst_bin, os.stat(chain_exe).st_mode | 0o111)
        except OSError:
            pass
    manifest_obj = {
        "canonical_sha": sha256(canonical_c),
        "seed_sha": sha256(dst_seed),
        "chain3_sha": sha256(dst_chain),
        "published": published_c_contract(),
        "runtime_sha": runtime_tree_sha(),
    }
    tmp = os.path.join(shared_dir, SHARED_MANIFEST + ".tmp%d" % os.getpid())
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(manifest_obj, indent=2) + "\n")
    os.replace(tmp, os.path.join(shared_dir, SHARED_MANIFEST))
    out.say(f"Wrote shared-work snapshots to {shared_dir} "
            f"(chain3={manifest_obj['chain3_sha']})")
    return os.path.join(shared_dir, SHARED_MANIFEST)


def _unity_cache_hit(cc_cmd, argv, sources) -> bool:
    """Best-effort probe: would compile_cached() hit for this argv.

    True means "take the unity path" (which re-validates through the real
    cache load, so a wrong True only costs the copy it would have done
    anyway). A disabled cache or a confident miss returns False: unity
    would compile cold there, which is exactly when shards may win. Any
    other probe error returns True.
    """
    try:
        if not orbit_ccache.enabled():
            return False
        key = orbit_ccache.compute_key(cc_cmd, argv, sources)
        entry = os.path.join(orbit_ccache.cache_root(), key[:2], key)
        if not (os.path.isfile(entry + ".art")
                and os.path.isfile(entry + ".meta")):
            return False
        with open(entry + ".meta", encoding="utf-8") as f:
            first = f.read().splitlines()
        return bool(first) and first[0] == "complete"
    except Exception:
        return True


def compile_tu_exe(cc, cc_cmd, iter_argv, iter_sources, c_path, next_exe,
                   work, tag) -> bool:
    """Build one iteration compiler, sharded when asked and worthwhile.

    Sharding (on unless ORBIT_SHARD_BUILD=0) tries the shard subcommand
    on the emitted TU (its sibling <base>.h must exist) and falls back to the unity
    compile_cached on any failure. The cache is probed first: a unity hit
    is a file copy, cheaper than any sharding, so shards only run on a
    confident miss. Returns the compile_cached-style reused flag (False
    for a shard build). A shard-built compiler is behaviorally identical
    (R10c); the loop's own hash convergence below is the verdict, so a
    bad shard binary diverges loudly instead of passing quietly.
    """
    use_shards = shard_enabled()
    header = os.path.splitext(c_path)[0] + ".h"
    if use_shards and not os.path.isfile(header):
        out.say(f"note: shard build {tag} off (no sibling header "
                f"{os.path.basename(header)}); unity compile.")
        use_shards = False
    if use_shards and _unity_cache_hit(cc_cmd, iter_argv, iter_sources):
        use_shards = False
    if use_shards:
        try:
            shard_build(
                cc, c_path, header, next_exe, work, tag=tag,
                jobs=shard_jobs(),
                runtime_dir=os.path.join(ROOT, "runtime"),
                lib_dir=os.path.join(work, "shardlib"), log=out.say,
                opt="-O0" if "-O0" in iter_argv else "-O1")
            out.say(f"shard-built {tag} (unity fallback skipped; "
                    f"no Windows branding stamp on this intermediate)")
            return False
        except Exception as exc:
            out.say(f"note: shard build {tag} failed ({exc}); "
                    f"falling back to the unity compile.")
    _, reused = orbit_ccache.compile_cached(cc_cmd, iter_argv, iter_sources,
                                            log=out.say)
    return reused


def cmd_build(args) -> int:
    out.set_quiet(args.quiet)

    if args.promote and args.check_stale:
        out.fail("Failed: --promote and --check-stale are mutually exclusive.")
        return 1

    warn_low_memory()
    args.low_mem = resolve_low_mem(args.low_mem, log=out.say)

    if not os.path.isfile(CANONICAL_C):
        out.fail(f"Failed: {CANONICAL_C} missing. It is the committed root of trust.")
        out.tip("restore it from git; it is the committed root of trust.")
        return 1

    if args.work:
        work = os.path.abspath(args.work)
        os.makedirs(work, exist_ok=True)
    else:
        work = tempfile.mkdtemp(prefix="orbit_selfhost_")
    if not args.keep:
        import atexit
        atexit.register(lambda: shutil.rmtree(work, ignore_errors=True))
    shared_dir = claim_shared_work(args.shared_work) if args.shared_work else None

    exe = ".exe" if sys.platform == "win32" else ""
    cc = args.cc or bs_detect_cc()
    cc_cmd = cc.split()
    extra_cc_flags = lowmem_cc_flags(cc) if args.low_mem else []
    if args.low_mem and not extra_cc_flags:
        out.say("Low-memory profile on (no extra C flags for this driver).")
    elif extra_cc_flags:
        out.say(f"Low-memory C flags: {' '.join(extra_cc_flags)}")
    h_canonical = sha256(CANONICAL_C)

    out.say(f"Bootstrapping from root:    {ROOT}")
    out.say(f"Bootstrapping with compiler:   {cc}")
    out.say(f"Canonical C:  {h_canonical}  ({os.path.getsize(CANONICAL_C)} bytes)")

    # Seed: canonical C -> amalgamate -> any C compiler -> working Orbit compiler.
    amal = os.path.join(work, "orbit_bootstrap.c")
    bs_run([sys.executable, TRUST, "amalgamate",
           "--entry", CANONICAL_C, "--out", amal], label="amalgamate canonical")
    # Fixed -o basename shared with the verify subcommand: the ccache key hashes
    # argv basenames, so "seed" vs "orbit_seed" was a permanent cross-miss
    # (~12s per make all). Safe because the key is still content-bound
    # (canonical C hash + flags + cc identity), and the mingw-gcc binary was
    # verified name-independent by hash. Flags come from bootstrap_cc_middle,
    # the one constructor both scripts share (Fase A, pieza F): same inputs
    # must hash to the same entry no matter which script stored it first.
    seed_exe = os.path.join(work, "orbit_seed_frozen" + exe)
    out.say("Building seed from canonical C")
    seed_argv = [*cc_cmd, *bootstrap_cc_middle(cc, args.low_mem),
                 "-o", seed_exe, amal, *PLATFORM_LINK_FLAGS]
    seed_argv, seed_sources = orbit_ccache.windows_stamp(
        seed_argv, [amal], work, "Orbit compiler", log=out.say)
    orbit_ccache.compile_cached(cc_cmd, seed_argv, seed_sources, log=out.say)

    # Iterate: current compiler builds the sources; repeat until C stabilises.
    prev_c_hash = None
    cur_exe = seed_exe
    converged_c = None
    first_c = None
    final_exe = None
    for i in range(1, MAX_ITERATIONS + 1):
        c_i = orb_build(cur_exe, f"iter{i}" + exe, work, cc,
                        os.path.join(work, f"iter{i}.selfhost.c"),
                        extra_cc_flags)
        if i == 1:
            first_c = c_i
        h_i = sha256(c_i)
        next_exe = os.path.join(work, f"iter{i}_exe" + exe)
        # Generated C is not amalgamated: it needs the runtime headers on the
        # include path (pipeline.orb does the same when building user programs).
        # Flags are bootstrap_cc_middle, shared with the verify subcommand (see seed).
        out.say(f"Building iter{i} compiler from its own C")
        iter_argv = [*cc_cmd, *bootstrap_cc_middle(cc, args.low_mem),
                     "-I", os.path.join(ROOT, "runtime"),
                     "-o", next_exe, c_i, *PLATFORM_LINK_FLAGS]
        iter_argv, iter_sources = orbit_ccache.windows_stamp(
            iter_argv, [c_i], work, "Orbit compiler", log=out.say)
        reused = compile_tu_exe(cc, cc_cmd, iter_argv, iter_sources, c_i,
                                next_exe, work, f"iter{i}")
        # The canonical is a fixed point by construction (verify asserts
        # it reproduces itself), so a first emission equal to it needs no
        # second round to show convergence. A canonical that is not a fixed
        # point never takes this path and runs the full loop.
        equals_canonical = i == 1 and h_i == h_canonical
        out.say(f"Iteration {i}: {h_i}"
                + ("  (fixed point)" if h_i == prev_c_hash else "")
                + ("  (equals canonical; fixed point)" if equals_canonical else "")
                + ("  (cc from cache)" if reused else ""))
        if h_i == prev_c_hash or equals_canonical:
            converged_c = c_i
            final_exe = next_exe
            break
        prev_c_hash = h_i
        cur_exe = next_exe
        final_exe = next_exe

    if converged_c is None:
        out.fail(f"Failed: no fixed point after {MAX_ITERATIONS} iterations "
                 "(the chain oscillates or the compiler miscompiles its own source).")
        return 1

    h_final = sha256(converged_c)
    stale = h_final != h_canonical

    if args.promote:
        shutil.copyfile(converged_c, CANONICAL_C)
        out.say(f"Promoted new canonical C -> {CANONICAL_C}")
        out.say(f"old: {h_canonical}")
        out.say(f"new: {h_final}")
        update_published_c(h_final)

    if shared_dir is not None and converged_c is not None:
        # Snapshots describe the converged chain even when it is stale: the
        # driver's byte comparison is what reports staleness. Written before
        # the --check-stale failure return below, and never on no-convergence.
        write_shared_work(shared_dir, canonical_c=CANONICAL_C,
                          seed_c=first_c if first_c is not None else converged_c,
                          chain_c=converged_c, chain_exe=final_exe)

    if args.check_stale and stale:
        out.fail("Failed: converged C != committed canonical (canonical is stale).")
        out.say(f"converged: {h_final}")
        out.tip("refresh it with: python scripts/trust.py build --promote")
        return 1
    elif not args.promote and stale:
        out.say("note: sources diverge from committed canonical "
                "(expected while hacking on the compiler; promote when ready).")

    if args.out:
        out_abs = os.path.abspath(args.out)
        os.makedirs(os.path.dirname(out_abs) or ".", exist_ok=True)
        shutil.copyfile(final_exe, out_abs)
        out.say(f"Wrote fixed-point compiler to {out_abs}")

    print(f"Finished bootstrap: converged ({'matches canonical' if not stale else 'diverged from canonical'}).")
    out.say("follow-up: python scripts/trust.py verify --cc \"" + cc + "\"")
    return 0


# ---- from scripts/verify_seed.py ----
# Verify the C bootstrap fixed point (the seed-verifier flow).
#
# Reproduces the verification end to end in a hermetic work directory and
# reports whether the compiler's reproducibility contract still holds:
#
#   C fixed point    : the C emitted by the seed when it compiles
#                      ``compiler/host/main.orb`` must be byte-identical to the
#                      canonical ``compiler/selfhost/stage3.exe.c``, and so must
#                      the C emitted by every later stage of the chain.
#   binary fixed pt  : the seed chain (seed2 -> chain2 -> chain3) is additionally
#                      compared byte for byte once the COFF link timestamps are
#                      zeroed. This is toolchain-specific (linker, C compiler, PE
#                      layout) and therefore informational for gcc and clang; the
#                      reproducible cross-platform contract is the C source.
#
# There is no second lineage to cross-check against. The committed canonical C
# IS the root of trust, and ``scripts/trust.py build --promote`` is the only
# way to replace it after an intentional compiler change.
#
# ``--release`` enforces the published fixed-point C contract (``PUBLISHED_C``)
# as a hard check against the self-hosted rebuild.
#
# ``--emit-fixed-point PATH`` copies the seed-chain fixed-point compiler
# (``chain3``, byte-identical to ``seed2``/``chain2``) to PATH. That binary is
# built entirely by the self-hosted seed chain: canonical C -> seed -> seed2 ->
# chain2 -> chain3.
#
# ``--shared-work DIR`` writes the same snapshot layout as the build subcommand
# --shared-work (chain3.c, the chain3 binary, seed.c, hashes.json) once the C
# fixed point holds; the path contract (SHARED_*) is defined there, not here.
# Without the flag nothing is written. When DIR already holds snapshots for
# the current canonical, the three frontend rebuilds are skipped and the four
# equality checks run on the snapshot bytes instead; a stale or unreadable dir
# falls back to the full rebuild. The slow path (no flag) is untouched.
#
# ``--shards-dir DIR`` + ``--manifest PATH`` (carril E3, detras de flag)
# ejecutan la verificacion por shards ANTES de la cadena heredada. Sin el
# flag nada de esto se ejecuta y el comportamiento es byte-identico al
# anterior. Con header comun (ORBIT_SHARD_COMMON_H en DIR) rige el modo
# header: cat(shards)==canonical es imposible por construccion (layout
# sec. 1), asi que lo que se verifica es fidelidad de particion R10a/b
# del driver contra el canonical (cada cuerpo en exactamente un shard o
# en el header, missing=0 extra=0) mas el canonico contra PUBLISHED_C.
# Sin header rige el modo cat heredado (cat==canonical, cat==PUBLISHED_C).
#
# Heredado e intacto tras el flag: las 4 igualdades (seed builds + C de
# seed/chain2/chain3 == canonical), el contrato --release y la via rapida
# --shared-work con su binario informativo. Nuevo bajo el flag: 2
# igualdades del modo que corresponda (cat o particion+header).
#
# Exit code 0 iff every hard check passes.
#
# Usage:
#     python scripts/trust.py verify [--release] [--emit-fixed-point PATH]
#                                   [--work DIR] [--cc CC] [--refresh] [--keep]
#                                   [--shared-work DIR] [--low-mem | --no-low-mem]
#                                   [--shards-dir DIR] [--manifest PATH]
#!/usr/bin/env python3



# The bootstrap builds at -O1, or at -O0 under the low-memory profile
# (bootstrap_opt_flag in the build section). pipeline.orb builds user programs
# at -O1 (-O2 with --release).
# The -Wno-error=int-conversion / -Wno-error=incompatible-pointer-types
# downgrades that used to be here are gone: the emitted C no longer produces
# either diagnostic on any program in examples/, tests/suite/ or tests/std/, and
# the canonical unit is -Wall clean. GCC 14+ treats both as errors, so keeping
# the downgrades would only have hidden a regression. scripts/werror_gate.py
# remains the strict gate.
# -Wall is deliberately absent: on the 3.9 MB compiler unit it costs 23.8 s
# against 3.7 s without it (5.7x, 2-core runner, gcc 13.3). The fixed point is
# about emitted C bytes, not warnings; warnings are werror_gate.py's job. Set
# ORBIT_BOOTSTRAP_WARNINGS=1 to restore it locally.
# Published fixed-point contract for the current compiler source. The C hash is
# the cross-platform reproducibility contract (enforced with --release); the
# binary hash is platform/toolchain specific and stays informational.
# PUBLISHED_C is rewritten automatically by `trust.py build --promote`,
# so it always matches the committed canonical. --release enforces it.
PUBLISHED_C = "C50D93D41E92A1C5889D0337C3F86C8BA0AF04B61577DA5AFCA7338EEFE33733"
# PUBLISHED_BIN is a fingerprint of one toolchain's output only. It is reported
# for information and never asserted: PE timestamps, PDB paths, section order
# and relocation layout all differ between linkers, so a mismatch here says
# nothing about the reproducibility contract, which is the C source above.
PUBLISHED_BIN = "868935A3B60A80B4FABB6819D3B0B0EB4EB99B4ABA92F30D7351440BF1EAF35E"


def vs_detect_cc() -> str:
    env_cc = os.environ.get("ORBIT_CC")
    if env_cc:
        return env_cc
    for cand in ("gcc", "clang", "cc"):
        if shutil.which(cand):
            return cand
    return "cc"


def zero_pe_timestamp(path: str) -> bool:
    """Zero the COFF TimeDateStamp so identical builds hash equally (no-op for ELF)."""
    try:
        with open(path, "r+b") as f:
            data = f.read()
            changed = False
            # 1) TimeDateStamp
            hdr = data[:0x400]
            if len(hdr) >= 0x40:
                lfanew = struct.unpack_from("<I", hdr, 0x3C)[0]
                if lfanew + 12 <= len(data) and data[lfanew : lfanew + 4] == b"PE\x00\x00":
                    ts_off = lfanew + 8
                    if data[ts_off : ts_off + 4] != b"\x00\x00\x00\x00":
                        data = data[:ts_off] + b"\x00\x00\x00\x00" + data[ts_off + 4 :]
                        changed = True
            # 2) CodeView RSDS: random 16-byte GUID + 4-byte age + pdb path,
            # written per-link by MSVC-toolchain linkers even when stripped.
            pos = 0
            while True:
                i = data.find(b"RSDS", pos)
                if i == -1:
                    break
                end = i + 4 + 20
                j = end
                while j < len(data) and data[j] != 0:
                    j += 1
                if j > end:
                    data = data[: i + 4] + b"\x00" * (j - (i + 4)) + data[j:]
                    changed = True
                pos = j + 1
            if changed:
                f.seek(0)
                f.write(data)
            return True
    except OSError:
        return False


def vs_run(argv, cwd, env_extra=None, label=""):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    out.say(f"Running {label or ' '.join(argv)}")
    proc = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, errors="replace")
    combined = (proc.stdout or "") + (proc.stderr or "")
    if combined.strip():
        print(combined.rstrip())
    if proc.returncode != 0:
        tail = "\n".join(combined.strip().splitlines()[-30:])
        out.ci_error(f"[{label or ' '.join(argv)}] rc={proc.returncode} :: {out.scrub_ci(tail)}")
        out.fail(f"Failed {label or ' '.join(argv)} (rc={proc.returncode})")
        raise SystemExit(2)
    return proc


def consume_shared_work(shared_dir, work, h_canon):
    """Reuse validated snapshots instead of rebuilding the chain (or None).

    Fast path for ``--shared-work DIR`` when DIR already describes the
    current canonical: copy seed.c / chain3.c / the chain3 binary into work
    and hash the copies. Valid means the manifest parses with its five keys,
    its canonical_sha matches the current canonical, its runtime_sha matches
    the runtime sources on disk, and the snapshot bytes hash to the manifest's
    seed_sha/chain3_sha. The runtime check is not redundant with the canonical
    one: the canonical C includes runtime/runtime.h, so a runtime edit changes
    the binary while leaving the canonical text byte-identical. Anything else
    is None and the caller rebuilds the chain exactly as without the flag.

    The four equality checks still run on these bytes below (same check()
    calls, same digest comparisons); only the frontend rebuilds are skipped.
    Hashes are computed on the work copies, so what is checked is what was
    hashed -- never what the shared dir claimed at validation time.
    """
    if (not shared_dir or SHARED_CHAIN_C is None or SHARED_SEED_C is None
            or SHARED_MANIFEST is None or shared_chain_bin is None
            or runtime_tree_sha is None):
        return None
    try:
        with open(os.path.join(shared_dir, SHARED_MANIFEST), encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    if any(k not in doc for k in ("canonical_sha", "seed_sha", "chain3_sha", "published")):
        return None
    if "runtime_sha" not in doc:
        return None
    if doc["canonical_sha"].lower() != h_canon.lower():
        return None
    if doc["runtime_sha"].lower() != runtime_tree_sha().lower():
        return None
    try:
        seed_c = os.path.join(work, "seed.selfhost.c")
        chain2_c = os.path.join(work, "chain2.selfhost.c")
        chain3_c = os.path.join(work, "chain3.selfhost.c")
        chain_exe = os.path.join(work, "chain3" + (".exe" if sys.platform == "win32" else ""))
        shutil.copyfile(os.path.join(shared_dir, SHARED_SEED_C), seed_c)
        shutil.copyfile(os.path.join(shared_dir, SHARED_CHAIN_C), chain2_c)
        shutil.copyfile(os.path.join(shared_dir, SHARED_CHAIN_C), chain3_c)
        shutil.copyfile(os.path.join(shared_dir, shared_chain_bin()), chain_exe)
    except OSError:
        return None
    h_seed = sha256(seed_c)
    h_chain2 = sha256(chain2_c)
    h_chain3 = sha256(chain3_c)
    # All three must name the converged bytes: the manifest binds both C
    # snapshots, and the chain2 copy must equal the chain3 copy (they are
    # copies of one file; a mismatch is an incoherent dir, never a pass).
    if (h_seed.lower() != doc["seed_sha"].lower()
            or h_chain3.lower() != doc["chain3_sha"].lower()
            or h_chain2 != h_chain3):
        return None
    return (seed_c, chain2_c, chain3_c, chain_exe, h_seed, h_chain2, h_chain3)


def _list_shard_files(shards_dir: str) -> list:
    """Shard *.c files under DIR, sorted (deterministic concat order)."""
    found = []
    for name in sorted(os.listdir(shards_dir)):
        if name.endswith(".c") and "shard" in name.lower():
            found.append(os.path.join(shards_dir, name))
    return found


def _manifest_shard_order(manifest_path: str) -> list:
    """Shard tokens in first-seen (TU) order from a shards.tsv manifest.

    Layout sec. 2: ``shard\\tfunc\\tdefstart\\tend``, 1-based, TU order. Blank
    lines and ``#`` comments are skipped; ranges must satisfy 1 <= start
    <= end. Returns the shard column deduplicated, order-preserving.
    """
    order = []
    with open(manifest_path, encoding="utf-8") as f:
        for ln, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            cols = s.split("\t")
            if len(cols) < 4:
                cols = s.split()
            if ln == 1 and cols and cols[0].strip() == "shard":
                continue
            if len(cols) < 4:
                raise ValueError(f"{manifest_path}:{ln}: want 4 columns "
                                 "(shard func defstart end)")
            try:
                start, end = int(cols[2]), int(cols[3])
            except ValueError:
                raise ValueError(f"{manifest_path}:{ln}: defstart/end "
                                 "are not ints")
            if start < 1 or end < start:
                raise ValueError(f"{manifest_path}:{ln}: bad range "
                                 f"{start}..{end}")
            if cols[0].strip() not in order:
                order.append(cols[0].strip())
    if not order:
        raise ValueError(f"{manifest_path}: no shard rows")
    return order


def cmd_verify(args) -> int:
    out.set_quiet(args.quiet)
    warn_low_memory()

    if args.work:
        work = os.path.abspath(args.work)
        os.makedirs(work, exist_ok=True)
    else:
        work = tempfile.mkdtemp(prefix="orbit_verify_seed_")
    if not args.keep:
        import atexit
        atexit.register(lambda: shutil.rmtree(work, ignore_errors=True))
    # Resolved here, claimed later: claiming retires the manifest, and the
    # fast path below must validate against it first. Without the flag there
    # are no snapshots in either direction (today's behaviour, unchanged).
    shared_dir = os.path.abspath(args.shared_work) if args.shared_work else None

    checks = []

    def check(name, ok, detail=""):
        checks.append((name, ok, detail))
        if ok:
            out.say(f"Verified {name} ... ok  {detail}".rstrip())
        else:
            out.fail(f"Failed {name}: {detail}" if detail else f"Failed {name}")

    exe = ".exe" if sys.platform == "win32" else ""
    cc = args.cc or vs_detect_cc()
    cc_cmd = cc.split()
    args.low_mem = resolve_low_mem(args.low_mem, log=out.say)
    extra_cc_flags = lowmem_cc_flags(cc) if args.low_mem else []
    if args.low_mem and not extra_cc_flags:
        out.say("Low-memory profile on (no extra C flags for this driver).")
    elif extra_cc_flags:
        out.say(f"Low-memory C flags: {' '.join(extra_cc_flags)}")
    out.say(f"Verifying from root:  {ROOT}")
    out.say(f"Verifying with seed CC:  {cc}")

    if not os.path.isfile(CANONICAL_C):
        out.fail(f"Failed: {CANONICAL_C} is missing; it is the committed root of trust.")
        out.say("Restore it from git. If the file was intentionally replaced,")
        out.say("regenerate and promote it with:")
        out.say("  python scripts/trust.py build --promote")
        return 1
    h_canon = sha256(CANONICAL_C)
    out.say(f"Canonical C:  {h_canon}  ({os.path.getsize(CANONICAL_C)} bytes)")
    seed_src_c = CANONICAL_C

    # E3 shard pre-check (flag only): interim half without the per-shard
    # emitter. Concatenates the shards in order and demands the canonical
    # bytes plus PUBLISHED_C, then falls through to the inherited chain
    # untouched. Without the flag this block does not run at all.
    shards_dir_arg = os.path.abspath(args.shards_dir) if args.shards_dir else None
    manifest_arg = os.path.abspath(args.manifest) if args.manifest else None
    if manifest_arg is not None and shards_dir_arg is None:
        out.fail("Failed: --manifest needs --shards-dir.")
        return 2
    if shards_dir_arg is not None:
        t_shards = time.time()
        if not os.path.isdir(shards_dir_arg):
            out.fail(f"Failed: --shards-dir {shards_dir_arg} is not a directory.")
            return 2
        try:
            dir_names = os.listdir(shards_dir_arg)
        except OSError:
            out.fail(f"Failed: --shards-dir {shards_dir_arg} is unreadable.")
            return 2
        # Header mode (layout sec. 1): with the common header, declarations
        # live outside the shards, so cat(shards)==canonical cannot hold by
        # construction. What does hold is partition fidelity: R10a (verbatim
        # slices reproduce the TU) plus R10b (every TU body in exactly one
        # shard or the header), re-run here against the canonical.
        _headers = []
        for _name in dir_names:
            if _name.endswith(".h"):
                try:
                    with open(os.path.join(shards_dir_arg, _name), "rb") as _hf:
                        _head = _hf.read(1 << 20)
                except OSError:
                    continue
                if b"ORBIT_SHARD_COMMON_H" in _head:
                    _headers.append(_name)
        if _headers:
            if len(_headers) != 1:
                out.fail(f"Failed: {_headers} carry ORBIT_SHARD_COMMON_H; "
                         f"want exactly one common header.")
                return 1
            _shard_files = _list_shard_files(shards_dir_arg)
            if not _shard_files:
                out.fail(f"Failed: no *shard*.c files under {shards_dir_arg}.")
                return 1
            _m = re.match(r"^(.*)\.shard(\d+)\.c$",
                           os.path.basename(_shard_files[0]))
            _base = _m.group(1) if _m else None
            _want_names = set()
            for _p in _shard_files:
                _m2 = re.match(r"^(.*)\.shard(\d+)\.c$",
                               os.path.basename(_p))
                if not _m2 or _m2.group(1) != _base:
                    _base = None
                    break
                _want_names.add(int(_m2.group(2)))
            if (_base is None
                    or _want_names != set(range(len(_shard_files)))):
                out.fail("Failed: shard files are not <base>.shard0..N-1.c "
                         "with one common base.")
                return 1
            try:
                _part = split_tu(
                    CANONICAL_C,
                    os.path.join(shards_dir_arg, _headers[0]),
                    len(_shard_files))
            except (OSError, ValueError) as _e:
                out.fail(f"Failed: R10a partition of the canonical: {_e}")
                return 1
            _missing, _residual = verify_shard_coverage(
                _part, shards_dir_arg, _base)
            if manifest_arg is not None:
                if not os.path.isfile(manifest_arg):
                    out.fail(f"Failed: --manifest {manifest_arg} is missing.")
                    return 2
                try:
                    _order = _manifest_shard_order(manifest_arg)
                except (OSError, ValueError) as _e:
                    out.fail(f"Failed: bad manifest: {_e}")
                    return 1
                _nums = []
                for _t in _order:
                    if _t == "header":
                        continue
                    try:
                        _nums.append(int(_t))
                    except ValueError:
                        out.fail(f"Failed: manifest shard {_t!r} is not "
                                 f"a shard index (want 0..N-1 or header).")
                        return 1
                _nums.sort()
                if _nums != sorted(_want_names):
                    out.fail(f"Failed: manifest shards {_nums} != dir "
                             f"shards {sorted(_want_names)} "
                             f"(header rows aside).")
                    return 1
            _detail = (f"bodies={len(_part['bodies'])} "
                       f"header-owned={len(_part['header_dropped'])} "
                       f"files={len(_shard_files)}")
            check("shard partition fidelity (R10a/b vs canonical C + header)",
                  not _missing and not _residual,
                  f"{_detail} missing={len(_missing)} "
                  f"extra={len(_residual)}")
            check("partitioned canonical matches published contract "
                  "(PUBLISHED_C)",
                  h_canon.upper() == PUBLISHED_C,
                  f"canonical={h_canon.upper()} published={PUBLISHED_C}")
            out.say(f"shard verification cost: {time.time() - t_shards:.2f}s "
                    f"({_detail}, parse+coverage only)")
            if _missing or _residual or h_canon.upper() != PUBLISHED_C:
                out.fail("Failed: shard partition diverges; the inherited "
                         "chain below is skipped.")
                return 1
        if not _headers:
            # No common header: the legacy cat mode (pre-E1 bundles
            # whose shards concatenate back to the canonical).
            shard_files = _list_shard_files(shards_dir_arg)
            if not shard_files:
                out.fail(f"Failed: no *shard*.c files under {shards_dir_arg}.")
                return 1
            if manifest_arg is not None:
                if not os.path.isfile(manifest_arg):
                    out.fail(f"Failed: --manifest {manifest_arg} is missing.")
                    return 2
                try:
                    _order = _manifest_shard_order(manifest_arg)
                except (OSError, ValueError) as _e:
                    out.fail(f"Failed: bad manifest: {_e}")
                    return 1
                _ordered = []
                for _tok in _order:
                    _hits = [p for p in shard_files
                             if _tok == os.path.basename(p)
                             or _tok in os.path.basename(p)]
                    if len(_hits) != 1:
                        out.fail(f"Failed: manifest shard {_tok!r} matches "
                                 f"{len(_hits)} files; want exactly 1.")
                        return 1
                    _ordered.append(_hits[0])
                if len(_ordered) != len(shard_files):
                    out.fail(f"Failed: manifest names {len(_ordered)} shards, "
                             f"dir holds {len(shard_files)}.")
                    return 1
                shard_files = _ordered
                out.say(f"shard manifest: {manifest_arg} "
                        f"({len(_order)} shards in TU order)")
            _h = hashlib.sha256()
            _total = 0
            for _p in shard_files:
                with open(_p, "rb") as _f:
                    for _chunk in iter(lambda: _f.read(1 << 20), b""):
                        _h.update(_chunk)
                        _total += len(_chunk)
            h_cat = _h.hexdigest()
            check("shard concatenation (cat(shards in order) == canonical C)",
                  h_cat == h_canon,
                  f"cat={h_cat} canonical={h_canon} "
                  f"files={len(shard_files)} bytes={_total}")
            check("shard concatenation matches published contract (PUBLISHED_C)",
                  h_cat.upper() == PUBLISHED_C,
                  f"cat={h_cat.upper()} published={PUBLISHED_C}")
            out.say(f"shard verification cost: {time.time() - t_shards:.2f}s "
                    f"({len(shard_files)} files, {_total} bytes, hashes+cat only)")
            if h_cat != h_canon or h_cat.upper() != PUBLISHED_C:
                out.fail("Failed: shard concatenation diverges; the inherited "
                         "chain below is skipped.")
                return 1

    fast = consume_shared_work(shared_dir, work, h_canon) if shared_dir else None
    if fast is not None:
        (fast_seed_c, fast_chain2_c, fast_chain3_c, fast_chain_exe,
         fast_h_seed, fast_h_chain2, fast_h_chain3) = fast
        out.say(f"shared snapshots: reused seed.c/chain3.c/chain3.exe from "
                f"{shared_dir} (no frontend rebuild; checks run on those bytes)")
    if shared_dir is not None:
        shared_dir = claim_shared_work(shared_dir)

    amal = os.path.join(work, "orbit_bootstrap.c")
    vs_run([sys.executable, TRUST, "amalgamate", "--entry", seed_src_c, "--out", amal], ROOT, label="amalgamate")

    # Fixed -o basename shared with the build subcommand: see the comment there.
    # Flags are bootstrap_cc_middle, the one constructor both scripts share
    # (Fase A, pieza F): same content, same flags, same cc -> same cache entry.
    # Extra low-memory flags ride along too (this machine auto-enables them),
    # which is what used to keep this entry apart from build's seed entry.
    seed_exe = os.path.join(work, "orbit_seed_frozen" + exe)
    seed_argv = [*cc_cmd, *bootstrap_cc_middle(cc, args.low_mem),
                 "-o", seed_exe, amal, *PLATFORM_LINK_FLAGS]
    seed_argv, seed_sources = orbit_ccache.windows_stamp(
        seed_argv, [amal], work, "Orbit compiler", log=out.say)
    orbit_ccache.compile_cached(cc_cmd, seed_argv, seed_sources, log=out.say)
    check("seed builds", os.path.isfile(seed_exe))

    def orb_build(compiler, out_name, snapshot_c):
        # All builds write the intermediate C to the SAME path: clang embeds the
        # C source path in the binary, so a per-build directory would break the
        # binary fixed point even for identical code. Snapshot the C afterwards.
        tmp = os.path.join(work, "tmp_build")
        os.makedirs(tmp, exist_ok=True)
        label = f"{os.path.basename(compiler)} -> {out_name}"
        # Windows real-time AV (Defender) briefly locks freshly linked
        # executables; running one immediately after linking can fail
        # spuriously. Retry once before giving up.
        last_rc = None
        for attempt in (1, 2):
            # The compiler emits the C and stops (ORBIT_SKIP_CC); this script
            # compiles that C itself below with known-good flags. See the same
            # comment in the build section. ORBIT_CCFLAGS_EXTRA mirrors
            # the build section for old compilers that ignore ORBIT_SKIP_CC.
            env = dict(os.environ)
            env.update({"TEMP": tmp, "TMP": tmp, "TMPDIR": tmp, "ORBIT_CC": cc,
                        "CC": cc, "ORBIT_SKIP_CC": "1", "ORBIT_WARNINGS": "0",
                        "ORBIT_CCFLAGS_EXTRA": " ".join(extra_cc_flags)})
            out.say(f"Building {label}" + ("  (retry)" if attempt == 2 else ""))
            proc = subprocess.run([compiler, "build", MAIN_ORB, "-o", os.path.join(work, out_name)], cwd=ROOT, env=env)
            last_rc = proc.returncode
            if last_rc == 0:
                break
            time.sleep(3)
        if last_rc != 0:
            # The compiler's internal cc step is incidental to the contract:
            # what matters is the emitted C (fixed point) and binaries built by
            # OUR OWN toolchain invocation. If it failed (e.g. AV locks or
            # memory pressure killing the linker), rebuild from the snapshot.
            c = os.path.join(tmp, "orbit_selfhost_build.c")
            if not os.path.isfile(c):
                out.fail(f"Failed ({last_rc}): {label} (no C emitted)")
                raise SystemExit(2)
            out.say(f"note: {label} exited {last_rc} after emitting C; rebuilding with our own cc.")
        else:
            c = os.path.join(tmp, "orbit_selfhost_build.c")
        # Deterministic contract binaries: ALWAYS rebuild from the shared
        # intermediate C with a FIXED output name. Internal builds use
        # per-stage -o names and lld-link embeds <output>.pdb into PE even
        # stripped, which breaks byte-equality across stages.
        shared = os.path.join(tmp, "orbit_selfhost_build.c")
        if os.path.abspath(c) != os.path.abspath(shared):
            shutil.copyfile(c, shared)
        fixed_out = os.path.join(work, "fixed_point_build" + exe)
        fixed_argv = [*cc_cmd, *bootstrap_cc_middle(cc, args.low_mem),
                      "-I", os.path.join(ROOT, "runtime"),
                      "-o", fixed_out, shared, *PLATFORM_LINK_FLAGS]
        fixed_argv, fixed_sources = orbit_ccache.windows_stamp(
            fixed_argv, [shared], work, "Orbit compiler", log=out.say)
        reused = compile_tu_exe(cc, cc_cmd, fixed_argv, fixed_sources,
                                shared, fixed_out, work, out_name)
        out.say(f"deterministic rebuild {out_name}"
                + ("  (from cache)" if reused else ""))
        shutil.move(fixed_out, os.path.join(work, out_name))
        shutil.copyfile(c, snapshot_c)
        return snapshot_c, reused

    if fast is not None:
        # No frontend rebuild: the check below hashes these snapshot bytes
        # against the canonical exactly as in the slow path.
        seed_c, h_seed_c, seed_reused = fast_seed_c, fast_h_seed, True
    else:
        seed_c, seed_reused = orb_build(seed_exe, "seed2" + exe, os.path.join(work, "seed.selfhost.c"))
        h_seed_c = sha256(seed_c)
    check("seed C fixed point (seed C == canonical C)", h_seed_c == h_canon, f"seed={h_seed_c}")
    if h_seed_c != h_canon:
        out.fail("Failed: the seed does not reproduce the canonical C; the fixed point is broken.")
        return 1

    seed2 = os.path.join(work, "seed2" + exe)
    chain2 = os.path.join(work, "chain2" + exe)
    chain3 = os.path.join(work, "chain3" + exe)
    if fast is not None:
        # One converged artifact by construction: every contract binary below
        # is this same file, so the binary section reports reuse (as on a
        # cache hit) rather than claiming a pass. chain3 already sits at
        # fast_chain_exe; copying it onto itself would raise SameFileError.
        for _b in (seed2, chain2):
            shutil.copyfile(fast_chain_exe, _b)
        chain3 = fast_chain_exe
        chain2_c, chain2_reused = fast_chain2_c, True
        chain3_c, chain3_reused = fast_chain3_c, True
    else:
        chain2_c, chain2_reused = orb_build(seed2, "chain2" + exe, os.path.join(work, "chain2.selfhost.c"))
        chain3_c, chain3_reused = orb_build(chain2, "chain3" + exe, os.path.join(work, "chain3.selfhost.c"))

    # Every stage must re-emit the canonical C, not just the first one. At a
    # genuine fixed point all three are byte-identical; asserting it closes the
    # hole where only stage one is compared and later stages drift silently.
    if fast is not None:
        h_chain2_c, h_chain3_c = fast_h_chain2, fast_h_chain3
    else:
        h_chain2_c = sha256(chain2_c)
        h_chain3_c = sha256(chain3_c)
    check("chain2 C fixed point (chain2 C == canonical C)", h_chain2_c == h_canon,
          f"chain2={h_chain2_c}")
    check("chain3 C fixed point (chain3 C == canonical C)", h_chain3_c == h_canon,
          f"chain3={h_chain3_c}")

    bins = [seed_exe, seed2, chain2, chain3]
    for b in bins:
        zero_pe_timestamp(b)
    h_bins = [sha256(b) for b in bins]
    if (shared_dir is not None and h_seed_c == h_canon
            and h_chain2_c == h_canon and h_chain3_c == h_canon):
        # Written only on C convergence ("tras converger"): a failed run leaves
        # the dir without hashes.json (retired at startup), which is the
        # driver's signal not to consume it. After the timestamp zeroing above,
        # so the snapshot binary carries the exact bytes the log hashes below.
        write_shared_work(shared_dir, canonical_c=CANONICAL_C, seed_c=seed_c,
                          chain_c=chain3_c, chain_exe=chain3)
    reused = {"seed2": seed_reused, "chain2": chain2_reused, "chain3": chain3_reused}
    any_reused = any(reused.values())
    # Binary reproducibility is toolchain-specific by design (see module
    # docstring): some toolchains strip deterministically, while PE-target
    # linkers randomize more than timestamps/GUIDs (section order, relocs), so
    # this stays informational. A cache hit also makes the three contract
    # binaries the same stored artifact by construction, so on a hit this
    # reports reuse rather than claiming a pass.
    if any_reused:
        reused_names = ", ".join(sorted(n for n, v in reused.items() if v))
        origin = "shared snapshots" if fast is not None else "compile cache"
        out.say(f"note: binary fixed point not evaluated ({origin} reused "
                f"{reused_names}); the C fixed point above is unaffected and is "
                "the cross-platform contract. Set ORBIT_CCACHE=0 to force it.")
        for n, h in zip(("seed2", "chain2", "chain3"), h_bins[1:]):
            out.say(f"  {n}={h}")
    else:
        ok_bins = h_bins[1] == h_bins[2] == h_bins[3]
        out.say(f"note: binary fixed point {'PASS' if ok_bins else 'DIFFERS'} "
                f"(informational for toolchain {cc})")
        for n, h in zip(("seed2", "chain2", "chain3"), h_bins[1:]):
            out.say(f"  {n}={h}")

    if h_seed_c.upper() == PUBLISHED_C:
        out.say(f"note: seed C matches published contract {PUBLISHED_C}")
    if h_bins[1].upper() == PUBLISHED_BIN:
        out.say(f"note: chain binaries match published binary contract {PUBLISHED_BIN}")
    if args.release:
        check("published C contract (--release)", h_seed_c.upper() == PUBLISHED_C,
              f"seed={h_seed_c.upper()} published={PUBLISHED_C}")
        # PUBLISHED_BIN stays informational: the released binary differs per
        # platform/toolchain (linker, C compiler, PE layout). The reproducible
        # cross-platform contract is the C source, enforced above.

    if args.refresh:
        os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
        shutil.copyfile(amal, os.path.join(ROOT, "dist", "orbit_bootstrap.c"))
        out.say("Refreshing dist/orbit_seed")
        dist_argv = [*cc_cmd, *bootstrap_cc_middle(cc, args.low_mem),
                     "-o", os.path.join(ROOT, "dist", "orbit_seed" + exe),
                     amal, *PLATFORM_LINK_FLAGS]
        dist_argv, dist_sources = orbit_ccache.windows_stamp(
            dist_argv, [amal], work, "Orbit compiler", log=out.say)
        orbit_ccache.compile_cached(cc_cmd, dist_argv, dist_sources, log=out.say)

    if args.emit_fixed_point:
        os.makedirs(os.path.dirname(os.path.abspath(args.emit_fixed_point)), exist_ok=True)
        shutil.copyfile(chain3, args.emit_fixed_point)
        if os.name != "nt":
            os.chmod(args.emit_fixed_point, 0o755)
        out.say(f"Wrote fixed-point compiler (seed chain, chain3) to {args.emit_fixed_point}")

    failed = [n for n, ok, _ in checks if not ok]
    out.finish("verify", len(checks) - len(failed), len(checks))
    out.say("work dir: " + work)
    if failed:
        details = []
        for n, ok, d in checks:
            if not ok:
                details.append(f"{n}: {d}")
        out.fail("Failed: " + " | ".join(details))
        out.ci_error("[verify checks] " + out.scrub_ci(" | ".join(details)))
    return 1 if failed else 0


# ---- from scripts/shard_selfhost.py ----
# Sharded build driver for the Orbit selfhost compiler C.
#
# Contract: docs/shard_layout.md (the emitter owns the layout; this driver
# implements against it). Given the single-TU emission (<base>.c plus the
# compiler-emitted <base>.h), the driver partitions the TU into 8 shards
# (R1-R7), compiles each shard with ``gcc -c`` in parallel plus link (R8),
# and verifies that the linked binary re-emits byte-identical C (R10c).
#
# E1 mode (``--header`` points at the compiler-emitted ``<base>.h``; when
# absent, ``<tu-dir>/<base>.h`` is used when it exists): the TU already
# carries external linkage; gaps stay in the header (R2), ``static inline``
# bodies stay in the header (R3), guard-wrapped bodies keep their ``#if``
# openers/closers (R4), shard0 carries the prologue plus the named preamble
# helpers (R5), the tail goes to the last shard (R6), the rest is dealt
# greedily by body-line count (R7). A TU without its E1 header is refused:
# there is no unity fallback here (that fallback lives in the callers,
# which compile unity when this driver fails).
#
# Usage:
#     python scripts/trust.py shard --tu path/to/orbit_selfhost_build.c
#         --header path/to/orbit_selfhost_build.h
#         --shards-dir C:/Temp/sharde2/shards --cc gcc --jobs 8
#         --out C:/Temp/sharde2/shardlinked.exe
#         --reference C:/Temp/sharde2/fp.exe --verify
#
#     python scripts/trust.py shard --self-test   # D8 aliveness (fast)
#
# Exit codes: 0 ok; 1 partition/coverage failure; 2 a shard did not compile
# (the message names the shard); 3 link failure; 4 emission SHA mismatch;
# 5 usage/environment failure. No state is kept between runs: every output
# goes under --shards-dir and a private temp dir (removed unless --keep).
#
# The header is copied into --shards-dir next to the shards, so the bundle
# (shards + header + TSV) is self-describing for verifiers. Shard compile
# flags mirror the TU flags plus -DORBIT_SEPARATE_COMPILATION, so the link
# needs libruntime_net.a (R8); unity builds omit the flag and carry the
# runtime inline instead, which is why they link with no library.
#
# DB programs stay on the unity build (R8): a TU with a real (column-0)
# ``ORBIT_WITH_DB`` conditional fails here instead of mislinking.
#!/usr/bin/env python3



DEFAULT_TU = os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c")
DEFAULT_RUNTIME = os.path.join(ROOT, "runtime")
N_SHARDS = 8

# R5: preamble-helper bodies owned by shard0, in this order. Only the ones
# present in the TU are moved (selfhost carries orbit_color_enabled only;
# route programs carry the rest).
PREAMBLE_HELPERS = (
    "orbit_color_enabled",
    "orbit_print_kynx_gradient",
    "orbit_render_server_banner",
    "orbit_worker_loop",
    "orbit_ctrl_handler",
    "orbit_term_handler",
    "orbit_kynx_register_limits",
)

# R1: a definition starts at a column-0 line outside #/}/, ending with {,
# whose name before ( is not a control word. Bodies are indented, but
# goto labels land at column 0 inside bodies and must be skipped.
DEF_RE = re.compile(
    r'^(static\s+)?(__attribute__\(\(.*?\)\)\s+)?(inline\s+)?'
    r'([A-Za-z_][\w]*[\s\*]+)+([A-Za-z_][\w]*)\s*\(')
CTRL = {'if', 'while', 'for', 'switch', 'return', 'sizeof'}


def fail(msg, code=1):
    out.fail("Failed shard-selfhost: %s" % msg)
    return code


def sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_tu(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    text = raw.decode("utf-8")
    newline = "\r\n" if b"\r\n" in raw else "\n"
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return raw, lines, newline


def is_def(line):
    if not line or line[0] in ' \t#}/':
        return None
    s = line.strip()
    if not s.endswith('{'):
        return None
    m = DEF_RE.match(s)
    if not m or m.group(5) in CTRL:
        return None
    return m.group(5)


def parse_tu(lines):
    """R1: brace-aware partition into header, bodies, gaps, tail."""
    starts = []
    for i, l in enumerate(lines):
        name = is_def(l)
        if name:
            starts.append((i, name))
    if not starts:
        raise ValueError("no top-level definitions found (R1 found nothing)")

    def body_end(st, limit):
        j = st + 1
        while j < limit:
            l = lines[j]
            if l == '' or l[0] in '# \t':
                j += 1
                continue
            if l[0] == '}':
                return j
            s = l.strip()
            if re.match(r'^\w+:\s*;?$', s) or s.startswith('case ') \
                    or s.startswith('default:'):
                j += 1
                continue
            return j - 1
        return limit - 1

    bodies = []
    for si, (st, name) in enumerate(starts):
        limit = starts[si + 1][0] if si + 1 < len(starts) else len(lines)
        bodies.append([st, body_end(st, limit), name])
    gaps = []
    for si, (st, en, _name) in enumerate(bodies):
        prev = bodies[si - 1][1] + 1 if si > 0 else starts[0][0]
        gaps.append(lines[prev:st])
    tail = lines[bodies[-1][1] + 1:]
    return lines[:starts[0][0]], bodies, gaps, tail


def cond_pairs(lines):
    stack, pairs = [], {}
    for i, l in enumerate(lines):
        s = l.strip()
        if re.match(r'#\s*(if|ifdef|ifndef)\b', s):
            stack.append(i)
        elif re.match(r'#\s*endif\b', s):
            if stack:
                pairs[stack.pop()] = i
    return pairs


def assert_no_toplevel_else(lines, bodies):
    """R4 precondition: no top-level #else/#elif. Body-internal directives
    are the owning body's business; only gap/header/tail lines count."""
    in_body = set()
    for st, en, _name in bodies:
        in_body.update(range(st, en + 1))
    depth = 0
    for i, l in enumerate(lines):
        if i in in_body:
            continue
        s = l.strip()
        if re.match(r'#\s*(if|ifdef|ifndef)\b', s):
            depth += 1
        elif re.match(r'#\s*endif\b', s):
            depth = max(0, depth - 1)
        elif re.match(r'#\s*(else|elif)\b', s):
            if depth <= 1:
                raise ValueError(
                    "top-level #else/#elif at TU line %d (R4 forbids it): %s"
                    % (i + 1, s[:80]))


def opener_macro(opener_line):
    s = opener_line.strip()
    m = re.match(r'#\s*ifdef\s+([A-Za-z_][\w]*)', s)
    if m:
        return m.group(1)
    m = re.match(r'#\s*ifndef\s+([A-Za-z_][\w]*)', s)
    if m:
        return m.group(1)
    m = re.match(r'#\s*if\b(.*)$', s)
    if m:
        e = m.group(1).strip()
        for pat in (r'^defined\s*\(\s*([A-Za-z_][\w]*)\s*\)$',
                    r'^!defined\s*\(\s*([A-Za-z_][\w]*)\s*\)$',
                    r'^!?([A-Za-z_][\w]*)$'):
            mm = re.match(pat, e)
            if mm:
                return mm.group(1)
    return None


def region_is_stateful(lines, opener, closer):
    """A region that #defines the macro it tests (layout section 5,
    AST_VARIANTS_DEFINED): wrapping re-tests against header state, so the
    header owns the body instead."""
    macro = opener_macro(lines[opener])
    if not macro:
        return False
    return any(re.match(r'#\s*define\s+%s\b' % re.escape(macro),
                        lines[i].strip())
               for i in range(opener + 1, closer))


# destaticize helpers: kept for the coverage normalizer below, which must
# accept both spellings of a definition line when it compares TU bytes
# against shard bytes. The writer itself is verbatim-only (E1): shard
# bodies keep the TU's external linkage untouched.


def destatic_defline(line):
    if line.startswith('static inline '):
        return line[len('static inline '):]
    if line.startswith('static '):
        return line[len('static '):]
    m = re.match(r'^(__attribute__\(\(.*?\)\)\s+)static inline\s+', line)
    if m:
        return m.group(1) + line[m.end():]
    m = re.match(r'^(__attribute__\(\(.*?\)\)\s+)static\s+', line)
    if m:
        return m.group(1) + line[m.end():]
    return line


def destatic_protoline(line):
    if line.startswith('static '):
        return line[len('static '):]
    m = re.match(r'^(__attribute__\(\(.*?\)\)\s+)static\s+', line)
    if m:
        return m.group(1) + line[m.end():]
    return line


def greedy_balance(bodies, indices, n):
    """R7: deal in TU order, greedily balanced by body-line count."""
    def blen(si):
        st, en, _name = bodies[si]
        return en - st + 1
    total = sum(blen(si) for si in indices)
    target = total / n if n else 0
    groups, cur, acc = [], [], 0.0
    for si in indices:
        cur.append(si)
        acc += blen(si)
        if len(groups) < n - 1 and acc >= target:
            groups.append(cur)
            cur, acc = [], 0.0
    groups.append(cur)
    while len(groups) < n:
        groups.append([])
    return groups


def check_cat_identical(lines, header, bodies, gaps, tail):
    """R10a: verbatim slices in TU order reproduce the TU byte-for-byte."""
    seq = list(header)
    for si, (_st, _en, _name) in enumerate(bodies):
        st, en, _name = bodies[si]
        seq.extend(gaps[si])
        seq.extend(lines[st:en + 1])
    seq.extend(tail)
    return seq == lines


def split_tu(tu_path, header_path, n_shards):
    """Partition per R1-R7. Returns a dict with shard files content,
    the TSV rows, and the verification evidence. The E1 header is
    required: without it the TU's declarations have nowhere to live,
    so there is no split to verify (callers fall back to unity)."""
    _raw, lines, _nl = read_tu(tu_path)
    header_part, bodies, gaps, tail = parse_tu(lines)
    assert_no_toplevel_else(lines, bodies)

    for i, l in enumerate(lines):
        if re.match(r'^#\s*(if|ifdef|ifndef).*ORBIT_WITH_DB', l):
            raise ValueError(
                "TU line %d tests ORBIT_WITH_DB: DB programs stay on the "
                "unity build (R8)" % (i + 1))

    pairs = cond_pairs(lines)
    if not header_path:
        raise ValueError(
            "no E1 header: split %s needs the compiler-emitted %s "
            "(build the TU with the current compiler so <base>.h exists; "
            "without it there is no shard verification to run)"
            % (tu_path, "<base>.h"))
    with open(header_path, "r", encoding="utf-8", errors="replace",
               newline="") as fh:
        header_text = fh.read()
    if "ORBIT_SHARD_COMMON_H" not in header_text:
        raise ValueError(
            "%s does not carry ORBIT_SHARD_COMMON_H: not the "
            "compiler-emitted shard header" % header_path)

    if not check_cat_identical(lines, header_part, bodies, gaps, tail):
        raise ValueError("R10a failed: verbatim slices do not reproduce "
                         "the TU (parser bug, not a sharding decision)")

    opens_map, stateful, wrapped = {}, set(), {}
    for si, (st, en, name) in enumerate(bodies):
        opens = sorted(o for o, c in pairs.items() if o < st and c > en)
        opens_map[si] = opens
        if not opens:
            continue
        if any(region_is_stateful(lines, o, pairs[o]) for o in opens):
            stateful.add(si)
        else:
            wrapped[si] = opens

    inline_dropped = {si for si, (st, _en, _name) in enumerate(bodies)
                      if lines[st].startswith('static inline ')}
    header_dropped = set(inline_dropped)
    for si in stateful:
        opener_text = lines[opens_map[si][0]]
        if opener_text not in header_text:
            raise ValueError(
                "body %s (TU line %d) lives in a stateful region owned "
                "by the header, but the header does not carry %r; "
                "the layout moved under this driver"
                % (bodies[si][2], bodies[si][0] + 1, opener_text[:80]))
        header_dropped.add(si)
    for si in inline_dropped:
        if bodies[si][2] not in header_text:
            raise ValueError(
                "R3 body %s (TU line %d) is not declared in %s; "
                "the layout moved under this driver"
                % (bodies[si][2], bodies[si][0] + 1, header_path))

    helpers = [si for si, (_st, _en, name) in enumerate(bodies)
               if name in PREAMBLE_HELPERS and si not in header_dropped]
    helper_set = set(helpers)
    helpers.sort(key=lambda si: PREAMBLE_HELPERS.index(bodies[si][2]))
    assignable = [si for si in range(len(bodies))
                  if si not in header_dropped and si not in helper_set]
    groups = greedy_balance(bodies, assignable, n_shards)

    # R10b: every non-dropped body lands in exactly one shard.
    seen = [si for g in groups for si in g] + helpers
    missing = sorted(set(assignable) - set(seen))
    dup = sorted(si for si in set(seen)
                 if seen.count(si) > 1 or si in header_dropped)
    if missing or dup:
        raise ValueError("R10b failed: missing=%s duplicate=%s"
                         % (missing, dup))

    return {
        "lines": lines, "header_part": header_part,
        "bodies": bodies, "gaps": gaps, "tail": tail,
        "pairs": pairs, "opens_map": opens_map, "wrapped": wrapped,
        "header_dropped": header_dropped, "helpers": helpers,
        "groups": groups, "header_text": header_text,
    }


def body_text(part, si):
    lines, bodies, pairs = part["lines"], part["bodies"], part["pairs"]
    st, en, _name = bodies[si]
    pre = [lines[o] for o in sorted(part["wrapped"].get(si, []))]
    closers = sorted((pairs[o] for o in part["wrapped"].get(si, [])),
                     reverse=True)
    post = [lines[c] for c in closers]
    return pre + lines[st:en + 1] + post


def write_shards(part, base, shards_dir, newline, header_path=None):
    os.makedirs(shards_dir, exist_ok=True)
    n = len(part["groups"])
    paths = []

    for k in range(n):
        banner = ("/* Shard %d/%d of %s.c: driver-split per "
                  "docs/shard_layout.md R1-R7. */\n"
                  % (k, n, base))
        chunks = ['#include "%s.h"' % base]
        if k == 0:
            # R5 prologue, in order.
            chunks.append('#include "thread_pool.c"')
            chunks.append('OrbitArena* arena = NULL;')
            chunks.append('#ifdef _WIN32')
            chunks.append('void __main(void) {}')
            chunks.append('#endif')
            for si in part["helpers"]:
                chunks.extend(body_text(part, si))
        for si in part["groups"][k]:
            chunks.extend(body_text(part, si))
        if k == n - 1 and part["tail"]:
            # R6: the tail goes to the last shard.
            chunks.extend(part["tail"])
        text = banner + "\n".join(c for c in chunks if c.strip()) + "\n"
        path = os.path.join(shards_dir, "%s.shard%d.c" % (base, k))
        with open(path, "w", encoding="utf-8", newline=newline) as fh:
            fh.write(text)
        paths.append(path)

    if header_path:
        # The bundle carries its own header copy, so a verifier holding
        # only --shards-dir can re-run R10a/b against the TU. Shard
        # compilation itself keeps resolving the header from the TU dir.
        dst = os.path.join(shards_dir, base + ".h")
        if os.path.abspath(header_path) != os.path.abspath(dst):
            shutil.copyfile(header_path, dst)

    rows = ["shard\tfunc\tdefstart_line\tend_line"]
    order = []
    for k in range(n):
        order.extend([(k, si) for si in ([*part["helpers"]] if k == 0 else [])
                      + part["groups"][k]])
    for si in sorted(part["header_dropped"]):
        order.append(("header", si))
    order.sort(key=lambda t: part["bodies"][t[1]][0])
    for tag, si in order:
        st, en, name = part["bodies"][si]
        rows.append("%s\t%s\t%d\t%d" % (tag, name, st + 1, en + 1))
    tsv = os.path.join(shards_dir, "%s.shards.tsv" % base)
    with open(tsv, "w", encoding="utf-8", newline=newline) as fh:
        fh.write("\n".join(rows) + "\n")
    return paths, tsv


def verify_shard_coverage(part, shards_dir, base):
    """R10b: every shard line traces to a TU line or a documented
    prologue/wrap line; every assigned TU body line is present. Gaps and
    the header part live in the compiler-emitted header, R3/stateful
    bodies live there too; shards carry assigned bodies plus the tail
    (R6).
    """
    owned = set(part["header_dropped"])
    tu_sel = []
    for st, en, _name in (b for si, b in enumerate(part["bodies"])
                          if si not in owned):
        tu_sel.extend(part["lines"][st:en + 1])
    tu_sel.extend(part["tail"])
    tu_lines = [l for l in tu_sel if l.strip()]
    have = []
    for k in range(len(part["groups"])):
        with open(os.path.join(shards_dir, "%s.shard%d.c" % (base, k)),
                  encoding="utf-8", newline="") as fh:
            have.extend(l for l in fh.read().split("\n") if l.strip())
    def norm(line):
        if line and line[0] not in ' \t':
            if is_def(line):
                return destatic_defline(line)
            if line.rstrip().endswith(');') and not line.startswith('#'):
                return destatic_protoline(line)
            if line == 'extern OrbitArena* arena;':
                return 'OrbitArena* arena = NULL;'
            if line == 'void __main(void);':
                return 'void __main(void) {}'
        return line

    from collections import Counter
    want = Counter(norm(l) for l in tu_lines)
    got = Counter(norm(l) for l in have)
    missing = list((want - got).elements())
    extra = list((got - want).elements())
    wrap_lines = []
    for si, opens in part["wrapped"].items():
        for o in opens:
            wrap_lines.append(norm(part["lines"][o]))
            wrap_lines.append(norm(part["lines"][part["pairs"][o]]))
    from collections import Counter as _C
    residual = list((_C(extra) - _C(wrap_lines)).elements())
    # Shard prologues (R5/R8): includes, banners, arena/__main lines.
    prologue_ok = re.compile(
        r'^(#include |/\*|OrbitArena\* arena = NULL;|void __main|'
        r'#ifdef _WIN32|#endif|extern OrbitArena\* arena;|void __main\(void\);)')
    residual = [l for l in residual if not prologue_ok.match(norm(l))]
    return missing, residual


def ensure_lib(cc, work, lib_override):
    if lib_override:
        if not os.path.isfile(lib_override):
            raise ValueError("--lib %s does not exist" % lib_override)
        return os.path.abspath(lib_override)
    import mklib_runtime
    from pathlib import Path
    mk = Path(work) / "mk"
    mk.mkdir(parents=True, exist_ok=True)
    out_path = Path(work) / "libruntime_net.a"
    # This archive links the fixed-point compiler, which spawns its own C
    # compiler. Under -DORBIT_SEPARATE_COMPILATION the exec implementation
    # lives here, not in the compiler's TU, so this define is what decides
    # whether a shard-built compiler can build programs at all. Without it
    # the compiler reports success without producing a binary -- ERRORS-1's
    # symptom, re-entered through the shard lane.
    rc = mklib_runtime.build_lib(cc, out_path, mk, defines=("ORBIT_WITH_EXEC",))
    if rc != 0:
        raise ValueError("mklib_runtime did not build (rc=%d)" % rc)
    return str(out_path)


def ensure_lib_cached(cc, lib_dir, lib_override):
    """ensure_lib, but reused across calls sharing lib_dir.

    The library TU costs ~5s (-O2); a bootstrap run compiles up to three
    big TUs, so rebuilding it per TU would eat the shard gain. The bytes
    depend only on runtime/ + cc, neither of which moves mid-run: when
    lib_dir already holds the archive, it is reused as-is.
    """
    if lib_override:
        return ensure_lib(cc, lib_dir, lib_override)
    cand = os.path.join(lib_dir, "libruntime_net.a")
    if os.path.isfile(cand):
        return os.path.abspath(cand)
    return ensure_lib(cc, lib_dir, None)


def shard_enabled():
    """Whether bootstrap callers may try sharded TU compiles.

    On unless ORBIT_SHARD_BUILD is 0/false/no (the unity build). The
    sharded compile of the 5.9 MB compiler unit takes 5-8 s of compile wall
    on 8 cores against 18-20 s for the unity -O1 build. Any shard failure
    falls back to unity (slow, never a false green).
    """
    return os.environ.get("ORBIT_SHARD_BUILD", "").strip().lower() not in (
        "0", "false", "no")


def shard_jobs(default=8):
    """Parallel shard compiles (ORBIT_SHARD_JOBS overrides)."""
    try:
        want = int(os.environ.get("ORBIT_SHARD_JOBS", "").strip() or default)
    except ValueError:
        return default
    return want if want >= 1 else default


def compile_shards(cc, shard_paths, work, inc_dirs, defines, jobs, opt="-O0"):
    obj_dir = os.path.join(work, "obj")
    os.makedirs(obj_dir, exist_ok=True)
    flags = [opt, "-DORBIT_WITH_EXEC", "-DORBIT_SEPARATE_COMPILATION",
             "-g0", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables"]
    for d in defines:
        flags.append("-D" + d)
    for inc in inc_dirs:
        flags += ["-I", inc]

    def one(src):
        obj = os.path.join(obj_dir,
                           os.path.basename(src) + ".o")
        argv = [cc] + flags + ["-c", "-o", obj, src]
        t0 = time.monotonic()
        proc = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True,
                              errors="replace")
        return src, obj, time.monotonic() - t0, proc

    t0 = time.monotonic()
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(one, s): s for s in shard_paths}
        for fut in concurrent.futures.as_completed(futs):
            results.append(fut.result())
    wall = time.monotonic() - t0
    ok, worst = True, 0.0
    for src, _obj, dt, proc in sorted(results):
        worst = max(worst, dt)
        if proc.returncode != 0:
            ok = False
            tag = os.path.basename(src)
            out.fail("shard %s did not compile (rc=%d, %.1fs)"
                     % (tag, proc.returncode, dt))
            tail = ((proc.stdout or "") + (proc.stderr or "")).strip()
            print("\n".join(tail.splitlines()[-25:]))
    return results, wall, worst, ok


def shard_build(cc, tu_path, header_path, out_exe, work, tag="tu",
                jobs=8, n_shards=None, runtime_dir=None, defines=(),
                lib_dir=None, log=None, opt="-O0"):
    """Compile one compiler-emitted TU via shards; raise on any failure.

    Split (R1-R7, R10a/b enforced) + parallel gcc -c (R8) + link against
    libruntime_net.a into out_exe. Raises ValueError/RuntimeError with
    the cause; callers catch it and fall back to the unity compile, so a
    shard failure costs time, never correctness. work holds shards_<tag>/
    plus objects; lib_dir (when given) holds the shared libruntime_net.a
    across calls, else work does. Returns a dict with split/wall/link
    times. No emission check here: the caller's own convergence hashes
    are the verdict (a bad shard binary diverges loudly, never green).
    """
    say = log or (lambda _m: None)
    n = n_shards or N_SHARDS
    rdir = runtime_dir or DEFAULT_RUNTIME
    tu_abs = os.path.abspath(tu_path)
    tu_dir, tu_file = os.path.split(tu_abs)
    base = tu_file[:-2] if tu_file.endswith(".c") else tu_file
    t0 = time.monotonic()
    part = split_tu(tu_abs, header_path, n)
    shards_dir = os.path.join(os.path.abspath(work), "shards_" + tag)
    _raw, _lines, newline = read_tu(tu_abs)
    try:
        shard_paths, _tsv = write_shards(part, base, shards_dir, newline,
                                         os.path.abspath(header_path))
    except OSError as exc:
        raise RuntimeError("cannot write shards: %s" % exc)
    missing, residual = verify_shard_coverage(part, shards_dir, base)
    if missing or residual:
        raise RuntimeError(
            "R10b coverage failed (missing=%d extra=%d)"
            % (len(missing), len(residual)))
    t_split = time.monotonic() - t0
    lib = ensure_lib_cached(cc.split()[0], os.path.abspath(lib_dir or work),
                            None)
    results, wall, worst, ok = compile_shards(
        cc.split()[0], shard_paths, shards_dir, [rdir, tu_dir],
        list(defines), jobs, opt)
    if not ok:
        bad = sorted(os.path.basename(s) for s, _o, _d, p in results
                     if p.returncode != 0)
        raise RuntimeError("shard compile failed: %s" % ", ".join(bad))
    t1 = time.monotonic()
    link_argv = [cc.split()[0], "-s", "-o", os.path.abspath(out_exe)] \
        + [obj for _src, obj, _dt, _p in sorted(results)] \
        + [lib] + (["-lws2_32", "-Wl,--stack,16777216"] if os.name == "nt" else [])
    proc = subprocess.run(link_argv, cwd=ROOT, capture_output=True,
                          text=True, errors="replace")
    t_link = time.monotonic() - t1
    if proc.returncode != 0:
        tail = ((proc.stdout or "") + (proc.stderr or "")).strip()
        raise RuntimeError("shard link failed (rc=%d): %s"
                           % (proc.returncode,
                              "\n".join(tail.splitlines()[-5:])))
    say("shard build %s: split %.1fs + compile wall %.1fs "
        "(slowest %.1fs) + link %.1fs -> %s"
        % (tag, t_split, wall, worst, t_link, out_exe))
    return {"split": t_split, "wall": wall, "worst": worst, "link": t_link}


def emit_with(compiler, work, cc, tag):
    tmp = os.path.join(work, "emit_" + tag)
    os.makedirs(tmp, exist_ok=True)
    snap = os.path.join(work, "emit_%s.c" % tag)
    orb_build(os.path.abspath(compiler),
                             "emit_%s.exe" % tag, tmp, cc, snap)
    return snap


def run_self_test(cc):
    checks, passed = [], 0

    def check(name, cond, detail=""):
        nonlocal passed
        checks.append((name, bool(cond), detail))
        if cond:
            passed += 1
            print("  ok    %s" % name)
        else:
            print("  WRONG %s %s" % (name, detail[:200]))

    work = tempfile.mkdtemp(prefix="shard_selfhost_selftest_")
    try:
        tu = os.path.join(work, "synth.c")
        synth = [
            '#define ORBIT_CUSTOM_ROUTER',
            '#include "socket_compat.h"',
            '#include "runtime.h"',
            '',
            'static inline int synth_helper(int x) {',
            '    return x + 1;',
            '}',
            '',
            'static int synth_color(void) {',
            '    return 1;',
            '}',
            '',
            'OrbitArena* arena = NULL;',
            'int synth_first(int a);',
            '',
            'int synth_first(int a) {',
            '    goto done;',
            'done:;',
            '    return synth_helper(a);',
            '}',
            '',
            '#ifdef ORBIT_WITH_NET',
            'int synth_net(int q) {',
            '    return q * 2;',
            '}',
            '#endif',
            '',
            'int main(int argc, char* argv[]) {',
            '    (void)argc; (void)argv;',
            '    orbit_string out = orbit_os_exec_selfhost("echo exec-ok");',
            '    return orbit_string_indexOf(out, "exec-ok") >= 0 ? 0 : 3;',
            '}',
        ]
        with open(tu, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(synth) + "\n")
        hdr = os.path.join(work, "synth.h")
        with open(hdr, "w", encoding="utf-8", newline="\n") as fh:
            fh.write('#ifndef SYNTH_H\n#define SYNTH_H\n'
                     '#define ORBIT_SHARD_COMMON_H\n'
                     '#include "runtime.h"\n'
                     'static inline int synth_helper(int x) {\n'
                     '    return x + 1;\n'
                     '}\n'
                     'int synth_first(int a);\n#endif\n')

        # 1. E1 partition of the synthetic TU.
        part = split_tu(tu, hdr, 2)
        check("e1 split parses 5 bodies",
              len(part["bodies"]) == 5,
              "got %d" % len(part["bodies"]))
        sd = os.path.join(work, "sh")
        _nl = "\n"
        paths, _tsv = write_shards(part, "synth", sd, _nl, hdr)
        missing, residual = verify_shard_coverage(part, sd, "synth")
        check("e1 coverage missing=0 extra=0",
              not missing and not residual,
              "missing=%s residual=%s" % (missing[:3], residual[:3]))

        # 2. Without the header there is no split (E1 is the only mode).
        try:
            split_tu(tu, None, 2)
            check("missing header is refused", False, "accepted")
        except ValueError as exc:
            check("missing header is refused",
                  "E1 header" in str(exc), str(exc)[:200])

        # 3. The R4 precondition can fire (top-level #else names its line).
        bad = os.path.join(work, "bad.c")
        with open(bad, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("int f(void) {\n    return 1;\n}\n"
                     "#ifdef X\nint g(void);\n#else\nint h(void);\n#endif\n"
                     "int f2(void) {\n    return 2;\n}\n")
        try:
            split_tu(bad, hdr, 2)
            check("top-level #else is refused", False, "accepted")
        except ValueError as exc:
            check("top-level #else is refused",
                  "R4" in str(exc), str(exc)[:200])

        # 4. A shard that does not compile is reported (the gcc path can
        # fail, not just succeed).
        broken = os.path.join(work, "broken.c")
        with open(broken, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("int main(void) { return this is not c; }\n")
        proc = subprocess.run([cc, "-O0", "-c", "-o",
                               os.path.join(work, "broken.o"), broken],
                              capture_output=True, text=True)
        check("gcc rejects bad C (rc!=0)", proc.returncode != 0,
              "rc=%d" % proc.returncode)

        # 5. The synthetic E1 shards compile with the real flags (the
        # header travels from the TU dir, as in a real sharded build).
        inc = [DEFAULT_RUNTIME, work]
        res, _wall, _worst, ok = compile_shards(
            cc, paths, os.path.join(work, "b"), inc, [], 2)
        check("synthetic shards compile -c", ok,
              "; ".join(os.path.basename(s) for s, _o, _d, p in res
                        if p.returncode != 0))

        # 6. A shard-linked binary can exec, and the echoed token proves the
        # real implementation ran: the stub returns "", so the token cannot
        # come back. The archive link happens through ensure_lib_cached, so
        # this is the one check that guards ORBIT_WITH_EXEC in the bootstrap
        # archive -- without it the fixed-point compiler it links reports
        # success without producing a binary (ERRORS-1's symptom, re-entered
        # through this lane).
        exe = os.path.join(work, "synth_exe.exe"
                           if os.name == "nt" else "synth_exe")
        try:
            shard_build(cc, tu, hdr, exe, work, tag="selftest", jobs=2)
            proc = subprocess.run([exe], capture_output=True, text=True)
            check("shard-linked binary can exec", proc.returncode == 0,
                  "rc=%d stdout=%r stderr=%r"
                  % (proc.returncode, proc.stdout[:60], proc.stderr[:60]))
        except (ValueError, RuntimeError, OSError) as exc:
            check("shard-linked binary can exec", False, str(exc)[:200])
    finally:
        shutil.rmtree(work, ignore_errors=True)

    out.finish("shard-selfhost self-test", passed, len(checks))
    return 0 if passed == len(checks) else 1


def cmd_shard(args) -> int:
    out.set_quiet(args.quiet)

    if args.self_test:
        cc = args.cc or os.environ.get("ORBIT_CC") or "gcc"
        return run_self_test(cc)

    cc = args.cc or os.environ.get("ORBIT_CC") or "gcc"
    if not shutil.which(cc.split()[0]):
        return fail("no C compiler %r on PATH" % cc, 5)
    if args.jobs is None or args.jobs < 1:
        return fail("--jobs must be >= 1", 5)
    if args.shards is None or args.shards < 1:
        return fail("--shards must be >= 1", 5)

    work = tempfile.mkdtemp(prefix="shard_selfhost_")
    if not args.keep:
        import atexit
        atexit.register(lambda: shutil.rmtree(work, ignore_errors=True))
    for var in ("TEMP", "TMP", "TMPDIR"):
        os.environ[var] = work

    if args.emit_with:
        comp = os.path.abspath(args.emit_with)
        if not os.path.isfile(comp):
            return fail("--emit-with %s does not exist" % args.emit_with, 5)
        out.say("emitting the TU with %s ..." % args.emit_with)
        try:
            args.tu = emit_with(comp, work, cc, "verify")
        except SystemExit as exc:
            return fail("--emit-with %s did not emit (rc=%s)"
                        % (args.emit_with, exc), 4)
        args.header = None
        out.say("emitted: %s (%d bytes)"
                % (os.path.basename(args.tu), os.path.getsize(args.tu)))

    if not os.path.isfile(args.tu):
        return fail("--tu %s does not exist" % args.tu, 5)
    tu_abs = os.path.abspath(args.tu)
    tu_dir, tu_file = os.path.split(tu_abs)
    base = tu_file[:-2] if tu_file.endswith(".c") else tu_file
    if args.name:
        base = args.name
    header = args.header
    if header is None:
        cand = os.path.join(tu_dir, base + ".h")
        header = cand if os.path.isfile(cand) else None
    if header is None:
        return fail("no E1 header for %s: shard builds need the "
                    "compiler-emitted %s (build the TU with the current "
                    "compiler so it exists), else use the unity build" % (tu_abs, base + ".h"), 5)
    out.say("shard-selfhost (E1): %s -> %d shards (jobs=%d, cc=%s)"
            % (tu_abs, args.shards, args.jobs, cc))

    t0 = time.monotonic()
    try:
        part = split_tu(tu_abs, header, args.shards)
    except ValueError as exc:
        return fail(str(exc), 1)
    shards_dir = os.path.abspath(args.shards_dir) if args.shards_dir \
        else os.path.join(work, "shards")
    if args.fresh:
        shutil.rmtree(shards_dir, ignore_errors=True)
    _raw, _lines, newline = read_tu(tu_abs)
    try:
        shard_paths, tsv = write_shards(part, base, shards_dir, newline,
                                        header)
    except OSError as exc:
        return fail("cannot write shards: %s" % exc, 5)
    missing, residual = verify_shard_coverage(part, shards_dir, base)
    if missing or residual:
        detail = "missing=%d extra=%d" % (len(missing), len(residual))
        for line in (missing[:5] + residual[:5]):
            print("  NOT-COVERED: %s" % line[:120])
        return fail("R10b coverage failed (%s)" % detail, 1)
    t_split = time.monotonic() - t0
    dropped = sorted(part["header_dropped"])
    out.say("split %.1fs: %d bodies (%d header-owned), %s, "
            "R10a CAT IDENTICAL, R10b missing=0 extra=0"
            % (t_split, len(part["bodies"]), len(dropped), tsv))
    # Hash binding for reuse, written only for a split that passed R10a/b: the
    # header is the one artifact only a compiler can make, so record which C
    # bytes it came with. A consumer (dev.py's T3) reuses this header and skips
    # the emission only when the TU's hash still matches the canonical's AND
    # the header still hashes to this record. The split itself is re-run and
    # re-checked downstream either way.
    bind = os.path.join(shards_dir, base + ".header.json")
    with open(bind, "w", encoding="utf-8") as fh:
        json.dump({"tu_sha256": sha_file(tu_abs),
                   "header_sha256": sha_file(header)}, fh, indent=1)
        fh.write("\n")

    if args.no_build:
        out.finish("shard-selfhost", 2, 2,
                   extra="split-only E1 (%d shards)" % args.shards)
        return 0

    try:
        lib = ensure_lib(cc.split()[0], work, args.lib)
    except ValueError as exc:
        return fail(str(exc), 5)
    inc_dirs = [args.runtime_dir, tu_dir]
    results, wall, worst, ok = compile_shards(
        cc.split()[0], shard_paths, work, inc_dirs, args.define, args.jobs)
    out.say("shard compile: wall %.1fs, slowest TU %.1fs, all-ok=%s"
            % (wall, worst, ok))
    if not ok:
        return fail("a shard did not compile (see shard name(s) above)", 2)

    out_bin = os.path.abspath(args.out) if args.out else os.path.join(
        shards_dir, base + ".linked" + (".exe" if os.name == "nt" else ""))
    os.makedirs(os.path.dirname(out_bin) or ".", exist_ok=True)
    t1 = time.monotonic()
    link_argv = [cc.split()[0], "-s", "-o", out_bin] \
        + [obj for _src, obj, _dt, _p in sorted(results)] \
        + [lib] + (["-lws2_32", "-Wl,--stack,16777216"] if os.name == "nt" else [])
    proc = subprocess.run(link_argv, cwd=ROOT, capture_output=True,
                          text=True, errors="replace")
    t_link = time.monotonic() - t1
    if proc.returncode != 0:
        tail = ((proc.stdout or "") + (proc.stderr or "")).strip()
        print("\n".join(tail.splitlines()[-25:]))
        return fail("link failed (rc=%d)" % proc.returncode, 3)
    out.say("link %.1fs -> %s" % (t_link, out_bin))

    if not args.verify:
        out.finish("shard-selfhost", 3, 3,
                   extra="split+compile+link E1, no emission check "
                         "(--verify off)")
        return 0
    if args.reference is None and args.expect_sha is None:
        return fail("--verify needs --reference or --expect-sha", 5)
    t2 = time.monotonic()
    try:
        got_c = emit_with(out_bin, work, cc.split()[0], "shard")
    except SystemExit as exc:
        return fail("the linked binary did not emit (rc=%s)" % exc, 4)
    got_sha = sha_file(got_c)
    if args.reference is not None:
        if not os.path.isfile(args.reference):
            return fail("--reference %s does not exist" % args.reference, 5)
        try:
            ref_c = emit_with(args.reference, work, cc.split()[0], "ref")
        except SystemExit as exc:
            return fail("the reference binary did not emit (rc=%s)" % exc,
                        4)
        want_sha = sha_file(ref_c)
    else:
        want_sha = args.expect_sha.lower()
    t_emit = time.monotonic() - t2
    match = got_sha.lower() == want_sha.lower()
    out.say("emission check %.1fs: shardlinked=%s reference=%s"
            % (t_emit, got_sha[:16], want_sha[:16]))
    if not match:
        return fail("R10c emission SHA differs (linked=%s reference=%s)"
                    % (got_sha, want_sha), 4)
    out.finish("shard-selfhost", 4, 4,
               extra="E1 split+%d shards+link+emission MATCH %s"
                     % (args.shards, got_sha[:12]))
    return 0


# ---- from scripts/promote_diff.py ----
# Show what actually changed in the canonical C, instead of 20 000 lines.
#
# `compiler/selfhost/stage3.exe.c` is regenerated whole by `scripts/trust.py build --promote`, and it renumbers every register as it goes, so the diff of a real
# change is mostly churn. Measured over four commits that changed both source and
# canonical: 23 source lines became 24 286 lines of C, 34 became 1 612, 44 became
# 4 674, and 310 became 21 004. 37 of the last 60 commits touch it at all.
#
# So the file's diff is not a reviewable artifact and never was. AGENTS.md already
# says not to read it and to review the `.orb` diff plus the commit's evidence
# block instead -- which leaves the reviewer trusting that nothing unexpected
# happened in the generated C. This closes that gap: it diffs the canonical
# against `HEAD` with the generated-name numbering flattened, and reports what a
# person can actually check.
#
# Normalisation is two substitutions and no more:
#
#     r_1234     -> r
#     label_567  -> label
#
# Measured on the canonical of 2026-11-02 (7,198,152 bytes): 204,011 `r_<digits>`
# and 27,821 `label_<digits>`. A third generated family exists and is deliberately
# left alone -- `<name>__s<digits>`, the static slots a hoisted constant gets, 941
# occurrences. Flattening it would make two different slots print alike, so a use
# that moved from one hoisted string to another would normalise away, and a tool
# that hides that change is worse than one that over-reports. The cost is honest
# and named here: `o_lowerStatement` growing by one arm renumbers those slots
# across the file, and today that put 11 untouched `o_doctor*` functions in the
# function list of a `promote-diff` run.
#
# Widening the pattern to any `name_<digits>` would look more general and would be
# wrong for the same reason: it would flatten a hand-written constant into an
# anonymous one.
#
# What it prints:
#
#   * the raw line delta, which is the number that makes people give up;
#   * the same diff after normalisation, which is the number that means something;
#   * the number of hunks;
#   * the C functions each hunk lands in, so a change can be named rather than
#     scanned.
#
# `--expect-none` turns "something changed semantically" into a non-zero exit,
# which is what a promote-and-then-think tool wants: it is asking whether this
# commit should have touched the canonical at all.
#
# Run it after `make promote`, before committing: the worktree holds the new
# canonical and `HEAD` still holds the old one.
#!/usr/bin/env python3


PD_ROOT = pathlib.Path(__file__).resolve().parent.parent
CANONICAL = "compiler/selfhost/stage3.exe.c"

# The two generated-name families, and nothing else. See the module docstring.
GENERATED = re.compile(r"\b(r|label)_[0-9]+\b")
DEFINITION = re.compile(r"^[A-Za-z_][\w \*]*?\b([A-Za-z_]\w*)\s*\(")


def normalize(text: str) -> str:
    """Flatten generated register and label numbering.

    One substitution per line, not a token pass: it is a diff to read, not a
    parser, and the file has exactly two families of generated names.
    """
    return GENERATED.sub(lambda m: m.group(1), text)


def load(paths) -> tuple:
    """(old, new) canonical text. Old comes from HEAD, new from the worktree."""
    try:
        # The canonical holds UTF-8 glyphs, so both sides decode as UTF-8. The
        # locale default is cp1252 on Windows and refuses the file outright.
        old = subprocess.run(
            ["git", "-C", str(PD_ROOT), "show", f"HEAD:{CANONICAL}"],
            capture_output=True, check=True).stdout.decode("utf-8", "replace")
    except subprocess.CalledProcessError:
        print(f"Failed: {CANONICAL} is not in HEAD. There is no previous "
              f"version to compare against.", file=sys.stderr)
        raise SystemExit(2)
    new = (PD_ROOT / CANONICAL).read_text(encoding="utf-8", errors="replace")
    return old, new


def enclosing(anchor: list, index: int) -> str:
    """The C function whose body contains line `index`."""
    for i in range(index, -1, -1):
        m = DEFINITION.match(anchor[i])
        if m:
            return m.group(1)
    return "<file scope>"


def diff_report(old: str, new: str) -> dict:
    raw = list(difflib.unified_diff(old.split("\n"), new.split("\n"), n=0))
    norm = list(difflib.unified_diff(normalize(old).split("\n"),
                                     normalize(new).split("\n"), n=0))

    def counts(lines):
        added = sum(1 for l in lines if l.startswith("+") and not l.startswith("+++"))
        removed = sum(1 for l in lines if l.startswith("-") and not l.startswith("---"))
        hunks = sum(1 for l in lines if l.startswith("@@"))
        return added, removed, hunks

    raw_add, raw_del, _ = counts(raw)
    add, rem, hunks = counts(norm)

    # Which functions the normalised changes land in. Attributed against the new
    # file, because a deleted function has no line left to attribute to and a
    # name for it is still worth printing. New-file line numbers come from the
    # hunk headers, not from the diff output index (those are different
    # sequences; using the diff index misattributes every hunk past the
    # first).
    functions = []
    new_lines = new.split("\n")
    new_ln = 0
    for line in norm:
        m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
        if m:
            new_ln = int(m.group(1))
            continue
        if line.startswith("+") and not line.startswith("+++"):
            fn = enclosing(new_lines, min(new_ln, len(new_lines)) - 1)
            functions.append(fn)
            new_ln += 1
        elif line.startswith("-") and not line.startswith("---"):
            fn = enclosing(new_lines, min(new_ln, len(new_lines)) - 1)
            functions.append(fn)
        elif line.startswith(" ") or line in ("", "\n"):
            new_ln += 1

    return {
        "raw_added": raw_add, "raw_removed": raw_del,
        "added": add, "removed": rem, "hunks": hunks,
        "functions": sorted(set(functions)),
    }


def self_test_promote_diff() -> int:
    """Assert the normaliser flattens numbering and nothing else."""
    a = "  r_14 = 5;\n  goto label_9;\n  orbit_int_to_string(r_3);\n"
    b = "  r_77 = 5;\n  goto label_102;\n  orbit_int_to_string(r_1);\n"
    if normalize(a) != normalize(b):
        print("self-test FAILED: renumbering registers and labels did not "
              "normalise to the same text")
        return 1
    if "orbit_int_to_string" not in normalize(a):
        print("self-test FAILED: normalisation destroyed a real identifier")
        return 1

    # A real change must SURVIVE normalisation, or the tool reports zero for a
    # commit that changed the compiler's behaviour. That is the failure that
    # would make it worse than reading the diff.
    c = "  r_1 = 5;\n  orbit_int_to_string(r_1);\n"
    d = "  r_1 = 5;\n  orbit_int_to_string(r_1, 2);\n"
    if normalize(c) == normalize(d):
        print("self-test FAILED: a real code change normalised away, which "
              "would report 'nothing changed' for a commit that did")
        return 1

    # The slot family must SURVIVE, because flattening it would make a use that
    # moved between two hoisted constants look like nothing at all.
    e = "  use_slot(r__s7);"
    f = "  use_slot(r__s9);"
    if normalize(e) == normalize(f):
        print("self-test FAILED: static-slot numbering was flattened, which "
              "would hide a use moving from one hoisted constant to another")
        return 1

    # And a genuinely identical pair must report nothing.
    rep = diff_report(normalize(a), normalize(a))
    if rep["added"] or rep["removed"]:
        print("self-test FAILED: identical input produced a non-empty diff")
        return 1

    print("Finished promote-diff self-test: register and label renumbering "
          "flattens, slot numbering and real changes survive, identical input "
          "is empty.")
    return 0


def cmd_promote_diff(args) -> int:

    if args.self_test:
        return self_test_promote_diff()

    old, new = load(args)
    r = diff_report(old, new)

    raw_total = r["raw_added"] + r["raw_removed"]
    norm_total = r["added"] + r["removed"]
    print(f"{CANONICAL}")
    print(f"  raw diff        {r['raw_added']:+6d} -{r['raw_removed']:<6d} "
          f"= {raw_total} lines")
    print(f"  after renumber  {r['added']:+6d} -{r['removed']:<6d} "
          f"= {norm_total} lines across {r['hunks']} hunk(s)")
    if raw_total:
        share = 100.0 * norm_total / raw_total
        print(f"  so {share:.1f}% of the raw diff survives normalisation; the "
              f"rest is register and label renumbering")

    if not norm_total:
        print("\nNothing changed beyond renumbering. The canonical was "
              "regenerated but the compiler behaves identically.")
        if args.expect_none:
            print("Failed: --expect-none and the canonical changed.")
            return 1
        return 0

    print(f"\nFunctions touched ({len(r['functions'])}):")
    for fn in r["functions"]:
        print(f"  {fn}")

    if args.expect_none:
        print(f"\nFailed: --expect-none and {norm_total} lines changed.")
        return 1
    return 0


# ---- from scripts/amalgamate.py ----
# Amalgamate the self-hosted Orbit compiler into a single self-contained C file.
#
# Bootstrap seed flow: produce `dist/orbit_bootstrap.c` by inlining every
# project-relative `#include "..."` reachable from `compiler/selfhost/stage3.exe.c`.
# System includes (`#include <...>`) are left untouched.
#
# Strategy: inline *every* occurrence of a project include, wrapping each file in
# its own include guard named after its relative path.  Because the guards are per
# file, an occurrence inside an `#ifdef` branch that is inactive at compile time
# does not mask a later unconditional occurrence, and two active occurrences of the
# same file collapse to one compiled copy.  This mirrors the preprocessor's own
# include-guard semantics without depending on the runtime files having guards.
#
# Usage:
#     python3 scripts/trust.py amalgamate [--entry compiler/selfhost/stage3.exe.c] [--out dist/orbit_bootstrap.c]
#!/usr/bin/env python3


INCLUDE_RE = re.compile(r'^(.*#\s*include\s*"([^"]+)"\s*)$', re.M)
MARKER = r'/* seed: #include "{name}" inlined below */'


def guard_for(relpath: str) -> str:
    ident = re.sub(r'[^A-Za-z0-9]', '_', relpath).strip('_').upper()
    return f"ORBIT_SEED_FILE_{ident}"


def amalgamate(entry_path: str, runtime_root: str, out_path: str) -> None:
    def resolve(from_dir: str, name: str) -> str:
        cand = os.path.normpath(os.path.join(from_dir, name))
        if os.path.isfile(cand):
            return cand
        fallback = os.path.normpath(os.path.join(runtime_root, name))
        if os.path.isfile(fallback):
            return fallback
        raise FileNotFoundError(f"cannot resolve include {name!r} from {from_dir!r}")

    def include(name: str, from_path: str, active: tuple) -> str:
        # A file that includes the header which includes it (runtime/gen/*.c
        # includes runtime.h) is already open: the include guard makes the
        # preprocessor skip it, so the text is left out here too.
        target = os.path.normpath(resolve(os.path.dirname(from_path), name))
        if target in active:
            return ""
        return inline(target, active)

    def inline(path: str, active: tuple = ()) -> str:
        path = os.path.normpath(path)
        active = active + (path,)
        with open(path, encoding="utf-8", errors="replace") as f:
            content = f.read()
        rel = os.path.relpath(path, runtime_root)
        content = INCLUDE_RE.sub(
            lambda m: MARKER.format(name=m.group(2)) + "\n" + include(m.group(2), path, active),
            content,
        )
        guard = guard_for(rel)
        return (
            f"\n/* BEGIN SEED FILE: {rel} */\n"
            f"#ifndef {guard}\n#define {guard}\n"
            f"{content}\n"
            f"#endif /* {guard} */\n"
            f"/* END SEED FILE: {rel} */\n"
        )

    with open(entry_path, encoding="utf-8", errors="replace") as f:
        main = f.read()
    entry_dir = os.path.dirname(os.path.abspath(entry_path))
    main = INCLUDE_RE.sub(
        lambda m: MARKER.format(name=m.group(2)) + "\n" + inline(resolve(entry_dir, m.group(2))),
        main,
    )
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(main)


def cmd_amalgamate(args) -> int:
    entry = (os.path.normpath(args.entry) if args.entry
             else os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c"))
    runtime_root = os.path.join(ROOT, "runtime")
    out_path = (os.path.normpath(args.out) if args.out
                else os.path.join(ROOT, "dist", "orbit_bootstrap.c"))
    amalgamate(entry, runtime_root, out_path)
    size = os.path.getsize(out_path)
    print(f"Wrote {out_path} ({size / 1e6:.1f} MB)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="trust.py",
        description="The root of trust: the bootstrap chain, its verifier, the shard driver, the canonical diff and the amalgamation.",
        epilog="Each subcommand takes the flags its own script had before the merge; run `%(prog)s <subcommand> --help`.")
    sub = ap.add_subparsers(dest="command", metavar="SUBCOMMAND", required=True)

    sp = sub.add_parser('build', help='self-hosted compiler bootstrap', description='self-hosted compiler bootstrap')
    sp.add_argument("--cc", default=None, help="C compiler (default: ORBIT_CC/gcc/clang/cc)")
    sp.add_argument("--work", default=None, help="work directory (default: temp)")
    sp.add_argument("--keep", action="store_true", help="keep the work directory")
    sp.add_argument("--check-stale", action="store_true",
                    help="fail if the converged C differs from the committed canonical")
    sp.add_argument("--promote", action="store_true",
                    help="replace the committed canonical C with the converged fixed point")
    sp.add_argument("--out", default=None, metavar="PATH",
                    help="copy the converged fixed-point compiler binary to PATH")
    sp.add_argument("--shared-work", default=None, metavar="DIR",
                    help="write converged snapshots + hashes.json under DIR")
    sp.add_argument("--low-mem", dest="low_mem", action="store_true", default=None,
                    help="force the low-memory C profile (-g0, no unwind tables)")
    sp.add_argument("--no-low-mem", dest="low_mem", action="store_false",
                    help="disable the low-memory C profile")
    out.add_quiet(sp)

    sp = sub.add_parser('verify', help='Verify the C bootstrap fixed point', description='Verify the C bootstrap fixed point')
    sp.add_argument("--release", action="store_true",
                    help="enforce the published fixed-point C contract (PUBLISHED_C)")
    sp.add_argument("--emit-fixed-point", default=None, metavar="PATH", help="copy the seed-chain fixed-point compiler (chain3) to PATH")
    sp.add_argument("--work", default=None, help="work directory (default: temp)")
    sp.add_argument("--cc", default=None, help="C compiler for the seed (default: auto-detect)")
    sp.add_argument("--refresh", action="store_true", help="also refresh dist/orbit_bootstrap.c and dist/orbit_seed")
    sp.add_argument("--keep", action="store_true", help="keep the work directory")
    sp.add_argument("--shared-work", default=None, metavar="DIR",
                    help="write converged snapshots + hashes.json under DIR")
    sp.add_argument("--shards-dir", default=None, metavar="DIR",
                    help="verify cat(shards in order) == canonical (+ PUBLISHED_C), then run the inherited chain")
    sp.add_argument("--manifest", default=None, metavar="PATH",
                    help="TSV manifest (shard func defstart end, TU order) ordering the --shards-dir concatenation")
    sp.add_argument("--low-mem", dest="low_mem", action="store_true", default=None,
                    help="force the low-memory C profile (-g0, no unwind tables)")
    sp.add_argument("--no-low-mem", dest="low_mem", action="store_false",
                    help="disable the low-memory C profile")
    out.add_quiet(sp)

    sp = sub.add_parser('shard', help='sharded build driver (E2)', description='sharded build driver (E2)')
    sp.add_argument("--tu", default=DEFAULT_TU,
                    help="single-TU C file to shard")
    sp.add_argument("--header", default=None,
                    help="compiler-emitted <base>.h (required); default: "
                         "<tu-dir>/<base>.h when it exists")
    sp.add_argument("--emit-with", default=None, metavar="COMPILER",
                    help="emit the TU (and its E1 header) with this "
                         "compiler before splitting; --tu/--header are "
                         "then ignored")
    sp.add_argument("--fresh", action="store_true",
                    help="clear --shards-dir before writing, so the bundle "
                         "holds only this run's shards")
    sp.add_argument("--name", default=None, metavar="BASE",
                    help="name for the shard files, TSV and header copy "
                         "(default: the TU's basename). Pin it when one bundle "
                         "is written from differently named TUs, so a verifier "
                         "can keep pointing at one manifest")
    sp.add_argument("--shards-dir", default=None,
                    help="where shards + TSV go (default: own temp dir)")
    sp.add_argument("--cc", default=None)
    sp.add_argument("--jobs", type=int, default=8)
    sp.add_argument("--shards", type=int, default=N_SHARDS)
    sp.add_argument("--out", default=None, help="linked binary path")
    sp.add_argument("--lib", default=None,
                    help="prebuilt libruntime_net.a (default: build it "
                         "into the run's own temp dir)")
    sp.add_argument("--define", action="append", default=[],
                    help="extra -D for shards (repeatable; R9: shards "
                         "inherit the TU flag set)")
    sp.add_argument("--runtime-dir", default=DEFAULT_RUNTIME)
    sp.add_argument("--reference", default=None,
                    help="reference fp binary for the R10c emission check")
    sp.add_argument("--expect-sha", default=None,
                    help="expected emission SHA256 instead of --reference")
    sp.add_argument("--verify", action="store_true",
                    help="run the R10c auto-emission SHA check")
    sp.add_argument("--no-build", action="store_true",
                    help="split only: no gcc, no link, no emission check")
    sp.add_argument("--keep", action="store_true",
                    help="keep the run's temp dir")
    sp.add_argument("--self-test", action="store_true")
    out.add_quiet(sp)

    sp = sub.add_parser('promote-diff', help='Show what actually changed in the canonical C, instead of 20 000 lines', description='Show what actually changed in the canonical C, instead of 20 000 lines')
    sp.add_argument("--self-test", action="store_true")
    sp.add_argument("--expect-none", action="store_true",
                    help="exit non-zero if anything changed after normalisation")

    sp = sub.add_parser('amalgamate', help='Amalgamate the self-hosted Orbit compiler into a single self-contained C file', description='Amalgamate the self-hosted Orbit compiler into a single self-contained C file')
    sp.add_argument("--entry", default=None,
                    help="C file to inline from (default: the canonical)")
    sp.add_argument("--out", default=None,
                    help="output path (default: dist/orbit_bootstrap.c)")

    args = ap.parse_args()
    commands = {
        "build": cmd_build,
        "verify": cmd_verify,
        "shard": cmd_shard,
        "promote-diff": cmd_promote_diff,
        "amalgamate": cmd_amalgamate,
    }
    return commands[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
