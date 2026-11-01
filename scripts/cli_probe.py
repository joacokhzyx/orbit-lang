#!/usr/bin/env python3
"""CLI contract probe: exit codes and streams per COMMANDS.md.

Usage:
    python scripts/cli_probe.py --compiler <orbit-binary> [--work DIR]
    python scripts/cli_probe.py --specimen

Exits 0 iff every case matches its expectation. Cases run in an empty
work directory so ambient state (.orbit/, repo files) cannot leak in.
Expected table derives from docs/COMMANDS.md plus the CLI-1 decisions:
unknown top-level command -> usage on stderr, exit 2; operational
errors go to stderr with an `orbit <cmd>:` prefix; --help exits 0.

--specimen prints the static output-grammar specimen (one section per
tool) so tone can be reviewed without running a bootstrap. Nothing
there executes a gate.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SPECIMEN = """\
--- suite -----------------------------------------------
Testing arith ... exit 0 as expected
Failed notes_write: got exit 1, want 0
Finished suite: 20/21 pass

--- parity ----------------------------------------------
Checking r1_route_only ... match (C)
Failed r12_route_err: mismatch (line 2: expected 'kind=DIAG' got 'kind=C')
Finished parity: 30/31 match goldens

--- cli-probe -------------------------------------------
Probing build-quiet ... ok
Failed check-missing: rc=0 (want 1)
Finished cli-probe: 34/35 pass

--- verify / bootstrap ----------------------------------
Running build seed from canonical C ...
Verified seed C fixed point (seed C == canonical C) ... ok
Finished bootstrap: converged (matches canonical).

--- load / gates ----------------------------------------
Loading 127.0.0.1:4102 /health x2 (source ips: 0) ...
  completed=200 ok_2xx=200 transport_errors=0 error_rate=0.000% elapsed=20.03s
Phase B passed: ok=5 denied=20 retry_after='1' elapsed=0.21s
Finished kynx gate: PASS

--- orbit build, C step fails ---------------------------
orbit build: couldn't finish the C step - this one is on me, not your code.
  Your program translated cleanly; the C compiler rejected my output:
  <build>:35703:12: error: assignment to integer from pointer without a cast
  ... 34 more lines (full log: <tmp>/orbit_build.cc.log)
  Tip: run `orbit check app.orb` first - if that passes, file an issue
  with the .orb file and I'll read it.
"""

SETUP = {
    # Stand-ins for r6.exe. The native backend must refuse both before it hands
    # either a program: one never answers `--version` (a stale r6 waits for
    # input), the other answers with an IR protocol this compiler does not emit.
    "r6_silent.cmd": "@echo off\r\nping -n 40 127.0.0.1 >nul\r\n",
    "r6_other.cmd": "@echo off\r\necho r6 9.9.9 ir-protocol 99\r\n",
    "files/case.orb": "fn main() -> int {\nreturn 0\n}\n",
    "files/clean.orb": "fn main() -> int {\n    return 0\n}\n",
    "files/ws.orb": "fn main() -> int {\n    return 0   \n}\n",
    "cleandir/clean.orb": "fn main() -> int {\n    return 0\n}\n",
    "tiny.orb": "fn main() -> int {\n    return 0\n}\n",
    # `orbit run` with a path that names a directory: cmd.exe reads a quoted
    # forward-slash path as a command named after its first segment, so the
    # child never started and the error named the directory instead.
    "sub/tiny.orb": "fn main() -> int {\n    print(\"ran from a subdir\")\n    return 0\n}\n",
    # Resolved through ORBIT_STD_DIR: the compiler binary lives outside the
    # tree and the working directory carries no std/.
    "stdimport/probe.orb": "import \"std/string/string.orb\"\n\nfn main() -> int {\n    return 0\n}\n",
    # Two independent services in one directory: the same route in each is two
    # programs' routes, not one program's duplicate.
    "services/health_a.orb": "route GET \"/health\" {\n    return ok { status: \"a\" }\n}\n\nfn main() -> int {\n    return 0\n}\n",
    "services/health_b.orb": "route GET \"/health\" {\n    return ok { status: \"b\" }\n}\n\nfn main() -> int {\n    return 0\n}\n",
    # One program across two files: the import edge makes the duplicate real.
    "mergesvc/lib.orb": "route GET \"/items\" {\n    return ok { status: \"lib\" }\n}\n",
    "mergesvc/app.orb": "import \"lib.orb\"\n\nroute GET \"/items\" {\n    return ok { status: \"app\" }\n}\n\nfn main() -> int {\n    return 0\n}\n",
    # `orbit migrate` runs the migration block without serving.
    "mig/app.orb": "migrations \"CREATE TABLE IF NOT EXISTS mig_probe (x INTEGER)\"\nmigrations down \"DROP TABLE IF EXISTS mig_probe\"\n\nfn main() -> int {\n    return 0\n}\n",
    # A dot-directory is tool state, not source: the unparseable file inside
    # .orbit must not be scanned, which is what keeps `doctor .` finite.
    "state/ok.orb": "fn main() -> int {\n    return 0\n}\n",
    # A directory git already ignores is not source: doctor must not scan it.
    "skiproot/.gitignore": "generated/\n",
    "skiproot/ok.orb": "fn main() -> int {\n    return 0\n}\n",
    "skiproot/generated/bad.orb": "this is not orbit source\n",
    # The positive control: an un-ignored broken file is still reported.
    "keeproot/.gitignore": "elsewhere/\n",
    "keeproot/broken.orb": "this is not orbit source\n",
    "state/.orbit/generated.orb": "this is not orbit source\n",
    # Two functions nothing reaches: `orphan` is never called and `orphan_helper`
    # is called only by it. `build --verbose` counts them as dropped.
    "prune/orphans.orb": "fn leaf() -> int {\n    return 1\n}\n\nfn used() -> int {\n    return leaf()\n}\n\nfn orphan() -> int {\n    return 2\n}\n\nfn orphan_helper() -> int {\n    return orphan()\n}\n\nfn main() -> int {\n    return used()\n}\n",
    # `inc` is reached only through a function value, which is not a call.
    "prune/fn_value.orb": "fn inc(x: int) -> int {\n    return x + 1\n}\n\nfn main() -> int {\n    val f = inc\n    return f(1)\n}\n",
    # Unparseable on purpose: `orbit fmt` must refuse it and leave it alone.
    "fmt/broken.orb": "fn main() -> int {\n    val =\n}\n",
    # Parseable but badly formatted: `orbit fmt` must rewrite it.
    "fmt/messy.orb": "fn main( )->int{return 0}\n",
    # Whitespace only: no tokens, so normalising to empty is correct.
    "fmt/blank.orb": "   \n\n  \n",
    # A program that fails `orbit check`. Diagnostics go to stderr and never to
    # stdout, so a script reading stdout sees only real output and artifacts
    # (see stderr-diagnostics).
    "reserved/read.orb": "fn main() -> int {\n    return missing_name\n}\n",
    # A function named after a C library symbol. The backend emits every user
    # symbol under the `o_` prefix, so this builds like any other program.
    "reserved/safe.orb": "fn read(text: string) -> int {\n    return text.len()\n}\n\nfn main() -> int {\n    return read(\"hi\")\n}\n",
    # The runtime's `orbit_` prefix and a C type name as a model: both are
    # ordinary user names now.
    "reserved/prefix.orb": "fn orbit_my_helper(x: int) -> int {\n    return x + 1\n}\n\nfn main() -> int {\n    return orbit_my_helper(1)\n}\n",
    "reserved/model_c_type.orb": "model FILE {\n    x: int\n}\n\nfn main() -> int {\n    val f = FILE(1)\n    return f.x\n}\n",
    # `extern fn` is how the compiler itself reaches the runtime, so the
    # prefix reservation must not fire on declarations. Check-only: there is
    # no such C symbol to link against.
    "reserved/extern_prefix.orb": "extern fn orbit_absent_symbol(x: int) -> int\n\nfn main() -> int {\n    return 0\n}\n",
}

CASES = [
    # (name, argv, exp_rc, stream, needle, absent)
    # stream: "out" (stdout), "err" (stderr), "any"; needle "" skips match.
    # absent: text that must NOT appear on either stream ("" skips), or scoped
    #   to one stream as "out:<text>" / "err:<text>".
    ("help", ["--help"], 0, "out", "Usage:", ""),
    # The native backend exists on Windows only. On a POSIX host the contract
    # is the platform refusal, which fires before any r6 is inspected.
    ("native-r6-no-answer", ["build", "tiny.orb", "-o", "t.exe", "--backend=native"], 1, "err",
     "did not answer `--version`" if os.name == "nt" else "targets Windows x86-64 only", "",
     {"ORBIT_R6": "./r6_silent.cmd"}),
    ("native-r6-wrong-protocol", ["build", "tiny.orb", "-o", "t.exe", "--backend=native"], 1, "err",
     "ir-protocol 99" if os.name == "nt" else "targets Windows x86-64 only", "",
     {"ORBIT_R6": "./r6_other.cmd"}),
    ("help-short", ["-h"], 0, "out", "Usage:", ""),
    ("version", ["--version"], 0, "out", "orbit 0.1.0", ""),
    ("unknown-cmd", ["frobnicate"], 2, "err", "Usage:", ""),
    ("unknown-flag", ["--badflag"], 2, "err", "Usage:", ""),
    ("build-noarg", ["build"], 2, "err", "Usage:", ""),
    ("build-missing", ["build", "nope.orb"], 1, "err", "orbit build:", ""),
    ("build-missing-plain", ["nope.orb"], 1, "err", "orbit build:", ""),
    ("build-quiet", ["build", "--quiet", "tiny.orb", "-o", "tq.exe"], 0, "out", "", "wrote "),
    # The runtime headers are found through ORBIT_RUNTIME_DIR when neither the
    # compiler's directory nor the working directory carries them. A named
    # directory with no headers is refused before cc runs, so the message names
    # the variable instead of a missing C include.
    ("runtime-dir-named", ["build", "--backend=c", "tiny.orb", "-o", "rt.exe"], 0, "out", "", "",
     {"ORBIT_RUNTIME_DIR": os.path.join(ROOT, "runtime")}),
    ("runtime-dir-missing", ["build", "--backend=c", "tiny.orb", "-o", "rm.exe"], 1, "err",
     "holds no runtime headers", "this one is on me",
     {"ORBIT_RUNTIME_DIR": "missing_runtime"}),
    ("build-verbose", ["build", "--verbose", "tiny.orb", "-o", "tv.exe"], 0, "out", "wrote ", ""),
    ("build-prune-drops-orphans", ["build", "--verbose", "prune/orphans.orb", "-o", "po.exe"], 0, "out", "prune: 2 unreachable functions dropped", ""),
    ("build-prune-keeps-called", ["build", "--verbose", "tiny.orb", "-o", "pt.exe"], 0, "out", "prune: 0 unreachable functions dropped", ""),
    ("build-prune-keeps-fn-value", ["build", "--verbose", "prune/fn_value.orb", "-o", "pv.exe"], 0, "out", "prune: 0 unreachable functions dropped", ""),
    ("check-noarg", ["check"], 2, "err", "Usage:", ""),
    ("check-missing", ["check", "nope.orb"], 1, "err", "orbit check:", ""),
    ("check-quiet", ["check", "--quiet", "tiny.orb"], 0, "out", "", "Checked"),
    ("check-std-dir-named", ["check", "stdimport/probe.orb"], 0, "out", "no errors", "",
     {"ORBIT_STD_DIR": ROOT}),
    ("check-verbose", ["check", "--verbose", "tiny.orb"], 0, "out", "check tiny.orb", ""),
    ("run-noarg", ["run"], 2, "err", "Usage:", ""),
    ("run-missing", ["run", "nope.orb"], 1, "err", "orbit run:", ""),
    ("run-subdir", ["run", "--backend=c", "sub/tiny.orb"], 0, "out", "ran from a subdir", ""),
    ("migrate-noarg", ["migrate"], 2, "err", "Usage:", ""),
    ("migrate-help", ["migrate", "--help"], 0, "out", "Usage:", ""),
    ("migrate-missing", ["migrate", "nope.orb"], 1, "err", "orbit migrate:", ""),
    # The child links SQLite's import library, and the DLL lives in the vendor
    # directory; PATH carries it so the case does not depend on where the
    # compiler under test sits.
    ("migrate-applies", ["migrate", "mig/app.orb"], 0, "out", "migrations applied", "",
     {"PATH": os.path.join(ROOT, "runtime", "vendor", "win-x64") + os.pathsep + os.environ.get("PATH", "")}),
    # `print` lowers in the TIR path now (tests/frontend/print_pipeline.orb),
    # so the command emits TIR for a program that uses it.
    ("frontend-print", ["frontend", "sub/tiny.orb", "-o", "tiny.tir"], 0, "out", "",
     "diagnostics contain errors"),
    ("fmt-noarg", ["fmt"], 2, "err", "Usage:", ""),
    ("fmt-help", ["fmt", "--help"], 0, "out", "Usage:", ""),
    ("fmt-missing", ["fmt", "nope.orb"], 1, "err", "orbit fmt:", ""),
    ("fmt-quiet", ["fmt", "--quiet", "files/case.orb"], 0, "out", "", "Formatted"),
    ("fmt-check-verbose", ["fmt", "--check", "files", "--verbose"], 1, "out", "scanned", ""),
    ("fmt-check-quiet", ["fmt", "--check", "files", "--quiet"], 1, "out", "", "files/ws.orb"),
    ("doctor-help", ["doctor", "--help"], 0, "out", "Usage:", ""),
    ("doctor-badflag", ["doctor", "--bogus"], 2, "err", "Usage:", ""),
    ("doctor-quiet-clean", ["doctor", "--quiet", "cleandir"], 0, "out", "", "no findings"),
    # D002 is scoped to a program: two independent services may both serve
    # GET /health, and one program that imports a route file may not.
    ("doctor-separate-programs", ["doctor", "--color", "never", "services"], 0, "out", "", "D002"),
    ("doctor-one-program", ["doctor", "--color", "never", "mergesvc"], 1, "out", "duplicate route GET /items", ""),
    ("doctor-skips-tool-state", ["doctor", "--color", "never", "state"], 0, "out", "no findings", "D008"),
    ("doctor-skips-gitignored", ["doctor", "--color", "never", "skiproot"], 0, "out", "no findings", "D008"),
    ("doctor-reads-unignored", ["doctor", "--color", "never", "keeproot"], 1, "out", "D008", ""),
    ("doctor-verbose", ["doctor", "--verbose", "cleandir"], 0, "out", "scanned", ""),
    ("doctor-json", ["doctor", "--format", "json", "files"], 1, "out", '"code"', ""),
    ("doctor-format-bad", ["doctor", "--format", "xml", "files"], 2, "err", "Usage:", ""),
    ("doctor-color-always", ["doctor", "--color", "always", "files"], 1, "out", "\x1b[", ""),
    ("doctor-color-never", ["doctor", "--color", "never", "files"], 1, "out", "warning [D006]", "\x1b["),
    ("doctor-color-bad", ["doctor", "--color", "maybe", "files"], 2, "err", "Usage:", ""),
    ("build-color-always", ["build", "--color", "always", "tiny.orb", "-o", "tc.exe"], 0, "out", "\x1b[", ""),
    ("build-color-never", ["build", "--color", "never", "tiny.orb", "-o", "tn.exe"], 0, "out", "wrote ", "\x1b["),
    ("check-color-always", ["check", "--color", "always", "reserved/read.orb"], 1, "err", "\x1b[31m", ""),
    ("check-color-never", ["check", "--color", "never", "reserved/read.orb"], 1, "err", "missing_name", "\x1b["),
    ("cluster-noarg", ["cluster"], 2, "err", "Usage:", ""),
    ("cluster-help", ["cluster", "--help"], 0, "out", "Usage:", ""),
    ("cluster-bogus", ["cluster", "bogus"], 2, "err", "unknown command", ""),
    ("cluster-status-nostate", ["cluster", "status"], 1, "out", "no state file", ""),
    ("frontend-noarg", ["frontend"], 2, "err", "Usage:", ""),
    # A function named after a C library symbol is an ordinary name: the
    # backend emits it as `o_read`, so neither check nor build refuses it.
    ("c-name-user-fn-check", ["check", "reserved/safe.orb"], 0, "out",
     "no errors", "Semantic error"),
    ("c-name-user-fn-builds", ["build", "--quiet", "reserved/safe.orb", "-o", "s.exe"], 0, "out",
     "", "Semantic error"),
    # stderr-diagnostics: stdout must stay clean when a check fails, so anything reading only
    # stdout cannot mistake a failed check for a successful one.
    ("check-failure-keeps-stdout-clean", ["check", "reserved/read.orb"], 1, "out",
     "", "out:Semantic error"),
    ("orbit-prefix-allowed", ["check", "reserved/prefix.orb"], 0, "out",
     "no errors", "Semantic error"),
    ("c-type-model-allowed", ["check", "reserved/model_c_type.orb"], 0, "out",
     "no errors", "Semantic error"),
    ("extern-prefix-allowed", ["check", "reserved/extern_prefix.orb"], 0, "out",
     "no errors", "Semantic error"),
    # A C toolchain that is not installed is the one build failure the compiler
    # may diagnose itself, and it has to keep saying so: the wording is what
    # tells the user to set ORBIT_CC instead of filing a bug.
    ("cc-absent-names-the-toolchain",
     ["build", "tiny.orb", "-o", "x.exe"], 1, "err", "was not found", "",
     {"ORBIT_CC": "orbit-no-such-c-compiler"}),
    # Bare `orbit` with no args prints the short help plus next steps on
    # stdout and exits 0, instead of the build usage on stderr.
    ("bare-noarg", [], 0, "out", "Usage:", ""),
    # `orbit start` builds into .orbit/ and runs: help exits 0, a missing
    # input is an operational error (exit 1), and with no file it looks for
    # main.orb, which the empty probe dir does not have.
    ("start-help", ["start", "--help"], 0, "out", "Usage:", ""),
    ("start-missing", ["start", "nope.orb"], 1, "err", "orbit start:", ""),
    ("start-no-main", ["start"], 1, "err", "orbit start:", ""),
    ("start-badflag", ["start", "--bogus"], 2, "err", "Usage:", ""),
    ("dev-help", ["dev", "--help"], 0, "out", "Usage:", ""),
    ("dev-missing", ["dev", "nope.orb"], 1, "err", "orbit dev:", ""),
    # `orbit stop` ends the service recorded in .orbit/start.pid and is
    # idempotent: with no record the probe dir has nothing to stop, exit 0.
    ("stop-help", ["stop", "--help"], 0, "out", "Usage:", ""),
    ("stop-no-server", ["stop"], 0, "out", "no server running", ""),
    ("stop-badflag", ["stop", "--bogus"], 2, "err", "Usage:", ""),
]

# The not-found wording is not unique to a missing toolchain: clang reports a
# missing include as `'<header>' file not found`, so substring-matching the
# compiler's output turned a wrong -I path into "your C compiler was not
# found" and hid the real error behind a fix that could not help. Only clang
# phrases it that way -- gcc says "No such file or directory" -- so the case is
# skipped where clang is absent rather than asserted against the wrong wording.
#
# The probe runs in an empty work directory, so the runtime include path does
# not resolve there and the C step fails on socket_compat.h for any compiler.
TOOLCHAIN_CASES = [
    ("cc-include-failure-is-not-a-missing-toolchain",
     ["build", "tiny.orb", "-o", "y.exe"], 1, "err",
     "the C compiler rejected my output", "was not found",
     {"ORBIT_CC": "clang", "ORBIT_CCFLAGS_EXTRA": ""}),
]

# Invariants that are about the tool's effect on disk rather than its exit
# code. These run after the CASES table because each one needs a post-condition
# on a file, not just a stream check.
#
# fmt-no-clobber-* guard the worst failure mode in the CLI: `orbit fmt` opening
# its input for writing truncates it before anything can fail, so any internal
# error after that point used to leave a 0-byte source file behind a success
# message. The contract is that a file is either rewritten completely or left
# byte-identical.
#
# outcome is one of:
#   "unchanged"  the file must be byte-identical afterwards
#   "rewritten"  the file must change, and must not end up empty
#   "emptied"    the file must become empty, which is only correct for a source
#                that holds no tokens at all
INVARIANTS = [
    ("fmt-no-clobber-parse-error",
     ["fmt", "fmt/broken.orb"], "fmt/broken.orb", 1, "left unchanged", "unchanged"),
    ("fmt-no-clobber-parse-error-quiet",
     ["fmt", "--quiet", "fmt/broken.orb"], "fmt/broken.orb", 1, "", "unchanged"),
    ("fmt-no-clobber-formats-ok",
     ["fmt", "fmt/messy.orb"], "fmt/messy.orb", 0, "Formatted", "rewritten"),
    # A whitespace-only file normalising to an empty file is intended, not data
    # loss: it has no tokens. Pinned so the distinction in fmtSourceIsBlank
    # cannot be quietly inverted.
    ("fmt-blank-normalises-to-empty",
     ["fmt", "fmt/blank.orb"], "fmt/blank.orb", 0, "Formatted", "emptied"),
]


# Which runtime link the C step chooses when ORBIT_LINK_RUNTIME is not set.
# Each case stages its own `runtime/` (a copy of the repo's .c and .h files) and
# `.orbit/lib/` beside it, with a stub archive and the stamp mklib_runtime.py
# would write, and reads the cc line from `build --verbose`. The C compiler is a
# no-op, so no archive is ever linked.
#   name, how the stage differs from a fresh archive, ORBIT_LINK_RUNTIME,
#   needle that must be on stdout, text that must not be.
LINK_FLAG = "-DORBIT_SEPARATE_COMPILATION"
LINK_CASES = [
    ("link-default-fresh-archive", "fresh", None, LINK_FLAG, ""),
    ("link-default-stale-archive", "stale", None, "does not match", LINK_FLAG),
    # A partial checkout shared between Windows and a POSIX host: the archive
    # was built for the other one, so it must fall to the unity build rather
    # than hand MinGW objects to the host linker.
    ("link-default-other-platform", "other-platform", None, "does not match", LINK_FLAG),
    ("link-default-unstamped-archive", "unstamped", None, "", LINK_FLAG),
    ("link-default-no-archive", "missing", None, "", LINK_FLAG),
    ("link-zero-forces-unity", "fresh", "0", "", LINK_FLAG),
    ("link-one-forces-link", "missing", "1", LINK_FLAG, ""),
]


def link_default_cases(compiler, work):
    """The runtime link the C step picks by default. Returns (ok, total)."""
    import mklib_runtime
    noop_cc = "cmd /c exit 0" if os.name == "nt" else "true"
    ok = 0
    for name, stage_kind, mode, needle, absent in LINK_CASES:
        stage = os.path.join(work, "case_" + name)
        os.makedirs(stage, exist_ok=True)
        setup_dir(stage)
        stage_runtime = os.path.join(stage, "runtime")
        os.makedirs(stage_runtime, exist_ok=True)
        for item in os.listdir(os.path.join(ROOT, "runtime")):
            if item.endswith((".c", ".h")) and not item.startswith("test_"):
                shutil.copy(os.path.join(ROOT, "runtime", item), stage_runtime)
        shutil.copytree(os.path.join(ROOT, "runtime", "gen"),
                        os.path.join(stage_runtime, "gen"), dirs_exist_ok=True)
        if stage_kind != "missing":
            lib_dir = os.path.join(stage, ".orbit", "lib")
            os.makedirs(lib_dir, exist_ok=True)
            archive = os.path.join(lib_dir, "libruntime_net.a")
            with open(archive, "wb") as f:
                f.write(b"!<arch>\n")
            if stage_kind != "unstamped":
                stamp_text = mklib_runtime.runtime_stamp(stage_runtime)
                if stage_kind == "other-platform":
                    here = mklib_runtime.platform_tag()
                    other = "unix" if here == "windows" else "windows"
                    stamp_text = stamp_text.replace(
                        "platform " + here, "platform " + other)
                with open(archive + ".stamp", "wb") as f:
                    f.write(stamp_text.encode("utf-8"))
            if stage_kind == "stale":
                with open(os.path.join(stage_runtime, "arena.c"), "ab") as f:
                    f.write(b"\n")
        env = dict(os.environ)
        for var in ("ORBIT_LINK_RUNTIME", "ORBIT_RUNTIME_LIB",
                    "ORBIT_CCFLAGS_EXTRA"):
            env.pop(var, None)
        env.update({"ORBIT_CC": noop_cc, "CC": noop_cc, "TEMP": stage,
                    "TMP": stage, "ORBIT_SKIP_WINDRES": "1"})
        if mode is not None:
            env["ORBIT_LINK_RUNTIME"] = mode
        p = subprocess.run([compiler, "build", "--verbose", "tiny.orb",
                            "-o", "t.exe"], cwd=stage, capture_output=True,
                           text=True, errors="replace", env=env)
        good = (p.returncode == 0 and needle in p.stdout and
                (not absent or absent not in p.stdout))
        if good:
            out.say(f"Probing {name} ... ok")
            ok += 1
        else:
            out.fail(f"Failed {name}: rc={p.returncode}")
            print("  out: %r" % p.stdout.strip()[:300], file=sys.stderr)
            print("  err: %r" % p.stderr.strip()[:200], file=sys.stderr)
    return (ok, len(LINK_CASES))


def setup_dir(work):
    """Write the probe fixtures into one (per-case) stage directory."""
    for rel, content in SETUP.items():
        dest = os.path.join(work, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)


def invariants(compiler, work):
    """Post-conditions on files the tool touched. Returns (ok, total)."""
    jobs = list(range(len(INVARIANTS)))

    def run_one(idx):
        # Each invariant owns a staged dir: fmt rewrites its input in place,
        # so a shared work dir lets one case format another's fixture, and
        # each build writes orbit_selfhost_build.c to TEMP. Returns
        # (name, ok, so, se) for ordered reporting below; only the main
        # thread prints.
        name, argv, rel, exp_rc, needle, outcome = INVARIANTS[idx]
        stage = os.path.join(work, "inv_" + name.replace("/", "_"))
        os.makedirs(stage, exist_ok=True)
        setup_dir(stage)
        ok, so, se, problems = check_invariant(compiler, stage, name, argv, rel,
                                               exp_rc, needle, outcome)
        return (name, ok, so, se, problems)

    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        results = list(pool.map(run_one, jobs))
    ok = 0
    for name, good, so, se, problems in results:
        if good:
            out.say("Probing %s ... ok" % name)
            ok += 1
        else:
            out.fail("Failed %s: %s" % (name, problems))
            if so.strip():
                print("  out: %r" % so.strip()[:200], file=sys.stderr)
            if se.strip():
                print("  err: %r" % se.strip()[:200], file=sys.stderr)
    return ok, len(INVARIANTS)


def check_invariant(compiler, work, name, argv, rel, exp_rc, needle, outcome):
    """One file post-condition. Returns (ok, stdout, stderr, problems)."""
    env = dict(os.environ)
    env["ORBIT_RUNTIME_DIR"] = os.path.join(ROOT, "runtime")
    env["TEMP"] = work
    env["TMP"] = work
    target = os.path.join(work, rel)
    with open(target, "rb") as f:
        before = f.read()
    p = subprocess.run([compiler] + argv, cwd=work, capture_output=True,
                       text=True, errors="replace", env=env)
    so, se = p.stdout or "", p.stderr or ""
    combined = so + se
    with open(target, "rb") as f:
        after = f.read()
    problems = []
    if p.returncode != exp_rc:
        problems.append("rc=%s (want %s)" % (p.returncode, exp_rc))
    if needle and needle not in combined:
        problems.append("missing %r" % needle)
    if outcome == "unchanged" and after != before:
        if after == b"" and before != b"":
            problems.append("FILE EMPTIED (was %d bytes)" % len(before))
        else:
            problems.append("file changed but should not have")
    elif outcome == "rewritten":
        if after == b"" and before != b"":
            problems.append("FILE EMPTIED (was %d bytes)" % len(before))
        elif after == before:
            problems.append("file unchanged but should have been formatted")
    elif outcome == "emptied" and after != b"":
        problems.append("file should have normalised to empty, got %d bytes" % len(after))
    if problems:
        return (False, so, se, "; ".join(problems))
    return (True, so, se, "")


def one(compiler, work, name, argv, exp_rc, stream, needle, absent="", env_extra=None):
    ok, so, se, rc = probe(compiler, work, name, argv, exp_rc, stream, needle,
                           absent, env_extra)
    if ok:
        out.say(f"Probing {name} ... ok")
    else:
        out.fail(f"Failed {name}: rc={rc} (want {exp_rc})")
        if so.strip():
            print("  out: %r" % so.strip()[:200], file=sys.stderr)
        if se.strip():
            print("  err: %r" % se.strip()[:200], file=sys.stderr)
    return ok


def probe(compiler, work, name, argv, exp_rc, stream, needle, absent="",
          env_extra=None):
    """One CLI case. Returns (ok, stdout, stderr); no printing.

    Each caller hands this its own stage dir as `work`: builds write
    orbit_selfhost_build.c to TEMP, so a shared TEMP lets one case's cc read
    another's half-written C, and several cases build outputs (-o *.exe)
    that must not share a cwd while another case mutates it.
    """
    env = dict(os.environ)
    # Build cases need the runtime headers; the probe binary lives in a
    # temp directory, so name the repo runtime explicitly.
    env["ORBIT_RUNTIME_DIR"] = os.path.join(ROOT, "runtime")
    env["TEMP"] = work
    env["TMP"] = work
    env.update(env_extra or {})
    p = subprocess.run([compiler] + argv, cwd=work, capture_output=True,
                       text=True, errors="replace", env=env)
    so, se = p.stdout or "", p.stderr or ""
    if stream == "out":
        ok_stream = (not needle) or (needle in so)
    elif stream == "err":
        ok_stream = (not needle) or (needle in se)
    else:
        ok_stream = (not needle) or (needle in (so + se))
    # `absent` is scoped to one stream when written "out:<text>" / "err:<text>";
    # bare text means it must not appear on either. This is what lets a case
    # assert that stdout stays clean while the same text is on stderr.
    if absent.startswith("out:"):
        ok_absent = absent[4:] not in so
    elif absent.startswith("err:"):
        ok_absent = absent[4:] not in se
    else:
        ok_absent = (not absent) or (absent not in so and absent not in se)
    ok_json = True
    if name == "doctor-json" and p.returncode == 1:
        import json as _json
        # The original six keys are a contract an editor may already depend on,
        # so they are required to be PRESENT rather than to be the whole object:
        # the newer keys are additive and a consumer that breaks on them is the
        # thing this assertion exists to catch.
        base_keys = {"file", "line", "code", "severity", "message", "fix"}
        added_keys = {"column", "layer", "fix_kind", "applied", "edits"}
        try:
            rows = _json.loads(so)
            ok_json = (isinstance(rows, list) and len(rows) >= 1 and
                       all(base_keys <= set(r) for r in rows) and
                       all(added_keys <= set(r) for r in rows) and
                       all(isinstance(r["column"], int) and
                           isinstance(r["edits"], list) and
                           isinstance(r["applied"], str) for r in rows))
        except Exception:
            ok_json = False
    ok = (p.returncode == exp_rc) and ok_stream and ok_absent and ok_json
    return (ok, so, se, p.returncode)


def main():
    ap = argparse.ArgumentParser(description="Probe the orbit CLI contract")
    ap.add_argument("--compiler", default=None)
    ap.add_argument("--work", default=None)
    ap.add_argument("--specimen", action="store_true",
                    help="print the static output-grammar specimen and exit")
    args = ap.parse_args()
    if args.specimen:
        print(SPECIMEN, end="")
        return 0
    if not args.compiler:
        ap.error("--compiler is required unless --specimen is given")
    work = os.path.abspath(args.work) if args.work else tempfile.mkdtemp(prefix="orbit_cli_")
    os.makedirs(work, exist_ok=True)

    def run_one(case):
        # Each case owns a staged dir: fmt/build cases read and write files
        # by relative path, so a shared work dir lets one case see another's
        # outputs, and each build writes orbit_selfhost_build.c to TEMP.
        # Returns (name, exp_rc, ok, so, se, rc) for ordered reporting below;
        # only the main thread prints.
        name, argv, exp_rc, stream, needle = case[:5]
        absent = case[5] if len(case) > 5 else ""
        env_extra = case[6] if len(case) > 6 else None
        stage = os.path.join(work, "case_" + name.replace("/", "_"))
        os.makedirs(stage, exist_ok=True)
        setup_dir(stage)
        ok, so, se, rc = probe(args.compiler, stage, name, argv, exp_rc,
                               stream, needle, absent, env_extra)
        return (name, exp_rc, ok, so, se, rc)

    def report(name, exp_rc, ok, so, se, rc):
        if ok:
            out.say(f"Probing {name} ... ok")
        else:
            out.fail(f"Failed {name}: rc={rc} (want {exp_rc})")
            if so.strip():
                print("  out: %r" % so.strip()[:200], file=sys.stderr)
            if se.strip():
                print("  err: %r" % se.strip()[:200], file=sys.stderr)
        return ok

    ok = 0
    total = len(CASES)
    with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        results = list(pool.map(run_one, CASES))
    for name, exp_rc, good, so, se, rc in results:
        if report(name, exp_rc, good, so, se, rc):
            ok += 1
    if shutil.which("clang"):
        with ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
            tc_results = list(pool.map(run_one, TOOLCHAIN_CASES))
        for name, exp_rc, good, so, se, rc in tc_results:
            if report(name, exp_rc, good, so, se, rc):
                ok += 1
            total += 1
    else:
        out.say("Skipping clang toolchain cases: clang is not installed")
    inv_ok, inv_total = invariants(args.compiler, work)
    ok += inv_ok
    total += inv_total
    link_ok, link_total = link_default_cases(args.compiler, work)
    ok += link_ok
    total += link_total
    out.finish("cli-probe", ok, total)
    return 0 if ok == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
