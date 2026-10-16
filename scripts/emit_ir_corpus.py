#!/usr/bin/env python3
"""Emit the designated IR corpus with `orbit build --emit-ir`.

The corpus is tests/suite (67 programs plus imports.support.orb) and
tests/std (22 programs): the 89+1 programs docs/IR_SPEC.md section 5.5
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

`--check` re-emits into a temporary directory and reports every file whose
hash or size differs, plus members that appeared or disappeared; it exits
1 on any drift.  Emission is deterministic, so drift means a different
compiler or changed sources -- which is the point of the check.
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
    """Emit every member; returns (entries, files, failures)."""
    entries = discover()
    files = []
    failures = []
    for rel, kind in entries:
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
    return entries, files, failures


def totals(files):
    counts = {"executable": 0, "support": 0, "total": len(files)}
    for entry in files:
        counts[entry["kind"]] += 1
    return counts


def manifest_for(entries, files, fingerprint):
    return {
        "schema": SCHEMA,
        "emitter": fingerprint,
        "counts": totals(files),
        "totalBytes": sum(entry["bytes"] for entry in files),
        "filesSha256": hashlib.sha256(canon(files)).hexdigest(),
        "files": files,
    }


def write_manifest(path, doc):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(doc, indent=2, ensure_ascii=True) + "\n")


def check_against(compiler, pinned_path):
    """Re-emit and compare against a pinned manifest."""
    with open(pinned_path, "r", encoding="utf-8") as handle:
        pinned = json.load(handle)
    work = tempfile.mkdtemp(prefix="orbit_ir_corpus_")
    print(f"emitting into {work}")
    entries, files, failures = emit_corpus(compiler, work)
    drifted = False
    for rel in failures:
        print(f"  FAIL emit {rel}")
        drifted = True
    want = {entry["path"]: entry for entry in pinned.get("files", [])}
    got = {entry["path"]: entry for entry in files}
    for path in sorted(set(want) | set(got)):
        if path not in got:
            print(f"  MISSING {path}")
            drifted = True
        elif path not in want:
            print(f"  EXTRA   {path}")
            drifted = True
        elif want[path] != got[path]:
            print(f"  DRIFT   {path}")
            print(f"    pinned {want[path]['sha256']} {want[path]['bytes']} bytes")
            print(f"    got    {got[path]['sha256']} {got[path]['bytes']} bytes")
            drifted = True
    got_root = hashlib.sha256(canon(files)).hexdigest()
    pinned_root = pinned.get("filesSha256")
    if got_root != pinned_root:
        print(f"  DRIFT   filesSha256 {pinned_root} -> {got_root}")
        drifted = True
    emitter = pinned.get("emitter", {})
    print(f"pinned emitter: {emitter.get('version')} "
          f"{emitter.get('languageCommit')} {emitter.get('sha256')}")
    now = compiler_fingerprint(compiler)
    print(f"regen  emitter: {now.get('version')} "
          f"{now.get('languageCommit')} {now.get('sha256')}")
    if drifted:
        print(f"FAIL: corpus drifts from {pinned_path}")
        return 1
    print(f"ok: {len(files)} files, filesSha256 {got_root}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", required=True)
    ap.add_argument("--out", default=os.path.join(ROOT, ".orbit", "ir-corpus"))
    ap.add_argument("--manifest", default=None)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    compiler = os.path.abspath(args.compiler)
    if args.check:
        if not args.manifest:
            ap.error("--check needs --manifest")
        return check_against(compiler, args.manifest)
    manifest = args.manifest or os.path.join(args.out, "manifest.json")
    entries, files, failures = emit_corpus(compiler, args.out)
    if failures:
        print(f"FAIL: {len(failures)} member(s) did not emit")
        return 1
    doc = manifest_for(entries, files, compiler_fingerprint(compiler))
    write_manifest(manifest, doc)
    print(f"wrote {len(files)} IR documents under {args.out}")
    print(f"  executables {doc['counts']['executable']}, "
          f"support {doc['counts']['support']}, "
          f"bytes {doc['totalBytes']}")
    print(f"  manifest {manifest}")
    print(f"  filesSha256 {doc['filesSha256']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
