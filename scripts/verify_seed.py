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

With ``--bootstrap`` the committed canonical C is additionally cross-checked
against the legacy Zig lineage (``zig-out/bin/orbit.exe bootstrap``, override
with ``--driver``), so a drift in either lineage fails the run. This is now
OPTIONAL: the primary gate is self-host-only -- canonical C + any C compiler.

``--release`` enforces the published fixed-point C contract (``PUBLISHED_C``)
as a hard check against the self-hosted rebuild; it works without ``--bootstrap``
whenever the canonical C is present (it is committed since SOVER-1). The published
binary hash stays informational because it is platform/toolchain specific (linker,
C compiler, PE layout) -- the reproducible cross-platform contract is the C source.

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
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from build_selfhost import warn_low_memory
except Exception:
    def warn_low_memory() -> None:
        pass
CANONICAL_C = os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c")
DRIVER = os.path.join(ROOT, "zig-out", "bin", "orbit.exe")
MAIN_ORB = os.path.join("compiler", "main.orb")

# -O0 keeps peak memory low: these builds run once per gate and speed is
# irrelevant, but low-RAM machines (4 GB) were OOMing inside LLVM/lld during
# -O2 links. The compiler's own internal invocations (pipeline.orb) already
# use -O0.
SUPPRESS_FLAGS = ["-O0", "-w", "-Wno-int-conversion", "-Wno-incompatible-pointer-types", "-DORBIT_WITH_EXEC"]
# Published fixed-point contract for the current compiler source. The C hash is
# the cross-platform reproducibility contract (enforced with --release); the
# binary hash is platform/toolchain specific and stays informational.
# Regenerated 2026-08-20 from the W1.5 diagnostic-card parity fix (FE-style
# error cards for parser/semantic failures + raw stderr writer + cmd raw
# capture in the parity runner); chain3 == stage3.
PUBLISHED_C = "0192ED8ACDA289D4EAF4B63D5EE56C75F527E221F73AC9D403B73889C9DAD9BB"
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
    print(f"[verify] {label or ' '.join(argv)}")
    proc = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, errors="replace")
    out = (proc.stdout or "") + (proc.stderr or "")
    if out.strip():
        print(out.rstrip())
    if proc.returncode != 0:
        tail = "\n".join(out.strip().splitlines()[-30:])
        payload = tail.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")[:3800]
        print(f"::error::[{label or ' '.join(argv)}] rc={proc.returncode} :: {payload}")
        print(f"[verify] FAILED ({proc.returncode}): {label or ' '.join(argv)}")
        raise SystemExit(2)
    return proc


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify the C bootstrap seed fixed point")
    ap.add_argument("--bootstrap", action="store_true", help="cross-check the canonical C against the legacy Zig lineage first")
    ap.add_argument("--driver", default=DRIVER, metavar="PATH",
                    help="legacy Zig driver used by --bootstrap (default: %(default)s)")
    ap.add_argument("--release", action="store_true", help="enforce the published fixed-point C contract (requires --bootstrap)")
    ap.add_argument("--emit-fixed-point", default=None, metavar="PATH", help="copy the seed-chain fixed-point compiler (chain3) to PATH")
    ap.add_argument("--work", default=None, help="work directory (default: temp)")
    ap.add_argument("--cc", default=None, help="C compiler for the seed (default: auto-detect)")
    ap.add_argument("--refresh", action="store_true", help="also refresh dist/orbit_bootstrap.c and dist/orbit_seed")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    args = ap.parse_args()
    warn_low_memory()

    if args.release and not args.bootstrap and not os.path.isfile(CANONICAL_C):
        print("[verify] --release requires either --bootstrap or a committed canonical C.")
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
        if not os.path.isfile(args.driver):
            print(f"[verify] FAIL: legacy Zig driver {args.driver} not found.")
            print("[verify] The self-hosted chain no longer needs it; to refresh the")
            print("[verify] canonical after compiler changes run:")
            print("[verify]   python scripts/build_selfhost.py --promote")
            return 1
        # Reuse the chain's shared temp dir so the freshly built stages and the
        # seed chain embed the SAME C source path and are byte-comparable.
        build_tmp = os.path.join(work, "tmp_build")
        os.makedirs(build_tmp, exist_ok=True)
        run([args.driver, "bootstrap"], ROOT, env_extra={"TEMP": build_tmp, "TMP": build_tmp}, label="bootstrap (legacy Zig lineage)")
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
        label = f"{os.path.basename(compiler)} -> {out}"
        # Windows real-time AV (Defender) briefly locks freshly linked
        # executables; running one immediately after linking can fail
        # spuriously. Retry once before giving up.
        last_rc = None
        for attempt in (1, 2):
            env = dict(os.environ)
            env.update({"TEMP": tmp, "TMP": tmp, "ORBIT_CC": cc, "CC": cc})
            print(f"[verify] {label}" + ("  (retry)" if attempt == 2 else ""))
            proc = subprocess.run([compiler, "build", MAIN_ORB, "-o", os.path.join(work, out)], cwd=ROOT, env=env)
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
                print(f"[verify] FAILED ({last_rc}): {label} (no C emitted)")
                raise SystemExit(2)
            print(f"[verify] note: {label} exited {last_rc} after emitting C; rebuilding with our own cc.")
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
        run([*cc_cmd, "-s", *SUPPRESS_FLAGS, "-I", os.path.join(ROOT, "runtime"),
             "-o", fixed_out, shared], ROOT,
            env_extra={"TEMP": tmp, "TMP": tmp}, label=f"deterministic rebuild {out}")
        shutil.move(fixed_out, os.path.join(work, out))
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
    # Binary reproducibility is toolchain-specific by design (see module
    # docstring): zig cc/clang strips deterministically, while MSVC-target
    # linkers randomize more than timestamps/GUIDs (section order, relocs).
    # Hard check only for proven-deterministic toolchains; warn otherwise.
    if cc.startswith("zig"):
        check("binary fixed point (seed2==chain2==chain3)", h_bins[1] == h_bins[2] == h_bins[3],
              f"seed2={h_bins[1]} chain2={h_bins[2]} chain3={h_bins[3]}")
    else:
        ok_bins = h_bins[1] == h_bins[2] == h_bins[3]
        print(f"[verify] note: binary fixed point {'PASS' if ok_bins else 'DIFFERS'} "
              f"(informational for non-zig toolchain {cc})")
        print(f"[verify]   seed2={h_bins[1]} chain2={h_bins[2]} chain3={h_bins[3]}")

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
        if os.name != "nt":
            os.chmod(args.emit_fixed_point, 0o755)
        print(f"[verify] fixed-point compiler (seed chain, chain3) emitted: {args.emit_fixed_point}")

    failed = [n for n, ok, _ in checks if not ok]
    print(f"\n[verify] {len(checks) - len(failed)}/{len(checks)} checks passed"
          + ("" if not failed else f", FAILED: {', '.join(failed)}"))
    print("[verify] work dir: " + work)
    if failed:
        details = []
        for n, ok, d in checks:
            if not ok:
                details.append(f"{n}: {d}")
        payload = " | ".join(details).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")[:3800]
        print(f"::error::[verify checks] {payload}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())