#!/usr/bin/env python3
"""Check that the documents' counted claims about the tree still match the tree.

Three times in one week a document kept a number the tree had left behind. The
behavior suite stayed at 71 runnable files after the 72nd landed; `std/` was
described as 14 modules after `bitwise` returned and made it 19; docs/FMT.md
still described a corpus of 107 files while `dev.py fmt_check_files` holds 154;
and ENGINEERING.md put the runtime C program table at 20 files while the table
in `scripts/runtime_c_tests.py` holds 21 rows. None of those was a lie: each was
a true number at the moment it was pasted. The failure is that a count is a fact
about the tree, and nothing recomputed it.

A number that can be counted should be counted, so this reads the tree, reads
the claims, and fails when they disagree -- in the same second, with no compiler,
next to the siblings whose shape it copies: schema_conformance.py (two files of
text that must agree) and walk_coverage.py (a declaration that must match the
code). It is T0 for the same reason they are: the check costs nothing, so there
is no reason to do it by hand and every reason to do it on every commit.

What a claim is: (path, pattern, keys). The pattern is a regular expression in
which each `{N}` matches one number, written in digits or in English up to
twenty. The pattern must match, and every captured number must equal the count
this script measures for the key at the same position. A claim that no longer
matches is a finding too: a sentence rewritten without its number is a claim the
gate has stopped checking, and silence there is the same failure as a wrong
number, only quieter.

Scope. Present-tense counts of the test corpus and the standard library, in the
documents that describe the tree as it is today: docs/STATUS.md,
docs/ARCHITECTURE.md, docs/KNOWN_LIMITATIONS.md, docs/IR_SPEC.md, docs/FMT.md,
ENGINEERING.md (the section 6 row and the section 8 command list), and the
README of the two corpora that count themselves.

Out of scope, and it is a decision rather than an oversight:

  * The unknown-type census. `scripts/unknown_census.py` types the corpus with a
    front end, so it needs a bootstrapped compiler; this gate is T0 and costs a
    second. Every place the census is written down is dated or defers to
    `scripts/baselines/unknown_count.json` as the current truth, which is a
    statement the gate does not have to make for it.
  * docs/PERF.md and docs/CHANGELOG.md. A performance transcript and a release
    history are dated by contract; their numbers are of their moment. PERF.md
    still says `runtime_c_tests.py` compiles 20 programs, which is where it was.

Run it with no arguments. `--self-test` asserts that the rule can say no and that
the counters read the trees they claim to, which is the difference between a
gate and a hope.
"""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The English numbers the documents actually use, longest first so that
# `fourteen` is read as fourteen and not as four followed by `teen`.
WORDS = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
         "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
         "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
WORD_VALUE = {w: i + 1 for i, w in enumerate(WORDS)}
WORDS.sort(key=len, reverse=True)
NUMBER = r"\b(\d+|" + "|".join(WORDS) + r")\b"


def as_int(token: str) -> int:
    return int(token) if token.isdigit() else WORD_VALUE[token.lower()]


def claim_regex(pattern: str) -> "re.Pattern":
    return re.compile(pattern.replace("{N}", NUMBER), re.S | re.I)


def measure(root: pathlib.Path) -> dict:
    """Every count a claim may rest on, read from the tree as it is now."""
    suite = sorted((root / "tests" / "suite").rglob("*.orb"))
    support = [p for p in suite if p.name.endswith(".support.orb")]
    std = [p for p in (root / "std").rglob("*.orb") if "quarantine" not in p.parts]
    std_tests = sorted((root / "tests" / "std").rglob("*.orb"))
    negative = sorted((root / "tests" / "negative").rglob("*.orb"))
    probes = sorted((root / "tests" / "parity" / "probes").glob("*.orb"))
    goldens = [p for p in (root / "tests" / "parity" / "golden").rglob("*")
               if p.is_file()]
    tir = sorted((root / "tests" / "frontend" / "expected").glob("*.tir"))
    fixtures = sorted((root / "tests" / "frontend").glob("*.orb"))
    compiler = sorted((root / "compiler").rglob("*.orb"))
    examples = [p for p in (root / "examples").glob("*.orb")
                if p.name != "orbit_full_expansion.orb"]
    quarantined = list((root / "std" / "quarantine").glob("*.orb.quarantined"))

    def directives(files, marker):
        return sum(1 for p in files
                   for line in p.read_text(encoding="utf-8").splitlines()
                   if line.startswith(marker))

    table = (root / "scripts" / "runtime_c_tests.py").read_text(encoding="utf-8")
    programs = len(re.findall(r"(?m)^\s*prog\(", table))
    posix_only = len(re.findall(r"posix_only=True", table))

    return {
        "std_modules": len(std),
        "std_quarantined": len(quarantined),
        "suite_files": len(suite),
        "suite_support": len(support),
        "suite_runnable": len(suite) - len(support),
        "std_tests": len(std_tests),
        "negative_cases": len(negative),
        "negative_expect_error": directives(negative, "// expect-error:"),
        "negative_known_defect": directives(negative, "// known-defect:"),
        "parity_probes": len(probes),
        "parity_goldens": len(goldens),
        "tir_expectations": len(tir),
        "frontend_fixtures": len(fixtures),
        "runtime_programs": programs,
        "runtime_windows": programs - posix_only,
        "fmt_compiler": len(compiler),
        "fmt_suite": len(suite),
        "fmt_examples": len(examples),
        "fmt_files": len(compiler) + len(suite) + len(std) + len(std_tests)
                     + len(examples),
    }


# (relative path, pattern with {N} per number, keys in capture order, what the
# claim is about). Split by document, in the order a reader meets them.
CLAIMS = [
    # docs/STATUS.md -- the snapshot of the tree.
    ("docs/STATUS.md", r"\*\*{N} runnable programs \({N} files;",
     ["suite_runnable", "suite_files"], "behavior suite"),
    ("docs/STATUS.md", r"\*\*{N} modules, and one import-all test merges all {N} into",
     ["std_modules", "std_modules"], "standard library in the import-all"),
    ("docs/STATUS.md", r"\*\*{N} files, {N}/{N} pass\*\*",
     ["std_tests", "std_tests", "std_tests"], "tests/std coverage"),
    ("docs/STATUS.md",
     r"\*\*{N}/{N} cases hold their pinned outcome\*\*, \*\*{N} known defects\*\*",
     ["negative_cases", "negative_cases", "negative_known_defect"],
     "negative ratchet"),

    # docs/KNOWN_LIMITATIONS.md.
    ("docs/KNOWN_LIMITATIONS.md",
     r"Finished negative: {N}/{N} pass \({N} known defects still accepted\)",
     ["negative_cases", "negative_cases", "negative_known_defect"],
     "negative gate transcript"),
    ("docs/KNOWN_LIMITATIONS.md", r"(?m)^## `std/` is {N} modules;",
     ["std_modules"], "standard library, section heading"),
    ("docs/KNOWN_LIMITATIONS.md", r"\*\*{N} modules, and all {N} compile",
     ["std_modules", "std_modules"], "standard library, merge claim"),
    ("docs/KNOWN_LIMITATIONS.md", r"is {N} files and runs\s+{N}/{N} green",
     ["std_tests", "std_tests", "std_tests"], "tests/std coverage"),

    # docs/ARCHITECTURE.md.
    ("docs/ARCHITECTURE.md", r"Orbit standard library\. {N} modules,",
     ["std_modules"], "standard library, module table"),
    ("docs/ARCHITECTURE.md", r"\*\*{N} modules, {N} of {N}\*\*",
     ["std_modules", "std_modules", "std_modules"],
     "standard library, compile-and-merge claim"),
    ("docs/ARCHITECTURE.md", r"against its golden \({N} today\)",
     ["parity_probes"], "parity probe count"),

    # docs/IR_SPEC.md -- the designated corpus.
    ("docs/IR_SPEC.md",
     r"Suite: {N} runnable files \+ {N} support file\.\*\* `tests/suite/` holds {N}",
     ["suite_runnable", "suite_support", "suite_files"],
     "designated corpus: the suite"),
    ("docs/IR_SPEC.md", r"{N} runnable programs plus `imports\.support\.orb`",
     ["suite_runnable"], "designated corpus: runnable files only"),
    ("docs/IR_SPEC.md", r"Standard library: {N} files\.\*\* `tests/std/` holds {N}",
     ["std_tests", "std_tests"], "designated corpus: tests/std"),
    ("docs/IR_SPEC.md",
     r"covering the {N} shipped `std/\*\*/\*\.orb` modules \(the {N} `std/quarantine",
     ["std_modules", "std_quarantined"],
     "designated corpus: std modules and quarantine"),

    # docs/FMT.md -- the corpus the fmt gate verifies.
    ("docs/FMT.md", r"under `compiler/` \({N} files\), `tests/suite/` \({N}\),",
     ["fmt_compiler", "fmt_suite"], "fmt corpus, source trees"),
    ("docs/FMT.md", r"`std/` \({N}\) and `tests/std/` \({N}\), plus",
     ["std_modules", "std_tests"], "fmt corpus, library trees"),
    ("docs/FMT.md", r"`examples/\*\.orb` \({N}, minus",
     ["fmt_examples"], "fmt corpus, examples"),
    ("docs/FMT.md", r"\. {N} files -- the exact list",
     ["fmt_files"], "fmt corpus, total"),

    # ENGINEERING.md, section 6 (the debt table) and section 8 (the commands).
    ("ENGINEERING.md", r"program table \({N}(?: runtime C)? programs; {N} on Windows",
     ["runtime_programs", "runtime_windows"],
     "runtime C program table, section 6"),
    ("ENGINEERING.md", r"\({N} of {N} there, as above\)",
     ["runtime_windows", "runtime_programs"],
     "runtime C table on Windows, section 6"),
    ("ENGINEERING.md",
     r"{N} runnable tests in `tests/suite` \({N} files, one a support module\), "
     r"{N} in `tests/std`, {N} parity probes, and {N} `\.tir` expectations",
     ["suite_runnable", "suite_files", "std_tests", "parity_probes",
      "tir_expectations"],
     "the gate counts, section 6"),
    ("ENGINEERING.md", r"Parity: {N} probes against {N} goldens",
     ["parity_probes", "parity_probes"], "parity probes, section 8"),
    ("ENGINEERING.md", r"defect class; {N} today",
     ["negative_cases"], "negative corpus size, section 8"),
    ("ENGINEERING.md", r"today {N}/{N} pass with {N} known",
     ["negative_cases", "negative_cases", "negative_known_defect"],
     "negative gate transcript, section 8"),
    ("ENGINEERING.md", r"{N} TIR goldens, {N} fixtures",
     ["tir_expectations", "frontend_fixtures"],
     "frontend gate fixtures, section 8"),
    ("ENGINEERING.md",
     r"the whole list \({N} programs; test_oom needs fork/waitpid, so\s+#\s+{N} run on Windows\)",
     ["runtime_programs", "runtime_windows"],
     "runtime C program table, section 8"),

    # The two corpora that count themselves.
    ("tests/parity/README.md", r"match their goldens \({N} today\)",
     ["parity_probes"], "parity probe count"),
    ("tests/negative/README.md",
     r"{N} cases: {N} are `expect-error:`.*?and {N} are `known-defect:`"
     r".*?negative: {N}/{N} pass \({N} known defects",
     ["negative_cases", "negative_expect_error", "negative_known_defect",
      "negative_cases", "negative_cases", "negative_known_defect"],
     "negative corpus census"),
]


def evaluate(root: pathlib.Path, counts: dict, claims: list) -> list:
    """Every claim that the tree no longer supports."""
    findings = []
    for rel, pattern, keys, what in claims:
        path = root / rel
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            findings.append((rel, 0, "claim", f"cannot read {rel}: {exc}"))
            continue
        matches = list(claim_regex(pattern).finditer(text))
        if not matches:
            findings.append((
                rel, 0, "missing",
                f"the {what} claim is not in the file: no match for "
                f"`{pattern}`. A sentence rewritten without its number is a "
                f"claim this gate has stopped checking.",
            ))
            continue
        for match in matches:
            line = text.count("\n", 0, match.start()) + 1
            for key, token in zip(keys, match.groups()):
                got = as_int(token)
                if got != counts[key]:
                    findings.append((
                        rel, line, key,
                        f"{what}: the document says {token}, the tree has "
                        f"{counts[key]}",
                    ))
    return findings


def check(root: pathlib.Path) -> list:
    counts = measure(root)
    findings = evaluate(root, counts, CLAIMS)
    if root == ROOT:
        # docs/FMT.md's total is a claim about dev.py's list, not about a glob
        # this script invented. If the two rules diverge, one of them moved and
        # the claim is measuring the wrong thing.
        sys.path.insert(0, str(ROOT / "scripts"))
        import dev  # noqa: E402

        fmt = len(dev.fmt_check_files())
        if fmt != counts["fmt_files"]:
            findings.append((
                "scripts/dev.py", 0, "fmt_files",
                f"fmt_check_files() holds {fmt} files and this gate counted "
                f"{counts['fmt_files']}; docs/FMT.md rests on dev.py's list, so "
                f"the two rules have to agree",
            ))
    return findings


def self_test() -> int:
    """Assert the rule can say no, and that the counters read the tree."""
    import tempfile

    with tempfile.TemporaryDirectory(prefix="doc_counts_selftest_") as td:
        root = pathlib.Path(td)
        doc = root / "doc.md"
        counts = {"suite_files": 73, "runtime_programs": 20}
        claims = [
            ("doc.md", r"holds {N} files", ["suite_files"], "a fixture count"),
            ("doc.md", r"{N} programs", ["runtime_programs"], "a spelled count"),
        ]

        doc.write_text("The suite holds 73 files and 20 programs.\n")
        if evaluate(root, counts, claims):
            print("self-test FAILED: a true claim was reported as a mismatch: "
                  f"{evaluate(root, counts, claims)}")
            return 1

        doc.write_text("The suite holds 72 files and Twenty programs.\n")
        got = [(f[0], f[2]) for f in evaluate(root, counts, claims)]
        if got != [("doc.md", "suite_files")]:
            print(f"self-test FAILED: an off-by-one was read as {got}")
            return 1

        doc.write_text("The suite holds 73 files and Nineteen programs.\n")
        got = [(f[0], f[2]) for f in evaluate(root, counts, claims)]
        if got != [("doc.md", "runtime_programs")]:
            print(f"self-test FAILED: a spelled number was read as {got}")
            return 1

        doc.write_text("The suite holds many files.\n")
        if sorted(f[2] for f in evaluate(root, counts, claims)) != ["missing", "missing"]:
            print("self-test FAILED: a claim that is gone was not reported")
            return 1

        if as_int("nineteen") != 19 or as_int("Four") != 4 or as_int("6") != 6:
            print("self-test FAILED: the number reader misreads a number")
            return 1

    real = measure(ROOT)
    invariants = [
        (real["suite_runnable"] == real["suite_files"] - real["suite_support"],
         "the suite's runnable count is not its file count minus its support"),
        (real["negative_expect_error"] + real["negative_known_defect"]
         == real["negative_cases"],
         "every negative case must pin exactly one of expect-error: and known-defect:"),
        (real["parity_probes"] == real["parity_goldens"],
         "every parity probe needs one golden"),
        (real["runtime_windows"] == real["runtime_programs"] - 1,
         "exactly one runtime program is posix-only"),
        (real["fmt_files"] == real["fmt_compiler"] + real["fmt_suite"]
         + real["std_modules"] + real["std_tests"] + real["fmt_examples"],
         "the fmt total is not the sum of the trees it verifies"),
    ]
    for ok, why in invariants:
        if not ok:
            print(f"self-test FAILED: {why}")
            return 1

    print(f"Finished doc-counts self-test: the rule reports a wrong number, a "
          f"spelled number and a claim that is gone, and the counters read the "
          f"trees they claim to (suite {real['suite_files']}, negative "
          f"{real['negative_cases']}, parity {real['parity_probes']}, runtime "
          f"{real['runtime_programs']}, fmt {real['fmt_files']}).")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--self-test", action="store_true",
                    help="assert the rule can fail, and exit")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    counts = measure(ROOT)
    findings = check(ROOT)
    numbers = sum(len(keys) for _, _, keys, _ in CLAIMS)

    if findings:
        for rel, line, key, message in findings:
            where = f"{rel}:{line}" if line else rel
            print(f"{where} [{key}] {message}")
        print(f"\nFinished doc-counts: {len(findings)} of {numbers} counted "
              f"claims in {len({c[0] for c in CLAIMS})} documents no longer "
              f"match the tree.")
        return 1

    print(f"Finished doc-counts: {len(CLAIMS)} claims, {numbers} numbers, all "
          f"equal to the tree (std {counts['std_modules']}, suite "
          f"{counts['suite_files']}/{counts['suite_runnable']} runnable, "
          f"tests/std {counts['std_tests']}, negative "
          f"{counts['negative_cases']}, parity {counts['parity_probes']}, "
          f"runtime {counts['runtime_programs']}, fmt {counts['fmt_files']}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
