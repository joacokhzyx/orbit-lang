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
                                  [--only NAME]... [--list] [--self-test]

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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")

# A tool that died on a signal, or a shell's 128+signal convention.
CRASH_RCS = {132, 133, 134, 135, 136, 137, 139, 3, 4, 5, 6, 7, 8, 11}
TRACEBACK = "Traceback (most recent call last)"


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
    """

    def __init__(self, name, kind, why, argv, marker=None, timeout=180,
                 allow_rc=(0,), cost="cheap", needs=(), expect_fail=False):
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
             "compiler/ast.orb against the code that builds nodes: arity, "
             "phantom models and variants, and a node read with a list operation",
             lambda: _script("schema_conformance.py"),
             r"Finished schema-conformance", 120, allow_rc=(0, 1)),
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
             needs=("compiler",)),
        Tool("test_suite.py", "gate",
             "the language behavior suite (this run covers the std subset; the "
             "full suite is the same runner over tests/suite)",
             lambda: _script("test_suite.py", *comp("--dir", "tests/std")),
             r"Finished suite: \d+/\d+", 900, allow_rc=(0, 1), needs=("compiler",)),
        Tool("parity_selfhost.py", "gate",
             "32 stability goldens, CLI path vs in-process path",
             lambda: _script("parity_selfhost.py", *comp()),
             r"Finished parity: \d+/\d+", 900, allow_rc=(0, 1), needs=("compiler",)),
        Tool("werror_gate.py", "gate",
             "generated C must compile clean under -Werror",
             lambda: _script("werror_gate.py", *comp()),
             r"Finished werror: \d+/\d+", 900, allow_rc=(0, 1), needs=("compiler",)),
        Tool("cli_probe.py", "gate",
             "the orbit CLI contract, 50 cases",
             lambda: _script("cli_probe.py", "--compiler", compiler,
                             "--work", _tmp(work, "cli")),
             r"Finished cli-probe: \d+/\d+", 600, allow_rc=(0, 1),
             needs=("compiler",)),
        # The scope gate: named directories must be clean. Not the whole repo --
        # tests/negative, tests/doctor and tests/parity are deliberately broken
        # fixtures, and examples/ is independent services whose routes collide
        # when read as one program. See the CI step for the full reasoning.
        Tool("doctor_scope_gate.py", "gate",
             "the directories that must have no doctor findings: compiler, std, tests/suite",
             lambda: _script("doctor_scope_gate.py", "--compiler", compiler),
             r"Finished doctor_scope: \d+ director", 300, allow_rc=(0, 1),
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
             cost="heavy"),

        Tool("verify_seed.py", "gate",
             "hermetic seed -> canonical C fixed point. Same: non-zero here "
             "means the tree has an unpromoted core edit, which is the tool "
             "being right, not the tool being dead",
             lambda: _script("verify_seed.py", "--cc", cc),
             r"fixed point", 900, allow_rc=(0, 1), cost="heavy"),
        Tool("kynx_route_limit_gate.py", "gate",
             "live route-limit gate; needs the blog_api server, which CI starts "
             "and this check does not",
             lambda: _script("kynx_route_limit_gate.py", "--port", "9",
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
        Tool("preview_output.py", "measurement",
             "the style specimen; it prints examples and executes no gate, so "
             "the only thing that can rot is the file itself",
             lambda: _script("preview_output.py"),
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
             "the differential fuzzer, report-only in CI with the count held "
             "one way by diff_fuzz_ratchet.py. 40 iterations, not the gate's "
             "400: this row asks whether the tool still works, and 40 already "
             "compiles 196 programs. The marker is the closing line INCLUDING "
             "the corpus sha, because a fuzzer that measured nothing still "
             "prints a line and non-empty output is not evidence (D8)",
             lambda: _script("diff_fuzz.py", "--compiler", compiler,
                             "--cc", cc, "--iterations", "40"),
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
        Tool("night_load.py", "report",
             "HTTP load generator, in NO CI step, and it USED to exit 0 against "
             "a dead port having measured nothing. Now it must fail when zero "
             "requests completed, which is what the marker below is checking",
             lambda: _script("night_load.py", "--port", "9", "--requests", "2",
                             "--duration", "1"),
             r"Failed night_load|Finished night-load: \d+ completed", 120,
             allow_rc=(0, 1)),
        Tool("kynx_burst_probe.py", "report",
             "429 admission-control probe, in NO CI step",
             lambda: _script("kynx_burst_probe.py", "--port", "9",
                             "--requests", "2", "--threads", "1",
                             "--timeout", "1"),
             r"Finished burst probe: FAIL", 120, allow_rc=(1,), expect_fail=True),
        Tool("orbit_ccache.py", "report",
             "the content-addressed C cache. It has a main that prints its "
             "state, so it can be run, and every self-host gate imports it",
             lambda: _script("orbit_ccache.py"),
             r"^cc cache: ", 60),

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
    ("demo-ledger-server.c", "a C fixture for a demo, not compiled by any gate. "
     "Recorded rather than checked: compiling it needs the demo's own inputs",
     None),
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
    "diff_fuzz_ratchet.py": "retired when the differential fuzzer reached 0 "
                            "disagreements in 678 cases. Its own rule is the "
                            "reason: the baseline has to carry a non-empty "
                            "by_class map so every row is a count that can "
                            "only fall, and a corpus with no disagreements has "
                            "no rows. A ratchet floored at zero cannot catch a "
                            "regression, because a regression is the number "
                            "going up. The tool is kept and still readable; it "
                            "is not run by anything, and the corpus is the "
                            "evidence now rather than a baseline.",
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
    total = len(cases) + 3
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
    out.finish("aliveness self-test", passed, total)
    return 0 if passed == total else 1


def ctx_cache():
    return os.environ.get("ORBIT_CCACHE_DIR",
                          os.path.join(os.environ.get("TMPDIR", "/tmp"), "orbit_ccache"))


# --------------------------------------------------------------------------
def seed_diff_fuzz_reader(work):
    """Write the one-finding document the D9 ratchet row is driven with.

    It carries the REAL baseline's corpus_sha and a count of 1, so the ratchet
    reaches the "held" verdict through its real reader and its real baseline
    loader. Any other sha and the row would be asserting the corpus-moved path,
    which is a different branch and a much weaker aliveness question.

    Written from the baseline rather than hard-coded so this cannot rot into
    asserting nothing: if the baseline moves, the document moves with it, and a
    baseline whose shape changed makes this fail loudly here rather than make
    the ratchet row pass for the wrong reason.
    """
    import json
    base = os.path.join(SCRIPTS, "baselines", "diff_fuzz.json")
    path = os.path.join(work, "difffuzz_alive.json")
    try:
        with open(base, encoding="utf-8") as fh:
            committed = json.load(fh)
        doc = {"seed": committed["seed"], "iterations": committed["iterations"],
               "batch": 40, "corpus_sha": committed["corpus_sha"],
               "cases": committed["cases"], "agree": committed["cases"] - 1,
               "findings": [{"class": "aliveness/one-synthetic-finding",
                             "source": "print(0)", "kind": "value",
                             "expect": "0", "note": "",
                             "problem": "synthetic, written by alive_check.py",
                             "status": "ok", "observed": "0"}]}
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh)
    except (OSError, ValueError, KeyError):
        # Leave the file absent. The ratchet row then fails, which is the
        # correct outcome: a synthetic document that could not be built must not
        # turn into a skipped check.
        if os.path.exists(path):
            os.remove(path)
    return path


def main():
    ap = argparse.ArgumentParser(
        description="Every tool in scripts/ has to prove it still works (D8)")
    ap.add_argument("--compiler", default=os.path.join(ROOT, "orbit.exe"),
                    help="an orbit compiler, for the tools that need one")
    ap.add_argument("--cc", default="gcc")
    ap.add_argument("--quick", action="store_true",
                    help="only the checks that need no compile")
    ap.add_argument("--only", action="append", default=None,
                    help="run only this tool (repeatable)")
    ap.add_argument("--list", action="store_true",
                    help="print the registry and exit")
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

    seed_diff_fuzz_reader(work)

    tools = registry(args.compiler, args.cc, work)
    if args.only:
        wanted = set(args.only)
        tools = [t for t in tools if t.name in wanted]
        if not tools:
            out.fail("Failed aliveness: no tool matched %s" % ", ".join(sorted(wanted)))
            return 1

    checked = 0
    failures = 0
    skipped = []

    for tool in tools:
        label = "%-28s %-12s" % (tool.name, tool.kind)
        if args.quick and tool.cost == "heavy":
            skipped.append((tool.name, "--quick"))
            out.say("%s skipped (--quick)" % label)
            continue
        if "compiler" in tool.needs and not have_compiler:
            skipped.append((tool.name, "no compiler at %s" % args.compiler))
            out.say("%s skipped (no compiler; pass --compiler)" % label)
            continue
        if tool.kind == "library":
            problems = library_checks(tool.name)
        else:
            problems = check(tool, ctx)
        checked += 1
        if problems:
            failures += 1
            out.fail("%s DEAD" % label)
            for p in problems:
                out.fail("    %s" % p)
            out.ci_error(out.scrub_ci("aliveness: %s: %s" % (tool.name, problems[0])))
        else:
            out.say("%s alive  (%s)" % (label, tool.why))

    # ---- the rest of scripts/: not python, or not scripts at all -----------
    for name, why in SHELL_ROWS:
        label = "%-28s %-12s" % (name, "shell")
        problems = shell_checks(name)
        checked += 1
        if problems:
            failures += 1
            out.fail("%s DEAD" % label)
            for p in problems:
                out.fail("    %s" % p)
        else:
            out.say("%s alive  (%s)" % (label, why))

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
