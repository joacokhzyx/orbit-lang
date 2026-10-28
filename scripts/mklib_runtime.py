#!/usr/bin/env python3
"""Build the net-variant Orbit runtime static library (.orbit/lib/libruntime_net.a).

A user TU compiled with -DORBIT_SEPARATE_COMPILATION sees only the
declarations in runtime/orbit_api.h; the definitions live in this archive.
The archive holds one member per runtime module (CORE_MODULES, NET_MODULES),
each compiled from its own runtime/<module>.c with -DORBIT_RUNTIME_MODULE
against the module headers. ld pulls only the members a program references,
so a program that never touches Kynx never links the Kynx tables, and a
program with no network never imports ws2_32. Unity builds (runtime.h without
the flag) include the same .c files and are unchanged.

The Orbit modules (runtime/orb/*.orb, C committed in runtime/gen/*.c) are
archive members too, always, compiled from the generated C.

Single variant on purpose: no test in tests/suite or tests/std uses the DB,
so the net-without-DB library links everything those suites emit. The DB
modules (DB_MODULES) are compiled by --db, which writes
libruntime_net_db.a: every module above plus database and auth, the last two
with -DORBIT_WITH_DB.

Usage:
    python scripts/mklib_runtime.py [--cc CC] [--out PATH] [--db] [--self-test]

--self-test asserts the tool can fail: a TU that does not compile and a
missing runtime directory must both be reported (D8: a gate that is not able
to fail is not a gate).
"""

import argparse
import concurrent.futures
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNTIME = ROOT / "runtime"

# One archive member per module. perf.c owns the performance counters and the
# Kynx lease pointer; every other module binds to them through extern.
CORE_MODULES = ("perf", "types", "console", "crash",
                "arena", "arena_alloc", "arena_oom", "arena_reset", "arena_checkpoint",
                "arena_child", "arena_stats", "arena_global", "arena_pool",
                "collections", "json", "file", "os", "builtins", "crypto",
                "selfhost", "energy", "ledger")
NET_MODULES = ("http", "kynx", "pulse")
DB_MODULES = ("database", "auth")

# Modules compiled with -DORBIT_WITH_NET (their sources branch on it).
# -DORBIT_LIB_NO_ROUTER leaves out the fallback router: every emitted TU
# defines ORBIT_CUSTOM_ROUTER and its own orbit_handle_request.
MODULE_DEFINES = {m: ("ORBIT_WITH_NET", "ORBIT_LIB_NO_ROUTER") for m in NET_MODULES}
# The DB modules sit in the DB archive only. The progress handler they install
# is defined in kynx.c, so the DB archive carries the network modules too.
MODULE_DEFINES.update({m: ("ORBIT_WITH_DB", "ORBIT_WITH_NET") for m in DB_MODULES})

# Symbols the archive must export (a TU-visible function the split relies
# on) and must not export (the fallback router the user TU provides).
MUST_EXPORT = "orbit_string_concat"
MUST_NOT_EXPORT = "orbit_handle_request"


def resolve_cc(cli_cc):
    if cli_cc:
        return cli_cc
    return os.environ.get("ORBIT_CC") or os.environ.get("CC") or "gcc"


def default_out(db=False):
    name = "libruntime_net_db.a" if db else "libruntime_net.a"
    return ROOT / ".orbit" / "lib" / name


def fnv1a_hex(data):
    """FNV-1a, 32 bits, 8 lowercase hex digits: orbit_string_hash_selfhost."""
    h = 2166136261
    for byte in data:
        h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
    return "%08x" % h


def runtime_stamp(runtime_dir):
    """One "<name> <digest>" line per runtime source the archive is built from.

    The compiler links the archive by default (compiler/host/pipeline.orb,
    runtimeArchiveFresh) only when it finds these lines for the runtime
    directory it resolves, so an archive built from older sources is skipped
    instead of linked. The file set is the .c and .h files directly in the
    directory and in its gen/ subdirectory (named "gen/<name>"), minus test_*,
    and must match runtimeSourceCounts there.
    """
    lines = []
    root = pathlib.Path(runtime_dir)
    for prefix, folder in (("", root), ("gen/", root / "gen")):
        if not folder.is_dir():
            continue
        for path in sorted(folder.iterdir()):
            name = path.name
            if not path.is_file() or not name.endswith((".c", ".h")):
                continue
            if name.startswith("test_"):
                continue
            lines.append("%s%s %s\n" % (prefix, name, fnv1a_hex(path.read_bytes())))
    return "".join(lines)


def orb_modules():
    """The Orbit runtime modules: one runtime/orb/<name>.orb each."""
    return tuple(sorted(p.stem for p in (RUNTIME / "orb").glob("*.orb")))


def build_lib(cc, out_path, work, defines=(), modules=None):
    """Compile every module into its own object and archive them.

    The Orbit modules come after `modules`: runtime/gen/<name>.c is compiled.

    `defines` ride on each cc line. shard_selfhost passes ORBIT_WITH_EXEC for
    the bootstrap archive that links the fixed-point compiler: that compiler
    spawns its own C compiler, so os.c needs the exec implementation. The
    user-facing archive (.orbit/lib/libruntime_net.a) stays exec-free (R3.6).
    """
    runtime_dir = RUNTIME
    if not runtime_dir.is_dir():
        out.fail(f"Failed mklib: no runtime directory at {runtime_dir}")
        return 1
    if not (runtime_dir / "runtime.h").exists():
        out.fail("Failed mklib: runtime/runtime.h is gone")
        return 1
    mods = tuple(modules) if modules else CORE_MODULES + NET_MODULES
    for m in mods:
        if not (runtime_dir / (m + ".c")).exists():
            out.fail(f"Failed mklib: runtime/{m}.c is gone")
            return 1
    orbs = orb_modules()
    for m in orbs:
        if not (runtime_dir / "gen" / (m + ".c")).exists():
            out.fail(f"Failed mklib: runtime/gen/{m}.c is gone")
            return 1

    def compile_gen(m):
        obj = work / (m + ".o")
        argv = [cc, "-O2", "-Wall", "-DORBIT_SEPARATE_COMPILATION",
                "-I", str(runtime_dir), "-I", str(runtime_dir / "vendor"),
                str(runtime_dir / "gen" / (m + ".c")), "-c", "-o", str(obj)]
        proc = subprocess.run(argv, cwd=str(ROOT), capture_output=True,
                              text=True, errors="replace")
        return m, obj, proc

    def compile_one(m):
        if m in orbs:
            return compile_gen(m)
        obj = work / (m + ".o")
        argv = [cc, "-O2", "-Wall", "-DORBIT_RUNTIME_MODULE"]
        for d in tuple(defines) + MODULE_DEFINES.get(m, ()):
            argv.append("-D" + d)
        argv += ["-I", str(runtime_dir), "-I", str(runtime_dir / "vendor"),
                 str(runtime_dir / (m + ".c")), "-c", "-o", str(obj)]
        proc = subprocess.run(argv, cwd=str(ROOT), capture_output=True,
                              text=True, errors="replace")
        return m, obj, proc

    jobs = min(8, os.cpu_count() or 2)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        results = list(pool.map(compile_one, mods + orbs))
    objs = []
    for m, obj, proc in results:
        if proc.returncode != 0:
            src = f"runtime/gen/{m}.c" if m in orbs else f"runtime/{m}.c"
            out.fail(f"Failed mklib: {src} did not compile (rc={proc.returncode})")
            sys.stdout.write(proc.stdout or "")
            sys.stderr.write(proc.stderr or "")
            return 1
        if proc.stderr.strip():
            # -Wall is advisory here (unity cleanliness is werror_gate.py's job);
            # surface it so a new warning is seen, without failing the build.
            out.say(f"mklib: compiler warnings from runtime/{m}.c:")
            sys.stderr.write(proc.stderr)
        objs.append(obj)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        out_path.unlink()
    ar = shutil.which("ar") or "ar"
    proc = subprocess.run([ar, "rcs", str(out_path)] + [str(o) for o in objs],
                          cwd=str(ROOT),
                          capture_output=True, text=True, errors="replace")
    if proc.returncode != 0:
        out.fail(f"Failed mklib: ar did not write {out_path} (rc={proc.returncode})")
        sys.stdout.write(proc.stdout or "")
        sys.stderr.write(proc.stderr or "")
        return 1
    nm = shutil.which("nm")
    if nm:
        proc = subprocess.run([nm, "-g", str(out_path)],
                              capture_output=True, text=True, errors="replace")
        symbols = proc.stdout or ""
        if MUST_EXPORT not in symbols:
            out.fail(f"Failed mklib: {MUST_EXPORT} not exported by {out_path}")
            return 1
        if MUST_NOT_EXPORT in symbols:
            out.fail(f"Failed mklib: {MUST_NOT_EXPORT} leaked into {out_path} "
                     f"(ORBIT_LIB_NO_ROUTER did not exclude the fallback router)")
            return 1
        out.say(f"mklib: nm confirms {MUST_EXPORT} exported, "
                f"{MUST_NOT_EXPORT} absent")
    else:
        out.say("mklib: no nm on PATH, skipping the export check")
    size_kb = out_path.stat().st_size / 1024
    out.finish("mklib", len(objs), len(objs),
               extra=f"Wrote {out_path} ({size_kb:.0f} KB, {len(objs)} members)")
    return 0


def self_test(cc):
    """The tool must be able to say no twice: bad C, missing runtime."""
    with tempfile.TemporaryDirectory(prefix="mklib_selftest_") as td:
        work = pathlib.Path(td)
        bad_src = work / "bad.c"
        bad_src.write_text("int main(void) { return this is not c; }\n")
        rc = subprocess.run([cc, "-O2", "-I", str(RUNTIME),
                             str(bad_src), "-c", "-o", str(work / "bad.o")],
                            capture_output=True, text=True).returncode
        if rc == 0:
            print("self-test FAILED: a file that does not compile was accepted")
            return 1
        if fnv1a_hex(b"") != "811c9dc5" or fnv1a_hex(b"a") != "e40c292c":
            print("self-test FAILED: fnv1a_hex disagrees with the published "
                  "FNV-1a vectors, so every archive would look stale")
            return 1
        missing = work / "no-runtime-here"
        proc = subprocess.run(
            [sys.executable, __file__, "--out", str(work / "lib.a")],
            capture_output=True, text=True, errors="replace",
            env={**os.environ, "ORBIT_MKLIB_RUNTIME_DIR": str(missing)})
        if proc.returncode == 0:
            print("self-test FAILED: a missing runtime directory was accepted")
            return 1
        if "Traceback (most recent call last)" in (proc.stdout + proc.stderr):
            print("self-test FAILED: missing runtime died with a traceback")
            return 1
    out.finish("mklib self-test", 2, 2,
               extra="compile failure and missing runtime are both reported")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cc", default=None)
    ap.add_argument("--out", default=None,
                    help="archive path (default: .orbit/lib/libruntime_net.a)")
    ap.add_argument("--db", action="store_true",
                    help="build the database variant (libruntime_net_db.a): "
                         "the modules above plus database and auth")
    ap.add_argument("--self-test", action="store_true")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    cc = resolve_cc(args.cc)
    if args.self_test:
        return self_test(cc)

    override = os.environ.get("ORBIT_MKLIB_RUNTIME_DIR")
    if override:
        global RUNTIME
        RUNTIME = pathlib.Path(override)
    out_path = pathlib.Path(args.out) if args.out else default_out(args.db)
    modules = CORE_MODULES + NET_MODULES + (DB_MODULES if args.db else ())
    with tempfile.TemporaryDirectory(prefix="mklib_") as td:
        rc = build_lib(cc, out_path, pathlib.Path(td), modules=modules)
    if rc == 0:
        # Bytes, not text: the compiler compares lines split on LF alone.
        stamp = out_path.with_name(out_path.name + ".stamp")
        stamp.write_bytes(runtime_stamp(RUNTIME).encode("utf-8"))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
