#!/usr/bin/env python3
"""Rebuild the self-hosted Orbit compiler WITHOUT any Zig dependency (SOVER-1).

The root of trust is the committed canonical C source
(``compiler/selfhost/stage3.exe.c``). Any conforming C compiler can turn it
into a working Orbit compiler; that compiler rebuilds the sources from
``compiler/main.orb`` and the loop is repeated until the emitted C reaches a
new fixed point. The Zig seed lineage is never invoked.

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

Usage:
    python scripts/build_selfhost.py [--cc CC] [--work DIR] [--keep]
                                     [--check-stale] [--promote] [--out PATH]

Exit code 0 iff the chain converged (and, with --check-stale, matches the
committed canonical).
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

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
SUPPRESS_FLAGS = ["-O0", "-w", "-Wno-int-conversion", "-Wno-incompatible-pointer-types", "-DORBIT_WITH_EXEC"]
MAX_ITERATIONS = 4


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
        print(f"[selfhost] WARNING: only ~{free_mb} MB commit available; LLVM/lld links of "
              "the compiler TU may OOM. Close applications or expect slower retried builds.")


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
    # Absolute last resort during the transition away from Zig: zig used purely
    # as a C toolchain (never to build or verify the self-hosted chain).
    if shutil.which("zig"):
        return "zig cc"
    print("[selfhost] FAIL: no C compiler found; set ORBIT_CC (gcc/clang/cc).")
    raise SystemExit(2)


def run(argv, cwd=ROOT, env_extra=None, label=""):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    print(f"[selfhost] {label or ' '.join(argv)}")
    proc = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, errors="replace")
    out = (proc.stdout or "") + (proc.stderr or "")
    if out.strip():
        print(out.rstrip())
    if proc.returncode != 0:
        # Emit as a GitHub error annotation: check-run annotations are public
        # API-readable even when job logs require authentication.
        tail = "\n".join(out.strip().splitlines()[-30:])
        payload = tail.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")[:3800]
        print(f"::error::[{label}] rc={proc.returncode} :: {payload}")
        raise SystemExit(2)


def orb_build(compiler, out_exe, work, cc, snapshot_path) -> str:
    """Compile compiler/main.orb with `compiler`; snapshot the intermediate C.

    The compiler's own final cc invocation is redundant here (we recompile the
    snapshot ourselves with known-good flags). If it fails -- e.g. because an
    older compiler bakes a stale runtime include path -- we continue as long
    as the C was emitted.
    """
    tmp = os.path.join(work, "tmp_build")
    os.makedirs(tmp, exist_ok=True)
    inter_c = os.path.join(tmp, "orbit_selfhost_build.c")
    if os.path.isfile(inter_c):
        os.remove(inter_c)
    env = dict(os.environ)
    env.update({"TEMP": tmp, "TMP": tmp, "ORBIT_CC": cc, "CC": cc})
    label = f"{os.path.basename(compiler)} build main.orb -> {out_exe}"
    print(f"[selfhost] {label}")
    proc = subprocess.run([compiler, "build", MAIN_ORB, "-o", os.path.join(work, out_exe)],
                          cwd=ROOT, env=env)
    if proc.returncode != 0:
        if not os.path.isfile(inter_c):
            print(f"[selfhost] FAILED ({proc.returncode}): {label} (no C emitted)")
            raise SystemExit(2)
        print(f"[selfhost] note: compiler exited {proc.returncode} but emitted C "
              "(stale baked-in flags?); continuing with our own cc invocation.")
    shutil.copyfile(inter_c, snapshot_path)
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
        print("[selfhost] WARN: could not update PUBLISHED_C in verify_seed.py")
        return
    with open(VERIFY_SEED, "w", encoding="utf-8", newline="\n") as f:
        f.write(new_content)
    print(f"[selfhost] updated PUBLISHED_C in verify_seed.py -> {new_hash.upper()}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Zig-free self-hosted compiler bootstrap")
    ap.add_argument("--cc", default=None, help="C compiler (default: ORBIT_CC/gcc/clang/cc)")
    ap.add_argument("--work", default=None, help="work directory (default: temp)")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    ap.add_argument("--check-stale", action="store_true",
                    help="fail if the converged C differs from the committed canonical")
    ap.add_argument("--promote", action="store_true",
                    help="replace the committed canonical C with the converged fixed point")
    ap.add_argument("--out", default=None, metavar="PATH",
                    help="copy the converged fixed-point compiler binary to PATH")
    args = ap.parse_args()

    if args.promote and args.check_stale:
        print("[selfhost] --promote and --check-stale are mutually exclusive.")
        return 1

    warn_low_memory()

    if not os.path.isfile(CANONICAL_C):
        print(f"[selfhost] FAIL: {CANONICAL_C} missing. It is the committed root of trust;")
        print("[selfhost] restore it from git or bootstrap once via the legacy Zig lineage.")
        return 1

    if args.work:
        work = os.path.abspath(args.work)
        os.makedirs(work, exist_ok=True)
    else:
        work = tempfile.mkdtemp(prefix="orbit_selfhost_")
    if not args.keep:
        import atexit
        atexit.register(lambda: shutil.rmtree(work, ignore_errors=True))

    exe = ".exe" if sys.platform == "win32" else ""
    cc = args.cc or detect_cc()
    cc_cmd = cc.split()
    h_canonical = sha256(CANONICAL_C)

    print(f"[selfhost] repo root:    {ROOT}")
    print(f"[selfhost] C compiler:   {cc}")
    print(f"[selfhost] canonical C:  {h_canonical}  ({os.path.getsize(CANONICAL_C)} bytes)")

    # Seed: canonical C -> amalgamate -> any C compiler -> working Orbit compiler.
    amal = os.path.join(work, "orbit_bootstrap.c")
    run([sys.executable, os.path.join(ROOT, "scripts", "amalgamate.py"),
         "--entry", CANONICAL_C, "--out", amal], label="amalgamate canonical")
    seed_exe = os.path.join(work, "seed" + exe)
    run([*cc_cmd, *SUPPRESS_FLAGS, "-o", seed_exe, amal], label="build seed from canonical C")

    # Iterate: current compiler builds the sources; repeat until C stabilises.
    prev_c_hash = None
    cur_exe = seed_exe
    converged_c = None
    final_exe = None
    for i in range(1, MAX_ITERATIONS + 1):
        c_i = orb_build(cur_exe, f"iter{i}" + exe, work, cc,
                        os.path.join(work, f"iter{i}.selfhost.c"))
        h_i = sha256(c_i)
        next_exe = os.path.join(work, f"iter{i}_exe" + exe)
        # Generated C is not amalgamated: it needs the runtime headers on the
        # include path (pipeline.orb does the same when building user programs).
        run([*cc_cmd, *SUPPRESS_FLAGS, "-I", os.path.join(ROOT, "runtime"),
             "-o", next_exe, c_i],
            label=f"build iter{i} compiler from its own C")
        print(f"[selfhost] iteration {i}: {h_i}"
              + ("  (fixed point)" if h_i == prev_c_hash else ""))
        if h_i == prev_c_hash:
            converged_c = c_i
            final_exe = next_exe
            break
        prev_c_hash = h_i
        cur_exe = next_exe
        final_exe = next_exe

    if converged_c is None:
        print(f"[selfhost] FAIL: no fixed point after {MAX_ITERATIONS} iterations "
              "(the chain oscillates or the compiler miscompiles its own source).")
        return 1

    h_final = sha256(converged_c)
    stale = h_final != h_canonical

    if args.promote:
        shutil.copyfile(converged_c, CANONICAL_C)
        print(f"[selfhost] PROMOTED new canonical C -> {CANONICAL_C}")
        print(f"[selfhost] old: {h_canonical}")
        print(f"[selfhost] new: {h_final}")
        update_published_c(h_final)
    elif args.check_stale and stale:
        print("[selfhost] FAIL: converged C != committed canonical (canonical is stale).")
        print(f"[selfhost] converged: {h_final}")
        print("[selfhost] refresh it with: python scripts/build_selfhost.py --promote")
        return 1
    elif stale:
        print("[selfhost] note: sources diverge from committed canonical "
              "(expected while hacking on the compiler; promote when ready).")

    if args.out:
        out_abs = os.path.abspath(args.out)
        os.makedirs(os.path.dirname(out_abs) or ".", exist_ok=True)
        shutil.copyfile(final_exe, out_abs)
        print(f"[selfhost] fixed-point compiler copied to: {out_abs}")

    print(f"\n[selfhost] OK: Zig-free bootstrap converged ({'matches canonical' if not stale else 'diverged from canonical'}).")
    print("[selfhost] follow-up: python scripts/verify_seed.py --cc \"" + cc + "\"")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
