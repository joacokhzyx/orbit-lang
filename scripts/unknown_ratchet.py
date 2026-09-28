#!/usr/bin/env python3
"""The unknown-type count, held to a one-way ratchet. This is the gate (D7).

`unknown` is not a detail of the type system, it is the mechanism. Every type
rule downstream of an `unknown` register is skipped, so an unknown name, an
unknown field, an unknown argument type and an unknown body all pass, and 46% of
them produce no diagnostic at all. A count that can only go down turns "do not
regress this" from a rule people follow into a property the build enforces.

It does not fail because the count is HIGH. 30.5% of inferred types are unknown
today and a zero-bar gate is a gate everybody disables, so the only thing that
fails here is a count that went UP relative to a committed baseline.

Two numbers are ratcheted, both already emitted by scripts/unknown_census.py:

    unknown_instructions         every instruction the front end typed `unknown`
    unknown_without_diagnostic   the ones it did not even complain about

The second is the sharper one: those reach codegen silently, and a silent
defect is by definition one the compiler accepts.

Usage:
    python scripts/unknown_ratchet.py [--compiler PATH] [--cc CC]
    python scripts/unknown_ratchet.py --write-baseline [--allow-regression]
    python scripts/unknown_ratchet.py --self-test

Exit code:
    0  the count held, or went down
    1  the count went up (or a number went missing, or the baseline is broken)
    2  the measurement could not be taken at all

Raising the baseline is a deliberate act: `--write-baseline` refuses to move a
number up unless `--allow-regression` is also given, and prints the delta and
the per-file movers either way. That is the difference between a ratchet and a
number in a file nobody looks at.
"""

import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CENSUS = os.path.join(ROOT, "scripts", "unknown_census.py")

# The baseline lives next to the tool that measures it, in a directory of its
# own so that "what is committed truth about the census" is one `ls`.
DEFAULT_BASELINE = os.path.join(ROOT, "scripts", "baselines", "unknown_count.json")

# Both move one way only. `instructions` is deliberately NOT here: the corpus
# legitimately grows, and a gate that fails when a file is added is a gate that
# gets deleted.
RATCHETED = ("unknown_instructions", "unknown_without_diagnostic")

SCHEMA = 1


# --------------------------------------------------------------------------
# The reader. One function, one source of truth, and it is meant to be swapped.
# --------------------------------------------------------------------------
def read_measurement(from_json=None, compiler=None, cc="gcc", dirs=None):
    """Take the census and return (data, note) or (None, why-it-failed).

    THIS IS THE SEAM. Everything below only knows the shape of the data this
    returns, so a better source can replace the census without touching the
    verdict logic. What it needs from a source, and all it needs:

        unknown_instructions          int
        unknown_without_diagnostic    int
        files_detail[][path]          str, repo-relative
        files_detail[][unknown_instructions]   int, summing to the first

    Assumed about `scripts/unknown_census.py --json` today: stdout is one JSON
    object and nothing else (the banner goes to stderr), and it exits 0 as long
    as the probe ran. If that stops being true -- a banner creeps back onto
    stdout, or the key is renamed -- this function raises rather than guessing,
    so a broken source is a loud failure and never a silent zero.

    `--from-json PATH` reads a census document from disk instead of running the
    census, which is how a compiler-emitted file can replace the probe later
    without this tool changing at all.
    """
    if from_json:
        try:
            with open(from_json, "r", encoding="utf-8") as fh:
                text = fh.read()
        except OSError as exc:
            return None, "could not read %s: %s" % (from_json, exc)
    else:
        cmd = [sys.executable, CENSUS, "--json"]
        if compiler:
            cmd += ["--compiler", compiler]
        if cc:
            cmd += ["--cc", cc]
        for d in (dirs or []):
            cmd += ["--dir", d]
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                              errors="replace")
        if proc.returncode != 0:
            return None, ("census exited %d\n%s"
                          % (proc.returncode, (proc.stderr or proc.stdout or "")[-1500:]))
        text = proc.stdout

    try:
        data = json.loads(text)
    except ValueError as exc:
        return None, ("census output is not one JSON object (%s). A banner on "
                      "stdout would do this." % exc)
    if not isinstance(data, dict):
        return None, "census output is not a JSON object"

    missing = [k for k in RATCHETED if not isinstance(data.get(k), int)]
    if missing:
        return None, ("census output has no integer %s. The reader in "
                      "read_measurement() needs those keys and will not guess."
                      % ", ".join(missing))
    detail = data.get("files_detail")
    if not isinstance(detail, list) or not detail:
        return None, "census output has no files_detail; per-file attribution is gone"
    for row in detail:
        if not isinstance(row, dict) or "path" not in row \
                or not isinstance(row.get("unknown_instructions"), int):
            return None, "census files_detail entry is missing path/unknown_instructions"
    return data, ""


def per_file(data):
    return {row["path"]: row["unknown_instructions"] for row in data["files_detail"]}


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
                      "    python scripts/unknown_ratchet.py --write-baseline" % path)
    except (OSError, ValueError) as exc:
        return None, "baseline %s is unreadable: %s" % (path, exc)
    if not isinstance(base, dict) or base.get("schema") != SCHEMA:
        return None, ("baseline %s has no schema %d; refusing to guess what it "
                      "means" % (path, SCHEMA))
    totals = base.get("totals")
    if not isinstance(totals, dict):
        return None, "baseline %s has no totals" % path
    for key in RATCHETED:
        if not isinstance(totals.get(key), int):
            return None, "baseline %s has no integer totals.%s" % (path, key)
    by_file = base.get("by_file")
    if not isinstance(by_file, dict):
        return None, "baseline %s has no by_file map" % path
    if sum(by_file.values()) != totals[RATCHETED[0]]:
        return None, ("baseline %s is inconsistent: by_file sums to %d but "
                      "totals.unknown_instructions is %d"
                      % (path, sum(by_file.values()), totals[RATCHETED[0]]))
    return base, ""


def write_baseline(path, data, allow_regression, prev):
    """Record today's measurement. Refuses to raise a number by accident."""
    totals = {k: data[k] for k in RATCHETED}
    if prev is not None:
        raised = {k: totals[k] - prev["totals"][k] for k in RATCHETED
                  if totals[k] > prev["totals"][k]}
        if raised and not allow_regression:
            out.fail("Refusing to raise the baseline: " +
                     ", ".join("%s +%d" % (k, v) for k, v in sorted(raised.items())))
            out.tip("if the rise is real and intended, re-run with "
                    "--allow-regression and say why in the commit message")
            return 1
    payload = {
        "schema": SCHEMA,
        "note": ("Ratchet baseline for the unknown-type count. Every number in "
                 "totals may only go down. Written by "
                 "scripts/unknown_ratchet.py --write-baseline. Do not hand-edit "
                 "a number up; that is what the gate is for."),
        "totals": totals,
        # Context, not ratcheted: the corpus legitimately grows.
        "files": data.get("files"),
        "instructions": data.get("instructions"),
        "by_file": dict(sorted(per_file(data).items())),
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
    for key in RATCHETED:
        old = prev["totals"][key] if prev else None
        out.say("  %-28s %d%s" % (key, totals[key],
                                  "" if old is None else " (was %d)" % old))
    return 0


# --------------------------------------------------------------------------
# The verdict.
# --------------------------------------------------------------------------
def movers(measured_files, base_files, top):
    """Files whose unknown count rose, biggest first, plus the two summary numbers."""
    rose = [(p, n - base_files.get(p, 0))
            for p, n in measured_files.items() if n > base_files.get(p, 0)]
    rose.sort(key=lambda kv: (-kv[1], kv[0]))
    fell = sum(1 for p, n in measured_files.items() if n < base_files.get(p, 0))
    return rose[:top], fell


def judge(data, base, per_file_mode=False, top=8):
    """Compare a measurement to a baseline.

    Returns (ok, lines, named_movers, count_of_all_movers). `lines` is the
    per-number verdict, already rendered for the house style. The verdict is on
    the TOTAL: a file may legitimately be added to the corpus, and a gate that
    fails when that happens is a gate that gets deleted. `--per-file` turns on
    the stricter reading, where a rise anywhere fails even if the total held --
    it catches the case the total hides, a regression in one file paid for by
    an improvement in another, and it is off by default because a half-finished
    refactor in one file is a normal thing to have in flight.
    """
    measured = per_file(data)
    rose, fell = movers(measured, base["by_file"], top)
    lines = []
    ok = True
    for key in RATCHETED:
        got, want = data[key], base["totals"][key]
        if got > want:
            ok = False
            lines.append("  %-28s %6d  baseline %6d  %+d" % (key, got, want, got - want))
        else:
            lines.append("  %-28s %6d  baseline %6d  %s"
                         % (key, got, want, "unchanged" if got == want
                            else "-%d" % (want - got)))
    if per_file_mode and rose:
        ok = False
    if not ok:
        named = [p for p, _ in rose]
        for path, delta in rose:
            lines.append("  rose  %-46s +%-6d now %d"
                         % (path[:46], delta, measured[path]))
        if len(measured) > len(base["by_file"]):
            lines.append("  %d file(s) are in the corpus that the baseline does "
                         "not know about" % (len(measured) - len(base["by_file"])))
        if fell:
            lines.append("  %d file(s) went down. The total is what is "
                         "ratcheted, so that does not pay for a rise."
                         % fell)
        if per_file_mode and all(data[k] <= base["totals"][k] for k in RATCHETED):
            lines.append("  The total held and --per-file is on, so a rise in "
                         "one file is still a regression.")
    return ok, lines, rose, fell


# --------------------------------------------------------------------------
# --self-test: prove the verdict logic can say no.
# --------------------------------------------------------------------------
def _measurement(total, silent, files=None):
    files = files or {"a.orb": total}
    return {"unknown_instructions": total,
            "unknown_without_diagnostic": silent,
            "files": len(files), "instructions": 100,
            "files_detail": [{"path": p, "unknown_instructions": n}
                             for p, n in files.items()]}


_BASE = {"schema": SCHEMA,
         "totals": {"unknown_instructions": 100, "unknown_without_diagnostic": 40},
         "by_file": {"a.orb": 100}}


def self_test():
    """Each case is a synthetic measurement against a synthetic baseline.

    This exists because the most expensive property of a gate is that it can
    fail, and the cheapest way to keep that property is to assert it rather
    than hope. Every branch that returns non-zero in main() is exercised here.
    """
    cases = [
        # name, measurement, baseline, per_file, expect_ok, expect_in_text
        ("identical measurement holds", _measurement(100, 40), _BASE, False, True, None),
        ("improvement holds", _measurement(90, 30), _BASE, False, True, None),
        ("count rose fails", _measurement(101, 40), _BASE, False, False, "unknown_instructions"),
        ("count rise names the delta", _measurement(101, 40), _BASE, False, False, "+1"),
        ("silent count rose fails", _measurement(100, 41), _BASE, False, False, "+1"),
        ("a new file that brings unknowns fails",
         _measurement(150, 40, {"a.orb": 100, "b.orb": 50}), _BASE, False, False, "rose"),
        ("a rise the total hides by a fall still fails",
         _measurement(101, 40, {"a.orb": 99, "b.orb": 2}), _BASE, False, False, "baseline"),
        ("per-file mode catches it where the total does not",
         _measurement(100, 40, {"a.orb": 99, "b.orb": 1}), _BASE, True, False, "per-file"),
        ("the same rise is tolerated with per-file mode off",
         _measurement(100, 40, {"a.orb": 99, "b.orb": 1}), _BASE, False, True, None),
    ]
    passed = 0
    total = len(cases)
    for name, data, base, per_file, want_ok, want_text in cases:
        ok, lines, _rose, _fell = judge(data, base, per_file)
        rendered = "\n".join(lines)
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
    tmp = os.path.join(os.environ.get("TMPDIR", "/tmp"), "orbit_ratchet_selftest")
    os.makedirs(tmp, exist_ok=True)
    live = os.path.join(tmp, "baseline.json")
    if os.path.exists(live):
        os.remove(live)
    bad = [
        ("no baseline file at all", None, "no baseline"),
        ("not json", "{not json", "unreadable"),
        ("wrong schema", {"totals": _BASE["totals"], "by_file": {"a.orb": 100}}, "schema"),
        ("no totals", {"schema": SCHEMA, "by_file": {"a.orb": 100}}, "no totals"),
        ("no by_file", {"schema": SCHEMA, "totals": _BASE["totals"]}, "by_file"),
        ("by_file does not add up",
         {"schema": SCHEMA, "totals": _BASE["totals"], "by_file": {"a.orb": 7}},
         "inconsistent"),
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
    out.finish("ratchet self-test", passed, total)
    return 0 if passed == total else 1



# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="Fail if the unknown-type count went up (one-way ratchet)")
    ap.add_argument("--compiler", default=os.path.join(ROOT, "orbit.exe"))
    ap.add_argument("--cc", default="gcc", help="C compiler for building the census probe")
    ap.add_argument("--dir", action="append", default=None,
                    help="corpus directory, repeatable (passed to the census)")
    ap.add_argument("--baseline", default=DEFAULT_BASELINE)
    ap.add_argument("--from-json", default=None,
                    help="read a census document from a file instead of running "
                         "the census (the seam: any source with these keys works)")
    ap.add_argument("--top", type=int, default=8,
                    help="how many per-file movers to name")
    ap.add_argument("--per-file", action="store_true",
                    help="stricter: any single file's count rising is a failure, "
                         "even if the total held. Off by default, because a new "
                         "file legitimately brings new unknowns with it")
    ap.add_argument("--write-baseline", action="store_true",
                    help="record today's measurement as the new baseline")
    ap.add_argument("--allow-regression", action="store_true",
                    help="permit --write-baseline to move a number UP")
    ap.add_argument("--self-test", action="store_true",
                    help="run the verdict logic against synthetic measurements "
                         "and assert it says no where it must")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    if args.self_test:
        return self_test()

    data, why = read_measurement(args.from_json, args.compiler, args.cc, args.dir)
    if data is None:
        out.fail("Failed unknown-count: the census could not be measured, and a "
                 "ratchet that cannot see the number cannot hold it.")
        out.fail("  " + why.replace("\n", "\n  "))
        out.ci_error(out.scrub_ci("unknown-count: measurement failed: " + why))
        out.tip("python scripts/unknown_census.py --compiler <orbit> --strict")
        print("Finished unknown-count: not measured (ratchet cannot hold what "
              "it cannot see)")
        return 2

    prev, why = load_baseline(args.baseline)
    if prev is None and not args.write_baseline:
        out.fail("Failed unknown-count: " + why)
        out.ci_error(out.scrub_ci("unknown-count: " + why))
        return 1

    if args.write_baseline:
        rc = write_baseline(args.baseline, data, args.allow_regression, prev)
        if rc == 0:
            print("Finished unknown-count: %d recorded as the new baseline"
                  % data[RATCHETED[0]])
        return rc

    ok, lines, rose, fell = judge(data, prev, args.per_file, args.top)
    got, want = data[RATCHETED[0]], prev["totals"][RATCHETED[0]]
    if ok:
        for line in lines:
            out.say(line)
        print("Finished unknown-count: %d (baseline %d, ratchet holds)"
              % (got, want))
        return 0

    out.fail("Failed unknown-count: the number the front end cannot type went "
             "UP. This is a one-way ratchet: %d was the high-water mark, and it "
             "is now %d." % (want, got))
    for line in lines:
        out.fail(line)
    out.ci_error(out.scrub_ci(
        "unknown-count: %s %d, baseline %d (+%d)"
        % (RATCHETED[0], got, want, got - want)))
    out.tip("unknown is the mechanism, not a detail: an unknown register skips "
            "every type rule downstream. If the rise is real, record it on "
            "purpose: python scripts/unknown_ratchet.py --write-baseline "
            "--allow-regression")
    print("Finished unknown-count: %d (baseline %d, ratchet broken, +%d)"
          % (got, want, got - want))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
