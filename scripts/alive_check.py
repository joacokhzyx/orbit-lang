#!/usr/bin/env python3
"""Aliveness: every tool in scripts/ has to prove it still works (D8).

The incident this exists for: `scripts/unknown_census.orb` carried a stub
`parseIntSelfhost` from before F-0004. The F-0004 fix put the real one in
scope, the probe stopped building, and NOTHING NOTICED, because the census was
report-only and the only symptom was one line on stderr. The census number was
then quoted twice, authoritatively, by a human, without anybody checking that
the thing producing it still ran.

So this is not a test of correctness. Every tool in `scripts/` already has
something that claims to check it, and most of those claims are about the
*language*, not about the tool. This checks EXISTENCE, in four parts per tool:

  1. it runs, and does not crash (no signal death, no Python traceback);
  2. it finishes inside its timeout, so a hang is a failure and not a red job;
  3. it exits with a code in its declared set -- a gate that returns 1 because
     it found a real problem is WORKING, and a gate that returns 139 is not;
  4. its output contains a marker that only appears when it did its actual
     work. This is the part that catches D8: a tool that starts, cannot do the
     work, says so in a sentence, and exits 0 still passes 1-3.

(4) is why the markers are per-tool regexes and not "output is non-empty". A
tool that printed "the probe did not build" has non-empty output, and that is
exactly the failure that reached production here.

Usage:
    python scripts/alive_check.py [--compiler PATH] [--cc CC] [--quick]
                                  [--only NAME]... [--list] [--self-test] [--witness RUNLOG]

`--only` narrows which rows RUN; it is not a coverage mode. The D8 coverage
assertion at the end still reads the whole registry, because the invariant it
checks -- one row per file in scripts/ -- is a property of the tree, not of a
run.
`--list` prints the rows that would run and exits: a listing mode, so it runs
none of them and asserts nothing, the shape `dev.py list` has for the tiers.
`--quick` runs only the checks marked cheap (the ones that need no compile).
`--self-test` feeds the checker deliberately broken tools and asserts that each
failure class is caught, which is the only way to know a gate can fail.

Exit code: 0 if every checked tool is alive, 1 otherwise. A tool that cannot be
checked (no compiler) is reported as skipped, loudly, and does not pass
silently.
"""

import argparse
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")

# A tool that died on a signal, or a shell's 128+signal convention.
CRASH_RCS = {132, 133, 134, 135, 136, 137, 139, 3, 4, 5, 6, 7, 8, 11}
TRACEBACK = "Traceback (most recent call last)"

# --witness <runlog> contract with dev.py (agent A owns the writer side).
# A witness row does not re-execute: its closing line must already sit in the
# runlog dev.py wrote this same run (default .orbit/last_run.log). The log is
# "fresh" when its mtime is at most this old; anything older is a stale log
# from a previous run and fails loudly instead of passing quietly. dev.py runs
# its gates and then alive_check back to back, so two hours comfortably covers
# a slow T3 while still catching yesterday's log.
WITNESS_MAX_AGE_SECS = 7200

# Single-census wiring: alive_check runs `unknown_census.py --json` once and
# hands the document to the ratchet via --from-json, instead of the census and
# the ratchet each censusing the corpus. The marker below is checked against
# the census's stdout (pure JSON); the human "Corpus: ..." banner is not
# printed in --json mode.
CENSUS_JSON_MARKER = r'"unknown_instructions"\s*:\s*\d+'
CENSUS_JSON_NAME = "unknown_census.json"


class Tool:
    """One row of the registry: what it is, how to run it, what proves it worked.

    kind is the classification D8 asks for:
      gate       already a CI step that can fail on its own; checked anyway,
                 because a gate that has stopped running is also a gate that
                 cannot fail
      measurement  feeds a gate or a person (the census feeds the ratchet)
      report     nobody consumes it; this check is its ONLY coverage
      live       needs a server that does not exist here; asserted instead to
                 fail CLEANLY, because a probe that hangs or throws a traceback
                 when its target is gone is a probe that cannot be trusted
                 when its target is there
      library    imported, not executed; assert the public surface still exists
      shell      not python; assert it parses and still names files that exist
      static     not a script, but part of a tool: the probe program, the C
                 fixture, the baseline

    witness is None for rows that always re-execute, or a regex that must be
    found in the dev.py runlog when --witness <runlog> is given. A witness row
    is a heavy T1-T3 gate that just ran green moments earlier in the same dev
    run: re-executing it proves nothing new, so the runlog's closing line
    stands in for a fresh run. Cheap rows (quick, self-tests, library/shell/
    static, coverage, routes, dispatch, fuzz, diff_fuzz) have witness None and
    always execute, with or without the flag.
    """

    def __init__(self, name, kind, why, argv, marker=None, timeout=180,
                 allow_rc=(0,), cost="cheap", needs=(), expect_fail=False,
                 witness=None):
        self.name = name
        self.kind = kind
        self.why = why
        self.argv = argv
        self.marker = marker
        self.timeout = timeout
        self.allow_rc = tuple(allow_rc)
        self.cost = cost
        self.needs = tuple(needs)
        # A `live` tool run here is expected to FAIL, because there is no
        # server. Its exit code must be non-zero and its output must say why.
        self.expect_fail = expect_fail
        self.witness = witness


# --------------------------------------------------------------------------
# Helpers for building argv.
# --------------------------------------------------------------------------
def _py(*args):
    return [sys.executable] + list(args)


def _script(name, *args):
    return _py(os.path.join("scripts", name)) + list(args)


def _tmp(work, *parts):
    return os.path.join(work, *parts)


# --------------------------------------------------------------------------
# The registry. One row per file in scripts/, no exceptions.
# --------------------------------------------------------------------------
def registry(compiler, cc, work):
    comp = lambda *extra: ["--compiler", compiler, "--cc", cc] + list(extra)
    tools = [
        # ---- the entry point ------------------------------------------------
        # `dev.py list` is the row, not `dev.py` bare. Bare means "run the tier
        # the working tree implies", which for a clean tree is T0+T1: it builds
        # the fixed point and runs the doctor and CLI gates, which turns a check
        # about this tool into a check about everything else. `list` enumerates
        # the tiers from the real diff and prints them, which is the part of
        # dev.py that can rot on its own -- a tier that stopped being selected,
        # or a gate renamed out from under it.
        Tool("dev.py", "gate",
             "the developer-loop entry point; `list` prints the tiers it "
             "selected from the working tree",
             lambda: _script("dev.py", "list"),
             r"T\d:", 120, allow_rc=(0, 1)),
        # The schema gate. It needs no compiler, which is the point: it compares
        # two files of text, so it runs in a second where a doctor check would
        # cost a bootstrap. `allow_rc=(0, 1)` because it is allowed to report a
        # real disagreement -- that is a finding, not a broken tool.
        Tool("schema_conformance.py", "gate",
             "compiler/front/ast.orb against the code that builds nodes: arity, "
             "phantom models and variants, and a node read with a list operation",
             lambda: _script("schema_conformance.py"),
             r"Finished schema-conformance", 120, allow_rc=(0, 1)),
        # The companion to the corpus: it does not measure visits, it checks that
        # every AST walk in the compiler DECLARES the fields it skips, and that
        # the declaration still matches the arms. A walk that silently stopped
        # reaching a field is invisible everywhere else.
        Tool("walk_coverage.py", "gate",
             "every AST walk in compiler/ declares the fields it skips, and "
             "every declaration matches the arms",
             lambda: _script("walk_coverage.py"),
             r"Finished walk-coverage", 120, allow_rc=(0, 1)),
        # The companion to schema_conformance and walk_coverage for a different
        # kind of stale text: a document's counted claim about the corpus. It
        # reads the tree and the claim and fails when they disagree.
        # `allow_rc=(0, 1)` because a real disagreement is a finding, not a
        # broken tool.
        Tool("doc_counts.py", "gate",
             "every counted claim about the corpus in the docs equals the tree",
             lambda: _script("doc_counts.py"),
             r"Finished doc-counts", 120, allow_rc=(0, 1)),
        # The companion to the three above for a claim one level out: a CLI flag
        # is a promise written in --help, and a promise nothing reads is the
        # quietest failure there is, because the run succeeds and the thing that
        # was asked for did not happen. It found this file's own `--list`, which
        # is why the listing mode above exists and why nothing caught it sooner.
        Tool("flag_coverage.py", "gate",
             "every flag a script in scripts/ declares is read by the script "
             "that owns it, or carries a declared reason why not",
             lambda: _script("flag_coverage.py"),
             r"Finished flag-coverage", 120, allow_rc=(0, 1)),
        # This one exists to be read, not to fail. It diffs the canonical with
        # the generated register numbering flattened, so a reviewer can see what
        # a promote did without reading 20 000 lines of renumbering. Its
        # self-test is the row that matters; the full run needs a pending
        # promote to say anything.
        Tool("promote_diff.py", "gate",
             "the canonical's diff with register and label numbering flattened",
             lambda: _script("promote_diff.py", "--self-test"),
             r"Finished promote-diff", 120, allow_rc=(0, 1)),
        # Not exempt, despite being a module rather than a tool. It is imported
        # by every gate that builds a compiler, so a defect in build_env or
        # resolve_cc is seven gates failing with a traceback through a shared
        # frame. The self-test names the broken helper; "this file cannot fail"
        # is true of nothing.
        Tool("_common.py", "gate",
             "the shared helpers every gate uses: build_env, resolve_cc, tail",
             lambda: _script("_common.py"),
             r"Finished _common self-test", 120, allow_rc=(0, 1)),
        # Both of these were inline shell in ci-gate.yml, which is the shape
        # where a flag quietly stops being applied and nothing notices. Each
        # needs to be able to fail, and each has to be runnable by hand: the
        # runtime one because it is the whole C test suite, the Kynx one because
        # it is the only gate that builds a service and starts it.
        # These two run their SELF-TESTS, and the reason is a measurement.
        # alive_check took 11 minutes on windows-latest against 2.5 on ubuntu,
        # and 8 of those 11 were the Kynx gate re-running its load phase. Both
        # tools are gates that already ran, moments earlier, in this same job --
        # alive_check re-executing them proves nothing the previous line did not,
        # and it doubles the most expensive thing in CI.
        #
        # What D8 actually asks is whether the tool can still FAIL, and both
        # carry a --self-test that asserts exactly that: runtime_c_tests builds
        # a file that does not compile and a program that exits non-zero, and
        # kynx_gate asserts its readiness loop reports "not ready" in
        # bounded time plus every subcommand failing cleanly on a dead port.
        # That is the guarantee, at seconds instead of eight minutes.
        Tool("runtime_c_tests.py", "gate",
             "the eleven runtime C test programs; self-test here because the "
             "real run is a gate that just executed",
             lambda: _script("runtime_c_tests.py", "--self-test"),
             r"Finished runtime-c self-test", 120, allow_rc=(0, 1)),
        Tool("kynx_gate.py", "gate",
             "builds and bursts a live service; --self-test proves the "
             "readiness loop plus all four subcommands (live shares it, "
             "route-limit, burst, load) without starting a server",
             lambda: _script("kynx_gate.py", "--self-test"),
             r"Finished kynx-gate self-test", 300),
        # ---- gates that already fail on their own in CI -------------------
        # Every row in this block allows a non-zero exit as well as zero, and
        # that is a change of question, not a loosening. This check asks "does
        # the tool still RUN": it launches, it does not crash, it does not
        # hang, and its output carries the closing line that only appears when
        # it did the work. It does not ask "does the repository pass", because
        # the answer to that is twenty lines earlier in the same job, as a hard
        # step, and a gate that is honestly reporting a defect is a gate
        # working. Collapsing the two questions means one core-zone case turns
        # two CI steps red and the second one tells nobody anything new -- which
        # is the "a tool that cannot fail is not a tool" argument run backwards
        # into "a check that cannot go green is not a check".
        Tool("negative_gate.py", "gate",
             "every program in tests/negative/ must NOT compile; a ratchet that "
             "fails on the fix. Exit 1 here means the corpus and the compiler "
             "disagree, which is the corpus's own hard CI step two dozen lines "
             "up reporting the same thing",
             lambda: _script("negative_gate.py", *comp()),
             r"Finished negative: \d+/\d+", 600, allow_rc=(0, 1), cost="cheap",
             witness=r"Finished negative: \d+/\d+ pass",
             needs=("compiler",)),
        Tool("dispatch_coverage.py", "gate",
             "every ASTNode variant has an arm in the one checker, and every "
             "arm returns -- so a check cannot silently stop running",
             lambda: _script("dispatch_coverage.py"),
             r"Finished dispatch-coverage: OK", 60, allow_rc=(0, 1),
             cost="cheap", needs=()),
        Tool("frontend_gate.py", "gate",
             "`orbit frontend` vs tests/frontend/expected/",
             lambda: _script("frontend_gate.py", *comp()),
             r"Finished frontend: \d+/\d+", 300, allow_rc=(0, 1),
             witness=r"Finished frontend: \d+/\d+ pass",
             needs=("compiler",)),
        Tool("test_suite.py", "gate",
             "the language behavior suite (this run covers the std subset; the "
             "full suite is the same runner over tests/suite)",
             lambda: _script("test_suite.py", *comp("--dir", "tests/std")),
             witness=r"Finished suite: \d+/\d+ pass",
             marker=r"Finished suite: \d+/\d+", timeout=900, allow_rc=(0, 1), needs=("compiler",)),
        # The native lane has two honest outcomes: it runs the std subset
        # through R6 (ORBIT_R6 set), or it skips with exit 77 and says why.
        # What it must never do is exit 0 with neither line.
        Tool("test_suite.py:native", "gate",
             "test_suite.py --backend native: the std subset through R6, or "
             "a loud skip (exit 77) when ORBIT_R6 is not set",
             lambda: _script("test_suite.py",
                             *comp("--dir", "tests/std", "--backend", "native")),
             marker=r"Skipped suite_native: ORBIT_R6 is not set|Finished suite_native: \d+/\d+",
             timeout=900, allow_rc=(0, 1, 77), needs=("compiler",)),
        Tool("parity_selfhost.py", "gate",
             "32 stability goldens, CLI path vs in-process path",
             lambda: _script("parity_selfhost.py", *comp()),
             witness=r"Finished parity: \d+/\d+ pass",
             marker=r"Finished parity: \d+/\d+", timeout=900, allow_rc=(0, 1), needs=("compiler",)),
        Tool("werror_gate.py", "gate",
             "generated C must compile clean under -Werror",
             lambda: _script("werror_gate.py", *comp()),
             witness=r"Finished werror: \d+/\d+ pass",
             marker=r"Finished werror: \d+/\d+", timeout=900, allow_rc=(0, 1), needs=("compiler",)),
        Tool("cli_probe.py", "gate",
             "the orbit CLI contract, 50 cases",
             lambda: _script("cli_probe.py", "--compiler", compiler,
                             "--work", _tmp(work, "cli")),
             r"Finished cli-probe: \d+/\d+", 600, allow_rc=(0, 1),
             witness=r"Finished cli-probe: \d+/\d+ pass",
             needs=("compiler",)),
        # The scope gate: named directories must be clean. Not the whole repo --
        # tests/negative, tests/doctor and tests/parity are deliberately broken
        # fixtures, and examples/ is independent services whose routes collide
        # when read as one program. A second row for doctor_gate.py on purpose:
        # the goldens and the scope check are different code paths in one file.
        # Was scripts/doctor_scope_gate.py, folded in because the two shared
        # everything but the scan loop.
        Tool("doctor_gate.py", "gate",
             "scope-only mode: the directories that must have no doctor "
             "findings: compiler, std, tests/suite",
             lambda: _script("doctor_gate.py", "--scope-only",
                             "--compiler", compiler),
             r"Finished doctor_scope: \d+ director", 300, allow_rc=(0, 1),
             witness=r"Finished doctor_scope: \d+ director",
             needs=("compiler",)),
        Tool("doctor_gate.py", "gate",
             "doctor's exact output against the goldens in tests/doctor/golden/",
             lambda: _script("doctor_gate.py", "--compiler", compiler),
             # 900, not 300: this gate used to SKIP the three cases that verify a
             # --fix by compiling the result, and now it runs them, because the
             # compiler in CI lives in RUNNER_TEMP and cannot otherwise reach the
             # runtime headers. Three real compiles on a cold ccache do not fit
             # in five minutes, and a timeout kills the process before it prints
             # the closing line -- which reads, to the check below, as "did not do
             # the work" rather than as the timeout it is.
             r"Finished doctor_gate: \d+ case", 900, allow_rc=(0, 1),
             witness=r"Finished doctor_gate: \d+ case",
             needs=("compiler",)),
        Tool("routes_probe.py", "gate",
             "MSYS2 argument-rewrite normalization; Windows CI only breaks "
             "without it and nothing else notices",
             lambda: _script("routes_probe.py"),
             r"Finished routes-probe: \d+/\d+", 60),
        Tool("build_selfhost.py", "gate",
             "the canonical is stale check. Non-zero is correct whenever the tree "
             "holds a core edit that has not been promoted, so both 0 and 1 are "
             "allowed here. The marker is the per-iteration hash line rather than "
             "the closing verdict, because the verdict line differs between the "
             "two outcomes ('converged' vs 'canonical is stale') and a marker "
             "that only matches the happy path fails the tool for being right",
             lambda: _script("build_selfhost.py", "--cc", cc, "--check-stale"),
             r"^Iteration \d+: [0-9a-f]{64}", 900, allow_rc=(0, 1),
             witness=r"Finished bootstrap: converged",
             cost="heavy"),

        Tool("verify_seed.py", "gate",
             "hermetic seed -> canonical C fixed point. Same: non-zero here "
             "means the tree has an unpromoted core edit, which is the tool "
             "being right, not the tool being dead",
             lambda: _script("verify_seed.py", "--cc", cc),
             witness=r"Finished verify: \d+/\d+ pass",
             marker=r"fixed point", timeout=900, allow_rc=(0, 1), cost="heavy"),
        Tool("kynx_gate.py", "gate",
             "live route-limit gate; the live server is started by the live "
             "subcommand, which CI runs; this row asserts the route-limit "
             "phase fails cleanly with no server",
             lambda: _script("kynx_gate.py", "route-limit", "--port", "9",
                             "--burst-path", "/gate-burst"),
             r"Finished kynx gate: FAIL", 120, allow_rc=(1,), expect_fail=True),

        # ---- measurements: something consumes them --------------------------
        Tool("unknown_census.py", "measurement",
             "the unknown-type count. It is the reader inside "
             "unknown_ratchet.py, so a rotted probe makes the ratchet exit 2 "
             "rather than quietly pass -- and the marker here is the "
             "measurement line, so a rotted probe is still caught on its own",
             lambda: _script("unknown_census.py", "--compiler", compiler,
                             "--cc", cc),
             r"^Corpus: \d+ files, \d+ functions, \d+ instructions$", 600,
             needs=("compiler",)),
        Tool("unknown_ratchet.py", "measurement",
             "the gate that holds the count one way (D7). Marker is the "
             "verdict line, so 'could not measure' cannot pass for 'held'",
             lambda: _script("unknown_ratchet.py", "--compiler", compiler,
                             "--cc", cc),
             r"^Finished unknown-count: \d+ \(baseline \d+, (ratchet holds|"
             r"ratchet broken)", 600, allow_rc=(0, 1), needs=("compiler",)),
        # diff_fuzz_ratchet.py used to be here, and was removed when the
        # differential fuzzer reached 0 disagreements in 678 cases. Its own
        # rule is why: the baseline has to carry a non-empty by_class map so
        # that every row is a count that can only fall, and a corpus with no
        # disagreements has no rows. A ratchet whose floor is zero cannot
        # detect a regression, because the regression is a number going UP and
        # zero is the only number it would have to go up to. Alive_check also
        # objects, correctly: a gate that cannot fail is not a gate.
        #
        # The fuzzer itself is still here, still run, and its count is still
        # worth reading. What is gone is the promise that the number cannot get
        # worse -- the corpus is the evidence now, not a baseline.
        Tool("amalgamate.py", "measurement",
             "inlines 20 runtime/*.c into the seed. Runs with --out into a "
             "temp dir ON PURPOSE: with no arguments it writes 4.8 MB into the "
             "repo's dist/, so 'just run it to see if it works' is not free",
             lambda: _script("amalgamate.py", "--out", _tmp(work, "amalg", "seed.c")),
             r"Wrote .*seed\.c \(\d+\.\d+ MB\)", 300),
        # The static library is a build artifact, not a gate input, so this
        # row runs only its --self-test: a TU that does not compile and a
        # missing runtime directory must both be reported. The real build
        # (compiling the whole runtime into .orbit/lib) is minutes of cc for
        # no new aliveness signal beyond what the self-test asserts.
        Tool("mklib_runtime.py", "measurement",
             "builds .orbit/lib/libruntime_net.a for separate compilation; "
             "--self-test proves a broken TU and a missing runtime still fail",
             lambda: _script("mklib_runtime.py", "--self-test"),
             r"Finished mklib self-test: 2/2", 300),
        Tool("shard_selfhost.py", "measurement",
             "sharded build driver: R1-R7 split of the compiler-emitted TU "
             "+ parallel gcc -c + link + auto-emission SHA check; --self-test "
             "splits a synthetic TU, refuses a missing header, and proves a "
             "bad shard is rejected",
             lambda: _script("shard_selfhost.py", "--self-test",
                             "--cc", cc),
             r"Finished shard-selfhost self-test: \d+/\d+", 300),
        # The IR corpus is a pinned artifact for the same reason the runtime
        # archive is: R6 regenerates it from this commit and compares hashes,
        # so the emission itself is the consumer's run (it needs the branch
        # compiler and a corpus). What can fail here is the contract and the
        # comparator, and both are what --self-test drives: 135+1 members in
        # pinned order, and a synthetic manifest against which a changed hash,
        # a changed size, a missing member, an extra member and a changed
        # whole-corpus hash must each still be reported. The marker is the full
        # ratio, so a self-test that quietly stopped asserting one of them
        # fails this row instead of passing it.
        Tool("emit_ir_corpus.py", "measurement",
             "emits the 135+1 IR corpus and its hash manifest; --self-test "
             "proves the corpus contract and that the comparator catches a "
             "changed hash, size, member and whole-corpus hash",
             lambda: _script("emit_ir_corpus.py", "--self-test"),
             r"Finished emit-ir-corpus self-test: 31/31", 300),
        Tool("ir_unknown_census.py", "measurement",
             "unknown register types in the emitted IR, by defining opcode; "
             "--self-test proves the count on a synthetic document and that "
             "a destination-less instruction and a non-.ir file are ignored",
             lambda: _script("ir_unknown_census.py", "--self-test"),
             r"Finished ir-unknown-census self-test: 6/6", 60, needs=()),
        Tool("tcc_setup.py", "measurement",
             "the pinned tcc 0.9.27 acquisition; --check proves the pin "
             "without installing. Exit 2 is SKIP (no tcc here), not death, "
             "so both 0 and 2 are allowed; the marker is the closing line "
             "in either case",
             lambda: _script("tcc_setup.py", "--check"),
             r"Finished tcc-setup", 300, allow_rc=(0, 2), needs=()),
        Tool("dual_judge.py", "gate",
             "dual-toolchain judge: the corpus must behave byte-identically "
             "under tcc and gcc; --self-test proves the comparator catches "
             "an exit and a stdout difference without a compiler",
             lambda: _script("dual_judge.py", "--self-test"),
             r"Finished dual self-test: \d+/\d+", 120, allow_rc=(0, 1)),
        Tool("triangle.py", "gate",
             "DDC triangle: tcc, gcc-O0 and gcc-O2 judges must emit "
             "byte-identical compiler C; --self-test proves the digest "
             "comparison without a toolchain",
             lambda: _script("triangle.py", "--self-test"),
             r"Finished triangle self-test: \d+/\d+", 120, allow_rc=(0, 1)),
        Tool("cli_probe.py", "measurement",
             "the style specimen (--specimen): static examples of the output "
             "grammar, so tone can be reviewed without running a bootstrap. "
             "A second row for cli_probe.py on purpose -- the probe and the "
             "specimen are different code paths in one file, and one row only "
             "proves one of them runs",
             lambda: _script("cli_probe.py", "--specimen"),
             r"--- suite -+", 60),

        # ---- report-only: this check is their only coverage -----------------
        Tool("fuzz_frontend.py", "report",
             "crash-only fuzzer, in NO CI step at all. Three iterations is "
             "enough: this asserts the runner works, not that the compiler is "
             "crash-free (scripts/diff_fuzz.py is the one hunting wrong values)",
             lambda: _script("fuzz_frontend.py", "--compiler", compiler,
                             "--iterations", "3"),
             r"^Fuzzed 3 iterations: ", 600, needs=("compiler",)),
        Tool("diff_fuzz.py", "report",
             "the differential fuzzer, report-only in CI. Two categories at 8 "
             "iterations (~30 cases in 2 programs), not the gate's 400: this "
             "row asks whether the tool still works, and int-arith plus "
             "string-escape exercise both batch mechanisms (value lines and "
             "sentinel-framed bytes). The marker is the closing line "
             "INCLUDING the corpus sha, because a fuzzer that measured nothing "
             "still prints a line and non-empty output is not evidence (D8)",
             lambda: _script("diff_fuzz.py", "--compiler", compiler,
                             "--cc", cc, "--only", "int-arith",
                             "--only", "string-escape", "--iterations", "8"),
             r"^Finished diff-fuzz: \d+/\d+ agree with the reference across \d+ "
             r"cases \(seed \d+, sha [0-9a-f]{16}\)$", 600,
             needs=("compiler",)),
        Tool("measure_selfhost.py", "report",
             "resource measurement across bootstrap phases, in NO CI step. One "
             "phase with a 1 ms interval is the aliveness question: did it "
             "build, sample and write a report",
             lambda: _script("measure_selfhost.py", "--cc", cc,
                             "--phases", "1", "--interval-ms", "1"),
             r"^Finished measure: \d+ phase record\(s\) written$", 900,
             allow_rc=(0, 1, 2), cost="heavy"),
        Tool("kynx_gate.py", "report",
             "HTTP load generator, in NO CI step, and it USED to exit 0 against "
             "a dead port having measured nothing. Now it must fail when zero "
             "requests completed, which is what the marker below is checking",
             lambda: _script("kynx_gate.py", "load", "--port", "9", "--requests", "2",
                             "--duration", "1", "--warmup", "0", "--timeout", "1"),
             r"Failed night_load|Finished night-load: \d+ completed", 120,
             allow_rc=(0, 1)),
        Tool("kynx_gate.py", "report",
             "429 admission-control probe, in NO CI step",
             lambda: _script("kynx_gate.py", "burst", "--port", "9",
                             "--requests", "2", "--threads", "1",
                             "--timeout", "1"),
             r"Finished burst probe: FAIL", 120, allow_rc=(1,), expect_fail=True),
        Tool("orbit_ccache.py", "report",
             "the content-addressed C cache. Its self-test asserts the two "
             "properties the whole cache rests on: identical inputs give an "
             "identical key, and every input an include flag can reach moves "
             "it. It has to assert them because this one fails silently -- the "
             "artifact outlives the header that produced it and the build "
             "still looks green -- and every self-host gate imports it",
             lambda: _script("orbit_ccache.py", "self-test"),
             r"^cc cache self-test: OK", 60),
        Tool("cc_cached.py", "report",
             "the ORBIT_CC wrapper that puts the compiler's INNER compile "
             "through that cache. No gate imports it -- it is wired in as a "
             "compiler, by environment -- so this row is its only coverage. "
             "Its self-test drives the wrapper against a compiler stub, "
             "because the properties that have to hold are the wrapper's own: "
             "argv and exit status passed through, a repeat served from the "
             "cache, the fail-open paths still open, and a driver that would "
             "name this file skipped rather than followed",
             lambda: _script("cc_cached.py", "--self-test"),
             r"^cc cache shim self-test: OK", 60),
        Tool("phase_times.py", "measurement",
             "phase boundaries read from the [mem] stamps the binary already "
             "prints, for one small program; the self-test is the part that "
             "matters, because a timer that never runs and a timer that "
             "measures nothing print the same table",
             lambda: _script("phase_times.py", "--compiler", compiler,
                             "--only", "hello", "--runs", "1"),
             r"^Finished phase-times: 1/1 pass \(\d+ program\(s\), 1 run\(s\),",
             300, allow_rc=(0,), needs=("compiler",)),
        Tool("phase_times.py", "measurement",
             "the two ways this harness must say no: an invalid --compiler "
             "path is refused with exit 2, and a program that cannot build is "
             "recorded as a non-zero run",
             lambda: _script("phase_times.py", "--compiler", compiler,
                             "--self-test"),
             r"^Finished phase-times: 2/2 pass \(self-test\)$",
             120, allow_rc=(0,), needs=("compiler",)),

        # ---- libraries: imported by the gates, never run ---------------------
        Tool("orbit_output.py", "library",
             "the house style every gate depends on. If finish() or fail() goes "
             "away, every gate in the repo changes shape at once",
             None, needs=()),
        Tool("orbit_routes.py", "library",
             "route normalization for Windows CI; routes_probe.py is the "
             "behavioural check, this is the surface it needs",
             None, needs=()),
    ]
    return tools


# Static rows: not scripts, but part of a tool, and rot-able. The third field
# is an optional checker for a file with internal structure, and there is one per
# row rather than one for the lot: the first version asserted the D7 baseline's
# shape for every `.json` in the directory, which is a shape assertion following
# the file instead of the gate. The moment a second baseline landed it would have
# failed a perfectly good file, and the cheapest way to be wrong about a
# validator is to write it once and reuse it.
def _check_unknown_baseline(path):
    import json
    with open(path, encoding="utf-8") as fh:
        base = json.load(fh)
    if base.get("schema") != 1 or not isinstance(base.get("totals"), dict):
        raise ValueError("no schema 1 / no totals")
    # The gate is on a rate and the absolute count moved to `context`, so this
    # has to check the rate keys exist and the per-file map still adds up to the
    # absolute. It asserted the old shape and caught me changing it -- which is
    # the second time this file has earned its existence in one session.
    for key in ("unknown_per_mille", "silent_per_mille"):
        if not isinstance(base["totals"].get(key), int):
            raise ValueError("totals has no integer %s" % key)
    context = base.get("context")
    if not isinstance(context, dict) or \
            not isinstance(context.get("unknown_instructions"), int):
        raise ValueError("no context.unknown_instructions")
    if sum(base["by_file"].values()) != context["unknown_instructions"]:
        raise ValueError("by_file does not add up to the absolute count")



STATIC_ROWS = [
    ("unknown_census.orb", "the census probe program. THIS is the file that "
     "rotted silently in D8: the F-0004 fix stopped it building and the only "
     "symptom was a line on stderr", None),
    ("../examples/demo-ledger-server.c", "a C fixture for a demo, not "
     "compiled by any gate. Recorded rather than checked: compiling it needs "
     "the demo's own inputs. It lives in examples/ because that is what it "
     "is; the ../ is the row reaching outside scripts/", None),
    ("baselines/unknown_count.json", "the D7 ratchet baseline. Checked against "
     "the shape the gate that reads it requires", _check_unknown_baseline),
    # baselines/diff_fuzz.json was here and is not any more. The D9 ratchet is
    # retired -- see COVERAGE_EXEMPT for why a floor of zero retires a one-way
    # ratchet rather than setting it to zero -- so there is no baseline for a
    # reader to have.
]

# Files in scripts/ that are deliberately not rows, each with the reason. The
# list is short on purpose: the point of writing it down is that anything NOT in
# it is a file somebody forgot, and D8's decision is that every script has a
# gate or an aliveness check. A tool that drops off the registry by accident is
# a tool nobody checks, which is the exact state D8 exists to end -- and
# diff_fuzz.py WAS in that state until the D9 ratchet made it worth a row.
COVERAGE_EXEMPT = {
    "alive_check.py": "the checker. A row that ran the checker from inside the "
                      "checker recurses forever. Its own coverage is "
                      "--self-test (eight broken tools, each failure class "
                      "required) and the coverage assertion below, which is the "
                      "one thing only this file can do.",
}

SHELL_ROWS = [
    ("install.sh", "Linux/macOS installer. Runs code in the user's home "
     "directory, so it is never executed by a gate; parsed and its referenced "
     "repo paths are checked instead"),
    ("build_seed.sh", "POSIX seed builder. Superseded by build_selfhost.py in "
     "CI but still the documented manual path"),
    ("install.ps1", "Windows installer, same reasoning as install.sh"),
    ("build_seed.bat", "Windows seed builder, same reasoning as build_seed.sh"),
]

BAT = (".bat", ".ps1")


def shell_checks(name):
    """Parse-check a shell script and confirm the repo files it names still exist."""
    problems = []
    path = os.path.join("scripts", name)
    if not os.path.isfile(path):
        return ["file is gone"]
    if os.name == "nt" and name.endswith(BAT):
        return []  # no POSIX shell to parse it with; the path check below still runs
    if not name.endswith(BAT):
        try:
            p = subprocess.run(["bash", "-n", path], cwd=ROOT,
                               capture_output=True, text=True, errors="replace")
        except OSError:
            p = None
        if p is not None and p.returncode != 0:
            detail = (p.stderr or "").strip()[:200]
            if os.name == "nt":
                # Advisory only. A Windows checkout has CRLF line endings and a
                # POSIX parser is the wrong tool for the job; the path check
                # below is the part that catches a real rot, and it still runs.
                problems.append("advisory: bash -n on a Windows checkout (%s)"
                                % (detail or "no message"))
            else:
                problems.append("does not parse: %s" % detail)
    try:
        text = open(os.path.join(ROOT, path), encoding="utf-8",
                    errors="replace").read()
    except OSError as exc:
        return ["unreadable: %s" % exc]
    # Every repo-relative path the script names must still be there. A renamed
    # script is the rot these installers would suffer and nothing would say so.
    # Only paths that start at a real top-level directory are checked: a
    # `$HOME/.orbit/bin` is supposed not to exist, and a shell variable glued
    # to the front of a path is not a repo path.
    tops = ("scripts/", "compiler/", "runtime/", "std/", "lib/", "tests/",
            "editors/", "docs/")
    for ref in sorted(set(re.findall(r'[./\w-]+\.(?:py|orb|c|exe|json|md|cjs)', text))):
        ref = ref.lstrip("./")
        if not ref.startswith(tops):
            continue
        if not os.path.exists(os.path.join(ROOT, ref)):
            problems.append("names %s, which does not exist" % ref)
    return problems


def library_checks(name):
    """Import a module and assert the surface other tools call still exists.

    A name check alone is weak -- a function can keep its name and lose its
    behaviour -- so each module also gets one behavioural assertion, the thing
    a caller is actually relying on. For orbit_routes that is the MSYS2
    prefix strip: if it stops working, Windows CI fails with "URL can't contain
    control characters" and nothing local ever sees it.
    """
    problems = []
    path = os.path.join(SCRIPTS, name)
    if not os.path.isfile(path):
        return ["file is gone"]
    surfaces = {
        "orbit_output.py": ["set_quiet", "is_quiet", "is_ci", "add_quiet", "say",
                            "fail", "tip", "ci_error", "finish", "scrub_ci"],
        "orbit_routes.py": ["normalize_route_path", "RoutePathError", "main"],
    }
    behaviour = {
        # (expression, expected) evaluated with `m` bound to the module
        "orbit_output.py": [
            ("m.finish('t', 1, 2)", None),          # must not raise
            ("m.scrub_ci('a\\nb%c', 10)", "a%0Ab%25c"),
            ("m.is_ci()", None),                     # must not raise
        ],
        "orbit_routes.py": [
            ("m.normalize_route_path('C:/Program Files/Git/gate-burst')",
             "/gate-burst"),
            ("m.normalize_route_path('health')", "/health"),
            ("m.normalize_route_path('/v1/notes/:id')", "/v1/notes/:id"),
        ],
    }
    code = (
        "import importlib.util, sys, json\n"
        "spec = importlib.util.spec_from_file_location(%r, %r)\n"
        "m = importlib.util.module_from_spec(spec)\n"
        "spec.loader.exec_module(m)\n"
        "missing = [n for n in %r if not hasattr(m, n)]\n"
        "bad = []\n"
        "for expr, want in %r:\n"
        "    try:\n"
        "        got = eval(expr)\n"
        "    except Exception as e:\n"
        "        bad.append('%%s raised %%r' %% (expr, e)); continue\n"
        "    if want is not None and got != want:\n"
        "        bad.append('%%s -> %%r, want %%r' %% (expr, got, want))\n"
        "print('MISSING:' + ','.join(missing) if missing else "
        "('BAD:' + ' | '.join(bad) if bad else 'SURFACE OK'))\n"
    ) % (name[:-3], path, surfaces[name], behaviour[name])
    p = subprocess.run([sys.executable, "-c", code], cwd=ROOT, capture_output=True,
                       text=True, errors="replace", timeout=60)
    line = (p.stdout or "").strip().splitlines()[-1] if (p.stdout or "").strip() else ""
    if p.returncode != 0 or "SURFACE OK" not in line:
        detail = (p.stderr or p.stdout or "").strip()[-200:] or "no output"
        problems.append("import failed, lost its public surface, or answered a "
                        "behavioural probe wrong: %s" % (line or detail))
    return problems


# --------------------------------------------------------------------------
# The check itself.
# --------------------------------------------------------------------------
def check(tool, ctx):
    """Run one tool and return a list of problems. Empty list means alive."""
    problems = []
    argv = tool.argv()
    env = dict(os.environ)
    env["ORBIT_CC"] = ctx["cc"]
    env["ORBIT_CCACHE_DIR"] = ctx["ccache"]
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        proc = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                              text=True, errors="replace",
                              timeout=tool.timeout)
    except subprocess.TimeoutExpired:
        return ["hung: no exit after %ds" % tool.timeout]
    except OSError as exc:
        return ["could not be launched: %s" % exc]

    output = (proc.stdout or "") + (proc.stderr or "")
    rc = proc.returncode

    # 1. a crash is not a finding, it is a dead tool
    # POSIX reports a signal as a negative status. Windows does not: a process
    # killed by an NTSTATUS exception exits with a large positive code, so `rc <
    # 0` never fires and os.abort() reads as "printed nothing at all". Anything
    # a shell could not have produced is a crash, not silence.
    if rc in CRASH_RCS or rc < 0 or (os.name == "nt" and rc > 255) \
            or TRACEBACK in output:
        tail = " | ".join(l.strip() for l in output.strip().splitlines()[-3:])
        problems.append("crashed (rc=%d): %s" % (rc, tail[:300]))
        return problems
    if not output.strip():
        problems.append("printed nothing at all")
        return problems
    # 2. did it hang?  (TimeoutExpired above)
    # 3. is the exit code one this tool is allowed to produce?
    if rc not in tool.allow_rc:
        problems.append("exited %d, which is not in the allowed set %s"
                        % (rc, list(tool.allow_rc)))
    # 4. THE D8 CHECK: did it do the work, or did it say why it could not and
    #    exit 0 anyway? Non-empty output is not evidence of anything.
    if tool.marker and not re.search(tool.marker, output, re.M):
        head = " / ".join(l.strip() for l in output.strip().splitlines()[:4])
        problems.append("no marker %r in its output -- it did not do the work. "
                        "Output began: %s" % (tool.marker, head[:300]))
    return problems


# --------------------------------------------------------------------------
# --witness <runlog>: trust the runlog for the heavy gates, re-run the rest.
# --------------------------------------------------------------------------
def load_witness(path):
    """Read the dev.py runlog for --witness mode.

    Returns (text, age_secs, problems). A missing, unreadable, empty or stale
    log is a loud failure, never a silent pass: every witness row reports it.
    """
    try:
        age = time.time() - os.stat(path).st_mtime
    except OSError as exc:
        return None, None, ["cannot stat witness log %s: %s" % (path, exc)]
    if age < 0:
        age = 0
    if age > WITNESS_MAX_AGE_SECS:
        return None, age, ["witness log %s is %.0fs old (max %ds); re-run "
                           "the gates first" % (path, age, WITNESS_MAX_AGE_SECS)]
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        return None, age, ["cannot read witness log %s: %s" % (path, exc)]
    if not text.strip():
        return None, age, ["witness log %s is empty" % path]
    return text, age, []


def check_witness(tool, text, path, age):
    """One heavy row against the runlog: its closing line must be there."""
    if tool.witness and re.search(tool.witness, text, re.M):
        return []
    return ["no witness marker %r in %s (%.0fs old) -- the gate did not run "
            "there or the log is stale. Re-run the gates, then re-run "
            "alive_check --witness %s" % (tool.witness, path,
                                          age if age is not None else -1,
                                          path)]


def run_unknown_pair(census_tool, census_label, ratchet_tool, ratchet_label,
                     ctx, compiler, cc, work):
    """One census for both unknown rows; returns two result tuples.

    Runs `unknown_census.py --json` once, writes its stdout to
    work/unknown_census.json, and judges that document with the ratchet via
    --from-json. Before this, the census row and the ratchet row each censused
    the corpus on their own: same probe build, same walk, twice the minutes.
    When the census gives no usable json, the ratchet is reported as not run
    rather than guessing -- a ratchet that cannot see the number cannot hold
    it, and it says so.
    """
    import json as _json

    json_path = _tmp(work, CENSUS_JSON_NAME)
    census_argv = _script("unknown_census.py", "--compiler", compiler,
                          "--cc", cc, "--json")
    env = dict(os.environ)
    env["ORBIT_CC"] = ctx["cc"]
    env["ORBIT_CCACHE_DIR"] = ctx["ccache"]
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    t0 = time.monotonic()
    try:
        proc = subprocess.run(census_argv, cwd=ROOT, env=env,
                              capture_output=True, text=True, errors="replace",
                              timeout=census_tool.timeout)
    except subprocess.TimeoutExpired:
        dt = time.monotonic() - t0
        return [(census_tool, census_label,
                 ["hung: no exit after %ds" % census_tool.timeout], dt),
                (ratchet_tool, ratchet_label,
                 ["not run: the single shared census hung, so there is no "
                  "json document to judge"], 0.0)]
    except OSError as exc:
        dt = time.monotonic() - t0
        return [(census_tool, census_label,
                 ["could not be launched: %s" % exc], dt),
                (ratchet_tool, ratchet_label,
                 ["not run: the single shared census never launched"], 0.0)]

    output = (proc.stdout or "") + (proc.stderr or "")
    rc = proc.returncode
    if rc in CRASH_RCS or rc < 0 or (os.name == "nt" and rc > 255) \
            or TRACEBACK in output:
        tail = " | ".join(l.strip() for l in output.strip().splitlines()[-3:])
        dt = time.monotonic() - t0
        return [(census_tool, census_label,
                 ["crashed (rc=%d): %s" % (rc, tail[:300])], dt),
                (ratchet_tool, ratchet_label,
                 ["not run: the single shared census crashed"], 0.0)]
    if not output.strip():
        dt = time.monotonic() - t0
        return [(census_tool, census_label, ["printed nothing at all"], dt),
                (ratchet_tool, ratchet_label,
                 ["not run: the single shared census printed nothing"], 0.0)]
    problems = []
    if rc not in census_tool.allow_rc:
        problems.append("exited %d, which is not in the allowed set %s"
                        % (rc, list(census_tool.allow_rc)))
    if not re.search(CENSUS_JSON_MARKER, proc.stdout or "", re.M):
        head = " / ".join(l.strip() for l in output.strip().splitlines()[:4])
        problems.append("no marker %r in its output -- it did not do the "
                        "work. Output began: %s" % (CENSUS_JSON_MARKER,
                                                    head[:300]))
    if not problems:
        try:
            data = _json.loads(proc.stdout)
            assert isinstance(data, dict)
            assert isinstance(data.get("instructions"), int) \
                and data["instructions"] > 0
            assert isinstance(data.get("unknown_instructions"), int)
            assert isinstance(data.get("unknown_without_diagnostic"), int)
            detail = data.get("files_detail")
            assert isinstance(detail, list) and detail
        except Exception as exc:  # noqa: BLE001 - any shape failure is the point
            problems.append("census --json is not a usable census document: "
                            "%r" % (exc,))
    census_dt = time.monotonic() - t0
    if problems:
        return [(census_tool, census_label, problems, census_dt),
                (ratchet_tool, ratchet_label,
                 ["not run: the single shared census gave no usable json "
                  "(%s), so there is nothing to judge" % problems[0][:200]],
                 0.0)]
    try:
        os.makedirs(work, exist_ok=True)
        with open(json_path, "w", encoding="utf-8") as fh:
            fh.write(proc.stdout)
    except OSError as exc:
        return [(census_tool, census_label, [], census_dt),
                (ratchet_tool, ratchet_label,
                 ["could not write shared census json %s: %s"
                  % (json_path, exc)], 0.0)]
    synth = Tool(ratchet_tool.name, ratchet_tool.kind, ratchet_tool.why,
                 lambda p=json_path: _script("unknown_ratchet.py",
                                             "--from-json", p),
                 marker=ratchet_tool.marker, timeout=ratchet_tool.timeout,
                 allow_rc=ratchet_tool.allow_rc, cost=ratchet_tool.cost,
                 needs=())
    t1 = time.monotonic()
    try:
        ratchet_problems = check(synth, ctx)
    except Exception as exc:  # noqa: BLE001 - a harness crash is a finding
        ratchet_problems = ["harness exception: %r" % (exc,)]
    return [(census_tool, census_label, [], census_dt),
            (ratchet_tool, ratchet_label, ratchet_problems,
             time.monotonic() - t1)]


# --self-test: a gate that cannot fail is not a gate.
# --------------------------------------------------------------------------
def self_test():
    """Feed the checker tools that are broken in one way each, and assert it says so."""
    py = lambda src: [sys.executable, "-c", src]
    cases = [
        ("healthy tool passes", "print('Finished thing: 1/1 pass')",
         r"Finished thing: \d+/\d+", (0,), 30, []),
        ("crash is caught", "import os; os.abort()", None, (0,), 30, ["crashed"]),
        ("python traceback is caught", "raise SystemError('boom')", None, (0,), 30,
         ["crashed"]),
        ("silence is caught", "pass", None, (0,), 30, ["printed nothing"]),
        ("no work done is caught (the D8 case)",
         "print('Census could not run: the probe did not build.')",
         r"^Corpus: \d+ files", (0,), 30, ["no marker"]),
        ("unexpected exit code is caught",
         "import sys; print('all done'); sys.exit(1)", r"all done", (0,), 30,
         ["exited 1"]),
        ("signal death is caught",
         "import os, signal; os.kill(os.getpid(), signal.SIGSEGV)", None, (0,), 30,
         ["crashed"]),
        ("a hang is caught", "import time; time.sleep(60)", None, (0,), 1,
         ["hung"]),
    ]
    passed = 0
    total = len(cases) + 4
    for name, src, marker, allow_rc, timeout, wants in cases:
        tool = Tool("synthetic", "gate", "self-test", lambda s=src: py(s), marker,
                    timeout=timeout, allow_rc=allow_rc)
        problems = check(tool, {"cc": "gcc", "ccache": ctx_cache()})
        got = " ".join(problems)
        good = all(w in got for w in wants) and (bool(wants) or not problems)
        if good:
            passed += 1
            print("  ok    %-42s -> %s" % (name, got[:64] or "clean"))
        else:
            out.fail("  WRONG %-39s -> %s (wanted %s)"
                     % (name, got or "clean", ", ".join(wants) or "no problem"))
    # Library and shell rows have their own failure modes.
    problems = library_checks("no_such_module.py")
    got = " ".join(problems)
    if "file is gone" in got:
        passed += 1
        print("  ok    %-42s -> %s" % ("a missing library is caught", got[:50]))
    else:
        out.fail("  WRONG a missing library was accepted")
    problems = shell_checks("no_such_script.sh")
    if any("file is gone" in p for p in problems):
        passed += 1
        print("  ok    %-42s -> file is gone" % "a missing shell script is caught")
    else:
        out.fail("  WRONG shell_checks accepted a missing file")
    problems = shell_checks("install.sh")
    problems = [x for x in problems if not x.startswith("advisory:")]
    if not problems:
        passed += 1
        print("  ok    %-42s -> no dangling repo paths" % "shell_checks on a real script")
    else:
        out.fail("  WRONG shell_checks on install.sh: %s" % "; ".join(problems))
    # Flag handling: --only used to rebind the registry before the D8 coverage
    # assertion, so every filtered run listed every other script in scripts/ as
    # "no gate and no row" and exited 1. Nothing above drives main()'s flags --
    # check() and the *_checks() helpers are the units -- so this guard is end
    # to end: one compiler-free row selected must still leave coverage reading
    # the whole registry. Asserted on the coverage verdict and not on the exit
    # code, because an unrelated unregistered script is the D8 gate's finding
    # and must not be reported twice.
    proc = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "alive_check.py"),
         "--only", "schema_conformance.py"],
        cwd=ROOT, capture_output=True, text=True, errors="replace", timeout=600)
    blob = (proc.stdout or "") + (proc.stderr or "")
    if "all gated, rowed or exempted" in blob and "Failed coverage" not in blob:
        passed += 1
        print("  ok    %-42s -> coverage still reads the whole registry"
              % "--only does not narrow coverage")
    else:
        tail = blob.strip().splitlines()
        out.fail("  WRONG %-39s -> rc=%d, no coverage verdict%s"
                 % ("--only narrowed the coverage registry", proc.returncode,
                    (": " + tail[-1][:60]) if tail else " (no output)"))
    out.finish("aliveness self-test", passed, total)
    return 0 if passed == total else 1


def ctx_cache():
    return os.environ.get("ORBIT_CCACHE_DIR",
                          os.path.join(os.environ.get("TMPDIR", "/tmp"), "orbit_ccache"))


def main():
    ap = argparse.ArgumentParser(
        description="Every tool in scripts/ has to prove it still works (D8)")
    ap.add_argument("--compiler", default=os.path.join(ROOT, "orbit.exe"),
                    help="an orbit compiler, for the tools that need one")
    ap.add_argument("--cc", default="gcc")
    ap.add_argument("--quick", action="store_true",
                    help="only the checks that need no compile")
    ap.add_argument("--only", action="append", default=None,
                    help="run only this tool (repeatable); this narrows which "
                         "rows execute and leaves the D8 coverage assertion "
                         "reading the whole registry")
    ap.add_argument("--workers", type=int, default=None,
                    help="registry rows to run at once (default: up to 4; "
                         "1 runs them one by one)")
    ap.add_argument("--list", action="store_true",
                    help="print the registry and exit")
    ap.add_argument("--witness", default=None, metavar="RUNLOG",
                    help="verify the ten heavy T1-T3 gates against a fresh "
                         "dev.py runlog instead of re-executing them; cheap "
                         "rows still re-execute, and without the flag "
                         "everything re-executes as before")
    ap.add_argument("--self-test", action="store_true",
                    help="assert the checker catches a crash, a hang, silence, "
                         "stale output and a wrong exit code")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    if args.self_test:
        return self_test()

    work = os.path.join(os.environ.get("TMPDIR", "/tmp"), "orbit_alive")
    os.makedirs(work, exist_ok=True)
    have_compiler = bool(args.compiler) and os.path.isfile(args.compiler)
    ctx = {"cc": args.cc, "ccache": ctx_cache()}

    tools = registry(args.compiler, args.cc, work)
    # --only narrows which rows EXECUTE. It must not rebind `tools`, because the
    # D8 coverage assertion at the bottom of this function reads `tools` to
    # decide whether the registry accounts for every file in scripts/. Rebinding
    # it here made every --only run report every other script as "no gate and no
    # row": a false positive, and worse, a way to make the coverage check go
    # quiet by selecting a subset. --quick already had the right shape -- it
    # narrows `runnable` below and leaves the registry alone.
    selected = tools
    if args.only:
        wanted = set(args.only)
        selected = [t for t in tools if t.name in wanted]
        if not selected:
            out.fail("Failed aliveness: no tool matched %s" % ", ".join(sorted(wanted)))
            return 1

    if args.list:
        # A listing mode, not a verification one: it prints what would run and
        # exits before the rows and the D8 coverage assertion, which is what
        # `dev.py list` does for the tiers. It prints `selected` rather than the
        # whole registry so that --only composes with it and the answer is the
        # same as the one the run would give.
        for tool in selected:
            out.say("%-30s %-10s %s" % (tool.name, tool.kind, tool.why))
        out.say("\n%d tool(s)." % len(selected))
        return 0

    witness_text, witness_age = None, None
    witness_load_problems = []
    witness_active = args.witness is not None
    if witness_active:
        witness_text, witness_age, witness_load_problems = load_witness(args.witness)
        if witness_text is None:
            for _problem in witness_load_problems:
                out.fail("witness log: %s" % _problem)
        else:
            out.say("witness log %s (%.0fs old): the ten heavy T1-T3 gates "
                    "are verified against it, every other row re-executes"
                    % (args.witness, witness_age))
    checked = 0
    failures = 0
    skipped = []

    workers = args.workers
    if workers is None:
        workers = min(4, os.cpu_count() or 1)
    if workers < 1:
        out.fail("Failed aliveness: --workers must be >= 1")
        return 2

    runnable = []
    for tool in selected:
        label = "%-28s %-12s" % (tool.name, tool.kind)
        if witness_active and tool.witness is not None:
            # Witness mode: the verification is a runlog grep, so it is cheap
            # and needs no compiler -- --quick does not skip it either.
            runnable.append((tool, label))
            continue
        if args.quick and tool.cost == "heavy":
            skipped.append((tool.name, "--quick"))
            out.say("%s skipped (--quick)" % label)
            continue
        if "compiler" in tool.needs and not have_compiler:
            skipped.append((tool.name, "no compiler at %s" % args.compiler))
            out.say("%s skipped (no compiler; pass --compiler)" % label)
            continue
        runnable.append((tool, label))

    # Single census for the two unknown rows: run `unknown_census --json`
    # once and judge it with the ratchet via --from-json, instead of each row
    # censusing the corpus on its own. Only when BOTH rows are runnable; with
    # --only on a single one, each still runs standalone as before.
    pair_results = []
    pair_task = None
    _census_at = _ratchet_at = None
    for _i, (_t, _l) in enumerate(runnable):
        if _t.name == "unknown_census.py" and _census_at is None:
            _census_at = _i
        if _t.name == "unknown_ratchet.py" and _ratchet_at is None:
            _ratchet_at = _i
    if _census_at is not None and _ratchet_at is not None:
        _ct, _cl = runnable[_census_at]
        _rt, _rl = runnable[_ratchet_at]
        for _idx in sorted((_census_at, _ratchet_at), reverse=True):
            runnable.pop(_idx)
        # Deferred into the pool below. Run here it was a head start before
        # any row began, and the wall is the kynx self-test's window; the pair
        # is still one task (the ratchet judges the census JSON), not two.
        pair_task = (_ct, _cl, _rt, _rl)
    def run_one(pair):
        # Subprocess-bound: the GIL is released while the tool runs, so
        # threads parallelise this for real. Nothing here mutates shared
        # state -- check() and library_checks() build their own env -- and
        # all printing stays on the main thread below, in registry order.
        tool, label = pair
        t0 = time.monotonic()
        try:
            if witness_active and tool.witness is not None:
                if witness_text is None:
                    problems = ["witness log unusable: %s"
                                % "; ".join(witness_load_problems)]
                else:
                    problems = check_witness(tool, witness_text, args.witness,
                                             witness_age)
            elif tool.kind == "library":
                problems = library_checks(tool.name)
            else:
                problems = check(tool, ctx)
        except Exception as exc:  # noqa: BLE001 - a harness crash is a finding
            problems = ["harness exception: %r" % (exc,)]
        return (tool, label, problems, time.monotonic() - t0)

    if workers == 1:
        results = [run_one(pair) for pair in runnable]
        if pair_task is not None:
            pair_results = run_unknown_pair(*pair_task, ctx, args.compiler,
                                            args.cc, work)
    else:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            pair_future = (pool.submit(run_unknown_pair, *pair_task, ctx,
                                       args.compiler, args.cc, work)
                           if pair_task is not None else None)
            results = list(pool.map(run_one, runnable))
            if pair_future is not None:
                pair_results = pair_future.result()
    if pair_results:
        # Back in registry order: the pool kept runnable order while the pair
        # ran aside, so re-sort the union by registry position.
        _order = {id(_t): _i for _i, _t in enumerate(tools)}
        results = sorted(results + pair_results,
                         key=lambda _r: _order.get(id(_r[0]), -1))

    for tool, label, problems, dt in results:
        checked += 1
        if problems:
            failures += 1
            out.fail("%s DEAD [%ds]" % (label, dt))
            for p in problems:
                out.fail("    %s" % p)
            out.ci_error(out.scrub_ci("aliveness: %s: %s" % (tool.name, problems[0])))
        else:
            out.say("%s alive  (%s) [%ds]" % (label, tool.why, dt))

    # ---- the rest of scripts/: not python, or not scripts at all -----------
    for name, why in SHELL_ROWS:
        label = "%-28s %-12s" % (name, "shell")
        found = shell_checks(name)
        # Advisories are notes, never verdicts: a POSIX parse of a CRLF
        # checkout must not fail a Windows run that has bash and pass one
        # that does not. self_test strips them the same way.
        notes = [p for p in found if p.startswith("advisory:")]
        problems = [p for p in found if not p.startswith("advisory:")]
        checked += 1
        if problems:
            failures += 1
            out.fail("%s DEAD" % label)
            for p in problems:
                out.fail("    %s" % p)
        else:
            out.say("%s alive  (%s)" % (label, why))
        for n in notes:
            out.say("%s note: %s" % (label, n))

    for name, why, checker in STATIC_ROWS:
        label = "%-28s %-12s" % (name, "static")
        path = os.path.join(SCRIPTS, name)
        checked += 1
        if not os.path.isfile(path):
            failures += 1
            out.fail("%s GONE  (%s)" % (label, why))
        elif checker is not None:
            try:
                checker(path)
            except Exception as exc:   # noqa: BLE001 - any failure is the point
                failures += 1
                out.fail("%s BROKEN  (%s): %s" % (label, why, exc))
            else:
                out.say("%s alive  (%s)" % (label, why))
        else:
            out.say("%s alive  (%s)" % (label, why))

    # D8 coverage, asserted. The registry is only "one row per file" if
    # something checks that it is: without this, a new script can be committed
    # with no gate and no row, and the tool that is supposed to notice is the
    # one that cannot.
    covered = set()
    for tool in tools:
        covered.add(tool.name)
    for name, _why, _checker in STATIC_ROWS:
        covered.add(name)
    for name, _why in SHELL_ROWS:
        covered.add(name)
    checked += 1
    uncovered = sorted(f for f in os.listdir(SCRIPTS)
                       if os.path.isfile(os.path.join(SCRIPTS, f))
                       and f not in covered and f not in COVERAGE_EXEMPT)
    known_exempt = sorted(f for f in COVERAGE_EXEMPT if not os.path.isfile(
        os.path.join(SCRIPTS, f)))
    if uncovered or known_exempt:
        failures += 1
        out.fail("Failed coverage: scripts/ has %d file(s) the registry does not "
                 "account for." % (len(uncovered) + len(known_exempt)))
        for f in uncovered:
            out.fail("    %-28s no gate and no row. D8: every script has to "
                     "have one or the other." % f)
        for f in known_exempt:
            out.fail("    %-28s exempt from the registry but the file is gone; "
                     "delete the exemption." % f)
        out.fail("    Exempt on purpose: " + ", ".join(sorted(COVERAGE_EXEMPT)))
    else:
        out.say("%-28s %-12s %d file(s) in scripts/, all gated, rowed or "
                "exempted with a reason" % ("(coverage)", "assert", len(covered)))

    for name, why in skipped:
        out.say("not checked: %s (%s)" % (name, why))

    if failures:
        out.tip("a tool that cannot fail is not a tool. Run it by hand: "
                "python scripts/<name>.py --help, then read the failure above.")
    line = "Finished aliveness: %d/%d tools alive" % (checked - failures, checked)
    if skipped:
        line += " (%d not checked)" % len(skipped)
    print(line)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
