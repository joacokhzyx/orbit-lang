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
    "files/case.orb": "fn main() -> int {\nreturn 0\n}\n",
    "files/clean.orb": "fn main() -> int {\n    return 0\n}\n",
    "files/ws.orb": "fn main() -> int {\n    return 0   \n}\n",
    "cleandir/clean.orb": "fn main() -> int {\n    return 0\n}\n",
    "tiny.orb": "fn main() -> int {\n    return 0\n}\n",
    # Unparseable on purpose: `orbit fmt` must refuse it and leave it alone.
    "fmt/broken.orb": "fn main() -> int {\n    val =\n}\n",
    # Parseable but badly formatted: `orbit fmt` must rewrite it.
    "fmt/messy.orb": "fn main( )->int{return 0}\n",
    # Whitespace only: no tokens, so normalising to empty is correct.
    "fmt/blank.orb": "   \n\n  \n",
    # A function named after a C library symbol. `orbit check` and `orbit build`
    # both report this on stderr: diagnostics never go to stdout, so a script
    # reading stdout sees only real output and artifacts (see stderr-diagnostics).
    "reserved/read.orb": "fn read(text: string) -> int {\n    return text.len()\n}\n\nfn main() -> int {\n    return read(\"hi\")\n}\n",
    # The same program with a safe name, which must still build.
    "reserved/safe.orb": "fn user_read(text: string) -> int {\n    return text.len()\n}\n\nfn main() -> int {\n    return user_read(\"hi\")\n}\n",
    # `orbit_` is the runtime's prefix. Reusing it passed `orbit check` and
    # then failed as a C signature conflict against a runtime function.
    "reserved/prefix.orb": "fn orbit_my_helper(x: int) -> int {\n    return x + 1\n}\n\nfn main() -> int {\n    return orbit_my_helper(1)\n}\n",
    # A model becomes a C struct under the user's name, so a C type name
    # collided at C compile time with nothing pointing back at the model.
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
    ("help-short", ["-h"], 0, "out", "Usage:", ""),
    ("version", ["--version"], 0, "out", "orbit 0.1.0-rc.2", ""),
    ("unknown-cmd", ["frobnicate"], 2, "err", "Usage:", ""),
    ("unknown-flag", ["--badflag"], 2, "err", "Usage:", ""),
    ("build-noarg", ["build"], 2, "err", "Usage:", ""),
    ("build-missing", ["build", "nope.orb"], 1, "err", "orbit build:", ""),
    ("build-missing-plain", ["nope.orb"], 1, "err", "orbit build:", ""),
    ("build-quiet", ["build", "--quiet", "tiny.orb", "-o", "tq.exe"], 0, "out", "", "wrote "),
    ("build-verbose", ["build", "--verbose", "tiny.orb", "-o", "tv.exe"], 0, "out", "wrote ", ""),
    ("check-noarg", ["check"], 2, "err", "Usage:", ""),
    ("check-missing", ["check", "nope.orb"], 1, "err", "orbit check:", ""),
    ("check-quiet", ["check", "--quiet", "tiny.orb"], 0, "out", "", "Checked"),
    ("check-verbose", ["check", "--verbose", "tiny.orb"], 0, "out", "check tiny.orb", ""),
    ("run-noarg", ["run"], 2, "err", "Usage:", ""),
    ("run-missing", ["run", "nope.orb"], 1, "err", "orbit run:", ""),
    ("fmt-noarg", ["fmt"], 2, "err", "Usage:", ""),
    ("fmt-help", ["fmt", "--help"], 0, "out", "Usage:", ""),
    ("fmt-missing", ["fmt", "nope.orb"], 1, "err", "orbit fmt:", ""),
    ("fmt-quiet", ["fmt", "--quiet", "files/case.orb"], 0, "out", "", "Formatted"),
    ("fmt-check-verbose", ["fmt", "--check", "files", "--verbose"], 1, "out", "scanned", ""),
    ("fmt-check-quiet", ["fmt", "--check", "files", "--quiet"], 1, "out", "", "files/ws.orb"),
    ("doctor-help", ["doctor", "--help"], 0, "out", "Usage:", ""),
    ("doctor-badflag", ["doctor", "--bogus"], 2, "err", "Usage:", ""),
    ("doctor-quiet-clean", ["doctor", "--quiet", "cleandir"], 0, "out", "", "no findings"),
    ("doctor-verbose", ["doctor", "--verbose", "cleandir"], 0, "out", "scanned", ""),
    ("doctor-json", ["doctor", "--format", "json", "files"], 1, "out", '"code"', ""),
    ("doctor-format-bad", ["doctor", "--format", "xml", "files"], 2, "err", "Usage:", ""),
    ("doctor-color-always", ["doctor", "--color", "always", "files"], 1, "out", "\x1b[", ""),
    ("doctor-color-never", ["doctor", "--color", "never", "files"], 1, "out", "warning [D006]", "\x1b["),
    ("doctor-color-bad", ["doctor", "--color", "maybe", "files"], 2, "err", "Usage:", ""),
    ("build-color-always", ["build", "--color", "always", "tiny.orb", "-o", "tc.exe"], 0, "out", "\x1b[", ""),
    ("build-color-never", ["build", "--color", "never", "tiny.orb", "-o", "tn.exe"], 0, "out", "wrote ", "\x1b["),
    ("check-color-always", ["check", "--color", "always", "reserved/read.orb"], 1, "err", "\x1b[31m", ""),
    ("check-color-never", ["check", "--color", "never", "reserved/read.orb"], 1, "err", "C library function name", "\x1b["),
    ("cluster-noarg", ["cluster"], 2, "err", "Usage:", ""),
    ("cluster-help", ["cluster", "--help"], 0, "out", "Usage:", ""),
    ("cluster-bogus", ["cluster", "bogus"], 2, "err", "unknown command", ""),
    ("cluster-status-nostate", ["cluster", "status"], 1, "out", "no state file", ""),
    ("frontend-noarg", ["frontend"], 2, "err", "Usage:", ""),
    # A function name that collides with a C library symbol must be refused by
    # the front end, with a diagnostic that names the collision and suggests a
    # rename. Previously this reached the C toolchain as "conflicting types for
    # 'read'" or a link error, with nothing in the Orbit output explaining it.
    ("reserved-name-check", ["check", "reserved/read.orb"], 1, "err",
     "C library function name", ""),
    ("reserved-name-build", ["build", "reserved/read.orb", "-o", "r.exe"], 1, "err",
     "C library function name", ""),
    ("reserved-name-suggests-rename", ["check", "reserved/read.orb"], 1, "err",
     "user_read", ""),
    # stderr-diagnostics: stdout must stay clean when a check fails, so anything reading only
    # stdout cannot mistake a failed check for a successful one.
    ("check-failure-keeps-stdout-clean", ["check", "reserved/read.orb"], 1, "out",
     "", "out:Semantic error"),
    ("orbit-prefix-rejected", ["check", "reserved/prefix.orb"], 1, "err",
     "reserved for the runtime", ""),
    ("c-type-model-rejected", ["check", "reserved/model_c_type.orb"], 1, "err",
     "is a C type name", ""),
    ("extern-prefix-allowed", ["check", "reserved/extern_prefix.orb"], 0, "out",
     "no errors", "Semantic error"),
    ("reserved-name-safe-still-builds", ["build", "--quiet", "reserved/safe.orb", "-o", "s.exe"], 0, "out", "", "Semantic error"),
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
    env["ORBIT_CCFLAGS_EXTRA"] = '-I"%s"' % os.path.join(ROOT, "runtime")
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
    # temp dir, so point the inner cc at the repo runtime explicitly.
    env["ORBIT_CCFLAGS_EXTRA"] = '-I"%s"' % os.path.join(ROOT, "runtime")
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
    out.finish("cli-probe", ok, total)
    return 0 if ok == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
