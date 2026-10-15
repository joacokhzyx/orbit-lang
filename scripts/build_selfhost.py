#!/usr/bin/env python3
"""Rebuild the self-hosted Orbit compiler from the committed canonical C.

The root of trust is the committed canonical C source
(``compiler/selfhost/stage3.exe.c``). Any conforming C compiler can turn it
into a working Orbit compiler; that compiler rebuilds the sources from
``compiler/main.orb`` and the loop is repeated until the emitted C reaches a
new fixed point. No toolchain beyond a C compiler is involved at any point.

Modes:
  default        Rebuild from the committed canonical C and verify that the
                 current ``compiler/*.orb`` sources converge to a fixed point.
  --check-stale  Additionally require the converged C to equal the committed
                 canonical byte-for-byte (CI mode: fails when the canonical
                 was not refreshed after a compiler change).
  --promote      Replace the committed canonical with the newly converged C
                 and update PUBLISHED_C in scripts/verify_seed.py. Use after
                 an intentional compiler change.
  --out PATH     Copy the converged fixed-point compiler binary to PATH.
  --shared-work DIR  After converging, write chain3.c / chain3.exe / seed.c /
                     hashes.json under DIR (see SHARED_* below; without the
                     flag nothing is written).

Usage:
    python scripts/build_selfhost.py [--cc CC] [--work DIR] [--keep]
                                     [--check-stale] [--promote] [--out PATH]
                                     [--shared-work DIR]

Exit code 0 iff the chain converged (and, with --check-stale, matches the
committed canonical).
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
import orbit_ccache

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANONICAL_C = os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c")
MAIN_ORB = os.path.join("compiler", "main.orb")
VERIFY_SEED = os.path.join(ROOT, "scripts", "verify_seed.py")

# -O0 keeps peak memory low: these builds run once per gate and speed is
# irrelevant, but low-RAM machines (4 GB) were OOMing inside LLVM/lld during
# -O2 links. The compiler's own internal invocations (pipeline.orb) already
# use -O0.
# -O0 keeps peak memory low on 4 GB machines; -DORBIT_WITH_EXEC enables the
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
SUPPRESS_FLAGS = ["-O0", "-DORBIT_WITH_EXEC"] + (
    ["-Wall"] if os.environ.get("ORBIT_BOOTSTRAP_WARNINGS", "").strip() not in ("", "0") else [])

# Low-memory profile: drop unwind tables and debug info so the multi-MB
# compiler TU links with less peak commit. GCC/Clang only; MSVC-style
# drivers (cl) do not accept these flags.
LOWMEM_C_FLAGS = ["-g0", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables"]
LOWMEM_AUTO_MB = 4096
MAX_ITERATIONS = 4
PLATFORM_LINK_FLAGS = ["-lws2_32"] if os.name == "nt" else []


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


def bootstrap_cc_middle(cc: str, low_mem: bool) -> list:
    """The unified middle of every bootstrap cc argv (Fase A, pieza F).

    build_selfhost.py and verify_seed.py both splice this in the same place --
    right after cc_cmd, before -I/-o/sources/link flags -- so identical inputs
    hash to one orbit_ccache entry no matter which script stored it first.
    Order is pinned: the cache key hashes argv tokens in order.
    """
    return [*cc_strip_flags(cc), *SUPPRESS_FLAGS,
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


def detect_cc() -> str:
    env_cc = os.environ.get("ORBIT_CC")
    if env_cc:
        return env_cc
    for cand in ("gcc", "clang", "cc"):
        if shutil.which(cand):
            return cand
    out.fail("Failed: no C compiler found; set ORBIT_CC (gcc/clang/cc).")
    raise SystemExit(2)


def run(argv, cwd=ROOT, env_extra=None, label=""):
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
    """Compile compiler/main.orb with `compiler`; snapshot the intermediate C.

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
    # (ORBIT_SHARD_BUILD=1) resolve it as the sibling <base>.h.
    inter_h = os.path.splitext(inter_c)[0] + ".h"
    if os.path.isfile(inter_h):
        shutil.copyfile(inter_h, os.path.splitext(snapshot_path)[0] + ".h")
    return snapshot_path


def update_published_c(new_hash: str) -> None:
    with open(VERIFY_SEED, "r", encoding="utf-8") as f:
        content = f.read()
    new_content, n = re.subn(
        r'PUBLISHED_C = "[0-9A-Fa-f]{64}"',
        f'PUBLISHED_C = "{new_hash.upper()}"',
        content,
    )
    if n != 1:
        print("Warning: could not update PUBLISHED_C in verify_seed.py", file=sys.stderr)
        return
    with open(VERIFY_SEED, "w", encoding="utf-8", newline="\n") as f:
        f.write(new_content)
    out.say(f"Updated PUBLISHED_C in verify_seed.py -> {new_hash.upper()}")


# Shared-work snapshots (Fase A, pieza F): after converging, both scripts can
# write these four paths under --shared-work DIR for the dev.py driver to
# consume without rerunning the chain -- check_stale as a byte comparison of
# chain3.c against the canonical, fp as a copy of the chain3 binary:
#
#   <dir>/chain3.c    converged fixed-point C
#   <dir>/chain3.exe  converged compiler binary (chain3, no suffix, off Windows)
#   <dir>/seed.c      seed-stage emitted C
#   <dir>/hashes.json {"canonical_sha":..,"seed_sha":..,"chain3_sha":..,"published":..}
#
# The three _sha values are lowercase hex of the bytes as written; published is
# PUBLISHED_C verbatim (uppercase): compare case-insensitively. Presence of
# hashes.json means THIS run converged; absence means it did not -- the writer
# deletes a stale manifest at startup and writes the manifest last
# (tmp+rename), so a failed run can never leave a fresh-looking manifest.
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
    """PUBLISHED_C verbatim from scripts/verify_seed.py (read-only)."""
    try:
        with open(VERIFY_SEED, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return ""
    m = re.search(r'PUBLISHED_C = "([0-9A-Fa-f]{64})"', text)
    return m.group(1).upper() if m else ""


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

    ORBIT_SHARD_BUILD=1 tries scripts/shard_selfhost.py on the emitted TU
    (its sibling <base>.h must exist) and falls back to the unity
    compile_cached on any failure. The cache is probed first: a unity hit
    is a file copy, cheaper than any sharding, so shards only run on a
    confident miss. Returns the compile_cached-style reused flag (False
    for a shard build). A shard-built compiler is behaviorally identical
    (R10c); the loop's own hash convergence below is the verdict, so a
    bad shard binary diverges loudly instead of passing quietly.
    """
    import shard_selfhost
    use_shards = shard_selfhost.shard_enabled()
    header = os.path.splitext(c_path)[0] + ".h"
    if use_shards and not os.path.isfile(header):
        out.say(f"note: shard build {tag} off (no sibling header "
                f"{os.path.basename(header)}); unity compile.")
        use_shards = False
    if use_shards and _unity_cache_hit(cc_cmd, iter_argv, iter_sources):
        use_shards = False
    if use_shards:
        try:
            shard_selfhost.shard_build(
                cc, c_path, header, next_exe, work, tag=tag,
                jobs=shard_selfhost.shard_jobs(),
                runtime_dir=os.path.join(ROOT, "runtime"),
                lib_dir=os.path.join(work, "shardlib"), log=out.say)
            out.say(f"shard-built {tag} (unity fallback skipped; "
                    f"no Windows branding stamp on this intermediate)")
            return False
        except Exception as exc:
            out.say(f"note: shard build {tag} failed ({exc}); "
                    f"falling back to the unity compile.")
    _, reused = orbit_ccache.compile_cached(cc_cmd, iter_argv, iter_sources,
                                            log=out.say)
    return reused


def main() -> int:
    ap = argparse.ArgumentParser(description="self-hosted compiler bootstrap")
    ap.add_argument("--cc", default=None, help="C compiler (default: ORBIT_CC/gcc/clang/cc)")
    ap.add_argument("--work", default=None, help="work directory (default: temp)")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    ap.add_argument("--check-stale", action="store_true",
                    help="fail if the converged C differs from the committed canonical")
    ap.add_argument("--promote", action="store_true",
                    help="replace the committed canonical C with the converged fixed point")
    ap.add_argument("--out", default=None, metavar="PATH",
                    help="copy the converged fixed-point compiler binary to PATH")
    ap.add_argument("--shared-work", default=None, metavar="DIR",
                    help="write converged snapshots + hashes.json under DIR")
    ap.add_argument("--low-mem", dest="low_mem", action="store_true", default=None,
                    help="force the low-memory C profile (-g0, no unwind tables)")
    ap.add_argument("--no-low-mem", dest="low_mem", action="store_false",
                    help="disable the low-memory C profile")
    out.add_quiet(ap)
    args = ap.parse_args()
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
    cc = args.cc or detect_cc()
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
    run([sys.executable, os.path.join(ROOT, "scripts", "amalgamate.py"),
         "--entry", CANONICAL_C, "--out", amal], label="amalgamate canonical")
    # Fixed -o basename shared with verify_seed.py: the ccache key hashes
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
        # Flags are bootstrap_cc_middle, shared with verify_seed.py (see seed).
        out.say(f"Building iter{i} compiler from its own C")
        iter_argv = [*cc_cmd, *bootstrap_cc_middle(cc, args.low_mem),
                     "-I", os.path.join(ROOT, "runtime"),
                     "-o", next_exe, c_i, *PLATFORM_LINK_FLAGS]
        iter_argv, iter_sources = orbit_ccache.windows_stamp(
            iter_argv, [c_i], work, "Orbit compiler", log=out.say)
        reused = compile_tu_exe(cc, cc_cmd, iter_argv, iter_sources, c_i,
                                next_exe, work, f"iter{i}")
        out.say(f"Iteration {i}: {h_i}"
                + ("  (fixed point)" if h_i == prev_c_hash else "")
                + ("  (cc from cache)" if reused else ""))
        if h_i == prev_c_hash:
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
        out.tip("refresh it with: python scripts/build_selfhost.py --promote")
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
    out.say("follow-up: python scripts/verify_seed.py --cc \"" + cc + "\"")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
