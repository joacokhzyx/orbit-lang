#!/usr/bin/env python3
"""Register types the emitted IR leaves `unknown`, by defining opcode.

`unknown_census.py` counts what the front end cannot type. This counts what a
second backend sees: the `registerTypes` entry of every instruction
destination in the documents `orbit build --emit-ir` writes. A backend that
reads `unknown` has to re-infer the type, so the count is the work it repeats.

Usage:
    python scripts/ir_unknown_census.py --compiler PATH [--top N] [--json]
    python scripts/ir_unknown_census.py --ir-dir DIR [--top N] [--json]
    python scripts/ir_unknown_census.py --self-test

`--compiler` emits the corpus of `scripts/emit_ir_corpus.py` into a scratch
directory first. `--ir-dir` reads an already emitted tree of `.ir` files.
The exit code is 0 whatever the count is; this is a measurement.
"""

import argparse
import json
import os
import sys
import tempfile
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


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


def self_test():
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", default=None)
    ap.add_argument("--ir-dir", default=None)
    ap.add_argument("--top", type=int, default=20)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if bool(args.compiler) == bool(args.ir_dir):
        ap.error("give exactly one of --compiler and --ir-dir")
    scratch = None
    ir_dir = args.ir_dir
    if args.compiler:
        import emit_ir_corpus
        scratch = tempfile.TemporaryDirectory()
        ir_dir = scratch.name
        compiler = os.path.abspath(args.compiler)
        files, failures = emit_ir_corpus.emit_corpus(compiler, ir_dir)
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


if __name__ == "__main__":
    sys.exit(main())
