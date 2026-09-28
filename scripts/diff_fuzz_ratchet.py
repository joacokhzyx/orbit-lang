#!/usr/bin/env python3
"""The differential fuzzer's disagreement count, held to a one-way ratchet (D9).

`scripts/unknown_census.py` counts what the front end cannot type and is
report-only; `scripts/unknown_ratchet.py` is the gate that holds that count one
way (D7). This is the same pair for the behavioural measurement.
`scripts/diff_fuzz.py` generates programs whose value a reference implementation
can compute, runs them, and counts the disagreements. It found 99, in 8 classes
across 676 cases, and every one was a program that compiles clean, runs, and
gives the wrong answer. A report nobody gates gets re-run once and forgotten, and
99 findings that exist only as fuzzer output are 99 findings nobody fixes.

It does not fail because the count is HIGH. 75 disagreements in 5 classes is
today's real state, and a zero-bar gate is a gate everybody disables. The only
thing that fails here is a count that went UP against a committed baseline, or a
corpus that is not the one the baseline was taken at.

    baselines/diff_fuzz.json
        disagreements   75   the only ratcheted number; it may only go down
        corpus_sha      the SHA-256 of the case list the count was taken at
        seed            20240928
        iterations      400
        by_class        one row per disagreement class, summing to the total

Why the count and not a rate, when D7 had to move from a count to a rate: a
rate is the right instrument when the corpus grows underneath you, because a
bigger corpus raises the numerator and the denominator together. This corpus
cannot grow by accident. It is seeded (`--seed 20240928`), generated in a fixed
order, and the summary prints a SHA-256 of the whole case list precisely so that
two runs can be shown to have measured the same thing. So the count IS
comparable, and comparing it is the whole value -- and the sha is what makes it
so. A change in the corpus is a different measurement, and this gate treats it
as one: `corpus_sha` has to match, and a mismatch is a failure, not a warning.

That is the discipline `unknown_ratchet.py` arrived at, applied to the
instrument it actually has. Changing the generator is a corpus change, so the
sha moves, so the baseline has to be re-written on purpose, and the reason
belongs in the commit message:

    python scripts/diff_fuzz_ratchet.py --write-baseline --new-corpus

Raising the count is a second, separate act, because it is the one that means
the language got worse:

    python scripts/diff_fuzz_ratchet.py --write-baseline --allow-regression

Both flags are refused when the corresponding change did not happen, so a
baseline cannot be re-written "just in case".

Usage:
    python scripts/diff_fuzz_ratchet.py [--compiler PATH] [--cc CC]
    python scripts/diff_fuzz_ratchet.py --write-baseline [--new-corpus]
                                       [--allow-regression] [--iterations N]
    python scripts/diff_fuzz_ratchet.py --self-test

Exit code:
    0  the count held, or went down
    1  the count went up, or the corpus is not the baseline's corpus
    2  the measurement could not be taken at all
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FUZZER = os.path.join(ROOT, "scripts", "diff_fuzz.py")

# Same reasoning as D7: the baseline lives next to the tool that measures it, in
# a directory of its own, so "what is committed truth" is one `ls`.
DEFAULT_BASELINE = os.path.join(ROOT, "scripts", "baselines", "diff_fuzz.json")

# The corpus this gate measures. Deliberately not a flag on a check run: the
# corpus belongs to the baseline, and a run that could quietly measure a
# different one is a run whose number nobody can compare to anything.
SEED = 20240928
ITERATIONS = 400

SCHEMA = 1


# --------------------------------------------------------------------------
# The reader. One function, one source of truth, and it is meant to be swapped.
# --------------------------------------------------------------------------
def read_measurement(from_json=None, compiler=None, cc="gcc", seed=SEED,
                     iterations=ITERATIONS, batch=40, top=4, timeout=3600):
    """Run the fuzzer and return (data, note) or (None, why-it-failed).

    THIS IS THE SEAM, and it is the same seam as `read_measurement()` in
    unknown_ratchet.py: the verdict logic below only knows the shape of the
    dictionary this returns, so a different measurement can replace the fuzzer
    without touching a line of the gate. What it needs from a source:

        corpus_sha   str, 16 hex chars: identifies the corpus exactly
        seed         int
        cases        int, the size of the corpus
        agree        int
        findings     list of {class: str, source: str, problem: str}

    `--from-json PATH` reads a fuzzer document from disk instead of running it.

    `top` is how many example programs per class the fuzzer prints, and it is
    small on purpose: a gate that dumps 170 lines into a CI log is a gate people
    stop reading. The fuzzer's own `--top 12 --json` is the full list.

    It raises rather than guessing if a key disappears, so a rotted producer is
    a loud failure and never a silent zero -- which is the census incident
    (D8) restated for this pair.
    """
    if from_json:
        try:
            with open(from_json, "r", encoding="utf-8") as fh:
                text = fh.read()
        except OSError as exc:
            return None, "could not read %s: %s" % (from_json, exc)
        detail = ""
    else:
        out_fd, path = tempfile.mkstemp(prefix="orbit_difffuzz_", suffix=".json")
        os.close(out_fd)
        try:
            cmd = [sys.executable, FUZZER, "--json", path,
                   "--seed", str(seed), "--iterations", str(iterations),
                   "--batch", str(batch), "--top", str(top), "--quiet"]
            if compiler:
                cmd += ["--compiler", compiler]
            if cc:
                cmd += ["--cc", cc]
            try:
                proc = subprocess.run(cmd, cwd=ROOT, capture_output=True,
                                      text=True, errors="replace",
                                      timeout=timeout)
            except subprocess.TimeoutExpired:
                return None, ("the fuzzer did not finish in %ds. It is a "
                              "measurement, not a hang: lower --iterations on a "
                              "slow machine, or raise the timeout." % timeout)
            detail = proc.stderr or ""
            if proc.returncode != 0:
                return None, ("diff_fuzz.py exited %d\n%s"
                              % (proc.returncode, detail[-1500:] or "(no output)"))
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    text = fh.read()
            except OSError as exc:
                return None, ("the fuzzer exited 0 and wrote no readable JSON "
                              "at %s: %s" % (path, exc))
        finally:
            if not from_json and os.path.exists(path):
                os.remove(path)

    try:
        data = json.loads(text)
    except ValueError as exc:
        return None, ("fuzzer output is not one JSON object (%s)" % exc)
    if not isinstance(data, dict):
        return None, "fuzzer output is not a JSON object"

    missing = [k for k in ("corpus_sha", "seed", "iterations", "cases", "agree",
                           "findings")
               if k not in data]
    if missing:
        return None, ("fuzzer output has no %s. The reader in "
                      "read_measurement() needs those keys and will not guess "
                      "what a missing one meant." % ", ".join(missing))
    if not isinstance(data["findings"], list):
        return None, "fuzzer findings is not a list"
    for item in data["findings"]:
        if not isinstance(item, dict) or not isinstance(item.get("class"), str):
            return None, ("a finding has no string `class`; per-class "
                          "attribution is what a failure names, and without it "
                          "a red run says only that a number moved")
    if detail and not from_json:
        # The fuzzer's own report: the minimal program per class, what it gave
        # and what the reference says. A red run prints it, because a number
        # with no program behind it is not a finding.
        data["_detail"] = detail
    return derive(data), ""


def derive(data):
    """The two numbers the verdict uses, computed from the findings list.

    One function, called by the reader and by the self-test, so the synthetic
    measurements the self-test judges are shaped exactly like the real ones. A
    self-test that fed the gate a different shape than production would be
    asserting the wrong thing.
    """
    data["disagreements"] = len(data["findings"])
    counts = {}
    for item in data["findings"]:
        counts[item["class"]] = counts.get(item["class"], 0) + 1
    data["by_class"] = counts
    return data


# --------------------------------------------------------------------------
# The baseline file.
# --------------------------------------------------------------------------
def load_baseline(path):
    """Return (baseline, why-it-failed). Never creates a file that is not there.

    A missing baseline is a FAILURE, not an invitation. A gate that quietly
    writes its own baseline the first time it runs is a gate that has never
    passed.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            base = json.load(fh)
    except FileNotFoundError:
        return None, ("no baseline at %s. Write one deliberately:\n"
                      "    python scripts/diff_fuzz_ratchet.py --write-baseline"
                      % path)
    except (OSError, ValueError) as exc:
        return None, "baseline %s is unreadable: %s" % (path, exc)
    if not isinstance(base, dict) or base.get("schema") != SCHEMA:
        return None, ("baseline %s has no schema %d; refusing to guess what it "
                      "means" % (path, SCHEMA))
    if not isinstance(base.get("disagreements"), int) or base["disagreements"] < 0:
        return None, "baseline %s has no integer disagreements" % path
    if not isinstance(base.get("corpus_sha"), str) or not base["corpus_sha"]:
        # Not optional. Without it the count is a number with no corpus behind
        # it, and the next run compares two different measurements and calls it
        # a pass.
        return None, ("baseline %s has no corpus_sha; a disagreement count with "
                      "no corpus identity cannot be compared to anything" % path)
    for key in ("seed", "iterations", "cases"):
        if not isinstance(base.get(key), int):
            return None, "baseline %s has no integer %s" % (path, key)
    by_class = base.get("by_class")
    if not isinstance(by_class, dict) or not by_class:
        return None, "baseline %s has no by_class map" % path
    for name, n in by_class.items():
        if not isinstance(n, int) or n < 0:
            return None, "baseline %s: by_class[%r] is not a count" % (path, name)
    # The sum check, and it is the same check the census learned to need: the
    # per-class rows are what a red run names, so a baseline whose rows do not
    # add up to its own total is naming the wrong thing.
    if sum(by_class.values()) != base["disagreements"]:
        return None, ("baseline %s is inconsistent: by_class sums to %d but "
                      "disagreements is %d"
                      % (path, sum(by_class.values()), base["disagreements"]))
    return base, ""


def write_baseline(path, data, prev, allow_regression, new_corpus):
    """Record today's measurement. Refuses both silent changes."""
    total = data["disagreements"]
    if prev is not None:
        old = prev["disagreements"]
        if total > old and not allow_regression:
            out.fail("Refusing to raise the baseline: disagreements %d -> %d (+%d)"
                     % (old, total, total - old))
            out.tip("every one of these is a program that compiles clean, runs, "
                    "and gives the wrong answer. If the rise is real, re-run "
                    "with --allow-regression and name the class in the commit "
                    "message")
            return 1
        if data["corpus_sha"] != prev["corpus_sha"] and not new_corpus:
            out.fail("Refusing to re-write the baseline: the corpus is different.")
            out.fail("  baseline corpus sha %s (%d cases, seed %d, %d iterations)"
                     % (prev["corpus_sha"], prev["cases"], prev["seed"],
                        prev["iterations"]))
            out.fail("  today's corpus sha    %s (%d cases, seed %d, %d iterations)"
                     % (data["corpus_sha"], data["cases"], data["seed"],
                        data["iterations"]))
            out.tip("a count is only comparable within one corpus. If the corpus "
                    "genuinely changed, say so in the commit message: re-run "
                    "with --new-corpus")
            return 1
    payload = {
        "schema": SCHEMA,
        "note": ("Ratchet baseline for the differential fuzzer's disagreement "
                 "count. `disagreements` may only go down. Written by "
                 "scripts/diff_fuzz_ratchet.py --write-baseline. Do not hand-edit "
                 "a number up, and do not hand-edit corpus_sha: that is what the "
                 "gate is for."),
        "disagreements": total,
        "corpus_sha": data["corpus_sha"],
        "seed": data["seed"],
        "iterations": data["iterations"],
        "cases": data["cases"],
        "agree": data["agree"],
        "by_class": dict(sorted(data["by_class"].items(), key=lambda kv: (-kv[1], kv[0]))),
    }
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=False)
            fh.write("\n")
    except OSError as exc:
        out.fail("Could not write the baseline: %s" % exc)
        return 1
    out.say("Wrote baseline %s" % path)
    out.say("  %-28s %d%s" % ("disagreements", total,
                              "" if prev is None
                              else " (was %d)" % prev["disagreements"]))
    out.say("  %-28s %s" % ("corpus_sha", data["corpus_sha"]))
    for name, n in payload["by_class"].items():
        out.say("    %-52s %d" % (name, n))
    return 0


# --------------------------------------------------------------------------
# The verdict.
# --------------------------------------------------------------------------
def judge(data, base):
    """Compare a measurement to a baseline.

    Returns (ok, lines, why, kind). Two failure classes, both real:
      - `count`:  the count went up, the regression this gate exists for;
      - `corpus`: the corpus is not the baseline's corpus, which means the
        count is not comparable and reporting it as a pass would be a lie told
        by omission.
    """
    got, want = data["disagreements"], base["disagreements"]
    lines = ["  %-28s %6d  baseline %6d  %s"
             % ("disagreements", got, want,
                "unchanged" if got == want else "%+d" % (got - want))]
    if data["corpus_sha"] != base["corpus_sha"]:
        lines.append("  %-28s %s" % ("corpus_sha", data["corpus_sha"]))
        lines.append("  %-28s %s  <- the baseline's" % ("", base["corpus_sha"]))
        return (False, lines,
                ("the corpus moved: sha %s over %d cases, the baseline is %s over "
                 "%d cases. Two different measurements are not a regression and "
                 "not a pass." % (data["corpus_sha"], data["cases"],
                                  base["corpus_sha"], base["cases"])),
                "corpus")
    if got > want:
        rose = [(n - base["by_class"].get(name, 0), name, n)
                for name, n in data["by_class"].items()
                if n > base["by_class"].get(name, 0)]
        rose.sort(key=lambda t: (-t[0], t[1]))
        for delta, name, n in rose:
            lines.append("  rose  %-52s +%-5d now %d" % (name, delta, n))
        gone = [(base["by_class"][name], name) for name in base["by_class"]
                if name not in data["by_class"]]
        gone.sort(key=lambda t: (-t[0], t[1]))
        for was, name in gone:
            lines.append("  gone  %-52s -%-5d was %d" % (name, was, was))
        moved = {name for _d, name, _n in rose} | {name for _w, name in gone}
        still = sum(n for name, n in base["by_class"].items() if name not in moved)
        if still:
            lines.append("  %d case(s) in the classes that did not move do not "
                         "pay for this rise: the total is what is ratcheted." % still)
        return (False, lines, ("the disagreement count went UP. %d was the "
                               "high-water mark, it is now %d." % (want, got)),
                "count")
    return True, lines, "", "held"


# --------------------------------------------------------------------------
# --self-test: prove the verdict logic can say no.
# --------------------------------------------------------------------------
def _measurement(n, sha="a" * 16, cases=100, agree=90, by_class=None):
    if by_class is None:
        by_class = {"float/truncated-to-an-integer": n}
    findings = []
    for name, count in sorted(by_class.items()):
        findings.extend({"class": name} for _ in range(count))
    return derive({"corpus_sha": sha, "seed": SEED, "iterations": 400,
                   "cases": cases, "agree": agree, "findings": findings})


_BASE = {"schema": SCHEMA, "disagreements": 75, "corpus_sha": "a" * 16,
         "seed": SEED, "iterations": 400, "cases": 676, "agree": 601,
         "by_class": {"float/truncated-to-an-integer": 43,
                      "div-zero/signal-instead-of-a-diagnostic": 16,
                      "int-literal/out-of-range-literal-is-accepted": 9,
                      "int-literal/unsupported-form-is-silently-wrong-in-a-binding": 6,
                      "string-escape/hex-zero-is-never-decoded": 1}}


def self_test():
    """Each case is a synthetic measurement against the synthetic baseline.

    The most expensive property of a gate is that it can fail, and the cheapest
    way to keep that is to assert it rather than hope. Every branch that returns
    non-zero in main() is exercised here.
    """
    cases = [
        # name, measurement, expect_ok, expect_in_text
        ("identical count holds", _measurement(75), True, None),
        ("count fell holds", _measurement(70), True, "-5"),
        ("a fall with the classes renamed holds", _measurement(70, by_class={
            "float/truncated-to-an-integer": 36,
            "div-zero/signal-instead-of-a-diagnostic": 16,
            "int-literal/out-of-range-literal-is-accepted": 9,
            "int-literal/unsupported-form-is-silently-wrong-in-a-binding": 6,
            "string-escape/hex-zero-is-never-decoded": 2,
            "string-escape/wrong-bytes": 1}), True, None),
        ("count rose fails", _measurement(76), False, "went UP"),
        ("the rise names the delta", _measurement(82, by_class={
            "float/truncated-to-an-integer": 48,
            "div-zero/signal-instead-of-a-diagnostic": 18,
            "int-literal/out-of-range-literal-is-accepted": 9,
            "int-literal/unsupported-form-is-silently-wrong-in-a-binding": 6,
            "string-escape/hex-zero-is-never-decoded": 1}), False, "+5"),
        ("a new class is named", _measurement(76, by_class={
            "float/truncated-to-an-integer": 43,
            "div-zero/signal-instead-of-a-diagnostic": 16,
            "int-literal/out-of-range-literal-is-accepted": 9,
            "int-literal/unsupported-form-is-silently-wrong-in-a-binding": 6,
            "string-escape/hex-zero-is-never-decoded": 1,
            "list/at-returns-a-pointer": 1}), False, "list/at-returns-a-pointer"),
        ("a total that held on a moved corpus is still a failure",
         _measurement(75, sha="b" * 16), False, "corpus moved"),
        ("fewer cases on a moved corpus is still a failure",
         _measurement(75, sha="b" * 16, cases=300), False, "not a pass"),
    ]
    passed = 0
    total = len(cases)
    for name, data, want_ok, want_text in cases:
        ok, lines, why, _kind = judge(data, _BASE)
        rendered = "\n".join(lines) + "\n" + why
        good = ok == want_ok and (want_text is None or want_text in rendered)
        if good:
            passed += 1
            print("  ok    %-52s -> %s" % (name, "hold" if ok else "fail"))
        else:
            out.fail("  WRONG %-47s -> %s (wanted %s)%s"
                     % (name, "hold" if ok else "fail",
                        "hold" if want_ok else "fail",
                        "" if want_text is None or want_text in rendered
                        else ", text missing %r" % want_text))
    # The baseline loader has its own failure modes, and a loader that trusts a
    # broken file is a gate with no floor under it.
    tmp = os.path.join(os.environ.get("TMPDIR", "/tmp"), "orbit_df_ratchet_selftest")
    os.makedirs(tmp, exist_ok=True)
    live = os.path.join(tmp, "baseline.json")
    if os.path.exists(live):
        os.remove(live)
    bad = [
        ("no baseline file at all", None, "no baseline"),
        ("not json", "{not json", "unreadable"),
        ("wrong schema", {"totals": _BASE["by_class"]}, "schema"),
        ("no disagreements", {"schema": SCHEMA, "corpus_sha": "a" * 16}, "disagreements"),
        ("no corpus_sha", {"schema": SCHEMA, "disagreements": 1, "seed": 1,
                           "iterations": 1, "cases": 1, "agree": 1,
                           "by_class": {"x": 1}}, "corpus_sha"),
        ("no seed", {"schema": SCHEMA, "disagreements": 1, "corpus_sha": "a" * 16,
                     "iterations": 1, "cases": 1, "agree": 1,
                     "by_class": {"x": 1}}, "seed"),
        ("no by_class", {"schema": SCHEMA, "disagreements": 1,
                         "corpus_sha": "a" * 16, "seed": 1, "iterations": 1,
                         "cases": 1, "agree": 1}, "by_class"),
        ("by_class does not add up",
         {"schema": SCHEMA, "disagreements": 75, "corpus_sha": "a" * 16,
          "seed": SEED, "iterations": 400, "cases": 676, "agree": 601,
          "by_class": {"x": 7}}, "inconsistent"),
    ]
    for name, payload, want_text in bad:
        if payload is not None:
            with open(live, "w", encoding="utf-8") as fh:
                fh.write(payload if isinstance(payload, str) else json.dumps(payload))
        _base, why = load_baseline(live)
        total += 1
        if _base is None and want_text in why:
            passed += 1
            print("  ok    baseline rejected: %-36s" % name)
        else:
            out.fail("  WRONG baseline accepted or wrong reason: %s -> %s"
                     % (name, why))
    # The reader too: a producer that drops a key must be a loud failure, not a
    # zero. This is the census incident, restated.
    tmp_json = os.path.join(tmp, "measure.json")
    for name, payload, want_text in [
            ("not json", "{nope", "not one JSON object"),
            ("not an object", "[]", "not a JSON object"),
        ("no corpus_sha", '{"seed":1,"iterations":1,"cases":1,"agree":1,'
                          '"findings":[]}', "corpus_sha"),

            ("findings is not a list",
             '{"corpus_sha":"a","seed":1,"iterations":1,"cases":1,"agree":1,'
             '"findings":3}', "not a list"),
            ("a finding has no class",
             '{"corpus_sha":"a","seed":1,"iterations":1,"cases":1,"agree":1,'
             '"findings":[{}]}', "class")]:
        with open(tmp_json, "w", encoding="utf-8") as fh:
            fh.write(payload)
        _data, why = read_measurement(from_json=tmp_json)
        total += 1
        if _data is None and want_text in why:
            passed += 1
            print("  ok    measurement rejected: %-33s" % name)
        else:
            out.fail("  WRONG measurement accepted or wrong reason: %s -> %s"
                     % (name, why))
    out.finish("diff-fuzz ratchet self-test", passed, total)
    return 0 if passed == total else 1


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="Fail if the differential fuzzer's disagreement count went up")
    ap.add_argument("--compiler", default=os.path.join(ROOT, "orbit.exe"))
    ap.add_argument("--cc", default=os.environ.get("ORBIT_CC")
                               or os.environ.get("CC") or "gcc",
                    help="inline, for the programs the fuzzer runs")
    ap.add_argument("--baseline", default=DEFAULT_BASELINE)
    ap.add_argument("--from-json", default=None,
                    help="read a diff_fuzz.py document from a file instead of "
                         "running the fuzzer (the seam: any source with these "
                         "keys works)")
    ap.add_argument("--batch", type=int, default=40,
                    help="cases per compiled program, passed to the fuzzer")
    ap.add_argument("--top", type=int, default=4,
                    help="example programs per class in a red run's report")
    ap.add_argument("--timeout", type=int, default=3600,
                    help="give up on the fuzzer after this many seconds and exit 2")
    ap.add_argument("--write-baseline", action="store_true",
                    help="record today's measurement as the new baseline")
    ap.add_argument("--allow-regression", action="store_true",
                    help="permit --write-baseline to move the count UP")
    ap.add_argument("--new-corpus", action="store_true",
                    help="permit --write-baseline onto a different corpus_sha")
    ap.add_argument("--iterations", type=int, default=None,
                    help="size of the generated corpus. Only with "
                         "--write-baseline: on a check run the corpus belongs to "
                         "the baseline, and measuring a different one would "
                         "produce a number that cannot be compared to it")
    ap.add_argument("--seed", type=int, default=None,
                    help="corpus seed. Same rule as --iterations")
    ap.add_argument("--self-test", action="store_true",
                    help="run the verdict logic against synthetic measurements "
                         "and assert it says no where it must")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    if args.self_test:
        return self_test()

    prev, why = load_baseline(args.baseline)

    if not args.write_baseline and (args.iterations is not None or args.seed is not None):
        out.fail("Failed diff-fuzz ratchet: the corpus belongs to the baseline.")
        out.fail("  --iterations/--seed only mean something with --write-baseline. "
                 "A check run that measured a different corpus would report a "
                 "number that is not comparable to the one in the file, and "
                 "'not comparable' is not 'held'.")
        out.tip("to change the corpus on purpose: python scripts/"
                "diff_fuzz_ratchet.py --write-baseline --new-corpus "
                "--iterations %s" % (args.iterations or ITERATIONS))
        out.ci_error("diff-fuzz ratchet: --iterations/--seed without --write-baseline")
        print("Finished diff-fuzz ratchet: not measured (corpus is the baseline's)")
        return 1

    if prev is None and not args.write_baseline:
        out.fail("Failed diff-fuzz ratchet: " + why)
        out.ci_error(out.scrub_ci("diff-fuzz ratchet: " + why))
        print("Finished diff-fuzz ratchet: no baseline (a ratchet that has never "
              "passed is not a ratchet)")
        return 1

    seed = args.seed if args.seed is not None else (prev or {}).get("seed", SEED)
    iterations = (args.iterations if args.iterations is not None
                  else (prev or {}).get("iterations", ITERATIONS))
    data, why = read_measurement(args.from_json, args.compiler, args.cc, seed,
                                 iterations, args.batch, args.top, args.timeout)
    if data is None:
        out.fail("Failed diff-fuzz ratchet: the fuzzer could not be measured, and "
                 "a ratchet that cannot see the number cannot hold it.")
        out.fail("  " + why.replace("\n", "\n  "))
        out.ci_error(out.scrub_ci("diff-fuzz ratchet: measurement failed: " + why))
        out.tip("python scripts/diff_fuzz.py --compiler <orbit> --cc gcc "
                "--iterations %d --json /tmp/df.json" % iterations)
        print("Finished diff-fuzz ratchet: not measured (ratchet cannot hold what "
              "it cannot see)")
        return 2

    if args.write_baseline:
        rc = write_baseline(args.baseline, data, prev, args.allow_regression,
                            args.new_corpus)
        if rc == 0:
            print("Finished diff-fuzz ratchet: %d disagreements recorded against "
                  "corpus sha %s" % (data["disagreements"], data["corpus_sha"]))
        return rc

    ok, lines, why, kind = judge(data, prev)
    got, want = data["disagreements"], prev["disagreements"]
    if ok:
        for line in lines:
            out.say(line)
        out.say("  %-28s %s  (the baseline's corpus, %d cases, seed %d, "
                "%d iterations)" % ("corpus_sha", data["corpus_sha"],
                                    data["cases"], data["seed"],
                                    data["iterations"]))
        out.say("A ratchet is not a waiver: %d of these are programs that compile "
                "clean, run, and give the wrong answer, and a fix is expected to "
                "make this gate go red." % want)
        print("Finished diff-fuzz ratchet: %d disagreements in %d cases "
              "(baseline %d, ratchet holds, corpus sha %s)"
              % (got, data["cases"], want, data["corpus_sha"]))
        return 0

    out.fail("Failed diff-fuzz ratchet: " + why)
    for line in lines:
        out.fail(line)
    out.ci_error(out.scrub_ci(
        "diff-fuzz ratchet: %d disagreements, baseline %d (+%d), corpus sha %s"
        % (got, want, got - want, data["corpus_sha"])))
    if kind == "count":
        # The fuzzer's own report is the deliverable: the minimal program for
        # each class, what it gave, and what the reference says it should give.
        detail = data.get("_detail")
        if detail:
            for line in detail.rstrip().splitlines():
                out.fail("  " + line)
        out.tip("if the rise is real, record it on purpose: python scripts/"
                "diff_fuzz_ratchet.py --write-baseline --allow-regression, and "
                "name the class in the commit message. If it is not real, the "
                "class names above are where to look.")
        print("Finished diff-fuzz ratchet: %d disagreements in %d cases "
              "(baseline %d, ratchet broken, +%d)"
              % (got, data["cases"], want, got - want))
        return 1
    out.tip("the corpus is the generator plus the seed, so this means a generator "
            "changed without the baseline being re-written. If that is on "
            "purpose, record it: python scripts/diff_fuzz_ratchet.py "
            "--write-baseline --new-corpus, and say what changed in the commit "
            "message")
    print("Finished diff-fuzz ratchet: %d disagreements in %d cases "
          "(corpus sha %s is not the baseline's %s, so the count is not "
          "comparable)" % (got, data["cases"], data["corpus_sha"],
                           prev["corpus_sha"]))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
