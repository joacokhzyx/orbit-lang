#!/usr/bin/env python3
"""Verify the C bootstrap seed fixed point (STAB-1).

Reproduces the Phase S1 (SOVER-0) verification end-to-end in a hermetic work
directory and reports whether the compiler's reproducibility contract still
holds:

  C fixed point    : the C emitted by the seed when it compiles
                     ``compiler/main.orb`` must be byte-identical to the
                     canonical ``compiler/selfhost/stage3.exe.c``.
  binary fixed pt  : the seed chain (seed2 -> chain2 -> chain3) must be
                     byte-identical once the COFF link timestamps are zeroed.

With ``--bootstrap`` the canonical C is first regenerated through the
independent Zig lineage (``zig-out/bin/orbit.exe bootstrap``) and must match
the committed ``stage3.exe.c``, so a drift in either lineage fails the run.

``--release`` enforces the published fixed-point C contract (``PUBLISHED_C``)
as a hard check; it requires ``--bootstrap`` so the canonical is regenerated
through the Zig lineage on a clean checkout. The published binary hash stays
informational because it is platform/toolchain specific (linker, C compiler,
PE layout) -- the reproducible cross-platform contract is the C source.

``--emit-fixed-point PATH`` copies the seed-chain fixed-point compiler
(``chain3``, byte-identical to ``seed2``/``chain2``) to PATH. That binary is
built entirely by the self-hosted seed chain (canonical C -> seed -> seed2 ->
chain2 -> chain3); the Zig driver is never involved in producing it.

Exit code 0 iff every hard check passes.

Usage:
    python scripts/verify_seed.py [--bootstrap] [--release] [--emit-fixed-point PATH]
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

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANONICAL_C = os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c")
DRIVER = os.path.join(ROOT, "zig-out", "bin", "orbit.exe")
MAIN_ORB = os.path.join("compiler", "main.orb")

SUPPRESS_FLAGS = ["-O2", "-w", "-Wno-int-conversion", "-Wno-incompatible-pointer-types"]
# Published fixed-point contract for the current compiler source. The C hash is
# the cross-platform reproducibility contract (enforced with --release); the
# binary hash is platform/toolchain specific and stays informational.
# Regenerated 2026-08-20 from the W1.5 diagnostic-card parity fix (FE-style
# error cards for parser/semantic failures + raw stderr writer + cmd raw
# capture in the parity runner); chain3 == stage3.
PUBLISHED_C = "EF664AE4D05BDAFF83AABF6FD22BE53029A93EBB49FCB97AAFDB872550C70213"
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
    return "zig cc"


def zero_pe_timestamp(path: str) -> bool:
    """Zero the COFF TimeDateStamp so identical builds hash equally (no-op for ELF)."""
    try:
        with open(path, "r+b") as f:
            hdr = f.read(0x100)
            if len(hdr) < 0x40:
                return False
            lfanew = struct.unpack_from("<I", hdr, 0x3C)[0]
            if lfanew + 12 > len(hdr) or hdr[lfanew : lfanew + 4] != b"PE\x00\x00":
                return False
            ts_off = lfanew + 8
            f.seek(ts_off)
            if f.read(4) == b"\x00\x00\x00\x00":
                return True
            f.seek(ts_off)
            f.write(b"\x00\x00\x00\x00")
            return True
    except OSError:
        return False


def run(argv, cwd, env_extra=None, label=""):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    print(f"[verify] {label or ' '.join(argv)}")
    proc = subprocess.run(argv, cwd=cwd, env=env)
    if proc.returncode != 0:
        print(f"[verify] FAILED ({proc.returncode}): {label or ' '.join(argv)}")
        raise SystemExit(2)
    return proc


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify the C bootstrap seed fixed point")
    ap.add_argument("--bootstrap", action="store_true", help="regenerate canonical C via the Zig lineage first")
    ap.add_argument("--release", action="store_true", help="enforce the published fixed-point C contract (requires --bootstrap)")
    ap.add_argument("--emit-fixed-point", default=None, metavar="PATH", help="copy the seed-chain fixed-point compiler (chain3) to PATH")
    ap.add_argument("--work", default=None, help="work directory (default: temp)")
    ap.add_argument("--cc", default=None, help="C compiler for the seed (default: auto-detect)")
    ap.add_argument("--refresh", action="store_true", help="also refresh dist/orbit_bootstrap.c and dist/orbit_seed")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    args = ap.parse_args()

    if args.release and not args.bootstrap:
        print("[verify] --release requires --bootstrap (the canonical must be regenerated through the Zig lineage on a clean checkout).")
        return 1

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
        print(f"[verify] {'PASS' if ok else 'FAIL'}  {name}  {detail}")

    exe = ".exe" if sys.platform == "win32" else ""
    cc = args.cc or detect_cc()
    cc_cmd = cc.split()
    print(f"[verify] repo root:  {ROOT}")
    print(f"[verify] seed CC:    {cc}")

    if os.path.isfile(CANONICAL_C):
        h_canon = sha256(CANONICAL_C)
        have_canon = True
        print(f"[verify] canonical C:  {h_canon}  ({os.path.getsize(CANONICAL_C)} bytes)")
    else:
        h_canon = None
        have_canon = False
        print("[verify] canonical C absent (clean checkout); will establish it from the Zig lineage with --bootstrap")

    if args.bootstrap:
        if not os.path.isfile(DRIVER):
            print(f"[verify] FAIL: {DRIVER} not found; run `zig build` first.")
            return 1
        # Reuse the chain's shared temp dir so the freshly built stages and the
        # seed chain embed the SAME C source path and are byte-comparable.
        build_tmp = os.path.join(work, "tmp_build")
        os.makedirs(build_tmp, exist_ok=True)
        run([DRIVER, "bootstrap"], ROOT, env_extra={"TEMP": build_tmp, "TMP": build_tmp}, label="bootstrap (Zig lineage)")
        fresh_c = os.path.join(build_tmp, "orbit_selfhost_build.c")
        h_fresh = sha256(fresh_c)
        if have_canon:
            check("bootstrap C == canonical stage3.exe.c", h_fresh == h_canon, f"fresh={h_fresh}")
            if h_fresh != h_canon:
                print("[verify] canonical C is stale; update compiler/selfhost/stage3.exe.c from the fresh build before this gate passes.")
                return 1
            seed_src_c = CANONICAL_C
        else:
            # Clean checkout: the fresh lineage C becomes the reproducibility
            # contract. Persist it so later hermetic runs compare against it.
            os.makedirs(os.path.dirname(CANONICAL_C), exist_ok=True)
            shutil.copyfile(fresh_c, CANONICAL_C)
            h_canon = h_fresh
            seed_src_c = CANONICAL_C
            print(f"[verify] established canonical C: {h_fresh}")
    else:
        if not have_canon:
            print("[verify] FAIL: canonical C missing; run with --bootstrap on a clean checkout.")
            return 1
        seed_src_c = CANONICAL_C

    amal = os.path.join(work, "orbit_bootstrap.c")
    run([sys.executable, os.path.join(ROOT, "scripts", "amalgamate.py"), "--entry", seed_src_c, "--out", amal], ROOT, label="amalgamate")

    seed_exe = os.path.join(work, "orbit_seed" + exe)
    run([*cc_cmd, *SUPPRESS_FLAGS, "-o", seed_exe, amal], ROOT, label="build seed")
    check("seed builds", os.path.isfile(seed_exe))

    def orb_build(compiler, out, snapshot_c):
        # All builds write the intermediate C to the SAME path: clang embeds the
        # C source path in the binary, so a per-build directory would break the
        # binary fixed point even for identical code. Snapshot the C afterwards.
        tmp = os.path.join(work, "tmp_build")
        os.makedirs(tmp, exist_ok=True)
        run([compiler, "build", MAIN_ORB, "-o", os.path.join(work, out)], ROOT,
            env_extra={"TEMP": tmp, "TMP": tmp, "ORBIT_CC": cc, "CC": cc}, label=f"{os.path.basename(compiler)} -> {out}")
        c = os.path.join(tmp, "orbit_selfhost_build.c")
        shutil.copyfile(c, snapshot_c)
        return snapshot_c

    seed_c = orb_build(seed_exe, "seed2" + exe, os.path.join(work, "seed.selfhost.c"))
    h_seed_c = sha256(seed_c)
    check("seed C fixed point (seed C == canonical C)", h_seed_c == h_canon, f"seed={h_seed_c}")
    if h_seed_c != h_canon:
        print("[verify] the seed does not reproduce the canonical C; the fixed point is broken.")
        return 1

    seed2 = os.path.join(work, "seed2" + exe)
    chain2 = os.path.join(work, "chain2" + exe)
    chain3 = os.path.join(work, "chain3" + exe)
    orb_build(seed2, "chain2" + exe, os.path.join(work, "chain2.selfhost.c"))
    orb_build(chain2, "chain3" + exe, os.path.join(work, "chain3.selfhost.c"))

    bins = [seed_exe, seed2, chain2, chain3]
    for b in bins:
        zero_pe_timestamp(b)
    h_bins = [sha256(b) for b in bins]
    check("binary fixed point (seed2==chain2==chain3)", h_bins[1] == h_bins[2] == h_bins[3],
          f"seed2={h_bins[1]} chain2={h_bins[2]} chain3={h_bins[3]}")

    stages = [os.path.join(ROOT, "compiler", "selfhost", "stage2.exe"), os.path.join(ROOT, "compiler", "selfhost", "stage3.exe")]
    present = [s for s in stages if os.path.isfile(s)]
    if present:
        for s in present:
            zero_pe_timestamp(s)
        h_stages = [sha256(s) for s in present]
        # Only a hard check when --bootstrap rebuilt the stages into the SAME
        # shared temp dir as the chain: clang embeds the C source path in the
        # binary, so stale stages of unknown provenance can never be compared.
        ok = all(h == h_bins[1] for h in h_stages)
        check("chain == Zig-bootstrap stages", (ok if args.bootstrap else True),
              " ".join(os.path.basename(s) + "=" + h for s, h in zip(present, h_stages))
              + ("" if ok else " (informational without --bootstrap; paths differ)"))

    if h_seed_c.upper() == PUBLISHED_C:
        print(f"[verify] note: seed C matches published contract {PUBLISHED_C}")
    if h_bins[1].upper() == PUBLISHED_BIN:
        print(f"[verify] note: chain binaries match published binary contract {PUBLISHED_BIN}")
    if args.release:
        check("published C contract (--release)", h_seed_c.upper() == PUBLISHED_C,
              f"seed={h_seed_c.upper()} published={PUBLISHED_C}")
        # PUBLISHED_BIN stays informational: the released binary differs per
        # platform/toolchain (linker, C compiler, PE layout). The reproducible
        # cross-platform contract is the C source, enforced above.

    if args.refresh:
        os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
        shutil.copyfile(amal, os.path.join(ROOT, "dist", "orbit_bootstrap.c"))
        run([*cc_cmd, *SUPPRESS_FLAGS, "-o", os.path.join(ROOT, "dist", "orbit_seed" + exe), amal], ROOT, label="refresh dist/orbit_seed")

    if args.emit_fixed_point:
        os.makedirs(os.path.dirname(os.path.abspath(args.emit_fixed_point)), exist_ok=True)
        shutil.copyfile(chain3, args.emit_fixed_point)
        print(f"[verify] fixed-point compiler (seed chain, chain3) emitted: {args.emit_fixed_point}")

    failed = [n for n, ok, _ in checks if not ok]
    print(f"\n[verify] {len(checks) - len(failed)}/{len(checks)} checks passed"
          + ("" if not failed else f", FAILED: {', '.join(failed)}"))
    print("[verify] work dir: " + work)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())