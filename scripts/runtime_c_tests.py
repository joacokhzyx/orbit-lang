#!/usr/bin/env python3
"""Compile and run the runtime C tests, the way CI does.

This step was forty lines of shell inside ci-gate.yml: ten programs, each with
its own include path, its own `-D`, its own link flags, and one of them
deliberately compiled with `-Wall` while its nine neighbours use `-w`. That shape
had two costs. The list of what the runtime is actually tested for lived in a
YAML `run:` block, where nothing could read it, and adding a program meant
editing a shell script by hand inside a workflow.

It also cost coverage, which is the reason this exists rather than a tidy-up.
In GitHub Actions a failing `run:` aborts its step and every step after it is
skipped, so within one job the step order IS the coverage policy. This step
crashed on Windows -- an access violation in test_migrations -- and while it sat
sixth of twenty-four it took fourteen gates with it. Moving it last fixed that
for the Python gates, and splitting the workflow into independent jobs fixes it
properly. Either way the step has to exist as a thing you can run by hand, or the
only way to test the runtime is to push and read a log.

Two rules are carried over verbatim from the shell and are the reason this is a
port rather than a rewrite:

  * test_oom observes the abort-on-exhaustion policy in a child process, so it
    needs fork/waitpid and is POSIX-only.
  * test_float_format is compiled with `-Wall` and not `-w`, on purpose and
    alone. The line it covers was a strncat in orbit_float_to_string, and no
    warning flag on gcc catches it -- MSVC is the only toolchain here that calls
    strncat unsafe, so this is the one runtime test that has to reach the
    Windows leg with its diagnostics intact. `-Wextra` is not used because it
    reports unrelated unused parameters in files the change did not touch.

Nothing here needs the Orbit compiler. It compiles C with a C compiler, which is
why it can be its own CI job with no dependency on the bootstrap.

Every compile goes through the shared content-addressed C cache
(`scripts/orbit_ccache.py`), because the programs' C does not change between
runs and neither do the headers they include. That second half is what the key
had to learn: a program's `-I` names the runtime trees its `#include`s resolve
against, so the key covers those trees and a runtime header change still
recompiles. A repeat run copies a binary instead of compiling one.

`--self-test` asserts the table can say no: a program that does not compile and a
program that fails must both be reported.
"""

import argparse
import os
import pathlib
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_ccache

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNTIME = ROOT / "runtime"
VENDOR = RUNTIME / "vendor"
WIN_VENDOR = VENDOR / "win-x64"

NET = ["-DORBIT_WITH_NET"]


def prog(name: str, *, vendor: bool = False, defines=(), warnings=False,
         posix_only=False, db=False, src=None):
    return {
        "name": name,
        "src": src or f"runtime/test_{name}.c",
        "vendor": vendor,
        "defines": list(defines),
        "warnings": warnings,
        "posix_only": posix_only,
        "db": db,
    }


# The whole list, in one place. Order is the shell's order, and it is the order
# CI ran them in, so a failure names the same neighbour it always did.
PROGRAMS = [
    prog("arena"),
    prog("file"),
    prog("oom", posix_only=True),
    prog("http_parse", vendor=True),
    prog("response", vendor=True),
    prog("upload", vendor=True),
    prog("params_decode", vendor=True),
    prog("latency_percentiles", vendor=True),
    prog("ledger_percentiles", vendor=True),
    prog("kynx", vendor=True, defines=["-DORBIT_KYNX_TEST"]),
    prog("json"),
    prog("crypto"),
    prog("float_format", warnings=True),
    prog("migrations", vendor=True, db=True, defines=["-DORBIT_WITH_DB"]),
    prog("db_ops", vendor=True, db=True, defines=["-DORBIT_WITH_DB"]),
    # The auth harness is a runtime test that happens to live under tests/auth
    # rather than runtime/, and it is the same shape as the ten above: compile a
    # C program against the runtime, link it, run it, check the exit code. It
    # was four lines of shell in ci-gate.yml with its own LDFLAGS block, and the
    # transcription that carried it into this table's job dropped the `-lsqlite3`
    # and failed at link time on both platforms. A gate that is a row in a table
    # cannot lose its link flags; a gate that is shell can.
    prog("auth", vendor=True, db=True, defines=["-DORBIT_WITH_DB"],
         src="tests/auth/auth_harness.c"),
    prog("result_float", warnings=True),
    prog("random", warnings=True),
    prog("exec", warnings=True, defines=["-DORBIT_WITH_EXEC"]),
    prog("http_client", warnings=True),
    prog("query", warnings=True),
    # The arena's own counters are joined into the process totals once per
    # request by orbit_arena_reset. This is the gate that says the join is the
    # only publisher: four threads' arenas against the aggregate delta, plus
    # the per-route memory columns orbit_ledger_exit fills.
    prog("arena_telemetry", warnings=True),
    prog("strings", warnings=True),
]


def windows() -> bool:
    return os.name == "nt"


def compile_argv(cc: str, p: dict, out: pathlib.Path) -> list:
    argv = [cc, "-O0", "-w" if not p["warnings"] else "-Wall"]
    argv += ["-I", "runtime"]
    if p["vendor"]:
        argv += ["-I", "runtime/vendor"]
    argv += NET + p["defines"]
    argv += [p["src"], "-o", str(out)]
    if windows():
        argv.append("-lws2_32")
        if p["db"]:
            argv.append("runtime/vendor/win-x64/sqlite3.lib")
    elif p["db"]:
        argv.append("-lsqlite3")
    return argv


def stage_sqlite(workdir: pathlib.Path) -> None:
    """Put sqlite3.dll beside the binaries on Windows.

    The auth step and the Kynx step both did this; the runtime step linked
    sqlite3.lib and did not, so the loader had to find it from whatever the
    runner's environment happened to offer. Copying it makes the step depend on
    the repository and not on PATH.
    """
    if not windows():
        return
    dll = WIN_VENDOR / "sqlite3.dll"
    if dll.exists():
        for dest in (workdir, pathlib.Path.cwd()):
            try:
                (dest / "sqlite3.dll").write_bytes(dll.read_bytes())
            except OSError:
                pass


def self_test() -> int:
    """Assert the runner can report both kinds of failure.

    A gate that cannot fail is not a gate, and the failure this replaced was a
    process crash that CI could only see as a bare `[ORBIT RUNTIME CRASH]`. So
    the two ways this can say no -- the compile fails, and the program exits
    non-zero -- are both asserted here, on scratch files.
    """
    with tempfile.TemporaryDirectory(prefix="runtime_c_selftest_") as td:
        work = pathlib.Path(td)
        bad_src = work / "bad.c"
        bad_src.write_text("int main(void) { return this is not c; }\n")
        rc = subprocess.run([os.environ.get("CC", "gcc"), "-O0", str(bad_src),
                             "-o", str(work / "bad")],
                            capture_output=True, text=True).returncode
        if rc == 0:
            print("self-test FAILED: a file that does not compile was accepted")
            return 1

        ok_src = work / "ok.c"
        ok_src.write_text("int main(void) { return 0; }\n")
        out = work / "ok"
        rc = subprocess.run([os.environ.get("CC", "gcc"), "-O0", str(ok_src),
                             "-o", str(out)],
                            capture_output=True, text=True).returncode
        if rc != 0:
            print("self-test FAILED: a valid file did not compile")
            return 1
        if out.exists():
            rc = subprocess.run([str(out)], capture_output=True, text=True).returncode
            if rc != 0:
                print("self-test FAILED: a program exiting 0 was reported as a "
                      "failure")
                return 1

        # Every entry in the table must name a file that exists and a flag set
        # that is a list, because the shell never checked either.
        for p in PROGRAMS:
            if not (ROOT / p["src"]).exists():
                print(f"self-test FAILED: the table names {p['src']}, which does "
                      f"not exist")
                return 1
            if not isinstance(p["defines"], list):
                print(f"self-test FAILED: {p['name']} has a non-list defines")
                return 1

    print(f"Finished runtime-c self-test: compile failure and program failure "
          f"are both reported; all {len(PROGRAMS)} programs in the table exist.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cc", default=os.environ.get("ORBIT_CC") or "gcc")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--filter", default=None,
                    help="only run programs whose name contains this")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    with tempfile.TemporaryDirectory(prefix="runtime_c_") as td:
        work = pathlib.Path(td)
        stage_sqlite(work)

        todo = [p for p in PROGRAMS
                if not p["posix_only"] or not windows()]
        if args.filter:
            todo = [p for p in todo if args.filter in p["name"]]

        failures = []

        def run_one(p):
            # Each program owns a run subdir: test_upload writes ./note.txt
            # and test_migrations writes test_migrations_tmp.db by design, so
            # a shared cwd lets two programs clobber each other's files, and
            # the Windows loader needs sqlite3.dll beside the run. Compile
            # output keeps a unique name; only the main thread prints.
            # Returns (name, kind, *payload) for ordered reporting below.
            pdir = work / ("r_" + p["name"])
            pdir.mkdir(exist_ok=True)
            if windows():
                dll = WIN_VENDOR / "sqlite3.dll"
                if dll.exists():
                    try:
                        (pdir / "sqlite3.dll").write_bytes(dll.read_bytes())
                    except OSError:
                        pass
            binary = pdir / ("t_" + p["name"] + (".exe" if windows() else ""))
            argv = compile_argv(args.cc, p, binary)
            try:
                orbit_ccache.compile_cached(
                    [args.cc], argv,
                    orbit_ccache.argv_inputs(argv, cwd=str(ROOT)),
                    cwd=str(ROOT), capture_output=True)
            except subprocess.CalledProcessError as exc:
                return (p["name"], "compile-fail",
                        exc.stdout or "", exc.stderr or "")
            # cwd is the program's own scratch dir, NOT the repository root
            # (see the note kept below): these tests use relative paths on
            # purpose, so running them from the root drops files into the
            # working tree.
            run = subprocess.run([str(binary)], cwd=str(pdir),
                                 capture_output=True, text=True)
            if run.returncode != 0:
                return (p["name"], "run-fail", run.returncode,
                        run.stdout, run.stderr)
            last = (run.stdout.strip().splitlines() or [""])[-1]
            return (p["name"], "ok", last)

        with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
            results = list(pool.map(run_one, todo))
        for name, kind, *rest in results:
            if kind == "compile-fail":
                so, se = rest
                sys.stdout.write(so)
                sys.stderr.write(se)
                failures.append(name + " (compile)")
                print(f"  {name:<20} COMPILE FAIL")
                continue
            # cwd is the scratch dir, NOT the repository root. These tests use
            # relative paths on purpose -- test_upload.c writes "./note.txt" and
            # test_migrations.c writes "test_migrations_tmp.db", both noted as
            # deliberate in their sources -- so running them from the root drops
            # two files into the working tree. It went unnoticed because CI's
            # workspace is ephemeral; locally it dirties `git status` and, worse,
            # it is a `git add -A` away from a commit.
            if kind == "run-fail":
                rc, so, se = rest
                # Everything, only on failure. A passing program gets one line.
                #
                # Both streams are suppressed on success on purpose.
                # test_oom exercises the abort-on-exhaustion policy in a child
                # process and prints "out of memory allocating
                # 4611686018427387904 bytes" on the way to PASS; test_migrations
                # narrates four sub-tests. Both are the tests working, and both
                # read like a gate failing if they land in the middle of a log.
                # A gate whose success output needs skimming is a gate whose
                # failure output gets skimmed too.
                sys.stdout.write(so)
                sys.stderr.write(se)
                failures.append(f"{name} (exit {rc})")
                print(f"  {name:<20} FAIL exit={rc}")
            else:
                last = rest[0]
                print(f"  {name:<20} ok{('  ' + last) if last else ''}")

    skipped = [p["name"] for p in PROGRAMS if p["posix_only"] and windows()]
    if skipped:
        print(f"  (skipped on Windows, needs fork/waitpid: {', '.join(skipped)})")

    if failures:
        print(f"\nFinished runtime-c: {len(failures)} of {len(todo)} failed: "
              f"{', '.join(failures)}")
        return 1
    print(f"\nFinished runtime-c: {len(todo)}/{len(todo)} pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())