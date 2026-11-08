#!/usr/bin/env python3
"""The corpus measurements: eight tools that count, fuzz and time, one entry point.

Each tool keeps its own command, its own flags and its own closing line:

    census             the unknown-type count over the corpus; closes with
                       "Finished unknown census: N/M instructions unknown ..."
    ratchet            the D7 one-way gate over that count; closes with
                       "Finished unknown-count: N (baseline M, ratchet
                       holds|broken)" or "Finished unknown-count: not
                       measured ..."
    diff-fuzz          the differential fuzzer against a Python reference;
                       closes with "Finished diff-fuzz: N/M agree with the
                       reference across K cases (seed S, sha H)"
    routes             the MSYS2 route-argument probe; closes through
                       out.finish("routes-probe", ...)
    phase-times        wall and CPU time per compiler phase; closes through
                       out.finish("phase-times", ...)
    measure-selfhost   RSS and timing across the bootstrap phases; closes
                       with "Finished measure: N phase record(s) written"
    emit-ir            emits the IR corpus and its hash manifest; its
                       self-test closes "Finished emit-ir-corpus self-test:
                       N/N"
    ir-census          unknown register types in the emitted IR; closes with
                       "Finished ir-unknown-census: ..." and its self-test
                       "Finished ir-unknown-census self-test: N/N"

The gate labels in `scripts/gate_registry.py` (`unknown_census`,
`unknown_ratchet`, `diff_fuzz`, `routes_probe`) do not change here, and
neither do the verdict lines `scripts/alive_check.py` matches:
`python scripts/measure.py census --compiler PATH --cc CC` prints what
`python scripts/unknown_census.py --compiler PATH --cc CC` printed.

Every `--self-test` of the eight tools survives as that subcommand's
`--self-test`: `ratchet`, `phase-times`, `emit-ir` and `ir-census` carry one
each. Exit codes are unchanged: `ratchet` answers 0, 1 or 2; `measure-selfhost`
0, 1 or 2; `diff-fuzz` 0 or 1 unless `--strict`; the rest 0 or 1.

Names that collided when the eight became one file. Each was resolved at its
first occurrence below, and the resolution never merged two behaviours:

  `ROOT`         six tools computed the same string with the same two
                 dirname calls; one definition here.
  `_fp_default`  census, ratchet and diff_fuzz carried the same helper that
                 asks dev.py for the fixed point; one definition here.
  `main`         one per tool, so it is now `cmd_<subcommand>(args)`.
  `self_test`    four tools had one: `self_test_ratchet`,
                 `self_test_phase_times`, `self_test_emit_ir` and
                 `self_test_ir_census`, each wired to that subcommand's
                 `--self-test`.
  `SCHEMA`       `unknown_ratchet` sets it to 1 and `emit_ir_corpus` to
                 "r6-ir-corpus/1"; the emit section names its one
                 `IR_SCHEMA`.
  `discover`     `unknown_census` and `emit_ir_corpus` walk corpora with
                 different rules; the emit section names its one
                 `ir_discover`.
  `CENSUS`       the ratchet ran the census as a subprocess of
                 `unknown_census.py`; it now runs this file with the
                 `census` subcommand, so the `--json` seam between them is
                 the same document it always read.
  `AMALGAMATE`   `measure_selfhost` ran `scripts/amalgamate.py` in a
                 subprocess; it now runs `scripts/trust.py` with the
                 `amalgamate` subcommand.

The `Usage:` lines inside each section header comment name the current
entry point: `python scripts/measure.py <subcommand> [flags]`. The rest of
that prose is the reason each tool exists, and it moved with the code.

To change one of these tools, edit its section, then run
`python scripts/measure.py <subcommand> --self-test` where it has one and the
subcommand itself.
"""

import argparse
import ctypes
import hashlib
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
from _common import build_env, resolve_cc  # noqa: E402
from orbit_routes import RoutePathError, normalize_route_path  # noqa: E402

# ROOT: the string two dirname calls, as six of the eight tools computed it.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# SELF is this file, so the ratchet can run the census in a subprocess exactly
# as it ran scripts/unknown_census.py; TRUST is the other merged entry point,
# so measure-selfhost can run the amalgamation as a subprocess.
SELF = os.path.abspath(__file__)
TRUST = os.path.join(os.path.dirname(SELF), "trust.py")
# The relative spelling phase-times and measure-selfhost build from, with the
# repo as the working directory.
MAIN_ORB = os.path.join("compiler", "host", "main.orb")
CANONICAL_C = os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c")


def _fp_default():
    """The fixed point a run uses when nobody named one: asked of `dev.py`, not
    guessed. The literal this replaces pointed at `ROOT/orbit.exe`, and a
    compiler sitting at the repository root is not merely untidy -- it satisfies
    `doctor_gate`'s three `--fix` goldens and silently voids `cli_probe`'s
    `cc-include-failure-is-not-a-missing-toolchain` probe, because that probe
    asserts a C include failure a compiler able to see `runtime/` never
    produces. That constraint is written down in `dev.fp_path()`; asking for it
    is how a tool stops re-deriving it wrong.
    """
    import dev
    return str(dev.fp_path())


_DESC_census = (
    'Count `unknown` types across the corpus (measurement; scripts/measure.py ratchet is the gate that holds it)')
_DESC_ratchet = (
    'Fail if the unknown-type count went up (one-way ratchet)')
_DESC_diff_fuzz = (
    'Differential fuzzer: Orbit vs a reference implementation')
_DESC_routes = (
    'Route-argument normalization probe: the MSYS2 Windows shell translation stays repaired')
_DESC_phase_times = (
    'Wall and CPU time per compiler phase, for three programs.')
_DESC_measure_selfhost = (
    'Measure self-host resource usage (Phase 0)')
_DESC_emit_ir = (
    'Emit the designated IR corpus with `orbit build --emit-ir`.')
_DESC_ir_census = (
    'Register types the emitted IR leaves `unknown`, by defining opcode')

# ---- from scripts/unknown_census.py ----
# Unknown-type census: how much of the corpus the front end cannot type.
#
# This is the MEASUREMENT. It never fails the build on a count, and that is
# deliberate: a zero-bar gate is a gate everybody disables. The count is held to
# a one-way ratchet one level up, by `scripts/measure.py ratchet`, which reads
# this output, compares it to a committed baseline, and fails if the number went
# up. That split is the whole defence -- see DECISIONS.md D7 -- and it is why the
# count is worth taking seriously: it can only go down, and moving it takes a
# deliberate, recorded act.
#
# Making `unknown` detectable is core-zone work, and doing it without a number is
# a guess: the question "how much of the corpus is currently unknown?" has to be
# answerable before "make unknown an error" can be scoped, prioritised, or
# regression-checked against. This prints that number, and prints the per-opcode
# and per-directory breakdown that says which front-end rules would pay for it.
#
# An `unknown` register is one the front end had no type for. Every type rule
# downstream of it is skipped, which is why it is contagious and why so much of
# the emitted C is `(void*)(uintptr_t)` casts. The count is the size of the hole
# the type work has to close.
#
# The measurement runs in-process through the front end itself
# (`scripts/unknown_census.orb`), not through `orbit check`, because `check` says
# only whether a file is clean. A file full of `unknown` and no diagnostics is
# still a file the compiler does not understand.
#
# Usage:
#     python scripts/measure.py census [--compiler PATH] [--cc CC] [--dir D]...
#                                      [--json] [--top N] [--strict]
#
# With `--json`, stdout is a single JSON object and nothing else -- the banner
# goes to stderr -- so the output can be consumed by a program. The keys
# `unknown_instructions`, `unknown_without_diagnostic` and
# `files_detail[].unknown_instructions` are the machine contract;
# `scripts/measure.py ratchet` reads exactly those.
#
# Exit code is 0 whatever the census finds. `--strict` exits non-zero only when
# the census could not run at all (probe did not build, corpus empty), which is
# an operational failure rather than a measurement.
#!/usr/bin/env python3



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


FN_RE = re.compile(r"^\s*fn\s+([A-Za-z_]\w*)", re.M)
EXTERN_FN_RE = re.compile(r"^\s*extern\s+fn\s+([A-Za-z_]\w*)", re.M)


def callee_origins(rows, dirs):
    """Sort the E2005 callees by the table that would have to answer for them.

    A callee spelled with a leading dot is a method read off a receiver this pass
    cannot type, and no declaration fixes it: the receiver's type is the missing
    table. A bare name is sorted by where a function of that name lives, and an
    `extern fn` is kept apart from an `fn` because a builtin is imported rather
    than declared in the file that calls it.
    """
    fns = {}
    externs = {}
    imports = {}
    for path in discover(dirs):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        key = rel(path)
        fns[key] = set(FN_RE.findall(text))
        externs[key] = set(EXTERN_FN_RE.findall(text))
        imports[key] = [rel(os.path.normpath(os.path.join(os.path.dirname(path), m)))
                        for m in IMPORT_RE.findall(text)]
    declared_anywhere = set()
    for names in fns.values():
        declared_anywhere |= names
    builtin_anywhere = set()
    for names in externs.values():
        builtin_anywhere |= names

    buckets = Counter()
    pairs = []
    for r in rows:
        path = r["path"]
        own = fns.get(path, set())
        direct = set()
        for e in imports.get(path, []):
            direct |= fns.get(e, set())
            direct |= externs.get(e, set())
        for callee, n in r.get("call", Counter()).items():
            if callee.startswith("."):
                bucket = "a method on a receiver this pass cannot type"
            elif callee == "(expression)":
                bucket = "a callee that is not a name"
            elif callee in own:
                bucket = "a function this file declares"
            elif callee in direct:
                bucket = "a function or builtin in a file this one imports"
            elif callee in declared_anywhere:
                bucket = "a function in a file this one does not import"
            elif callee in builtin_anywhere:
                bucket = "a builtin in a file this one does not import"
            else:
                bucket = "a name no corpus file declares"
            buckets[bucket] += n
            pairs.append((n, path, callee))
    pairs.sort(reverse=True)
    return buckets, pairs


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
                   "giveup": Counter(), "name": Counter(), "load": Counter(),
                   "member": Counter(), "call": Counter()}
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
        elif parts[0] == "MEMBER" and cur is not None:
            # MEMBER <count> cannot type the member read .<field>: the last word
            # is the field, and one field repeated over files is one rule to fix.
            try:
                cur["member"][parts[-1]] += int(parts[1])
            except (ValueError, IndexError):
                pass
        elif parts[0] == "CALL" and cur is not None:
            # CALL <count> cannot type the result of this call <callee>: the last
            # word is what the file tried to call.
            try:
                cur["call"][parts[-1]] += int(parts[1])
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


def cmd_census(args) -> int:
    out.set_quiet(args.quiet)

    banner = ("Unknown-type census -- measurement, not a gate. The number is "
              "held to a one-way ratchet by scripts/measure.py ratchet.")
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
                 "scripts/measure.py ratchet")
        # stdout is the JSON and nothing else, so `--json > f.json` is a file
        # another program can read. The banner has already gone to stderr.
        print(json.dumps({
            "schema": 1,
            "source": "measure.py census",
            "note": "measurement; the gate is measure.py ratchet (D7)",
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
        note = message.split(" to TIR")[0]
        # A message with no node class in it is its own class name, and printing it
        # twice makes the row look like two different give-ups. The reader wants the
        # class in column one and the sentence that explains it in column two; when
        # there is no shorter class, the sentence goes in column one once.
        if note == kind:
            note = ""
        print("  %-22s %9d  %s" % (kind, count, note))
    if len(by_giveup) > len(give_rows):
        print("  ... %d more classes (--top raises the cap)"
              % (len(by_giveup) - len(give_rows)))
    give_pairs = []
    for r in rows:
        for message, n in r.get("giveup", Counter()).items():
            give_pairs.append((n, r["path"], message))
    give_pairs.sort(reverse=True)
    print("  The largest single give-ups (file, class, count):")
    for n, path, message in give_pairs[:args.top]:
        print("  %-40s %-26s %5d" % (path[:40], message.split(":")[-1].strip()[:26], n))
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
    # The pairs, not just the names: a fix that adds a missing import or widens
    # a table is chosen file by file, and the name alone does not say where.
    pairs = []
    for r in rows:
        for name, n in r.get("name", Counter()).items():
            pairs.append((n, r["path"], name))
    pairs.sort(reverse=True)
    print("")
    print("The largest single unknown loads (file, name, count):")
    for n, path, name in pairs[:args.top]:
        print("  %-40s %-28s %5d" % (path[:40], name[:28], n))
    print("")
    # The member read asked the same way: E2004's message ends with the field,
    # so a field repeated across files is one rule that would answer many of
    # them, and a field named once is a site, not a class.
    by_field = Counter()
    field_pairs = []
    for r in rows:
        for field, n in r.get("member", Counter()).items():
            by_field[field] += n
            field_pairs.append((n, r["path"], field))
    field_pairs.sort(reverse=True)
    print("What the untyped member reads ask for, by field "
          "(%d fields sorted, the E2004 count is %d):"
          % (sum(by_field.values()), by_code.get("E2004", 0)))
    table(by_field, max(sum(by_field.values()), 1), args.top, "field")
    print("  The largest single untyped member reads (file, field, count):")
    for n, path, field in field_pairs[:args.top]:
        print("  %-40s %-28s %5d" % (path[:40], field[:28], n))
    print("")
    by_callee = Counter()
    for r in rows:
        by_callee.update(r.get("call", Counter()))
    buckets, sorted_pairs = callee_origins(rows, dirs)
    print("What the untyped calls ask for, by what was called "
          "(%d sorted, the E2005 count is %d):"
          % (sum(by_callee.values()), by_code.get("E2005", 0)))
    table(by_callee, max(sum(by_callee.values()), 1), args.top, "callee")
    print("  The untyped calls sorted by what would have to answer "
          "(%d in the buckets):" % sum(buckets.values()))
    for bucket, n in buckets.most_common():
        print("  %-52s %7d" % (bucket[:52], n))
    if sum(buckets.values()) != by_code.get("E2005", 0):
        print("  NOTE: %d sorted against %d E2005 -- the callee tally and the "
              "diagnostic count are not one thing this run."
              % (sum(buckets.values()), by_code.get("E2005", 0)))
    print("  The largest single untyped calls (file, callee, count):")
    for n, path, callee in sorted_pairs[:args.top]:
        print("  %-40s %-28s %5d" % (path[:40], callee[:28], n))
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
    print("This is the measurement only. scripts/measure.py ratchet decides "
          "whether it is allowed.")
    return 0


# ---- from scripts/unknown_ratchet.py ----
# The unknown-type count, held to a one-way ratchet. This is the gate (D7).
#
# `unknown` is not a detail of the type system, it is the mechanism. Every type
# rule downstream of an `unknown` register is skipped, so an unknown name, an
# unknown field, an unknown argument type and an unknown body all pass, and 46% of
# them produce no diagnostic at all. A count that can only go down turns "do not
# regress this" from a rule people follow into a property the build enforces.
#
# It does not fail because the count is HIGH. 19.5% of inferred types are unknown
# today and a zero-bar gate is a gate everybody disables, so the only thing that
# fails here is a count that went UP relative to a committed baseline.
#
# Three numbers are ratcheted, all already emitted by scripts/measure.py census:
#
#     unknown_per_mille            every instruction the front end typed `unknown`,
#                                  per thousand  -- may only go DOWN
#     silent_per_mille             the ones it did not even complain about,
#                                  per thousand  -- may only go DOWN
#     instructions                 the corpus itself  -- may only go UP
#
# The second is the sharper one: those reach codegen silently, and a silent
# defect is by definition one the compiler accepts. It measures 0 on the whole
# corpus (2026-11-02, 209 files, 20,003 unknown instructions), because each of
# the five opcode classes that can produce an `unknown` carries its own lowering
# diagnostic -- E2001 load, E2002 binary, E2003 unary, E2004 member, E2005 call.
# The residue is therefore a guard, not a to-do: a new opcode that types
# `unknown` without a diagnostic, or one of the five that stops firing once per
# instruction, moves it off zero and this gate fails.
#
# Usage:
#     python scripts/measure.py ratchet [--compiler PATH] [--cc CC]
#     python scripts/measure.py ratchet --write-baseline [--allow-regression]
#     python scripts/measure.py ratchet --self-test
#
# Exit code:
#     0  the count held, or went down
#     1  the count went up (or a number went missing, or the baseline is broken)
#     2  the measurement could not be taken at all
#
# Raising the baseline is a deliberate act: `--write-baseline` refuses to move a
# number up unless `--allow-regression` is also given, and prints the delta and
# the per-file movers either way. That is the difference between a ratchet and a
# number in a file nobody looks at.
#!/usr/bin/env python3




# The baseline lives next to the tool that measures it, in a directory of its
# own so that "what is committed truth about the census" is one `ls`.
DEFAULT_BASELINE = os.path.join(ROOT, "scripts", "baselines", "unknown_count.json")

# Both move one way only. `instructions` is deliberately NOT here: the corpus
# legitimately grows, and a gate that fails when a file is added is a gate that
# gets deleted.
# One-way, on rates rather than counts, so a corpus that grows is not a
# regression. See the note in read_measurement() for why the first version was
# wrong.
RATCHETED = ("unknown_per_mille", "silent_per_mille")

# One number is ratcheted the other way: the instruction total may only GROW.
# A rule that makes the front end give up earlier does not type more, it lowers
# less, and the rate it leaves behind looks better only because the corpus
# shrank. Measured 2026-11-08: an attempt at `match` in value position took the
# total from 149,050 to 105,504 instructions while the rate stayed at 0 per
# mille, so the rate ratchet alone would have called it an improvement. A file
# added to the corpus moves this number up and must never fail the gate; a
# number that falls means TIR the corpus used to have is gone.
GROW_ONLY = ("instructions",)

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

    Assumed about `scripts/measure.py census --json` today: stdout is one JSON
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
        cmd = [sys.executable, SELF, "census", "--json"]
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

    # The ratchet is on a RATE, not a count.
    #
    # The first version ratcheted `unknown_instructions` and deliberately did
    # not ratchet `instructions`, on the grounds that the corpus legitimately
    # grows and a gate that fails when a file is added is a gate that gets
    # deleted. Those two decisions contradict each other: the corpus growing
    # raises the count just as surely as it raises the denominator. The
    # first thing the core agent's work did was add test files, and the
    # ratchet fired at +110 on a change that had actually *improved* the
    # ratio from 29.3% to 29.0%.
    #
    # Per-thousand-instructions is stable when the corpus grows and still
    # falls when the language improves. The absolute count stays in the
    # baseline as information, so padding the corpus to move the rate would be
    # visible rather than invisible.
    total_instructions = data.get("instructions")
    if not isinstance(total_instructions, int) or total_instructions <= 0:
        return None, ("census reports %r instructions; the rate needs a positive "
                      "denominator" % (total_instructions,))
    for _key in ("unknown_instructions", "unknown_without_diagnostic"):
        if not isinstance(data.get(_key), int):
            return None, ("census output has no integer %s. The reader in "
                          "read_measurement() needs those keys and will not guess."
                          % _key)
    data["unknown_per_mille"] = int(
        round(1000.0 * data["unknown_instructions"] / total_instructions))
    data["silent_per_mille"] = int(
        round(1000.0 * data["unknown_without_diagnostic"] / total_instructions))

    missing = [k for k in RATCHETED + GROW_ONLY if not isinstance(data.get(k), int)]
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
                      "    python scripts/measure.py ratchet --write-baseline" % path)
    except (OSError, ValueError) as exc:
        return None, "baseline %s is unreadable: %s" % (path, exc)
    if not isinstance(base, dict) or base.get("schema") != SCHEMA:
        return None, ("baseline %s has no schema %d; refusing to guess what it "
                      "means" % (path, SCHEMA))
    totals = base.get("totals")
    if not isinstance(totals, dict):
        return None, "baseline %s has no totals" % path
    for key in RATCHETED + GROW_ONLY:
        if not isinstance(totals.get(key), int):
            return None, "baseline %s has no integer totals.%s" % (path, key)
    by_file = base.get("by_file")
    if not isinstance(by_file, dict):
        return None, "baseline %s has no by_file map" % path
    # The gate is on a rate, so the absolute count lives in `context` now. The
    # sum check still has to hold, and against the absolute count, not against
    # the per-mille figure -- comparing a sum of counts to a rate is the kind of
    # thing that passes by accident.
    context = base.get("context")
    absolute = context.get("unknown_instructions") if isinstance(context, dict) else None
    if not isinstance(absolute, int):
        return None, ("baseline %s has no context.unknown_instructions; the "
                      "per-file map is checked against the absolute count, which "
                      "is no longer in totals" % path)
    if sum(by_file.values()) != absolute:
        return None, ("baseline %s is inconsistent: by_file sums to %d but "
                      "context.unknown_instructions is %d"
                      % (path, sum(by_file.values()), absolute))
    return base, ""


def write_baseline(path, data, allow_regression, prev):
    """Record today's measurement. Refuses to raise a number by accident."""
    totals = {k: data[k] for k in RATCHETED + GROW_ONLY}
    if prev is not None:
        raised = {k: totals[k] - prev["totals"][k] for k in RATCHETED
                  if totals[k] > prev["totals"][k]}
        shrank = {k: totals[k] - prev["totals"][k] for k in GROW_ONLY
                  if totals[k] < prev["totals"][k]}
        moved = dict(raised)
        moved.update(shrank)
        if moved and not allow_regression:
            out.fail("Refusing to move the baseline the wrong way: " +
                     ", ".join("%s %+d" % (k, v) for k, v in sorted(moved.items())))
            out.tip("if the move is real and intended, re-run with "
                    "--allow-regression and say why in the commit message")
            return 1
    payload = {
        "schema": SCHEMA,
        "note": ("Ratchet baseline for the unknown-type count. The two rates "
                 "may only go down and the instruction total may only go up. "
                 "Written by scripts/measure.py ratchet --write-baseline. Do not "
                 "hand-edit a number the wrong way; that is what the gate is for."),
        "totals": totals,
        # Context, not ratcheted: the corpus legitimately grows, so the absolute
        # count is recorded for information and the RATE is what is gated.
        "files": data.get("files"),
        "instructions": data.get("instructions"),
        "context": {"unknown_instructions": data.get("unknown_instructions"),
                    "unknown_without_diagnostic": data.get("unknown_without_diagnostic")},
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
    for key in GROW_ONLY:
        got, want = data[key], base["totals"].get(key)
        if want is None:
            ok = False
            lines.append("  %-28s %6d  baseline has no %s" % (key, got, key))
        elif got < want:
            ok = False
            lines.append("  %-28s %6d  baseline %6d  %+d  the corpus shrank"
                         % (key, got, want, got - want))
        else:
            lines.append("  %-28s %6d  baseline %6d  %s"
                         % (key, got, want, "unchanged" if got == want
                            else "+%d" % (got - want)))
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
def _measurement(total, silent, files=None, instructions=100):
    files = files or {"a.orb": total}
    return {"unknown_instructions": total,
            "unknown_without_diagnostic": silent,
            "unknown_per_mille": total * 10,
            "silent_per_mille": silent * 10,
            "files": len(files), "instructions": instructions,
            "files_detail": [{"path": p, "unknown_instructions": n}
                             for p, n in files.items()]}


_BASE = {"schema": SCHEMA,
         "totals": {"unknown_per_mille": 1000, "silent_per_mille": 400,
                    "instructions": 100},
         "by_file": {"a.orb": 100}}


def self_test_ratchet():
    """Each case is a synthetic measurement against a synthetic baseline.

    This exists because the most expensive property of a gate is that it can
    fail, and the cheapest way to keep that property is to assert it rather
    than hope. Every branch that returns non-zero in main() is exercised here.
    """
    cases = [
        # name, measurement, baseline, per_file, expect_ok, expect_in_text
        ("identical measurement holds", _measurement(100, 40), _BASE, False, True, None),
        ("improvement holds", _measurement(90, 30), _BASE, False, True, None),
        ("rate rose fails", _measurement(101, 40), _BASE, False, False, "unknown_per_mille"),
        ("rate rise names the delta", _measurement(101, 40), _BASE, False, False, "+10"),
        ("silent rate rose fails", _measurement(100, 41), _BASE, False, False, "+10"),
        ("a new file that brings unknowns fails",
         _measurement(150, 40, {"a.orb": 100, "b.orb": 50}), _BASE, False, False, "rose"),
        ("a rise the total hides by a fall still fails",
         _measurement(101, 40, {"a.orb": 99, "b.orb": 2}), _BASE, False, False, "baseline"),
        ("per-file mode catches it where the total does not",
         _measurement(100, 40, {"a.orb": 99, "b.orb": 1}), _BASE, True, False, "per-file"),
        ("the same rise is tolerated with per-file mode off",
         _measurement(100, 40, {"a.orb": 99, "b.orb": 1}), _BASE, False, True, None),
        # The rate can hold while the corpus shrinks, which is what a rule that
        # gives up earlier looks like. This is the case the rate alone missed.
        ("a corpus that lost instructions fails",
         _measurement(90, 30, instructions=90), _BASE, False, False, "shrank"),
        ("a corpus that grew holds", _measurement(90, 30, instructions=120),
         _BASE, False, True, None),
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
         {"schema": SCHEMA, "totals": _BASE["totals"],
          "context": {"unknown_instructions": 100}, "by_file": {"a.orb": 7}},
         "inconsistent"),
        ("no absolute count to check by_file against",
         {"schema": SCHEMA, "totals": _BASE["totals"], "by_file": {"a.orb": 100}},
         "context.unknown_instructions"),
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
    # The --from-json seam alive_check.py now depends on for its single census:
    # a census document on disk must read exactly like a live census, and a
    # document without the keys must be a loud failure, never a silent zero.
    census_doc = {"instructions": 1000,
                  "unknown_instructions": 290,
                  "unknown_without_diagnostic": 120,
                  "files": 5, "functions": 50,
                  "files_detail": [{"path": "a.orb", "functions": 40,
                                    "instructions": 700,
                                    "unknown_instructions": 200},
                                   {"path": "b.orb", "functions": 10,
                                    "instructions": 300,
                                    "unknown_instructions": 90}]}
    census_path = os.path.join(tmp, "census.json")
    with open(census_path, "w", encoding="utf-8") as fh:
        json.dump(census_doc, fh)
    data, why = read_measurement(from_json=census_path)
    total += 1
    if data is not None and data.get("unknown_per_mille") == 290 \
            and data.get("silent_per_mille") == 120:
        passed += 1
        print("  ok    from-json reads a census document             -> hold")
    else:
        out.fail("  WRONG from-json did not read the census document -> %s" % why)
    with open(census_path, "w", encoding="utf-8") as fh:
        json.dump({"instructions": 1000, "unknown_instructions": 7,
                   "unknown_without_diagnostic": 2}, fh)
    data, why = read_measurement(from_json=census_path)
    total += 1
    if data is None and "files_detail" in why:
        passed += 1
        print("  ok    from-json without files_detail is rejected    -> fail")
    else:
        out.fail("  WRONG from-json accepted a document with no detail")
    out.finish("ratchet self-test", passed, total)
    return 0 if passed == total else 1



# --------------------------------------------------------------------------


def cmd_ratchet(args) -> int:
    out.set_quiet(args.quiet)

    if args.self_test:
        return self_test_ratchet()

    data, why = read_measurement(args.from_json, args.compiler, args.cc, args.dir)
    if data is None:
        out.fail("Failed unknown-count: the census could not be measured, and a "
                 "ratchet that cannot see the number cannot hold it.")
        out.fail("  " + why.replace("\n", "\n  "))
        out.ci_error(out.scrub_ci("unknown-count: measurement failed: " + why))
        out.tip("python scripts/measure.py census --compiler <orbit> --strict")
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
            "purpose: python scripts/measure.py ratchet --write-baseline "
            "--allow-regression")
    print("Finished unknown-count: %d (baseline %d, ratchet broken, +%d)"
          % (got, want, got - want))
    return 1


# ---- from scripts/diff_fuzz.py ----
# Differential fuzzer: Orbit's arithmetic against a reference implementation.
#
# `scripts/fuzz_frontend.py` looks for crashes. A crash is loud: it prints a
# message, returns a signal, and stops the run. The failures this repo actually
# ships are the quiet ones -- a program that compiles clean, runs, and serves the
# wrong number with no diagnostic anywhere. A crash-only fuzzer is structurally
# unable to find those, because a wrong answer is not an event.
#
# So this generates small programs whose value is computable by a reference
# implementation, runs them, and compares. Python 3 is the reference because it is
# what a reader would assume Orbit means, with the three places it does not mean
# it corrected explicitly: integers are 32-bit two's complement, `/` and `%`
# truncate toward zero rather than flooring, and an integer literal outside the
# 32-bit signed range is an error rather than a wrap.
#
# The classes are the ones already known to be wrong, so the fuzzer proves itself
# first and then widens:
#
#     int-arith     + - * / % over signed operands, including 0 and the edges
#                   around 2^31-1, 2^31 and 2^63
#     int-literal   decimal, 0x, `_` separators, and the forms that do not exist
#                   yet (0b, 0o, exponent), in a call position AND in a binding
#     div-zero      `/ 0`, `% 0`, `INT_MIN / -1`, and the sign of the result
#     string-escape the six escapes the language documents, `\xHH`, the C
#                   escapes it does NOT document, and the malformed ones
#     float         round-tripping; floats are not implemented at all today, so
#                   this class is reported on its own line and never mixed in
#
# It is DETERMINISTIC. `--seed` fixes the corpus, generators run in a fixed
# order, and the summary prints a SHA-256 of the case list, so two runs on two
# machines can be shown to have run the same programs. A fuzzer whose corpus
# moves cannot tell you whether a finding is new.
#
# REPORT ONLY by default. It exits non-zero only with `--strict`, because a fuzzer
# that fails the build on the day a finding appears is a fuzzer that gets turned
# off on the day a finding appears. The findings are the deliverable.
#
# `scripts/diff_fuzz_ratchet.py` used to hold that count one way. It was retired
# when the corpus reached 0 disagreements in 678 cases: the baseline has to carry
# a non-empty by_class map so that every row is a count which can only fall, and
# a corpus with no disagreements has no rows. A ratchet with a floor of zero
# cannot catch a regression, because a regression is the number going up. Read
# the count, and treat a non-zero one as the finding it is.
#
# Usage:
#     python scripts/measure.py diff-fuzz --compiler PATH [--seed N] [--iterations N]
#                                [--batch N] [--cc CC] [--only CATEGORY]...
#                                [--json PATH] [--strict] [--list]
#!/usr/bin/env python3



INT_MIN, INT_MAX = -(2 ** 31), 2 ** 31 - 1
SEED = 20240928
SENTINEL = "--df8<--"

CATEGORIES = ("int-arith", "int-literal", "int-literal-bind", "div-zero",
              "string-escape", "float")


# --------------------------------------------------------------------------
# The reference. Everything here is what a reader would assume Orbit means.
# --------------------------------------------------------------------------
def i32(x):
    """Wrap to signed 32-bit, which is what orbit_int is."""
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x >= 0x80000000 else x


def c_div(a, b):
    """C99 integer division: truncate toward zero. Python's // floors."""
    q = abs(a) // abs(b)
    return i32(-q if (a < 0) != (b < 0) else q)


def c_mod(a, b):
    """C99 remainder: the sign follows the dividend, not the divisor."""
    return i32(a - c_div(a, b) * b)


# --------------------------------------------------------------------------
# Cases.
# --------------------------------------------------------------------------
class Case:
    """One program, and what a correct compiler does with it.

    kind is the expectation, and there are exactly five:
      value     the program's stdout must be exactly `expect`
      bytes     the program's stdout must be exactly `expect` (a bytes object),
                used where the output is not line-shaped
      either    `expect` OR a clean refusal. For a form the language does not
                have yet, where refusing is the correct answer today and the
                wrong answer tomorrow. A fuzzer that fails the day a missing
                feature is implemented is a fuzzer that gets switched off.
      reject    the program must NOT build, and must say why
      diagnose  the program must not die on a signal and must not print a
                number: a division by zero is either a compile-time or a
                runtime diagnostic, and a signal is neither
    """

    def __init__(self, category, source, kind, expect, note=""):
        self.category = category
        self.source = source        # the Orbit source of one `print(...)` call
        self.kind = kind
        self.expect = expect
        self.note = note

    def program(self):
        body = "".join("    %s\n" % line for line in self.source.splitlines())
        return "fn main() -> int {\n%s    return 0\n}\n" % body

    def label(self):
        return self.source


def literal_cases(rng, n_literals):
    """Integer literals: the forms that exist, and the ones that do not.

    Two judgement calls, both stated so they can be argued with:

    - `-2147483648` is a `reject` case in name only; the value IS representable
      (it is the minimum int), so the case expects the value. What must not
      happen is the bare `2147483648`, which is not a value the type has.
    - a form the language does not have (`0b`, `0o`, an exponent) is a GAP, not
      a wrong answer, so it gets the `either` expectation: refusing it is
      correct today, and the day someone implements it the case starts
      asserting the value instead. That is the useful direction for a fuzzer to
      fail in.
    """
    cases = []
    for n in (0, 1, 7, 9, 10, 42, 255, 256, 1000, 65535, INT_MAX, INT_MAX - 1):
        cases.append(Case("int-literal", "print(%d)" % n, "value", str(n)))
    cases.append(Case("int-literal", "print(-%d)" % -INT_MIN, "value", str(INT_MIN),
                      "the minimum int, written as a negation: representable"))
    for text, val in (("0x0", 0), ("0x10", 16), ("0xFF", 255), ("0x7FFFFFFF", INT_MAX),
                      ("1_000", 1000), ("1_000_000", 1000000), ("1_0_0", 100)):
        cases.append(Case("int-literal", "print(%s)" % text, "value", str(i32(val)),
                          "hex and the `_` separator"))
    # `_` works in a decimal literal and not in a hex one. A reader who has
    # learned one has every reason to expect the other.
    for text, want in (("0x1_000", "4096"), ("0x0_0", "0")):
        cases.append(Case("int-literal", "print(%s)" % text, "either", want,
                          "`_` separates digits in decimal (1_0_0 = 100) but "
                          "not in hex"))
    # out of range: a literal is a value the type does not have, so it has to
    # be refused. Folding it silently is how 2147483648 became -2147483648.
    for text in ("2147483648", "4294967296", "9223372036854775807",
                 "18446744073709551616", "99999999999999999999999",
                 "0xFFFFFFFF"):
        cases.append(Case("int-literal", "print(%s)" % text, "reject", None,
                          "out of range for orbit_int (32-bit signed)"))
    # `0x1_0000000` used to be in that list. It is 268435456, which fits a
    # signed 32-bit int with room to spare, so the compiler was right to accept
    # it and the fuzzer was wrong to require a refusal. The separator is
    # honoured in hex now too, so the literal is one number rather than 0x1
    # followed by an identifier. Asserted below, in the accepted forms, where
    # it belongs.
    # the forms that do not exist yet
    # The exponent forms are floats, and they print as floats. These were
    # written when an exponent did not exist at all and the expectation was
    # "refuse"; when the form landed it was a float, so `1e2` is 100.0 and not
    # 100. Expecting 100 asked a float to print as an integer, which is the
    # same mistake the formatter was making.
    for text, want in (("0b1010", "10"), ("0o17", "15"),
                       ("0x1_0000000", "268435456"), ("0xFF_FF", "65535"),
                       ("1e2", "100.0"), ("2e3", "2000.0"),
                       ("2.5e3", "2500.0"), ("2.5E3", "2500.0"),
                       ("2.5e-3", "0.0025")):
        cases.append(Case("int-literal", "print(%s)" % text, "either", want,
                          "form does not exist yet: refusing is correct, "
                          "answering something else is not"))
    cases.append(Case("int-literal", "print(007)", "value", "7", "leading zeros"))
    # seeded bulk: in-range decimals are uninteresting individually, but they
    # are what makes the corpus a corpus and not eight examples.
    for _ in range(n_literals):
        v = rng.randrange(INT_MIN, INT_MAX + 1)
        cases.append(Case("int-literal", "print(%d)" % v, "value", str(v)))
    return cases


def bind_cases():
    """The same literals, in a `val` binding instead of inside a call.

    This class exists because of a measured asymmetry, not a hunch. A literal
    that is REFUSED inside `print(...)` can be silently answered with a wrong
    number one token later:

        print(0b1010)            -> Parser error
        val x: int = 0b1010      -> 0
        print(0x1_000)           -> Parser error
        val x: int = 0x1_000     -> 1

    So a fuzzer that only ever puts a literal in a call position measures half
    the behaviour of a literal. Refusing is still acceptable -- these forms do
    not exist yet -- so the expectation is `either`: a clean refusal passes, and
    any number at all has to be the right one.
    """
    forms = [
        ("0b1010", "10"), ("0b0", "0"), ("0o17", "15"), ("0o777", "511"),
        ("1e2", "100"), ("2e3", "2000"), ("0x1_000", "4096"), ("0x0_0", "0"),
        # controls: these already work and must keep working
        ("0x10", "16"), ("1_0_0", "100"), ("1_000", "1000"), ("007", "7"),
    ]
    out_of_range = ["2147483648", "4294967296", "0xFFFFFFFF"]
    cases = []
    for text, want in forms:
        cases.append(Case("int-literal-bind",
                          "val x: int = %s\nprint(x)" % text, "either", want,
                          "in a binding, not in a call"))
    for text in out_of_range:
        cases.append(Case("int-literal-bind",
                          "val x: int = %s\nprint(x)" % text, "reject", None,
                          "out of range for orbit_int (32-bit signed)"))
    return cases


def arith_cases(rng, n_arith):
    """The four integer operators over signed operands.

    `n_arith` counts CASES, so the pair count is divided by the five operators.
    """
    interesting = [0, 1, -1, 2, -2, 3, 7, -7, 10, -10, 100, -100,
                   INT_MAX, INT_MAX - 1, INT_MIN, INT_MIN + 1, 65536, -65536,
                   2147483646, -2147483647, 1073741824, -1073741824]
    pairs = [(a, b) for a in interesting for b in interesting if b != 0]
    rng.shuffle(pairs)
    pairs = pairs[:max(0, n_arith // 5 - 120)]
    for _ in range(max(0, n_arith // 5 - len(pairs))):
        pairs.append((rng.randrange(INT_MIN, INT_MAX + 1),
                      rng.randrange(INT_MIN, INT_MAX + 1)))
    cases = []
    for a, b in pairs:
        b = b or 1  # division by zero is its own class
        for op, ref in (("+", lambda x, y: i32(x + y)),
                        ("-", lambda x, y: i32(x - y)),
                        ("*", lambda x, y: i32(x * y)),
                        ("/", c_div),
                        ("%", c_mod)):
            if a == INT_MIN and b == -1 and op in "/%":
                continue  # overflows on x86; div-zero class covers the signal
            cases.append(Case("int-arith", "print((%d) %s (%d))" % (a, op, b),
                              "value", str(ref(a, b))))
    return cases


def divzero_cases():
    """Division and modulo by zero, and the sign of a negative result."""
    cases = []
    for a in (1, -1, 7, -7, 0, INT_MAX, INT_MIN):
        for op in ("/", "%"):
            cases.append(Case("div-zero", "print((%d) %s 0)" % (a, op), "diagnose", None,
                              "division by zero must be a diagnostic, not a signal"))
    cases.append(Case("div-zero", "print((%d) / -1)" % INT_MIN, "diagnose", None,
                      "INT_MIN / -1 overflows on x86 and raises SIGFPE"))
    cases.append(Case("div-zero", "print((%d) %% -1)" % INT_MIN, "diagnose", None,
                      "INT_MIN %% -1 is defined and equals 0"))
    # the sign of a result, which is the half of F-0014 that a log hides
    for a, b in ((-7, 2), (-7, 3), (-7, 10), (7, -2), (7, -3), (-1, 2), (1, -2)):
        cases.append(Case("div-zero", "print((%d) / (%d))" % (a, b), "value",
                          str(c_div(a, b))))
        cases.append(Case("div-zero", "print((%d) %% (%d))" % (a, b), "value",
                          str(c_mod(a, b))))
    return cases


# Escape handling, stated as a table so the expectation is a decision and not
# an accident of what Orbit happens to do.
#
# The reference implements what the language DOCUMENTS, not what C does. That
# distinction is the whole content of this section, so it is argued here rather
# than left implicit, because getting it wrong is how a fuzzer ends up
# reporting 24 permanent "disagreements" that nobody will ever fix and everybody
# learns to ignore.
#
# docs/LANGUAGE_REFERENCE.md ("Arrays and objects") says: "An ordinary string
# supports \n, \t, \r, \", \\, and the byte escape \xHH with two hex digits ...
# Anything malformed stays literal."
#
# So the rule is total: decode the escapes this language has, and write back
# exactly what the author wrote for everything else. Nothing needs a table of
# the escapes it does not have, which is why the fallback is safe. The
# alternative -- decode what C decodes -- is not a smaller rule, it is a
# different and much larger one: C's set is a table with rules of its own
# (\0 starts an octal escape, \x is greedy, \e is not standard at all), and
# every escape still outside it is a guess about what the author meant. Guessing
# is how `"\q"` becomes some other character and nobody can tell why.
#
# The three classes this moved, measured before the change, 24 cases in all:
#
#   string-escape/c-escape-is-kept-as-two-characters              17
#   string-escape/malformed-hex-escape-is-kept-literal             6
#   string-escape/unknown-escape-is-kept-literal                   1
#
# All three were the reference saying "C would decode this" about a language
# that documents six escapes. They are now ASSERTED agreements, which is a
# stronger pin than a note: if the escape behaviour ever changes, the count goes
# up and the ratchet fires. Reversing the decision is a deliberate act -- edit
# the table below, and the corpus sha moves with it.
#
# What is left in this class is one case, and it is a bug and not a decision:
# `\x00` is two hex digits, so the documented rule covers it, and the compiler
# does not decode it (F-0020, `compiler/ir/builder.orb:2481` tests the SUM of the
# two nibbles against zero instead of testing that both digits are valid). There
# is no reading of the documentation under which `\x00` stays literal.
DOCUMENTED_ESCAPES = {"n": 0x0A, "t": 0x09, "r": 0x0D, '"': 0x22, "\\": 0x5C}

# The C escapes this language does not have. Listed so the table above can be
# argued with: every one of these is a case where the compiler and C disagree
# on purpose today, and the corpus asserts the compiler.
C_ESCAPES_NOT_HERE = ("\\a", "\\b", "\\f", "\\v", "\\e", "\\0", "\\'")


class Unterminated(ValueError):
    """A string literal that never closes.

    Not a malformed ESCAPE: the backslash is not the problem, the missing quote
    is, and the parser already says so. It stays a `reject` expectation because
    the correct answer really is a diagnostic.
    """


def documented_unescape(body):
    """Decode the text BETWEEN two pairs of double quotes, as the language says.

    Raises Unterminated for a trailing backslash, which is an unterminated
    literal rather than a malformed escape. Everything else has a defined value,
    including the malformed escapes: they are the two characters the author
    wrote, which is what "stays literal" means and is the only total rule.
    """
    out_bytes = bytearray()
    i = 0
    while i < len(body):
        ch = body[i]
        if ch != "\\":
            out_bytes += ch.encode("utf-8")
            i += 1
            continue
        if i + 1 >= len(body):
            raise Unterminated("trailing backslash: the literal never closes")
        nxt = body[i + 1]
        if nxt == "x":
            hexpart = body[i + 2:i + 4]
            if len(hexpart) == 2 and re.fullmatch(r"[0-9a-fA-F]{2}", hexpart):
                out_bytes.append(int(hexpart, 16))
                i += 4
                continue
            # Malformed \x: not an escape this literal has, so the two
            # characters stay and whatever followed is ordinary text.
            out_bytes += b"\\x"
            i += 2
            continue
        if nxt in DOCUMENTED_ESCAPES:
            out_bytes.append(DOCUMENTED_ESCAPES[nxt])
            i += 2
            continue
        # Not an escape this language has: write what the author wrote. The
        # backslash goes out now and the next character is copied as ordinary
        # text by the next turn of the loop, which is the same two bytes.
        out_bytes += b"\\"
        i += 1
    return bytes(out_bytes)


def escape_cases(rng, n_escapes):
    """Well-formed escapes, C escapes the language does not document, and the
    malformed ones.

    Every body here has a defined value now, including the malformed ones, so
    every case is a `bytes` comparison except the unterminated literal. That is
    the point of the reclassification above: a case whose expectation is "or a
    refusal" cannot tell a language that decided from a language that gave up.
    """
    bodies = [
        ("\\n", "newline"), ("\\t", "tab"), ("\\r", "carriage return"),
        ('\\"', "double quote"), ("\\\\", "backslash"),
        ("\\x41", "hex A"), ("\\x7F", "hex DEL"),
        # \x00 is NOT here, and the language refuses it. An orbit_string is a
        # NUL-terminated const char*, so a string holding a zero byte is
        # truncated at that byte on the way into C. The reference happily
        # produces a b"\x00" that no orbit_string can carry, so this is a
        # refusal and not a disagreement about bytes; asserted as one below.
        # \0 is a different matter and stays in the list -- it is not a
        # documented escape, so it stays the two characters backslash-zero.
        ("\\xFF", "hex high byte"),
        ("a\\nb", "newline inside"), ("a\\tb\\rc", "several"),
        ("\\x41\\x42\\x43", "three hex bytes"),
        # escapes a C reader expects and this language does not document
        ("\\a", "bell"), ("\\b", "backspace"), ("\\f", "form feed"),
        ("\\v", "vertical tab"), ("\\e", "escape"),
        ("\\0", "NUL octal, not a documented escape"),
        ("a\\0b", "NUL octal inside a word"),
        ("\\'", "single quote"),
        # malformed: documented as staying literal, so that is the value
        ("\\x", "hex with no digits"), ("\\x4", "hex with one digit"),
        ("\\xZZ", "hex with non-hex"), ("\\q", "unknown letter"),
        ("\\", "trailing backslash"),
    ]
    for _ in range(max(0, n_escapes - len(bodies))):
        pool = "abZ019 _"
        body = "".join("\\" + rng.choice("ntrax0e") if rng.random() < 0.5
                       else rng.choice(pool) for _ in range(rng.randrange(1, 5)))
        bodies.append((body, "seeded"))
    # A string that holds a zero byte cannot be an orbit_string, so these are
    # the correct answer rather than a disagreement about bytes. Asserted as
    # refusals, so the corpus still says what it expects rather than losing
    # the coverage.
    # Only \x00, and only because it is a *documented* escape. \0 is not
    # documented, so it stays the two characters backslash-zero, the same as
    # \a, \b, \f, \v and \e. Asserting it a refusal would have been me
    # deciding the language should reject something it documents as literal.
    nul_cases = [
        Case("string-escape", 'print("\\x00")', "reject", None,
             "hex NUL: a string cannot contain a NUL byte"),
    ]
    cases = []
    for body, note in bodies:
        try:
            expect = documented_unescape(body)
        except Unterminated as exc:
            cases.append(Case("string-escape", 'print("%s")' % body, "reject", None,
                              "%s: %s" % (note, exc)))
            continue
        cases.append(Case("string-escape", 'print("%s")' % body, "bytes", expect,
                          note))
    for c in nul_cases:
        cases.append(c)
    return cases


def float_cases(rng, n_floats):
    """Float round-tripping. Literals, arithmetic, calls, comparisons, model
    fields, lists, interpolation and exponents all round-trip on the current
    tree (measured); what remains of F-0016 is the transport holes, e.g. a
    float the backend cannot see as one falling into the uintptr_t cast."""
    lits = ["1.5", "2.0", "0.1", "3.14159", "100.0", "0.5", "-2.25", "1e0" ]
    for _ in range(max(0, n_floats - len(lits))):
        lits.append("%d.%02d" % (rng.randrange(0, 1000), rng.randrange(0, 100)))
    cases = []
    for text in lits:
        try:
            expect = repr(float(text))
        except ValueError:
            continue
        # An exponent form does not exist yet, so refusing it is correct and
        # answering a truncated integer is not; the `either` kind says exactly
        # that, and starts checking the value the day it is implemented.
        kind = "either" if "e" in text else "value"
        cases.append(Case("float", "print(%s)" % text, kind, expect,
                          "exponent form" if kind == "either" else "literal"))
    for expr, ref in (("1.5 + 1.5", lambda: 3.0), ("0.5 * 4.0", lambda: 2.0),
                      ("3.0 / 2.0", lambda: 1.5), ("1.0 - 0.25", lambda: 0.75)):
        cases.append(Case("float", "print(%s)" % expr, "value", repr(ref()), expr))
    return cases


# --------------------------------------------------------------------------
# Running.
# --------------------------------------------------------------------------
class Runner:
    def __init__(self, compiler, cc, work, timeout=120):
        self.compiler = compiler
        self.cc = cc
        self.work = work
        self.timeout = timeout
        self.programs = 0

    def _env(self):
        env = dict(os.environ)
        return build_env(self.work, cc=self.cc)

    def _build(self, source, index):
        """Write a program and run it. Returns (status, stdout_bytes, note).

        --quiet is load-bearing, not cosmetic: `orbit run` prints build
        chatter (Compiled ..., wrote ...) to stdout, and stdout is what the
        batch comparison reads. Without it every batch mislines (the chatter
        counts as program lines), attribution falls back to one program per
        case, and every value compares wrong. That is how a CLI restyle
        silently retires the fuzzer's batching.
        """
        path = os.path.join(self.work, "case_%05d.orb" % index)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(source)
        try:
            proc = subprocess.run([self.compiler, "run", "--quiet", path], cwd=ROOT,
                                  env=self._env(), capture_output=True,
                                  timeout=self.timeout)
        except subprocess.TimeoutExpired:
            return "hung", b"", "no exit after %ds" % self.timeout
        self.programs += 1
        if proc.returncode in (1, 2):
            return "rejected", proc.stdout, ""
        if proc.returncode < 0 or proc.returncode >= 128:
            return "crashed", proc.stdout, "died on signal (rc=%d)" % proc.returncode
        if proc.returncode != 0:
            return "error", proc.stdout, "rc=%d: %s" % (
                proc.returncode, (proc.stderr or b"").decode("utf-8", "replace")[-200:])
        # Windows C-runtime text-mode translation: the program's \n arrives as
        # \r\n. The reference computes logical lines, so compare those: the
        # sentinel framing splits on b"\n" and every body would otherwise keep
        # a stray \r (23 false disagreements on every Windows run, plus the
        # batch falling back to one program per case). A body that really
        # contains \r still compares right: only the line ending collapses.
        return "ok", proc.stdout.replace(b"\r\n", b"\n"), ""

    def run_source(self, source, index):
        return self._build(source, index)

    def run_batch(self, cases, index):
        """Many one-line cases in one program, compared line by line.

        A build+run costs about as much whatever the program contains, so 40
        cases in one program is 40x the corpus for the same seconds. The
        contract is one output line per case, which holds because every value
        case prints exactly one integer. When the program does not deliver that
        -- it crashed, or a value printed more than one line -- the caller falls
        back to running the cases one at a time, so a batch can never hide a
        finding behind an attribution failure.
        """
        source = "fn main() -> int {\n" + "".join("    %s\n" % c.source
                                                   for c in cases) + "    return 0\n}\n"
        status, stdout, note = self._build(source, index)
        if status != "ok":
            if not note:
                note = "the batched program was %s" % (
                    "refused to compile" if status == "rejected" else status)
            return None, status, note
        lines = stdout.decode("utf-8", "replace").splitlines()
        if len(lines) != len(cases):
            return None, status, "produced %d lines for %d cases" % (len(lines), len(cases))
        return lines, status, note

    def run_bytes_batch(self, cases, index):
        """String cases in one program, each framed so its output is findable.

        The output is bytes and can contain newlines, so line splitting does not
        work; each case is printed between two sentinel lines instead, and the
        bytes between them are compared exactly. The sentinel is a fixed string
        the generator can never produce inside a body.
        """
        # One sentinel BEFORE each case and one at the very end, never two in
        # a row: a doubled sentinel would put an empty region between
        # neighbours, which is indistinguishable from a case that printed
        # nothing. The framing is then S b1 S b2 ... S bn S, which splits into
        # exactly n bodies.
        source = ("fn main() -> int {\n"
                  + "".join('    print("%s")\n    %s\n' % (SENTINEL, c.source)
                            for c in cases)
                  + '    print("%s")\n' % SENTINEL
                  + "    return 0\n}\n")
        status, stdout, note = self._build(source, index)
        if status != "ok":
            if not note:
                note = "the batched program was %s" % (
                    "refused to compile" if status == "rejected" else status)
            return None, status, note
        marker = SENTINEL.encode() + b"\n"
        if not stdout.startswith(marker):
            return None, status, "output does not start with the sentinel"
        # n cases produce n+1 sentinels, so n+1 regions, of which the first and
        # last are empty. Each region carries the newline `print` added.
        regions = stdout.split(marker)
        bodies = regions[1:-1]
        if len(bodies) != len(cases):
            return None, status, ("framing gave %d regions for %d cases"
                                  % (len(bodies), len(cases)))
        return [b[:-1] if b.endswith(b"\n") else b for b in bodies], status, note


def observed_of(case, status, stdout):
    """What Orbit actually did, in the same shape the report prints."""
    if status == "rejected":
        return "refused to compile (no diagnostic named)"
    if status == "crashed":
        return "died on a signal"
    if isinstance(case.expect, bytes):
        return repr(_one_nl_off(stdout))
    text = stdout.decode("utf-8", "replace").strip()
    return text if text else "(printed nothing)"


def check_reject(case, status, note):
    if status == "rejected":
        return None
    if status == "ok":
        return "accepted a program it must reject: %s" % (case.note or "no diagnostic")
    if status == "crashed":
        return "crashed instead of diagnosing: %s" % note
    return "failed to build for the wrong reason: %s" % note


def check_diagnose(case, status, note, stdout=b""):
    if status == "rejected":
        return None
    if status == "crashed":
        return "died on a signal instead of diagnosing: %s" % note
    if status == "hung":
        return "hung instead of diagnosing: %s" % note
    return ("answered %r where the only correct answers are a diagnostic or a "
            "refusal" % stdout.decode("utf-8", "replace").strip())


def _one_nl_off(data):
    """`print` adds exactly one newline; a case's expectation does not have it."""
    return data[:-1] if data.endswith(b"\n") else data


def check_bytes(case, got):
    if got == case.expect:
        return None
    return "wrong bytes: got %s, want %s" % (repr(got), repr(case.expect))


# --------------------------------------------------------------------------
# The sweep.
# --------------------------------------------------------------------------
def sweep(runner, corpus, batch, verbose=True):
    """Run the whole corpus. Returns (findings, agree, by_category)."""
    findings = []
    agree = 0
    by_category = {}

    def record(case, problem, status, stdout=b""):
        if problem is None:
            return True
        findings.append({"category": case.category, "kind": case.kind,
                         "source": case.source,
                         "expect": (repr(case.expect)
                                    if isinstance(case.expect, bytes)
                                    else case.expect),
                         "note": case.note, "problem": problem, "status": status,
                         "observed": observed_of(case, status, stdout),
                         "class": class_of(case, problem)})
        return False

    def tally(case):
        stats = by_category.setdefault(case.category, [0, 0])
        stats[0] += 1
        return stats

    index = 0
    # `either` cases ride with the value cases so a batch can hold them, and
    # they are the one kind that treats a refusal as a pass.
    value_cases = [c for c in corpus
                   if c.kind in ("value", "either") and "\n" not in c.source]
    bytes_cases = [c for c in corpus if c.kind == "bytes"]
    single_cases = [c for c in corpus
                    if c.kind in ("reject", "diagnose") or "\n" in c.source]

    def judge_one(case, status, stdout):
        if status != "ok":
            if status == "crashed":
                return "crashed instead of answering (%s)" % stdout.decode(
                    "utf-8", "replace")[:120]
            if status == "hung":
                return "hung: no answer at all"
            if case.kind == "either":
                return None
            if status == "rejected":
                return ("rejected a program with a defined answer (%s)"
                        % (case.note or case.expect))
            return "failed to build: %s" % stdout.decode("utf-8", "replace")[:120]
        got = stdout.decode("utf-8", "replace").strip()
        if got == case.expect:
            return None
        if case.kind == "either":
            return ("answered %r where the only correct answers are %r or a "
                    "refusal: %s" % (got, case.expect, case.note))
        return "wrong value: got %r, want %r" % (got, case.expect)

    for start in range(0, len(value_cases), batch):
        chunk = value_cases[start:start + batch]
        index += 1
        lines, status, note = runner.run_batch(chunk, index)
        if lines is not None:
            for case, line in zip(chunk, lines):
                stats = tally(case)
                problem = judge_one(case, "ok", line.encode("utf-8", "replace"))
                if record(case, problem, "ok", line.encode("utf-8", "replace")):
                    stats[1] += 1
                    agree += 1
            continue
        if verbose:
            out.say("  batch of %d did not line up (%s: %s); attributing it"
                    % (len(chunk), status, note))
        # A batch that was REFUSED has at least one unparseable case in it and
        # the rest are innocent, so halve it rather than running 40 programs.
        # A batch that crashed or misaligned has to be split all the way down,
        # because then any case in it could be the culprit.
        if status == "rejected" and len(chunk) > 1:
            mid = len(chunk) // 2
            halves = [chunk[:mid], chunk[mid:]]
        else:
            halves = [[c] for c in chunk]
        for half in halves:
            index += 1
            sub_lines, sub_status, sub_note = runner.run_batch(half, index)
            if sub_lines is not None:
                for case, line in zip(half, sub_lines):
                    stats = tally(case)
                    problem = judge_one(case, "ok", line.encode("utf-8", "replace"))
                    if record(case, problem, "ok", line.encode("utf-8", "replace")):
                        stats[1] += 1
                        agree += 1
                continue
            for case in half:
                index += 1
                st, stdout, nt = runner.run_source(case.program(), index)
                stats = tally(case)
                if record(case, judge_one(case, st, stdout), st, stdout):
                    stats[1] += 1
                    agree += 1

    for start in range(0, len(bytes_cases), batch):
        chunk = bytes_cases[start:start + batch]
        index += 1
        bodies, status, note = runner.run_bytes_batch(chunk, index)
        if bodies is not None:
            for case, body in zip(chunk, bodies):
                stats = tally(case)
                if record(case, check_bytes(case, body), "ok", body):
                    stats[1] += 1
                    agree += 1
            continue
        if verbose:
            out.say("  byte batch of %d did not frame (%s); one at a time"
                    % (len(chunk), note))
        for case in chunk:
            index += 1
            st, stdout, nt = runner.run_source(case.program(), index)
            stats = tally(case)
            if st == "ok":
                problem = check_bytes(case, _one_nl_off(stdout))
            elif st == "rejected":
                problem = "rejected a well-formed string literal"
            elif st == "crashed":
                problem = "crashed on a string literal: %s" % nt
            else:
                problem = "failed to build: %s" % nt
            if record(case, problem, st, stdout):
                stats[1] += 1
                agree += 1

    # reject / diagnose are one program each: a program that must be refused
    # takes the whole program down, so there is nothing to batch it with.
    for case in single_cases:
        index += 1
        st, stdout, nt = runner.run_source(case.program(), index)
        stats = tally(case)
        if case.kind == "reject":
            problem = check_reject(case, st, nt)
        elif case.kind == "diagnose":
            problem = check_diagnose(case, st, nt, stdout)
        else:
            problem = judge_one(case, st, stdout)
        if record(case, problem, st, stdout):
            stats[1] += 1
            agree += 1
    return findings, agree, by_category


# --------------------------------------------------------------------------
def build_corpus(seed, iterations, categories):
    """The corpus, in a fixed order, from a fixed seed. Same every run."""
    rng = random.Random(seed)
    n = max(0, iterations)
    quarter = max(40, n // 4)
    corpus = []
    if "int-literal" in categories:
        corpus += literal_cases(rng, quarter)
    if "int-literal-bind" in categories:
        corpus += bind_cases()
    if "int-arith" in categories:
        corpus += arith_cases(rng, n)
    if "div-zero" in categories:
        corpus += divzero_cases()
    if "string-escape" in categories:
        corpus += escape_cases(rng, quarter // 2)
    if "float" in categories:
        corpus += float_cases(rng, min(quarter, 40))
    return corpus


def corpus_digest(corpus):
    h = hashlib.sha256()
    for case in corpus:
        h.update(("%s\x00%s\x00%s\x00%s\n" % (case.category, case.source,
                                               case.kind, case.expect)).encode())
    return h.hexdigest()[:16]


def class_of(case, problem):
    """Group disagreements by mechanism, so 400 cases are 8 findings, not 400.

    The class name is the finding. Everything in a class has one cause, so
    whoever fixes it fixes all of them, and the count says how wide it is.
    """
    if case.category == "string-escape":
        body = case.source[len('print("'):-len('")')]
        if body == "\\":
            return "string-escape/unterminated-literal-is-accepted"
        if "\\x00" in body or "\\x0" in body and case.expect == b"\x00":
            return "string-escape/hex-zero-is-never-decoded"
        if case.kind == "reject":
            return "string-escape/unterminated-literal-is-accepted"
        if any(e in body for e in C_ESCAPES_NOT_HERE):
            return "string-escape/c-escape-is-kept-as-two-characters"
        return "string-escape/wrong-bytes"
    if case.category == "int-literal-bind":
        if "out of range" in case.note:
            return "int-literal/out-of-range-literal-is-accepted"
        return "int-literal/unsupported-form-is-silently-wrong-in-a-binding"
    if case.category == "int-literal":
        if "out of range" in case.note:
            return "int-literal/out-of-range-literal-is-accepted"
        if "form does not exist yet" in case.note:
            return "int-literal/unsupported-literal-form-answers-wrongly"
        if "separates digits in decimal" in case.note:
            return "int-literal/underscore-works-in-decimal-but-not-in-hex"
        return "int-literal/wrong-value"
    if case.category == "int-arith":
        if " / " in case.source:
            return "int-arith/wrong-division"
        if " % " in case.source:
            return "int-arith/wrong-modulo"
        return "int-arith/wrong-value"
    if case.category == "div-zero":
        if case.kind == "diagnose":
            return "div-zero/signal-instead-of-a-diagnostic"
        return "div-zero/wrong-sign"
    if case.category == "float":
        if case.kind == "either":
            return "float/exponent-form-is-not-a-float"
        return "float/truncated-to-an-integer"
    return "%s/other" % case.category


def cmd_diff_fuzz(args) -> int:
    out.set_quiet(args.quiet)

    categories = tuple(args.only) if args.only else CATEGORIES
    for c in categories:
        if c not in CATEGORIES:
            out.fail("Failed diff-fuzz: unknown category %r; known: %s"
                     % (c, ", ".join(CATEGORIES)))
            return 1

    corpus = build_corpus(args.seed, args.iterations, categories)
    digest = corpus_digest(corpus)
    if not corpus:
        out.fail("Failed diff-fuzz: the corpus is empty")
        return 1

    if args.list:
        for case in corpus:
            print("%-14s %-9s %-46s %s" % (case.category, case.kind, case.label(),
                                            case.expect))
        print("Finished diff-fuzz corpus: %d cases, sha %s" % (len(corpus), digest))
        return 0

    out.say("Differential fuzz: %d cases, seed %d, corpus sha %s, reference is "
            "Python 3 with 32-bit ints and truncating / and %%"
            % (len(corpus), args.seed, digest))
    work = os.path.join(os.environ.get("TMPDIR", "/tmp"), "orbit_difffuzz")
    os.makedirs(work, exist_ok=True)
    runner = Runner(args.compiler, args.cc, work)

    findings, agree, by_category = sweep(runner, corpus, max(1, args.batch),
                                         verbose=not out.is_quiet())
    out.say("Ran %d program(s) for %d cases" % (runner.programs, len(corpus)))

    # ---- report ---------------------------------------------------------
    groups = {}
    for f in findings:
        groups.setdefault(f["class"], []).append(f)

    for name in sorted(groups):
        items = groups[name]
        worst = items[0]
        out.fail("Disagreement %s (%d case%s)" % (name, len(items),
                                                   "" if len(items) == 1 else "s"))
        out.fail("  %s" % worst["problem"])
        for f in items[:args.top]:
            out.fail("  minimal program: %s" % f["source"])
            out.fail("    orbit: %s" % f["observed"])
            if isinstance(f["expect"], bytes):
                out.fail("    ref:   %s" % repr(f["expect"]))
            elif f["expect"] is not None:
                out.fail("    ref:   %s" % f["expect"])
            if f["note"]:
                out.fail("    case:  %s" % f["note"])
        if len(items) > args.top:
            out.fail("  ... and %d more of this class" % (len(items) - args.top))

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            # `iterations` and `batch` are recorded because the ratchet writes
            # them into its baseline: a count with no corpus parameters behind
            # it is a number nobody can reproduce. Neither is part of the corpus
            # identity -- the sha is over the case list -- so adding them does
            # not move it.
            json.dump({"seed": args.seed, "iterations": args.iterations,
                       "batch": args.batch, "corpus_sha": digest,
                       "cases": len(corpus), "agree": agree,
                       "findings": findings}, fh, indent=2)
            fh.write("\n")
        out.say("Wrote every finding to %s" % args.json)

    for name in CATEGORIES:
        if name in by_category:
            total, ok = by_category[name]
            out.say("  %-14s %4d cases, %4d agree, %4d disagree"
                    % (name, total, ok, total - ok))

    print("Finished diff-fuzz: %d/%d agree with the reference across %d cases "
          "(seed %d, sha %s)" % (agree, len(corpus), len(corpus), args.seed, digest))
    if findings:
        print("  %d disagreement(s) in %d class(es). REPORT ONLY unless --strict."
              % (len(findings), len(groups)))
        out.tip("each one is a program that compiles clean, runs, and gives the "
                "wrong answer. --json keeps the full list.")
    return 1 if (findings and args.strict) else 0


# ---- from scripts/routes_probe.py ----
# Route-argument normalization probe (STAB: Windows shell translation).
#
# Under Git Bash on a Windows runner, MSYS2 rewrites any argument that looks
# like an absolute POSIX path into a Windows path before a native program sees
# it. That broke the admission live gate with
#
#     Phase B failed: unexpected status "err:URL can't contain control
#     characters. '/Program Files/Git/gate-burst' (found at least ' ')"
#
# This probe pins the contract of scripts/orbit_routes.py so the repair cannot
# regress: every tool that takes a route from the command line normalizes it
# the same way, on every platform.
#
# Usage:
#     python scripts/measure.py routes
#
# Exits 0 iff every case matches.
#!/usr/bin/env python3



# (name, raw, expected, must_raise)
CASES = [
    # Already-correct absolute routes pass through untouched.
    ("plain", "/health", "/health", False),
    ("burst", "/gate-burst", "/gate-burst", False),
    ("root", "/", "/", False),
    ("nested", "/v1/catalog/items", "/v1/catalog/items", False),
    # ':' param segments and escaped backslashes are legal route content.
    ("colon-param", "/notes/:id", "/notes/:id", False),
    ("brace-param", "/notes/{id}", "/notes/{id}", False),
    ("escaped-backslash", "/we\\ird\\path", "/we\\ird\\path", False),
    # A missing leading slash is added so both spellings are one route.
    ("no-leading-slash", "gate-burst", "/gate-burst", False),
    ("no-leading-slash-nested", "v1/notes", "/v1/notes", False),
    ("empty-uses-default", "", "/", False),
    ("none-uses-default", None, "/", False),
    # Duplicate separators collapse.
    ("double-slash", "//posts//1", "/posts/1", False),
    # The Git Bash / MSYS2 rewrite, in every shape it is observed. These are
    # the exact strings that reached the gate as 'C:/Program Files/Git/...'.
    ("msys-drive-forward", "C:/Program Files/Git/gate-burst", "/gate-burst", False),
    ("msys-drive-backslash", "C:\\Program Files\\Git\\gate-burst", "/gate-burst", False),
    ("msys-no-drive", "/Program Files/Git/gate-burst", "/gate-burst", False),
    ("msys-dos-drive", "/c/Program Files/Git/gate-burst", "/gate-burst", False),
    ("msys-x86", "/Program Files (x86)/Git/gate-burst", "/gate-burst", False),
    ("msys-lowercase-drive", "c:/program files/git/gate-burst", "/gate-burst", False),
    ("drive-only", "C:/health", "/health", False),
    ("msys-root-only", "/Program Files/Git/", "/", False),
    # Quoting a route must not change it.
    ("quoted", '"/gate-burst"', "/gate-burst", False),
    ("single-quoted", "'/gate-burst'", "/gate-burst", False),
    # Unrepairable input is rejected, never silently turned into a bad URL.
    ("spaces-unrepairable", "C:/some other place/x", None, True),
    ("bare-spaces", "gate burst", None, True),
    ("tab", "/gate\tburst", None, True),
    ("newline", "/gate\nburst", None, True),
    ("nul", "/gate\x00burst", None, True),
]


def roundtrip_cases():
    """The invariant that matters: translating a route and repairing it is a
    no-op. MSYS2 rewrites `/R` to `<Git install>/R`; normalize_route_path must
    map that back to `/R` for every route the tools accept, so no route is ever
    silently changed by the repair."""
    roots = ("C:/Program Files/Git", "C:/Program Files (x86)/Git",
             "/c/Program Files/Git", "/Program Files/Git",
             "C:\\Program Files\\Git")
    routes = ["/", "/health", "/gate-burst", "/v1/catalog/items", "/notes/:id",
              "/notes/{id}", "/we\\ird\\path", "/upload", "/loop"]
    return [(("roundtrip %s @ %s" % (r, root)), root + r, r, False)
            for root in roots for r in routes]


def cmd_routes(args) -> int:
    cases = CASES + roundtrip_cases()
    ok = 0
    for name, raw, want, must_raise in cases:
        try:
            got = normalize_route_path(raw)
        except RoutePathError as e:
            if must_raise:
                out.say("Normalizing %s ... rejected as expected" % name)
                ok += 1
            else:
                out.fail("Failed %s: %r was rejected (%s)" % (name, raw, e))
            continue
        if must_raise:
            out.fail("Failed %s: %r accepted as %r but must be rejected" % (name, raw, got))
        elif got == want:
            out.say("Normalizing %s -> %s ... ok" % (name, got))
            ok += 1
        else:
            out.fail("Failed %s: %r normalized to %r, want %r" % (name, raw, got, want))
    out.finish("routes-probe", ok, len(cases))
    return 0 if ok == len(cases) else 1


# ---- from scripts/phase_times.py ----
# Wall and CPU time per compiler phase, for a program you name.
#
# The compiler already reports where its stages end when ORBIT_MEM_REPORT is set:
# pipeline.orb calls reportMemStage after parse, resolve, sema, buildAST and
# generateC+generateCHeader, and each call writes one `[mem] <stage> ...` line to
# stderr. This script stamps the arrival of those lines, so a phase boundary that
# exists in the binary can be measured without touching compiler sources.
#
# The boundaries, in the order pipeline.orb writes them:
#
#   parse      start -> `[mem] parse`      parseProgram
#   resolve    -> `[mem] resolve`          resolveModuleAST
#   sema       -> `[mem] sema`             analyze + reportResolutionGaps
#   builder    -> `[mem] build`            buildAST
#   c-emit     -> `[mem] codegen`          optimizeIRModule + cteOptimize
#                                          + generateC + generateCHeader
#   emit-write -> the `cc ` line           verifyModuleTypes + write the C and
#                                          the shard header + app resource
#   cc         -> process exit             the C compiler and the linker
#
# Two phases are bundled and are named that way in the output. `c-emit` bundles
# the two optimizer passes with C emission: there is no reportMemStage call
# between them, and adding one would change compiler sources. `emit-write`
# bundles the IR type verification with writing the intermediate C.
#
# `check` is measured as its own process. The check path calls neither
# reportMemStage nor the builder, so it has no internal split; the split above is
# the same front end running inside `build`, which is why `check` and
# parse+resolve+sema are both reported and should be close.
#
# The `cc` boundary is the `cc <command>` line that `--verbose` prints on stdout
# immediately before the compiler runs. It is the only observable edge between
# Orbit's work and the C toolchain's, and it is what makes a full build splittable
# into one process instead of two.
#
# CPU time is per process, not per phase. A job object totals the process and its
# children (the C compiler is a child), and the stage stamps are wall edges only,
# so `check` and `total` carry CPU and the phases between them do not. On Windows
# the accounting advances with the scheduler quantum, so a process shorter than
# about 15 ms can read 0.0 s; `hello`'s check is one.
#
# Usage:
#     python scripts/measure.py phase-times --compiler PATH
#     python scripts/measure.py phase-times --compiler PATH --runs 20 --only main
#     python scripts/measure.py phase-times --compiler PATH --self-test
#     python scripts/measure.py phase-times --compiler PATH --json out.json
#
# A run that cannot produce a stage is a failure, not a blank cell: a missing
# `[mem]` line, a missing `cc` line, or a non-zero exit is counted and the
# closing line is red.
#!/usr/bin/env python3



DEFAULT_WORK = os.path.join(ROOT, "scratch", "phase")

STAGE_RE = re.compile(r"^\[mem\] (parse|resolve|sema|build|codegen)(?: |$)")
# The stage order pipeline.orb writes. A phase is scored only when every earlier
# boundary arrived, so a truncated build cannot be read as a fast one.
STAGE_ORDER = ["parse", "resolve", "sema", "build", "codegen"]
PHASE_ORDER = ["check", "parse", "resolve", "sema", "builder", "c-emit",
               "emit-write", "cc", "total"]
PROGRAM_ORDER = ["hello", "gen10k", "main"]

# The 10k-function program. Deliberately flat and bodyless: it exists to put
# 10,000 function bodies through the front end, the builder and the emitter, and
# nothing else. Chaining or recursion would measure the call graph instead.
GEN10K_TEMPLATE = (
    "fn gen_{i}() -> int {{\n"
    "    return {i}\n"
    "}}\n\n"
)
GEN10K_MAIN = (
    "fn main() -> int {\n"
    "    print(gen_1() + gen_5000() + gen_10000())\n"
    "    return 0\n"
    "}\n"
)


# ---------------------------------------------------------------------------
# CPU accounting for a process and its children
# ---------------------------------------------------------------------------

class _JobAccounting:
    """Windows: a job object totals the CPU of every process in it.

    `subprocess` can report one process's times after it exits, not its
    children's, and the phase that matters most (`cc`) is a child. Counting
    GetProcessTimes on the tree while it runs misses work; a job object keeps
    the total for exited members too. The process is assigned a few
    milliseconds after spawn, so any grandchild started in that window escapes
    the total -- the compiler spends seconds before it starts the C compiler,
    so in practice the whole `cc` subtree is counted, and a run whose
    assignment failed reports cpu as unavailable instead of guessing.
    """

    JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION = 1
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9

    class _Basic(ctypes.Structure):
        _fields_ = [
            ("TotalUserTime", ctypes.c_int64),
            ("TotalKernelTime", ctypes.c_int64),
            ("ThisPeriodTotalUserTime", ctypes.c_int64),
            ("ThisPeriodTotalKernelTime", ctypes.c_int64),
            ("TotalPageFaultCount", ctypes.c_uint32),
            ("TotalProcesses", ctypes.c_uint32),
            ("ActiveProcesses", ctypes.c_uint32),
            ("TotalTerminatedProcesses", ctypes.c_uint32),
        ]

    class _IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in (
            "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
            "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

    class _Extended(ctypes.Structure):
        _fields_ = [
            ("PerProcessUserTimeLimit", ctypes.c_int64),
            ("PerJobUserTimeLimit", ctypes.c_int64),
            ("LimitFlags", ctypes.c_uint32),
            ("MinimumWorkingSetSize", ctypes.c_size_t),
            ("MaximumWorkingSetSize", ctypes.c_size_t),
            ("ActiveProcessLimit", ctypes.c_uint32),
            ("Affinity", ctypes.c_size_t),
            ("PriorityClass", ctypes.c_uint32),
            ("SchedulingClass", ctypes.c_uint32),
        ]

    def __init__(self):
        self.handle = None
        self.error = ""
        self.kernel32 = None

    def attach(self, proc):
        try:
            self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            k32 = self.kernel32
            k32.CreateJobObjectW.restype = ctypes.c_void_p
            self.handle = k32.CreateJobObjectW(None, None)
            if not self.handle:
                self.error = "CreateJobObject failed"
                return
            ext = self._Extended()
            ext.LimitFlags = 0  # accounting only, no limits imposed
            k32.SetInformationJobObject(ctypes.c_void_p(self.handle),
                                        self.JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
                                        ctypes.byref(ext), ctypes.sizeof(ext))
            ok = k32.AssignProcessToJobObject(ctypes.c_void_p(self.handle),
                                              ctypes.c_void_p(int(proc._handle)))
            if not ok:
                self.error = ("AssignProcessToJobObject failed (%d)"
                              % ctypes.get_last_error())
        except Exception as exc:  # pragma: no cover - defensive on odd hosts
            self.error = str(exc)

    def cpu_seconds(self):
        if not self.handle:
            return None
        try:
            info = self._Basic()
            ok = self.kernel32.QueryInformationJobObject(
                ctypes.c_void_p(self.handle),
                self.JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION,
                ctypes.byref(info), ctypes.sizeof(info), None)
            if not ok:
                return None
            # FILETIME ticks: 100 ns each.
            return (info.TotalUserTime + info.TotalKernelTime) / 1e7
        except Exception:
            return None

    def close(self):
        if self.handle:
            try:
                self.kernel32.CloseHandle(ctypes.c_void_p(self.handle))
            except Exception:
                pass
            self.handle = None


def _child_cpu_delta():
    """POSIX: RUSAGE_CHILDREN totals every reaped child, so sequential runs
    give a clean delta. Not used on Windows, where it is a no-op."""
    try:
        import resource
        r = resource.getrusage(resource.RUSAGE_CHILDREN)
        return r.ru_utime + r.ru_stime
    except Exception:
        return None


# ---------------------------------------------------------------------------
# One measured process
# ---------------------------------------------------------------------------

class Run:
    """One child process: exit code, wall, CPU, and timestamped output lines."""

    def __init__(self, argv, cwd, env, timeout):
        self.argv = argv
        self.rc = None
        self.wall = None
        self.cpu = None
        self.cpu_note = ""
        self.lines = []          # (seconds since start, "out"|"err", text)
        self.output = ""
        self.timed_out = False
        self._timeout = timeout
        self._cwd = cwd
        self._env = env
        self._run()

    def _run(self):
        started = time.perf_counter()
        proc = subprocess.Popen(
            self.argv, cwd=self._cwd, env=self._env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, errors="replace", bufsize=1,
        )
        job = None
        posix_before = None
        if os.name == "nt":
            job = _JobAccounting()
            job.attach(proc)
        else:
            posix_before = _child_cpu_delta()

        lock = threading.Lock()
        collected = []

        def pump(stream, name):
            for line in stream:
                stamp = time.perf_counter() - started
                with lock:
                    collected.append((stamp, name, line.rstrip("\r\n")))

        threads = [
            threading.Thread(target=pump, args=(proc.stdout, "out"), daemon=True),
            threading.Thread(target=pump, args=(proc.stderr, "err"), daemon=True),
        ]
        for t in threads:
            t.start()
        try:
            proc.wait(timeout=self._timeout)
        except subprocess.TimeoutExpired:
            self.timed_out = True
            proc.kill()
            proc.wait()
        for t in threads:
            t.join(timeout=5)
        self.wall = time.perf_counter() - started
        self.rc = proc.returncode
        if job is not None:
            self.cpu = job.cpu_seconds()
            self.cpu_note = job.error
            job.close()
        else:
            after = _child_cpu_delta()
            if posix_before is not None and after is not None:
                self.cpu = after - posix_before
        with lock:
            self.lines = sorted(collected, key=lambda item: item[0])
        self.output = "\n".join(text for _t, _n, text in self.lines)

    def find(self, predicate):
        for stamp, _name, text in self.lines:
            if predicate(text):
                return stamp, text
        return None

    def exit_seconds(self):
        """When the process stopped doing work. The last line is the last
        evidence of life; the gap between it and wait() is not the program's."""
        return self.lines[-1][0] if self.lines else self.wall


def stage_stamps(run):
    """stage -> arrival seconds, only for stages that arrived in order."""
    found = {}
    for stamp, _name, text in run.lines:
        m = STAGE_RE.match(text)
        if m:
            found.setdefault(m.group(1), stamp)
    ordered = {}
    previous = 0.0
    for stage in STAGE_ORDER:
        if stage not in found or found[stage] < previous:
            break
        ordered[stage] = found[stage]
        previous = found[stage]
    return ordered


def cc_stamp(run):
    """Arrival of `cc <command>`, printed by --verbose just before the toolchain
    runs. `rc <path>` (the app resource) can precede it on Windows."""
    hit = run.find(lambda text: text.startswith("cc ") and " -o " in text)
    return hit


def phases_of_check(run):
    return {"check": (run.wall, run.cpu)}


def phases_of_build(run):
    """Every phase that can be isolated from one build process."""
    stamps = stage_stamps(run)
    cc_hit = cc_stamp(run)
    end = run.exit_seconds()
    vals = {}
    if "parse" in stamps:
        vals["parse"] = stamps["parse"]
    if "resolve" in stamps:
        vals["resolve"] = stamps["resolve"] - stamps["parse"]
    if "sema" in stamps:
        vals["sema"] = stamps["sema"] - stamps["resolve"]
    if "build" in stamps:
        vals["builder"] = stamps["build"] - stamps["sema"]
    if "codegen" in stamps:
        vals["c-emit"] = stamps["codegen"] - stamps["build"]
    if cc_hit is not None and "codegen" in stamps:
        vals["emit-write"] = cc_hit[0] - stamps["codegen"]
    if cc_hit is not None:
        vals["cc"] = end - cc_hit[0]
    vals["total"] = run.wall
    phases = {}
    for name in PHASE_ORDER:
        if name in vals:
            cpu = run.cpu if name == "total" else None
            phases[name] = (max(0.0, vals[name]), cpu)
    return phases


# ---------------------------------------------------------------------------
# Programs
# ---------------------------------------------------------------------------

def write_gen10k(path, count=10000):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for i in range(1, count + 1):
            f.write(GEN10K_TEMPLATE.format(i=i))
        f.write(GEN10K_MAIN)


def programs(work, cc):
    """name -> source path, after materialising the two generated programs."""
    os.makedirs(work, exist_ok=True)
    hello = os.path.join(work, "hello.orb")
    with open(hello, "w", encoding="utf-8", newline="\n") as f:
        f.write("fn main() -> int {\n"
                "    print(\"hello, orbit\")\n"
                "    return 0\n"
                "}\n")
    gen10k = os.path.join(work, "gen_10k.orb")
    if not os.path.isfile(gen10k):
        write_gen10k(gen10k)
    return {
        "hello": hello,
        "gen10k": gen10k,
        "main": os.path.join(ROOT, MAIN_ORB),
    }


def build_argv(compiler, source, binary):
    return [compiler, "build", source, "-o", binary, "--verbose"]


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

def percentile(values, p):
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    k = max(0, min(len(vals) - 1, math.ceil(p / 100.0 * len(vals)) - 1))
    return vals[k]


def ms(seconds):
    return "-" if seconds is None else "%.1f" % (seconds * 1000.0)


def rc_label(rcs):
    """Distinct exit codes, with the count when one of them is not zero."""
    if not rcs:
        return "-"
    bad = [rc for rc in rcs if rc != 0]
    if not bad:
        return "0"
    return "%s x%d" % (bad[0], len(bad))


# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------

def measure_program(name, source, compiler, cc, work, runs, timeout, say):
    binary = os.path.join(work, name + ".exe" if os.name == "nt" else name)
    env = build_env(work, cc=cc)
    env["ORBIT_MEM_REPORT"] = "1"
    # -Wall stays on: it is what a user build gets. The bootstrap turns it off
    # for its own 5 MB unit, which is a different question from this one.
    env.pop("ORBIT_WARNINGS", None)
    env.pop("ORBIT_SKIP_CC", None)

    check_argv = [compiler, "check", source]
    check_env = dict(env)
    check_env.pop("ORBIT_MEM_REPORT", None)

    # The first build is the cold sample and the warm-up in one: file cache is
    # cold for this program, and its result is reported separately, not pooled.
    say("  %s: cold build + check ..." % name)
    cold_build = Run(build_argv(compiler, source, binary), ROOT, env, timeout)
    cold_check = Run(check_argv, ROOT, check_env, timeout)
    cold = {
        "build": cold_build,
        "check": cold_check,
        "phases": phases_of_build(cold_build),
    }
    failures = []
    if cold_build.rc != 0:
        failures.append("%s: cold build exit %s" % (name, cold_build.rc))
    if cold_check.rc != 0:
        failures.append("%s: cold check exit %s" % (name, cold_check.rc))

    say("  %s: %d measured run(s) ..." % (name, runs))
    samples = {phase: [] for phase in PHASE_ORDER}
    rcs = []
    check_rcs = []
    build_rcs = []
    for index in range(1, runs + 1):
        build = Run(build_argv(compiler, source, binary), ROOT, env, timeout)
        check = Run(check_argv, ROOT, check_env, timeout)
        rcs.append(("check", check.rc, index))
        rcs.append(("build", build.rc, index))
        check_rcs.append(check.rc)
        build_rcs.append(build.rc)
        if check.rc != 0:
            failures.append("%s: run %d check exit %s" % (name, index, check.rc))
        if build.rc != 0:
            failures.append("%s: run %d build exit %s, %d output line(s)"
                            % (name, index, build.rc, len(build.lines)))
        for phase, (wall, cpu) in phases_of_check(check).items():
            samples[phase].append((wall, cpu))
        for phase, (wall, cpu) in phases_of_build(build).items():
            samples[phase].append((wall, cpu))
        say("    run %d: build %s ms, check %s ms, rc %s/%s"
            % (index, ms(build.wall), ms(check.wall), check.rc, build.rc))
        if index == runs:
            last = {"build": build, "check": check}

    return {
        "name": name,
        "source": os.path.relpath(source, ROOT),
        "samples": samples,
        "cold": cold,
        "rcs": rcs,
        "check_rcs": check_rcs,
        "build_rcs": build_rcs,
        "failures": failures,
        "cpu_note": last["build"].cpu_note if runs else "",
        "cc_command": (cc_stamp(last["build"])[1] if runs and
                       cc_stamp(last["build"]) else ""),
    }


def print_program(result, say):
    samples = result["samples"]
    totals = [wall for wall, _cpu in samples.get("total", [])]
    total_p50 = percentile(totals, 50)
    cold_phases = result["cold"]["phases"]
    cold_total = result["cold"]["build"].wall

    say("")
    say("%s  (%s)" % (result["name"], result["source"]))
    say("  %-12s %3s %11s %11s %10s %10s %8s %7s"
        % ("phase", "n", "wall p50", "wall p99", "cpu p50", "cpu p99",
           "rc", "% tot"))
    for phase in PHASE_ORDER:
        rows = samples.get(phase, [])
        if not rows:
            continue
        walls = [w for w, _c in rows]
        cpus = [c for _w, c in rows]
        share = "-"
        if phase != "check" and phase != "total" and total_p50:
            p50 = percentile(walls, 50)
            if p50 is not None:
                share = "%.0f%%" % (100.0 * p50 / total_p50)
        rc = rc_label(result["check_rcs"] if phase == "check"
                      else result["build_rcs"])
        say("  %-12s %3d %11s %11s %10s %10s %8s %7s"
            % (phase, len(rows), ms(percentile(walls, 50)),
               ms(percentile(walls, 99)), ms(percentile(cpus, 50)),
               ms(percentile(cpus, 99)), rc, share))
    say("  cold (first invocation, not pooled): build %s ms, check %s ms"
        % (ms(cold_total), ms(result["cold"]["check"].wall)))
    cold_cells = " ".join("%s=%s" % (p, ms(cold_phases[p][0]))
                          for p in PHASE_ORDER if p in cold_phases)
    say("  cold phases: %s" % cold_cells)
    if result["cpu_note"]:
        say("  cpu unavailable: %s" % result["cpu_note"])
    if result["cc_command"]:
        say("  cc: %s" % result["cc_command"])


def write_json(path, results, meta):
    doc = {"meta": meta, "programs": []}
    for result in results:
        entry = {"name": result["name"], "source": result["source"],
                 "rcs": result["rcs"], "failures": result["failures"],
                 "cold": {"build_wall": result["cold"]["build"].wall,
                          "check_wall": result["cold"]["check"].wall,
                          "phases": {k: v[0] for k, v in
                                     result["cold"]["phases"].items()}},
                 "phases": {}}
        for phase, rows in result["samples"].items():
            entry["phases"][phase] = {
                "n": len(rows),
                "wall": [w for w, _c in rows],
                "cpu": [c for _w, c in rows],
                "wall_p50": percentile([w for w, _c in rows], 50),
                "wall_p99": percentile([w for w, _c in rows], 99),
                "cpu_p50": percentile([c for _w, c in rows if c is not None], 50),
                "cpu_p99": percentile([c for _w, c in rows if c is not None], 99),
            }
        doc["programs"].append(entry)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")


# ---------------------------------------------------------------------------
# Self-test: the harness must be able to fail
# ---------------------------------------------------------------------------

def self_test_phase_times(compiler, cc, work, timeout, say):
    """Two ways this tool must say no. Both run; both must behave.

    1. A compiler path that is not a file is refused before any measurement,
       with exit 2 and a message, not an empty table.
    2. A program that cannot build produces a non-zero rc, is recorded as a
       failure, and stops the run from closing green.
    """
    passed = 0
    total = 0

    total += 1
    bogus = os.path.join(work, "no-such-compiler.exe")
    rc, message = validate_compiler(bogus)
    if rc == 2 and "not a file" in message:
        say("  ok    invalid compiler path refused: %s" % message)
        passed += 1
    else:
        out.fail("Failed phase-times: invalid compiler path returned %d (%s)"
                 % (rc, message))
        say("  FAIL  invalid compiler path: rc %d, %r" % (rc, message))

    total += 1
    bad = os.path.join(work, "cannot_build.orb")
    with open(bad, "w", encoding="utf-8", newline="\n") as f:
        f.write("fn main() -> int {\n    print(\"unterminated\n}\n")
    say("  building a program with a syntax error ...")
    run = Run([compiler, "build", bad, "-o",
               os.path.join(work, "cannot_build.exe")],
              ROOT, build_env(work, cc=cc), timeout)
    if run.rc != 0:
        say("  ok    non-zero build recorded: exit %d, %d line(s) of output"
            % (run.rc, len(run.lines)))
        passed += 1
    else:
        out.fail("Failed phase-times: a program with a syntax error exited 0")
        say("  FAIL  non-zero build: exit 0")

    out.finish("phase-times", passed, total, "(self-test)")
    return 0 if passed == total else 1


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def validate_compiler(path):
    """Return (rc, message). rc 0 means the path exists and speaks `orbit`."""
    if not path:
        return 2, "no --compiler given"
    full = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
    if not os.path.exists(full):
        return 2, "not a file: %s" % path
    if os.path.isdir(full):
        return 2, "not a file: %s is a directory" % path
    try:
        proc = subprocess.run([full, "--version"], capture_output=True,
                              text=True, timeout=60)
    except Exception as exc:
        return 2, "could not run %s (%s)" % (path, exc)
    first = (proc.stdout or proc.stderr or "").strip().splitlines()
    line = first[0] if first else ""
    if proc.returncode != 0 or not line.startswith("orbit"):
        return 2, "%s did not answer `--version` with an orbit banner (%r)" % (
            path, line)
    return 0, line


def cmd_phase_times(args) -> int:
    out.set_quiet(args.quiet)

    work = os.path.abspath(args.work)
    os.makedirs(work, exist_ok=True)

    rc, message = validate_compiler(args.compiler)
    if rc != 0:
        out.fail("Failed phase-times: %s" % message)
        out.tip("pass --compiler PATH to an existing orbit binary, for example "
                ".orbit/shared/chain3.exe on Windows")
        return 2
    compiler = os.path.abspath(args.compiler)
    say = out.say
    say("Measuring with %s (%s)" % (compiler, message))
    say("Work dir: %s" % work)

    cc = resolve_cc(args.cc)

    if args.self_test:
        return self_test_phase_times(compiler, cc, work, args.timeout, say)

    say("C compiler for the inner build: %s" % cc)

    wanted = args.only or PROGRAM_ORDER
    sources = programs(work, cc)
    results = []
    failures = []
    for name in PROGRAM_ORDER:
        if name not in wanted:
            continue
        result = measure_program(name, sources[name], compiler, cc, work,
                                 max(1, args.runs), args.timeout, say)
        results.append(result)
        failures.extend(result["failures"])

    for result in results:
        print_program(result, say)

    if args.json:
        write_json(os.path.abspath(args.json), results, {
            "compiler": compiler,
            "compiler_version": message,
            "cc": cc,
            "platform": sys.platform,
            "runs": args.runs,
            "note": "p99 over n=5 is the largest sample; raise --runs for a "
                    "percentile that is not the maximum.",
        })
        say("")
        say("Wrote %s" % args.json)

    say("")
    total = len(results)
    ok = sum(1 for r in results if not r["failures"])
    if failures:
        for line in failures:
            out.fail("Failed %s" % line)
    out.finish("phase-times", ok, total,
               "(%d program(s), %d run(s), %s)"
               % (total, max(1, args.runs), sys.platform))
    return 0 if ok == total else 1


# ---- from scripts/measure_selfhost.py ----
# Measure self-host bootstrap resource usage without changing the compiler.
#
# Phase 0 instrument: external RSS/time/size sampler per build phase so the
# peak on low-RAM machines can be attributed before any optimization lands.
#
# What it does:
#   static      : file sizes, SHA, counts of risky patterns (out+concat,
#                 list grows, arena allocs). No subprocess, safe on any RAM.
#   amalgamate  : runs scripts/trust.py amalgamate on the canonical C, samples RSS.
#   seed-cc     : compiles the amalgamated TU with the C compiler, samples RSS.
#   orbit-build : runs seed.exe build compiler/host/main.orb, samples the orbit
#                 process tree separately from its inner cc child.
#   iter-cc     : recompiles the emitted C with our own cc invocation.
#
# Defaults are deliberately light: only static+amalgamate run unless
# --allow-heavy is passed, so an 8 GB machine never OOMs by accident.
#
# Outputs:
#   --out-jsonl PATH  machine-readable per-phase records (default: work/measure.jsonl)
#   --out-md PATH     markdown summary table (default: work/measure.md)
#
# Usage:
#     python scripts/measure.py measure-selfhost
#     python scripts/measure.py measure-selfhost --allow-heavy --phases static,amalgamate,seed-cc
#     python scripts/measure.py measure-selfhost --allow-heavy --phases all --cc gcc
#!/usr/bin/env python3



RUNTIME_DIR = os.path.join(ROOT, "runtime")
COMPILER_DIR = os.path.join(ROOT, "compiler")

SUPPRESS_FLAGS = ["-O0", "-w", "-Wno-int-conversion",
                  "-Wno-incompatible-pointer-types", "-DORBIT_WITH_EXEC"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def detect_cc():
    env_cc = os.environ.get("ORBIT_CC")
    if env_cc:
        return env_cc
    for cand in ("gcc", "clang", "cc"):
        if shutil.which(cand):
            return cand
    return "gcc"


# ---------------------------------------------------------------------------
# System memory (stdlib only)
# ---------------------------------------------------------------------------

def system_snapshot():
    """Return (total_mb, avail_mb) or (None, None) when unavailable."""
    if sys.platform == "win32":
        try:
            import ctypes

            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]

            stat = MEMORYSTATUSEX()
            stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
                total = int(stat.ullTotalPhys) // (1 << 20)
                avail = int(stat.ullAvailPhys) // (1 << 20)
                return (total, avail)
        except Exception:
            return (None, None)
    else:
        try:
            with open("/proc/meminfo") as f:
                txt = f.read()
            total = avail = None
            for line in txt.splitlines():
                if line.startswith("MemTotal:"):
                    total = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"):
                    avail = int(line.split()[1]) // 1024
            return (total, avail)
        except Exception:
            return (None, None)
    return (None, None)


# ---------------------------------------------------------------------------
# Process tree RSS sampler (stdlib only)
# ---------------------------------------------------------------------------

def _win_child_pids(root_pid):
    """Return set of descendant pids via Toolhelp snapshot. Best effort."""
    try:
        import ctypes
        from ctypes import wintypes
        TH32CS_SNAPPROCESS = 0x00000002
        kernel32 = ctypes.windll.kernel32
        CreateToolhelp32Snapshot = kernel32.CreateToolhelp32Snapshot
        Process32First = kernel32.Process32FirstW
        Process32Next = kernel32.Process32NextW
        CloseHandle = kernel32.CloseHandle

        class PROCESSENTRY32(ctypes.Structure):
            _fields_ = [
                ("dwSize", wintypes.DWORD),
                ("cntUsage", wintypes.DWORD),
                ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_void_p),
                ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", wintypes.LONG),
                ("dwFlags", wintypes.DWORD),
                ("szExeFile", wintypes.WCHAR * 260),
            ]

        snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
        if snap == wintypes.HANDLE(-1).value:
            return set(), {}
        try:
            parent = {}
            names = {}
            entry = PROCESSENTRY32()
            entry.dwSize = ctypes.sizeof(PROCESSENTRY32)
            ok = Process32First(snap, ctypes.byref(entry))
            while ok:
                parent[entry.th32ProcessID] = entry.th32ParentProcessID
                names[entry.th32ProcessID] = entry.szExeFile
                ok = Process32Next(snap, ctypes.byref(entry))
            out = set()
            changed = True
            frontier = {root_pid}
            while changed:
                changed = False
                for pid, ppid in parent.items():
                    if ppid in frontier and pid not in frontier:
                        frontier.add(pid)
                        out.add(pid)
                        changed = True
            return out, names
        finally:
            CloseHandle(snap)
    except Exception:
        return set(), {}


def _win_rss_mb(pid):
    try:
        import ctypes
        from ctypes import wintypes

        class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
            _fields_ = [
                ("cb", wintypes.DWORD),
                ("PageFaultCount", wintypes.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        kernel32 = ctypes.windll.kernel32
        psapi = ctypes.windll.psapi
        h = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return None, ""
        try:
            counters = PROCESS_MEMORY_COUNTERS()
            counters.cb = ctypes.sizeof(counters)
            if psapi.GetProcessMemoryInfo(h, ctypes.byref(counters), counters.cb):
                exe = ""
                try:
                    buf = ctypes.create_unicode_buffer(260)
                    if psapi.GetModuleBaseNameW(h, None, buf, 260):
                        exe = buf.value
                except Exception:
                    exe = ""
                return (counters.WorkingSetSize // (1 << 20), exe.lower())
            return None, ""
        finally:
            kernel32.CloseHandle(h)
    except Exception:
        return None, ""


def _posix_rss_mb(pid):
    try:
        with open("/proc/%d/status" % pid) as f:
            exe = ""
            try:
                exe = os.path.basename(os.readlink("/proc/%d/exe" % pid)).lower()
            except Exception:
                exe = ""
            for line in f:
                if line.startswith("VmRSS:"):
                    kb = int(line.split()[1])
                    return (kb // 1024, exe)
        return None, ""
    except Exception:
        return None, ""


def _posix_child_pids(root_pid):
    out = set()
    try:
        for name in os.listdir("/proc"):
            if not name.isdigit():
                continue
            pid = int(name)
            try:
                with open("/proc/%d/stat" % pid) as f:
                    parts = f.read().rsplit(")", 1)[1].split()
                    ppid = int(parts[1])
                    if ppid == root_pid:
                        out.add(pid)
                        out |= _posix_child_pids(pid)
            except Exception:
                continue
    except Exception:
        pass
    return out


def is_cc_name(exe_lower):
    for token in ("cc1", "cc1plus", "gcc", "clang", "collect2", "ld", "as", "cl", "link"):
        if token in exe_lower:
            return True
    return False


class TreeSampler(threading.Thread):
    """Sample a process tree every interval_ms; track per-class peaks."""

    def __init__(self, root_pid, interval_ms=100):
        super().__init__(daemon=True)
        self.root_pid = root_pid
        self.interval = max(20, interval_ms) / 1000.0
        self.stop_flag = threading.Event()
        self.peak_total_mb = 0
        self.peak_orbit_mb = 0
        self.peak_cc_mb = 0
        self.samples = 0
        self.min_avail_mb = None

    def run(self):
        while not self.stop_flag.is_set():
            try:
                self._sample_once()
            except Exception:
                pass
            time.sleep(self.interval)

    def stop(self):
        self.stop_flag.set()
        self.join(timeout=2.0)

    def _sample_once(self):
        if sys.platform == "win32":
            children, names = _win_child_pids(self.root_pid)
            pids = {self.root_pid} | set(children)
            total = 0
            orbit = 0
            ccm = 0
            for pid in pids:
                rss, exe = _win_rss_mb(pid)
                if rss is None:
                    continue
                if not exe:
                    exe = str(names.get(pid, "")).lower()
                total += rss
                if is_cc_name(exe):
                    ccm += rss
                elif exe == "":
                    # Unnamed helper during cc phases is almost always
                    # cc1/collect2/ld spawned by the driver; attribute to
                    # cc so orbit-vs-cc split stays meaningful.
                    ccm += rss
                else:
                    orbit += rss
        else:
            pids = {self.root_pid} | _posix_child_pids(self.root_pid)
            total = 0
            orbit = 0
            ccm = 0
            for pid in pids:
                rss, exe = _posix_rss_mb(pid)
                if rss is None:
                    continue
                total += rss
                if is_cc_name(exe):
                    ccm += rss
                else:
                    orbit += rss
        _, avail = system_snapshot()
        self.samples += 1
        if total > self.peak_total_mb:
            self.peak_total_mb = total
        if orbit > self.peak_orbit_mb:
            self.peak_orbit_mb = orbit
        if ccm > self.peak_cc_mb:
            self.peak_cc_mb = ccm
        if avail is not None:
            if self.min_avail_mb is None or avail < self.min_avail_mb:
                self.min_avail_mb = avail


def run_sampled(argv, cwd, env_extra=None, interval_ms=100, label=""):
    """Run argv with tree sampling; return dict with peaks and timing."""
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    print("Running %s ..." % (label or " ".join(argv[:4])), flush=True)
    total_mb, avail_before = system_snapshot()
    t0 = time.time()
    proc = subprocess.Popen(argv, cwd=cwd, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace")
    sampler = TreeSampler(proc.pid, interval_ms=interval_ms)
    sampler.start()
    try:
        out, _ = proc.communicate()
    finally:
        sampler.stop()
    wall = time.time() - t0
    _, avail_after = system_snapshot()
    if out and out.strip():
        tail = "\n".join(out.rstrip().splitlines()[-15:])
        print(tail)
    return {
        "rc": proc.returncode,
        "wall_s": round(wall, 2),
        "peak_tree_mb": sampler.peak_total_mb,
        "peak_orbit_mb": sampler.peak_orbit_mb,
        "peak_cc_mb": sampler.peak_cc_mb,
        "sys_total_mb": total_mb,
        "sys_avail_before_mb": avail_before,
        "sys_avail_min_mb": sampler.min_avail_mb,
        "sys_avail_after_mb": avail_after,
        "samples": sampler.samples,
    }


# ---------------------------------------------------------------------------
# Static analysis (no subprocess)
# ---------------------------------------------------------------------------

def count_in_file(path, pattern, flags=0):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            txt = f.read()
        return len(re.findall(pattern, txt, flags))
    except OSError:
        return 0


def static_record():
    rec = {"phase": "static"}
    total_mb, avail_mb = system_snapshot()
    rec["sys_total_mb"] = total_mb
    rec["sys_avail_mb"] = avail_mb
    files = {}
    paths = {}
    total_orb = 0
    for dirpath, _dirnames, filenames in os.walk(COMPILER_DIR):
        for name in sorted(filenames):
            if not name.endswith(".orb"):
                continue
            p = os.path.join(dirpath, name)
            try:
                sz = os.path.getsize(p)
            except OSError:
                sz = 0
            files[name] = sz
            paths[name] = p
            total_orb += sz
    rec["compiler_orb_bytes"] = total_orb
    rec["compiler_orb_files"] = files
    try:
        rec["canonical_c_bytes"] = os.path.getsize(CANONICAL_C)
        rec["canonical_c_sha"] = sha256(CANONICAL_C)
    except OSError:
        rec["canonical_c_bytes"] = 0
        rec["canonical_c_sha"] = ""
    rt_total = 0
    for name in sorted(os.listdir(RUNTIME_DIR)):
        if name.endswith(".c") or name.endswith(".h"):
            try:
                rt_total += os.path.getsize(os.path.join(RUNTIME_DIR, name))
            except OSError:
                pass
    rec["runtime_bytes"] = rt_total
    cb = paths["c_backend.orb"]
    rec["c_backend_out_concat"] = count_in_file(cb, r"out\s*=\s*out\s*\+")
    rec["c_backend_bytes"] = files.get("c_backend.orb", 0)
    builder = paths["builder.orb"]
    rec["builder_bytes"] = files.get("builder.orb", 0)
    # Risky idioms across compiler sources.
    rec["string_concat_all"] = 0
    rec["list_grow_sites"] = 0
    for name in files:
        p = paths[name]
        rec["string_concat_all"] += count_in_file(p, r"out\s*=\s*out\s*\+|\+\s*\"")
        if name in ("resolver.orb", "builder.orb", "parser.orb"):
            rec["list_grow_sites"] += count_in_file(p, r"\.push\(")
    rt = os.path.join(RUNTIME_DIR, "collections.c")
    rec["runtime_concat_def"] = count_in_file(rt, r"orbit_string_concat")
    rec["runtime_list_grow_def"] = count_in_file(rt, r"orbit_list_grow")
    fe = os.path.join(COMPILER_DIR, "tir")
    if os.path.isdir(fe):
        rec["frontend_bytes"] = sum(
            os.path.getsize(os.path.join(fe, n)) for n in os.listdir(fe)
            if n.endswith(".orb"))
    else:
        rec["frontend_bytes"] = 0
    return rec


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------



def read_all_records(path):
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    continue
    except OSError:
        pass
    return out


def write_markdown(path, records, cc):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("# Self-host resource measurement (Phase 0)\n\n")
        f.write("cc: `%s`  platform: `%s`\n\n" % (cc, sys.platform))
        f.write("| phase | wall_s | peak_tree_MB | peak_orbit_MB | peak_cc_MB | in/out |\n")
        f.write("|---|---|---|---|---|---|\n")
        for r in records:
            if r.get("phase") == "static":
                f.write("| static | - | - | - | - | orb=%d KB canon=%d KB runtime=%d KB out_concat=%d |\n" % (
                    r.get("compiler_orb_bytes", 0) // 1024,
                    r.get("canonical_c_bytes", 0) // 1024,
                    r.get("runtime_bytes", 0) // 1024,
                    r.get("c_backend_out_concat", 0)))
            else:
                inout = ""
                if "in_bytes" in r or "out_bytes" in r:
                    ib = r.get("in_bytes", 0) // 1024
                    ob = r.get("out_bytes", 0) // 1024
                    inout = "in=%d KB out=%d KB" % (ib, ob)
                if "out_c_bytes" in r:
                    inout += " c=%d KB" % (r.get("out_c_bytes", 0) // 1024)
                f.write("| %s | %s | %s | %s | %s | %s |\n" % (
                    r.get("phase"), r.get("wall_s"),
                    r.get("peak_tree_mb"), r.get("peak_orbit_mb"),
                    r.get("peak_cc_mb"), inout))
        f.write("\n peak_tree_MB = orbit + cc tree WorkingSet peak during the phase.\n")


def cmd_measure_selfhost(args) -> int:
    out.set_quiet(args.quiet)

    phases = [p.strip() for p in args.phases.split(",") if p.strip()]
    if phases == ["all"]:
        phases = ["static", "amalgamate", "seed-cc", "orbit-build", "iter-cc"]
    heavy = {"seed-cc", "orbit-build", "iter-cc"}
    if not args.allow_heavy and any(p in heavy for p in phases):
        out.fail("Failed measure: refusing heavy phases without --allow-heavy on this machine.")
        out.tip("run with --phases static,amalgamate or add --allow-heavy.")
        return 2

    if args.work:
        work = os.path.abspath(args.work)
        os.makedirs(work, exist_ok=True)
    else:
        work = tempfile.mkdtemp(prefix="orbit_measure_")
    if not args.keep and not args.work:
        import atexit
        atexit.register(lambda: shutil.rmtree(work, ignore_errors=True))

    out_jsonl = args.out_jsonl or os.path.join(work, "measure.jsonl")
    out_md = args.out_md or os.path.join(work, "measure.md")
    os.makedirs(os.path.dirname(os.path.abspath(out_jsonl)) or ".", exist_ok=True)

    cc = args.cc or detect_cc()
    cc_cmd = cc.split()
    plat_link = ["-lws2_32"] if os.name == "nt" else []
    exe = ".exe" if sys.platform == "win32" else ""

    records = []
    total_mb, avail_mb = system_snapshot()
    out.say("Measuring from root: %s" % ROOT)
    out.say("Measuring with cc: %s" % cc)
    out.say("Machine: total=%s MB avail=%s MB" % (total_mb, avail_mb))
    out.say("Work dir: %s" % work)

    def emit(rec):
        records.append(rec)
        with open(out_jsonl, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")

    if "static" in phases:
        rec = static_record()
        rec["cc"] = cc
        emit(rec)
        out.say("Measured static: orb=%d KB canon=%d KB runtime=%d KB out_concat=%d" % (
            rec["compiler_orb_bytes"] // 1024,
            rec["canonical_c_bytes"] // 1024,
            rec["runtime_bytes"] // 1024,
            rec["c_backend_out_concat"]))

    amal = os.path.join(work, "orbit_bootstrap.c")
    if "amalgamate" in phases:
        t0 = time.time()
        r = run_sampled([sys.executable, TRUST, "amalgamate", "--entry", CANONICAL_C,
                         "--out", amal],
                        cwd=ROOT, interval_ms=args.interval_ms,
                        label="amalgamate canonical")
        rec = {"phase": "amalgamate", "cc": cc}
        rec.update(r)
        try:
            rec["out_bytes"] = os.path.getsize(amal)
        except OSError:
            rec["out_bytes"] = 0
        rec["in_bytes"] = rec.get("canonical_c_bytes", 0) or 0
        try:
            rec["in_bytes"] = os.path.getsize(CANONICAL_C)
        except OSError:
            pass
        emit(rec)
        if r["rc"] != 0:
            out.fail("Failed measure: amalgamate failed, stopping.")
            write_markdown(out_md, read_all_records(out_jsonl), cc)
            return 2
    else:
        if os.path.isfile(amal) is False and any(p in heavy for p in phases):
            out.fail("Failed measure: need amalgamate output for heavy phases.")
            out.tip("add amalgamate to --phases.")
            return 2

    seed_exe = os.path.join(work, "seed" + exe)
    if "seed-cc" in phases:
        r = run_sampled([*cc_cmd, *SUPPRESS_FLAGS, "-o", seed_exe, amal,
                         *plat_link],
                        cwd=ROOT, interval_ms=args.interval_ms,
                        label="build seed from amalgamated TU")
        rec = {"phase": "seed-cc", "cc": cc}
        rec.update(r)
        try:
            rec["in_bytes"] = os.path.getsize(amal)
        except OSError:
            rec["in_bytes"] = 0
        try:
            rec["out_bytes"] = os.path.getsize(seed_exe)
        except OSError:
            rec["out_bytes"] = 0
        emit(rec)
        if r["rc"] != 0:
            out.fail("Failed measure: seed-cc failed, stopping.")
            write_markdown(out_md, read_all_records(out_jsonl), cc)
            return 2

    iter_c = None
    if "orbit-build" in phases:
        if not os.path.isfile(seed_exe):
            out.fail("Failed measure: seed exe missing for orbit-build.")
            out.tip("add seed-cc to --phases.")
            return 2
        tmp = os.path.join(work, "tmp_build")
        os.makedirs(tmp, exist_ok=True)
        inter_c = os.path.join(tmp, "orbit_selfhost_build.c")
        env_extra = {"TEMP": tmp, "TMP": tmp, "ORBIT_CC": cc, "CC": cc}
        out_exe = os.path.join(work, "iter1" + exe)
        r = run_sampled([seed_exe, "build", MAIN_ORB, "-o", out_exe],
                        cwd=ROOT, env_extra=env_extra,
                        interval_ms=args.interval_ms,
                        label="seed build main.orb (orbit + inner cc)")
        rec = {"phase": "orbit-build", "cc": cc}
        rec.update(r)
        try:
            rec["out_c_bytes"] = os.path.getsize(inter_c)
            rec["out_c_sha"] = sha256(inter_c)
            iter_c = inter_c
        except OSError:
            rec["out_c_bytes"] = 0
            rec["out_c_sha"] = ""
        try:
            rec["out_bytes"] = os.path.getsize(out_exe)
        except OSError:
            rec["out_bytes"] = 0
        emit(rec)
        if r["rc"] != 0 and rec["out_c_bytes"] == 0:
            out.fail("Failed measure: orbit-build failed with no C emitted, stopping.")
            write_markdown(out_md, read_all_records(out_jsonl), cc)
            return 2

    if "iter-cc" in phases:
        src = iter_c
        if src is None:
            cand = os.path.join(work, "tmp_build", "orbit_selfhost_build.c")
            if os.path.isfile(cand):
                src = cand
        if src is None or not os.path.isfile(src):
            out.fail("Failed measure: no emitted C for iter-cc.")
            out.tip("add orbit-build to --phases.")
            return 2
        out_exe = os.path.join(work, "iter1_rebuilt" + exe)
        r = run_sampled([*cc_cmd, *SUPPRESS_FLAGS, "-I",
                         os.path.join(ROOT, "runtime"),
                         "-o", out_exe, src, *plat_link],
                        cwd=ROOT, interval_ms=args.interval_ms,
                        label="build iter compiler from its own C")
        rec = {"phase": "iter-cc", "cc": cc}
        rec.update(r)
        try:
            rec["in_bytes"] = os.path.getsize(src)
        except OSError:
            rec["in_bytes"] = 0
        try:
            rec["out_bytes"] = os.path.getsize(out_exe)
        except OSError:
            rec["out_bytes"] = 0
        emit(rec)
        if r["rc"] != 0:
            out.fail("Failed measure: iter-cc failed.")
            write_markdown(out_md, read_all_records(out_jsonl), cc)
            return 2

    write_markdown(out_md, read_all_records(out_jsonl), cc)
    out.say("Wrote %s and %s" % (out_jsonl, out_md))
    # The house convention is that every tool closes the same way, and this one
    # did not: a reader (or scripts/alive_check.py) could not tell a finished
    # measurement from a run that stopped early, because both printed whatever
    # the last phase said and exited 0.
    print("Finished measure: %d phase record(s) written" % len(read_all_records(out_jsonl)))
    return 0


# ---- from scripts/emit_ir_corpus.py ----
# Emit the designated IR corpus with `orbit build --emit-ir`.
#
# The corpus is tests/suite (127 programs plus imports.support.orb) and
# tests/std (24 programs): the 151+1 programs docs/IR_SPEC.md section 5.5
# designates, with the same discovery scripts/test_suite.py and
# scripts/measure.py census already use (`.orb`, minus `*.support.orb`,
# which is kept here because the corpus is about IR and the support module
# has IR too).
#
# What comes out is one IRv1 document per program plus a manifest of their
# sha256 hashes.  The manifest is the pinned artifact: a consumer (R6)
# regenerates the corpus from the same language commit, recomputes the
# hashes and compares, so "the corpus" is a hash rather than a directory of
# files somebody copied once.  The same pattern pins runtime/orbit_api.h
# and the runtime archive.
#
# The C step is skipped (ORBIT_SKIP_CC): the artifact under test is the IR
# the builder hands over, not an executable, so emission needs no C
# compiler, links nothing and leaves no binaries behind.
#
# Usage:
#     python scripts/measure.py emit-ir --compiler PATH --out DIR [--manifest PATH]
#     python scripts/measure.py emit-ir --compiler PATH --check --manifest PATH
#     python scripts/measure.py emit-ir --self-test
#
# `--check` re-emits into a temporary directory and reports every file whose
# hash or size differs, plus members that appeared or disappeared; it exits
# 1 on any drift.  Emission is deterministic, so drift means a different
# compiler or changed sources -- which is the point of the check.
#
# `--self-test` is the hermetic half: it asserts the corpus contract (151
# executables plus imports.support.orb, discovered in pinned order) and
# drives the comparator with a synthetic manifest, so the drift detector is
# proven to catch a changed hash, a changed size, a missing member, an extra
# member and a changed whole-corpus hash WITHOUT a compiler.  A comparator
# that cannot fail is not a comparator, and this is the row alive_check owns
# -- the real emission needs the branch compiler and a corpus, which is the
# consumer's run (R6 regenerates and pins).
#!/usr/bin/env python3


SUITE = "tests/suite"
STD = "tests/std"
IR_SCHEMA = "r6-ir-corpus/1"

# The corpus size docs/IR_SPEC.md section 5.5 designates. Named here so the
# self-test asserts a contract rather than re-deriving it from the listing.
SUITE_PROGRAMS = 127
STD_PROGRAMS = 24
SUPPORT_MODULES = 1
PROGRAMS = SUITE_PROGRAMS + STD_PROGRAMS
MEMBERS = PROGRAMS + SUPPORT_MODULES

# The 66 opcode names of docs/IR_SPEC.md section 1, in IROpcode order.
OPCODES = frozenset("""
nop load_const load_var store_var decl_var add sub mul div mod eq ne lt le gt
ge and_op or_op not_op neg begin_block end_block call ret jump jump_if_false
alloc free db_get db_set db_all db_where http_response label copy arg
load_field store_field switch_op type_info list_create list_push list_get
list_set list_len list_pop map_create map_set map_get map_has map_delete
map_keys result_ok result_err result_unwrap result_is_ok result_unwrap_err
union_create union_get_tag union_get_data bit_and bit_or bit_xor shl shr
bit_not
""".split())


def ir_discover():
    """The corpus members as (repo-relative path, kind), in pinned order."""
    entries = []
    for name in sorted(os.listdir(os.path.join(ROOT, SUITE))):
        if not name.endswith(".orb"):
            continue
        kind = "support" if name.endswith(".support.orb") else "executable"
        entries.append((SUITE + "/" + name, kind))
    for name in sorted(os.listdir(os.path.join(ROOT, STD))):
        if name.endswith(".orb"):
            entries.append((STD + "/" + name, "executable"))
    return entries


def ir_name(rel):
    """tests/suite/arith.orb -> tests/suite/arith.ir, tree preserved."""
    return rel[: -len(".orb")] + ".ir"


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canon(obj):
    """Canonical bytes for hashing: sorted keys, compact, ASCII-safe."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True).encode("ascii")


def files_hash(files):
    """The one hash that stands for the corpus. Order is part of the pin."""
    return hashlib.sha256(canon(files)).hexdigest()


def emit(compiler, rel, out_dir):
    """Emit one member; returns the .ir path or None on failure."""
    ir = os.path.join(out_dir, *ir_name(rel).split("/"))
    os.makedirs(os.path.dirname(ir), exist_ok=True)
    env = dict(os.environ)
    env["ORBIT_SKIP_CC"] = "1"
    proc = subprocess.run(
        [compiler, "build", rel, "--emit-ir", ir],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=300,
    )
    if proc.returncode != 0 or not os.path.isfile(ir):
        sys.stderr.write(proc.stdout or "")
        sys.stderr.write(proc.stderr or "")
        return None
    return ir


def language_commit():
    try:
        proc = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                              capture_output=True, text=True, timeout=60)
        return proc.stdout.strip() or None
    except Exception:
        return None


def compiler_fingerprint(compiler):
    try:
        version = subprocess.run([compiler, "--version"], capture_output=True,
                                 text=True, timeout=60).stdout.strip()
    except Exception:
        version = None
    return {
        "path": compiler,
        "sha256": sha256_file(compiler),
        "bytes": os.path.getsize(compiler),
        "version": version or None,
        "languageCommit": language_commit(),
    }


# Runtime symbols the builder lowers a call to without an `extern fn` in the
# source. The emitter declares each one the module calls (IR_SPEC.md 3.3).
RUNTIME_CALLS = frozenset("""
orbit_string_len orbit_string_at orbit_string_slice orbit_string_slice_known_len
orbit_string_indexOf orbit_string_find orbit_object_create orbit_object_set_int
orbit_object_set_float orbit_object_set_bool orbit_object_set_string
orbit_object_set_object orbit_object_set_list orbit_db_query_all
orbit_db_query_first orbit_db_query_where orbit_db_query_where_p
orbit_db_query_get orbit_db_query_order orbit_db_query_order_desc
orbit_db_count_all orbit_db_insert orbit_db_update orbit_db_delete
system_uptime system_pid system_active_workers system_http_requests_total
system_latency_avg_us system_latency_p50_us system_latency_p95_us
system_latency_p99_us
""".split())

# Names the lexer uses for literal kinds. They are not register types.
LEXER_TYPE_NAMES = frozenset(["string_raw", "string_chunk"])


def ir_findings(doc):
    """Completeness findings of one IR document. Pure.

    A consumer cannot guess an opcode name, so an emitted name outside the
    66 of docs/IR_SPEC.md section 1 (the empty string included) is a defect
    of the emitter, never of the consumer. A lexer literal name used as a
    register type (`string_raw`), an object field read left `unknown` and a call to a runtime symbol with no
    extern entry are the same kind of leak.
    """
    findings = []
    declared = {fn["name"] for fn in doc["module"]["functions"]}
    for fn in doc["module"]["functions"]:
        for ins in fn["instructions"]:
            callee = ins.get("operand1", {}).get("value")
            if (ins["opcode"] == "call" and callee in RUNTIME_CALLS
                    and callee not in declared):
                findings.append(f"call to undeclared runtime symbol {callee!r}"
                                f" in {fn['name']}")
        types = fn["registerTypes"]
        for where, name in ([("register r%d" % i, t) for i, t in enumerate(types)]
                            + [("param", t) for t in fn.get("paramTypes", [])]
                            + [("return", fn.get("returnType", ""))]):
            if name == "unknown":
                findings.append(f"type 'unknown' ({where}) in {fn['name']}")
        for ins in fn["instructions"]:
            if ins["opcode"] != "load_field" or ins["dest"] < 0:
                continue
            recv = ins["operand1"].get("value")
            if (ins["operand1"].get("kind") == "Register" and recv < len(types)
                    and types[recv] == "object" and types[ins["dest"]] == "unknown"):
                findings.append(f"untyped object field read in {fn['name']}")
        for index, name in enumerate(fn["registerTypes"]):
            if name in LEXER_TYPE_NAMES:
                findings.append(
                    f"register type {name!r} in {fn['name']} at r{index}")
        for index, ins in enumerate(fn["instructions"]):
            if ins["opcode"] not in OPCODES:
                findings.append(
                    f"opcode {ins['opcode']!r} in {fn['name']} at {index}")
    return findings


def emit_corpus(compiler, out_dir):
    """Emit every member; returns (files, failures)."""
    files = []
    failures = []
    for rel, kind in ir_discover():
        ir = emit(compiler, rel, out_dir)
        if ir is None:
            failures.append(rel)
            continue
        with open(ir, "r", encoding="utf-8") as handle:
            for finding in ir_findings(json.load(handle)):
                print(f"  INCOMPLETE {rel}: {finding}")
                failures.append(rel)
        files.append({
            "path": rel,
            "kind": kind,
            "ir": ir_name(rel),
            "bytes": os.path.getsize(ir),
            "sha256": sha256_file(ir),
        })
    return files, failures


def totals(files):
    counts = {"executable": 0, "support": 0, "total": len(files)}
    for entry in files:
        counts[entry["kind"]] += 1
    return counts


def manifest_for(files, fingerprint):
    return {
        "schema": IR_SCHEMA,
        "emitter": fingerprint,
        "counts": totals(files),
        "totalBytes": sum(entry["bytes"] for entry in files),
        "filesSha256": files_hash(files),
        "files": files,
    }


def write_manifest(path, doc):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(doc, indent=2, ensure_ascii=True) + "\n")


def compare(pinned, files):
    """Findings of an emission against a pinned manifest. Pure."""
    findings = []
    want = {entry["path"]: entry for entry in pinned.get("files", [])}
    got = {entry["path"]: entry for entry in files}
    for path in sorted(set(want) | set(got)):
        if path not in got:
            findings.append(f"MISSING {path}")
        elif path not in want:
            findings.append(f"EXTRA   {path}")
        elif want[path] != got[path]:
            findings.append(
                f"DRIFT   {path} {want[path]['sha256']} -> {got[path]['sha256']}")
    if files_hash(files) != pinned.get("filesSha256"):
        findings.append(
            f"DRIFT   filesSha256 {pinned.get('filesSha256')} -> {files_hash(files)}")
    return findings


def emitter_line(label, fingerprint):
    return (f"{label} emitter: {fingerprint.get('version')} "
            f"{fingerprint.get('languageCommit')} {fingerprint.get('sha256')}")


def check_against(compiler, pinned_path):
    """Re-emit and compare against a pinned manifest."""
    with open(pinned_path, "r", encoding="utf-8") as handle:
        pinned = json.load(handle)
    work = tempfile.mkdtemp(prefix="orbit_ir_corpus_")
    print(f"emitting into {work}")
    files, failures = emit_corpus(compiler, work)
    for rel in failures:
        print(f"  FAIL    emit/complete {rel}")
    findings = compare(pinned, files)
    for finding in findings:
        print(f"  {finding}")
    print(emitter_line("pinned", pinned.get("emitter", {})))
    print(emitter_line("regen ", compiler_fingerprint(compiler)))
    if findings or failures:
        print(f"FAIL: corpus drifts from {pinned_path}")
        return 1
    print(f"ok: {len(files)} files, filesSha256 {files_hash(files)}")
    return 0


def self_test_emit_ir():
    """Prove the corpus contract and the drift detector, with no compiler."""
    checks = []

    def check(name, condition, detail=""):
        checks.append((name, bool(condition), detail))

    entries = ir_discover()
    paths = [path for path, _ in entries]
    kinds = [kind for _, kind in entries]
    executables = [p for p in kinds if p == "executable"]
    check(f"corpus has {PROGRAMS}+{SUPPORT_MODULES} members", len(entries) == MEMBERS,
          f"got {len(entries)}")
    check(f"corpus has {PROGRAMS} executables", len(executables) == PROGRAMS,
          f"got {len(executables)}")
    check(f"corpus has {SUPPORT_MODULES} support module",
          kinds.count("support") == SUPPORT_MODULES)
    check(f"suite contributes {SUITE_PROGRAMS}+{SUPPORT_MODULES}",
          sum(1 for p in paths if p.startswith(SUITE + "/")) == SUITE_PROGRAMS + SUPPORT_MODULES)
    check(f"std contributes {STD_PROGRAMS}",
          sum(1 for p in paths if p.startswith(STD + "/")) == STD_PROGRAMS)
    check("imports.support.orb is the support member",
          [p for p, k in entries if k == "support"] == [SUITE + "/imports.support.orb"])
    check("no .skip member is discovered",
          all(not p.endswith(".skip") for p in paths))
    suite_paths = [p for p in paths if p.startswith(SUITE + "/")]
    std_paths = [p for p in paths if p.startswith(STD + "/")]
    check("suite members are sorted", suite_paths == sorted(suite_paths))
    check("std members are sorted", std_paths == sorted(std_paths))
    check("the suite block precedes the std block",
          paths == suite_paths + std_paths)
    check("no duplicate member", len(set(paths)) == len(paths))
    check("IR name keeps the tree",
          ir_name("tests/suite/arith.orb") == "tests/suite/arith.ir")
    check("IR name does not touch the source name",
          ir_name("tests/std/test_io.orb") == "tests/std/test_io.ir")

    sample = [
        {"path": "a.orb", "kind": "executable", "ir": "a.ir",
         "bytes": 3, "sha256": "a" * 64},
        {"path": "b.support.orb", "kind": "support", "ir": "b.support.ir",
         "bytes": 5, "sha256": "b" * 64},
    ]
    pinned = {"schema": IR_SCHEMA, "files": sample, "filesSha256": files_hash(sample)}
    check("an identical emission compares clean",
          compare(pinned, [dict(e) for e in sample]) == [])

    tampered = json.loads(json.dumps(pinned))
    tampered["files"][0]["sha256"] = "c" * 64
    check("a changed hash is caught",
          any("DRIFT" in f and "a.orb" in f for f in compare(tampered, sample)))
    resized = json.loads(json.dumps(pinned))
    resized["files"][1]["bytes"] = 6
    check("a changed size is caught",
          any("DRIFT" in f and "b.support.orb" in f for f in compare(resized, sample)))
    short = json.loads(json.dumps(pinned))
    short["files"] = short["files"][:1]
    short["filesSha256"] = files_hash(short["files"])
    check("a missing member is caught",
          any(f.startswith("MISSING") for f in compare(pinned, sample[:1])))
    check("an extra member is caught",
          any(f.startswith("EXTRA") for f in compare(short, sample)))
    rootless = json.loads(json.dumps(pinned))
    rootless["filesSha256"] = "0" * 64
    check("a changed whole-corpus hash is caught",
          any("filesSha256" in f for f in compare(rootless, sample)))
    check("the whole-corpus hash ignores key order",
          files_hash([dict(e) for e in sample]) == files_hash(sample))

    def doc_with(opcode):
        return {"module": {"functions": [{
            "name": "f", "registerTypes": [],
            "instructions": [{"opcode": opcode}]}]}}

    check("the 66 opcode names are distinct", len(OPCODES) == 66)
    check("a named opcode is complete", ir_findings(doc_with("shl")) == [])
    check("an empty opcode is caught", len(ir_findings(doc_with(""))) == 1)
    leaked = doc_with("load_const")
    leaked["module"]["functions"][0]["registerTypes"] = ["string_raw"]
    check("a lexer literal name as a register type is caught",
          len(ir_findings(leaked)) == 1)
    call = doc_with("call")
    call["module"]["functions"][0]["instructions"][0]["operand1"] = {
        "kind": "String", "value": "system_pid"}
    check("a call to an undeclared runtime symbol is caught",
          len(ir_findings(call)) == 1)
    call["module"]["functions"].append({
        "name": "system_pid", "registerTypes": [], "instructions": []})
    check("a declared runtime symbol is complete", ir_findings(call) == [])
    read = doc_with("load_field")
    read["module"]["functions"][0]["registerTypes"] = ["object", "unknown"]
    read["module"]["functions"][0]["instructions"][0].update(
        {"dest": 1, "operand1": {"kind": "Register", "value": 0}})
    check("an untyped object field read is caught",
          any("object field read" in f for f in ir_findings(read)))
    read["module"]["functions"][0]["registerTypes"][1] = "int"
    check("a typed object field read is complete", ir_findings(read) == [])
    typed = doc_with("nop")
    typed["module"]["functions"][0]["registerTypes"] = ["void*"]
    check("void* is a complete register type", ir_findings(typed) == [])
    typed["module"]["functions"][0]["registerTypes"] = ["unknown"]
    check("an unknown register type is caught", len(ir_findings(typed)) == 1)
    check("an unknown opcode is caught",
          len(ir_findings(doc_with("shift_left"))) == 1)

    passed = sum(1 for _, ok, _ in checks if ok)
    for name, ok, detail in checks:
        if not ok:
            print(f"  FAIL {name} {detail}")
    print(f"Finished emit-ir-corpus self-test: {passed}/{len(checks)}")
    return 0 if passed == len(checks) else 1


def cmd_emit_ir(args) -> int:
    if args.self_test:
        return self_test_emit_ir()
    if not args.compiler:
        print("measure.py emit-ir: error: --compiler is required "
              "unless --self-test", file=sys.stderr)
        return 2
    compiler = os.path.abspath(args.compiler)
    if not os.path.isfile(compiler):
        print(f"no compiler at {compiler}")
        return 2
    if args.check:
        if not args.manifest:
            print("measure.py emit-ir: error: --check needs "
                  "--manifest", file=sys.stderr)
            return 2
        return check_against(compiler, args.manifest)
    manifest = args.manifest or os.path.join(args.out, "manifest.json")
    files, failures = emit_corpus(compiler, args.out)
    if failures:
        print(f"FAIL: {len(failures)} member(s) did not emit or are incomplete")
        return 1
    doc = manifest_for(files, compiler_fingerprint(compiler))
    write_manifest(manifest, doc)
    print(f"wrote {len(files)} IR documents under {args.out}")
    print(f"  executables {doc['counts']['executable']}, "
          f"support {doc['counts']['support']}, bytes {doc['totalBytes']}")
    print(f"  manifest {manifest}")
    print(f"  filesSha256 {doc['filesSha256']}")
    return 0


# ---- from scripts/ir_unknown_census.py ----
# Register types the emitted IR leaves `unknown`, by defining opcode.
#
# `measure.py census` counts what the front end cannot type. This counts what a
# second backend sees: the `registerTypes` entry of every instruction
# destination in the documents `orbit build --emit-ir` writes. A backend that
# reads `unknown` has to re-infer the type, so the count is the work it repeats.
#
# Usage:
#     python scripts/measure.py ir-census --compiler PATH [--top N] [--json]
#     python scripts/measure.py ir-census --ir-dir DIR [--top N] [--json]
#     python scripts/measure.py ir-census --self-test
#
# `--compiler` emits the corpus of `scripts/measure.py emit-ir` into a scratch
# directory first. `--ir-dir` reads an already emitted tree of `.ir` files.
# The exit code is 0 whatever the count is; this is a measurement.
#!/usr/bin/env python3




def census(ir_dir):
    """Return (instructions, destinations, unknown, by_opcode, by_opcode_all)."""
    instructions = 0
    destinations = 0
    unknown = 0
    unknown_by = Counter()
    all_by = Counter()
    for dirpath, dirnames, filenames in os.walk(ir_dir):
        dirnames.sort()
        for name in sorted(filenames):
            if not name.endswith(".ir"):
                continue
            with open(os.path.join(dirpath, name), encoding="utf-8") as handle:
                doc = json.load(handle)
            for fn in doc["module"]["functions"]:
                types = fn["registerTypes"]
                for ins in fn["instructions"]:
                    instructions += 1
                    dest = ins["dest"]
                    if dest < 0:
                        continue
                    destinations += 1
                    all_by[ins["opcode"]] += 1
                    if types[dest] == "unknown":
                        unknown += 1
                        unknown_by[ins["opcode"]] += 1
    return instructions, destinations, unknown, unknown_by, all_by


def per_mille(part, whole):
    return part * 1000 // whole if whole else 0


def self_test_ir_census():
    checks = []
    with tempfile.TemporaryDirectory() as tmp:
        def ins(opcode, dest):
            return {"opcode": opcode, "dest": dest}
        doc = {"module": {"functions": [{
            "registerTypes": ["int", "unknown", "bool", "unknown"],
            "instructions": [ins("load_const", 0), ins("add", 1), ins("eq", 2),
                             ins("add", 3), ins("ret", -1)]}]}}
        with open(os.path.join(tmp, "a.ir"), "w", encoding="utf-8") as handle:
            json.dump(doc, handle)
        with open(os.path.join(tmp, "b.json"), "w", encoding="utf-8") as handle:
            handle.write("not read")
        total, dests, unk, by, all_by = census(tmp)
        checks.append(("counts every instruction", total == 5))
        checks.append(("counts destinations only", dests == 4))
        checks.append(("counts unknown destinations", unk == 2))
        checks.append(("attributes unknown to the defining opcode",
                       by == Counter({"add": 2}) and all_by["eq"] == 1))
        checks.append(("ignores files that are not .ir", total == 5))
    checks.append(("per mille rounds down", per_mille(2, 4) == 500 and per_mille(1, 3) == 333))
    passed = sum(1 for _, ok in checks if ok)
    for name, ok in checks:
        if not ok:
            print(f"  FAIL {name}")
    print(f"Finished ir-unknown-census self-test: {passed}/{len(checks)}")
    return 0 if passed == len(checks) else 1


def cmd_ir_census(args) -> int:
    if args.self_test:
        return self_test_ir_census()
    if bool(args.compiler) == bool(args.ir_dir):
        print("measure.py ir-census: error: give exactly one of "
              "--compiler and --ir-dir", file=sys.stderr)
        return 2
    scratch = None
    ir_dir = args.ir_dir
    if args.compiler:
        scratch = tempfile.TemporaryDirectory()
        ir_dir = scratch.name
        compiler = os.path.abspath(args.compiler)
        files, failures = emit_corpus(compiler, ir_dir)
        if failures:
            print(f"FAIL: {len(failures)} member(s) did not emit")
            return 2
    total, dests, unk, by, all_by = census(ir_dir)
    if scratch:
        scratch.cleanup()
    if args.json:
        print(json.dumps({
            "instructions": total, "destinations": dests, "unknown": unk,
            "unknown_per_mille_of_instructions": per_mille(unk, total),
            "by_opcode": dict(by.most_common()),
        }, indent=2))
        return 0
    print(f"{'opcode':<22}{'unknown':>8}{'of':>8}")
    for opcode, count in by.most_common(args.top):
        print(f"{opcode:<22}{count:>8}{all_by[opcode]:>8}")
    print(f"Finished ir-unknown-census: {unk} unknown of {dests} destinations, "
          f"{total} instructions, {per_mille(unk, total)} per mille of instructions")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="measure.py",
        description="The corpus measurements: eight tools that count, fuzz and time, one entry point.",
        epilog="Each subcommand takes the flags its own tool had before the merge; run `%(prog)s <subcommand> --help`.")
    sub = ap.add_subparsers(dest="command", metavar="SUBCOMMAND", required=True)

    sp = sub.add_parser('census', help=_DESC_census, description=_DESC_census)
    sp.add_argument("--compiler", default=_fp_default())
    sp.add_argument("--cc", default="gcc", help="C compiler for building the probe")
    sp.add_argument("--dir", action="append", default=None,
                    help="corpus directory, repeatable (default: %s)"
                         % ", ".join(DEFAULT_DIRS))
    sp.add_argument("--top", type=int, default=15)
    sp.add_argument("--json", action="store_true",
                    help="emit the census as the only thing on stdout")
    sp.add_argument("--strict", action="store_true",
                    help="exit non-zero if the census cannot RUN (never on a count)")
    out.add_quiet(sp)

    sp = sub.add_parser('ratchet', help=_DESC_ratchet, description=_DESC_ratchet)
    sp.add_argument("--compiler", default=_fp_default())
    sp.add_argument("--cc", default="gcc", help="C compiler for building the census probe")
    sp.add_argument("--dir", action="append", default=None,
                    help="corpus directory, repeatable (passed to the census)")
    sp.add_argument("--baseline", default=DEFAULT_BASELINE)
    sp.add_argument("--from-json", default=None,
                    help="read a census document from a file instead of running "
                         "the census (the seam: any source with these keys works)")
    sp.add_argument("--top", type=int, default=8,
                    help="how many per-file movers to name")
    sp.add_argument("--per-file", action="store_true",
                    help="stricter: any single file's count rising is a failure, "
                         "even if the total held. Off by default, because a new "
                         "file legitimately brings new unknowns with it")
    sp.add_argument("--write-baseline", action="store_true",
                    help="record today's measurement as the new baseline")
    sp.add_argument("--allow-regression", action="store_true",
                    help="permit --write-baseline to move a number UP")
    sp.add_argument("--self-test", action="store_true",
                    help="run the verdict logic against synthetic measurements "
                         "and assert it says no where it must")
    out.add_quiet(sp)

    sp = sub.add_parser('diff-fuzz', help=_DESC_diff_fuzz, description=_DESC_diff_fuzz)
    sp.add_argument("--compiler", default=_fp_default())
    sp.add_argument("--cc", default="gcc", help="inline, for run/build")
    sp.add_argument("--seed", type=int, default=SEED)
    sp.add_argument("--iterations", type=int, default=400,
                    help="size of the generated part of the corpus (default 400)")
    sp.add_argument("--only", action="append", default=None,
                    help="restrict to a category (repeatable): %s"
                         % ", ".join(CATEGORIES))
    sp.add_argument("--batch", type=int, default=40,
                    help="how many one-line cases share one program (default 40; "
                         "a build costs the same whatever the program contains)")
    sp.add_argument("--json", default=None, help="write every finding to this file")
    sp.add_argument("--top", type=int, default=12,
                    help="how many example programs to print per class")
    sp.add_argument("--strict", action="store_true",
                    help="exit non-zero when any case disagrees (report-only "
                         "by default: a fuzzer that fails the build the day a "
                         "finding appears is one that gets switched off)")
    sp.add_argument("--list", action="store_true",
                    help="print the corpus without running anything")
    out.add_quiet(sp)

    sp = sub.add_parser('routes', help=_DESC_routes, description=_DESC_routes)

    sp = sub.add_parser('phase-times', help=_DESC_phase_times, description=_DESC_phase_times)
    sp.add_argument("--compiler", required=True,
                    help="path to an existing orbit compiler binary")
    sp.add_argument("--cc", default=None,
                    help="C compiler the inner build uses (default: ORBIT_CC/CC on PATH)")
    sp.add_argument("--runs", type=int, default=5,
                    help="measured runs after one warm-up (default 5)")
    sp.add_argument("--only", action="append", default=None,
                    choices=PROGRAM_ORDER,
                    help="measure only this program; repeatable")
    sp.add_argument("--work", default=DEFAULT_WORK,
                    help="scratch directory (default scratch/phase)")
    sp.add_argument("--timeout", type=int, default=1800,
                    help="per-process timeout in seconds (default 1800)")
    sp.add_argument("--json", default=None, help="write the samples as JSON")
    sp.add_argument("--self-test", action="store_true",
                    help="check that the harness can fail, then exit")
    out.add_quiet(sp)

    sp = sub.add_parser('measure-selfhost', help=_DESC_measure_selfhost, description=_DESC_measure_selfhost)
    sp.add_argument("--cc", default=None, help="C compiler (default: auto-detect)")
    sp.add_argument("--work", default=None, help="work dir (default: temp)")
    sp.add_argument("--keep", action="store_true", help="keep work dir")
    sp.add_argument("--interval-ms", type=int, default=100, help="RSS sample period")
    sp.add_argument("--phases", default="static,amalgamate",
                    help="comma list of static,amalgamate,seed-cc,orbit-build,iter-cc,all")
    sp.add_argument("--allow-heavy", action="store_true",
                    help="permit cc/orbit subprocess phases (needs RAM)")
    sp.add_argument("--out-jsonl", default=None, help="JSONL output path")
    sp.add_argument("--out-md", default=None, help="markdown output path")
    out.add_quiet(sp)

    sp = sub.add_parser('emit-ir', help=_DESC_emit_ir, description=_DESC_emit_ir)
    sp.add_argument("--compiler", default=None)
    sp.add_argument("--out", default=os.path.join(ROOT, ".orbit", "ir-corpus"))
    sp.add_argument("--manifest", default=None)
    sp.add_argument("--check", action="store_true")
    sp.add_argument("--self-test", action="store_true")

    sp = sub.add_parser('ir-census', help=_DESC_ir_census, description=_DESC_ir_census)
    sp.add_argument("--compiler", default=None)
    sp.add_argument("--ir-dir", default=None)
    sp.add_argument("--top", type=int, default=20)
    sp.add_argument("--json", action="store_true")
    sp.add_argument("--self-test", action="store_true")

    args = ap.parse_args()
    commands = {
        "census": cmd_census,
        "ratchet": cmd_ratchet,
        "diff-fuzz": cmd_diff_fuzz,
        "routes": cmd_routes,
        "phase-times": cmd_phase_times,
        "measure-selfhost": cmd_measure_selfhost,
        "emit-ir": cmd_emit_ir,
        "ir-census": cmd_ir_census,
    }
    return commands[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
