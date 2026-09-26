#!/usr/bin/env python3
"""Verify the C bootstrap fixed point (STAB-1).

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

Exit code 0 iff every hard check passes.

Usage:
    python scripts/verify_seed.py [--release] [--emit-fixed-point PATH]
                                  [--work DIR] [--cc CC] [--refresh] [--keep]
"""

import argparse
import hashlib
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
    from build_selfhost import warn_low_memory
except Exception:
    def warn_low_memory() -> None:
        pass
CANONICAL_C = os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c")
MAIN_ORB = os.path.join("compiler", "main.orb")

# -O0 keeps peak memory low: these builds run once per gate and speed is
# irrelevant, but low-RAM machines (4 GB) were OOMing inside LLVM/lld during
# -O2 links. The compiler's own internal invocations (pipeline.orb) already
# use -O0.
# -Wno-error= downgrades are load-bearing on GCC 14+ (int-conversion and
# incompatible-pointer-types are errors by default there); without them any
# remaining instance bricks the seed build instead of warning. Full -Werror
# cleanliness is tracked by scripts/werror_gate.py (STAB-3), which is the
# strict gate and runs in CI.
# -Wall is deliberately absent: on the 3.9 MB compiler unit it costs 23.8 s
# against 3.7 s without it (5.7x, 2-core runner, gcc 13.3) and surfaces 89
# warnings there, because the analysis it enables is superlinear in emitted
# size. The fixed point is about emitted C bytes, not warnings; warnings are
# werror_gate.py's job. Set ORBIT_BOOTSTRAP_WARNINGS=1 to restore it locally.
SUPPRESS_FLAGS = ["-O0", "-Wno-error=int-conversion",
                  "-Wno-error=incompatible-pointer-types", "-DORBIT_WITH_EXEC"] + (
    ["-Wall"] if os.environ.get("ORBIT_BOOTSTRAP_WARNINGS", "").strip() not in ("", "0") else [])
PLATFORM_LINK_FLAGS = ["-lws2_32"] if os.name == "nt" else []
# Published fixed-point contract for the current compiler source. The C hash is
# the cross-platform reproducibility contract (enforced with --release); the
# binary hash is platform/toolchain specific and stays informational.
# PUBLISHED_C is rewritten automatically by scripts/build_selfhost.py --promote,
# so it always matches the committed canonical. --release enforces it.
PUBLISHED_C = "3A845B104F8ADC3E4C1DF273B90AA0E4EC48F2CC46A0A84129CCD03D8E498F35"
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


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify the C bootstrap fixed point")
    ap.add_argument("--release", action="store_true",
                    help="enforce the published fixed-point C contract (PUBLISHED_C)")
    ap.add_argument("--emit-fixed-point", default=None, metavar="PATH", help="copy the seed-chain fixed-point compiler (chain3) to PATH")
    ap.add_argument("--work", default=None, help="work directory (default: temp)")
    ap.add_argument("--cc", default=None, help="C compiler for the seed (default: auto-detect)")
    ap.add_argument("--refresh", action="store_true", help="also refresh dist/orbit_bootstrap.c and dist/orbit_seed")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
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

    amal = os.path.join(work, "orbit_bootstrap.c")
    run([sys.executable, os.path.join(ROOT, "scripts", "amalgamate.py"), "--entry", seed_src_c, "--out", amal], ROOT, label="amalgamate")

    seed_exe = os.path.join(work, "orbit_seed" + exe)
    orbit_ccache.compile_cached(cc_cmd, [*cc_cmd, *SUPPRESS_FLAGS, "-o", seed_exe, amal,
                                        *PLATFORM_LINK_FLAGS], [amal], log=out.say)
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
            # comment in scripts/build_selfhost.py.
            env = dict(os.environ)
            env.update({"TEMP": tmp, "TMP": tmp, "TMPDIR": tmp, "ORBIT_CC": cc,
                        "CC": cc, "ORBIT_SKIP_CC": "1", "ORBIT_WARNINGS": "0"})
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
        _, reused = orbit_ccache.compile_cached(
            cc_cmd,
            [*cc_cmd, "-s", *SUPPRESS_FLAGS, "-I", os.path.join(ROOT, "runtime"),
             "-o", fixed_out, shared, *PLATFORM_LINK_FLAGS],
            [shared], log=out.say)
        out.say(f"deterministic rebuild {out_name}"
                + ("  (from cache)" if reused else ""))
        shutil.move(fixed_out, os.path.join(work, out_name))
        shutil.copyfile(c, snapshot_c)
        return snapshot_c, reused

    seed_c, seed_reused = orb_build(seed_exe, "seed2" + exe, os.path.join(work, "seed.selfhost.c"))
    h_seed_c = sha256(seed_c)
    check("seed C fixed point (seed C == canonical C)", h_seed_c == h_canon, f"seed={h_seed_c}")
    if h_seed_c != h_canon:
        out.fail("Failed: the seed does not reproduce the canonical C; the fixed point is broken.")
        return 1

    seed2 = os.path.join(work, "seed2" + exe)
    chain2 = os.path.join(work, "chain2" + exe)
    chain3 = os.path.join(work, "chain3" + exe)
    chain2_c, chain2_reused = orb_build(seed2, "chain2" + exe, os.path.join(work, "chain2.selfhost.c"))
    chain3_c, chain3_reused = orb_build(chain2, "chain3" + exe, os.path.join(work, "chain3.selfhost.c"))

    # Every stage must re-emit the canonical C, not just the first one. At a
    # genuine fixed point all three are byte-identical; asserting it closes the
    # hole where only stage one is compared and later stages drift silently.
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
        out.say("note: binary fixed point not evaluated (compile cache reused "
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
        orbit_ccache.compile_cached(
            cc_cmd,
            [*cc_cmd, *SUPPRESS_FLAGS, "-o", os.path.join(ROOT, "dist", "orbit_seed" + exe),
             amal, *PLATFORM_LINK_FLAGS],
            [amal], log=out.say)

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