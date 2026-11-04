#!/usr/bin/env python3
"""Unknown-type census: how much of the corpus the front end cannot type.

This is the MEASUREMENT. It never fails the build on a count, and that is
deliberate: a zero-bar gate is a gate everybody disables. The count is held to
a one-way ratchet one level up, by `scripts/unknown_ratchet.py`, which reads
this output, compares it to a committed baseline, and fails if the number went
up. That split is the whole defence -- see DECISIONS.md D7 -- and it is why the
count is worth taking seriously: it can only go down, and moving it takes a
deliberate, recorded act.

Making `unknown` detectable is core-zone work, and doing it without a number is
a guess: the question "how much of the corpus is currently unknown?" has to be
answerable before "make unknown an error" can be scoped, prioritised, or
regression-checked against. This prints that number, and prints the per-opcode
and per-directory breakdown that says which front-end rules would pay for it.

An `unknown` register is one the front end had no type for. Every type rule
downstream of it is skipped, which is why it is contagious and why so much of
the emitted C is `(void*)(uintptr_t)` casts. The count is the size of the hole
the type work has to close.

The measurement runs in-process through the front end itself
(`scripts/unknown_census.orb`), not through `orbit check`, because `check` says
only whether a file is clean. A file full of `unknown` and no diagnostics is
still a file the compiler does not understand.

Usage:
    python scripts/unknown_census.py [--compiler PATH] [--cc CC] [--dir D]...
                                     [--json] [--top N] [--strict]

With `--json`, stdout is a single JSON object and nothing else -- the banner
goes to stderr -- so the output can be consumed by a program. The keys
`unknown_instructions`, `unknown_without_diagnostic` and
`files_detail[].unknown_instructions` are the machine contract;
`scripts/unknown_ratchet.py` reads exactly those.

Exit code is 0 whatever the census finds. `--strict` exits non-zero only when
the census could not run at all (probe did not build, corpus empty), which is
an operational failure rather than a measurement.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import build_env  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = os.path.join(ROOT, "scripts", "unknown_census.orb")

DEFAULT_DIRS = ["examples", "tests/suite", "tests/std", "compiler", "std"]

# Windows caps a command line at 32k characters, so the corpus goes over in
# chunks rather than as one enormous argv.
CHUNK = 60


def discover(dirs):
    files = []
    for d in dirs:
        base = os.path.join(ROOT, d)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(n for n in dirnames if n not in (".git", "__pycache__"))
            for name in sorted(filenames):
                if not name.endswith(".orb"):
                    continue
                if name.endswith(".support.orb"):
                    continue
                files.append(os.path.join(dirpath, name))
    return files


def rel(path):
    return os.path.relpath(path, ROOT).replace("\\", "/")


def group_of(path):
    r = rel(path)
    for d in DEFAULT_DIRS:
        if r == d or r.startswith(d + "/"):
            return d
    return r.split("/")[0]


DECL_RE = re.compile(r"^\s*(?:extern\s+)?(?:fn|enum|union|model|type|val|const)"
                     r"\s+([A-Za-z_]\w*)", re.M)
IMPORT_RE = re.compile(r'^\s*import\s+"([^"]+)"', re.M)


def name_origins(rows, dirs):
    """Sort the E2001 identifiers by where a definition of the name lives.

    The four answers decide what the front end would have to learn to type the
    load: a name this file declares, a name in a file it imports, a name
    somewhere else in the corpus, or a name nothing declares. DECL_RE takes the
    keywords a corpus file introduces a name with at the top level -- `fn`,
    `extern fn` with no body, `enum`, `union`, `model`, the `type X = A | B`
    alias, and a top-level `val`/`const`, which the compiler emits as a global
    `#define` -- because a classifier that only matches `^fn` moves the 37
    runtime externs of compiler/host/extern.orb and every enum, union and alias
    name into "nothing declares it" and reports a boundary that does not exist.
    Both regexes carry re.M on purpose: a whole-file findall without it matches
    only at offset zero and the classification reads zero, which looks like a
    small answer instead of a broken instrument.
    """
    decls = {}
    imports = {}
    for p in discover(dirs):
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        key = rel(p)
        decls[key] = set(DECL_RE.findall(text))
        imports[key] = [rel(os.path.normpath(os.path.join(os.path.dirname(p), m)))
                        for m in IMPORT_RE.findall(text)]
    everywhere = set()
    for names in decls.values():
        everywhere |= names

    buckets = Counter()
    top = {}
    for r in rows:
        path = r["path"]
        own = decls.get(path, set())
        direct = set()
        for e in imports.get(path, []):
            direct |= decls.get(e, set())
        for name, n in r.get("name", Counter()).items():
            if name in own:
                bucket = "declared in this file"
            elif name in direct:
                bucket = "declared in a file this one imports"
            elif name in everywhere:
                bucket = "declared elsewhere in the corpus"
            else:
                bucket = "declared by no corpus file"
            buckets[bucket] += n
            top.setdefault(bucket, Counter())[name] += n
    return buckets, top


def build_probe(compiler, cc, work):
    exe = os.path.join(work, "census" + (".exe" if os.name == "nt" else ""))
    env = dict(os.environ)
    env = build_env(work, cc=cc)
    env["ORBIT_CCFLAGS_EXTRA"] = '-I"%s"' % os.path.join(ROOT, "runtime")
    p = subprocess.run([compiler, "build", rel(PROBE), "-o", exe], cwd=ROOT,
                       env=env, capture_output=True, text=True, errors="replace")
    if p.returncode != 0 or not os.path.isfile(exe):
        tail = "\n".join(((p.stdout or "") + (p.stderr or "")).strip().splitlines()[-12:])
        return None, tail
    return exe, ""


def run_probe(exe, files, work):
    """Run the probe over the corpus and parse its report lines."""
    rows = []
    for start in range(0, len(files), CHUNK):
        chunk = files[start:start + CHUNK]
        p = subprocess.run([exe] + [rel(f) for f in chunk], cwd=ROOT,
                           capture_output=True, text=True, errors="replace",
                           timeout=300)
        if p.returncode != 0:
            return None, (p.stdout or "") + (p.stderr or "")
        rows.extend(parse(p.stdout))
    return rows, ""


def parse(text):
    """FILE/FN/OP/CODE blocks into dicts."""
    rows = []
    cur = None
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "FILE":
            cur = {"path": " ".join(parts[1:]), "op": Counter(), "code": Counter(),
                   "giveup": Counter(), "name": Counter(), "load": Counter()}
            rows.append(cur)
        elif parts[0] == "FN" and cur is not None:
            # FN <functions> RETUNK <n> PARAMUNK <n> INSTR <n> INSTRUNK <n> DIAG <n>
            labels = parts[2::2]
            values = parts[3::2]
            fields = dict(zip(labels, values))
            cur["functions"] = int(parts[1])
            cur["ret_unk"] = int(fields.get("RETUNK", 0))
            cur["param_unk"] = int(fields.get("PARAMUNK", 0))
            cur["instr"] = int(fields.get("INSTR", 0))
            cur["instr_unk"] = int(fields.get("INSTRUNK", 0))
            cur["diag"] = int(fields.get("DIAG", 0))
        elif parts[0] == "OP" and cur is not None:
            cur["op"][parts[1]] += int(parts[2])
        elif parts[0] == "GIVEUP" and cur is not None:
            # GIVEUP <count> <message...>: one front-end give-up class and how
            # many expressions of this file fell into it.
            try:
                cur["giveup"][" ".join(parts[2:])] += int(parts[1])
            except (ValueError, IndexError):
                pass
        elif parts[0] == "CODE" and cur is not None:
            cur["code"][parts[1]] += int(parts[2])
        elif parts[0] == "NAME" and cur is not None:
            # NAME <count> unknown identifier <name>: the last word is the
            # identifier the file loads without a type for it.
            try:
                cur["name"][parts[-1]] += int(parts[1])
            except (ValueError, IndexError):
                pass
        elif parts[0] == "LOAD" and cur is not None:
            # LOAD <count> <kind>: the unknown loads of this file, split by
            # whether the function that reads the name also binds it.
            try:
                cur["load"][" ".join(parts[2:])] += int(parts[1])
            except (ValueError, IndexError):
                pass
        elif parts[0] == "UNREADABLE" and cur is not None:
            cur["unreadable"] = True
    return rows


def aggregate(rows):
    totals = Counter()
    by_op = Counter()
    by_code = Counter()
    by_giveup = Counter()
    by_dir = defaultdict(Counter)
    for r in rows:
        totals["files"] += 1
        for k in ("functions", "ret_unk", "param_unk", "instr", "instr_unk", "diag"):
            totals[k] += r.get(k, 0)
        by_op.update(r["op"])
        by_code.update(r["code"])
        by_giveup.update(r.get("giveup", Counter()))
        d = group_of(r["path"])
        by_dir[d]["files"] += 1
        by_dir[d]["instr"] += r.get("instr", 0)
        by_dir[d]["instr_unk"] += r.get("instr_unk", 0)
        by_dir[d]["diag"] += r.get("diag", 0)
    return totals, by_op, by_code, by_dir, by_giveup


def pct(num, den):
    return 0.0 if not den else 100.0 * num / den


def table(counter, total, top, label):
    print("  %-18s %9s %8s" % (label, "count", "share"))
    for name, n in counter.most_common(top):
        print("  %-18s %9d %7.1f%%" % (name, n, pct(n, total)))
    if len(counter) > top:
        rest = sum(counter.values()) - sum(n for _, n in counter.most_common(top))
        print("  %-18s %9d %7.1f%%" % ("(%d more)" % (len(counter) - top), rest,
                                       pct(rest, total)))


def main():
    ap = argparse.ArgumentParser(
        description="Count `unknown` types across the corpus (measurement; "
                    "scripts/unknown_ratchet.py is the gate that holds it)")
    ap.add_argument("--compiler", default=os.path.join(ROOT, "orbit.exe"))
    ap.add_argument("--cc", default="gcc", help="C compiler for building the probe")
    ap.add_argument("--dir", action="append", default=None,
                    help="corpus directory, repeatable (default: %s)"
                         % ", ".join(DEFAULT_DIRS))
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--json", action="store_true",
                    help="emit the census as the only thing on stdout")
    ap.add_argument("--strict", action="store_true",
                    help="exit non-zero if the census cannot RUN (never on a count)")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    banner = ("Unknown-type census -- measurement, not a gate. The number is "
              "held to a one-way ratchet by scripts/unknown_ratchet.py.")
    if args.json:
        out.fail(banner)
    else:
        print(banner)

    dirs = args.dir or DEFAULT_DIRS
    files = discover(dirs)
    if not files:
        print("Census could not run: no .orb files under " + ", ".join(dirs))
        return 1 if args.strict else 0

    work = os.path.join(os.environ.get("TMPDIR", "/tmp") if os.name != "nt"
                        else os.environ.get("TEMP", "."), "orbit_census")
    try:
        os.makedirs(work, exist_ok=True)
    except OSError:
        work = ROOT
    exe, err = build_probe(args.compiler, args.cc, work)
    if exe is None:
        print("Census could not run: the probe did not build. "
              "scripts/unknown_census.orb imports the front end, and the front "
              "end is the core zone.\n" + err)
        return 1 if args.strict else 0
    rows, err = run_probe(exe, files, work)
    if rows is None:
        print("Census could not run: the probe failed.\n" + err[-2000:])
        return 1 if args.strict else 0

    totals, by_op, by_code, by_dir, by_giveup = aggregate(rows)
    known = totals["instr"] - totals["instr_unk"]
    # Five of the lowering diagnostics fire exactly once per instruction they
    # make `unknown`, each on the line that emits it: E2001 for a load
    # (compiler/tir/lower.orb:118), E2002 for a binary op (:131), E2003 for a
    # unary op (:139), E2004 for a member read (:152) and E2005 for a call
    # result (:190). What is left after all five is the part that reaches
    # codegen with no message. Until E2004 and E2005 were counted here that
    # residue read 11,577 and was reported as silent; the two classes carry
    # 4,821 and 6,756 of it.
    silent_codes = ("E2001", "E2002", "E2003", "E2004", "E2005")
    silent = totals["instr_unk"] - sum(by_code.get(c, 0) for c in silent_codes)
    if silent < 0:
        # One of the five no longer ties to one instruction. The residue is
        # then not a measurement of anything, so say it instead of printing a
        # negative count a ratchet would read as an improvement.
        out.fail("WARNING: the five per-instruction diagnostics sum above the "
                 "unknown total; `unknown without diagnostic` is not "
                 "meaningful this run.")

    if args.json:
        out.fail("Unknown-type census -- measurement, the gate is "
                 "scripts/unknown_ratchet.py")
        # stdout is the JSON and nothing else, so `--json > f.json` is a file
        # another program can read. The banner has already gone to stderr.
        print(json.dumps({
            "schema": 1,
            "source": "unknown_census.py",
            "note": "measurement; the gate is unknown_ratchet.py (D7)",
            "files": totals["files"],
            "functions": totals["functions"],
            "instructions": totals["instr"],
            "unknown_instructions": totals["instr_unk"],
            "unknown_instruction_percent": round(pct(totals["instr_unk"], totals["instr"]), 2),
            "unknown_return_types": totals["ret_unk"],
            "unknown_parameters": totals["param_unk"],
            "diagnostics": totals["diag"],
            "unknown_without_diagnostic": silent,
            "by_opcode": dict(by_op),
            "by_diagnostic": dict(by_code),
            "by_giveup_class": dict(by_giveup),
            "by_directory": {k: dict(v) for k, v in by_dir.items()},
            "files_detail": [
                {"path": r["path"],
                 "functions": r.get("functions", 0),
                 "instructions": r.get("instr", 0),
                 "unknown_instructions": r.get("instr_unk", 0),
                 "diagnostics": r.get("diag", 0),
                 "unknown_by_opcode": dict(r["op"])}
                for r in rows],
        }, indent=2, sort_keys=True))
        return 0

    print("Corpus: %d files, %d functions, %d instructions"
          % (totals["files"], totals["functions"], totals["instr"]))
    print("")
    print("  %-34s %9d  %5.1f%%" % ("instructions typed `unknown`",
                                    totals["instr_unk"],
                                    pct(totals["instr_unk"], totals["instr"])))
    print("  %-34s %9d" % ("instructions with a real type", known))
    print("  %-34s %9d  (%d functions)"
          % ("functions with unknown return type", totals["ret_unk"], totals["functions"]))
    print("  %-34s %9d" % ("parameters typed `unknown`", totals["param_unk"]))
    print("  %-34s %9d" % ("diagnostics the front end raised", totals["diag"]))
    print("")
    print("By directory:")
    print("  %-16s %6s %10s %10s %8s" % ("group", "files", "instr", "unknown", "share"))
    for name in sorted(by_dir):
        d = by_dir[name]
        print("  %-16s %6d %10d %10d %7.1f%%"
              % (name, d["files"], d["instr"], d["instr_unk"],
                 pct(d["instr_unk"], d["instr"])))
    print("")
    print("Unknown instructions by opcode (which lowering rules to fix first):")
    table(by_op, totals["instr_unk"], args.top, "opcode")
    print("")
    print("Unknown types the front end did not even complain about:")
    print("  Five of the lowering diagnostics in compiler/tir/lower.orb fire "
          "exactly")
    print("  once per instruction they make `unknown`, and their counts match "
          "the opcode")
    print("  counts above exactly: E2001=load, E2002=binary op, E2003=unary op,")
    print("  E2004=member read, E2005=call result.")
    print("  Everything left over is `unknown` with no diagnostic, which is the "
          "part")
    print("  that reaches codegen silently.")
    print("")
    print("  %-34s %9d  %5.1f%% of all unknown"
          % ("unknown with no diagnostic", silent,
             pct(silent, max(totals["instr_unk"], 1))))
    print("")
    print("What the front end gives up on, by node class (E3000/E3001):")
    if not by_giveup:
        print("  (nothing: every give-up message the probe read is tallied)")
    give_rows = sorted(by_giveup.items(), key=lambda kv: -kv[1])[:args.top]
    for message, count in give_rows:
        kind = message.split(":")[-1].strip()
        print("  %-22s %9d  %s" % (kind, count, message.split(" to TIR")[0]))
    if len(by_giveup) > len(give_rows):
        print("  ... %d more classes (--top raises the cap)"
              % (len(by_giveup) - len(give_rows)))
    print("")
    origin_buckets, origin_top = name_origins(rows, dirs)
    sorted_loads = sum(origin_buckets.values())
    e2001 = by_code.get("E2001", 0)
    print("What the %d unknown loads read, by where the name is declared "
          "(the E2001 count is %d):" % (sorted_loads, e2001))
    for bucket, n in origin_buckets.most_common():
        names = ", ".join("%s %d" % (k, v) for k, v in origin_top[bucket].most_common(5))
        print("  %-32s %7d  %s" % (bucket, n, names))
    if sorted_loads != e2001:
        print("  NOTE: %d identifiers sorted against %d E2001 diagnostics -- the"
              " probe line and the code count are not one thing this run."
              % (sorted_loads, e2001))
    print("")
    load_split = Counter()
    for r in rows:
        load_split.update(r.get("load", Counter()))
    split_total = sum(load_split.values())
    print("Unknown loads split by whether the reading function binds the name "
          "(%d split, the `load` opcode counts %d):"
          % (split_total, by_op.get("load", 0)))
    for kind, n in load_split.most_common():
        print("  %-32s %7d" % (kind, n))
    if split_total != by_op.get("load", 0):
        print("  NOTE: %d split against %d unknown loads -- the probe's split and "
              "the opcode tally are not one thing this run."
              % (split_total, by_op.get("load", 0)))
    print("")
    print("Front-end diagnostics by code (a file that errors is not a typed file):")
    table(by_code, max(totals["diag"], 1), args.top, "code")
    print("")
    print("Files with the most unknown types:")
    worst = sorted(rows, key=lambda r: r.get("instr_unk", 0), reverse=True)[:args.top]
    print("  %-46s %8s %8s %7s" % ("file", "instr", "unknown", "share"))
    for r in worst:
        print("  %-46s %8d %8d %6.1f%%"
              % (r["path"][:46], r.get("instr", 0), r.get("instr_unk", 0),
                 pct(r.get("instr_unk", 0), r.get("instr", 0))))
    print("")
    print("Finished unknown census: %d/%d instructions unknown (%.1f%%) over %d files"
          % (totals["instr_unk"], totals["instr"],
             pct(totals["instr_unk"], totals["instr"]), totals["files"]))
    print("This is the measurement only. scripts/unknown_ratchet.py decides "
          "whether it is allowed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
