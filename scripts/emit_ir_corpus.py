#!/usr/bin/env python3
"""Emit the designated IR corpus with `orbit build --emit-ir`.

The corpus is tests/suite (73 programs plus imports.support.orb) and
tests/std (23 programs): the 96+1 programs docs/IR_SPEC.md section 5.5
designates, with the same discovery scripts/test_suite.py and
scripts/unknown_census.py already use (`.orb`, minus `*.support.orb`,
which is kept here because the corpus is about IR and the support module
has IR too).

What comes out is one IRv1 document per program plus a manifest of their
sha256 hashes.  The manifest is the pinned artifact: a consumer (R6)
regenerates the corpus from the same language commit, recomputes the
hashes and compares, so "the corpus" is a hash rather than a directory of
files somebody copied once.  The same pattern pins runtime/orbit_api.h
and the runtime archive.

The C step is skipped (ORBIT_SKIP_CC): the artifact under test is the IR
the builder hands over, not an executable, so emission needs no C
compiler, links nothing and leaves no binaries behind.

Usage:
    python scripts/emit_ir_corpus.py --compiler PATH --out DIR [--manifest PATH]
    python scripts/emit_ir_corpus.py --compiler PATH --check --manifest PATH
    python scripts/emit_ir_corpus.py --self-test

`--check` re-emits into a temporary directory and reports every file whose
hash or size differs, plus members that appeared or disappeared; it exits
1 on any drift.  Emission is deterministic, so drift means a different
compiler or changed sources -- which is the point of the check.

`--self-test` is the hermetic half: it asserts the corpus contract (96
executables plus imports.support.orb, discovered in pinned order) and
drives the comparator with a synthetic manifest, so the drift detector is
proven to catch a changed hash, a changed size, a missing member, an extra
member and a changed whole-corpus hash WITHOUT a compiler.  A comparator
that cannot fail is not a comparator, and this is the row alive_check owns
-- the real emission needs the branch compiler and a corpus, which is the
consumer's run (R6 regenerates and pins).
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITE = "tests/suite"
STD = "tests/std"
SCHEMA = "r6-ir-corpus/1"

# The corpus size docs/IR_SPEC.md section 5.5 designates. Named here so the
# self-test asserts a contract rather than re-deriving it from the listing.
SUITE_PROGRAMS = 73
STD_PROGRAMS = 23
SUPPORT_MODULES = 1
PROGRAMS = SUITE_PROGRAMS + STD_PROGRAMS
MEMBERS = PROGRAMS + SUPPORT_MODULES


def discover():
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


def emit_corpus(compiler, out_dir):
    """Emit every member; returns (files, failures)."""
    files = []
    failures = []
    for rel, kind in discover():
        ir = emit(compiler, rel, out_dir)
        if ir is None:
            failures.append(rel)
            continue
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
        "schema": SCHEMA,
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
        print(f"  FAIL    emit {rel}")
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


def self_test():
    """Prove the corpus contract and the drift detector, with no compiler."""
    checks = []

    def check(name, condition, detail=""):
        checks.append((name, bool(condition), detail))

    entries = discover()
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
    pinned = {"schema": SCHEMA, "files": sample, "filesSha256": files_hash(sample)}
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

    passed = sum(1 for _, ok, _ in checks if ok)
    for name, ok, detail in checks:
        if not ok:
            print(f"  FAIL {name} {detail}")
    print(f"Finished emit-ir-corpus self-test: {passed}/{len(checks)}")
    return 0 if passed == len(checks) else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", default=None)
    ap.add_argument("--out", default=os.path.join(ROOT, ".orbit", "ir-corpus"))
    ap.add_argument("--manifest", default=None)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if not args.compiler:
        ap.error("--compiler is required unless --self-test")
    compiler = os.path.abspath(args.compiler)
    if not os.path.isfile(compiler):
        print(f"no compiler at {compiler}")
        return 2
    if args.check:
        if not args.manifest:
            ap.error("--check needs --manifest")
        return check_against(compiler, args.manifest)
    manifest = args.manifest or os.path.join(args.out, "manifest.json")
    files, failures = emit_corpus(compiler, args.out)
    if failures:
        print(f"FAIL: {len(failures)} member(s) did not emit")
        return 1
    doc = manifest_for(files, compiler_fingerprint(compiler))
    write_manifest(manifest, doc)
    print(f"wrote {len(files)} IR documents under {args.out}")
    print(f"  executables {doc['counts']['executable']}, "
          f"support {doc['counts']['support']}, bytes {doc['totalBytes']}")
    print(f"  manifest {manifest}")
    print(f"  filesSha256 {doc['filesSha256']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
