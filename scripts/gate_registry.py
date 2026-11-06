"""One table: which gate runs, in which tier, with what command line.

Before this file, that answer lived in five places that could disagree:

1. `scripts/dev.py:734-738` -- the tier-0 literal inside `fmt_gate`;
2. `scripts/dev.py:787-877` -- `gate_spec`, tiers 1 to 3, with the comments that
   say why each row sits where it sits;
3. the root `Makefile:19-73` -- eleven pass-throughs plus five single-gate
   recipes that rebuild each gate's argv by hand and reach the fixed point with
   `$(shell $(DEV) fp-path)`, five times;
4. `.github/workflows/ci-gate.yml` -- 18 distinct `scripts/<name>.py` paths in
   37 steps;
5. `ENGINEERING.md:747-762` -- the sequence written out again as prose.

`ENGINEERING.md` §7 row `gate-sequence` records the disagreement this caused and
the one fix already applied (CI calling `make all`). This module is the second
half of that fix: the table has one owner, and the four readers read it.

What is NOT here, and should not be: the liveness fields `timeout`, `marker` and
`allow_rc` stay `None` in these rows. Measured 2026-11-06, `scripts/dev.py` keeps
no per-gate timeout -- its only three are internal: 30 s for the compiler
identity probe (`:183`), 60 s for `--version` (`:406`) and 30 s for the `--help`
capability probe (`:433`). So `scripts/alive_check.py` is not a second copy of a
number the runner also holds: it is the one owner of how long a tool may take
and what its output must contain. Copying those fields here would move them
further from the code that enforces them and remove no drift, which is the only
reason a table gets a field.

A gate label is a stable identifier. `python scripts/dev.py all --filter <label>`,
§7, §8 and the people working here name gates by it, so renaming one is a change
to a contract, not a rename. The liveness of this table is checked by
`--self-test`: a duplicated label, a row whose script file is gone, an empty tier,
or an argv that no longer matches what `dev.py` builds today each make it fail.
"""

import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")

# The two forms of the shard step's argv, transcribed from dev.py's
# shard_split_argv. The reuse form is chosen by dev.py's main() only when a
# bundle header is bound to the canonical's exact bytes; the table keeps the
# emission form, which is what `list` shows and what a cold run executes.
# (amended by the root-of-trust merge of 2026-11-07: the shard step is the
# `shard` subcommand of scripts/trust.py; the subcommand stays the first
# argument after the script.)
SHARD_EMIT = ["shard", "--name", "emit_verify", "--emit-with", "FP", "--no-build",
              "--fresh"]
SHARD_REUSE = ["shard", "--name", "emit_verify", "--tu", "CANONICAL", "--header",
               "HEADER", "--no-build"]


class Gate:
    """One row of the table.

    `argv` is a function of the three paths a run needs -- the fixed point, the
    C compiler, the work directory -- because that is exactly what `dev.py`
    interpolates today. `None` means the gate is not a subprocess of a script:
    only `fmt` is in that case, and it runs sharded through
    `dev.py:567-618`.
    """

    def __init__(self, label, tier, script, argv, kind="gate", why="",
                 timeout=None, marker=None, allow_rc=None, self_test=None):
        self.label = label
        self.tier = tier
        self.script = script
        self.argv = argv
        self.kind = kind
        self.why = why
        self.timeout = timeout
        self.marker = marker
        self.allow_rc = allow_rc
        self.self_test = self_test

    @property
    def script_path(self):
        return os.path.join("scripts", os.path.basename(self.script))


def _py():
    return sys.executable


def _argv(script, *extra):
    """The argv form dev.py uses: an interpreter, a script path joined with a
    forward slash, then the flags.

    The separator is written, not computed. `dev.py:800` sets `s = str(ROOT /
    "scripts")` and then builds `f"{s}/gate.py"`, so on Windows its argv holds a
    mixed-separator path and a `os.path.join` version of the same file is a
    different string. Windows opens both, so nothing would fail -- and the point
    of this table is that the two forms can be compared exactly. Keeping the
    separator identical is what makes that comparison mean anything.
    """
    path = SCRIPTS + "/" + script
    return lambda fp, cc, work: [_py(), path] + [
        a.format(fp=fp, cc=cc, work=work) for a in extra]


GATES = [
    # ---- T0: static. Three of the six read text with no compiler; fmt, schema
    # and walk all need the fixed point. fmt is in the tier and not a row with
    # an argv: dev.py runs it sharded per file, so its command line is not one
    # subprocess (dev.py:535-655).
    Gate("fmt", 0, "scripts/dev.py", None,
         why="`orbit fmt --check` over compiler/, tests/suite/, std/, tests/std/ "
             "and examples/, sharded per file; the files are listed by "
             "dev.py:535 fmt_check_files()"),

    Gate("schema_conformance", 0, "scripts/static_gates.py",
         _argv("static_gates.py", "schema", "--cc", "{cc}", "--compiler", "{fp}"),
         why="`compiler/front/ast.orb` against the code that builds its nodes, "
             "as `scripts/schema_conformance.orb` since 2026-11-06. It belongs "
             "in T0: it reads two files of text and catches a class of silent "
             "wrong answers -- the schema declaring a field a list when the "
             "parser hands it a node -- so it runs every time, including for a "
             "clean tree. The driver compiles the probe with the fixed point "
             "(measured: 1.4 s to build, 0.05 s to read the tree)"),
    Gate("walk_coverage", 0, "scripts/static_gates.py",
         _argv("static_gates.py", "walk", "--cc", "{cc}", "--compiler", "{fp}"),
         why="every AST walk declares the fields it skips, as "
             "`scripts/walk_coverage.orb`; the driver compiles the probe with "
             "the fixed point (dev.py:720)"),
    Gate("doc_counts", 0, "scripts/static_gates.py", _argv("static_gates.py", "counts"),
         why="a document's counted claim about the corpus still matching the "
             "tree it describes"),
    Gate("flag_coverage", 0, "scripts/static_gates.py", _argv("static_gates.py", "flags"),
         why="a CLI flag is a promise written in --help, and a promise nothing "
             "reads is invisible in every run because the run succeeds without "
             "doing what was asked"),
    Gate("cite_coverage", 0, "scripts/static_gates.py", _argv("static_gates.py", "cites"),
         why="a `path:line` in a document is the same kind of promise, and 125 "
             "of the 184 in the nine audited documents did not open at the "
             "construct their sentence named. Measured 2026-11-03"),

    # ---- T1: an existing orbit binary, no fresh build.
    Gate("doctor_gate", 1, "scripts/doctor_gates.py", _argv(
        "doctor_gates.py", "doctor", "--compiler", "{fp}"),
         why="the doctor goldens, run against the binary under test"),
    Gate("doctor_scope", 1, "scripts/doctor_gates.py", _argv(
        "doctor_gates.py", "doctor", "--scope-only", "--compiler", "{fp}"),
         why="the same binary's scope checks (D013, D021), in the gate whose "
             "row §7 names doctor_scope"),
    Gate("cli_probe", 1, "scripts/doctor_gates.py", _argv(
        "doctor_gates.py", "cli-probe", "--compiler", "{fp}", "--work",
         "{work}" + os.sep + "cli"),
         why="the CLI contract. It runs the compiler with cwd set to its own "
             "work directory, which is why the fixed point handed to it must be "
             "absolute (dev.py:801-803)"),
    Gate("runtime_c", 1, "scripts/runtime_c_tests.py", _argv(
        "runtime_c_tests.py", "--cc", "{cc}"),
         why="the runtime C test programs. Needs a C compiler and nothing else "
             "-- no orbit binary, no bootstrap -- which is why it was forty "
             "lines of shell inside ci-gate.yml and the one gate nobody could "
             "run locally (dev.py:812-814)"),
    Gate("ui_snapshots", 1, "scripts/doctor_gates.py", _argv(
        "doctor_gates.py", "snapshots", "--compiler", "{fp}", "--cc", "{cc}", "--work",
         "{work}" + os.sep + "ui"),
         why="the rich and colour screens, byte for byte with their escapes, "
             "plus the interrupt probe (dev.py:816-818)"),

    # ---- T2: language behaviour against a freshly built fixed point.
    Gate("suite", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "suite", "--cc", "{cc}", "--compiler", "{fp}"),
         why="tests/suite/, built and run"),
    Gate("suite_std", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "suite", "--cc", "{cc}", "--compiler", "{fp}", "--dir",
         "tests/std"),
         why="the same harness over tests/std/"),
    Gate("suite_native", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "suite", "--cc", "{cc}", "--compiler", "{fp}", "--backend",
         "native"),
         why="suite through R6 instead of the C compiler. Without ORBIT_R6 it "
             "exits SKIP_RC and is reported skipped, not passed "
             "(dev.py:826-828)"),
    Gate("suite_std_native", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "suite", "--cc", "{cc}", "--compiler", "{fp}", "--dir",
         "tests/std", "--backend", "native"),
         why="tests/std/ through R6, same skip rule"),
    Gate("runtime_module", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "runtime_module", "--cc", "{cc}", "--compiler", "{fp}"),
         why="`orbit build --runtime-module` to an object, linked into a "
             "program"),
    Gate("runtime_module_native", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "runtime_module", "--cc", "{cc}", "--compiler", "{fp}",
         "--backend", "native"),
         why="the same module through R6 (ir-protocol 3), skipped without it"),
    Gate("runtime_gen", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "runtime_gen", "--cc", "{cc}", "--compiler", "{fp}"),
         why="committed runtime/gen/*.c must equal what the compiler emits for "
             "runtime/orb/*.orb, byte for byte (dev.py:839-840)"),
    Gate("negative", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "negative", "--cc", "{cc}", "--compiler", "{fp}"),
         why="tests/negative/ must fail with the text its header pins"),
    Gate("frontend", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "frontend", "--cc", "{cc}", "--compiler", "{fp}"),
         why="the TIR goldens the frontend prints"),
    Gate("dispatch", 2, "scripts/doctor_gates.py", _argv(
        "doctor_gates.py", "dispatch"),
         why="the CLI dispatch table against what the dispatcher accepts"),
    Gate("parity", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "parity", "--cc", "{cc}", "--compiler", "{fp}"),
         why="the generated-C parity probes against their goldens"),
    Gate("werror", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "werror", "--cc", "{cc}", "--compiler", "{fp}"),
         why="the -Wall -Werror probes: clean C from the emitter, not C that "
             "only one toolchain tolerates"),
    Gate("fuzz_frontend", 2, "scripts/corpus_gates.py", _argv("corpus_gates.py", "fuzz_frontend", "--compiler", "{fp}"),
         why="the frontend fuzz driver, in the tier that has a binary to feed "
             "it"),
    Gate("kynx_live", 2, "scripts/kynx_gate.py", _argv(
        "kynx_gate.py", "live", "--cc", "{cc}", "--compiler", "{fp}"),
         why="the only gate that builds a service and runs it. It was the other "
             "shell block in CI, and being unable to run the gate that proves "
             "the compiler produces a working server is how a compiler ends up "
             "green on every unit test and broken in the way that matters "
             "(dev.py:848-851)"),
    Gate("unknown_ratchet", 2, "scripts/measure.py", _argv(
        "measure.py", "ratchet", "--compiler", "{fp}", "--cc", "{cc}"),
         why="D7's one-way ratchet, the reader the baseline never had in this "
             "sequence. It was a hard CI step until f001308 folded CI into "
             "`dev.py all`, and alive_check's row for it is liveness only (rc 1 "
             "tolerated, marker matches both verdicts) -- so without this entry "
             "a tree that raised unknown_per_mille above the baseline shipped "
             "green. T2, like kynx_live: it measures the freshly built fp, and "
             "`report` keeps only the raw census (dev.py:854-860)"),

    # ---- T3: the root of trust.
    Gate("check_stale", 3, "scripts/trust.py", _argv(
        "trust.py", "build", "--cc", "{cc}", "--check-stale"),
         why="the committed canonical still describes these sources"),
    Gate("shard_split", 3, "scripts/trust.py", _argv(
        "trust.py", "shard", "--name", "emit_verify", "--emit-with", "{fp}",
         "--no-build", "--fresh", "--shards-dir",
         "{work}" + os.sep + "shards", "--cc", "{cc}"),
         why="the T3 split step in its emission form; dev.py's main() swaps in "
             "the reuse form (dev.py:752-755) when a bundle header is bound to "
             "the canonical's exact bytes, so `list` shows the emission argv "
             "either way (dev.py:794-797)"),
    Gate("verify_seed", 3, "scripts/trust.py", _argv(
        "trust.py", "verify", "--cc", "{cc}"),
         why="the seed chain reproduces the canonical bit for bit"),
    Gate("alive_check", 3, "scripts/alive_check.py", _argv(
        "alive_check.py", "--cc", "{cc}", "--compiler", "{fp}"),
         why="D8: every tool in scripts/ proves it can still fail"),

    # ---- report tier: measured, printed, and never able to fail the build.
    Gate("routes_probe", 99, "scripts/measure.py", _argv(
        "measure.py", "routes"), kind="report",
         why="the routes CLI probe, run by `dev.py report` (dev.py:1108)"),
    Gate("unknown_census", 99, "scripts/measure.py", _argv(
        "measure.py", "census", "--cc", "{cc}", "--compiler", "{fp}"),
         kind="report",
         why="the raw census behind the D7 ratchet; the ratchet is the gate, "
             "the census is the measurement (dev.py:1109)"),
    Gate("diff_fuzz", 99, "scripts/measure.py", _argv(
        "measure.py", "diff-fuzz", "--cc", "{cc}", "--compiler", "{fp}"),
        kind="report",
         why="the differential fuzzer, report-only by design since the D9 "
             "ratchet retired (dev.py:1110)"),
]

# Transcribed from `scripts/dev.py:734-738` and `:805-877` on 2026-11-05, with
# the three paths replaced by FP, CC and W. This is what makes the table testable
# rather than self-describing: `dev.py` still builds its own argv from its own
# literals, so a row that drifts from the real sequence was caught there and not
# in a green run: 29 rows compared, no difference. dev.py now builds its argv
# from this table, so that comparison would be the table against itself. Two
# guards replace it, and both read a second source: EXPECTED_ARGV pins the
# transcription made from dev.py's own literals, and EXPECTED_TIERS pins which
# tier each label runs in, which is what a reviewer has to disagree with.
# (amended by the corpus merge of 2026-11-06: twelve labels invoke
# scripts/corpus_gates.py with their gate name; the tiers did not move)
# (amended by the measurement and root-of-trust merges of 2026-11-07: seven
# labels invoke scripts/measure.py or scripts/trust.py with their
# subcommand; no label, tier or verdict line moved)
EXPECTED_ARGV = {
    "schema_conformance": ["{script}static_gates.py", "schema", "--cc", "CC",
                           "--compiler", "FP"],
    "walk_coverage": ["{script}static_gates.py", "walk", "--cc", "CC",
                      "--compiler", "FP"],
    "doc_counts": ["{script}static_gates.py", "counts"],
    "flag_coverage": ["{script}static_gates.py", "flags"],
    "cite_coverage": ["{script}static_gates.py", "cites"],
    "doctor_gate": ["{script}doctor_gates.py", "doctor", "--compiler", "FP"],
    "doctor_scope": ["{script}doctor_gates.py", "doctor", "--scope-only",
                     "--compiler", "FP"],
    "cli_probe": ["{script}doctor_gates.py", "cli-probe", "--compiler", "FP",
                  "--work", "W" + os.sep + "cli"],
    "runtime_c": ["{script}runtime_c_tests.py", "--cc", "CC"],
    "ui_snapshots": ["{script}doctor_gates.py", "snapshots", "--compiler", "FP",
                     "--cc", "CC", "--work", "W" + os.sep + "ui"],
    "suite": ["{script}corpus_gates.py", "suite", "--cc", "CC", "--compiler", "FP"],
    "suite_std": ["{script}corpus_gates.py", "suite", "--cc", "CC", "--compiler", "FP",
                  "--dir", "tests/std"],
    "suite_native": ["{script}corpus_gates.py", "suite", "--cc", "CC", "--compiler", "FP",
                     "--backend", "native"],
    "suite_std_native": ["{script}corpus_gates.py", "suite", "--cc", "CC", "--compiler",
                         "FP", "--dir", "tests/std", "--backend", "native"],
    "runtime_module": ["{script}corpus_gates.py", "runtime_module", "--cc", "CC",
                       "--compiler", "FP"],
    "runtime_module_native": ["{script}corpus_gates.py", "runtime_module", "--cc", "CC",
                              "--compiler", "FP", "--backend", "native"],
    "runtime_gen": ["{script}corpus_gates.py", "runtime_gen", "--cc", "CC", "--compiler", "FP"],
    "negative": ["{script}corpus_gates.py", "negative", "--cc", "CC", "--compiler", "FP"],
    "frontend": ["{script}corpus_gates.py", "frontend", "--cc", "CC", "--compiler", "FP"],
    "dispatch": ["{script}doctor_gates.py", "dispatch"],
    "parity": ["{script}corpus_gates.py", "parity", "--cc", "CC", "--compiler", "FP"],
    "werror": ["{script}corpus_gates.py", "werror", "--cc", "CC", "--compiler", "FP"],
    "fuzz_frontend": ["{script}corpus_gates.py", "fuzz_frontend", "--compiler", "FP"],
    "kynx_live": ["{script}kynx_gate.py", "live", "--cc", "CC", "--compiler",
                  "FP"],
    "unknown_ratchet": ["{script}measure.py", "ratchet", "--compiler", "FP",
                        "--cc", "CC"],
    "check_stale": ["{script}trust.py", "build", "--cc", "CC",
                    "--check-stale"],
    "shard_split": ["{script}trust.py", "shard", "--name", "emit_verify",
                    "--emit-with", "FP", "--no-build", "--fresh",
                    "--shards-dir", "W" + os.sep + "shards", "--cc", "CC"],
    "verify_seed": ["{script}trust.py", "verify", "--cc", "CC"],
    "alive_check": ["{script}alive_check.py", "--cc", "CC", "--compiler", "FP"],
    "routes_probe": ["{script}measure.py", "routes"],
    "unknown_census": ["{script}measure.py", "census", "--cc", "CC",
                       "--compiler", "FP"],
    "diff_fuzz": ["{script}measure.py", "diff-fuzz", "--cc", "CC",
                  "--compiler", "FP"],
}

# The tier a label runs in, transcribed from dev.py's tier dict on 2026-11-05 and
# from the baseline `dev.py list` printed before any of this work, amended by the
# tier-0 merge of 2026-11-06: the five static labels now invoke
# scripts/static_gates.py with their subcommand, and the fixture records that
# (.orbit/specs/2026-11-05-baseline-gate-list.txt). Order is part of the pin:
# ENGINEERING.md section 8 gives the sequence, and a gate moved sideways in the
# list changes which gates a crash costs.
EXPECTED_TIERS = {
    0: ["fmt", "schema_conformance", "walk_coverage", "doc_counts",
        "flag_coverage", "cite_coverage"],
    1: ["doctor_gate", "doctor_scope", "cli_probe", "runtime_c",
        "ui_snapshots"],
    2: ["suite", "suite_std", "suite_native", "suite_std_native",
        "runtime_module", "runtime_module_native", "runtime_gen", "negative",
        "frontend", "dispatch", "parity", "werror", "fuzz_frontend",
        "kynx_live", "unknown_ratchet"],
    3: ["check_stale", "shard_split", "verify_seed", "alive_check"],
    99: ["routes_probe", "unknown_census", "diff_fuzz"],
}


def gates(tier=None):
    """The rows, optionally narrowed to one tier. Tier 99 is the report tier."""
    if tier is None:
        return list(GATES)
    return [g for g in GATES if g.tier == tier]


def labels(tier=None):
    return [g.label for g in gates(tier)]


def self_test() -> int:
    """The table has to be able to say no, four ways.

    A duplicated label, a row naming a script that is gone, a tier that lost
    every row, and an argv that no longer equals what `dev.py` builds. The last
    one is the point of this file: without it, a transcription error in a table
    whose whole job is describing commands is invisible until a gate runs the
    wrong thing.
    """
    problems = []
    seen = {}
    for g in GATES:
        if g.label in seen:
            problems.append("label %s is declared twice" % g.label)
        seen[g.label] = g
        if not os.path.isfile(os.path.join(ROOT, g.script)):
            problems.append("%s names a script that is gone: %s"
                            % (g.label, g.script))
    for tier, name in ((0, "T0"), (1, "T1"), (2, "T2"), (3, "T3"),
                       (99, "report")):
        if not gates(tier):
            problems.append("tier %s has no gate" % name)

    for label, expected in EXPECTED_ARGV.items():
        g = seen.get(label)
        if g is None or g.argv is None:
            problems.append("EXPECTED_ARGV names %s, the table has no argv row "
                            "for it" % label)
            continue
        got = g.argv("FP", "CC", "W")
        # The interpreter is sys.executable in both, so it is compared, not
        # skipped: a row built with a bare "python" instead would run a
        # different interpreter than the one that started the gate.
        want = [_py()] + [e.format(script=SCRIPTS + "/") for e in expected]
        if got != want:
            problems.append("%s argv is %r, dev.py builds %r"
                            % (label, got, want))
    for g in GATES:
        if g.kind == "gate" and g.argv is not None and g.label not in \
                EXPECTED_ARGV:
            problems.append("%s has an argv with no expected form" % g.label)

    for tier, want in EXPECTED_TIERS.items():
        got = labels(tier)
        if got != want:
            problems.append("tier %s runs %r, expected %r -- a gate that moves "
                            "tier changes what a run pays for and what it "
                            "proves" % (tier, got, want))

    # The other table that must agree: scripts/alive_check.py keeps one row per
    # file in scripts/ and that is D8. A gate row whose script has no aliveness
    # row is a gate nobody can prove still works, and the registry can be edited
    # without noticing. This reads alive_check, so it is a second source and not
    # a mirror.
    import alive_check
    rowed = {t.name for t in alive_check.registry("FP", "CC", "W")}
    # `alive_check.py` itself is the one file in scripts/ with no row: a row that
    # ran the checker from inside the checker recurses forever, and its own
    # coverage is --self-test plus the D8 assertion. The exemption list is the
    # authority for that, so it is read here rather than remembered.
    rowed |= set(alive_check.COVERAGE_EXEMPT)
    for g in GATES:
        name = os.path.basename(g.script)
        if name not in rowed:
            problems.append("%s runs %s, which has no alive_check row"
                            % (g.label, name))

    if problems:
        for p in problems:
            print("gate-registry: %s" % p)
        return 1
    print("Finished gate-registry: %d labels, %d with a command line matched to "
          "dev.py's own argv, tiers T0-T3 and report non-empty, all scripts "
          "present" % (len(GATES), len(EXPECTED_ARGV)))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="The gate table: one source for what runs in which tier.")
    ap.add_argument("--self-test", action="store_true",
                    help="prove this table can still fail")
    ap.add_argument("--list", action="store_true",
                    help="print the labels per tier and exit")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.list:
        for tier, name in ((0, "T0"), (1, "T1"), (2, "T2"), (3, "T3"),
                           (99, "report")):
            print("%s: %s" % (name, ", ".join(labels(tier))))
        return 0
    ap.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
