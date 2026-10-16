#!/usr/bin/env python3
"""Verify the C bootstrap fixed point (the seed-verifier flow).

Reproduces the verification end to end in a hermetic work directory and
reports whether the compiler's reproducibility contract still holds:

  C fixed point    : the C emitted by the seed when it compiles
                     ``compiler/main.orb`` must be byte-identical to the
                     canonical ``compiler/selfhost/stage3.exe.c``, and so must
                     the C emitted by every later stage of the chain.
  binary fixed pt  : the seed chain (seed2 -> chain2 -> chain3) is additionally
                     compared byte for byte once the COFF link timestamps are
                     zeroed. This is toolchain-specific (linker, C compiler, PE
                     layout) and therefore informational for gcc and clang; the
                     reproducible cross-platform contract is the C source.

There is no second lineage to cross-check against. The committed canonical C
IS the root of trust, and ``scripts/build_selfhost.py --promote`` is the only
way to replace it after an intentional compiler change.

``--release`` enforces the published fixed-point C contract (``PUBLISHED_C``)
as a hard check against the self-hosted rebuild.

``--emit-fixed-point PATH`` copies the seed-chain fixed-point compiler
(``chain3``, byte-identical to ``seed2``/``chain2``) to PATH. That binary is
built entirely by the self-hosted seed chain: canonical C -> seed -> seed2 ->
chain2 -> chain3.

``--shared-work DIR`` writes the same snapshot layout as build_selfhost.py
--shared-work (chain3.c, the chain3 binary, seed.c, hashes.json) once the C
fixed point holds; the path contract (SHARED_*) is defined there, not here.
Without the flag nothing is written. When DIR already holds snapshots for
the current canonical, the three frontend rebuilds are skipped and the four
equality checks run on the snapshot bytes instead; a stale or unreadable dir
falls back to the full rebuild. The slow path (no flag) is untouched.

Exit code 0 iff every hard check passes.

Usage:
    python scripts/verify_seed.py [--release] [--emit-fixed-point PATH]
                                  [--work DIR] [--cc CC] [--refresh] [--keep]
                                  [--shared-work DIR] [--low-mem | --no-low-mem]
"""

import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
import orbit_ccache

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from build_selfhost import (warn_low_memory, bootstrap_cc_middle,
                                lowmem_cc_flags, resolve_low_mem,
                                claim_shared_work, write_shared_work,
                                SHARED_CHAIN_C, SHARED_SEED_C, SHARED_MANIFEST,
                                shared_chain_bin)
except Exception:
    # Degraded mirrors for when the sibling module cannot be imported; the
    # gate still runs. Flags stay unified by construction (same order, same
    # driver guard); --shared-work refuses to guess a layout it does not own
    # (see main: fail-hard when write_shared_work is None).
    def warn_low_memory() -> None:
        pass

    def resolve_low_mem(setting, log=None) -> bool:
        return bool(setting)

    def lowmem_cc_flags(cc: str) -> list:
        return []

    def bootstrap_cc_middle(cc: str, low_mem: bool) -> list:
        low = cc.lower()
        strip = [] if ("cl" in low.split() or low.strip() == "cl") else (
            ["-s"] if any(t in low for t in ("gcc", "clang", "cc")) else [])
        return [*strip, *SUPPRESS_FLAGS]

    claim_shared_work = None
    write_shared_work = None
    SHARED_CHAIN_C = None
    SHARED_SEED_C = None
    SHARED_MANIFEST = None
    shared_chain_bin = None
CANONICAL_C = os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c")
MAIN_ORB = os.path.join("compiler", "main.orb")

# -O0 keeps peak memory low: these builds run once per gate and speed is
# irrelevant, but low-RAM machines (4 GB) were OOMing inside LLVM/lld during
# -O2 links. The compiler's own internal invocations (pipeline.orb) already
# use -O0.
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
SUPPRESS_FLAGS = ["-O0", "-DORBIT_WITH_EXEC"] + (
    ["-Wall"] if os.environ.get("ORBIT_BOOTSTRAP_WARNINGS", "").strip() not in ("", "0") else [])
PLATFORM_LINK_FLAGS = ["-lws2_32"] if os.name == "nt" else []
# Published fixed-point contract for the current compiler source. The C hash is
# the cross-platform reproducibility contract (enforced with --release); the
# binary hash is platform/toolchain specific and stays informational.
# PUBLISHED_C is rewritten automatically by scripts/build_selfhost.py --promote,
# so it always matches the committed canonical. --release enforces it.
PUBLISHED_C = "32FE98D7CBA95C6B2334E7B6A0FD962D963AE428EF0F81D8ACAEAC05B9FCBACB"
# PUBLISHED_BIN is a fingerprint of one toolchain's output only. It is reported
# for information and never asserted: PE timestamps, PDB paths, section order
# and relocation layout all differ between linkers, so a mismatch here says
# nothing about the reproducibility contract, which is the C source above.
PUBLISHED_BIN = "868935A3B60A80B4FABB6819D3B0B0EB4EB99B4ABA92F30D7351440BF1EAF35E"


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


def run(argv, cwd, env_extra=None, label=""):
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
    and hash the copies. Valid means the manifest parses with its four keys,
    its canonical_sha matches the current canonical, and the snapshot bytes
    hash to the manifest's seed_sha/chain3_sha. Anything else is None and the
    caller rebuilds the chain exactly as without the flag.

    The four equality checks still run on these bytes below (same check()
    calls, same digest comparisons); only the frontend rebuilds are skipped.
    Hashes are computed on the work copies, so what is checked is what was
    hashed -- never what the shared dir claimed at validation time.
    """
    if (not shared_dir or SHARED_CHAIN_C is None or SHARED_SEED_C is None
            or SHARED_MANIFEST is None or shared_chain_bin is None):
        return None
    try:
        with open(os.path.join(shared_dir, SHARED_MANIFEST), encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return None
    if any(k not in doc for k in ("canonical_sha", "seed_sha", "chain3_sha", "published")):
        return None
    if doc["canonical_sha"].lower() != h_canon.lower():
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


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify the C bootstrap fixed point")
    ap.add_argument("--release", action="store_true",
                    help="enforce the published fixed-point C contract (PUBLISHED_C)")
    ap.add_argument("--emit-fixed-point", default=None, metavar="PATH", help="copy the seed-chain fixed-point compiler (chain3) to PATH")
    ap.add_argument("--work", default=None, help="work directory (default: temp)")
    ap.add_argument("--cc", default=None, help="C compiler for the seed (default: auto-detect)")
    ap.add_argument("--refresh", action="store_true", help="also refresh dist/orbit_bootstrap.c and dist/orbit_seed")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    ap.add_argument("--shared-work", default=None, metavar="DIR",
                    help="write converged snapshots + hashes.json under DIR")
    ap.add_argument("--low-mem", dest="low_mem", action="store_true", default=None,
                    help="force the low-memory C profile (-g0, no unwind tables)")
    ap.add_argument("--no-low-mem", dest="low_mem", action="store_false",
                    help="disable the low-memory C profile")
    out.add_quiet(ap)
    args = ap.parse_args()
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
    if args.shared_work and write_shared_work is None:
        out.fail("Failed: --shared-work needs scripts/build_selfhost.py "
                 "beside verify_seed.py.")
        return 2
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
    cc = args.cc or detect_cc()
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
        out.say("  python scripts/build_selfhost.py --promote")
        return 1
    h_canon = sha256(CANONICAL_C)
    out.say(f"Canonical C:  {h_canon}  ({os.path.getsize(CANONICAL_C)} bytes)")
    seed_src_c = CANONICAL_C

    fast = consume_shared_work(shared_dir, work, h_canon) if shared_dir else None
    if fast is not None:
        (fast_seed_c, fast_chain2_c, fast_chain3_c, fast_chain_exe,
         fast_h_seed, fast_h_chain2, fast_h_chain3) = fast
        out.say(f"shared snapshots: reused seed.c/chain3.c/chain3.exe from "
                f"{shared_dir} (no frontend rebuild; checks run on those bytes)")
    if shared_dir is not None:
        shared_dir = claim_shared_work(shared_dir)

    amal = os.path.join(work, "orbit_bootstrap.c")
    run([sys.executable, os.path.join(ROOT, "scripts", "amalgamate.py"), "--entry", seed_src_c, "--out", amal], ROOT, label="amalgamate")

    # Fixed -o basename shared with build_selfhost.py: see the comment there.
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
            # comment in scripts/build_selfhost.py. ORBIT_CCFLAGS_EXTRA mirrors
            # build_selfhost.py for old compilers that ignore ORBIT_SKIP_CC.
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
        _, reused = orbit_ccache.compile_cached(cc_cmd, fixed_argv, fixed_sources, log=out.say)
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


if __name__ == "__main__":
    raise SystemExit(main())