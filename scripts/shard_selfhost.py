#!/usr/bin/env python3
"""Sharded build driver for the Orbit selfhost compiler C.

Contract: docs/shard_layout.md (the emitter owns the layout; this driver
implements against it). Given the single-TU emission (<base>.c plus the
compiler-emitted <base>.h), the driver partitions the TU into 8 shards
(R1-R7), compiles each shard with ``gcc -c`` in parallel plus link (R8),
and verifies that the linked binary re-emits byte-identical C (R10c).

E1 mode (``--header`` points at the compiler-emitted ``<base>.h``; when
absent, ``<tu-dir>/<base>.h`` is used when it exists): the TU already
carries external linkage; gaps stay in the header (R2), ``static inline``
bodies stay in the header (R3), guard-wrapped bodies keep their ``#if``
openers/closers (R4), shard0 carries the prologue plus the named preamble
helpers (R5), the tail goes to the last shard (R6), the rest is dealt
greedily by body-line count (R7). A TU without its E1 header is refused:
there is no unity fallback here (that fallback lives in the callers,
which compile unity when this driver fails).

Usage:
    python scripts/shard_selfhost.py --tu path/to/orbit_selfhost_build.c
        --header path/to/orbit_selfhost_build.h
        --shards-dir C:/Temp/sharde2/shards --cc gcc --jobs 8
        --out C:/Temp/sharde2/shardlinked.exe
        --reference C:/Temp/sharde2/fp.exe --verify

    python scripts/shard_selfhost.py --self-test   # D8 aliveness (fast)

Exit codes: 0 ok; 1 partition/coverage failure; 2 a shard did not compile
(the message names the shard); 3 link failure; 4 emission SHA mismatch;
5 usage/environment failure. No state is kept between runs: every output
goes under --shards-dir and a private temp dir (removed unless --keep).

The header is copied into --shards-dir next to the shards, so the bundle
(shards + header + TSV) is self-describing for verifiers. Shard compile
flags mirror the TU flags plus -DORBIT_SEPARATE_COMPILATION, so the link
needs libruntime_net.a (R8); unity builds omit the flag and carry the
runtime inline instead, which is why they link with no library.

DB programs stay on the unity build (R8): a TU with a real (column-0)
``ORBIT_WITH_DB`` conditional fails here instead of mislinking.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_TU = os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c")
DEFAULT_RUNTIME = os.path.join(ROOT, "runtime")
N_SHARDS = 8

# R5: preamble-helper bodies owned by shard0, in this order. Only the ones
# present in the TU are moved (selfhost carries orbit_color_enabled only;
# route programs carry the rest).
PREAMBLE_HELPERS = (
    "orbit_color_enabled",
    "orbit_print_kynx_gradient",
    "orbit_render_server_banner",
    "orbit_worker_loop",
    "orbit_ctrl_handler",
    "orbit_term_handler",
    "orbit_kynx_register_limits",
)

# R1: a definition starts at a column-0 line outside #/}/, ending with {,
# whose name before ( is not a control word. Bodies are indented, but
# goto labels land at column 0 inside bodies and must be skipped.
DEF_RE = re.compile(
    r'^(static\s+)?(__attribute__\(\(.*?\)\)\s+)?(inline\s+)?'
    r'([A-Za-z_][\w]*[\s\*]+)+([A-Za-z_][\w]*)\s*\(')
CTRL = {'if', 'while', 'for', 'switch', 'return', 'sizeof'}


def fail(msg, code=1):
    out.fail("Failed shard-selfhost: %s" % msg)
    return code


def sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_tu(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    text = raw.decode("utf-8")
    newline = "\r\n" if b"\r\n" in raw else "\n"
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return raw, lines, newline


def is_def(line):
    if not line or line[0] in ' \t#}/':
        return None
    s = line.strip()
    if not s.endswith('{'):
        return None
    m = DEF_RE.match(s)
    if not m or m.group(5) in CTRL:
        return None
    return m.group(5)


def parse_tu(lines):
    """R1: brace-aware partition into header, bodies, gaps, tail."""
    starts = []
    for i, l in enumerate(lines):
        name = is_def(l)
        if name:
            starts.append((i, name))
    if not starts:
        raise ValueError("no top-level definitions found (R1 found nothing)")

    def body_end(st, limit):
        j = st + 1
        while j < limit:
            l = lines[j]
            if l == '' or l[0] in '# \t':
                j += 1
                continue
            if l[0] == '}':
                return j
            s = l.strip()
            if re.match(r'^\w+:\s*;?$', s) or s.startswith('case ') \
                    or s.startswith('default:'):
                j += 1
                continue
            return j - 1
        return limit - 1

    bodies = []
    for si, (st, name) in enumerate(starts):
        limit = starts[si + 1][0] if si + 1 < len(starts) else len(lines)
        bodies.append([st, body_end(st, limit), name])
    gaps = []
    for si, (st, en, _name) in enumerate(bodies):
        prev = bodies[si - 1][1] + 1 if si > 0 else starts[0][0]
        gaps.append(lines[prev:st])
    tail = lines[bodies[-1][1] + 1:]
    return lines[:starts[0][0]], bodies, gaps, tail


def cond_pairs(lines):
    stack, pairs = [], {}
    for i, l in enumerate(lines):
        s = l.strip()
        if re.match(r'#\s*(if|ifdef|ifndef)\b', s):
            stack.append(i)
        elif re.match(r'#\s*endif\b', s):
            if stack:
                pairs[stack.pop()] = i
    return pairs


def assert_no_toplevel_else(lines, bodies):
    """R4 precondition: no top-level #else/#elif. Body-internal directives
    are the owning body's business; only gap/header/tail lines count."""
    in_body = set()
    for st, en, _name in bodies:
        in_body.update(range(st, en + 1))
    depth = 0
    for i, l in enumerate(lines):
        if i in in_body:
            continue
        s = l.strip()
        if re.match(r'#\s*(if|ifdef|ifndef)\b', s):
            depth += 1
        elif re.match(r'#\s*endif\b', s):
            depth = max(0, depth - 1)
        elif re.match(r'#\s*(else|elif)\b', s):
            if depth <= 1:
                raise ValueError(
                    "top-level #else/#elif at TU line %d (R4 forbids it): %s"
                    % (i + 1, s[:80]))


def opener_macro(opener_line):
    s = opener_line.strip()
    m = re.match(r'#\s*ifdef\s+([A-Za-z_][\w]*)', s)
    if m:
        return m.group(1)
    m = re.match(r'#\s*ifndef\s+([A-Za-z_][\w]*)', s)
    if m:
        return m.group(1)
    m = re.match(r'#\s*if\b(.*)$', s)
    if m:
        e = m.group(1).strip()
        for pat in (r'^defined\s*\(\s*([A-Za-z_][\w]*)\s*\)$',
                    r'^!defined\s*\(\s*([A-Za-z_][\w]*)\s*\)$',
                    r'^!?([A-Za-z_][\w]*)$'):
            mm = re.match(pat, e)
            if mm:
                return mm.group(1)
    return None


def region_is_stateful(lines, opener, closer):
    """A region that #defines the macro it tests (layout section 5,
    AST_VARIANTS_DEFINED): wrapping re-tests against header state, so the
    header owns the body instead."""
    macro = opener_macro(lines[opener])
    if not macro:
        return False
    return any(re.match(r'#\s*define\s+%s\b' % re.escape(macro),
                        lines[i].strip())
               for i in range(opener + 1, closer))


# destaticize helpers: kept for the coverage normalizer below, which must
# accept both spellings of a definition line when it compares TU bytes
# against shard bytes. The writer itself is verbatim-only (E1): shard
# bodies keep the TU's external linkage untouched.


def destatic_defline(line):
    if line.startswith('static inline '):
        return line[len('static inline '):]
    if line.startswith('static '):
        return line[len('static '):]
    m = re.match(r'^(__attribute__\(\(.*?\)\)\s+)static inline\s+', line)
    if m:
        return m.group(1) + line[m.end():]
    m = re.match(r'^(__attribute__\(\(.*?\)\)\s+)static\s+', line)
    if m:
        return m.group(1) + line[m.end():]
    return line


def destatic_protoline(line):
    if line.startswith('static '):
        return line[len('static '):]
    m = re.match(r'^(__attribute__\(\(.*?\)\)\s+)static\s+', line)
    if m:
        return m.group(1) + line[m.end():]
    return line


def greedy_balance(bodies, indices, n):
    """R7: deal in TU order, greedily balanced by body-line count."""
    def blen(si):
        st, en, _name = bodies[si]
        return en - st + 1
    total = sum(blen(si) for si in indices)
    target = total / n if n else 0
    groups, cur, acc = [], [], 0.0
    for si in indices:
        cur.append(si)
        acc += blen(si)
        if len(groups) < n - 1 and acc >= target:
            groups.append(cur)
            cur, acc = [], 0.0
    groups.append(cur)
    while len(groups) < n:
        groups.append([])
    return groups


def check_cat_identical(lines, header, bodies, gaps, tail):
    """R10a: verbatim slices in TU order reproduce the TU byte-for-byte."""
    seq = list(header)
    for si, (_st, _en, _name) in enumerate(bodies):
        st, en, _name = bodies[si]
        seq.extend(gaps[si])
        seq.extend(lines[st:en + 1])
    seq.extend(tail)
    return seq == lines


def split_tu(tu_path, header_path, n_shards):
    """Partition per R1-R7. Returns a dict with shard files content,
    the TSV rows, and the verification evidence. The E1 header is
    required: without it the TU's declarations have nowhere to live,
    so there is no split to verify (callers fall back to unity)."""
    _raw, lines, _nl = read_tu(tu_path)
    header_part, bodies, gaps, tail = parse_tu(lines)
    assert_no_toplevel_else(lines, bodies)

    for i, l in enumerate(lines):
        if re.match(r'^#\s*(if|ifdef|ifndef).*ORBIT_WITH_DB', l):
            raise ValueError(
                "TU line %d tests ORBIT_WITH_DB: DB programs stay on the "
                "unity build (R8)" % (i + 1))

    pairs = cond_pairs(lines)
    if not header_path:
        raise ValueError(
            "no E1 header: split %s needs the compiler-emitted %s "
            "(build the TU with the current compiler so <base>.h exists; "
            "without it there is no shard verification to run)"
            % (tu_path, "<base>.h"))
    with open(header_path, "r", encoding="utf-8", errors="replace",
               newline="") as fh:
        header_text = fh.read()
    if "ORBIT_SHARD_COMMON_H" not in header_text:
        raise ValueError(
            "%s does not carry ORBIT_SHARD_COMMON_H: not the "
            "compiler-emitted shard header" % header_path)

    if not check_cat_identical(lines, header_part, bodies, gaps, tail):
        raise ValueError("R10a failed: verbatim slices do not reproduce "
                         "the TU (parser bug, not a sharding decision)")

    opens_map, stateful, wrapped = {}, set(), {}
    for si, (st, en, name) in enumerate(bodies):
        opens = sorted(o for o, c in pairs.items() if o < st and c > en)
        opens_map[si] = opens
        if not opens:
            continue
        if any(region_is_stateful(lines, o, pairs[o]) for o in opens):
            stateful.add(si)
        else:
            wrapped[si] = opens

    inline_dropped = {si for si, (st, _en, _name) in enumerate(bodies)
                      if lines[st].startswith('static inline ')}
    header_dropped = set(inline_dropped)
    for si in stateful:
        opener_text = lines[opens_map[si][0]]
        if opener_text not in header_text:
            raise ValueError(
                "body %s (TU line %d) lives in a stateful region owned "
                "by the header, but the header does not carry %r; "
                "the layout moved under this driver"
                % (bodies[si][2], bodies[si][0] + 1, opener_text[:80]))
        header_dropped.add(si)
    for si in inline_dropped:
        if bodies[si][2] not in header_text:
            raise ValueError(
                "R3 body %s (TU line %d) is not declared in %s; "
                "the layout moved under this driver"
                % (bodies[si][2], bodies[si][0] + 1, header_path))

    helpers = [si for si, (_st, _en, name) in enumerate(bodies)
               if name in PREAMBLE_HELPERS and si not in header_dropped]
    helper_set = set(helpers)
    helpers.sort(key=lambda si: PREAMBLE_HELPERS.index(bodies[si][2]))
    assignable = [si for si in range(len(bodies))
                  if si not in header_dropped and si not in helper_set]
    groups = greedy_balance(bodies, assignable, n_shards)

    # R10b: every non-dropped body lands in exactly one shard.
    seen = [si for g in groups for si in g] + helpers
    missing = sorted(set(assignable) - set(seen))
    dup = sorted(si for si in set(seen)
                 if seen.count(si) > 1 or si in header_dropped)
    if missing or dup:
        raise ValueError("R10b failed: missing=%s duplicate=%s"
                         % (missing, dup))

    return {
        "lines": lines, "header_part": header_part,
        "bodies": bodies, "gaps": gaps, "tail": tail,
        "pairs": pairs, "opens_map": opens_map, "wrapped": wrapped,
        "header_dropped": header_dropped, "helpers": helpers,
        "groups": groups, "header_text": header_text,
    }


def body_text(part, si):
    lines, bodies, pairs = part["lines"], part["bodies"], part["pairs"]
    st, en, _name = bodies[si]
    pre = [lines[o] for o in sorted(part["wrapped"].get(si, []))]
    closers = sorted((pairs[o] for o in part["wrapped"].get(si, [])),
                     reverse=True)
    post = [lines[c] for c in closers]
    return pre + lines[st:en + 1] + post


def write_shards(part, base, shards_dir, newline, header_path=None):
    os.makedirs(shards_dir, exist_ok=True)
    n = len(part["groups"])
    paths = []

    for k in range(n):
        banner = ("/* Shard %d/%d of %s.c: driver-split per "
                  "docs/shard_layout.md R1-R7. */\n"
                  % (k, n, base))
        chunks = ['#include "%s.h"' % base]
        if k == 0:
            # R5 prologue, in order.
            chunks.append('#include "thread_pool.c"')
            chunks.append('OrbitArena* arena = NULL;')
            chunks.append('#ifdef _WIN32')
            chunks.append('void __main(void) {}')
            chunks.append('#endif')
            for si in part["helpers"]:
                chunks.extend(body_text(part, si))
        for si in part["groups"][k]:
            chunks.extend(body_text(part, si))
        if k == n - 1 and part["tail"]:
            # R6: the tail goes to the last shard.
            chunks.extend(part["tail"])
        text = banner + "\n".join(c for c in chunks if c.strip()) + "\n"
        path = os.path.join(shards_dir, "%s.shard%d.c" % (base, k))
        with open(path, "w", encoding="utf-8", newline=newline) as fh:
            fh.write(text)
        paths.append(path)

    if header_path:
        # The bundle carries its own header copy, so a verifier holding
        # only --shards-dir can re-run R10a/b against the TU. Shard
        # compilation itself keeps resolving the header from the TU dir.
        dst = os.path.join(shards_dir, base + ".h")
        if os.path.abspath(header_path) != os.path.abspath(dst):
            shutil.copyfile(header_path, dst)

    rows = ["shard\tfunc\tdefstart_line\tend_line"]
    order = []
    for k in range(n):
        order.extend([(k, si) for si in ([*part["helpers"]] if k == 0 else [])
                      + part["groups"][k]])
    for si in sorted(part["header_dropped"]):
        order.append(("header", si))
    order.sort(key=lambda t: part["bodies"][t[1]][0])
    for tag, si in order:
        st, en, name = part["bodies"][si]
        rows.append("%s\t%s\t%d\t%d" % (tag, name, st + 1, en + 1))
    tsv = os.path.join(shards_dir, "%s.shards.tsv" % base)
    with open(tsv, "w", encoding="utf-8", newline=newline) as fh:
        fh.write("\n".join(rows) + "\n")
    return paths, tsv


def verify_shard_coverage(part, shards_dir, base):
    """R10b: every shard line traces to a TU line or a documented
    prologue/wrap line; every assigned TU body line is present. Gaps and
    the header part live in the compiler-emitted header, R3/stateful
    bodies live there too; shards carry assigned bodies plus the tail
    (R6).
    """
    owned = set(part["header_dropped"])
    tu_sel = []
    for st, en, _name in (b for si, b in enumerate(part["bodies"])
                          if si not in owned):
        tu_sel.extend(part["lines"][st:en + 1])
    tu_sel.extend(part["tail"])
    tu_lines = [l for l in tu_sel if l.strip()]
    have = []
    for k in range(len(part["groups"])):
        with open(os.path.join(shards_dir, "%s.shard%d.c" % (base, k)),
                  encoding="utf-8", newline="") as fh:
            have.extend(l for l in fh.read().split("\n") if l.strip())
    def norm(line):
        if line and line[0] not in ' \t':
            if is_def(line):
                return destatic_defline(line)
            if line.rstrip().endswith(');') and not line.startswith('#'):
                return destatic_protoline(line)
            if line == 'extern OrbitArena* arena;':
                return 'OrbitArena* arena = NULL;'
            if line == 'void __main(void);':
                return 'void __main(void) {}'
        return line

    from collections import Counter
    want = Counter(norm(l) for l in tu_lines)
    got = Counter(norm(l) for l in have)
    missing = list((want - got).elements())
    extra = list((got - want).elements())
    wrap_lines = []
    for si, opens in part["wrapped"].items():
        for o in opens:
            wrap_lines.append(norm(part["lines"][o]))
            wrap_lines.append(norm(part["lines"][part["pairs"][o]]))
    from collections import Counter as _C
    residual = list((_C(extra) - _C(wrap_lines)).elements())
    # Shard prologues (R5/R8): includes, banners, arena/__main lines.
    prologue_ok = re.compile(
        r'^(#include |/\*|OrbitArena\* arena = NULL;|void __main|'
        r'#ifdef _WIN32|#endif|extern OrbitArena\* arena;|void __main\(void\);)')
    residual = [l for l in residual if not prologue_ok.match(norm(l))]
    return missing, residual


def ensure_lib(cc, work, lib_override):
    if lib_override:
        if not os.path.isfile(lib_override):
            raise ValueError("--lib %s does not exist" % lib_override)
        return os.path.abspath(lib_override)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import mklib_runtime
    from pathlib import Path
    mk = Path(work) / "mk"
    mk.mkdir(parents=True, exist_ok=True)
    out_path = Path(work) / "libruntime_net.a"
    # This archive links the fixed-point compiler, which spawns its own C
    # compiler. Under -DORBIT_SEPARATE_COMPILATION the exec implementation
    # lives here, not in the compiler's TU, so this define is what decides
    # whether a shard-built compiler can build programs at all. Without it
    # the compiler reports success without producing a binary -- ERRORS-1's
    # symptom, re-entered through the shard lane.
    rc = mklib_runtime.build_lib(cc, out_path, mk, defines=("ORBIT_WITH_EXEC",))
    if rc != 0:
        raise ValueError("mklib_runtime did not build (rc=%d)" % rc)
    return str(out_path)


def ensure_lib_cached(cc, lib_dir, lib_override):
    """ensure_lib, but reused across calls sharing lib_dir.

    The library TU costs ~5s (-O2); a bootstrap run compiles up to three
    big TUs, so rebuilding it per TU would eat the shard gain. The bytes
    depend only on runtime/ + cc, neither of which moves mid-run: when
    lib_dir already holds the archive, it is reused as-is.
    """
    if lib_override:
        return ensure_lib(cc, lib_dir, lib_override)
    cand = os.path.join(lib_dir, "libruntime_net.a")
    if os.path.isfile(cand):
        return os.path.abspath(cand)
    return ensure_lib(cc, lib_dir, None)


def shard_enabled():
    """Whether bootstrap callers may try sharded TU compiles.

    On unless ORBIT_SHARD_BUILD is 0/false/no (the unity build). The
    sharded compile of the 5.9 MB compiler unit takes 5-8 s of compile wall
    on 8 cores against 18-20 s for the unity -O1 build. Any shard failure
    falls back to unity (slow, never a false green).
    """
    return os.environ.get("ORBIT_SHARD_BUILD", "").strip().lower() not in (
        "0", "false", "no")


def shard_jobs(default=8):
    """Parallel shard compiles (ORBIT_SHARD_JOBS overrides)."""
    try:
        want = int(os.environ.get("ORBIT_SHARD_JOBS", "").strip() or default)
    except ValueError:
        return default
    return want if want >= 1 else default


def compile_shards(cc, shard_paths, work, inc_dirs, defines, jobs, opt="-O0"):
    obj_dir = os.path.join(work, "obj")
    os.makedirs(obj_dir, exist_ok=True)
    flags = [opt, "-DORBIT_WITH_EXEC", "-DORBIT_SEPARATE_COMPILATION",
             "-g0", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables"]
    for d in defines:
        flags.append("-D" + d)
    for inc in inc_dirs:
        flags += ["-I", inc]

    def one(src):
        obj = os.path.join(obj_dir,
                           os.path.basename(src) + ".o")
        argv = [cc] + flags + ["-c", "-o", obj, src]
        t0 = time.monotonic()
        proc = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True,
                              errors="replace")
        return src, obj, time.monotonic() - t0, proc

    t0 = time.monotonic()
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(one, s): s for s in shard_paths}
        for fut in concurrent.futures.as_completed(futs):
            results.append(fut.result())
    wall = time.monotonic() - t0
    ok, worst = True, 0.0
    for src, _obj, dt, proc in sorted(results):
        worst = max(worst, dt)
        if proc.returncode != 0:
            ok = False
            tag = os.path.basename(src)
            out.fail("shard %s did not compile (rc=%d, %.1fs)"
                     % (tag, proc.returncode, dt))
            tail = ((proc.stdout or "") + (proc.stderr or "")).strip()
            print("\n".join(tail.splitlines()[-25:]))
    return results, wall, worst, ok


def shard_build(cc, tu_path, header_path, out_exe, work, tag="tu",
                jobs=8, n_shards=None, runtime_dir=None, defines=(),
                lib_dir=None, log=None, opt="-O0"):
    """Compile one compiler-emitted TU via shards; raise on any failure.

    Split (R1-R7, R10a/b enforced) + parallel gcc -c (R8) + link against
    libruntime_net.a into out_exe. Raises ValueError/RuntimeError with
    the cause; callers catch it and fall back to the unity compile, so a
    shard failure costs time, never correctness. work holds shards_<tag>/
    plus objects; lib_dir (when given) holds the shared libruntime_net.a
    across calls, else work does. Returns a dict with split/wall/link
    times. No emission check here: the caller's own convergence hashes
    are the verdict (a bad shard binary diverges loudly, never green).
    """
    say = log or (lambda _m: None)
    n = n_shards or N_SHARDS
    rdir = runtime_dir or DEFAULT_RUNTIME
    tu_abs = os.path.abspath(tu_path)
    tu_dir, tu_file = os.path.split(tu_abs)
    base = tu_file[:-2] if tu_file.endswith(".c") else tu_file
    t0 = time.monotonic()
    part = split_tu(tu_abs, header_path, n)
    shards_dir = os.path.join(os.path.abspath(work), "shards_" + tag)
    _raw, _lines, newline = read_tu(tu_abs)
    try:
        shard_paths, _tsv = write_shards(part, base, shards_dir, newline,
                                         os.path.abspath(header_path))
    except OSError as exc:
        raise RuntimeError("cannot write shards: %s" % exc)
    missing, residual = verify_shard_coverage(part, shards_dir, base)
    if missing or residual:
        raise RuntimeError(
            "R10b coverage failed (missing=%d extra=%d)"
            % (len(missing), len(residual)))
    t_split = time.monotonic() - t0
    lib = ensure_lib_cached(cc.split()[0], os.path.abspath(lib_dir or work),
                            None)
    results, wall, worst, ok = compile_shards(
        cc.split()[0], shard_paths, shards_dir, [rdir, tu_dir],
        list(defines), jobs, opt)
    if not ok:
        bad = sorted(os.path.basename(s) for s, _o, _d, p in results
                     if p.returncode != 0)
        raise RuntimeError("shard compile failed: %s" % ", ".join(bad))
    t1 = time.monotonic()
    link_argv = [cc.split()[0], "-s", "-o", os.path.abspath(out_exe)] \
        + [obj for _src, obj, _dt, _p in sorted(results)] \
        + [lib] + (["-lws2_32", "-Wl,--stack,16777216"] if os.name == "nt" else [])
    proc = subprocess.run(link_argv, cwd=ROOT, capture_output=True,
                          text=True, errors="replace")
    t_link = time.monotonic() - t1
    if proc.returncode != 0:
        tail = ((proc.stdout or "") + (proc.stderr or "")).strip()
        raise RuntimeError("shard link failed (rc=%d): %s"
                           % (proc.returncode,
                              "\n".join(tail.splitlines()[-5:])))
    say("shard build %s: split %.1fs + compile wall %.1fs "
        "(slowest %.1fs) + link %.1fs -> %s"
        % (tag, t_split, wall, worst, t_link, out_exe))
    return {"split": t_split, "wall": wall, "worst": worst, "link": t_link}


def emit_with(compiler, work, cc, tag):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import build_selfhost
    tmp = os.path.join(work, "emit_" + tag)
    os.makedirs(tmp, exist_ok=True)
    snap = os.path.join(work, "emit_%s.c" % tag)
    build_selfhost.orb_build(os.path.abspath(compiler),
                             "emit_%s.exe" % tag, tmp, cc, snap)
    return snap


def run_self_test(cc):
    checks, passed = [], 0

    def check(name, cond, detail=""):
        nonlocal passed
        checks.append((name, bool(cond), detail))
        if cond:
            passed += 1
            print("  ok    %s" % name)
        else:
            print("  WRONG %s %s" % (name, detail[:200]))

    work = tempfile.mkdtemp(prefix="shard_selfhost_selftest_")
    try:
        tu = os.path.join(work, "synth.c")
        synth = [
            '#define ORBIT_CUSTOM_ROUTER',
            '#include "socket_compat.h"',
            '#include "runtime.h"',
            '',
            'static inline int synth_helper(int x) {',
            '    return x + 1;',
            '}',
            '',
            'static int synth_color(void) {',
            '    return 1;',
            '}',
            '',
            'OrbitArena* arena = NULL;',
            'int synth_first(int a);',
            '',
            'int synth_first(int a) {',
            '    goto done;',
            'done:;',
            '    return synth_helper(a);',
            '}',
            '',
            '#ifdef ORBIT_WITH_NET',
            'int synth_net(int q) {',
            '    return q * 2;',
            '}',
            '#endif',
            '',
            'int main(int argc, char* argv[]) {',
            '    (void)argc; (void)argv;',
            '    orbit_string out = orbit_os_exec_selfhost("echo exec-ok");',
            '    return orbit_string_indexOf(out, "exec-ok") >= 0 ? 0 : 3;',
            '}',
        ]
        with open(tu, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(synth) + "\n")
        hdr = os.path.join(work, "synth.h")
        with open(hdr, "w", encoding="utf-8", newline="\n") as fh:
            fh.write('#ifndef SYNTH_H\n#define SYNTH_H\n'
                     '#define ORBIT_SHARD_COMMON_H\n'
                     '#include "runtime.h"\n'
                     'static inline int synth_helper(int x) {\n'
                     '    return x + 1;\n'
                     '}\n'
                     'int synth_first(int a);\n#endif\n')

        # 1. E1 partition of the synthetic TU.
        part = split_tu(tu, hdr, 2)
        check("e1 split parses 5 bodies",
              len(part["bodies"]) == 5,
              "got %d" % len(part["bodies"]))
        sd = os.path.join(work, "sh")
        _nl = "\n"
        paths, _tsv = write_shards(part, "synth", sd, _nl, hdr)
        missing, residual = verify_shard_coverage(part, sd, "synth")
        check("e1 coverage missing=0 extra=0",
              not missing and not residual,
              "missing=%s residual=%s" % (missing[:3], residual[:3]))

        # 2. Without the header there is no split (E1 is the only mode).
        try:
            split_tu(tu, None, 2)
            check("missing header is refused", False, "accepted")
        except ValueError as exc:
            check("missing header is refused",
                  "E1 header" in str(exc), str(exc)[:200])

        # 3. The R4 precondition can fire (top-level #else names its line).
        bad = os.path.join(work, "bad.c")
        with open(bad, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("int f(void) {\n    return 1;\n}\n"
                     "#ifdef X\nint g(void);\n#else\nint h(void);\n#endif\n"
                     "int f2(void) {\n    return 2;\n}\n")
        try:
            split_tu(bad, hdr, 2)
            check("top-level #else is refused", False, "accepted")
        except ValueError as exc:
            check("top-level #else is refused",
                  "R4" in str(exc), str(exc)[:200])

        # 4. A shard that does not compile is reported (the gcc path can
        # fail, not just succeed).
        broken = os.path.join(work, "broken.c")
        with open(broken, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("int main(void) { return this is not c; }\n")
        proc = subprocess.run([cc, "-O0", "-c", "-o",
                               os.path.join(work, "broken.o"), broken],
                              capture_output=True, text=True)
        check("gcc rejects bad C (rc!=0)", proc.returncode != 0,
              "rc=%d" % proc.returncode)

        # 5. The synthetic E1 shards compile with the real flags (the
        # header travels from the TU dir, as in a real sharded build).
        inc = [DEFAULT_RUNTIME, work]
        res, _wall, _worst, ok = compile_shards(
            cc, paths, os.path.join(work, "b"), inc, [], 2)
        check("synthetic shards compile -c", ok,
              "; ".join(os.path.basename(s) for s, _o, _d, p in res
                        if p.returncode != 0))

        # 6. A shard-linked binary can exec, and the echoed token proves the
        # real implementation ran: the stub returns "", so the token cannot
        # come back. The archive link happens through ensure_lib_cached, so
        # this is the one check that guards ORBIT_WITH_EXEC in the bootstrap
        # archive -- without it the fixed-point compiler it links reports
        # success without producing a binary (ERRORS-1's symptom, re-entered
        # through this lane).
        exe = os.path.join(work, "synth_exe.exe"
                           if os.name == "nt" else "synth_exe")
        try:
            shard_build(cc, tu, hdr, exe, work, tag="selftest", jobs=2)
            proc = subprocess.run([exe], capture_output=True, text=True)
            check("shard-linked binary can exec", proc.returncode == 0,
                  "rc=%d stdout=%r stderr=%r"
                  % (proc.returncode, proc.stdout[:60], proc.stderr[:60]))
        except (ValueError, RuntimeError, OSError) as exc:
            check("shard-linked binary can exec", False, str(exc)[:200])
    finally:
        shutil.rmtree(work, ignore_errors=True)

    out.finish("shard-selfhost self-test", passed, len(checks))
    return 0 if passed == len(checks) else 1


def main():
    ap = argparse.ArgumentParser(description="sharded build driver (E2)")
    ap.add_argument("--tu", default=DEFAULT_TU,
                    help="single-TU C file to shard")
    ap.add_argument("--header", default=None,
                    help="compiler-emitted <base>.h (required); default: "
                         "<tu-dir>/<base>.h when it exists")
    ap.add_argument("--emit-with", default=None, metavar="COMPILER",
                    help="emit the TU (and its E1 header) with this "
                         "compiler before splitting; --tu/--header are "
                         "then ignored")
    ap.add_argument("--fresh", action="store_true",
                    help="clear --shards-dir before writing, so the bundle "
                         "holds only this run's shards")
    ap.add_argument("--name", default=None, metavar="BASE",
                    help="name for the shard files, TSV and header copy "
                         "(default: the TU's basename). Pin it when one bundle "
                         "is written from differently named TUs, so a verifier "
                         "can keep pointing at one manifest")
    ap.add_argument("--shards-dir", default=None,
                    help="where shards + TSV go (default: own temp dir)")
    ap.add_argument("--cc", default=None)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--shards", type=int, default=N_SHARDS)
    ap.add_argument("--out", default=None, help="linked binary path")
    ap.add_argument("--lib", default=None,
                    help="prebuilt libruntime_net.a (default: build it "
                         "into the run's own temp dir)")
    ap.add_argument("--define", action="append", default=[],
                    help="extra -D for shards (repeatable; R9: shards "
                         "inherit the TU flag set)")
    ap.add_argument("--runtime-dir", default=DEFAULT_RUNTIME)
    ap.add_argument("--reference", default=None,
                    help="reference fp binary for the R10c emission check")
    ap.add_argument("--expect-sha", default=None,
                    help="expected emission SHA256 instead of --reference")
    ap.add_argument("--verify", action="store_true",
                    help="run the R10c auto-emission SHA check")
    ap.add_argument("--no-build", action="store_true",
                    help="split only: no gcc, no link, no emission check")
    ap.add_argument("--keep", action="store_true",
                    help="keep the run's temp dir")
    ap.add_argument("--self-test", action="store_true")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    if args.self_test:
        cc = args.cc or os.environ.get("ORBIT_CC") or "gcc"
        return run_self_test(cc)

    cc = args.cc or os.environ.get("ORBIT_CC") or "gcc"
    if not shutil.which(cc.split()[0]):
        return fail("no C compiler %r on PATH" % cc, 5)
    if args.jobs is None or args.jobs < 1:
        return fail("--jobs must be >= 1", 5)
    if args.shards is None or args.shards < 1:
        return fail("--shards must be >= 1", 5)

    work = tempfile.mkdtemp(prefix="shard_selfhost_")
    if not args.keep:
        import atexit
        atexit.register(lambda: shutil.rmtree(work, ignore_errors=True))
    for var in ("TEMP", "TMP", "TMPDIR"):
        os.environ[var] = work

    if args.emit_with:
        comp = os.path.abspath(args.emit_with)
        if not os.path.isfile(comp):
            return fail("--emit-with %s does not exist" % args.emit_with, 5)
        out.say("emitting the TU with %s ..." % args.emit_with)
        try:
            args.tu = emit_with(comp, work, cc, "verify")
        except SystemExit as exc:
            return fail("--emit-with %s did not emit (rc=%s)"
                        % (args.emit_with, exc), 4)
        args.header = None
        out.say("emitted: %s (%d bytes)"
                % (os.path.basename(args.tu), os.path.getsize(args.tu)))

    if not os.path.isfile(args.tu):
        return fail("--tu %s does not exist" % args.tu, 5)
    tu_abs = os.path.abspath(args.tu)
    tu_dir, tu_file = os.path.split(tu_abs)
    base = tu_file[:-2] if tu_file.endswith(".c") else tu_file
    if args.name:
        base = args.name
    header = args.header
    if header is None:
        cand = os.path.join(tu_dir, base + ".h")
        header = cand if os.path.isfile(cand) else None
    if header is None:
        return fail("no E1 header for %s: shard builds need the "
                    "compiler-emitted %s (build the TU with the current "
                    "compiler so it exists), else use the unity build" % (tu_abs, base + ".h"), 5)
    out.say("shard-selfhost (E1): %s -> %d shards (jobs=%d, cc=%s)"
            % (tu_abs, args.shards, args.jobs, cc))

    t0 = time.monotonic()
    try:
        part = split_tu(tu_abs, header, args.shards)
    except ValueError as exc:
        return fail(str(exc), 1)
    shards_dir = os.path.abspath(args.shards_dir) if args.shards_dir \
        else os.path.join(work, "shards")
    if args.fresh:
        shutil.rmtree(shards_dir, ignore_errors=True)
    _raw, _lines, newline = read_tu(tu_abs)
    try:
        shard_paths, tsv = write_shards(part, base, shards_dir, newline,
                                        header)
    except OSError as exc:
        return fail("cannot write shards: %s" % exc, 5)
    missing, residual = verify_shard_coverage(part, shards_dir, base)
    if missing or residual:
        detail = "missing=%d extra=%d" % (len(missing), len(residual))
        for line in (missing[:5] + residual[:5]):
            print("  NOT-COVERED: %s" % line[:120])
        return fail("R10b coverage failed (%s)" % detail, 1)
    t_split = time.monotonic() - t0
    dropped = sorted(part["header_dropped"])
    out.say("split %.1fs: %d bodies (%d header-owned), %s, "
            "R10a CAT IDENTICAL, R10b missing=0 extra=0"
            % (t_split, len(part["bodies"]), len(dropped), tsv))
    # Hash binding for reuse, written only for a split that passed R10a/b: the
    # header is the one artifact only a compiler can make, so record which C
    # bytes it came with. A consumer (dev.py's T3) reuses this header and skips
    # the emission only when the TU's hash still matches the canonical's AND
    # the header still hashes to this record. The split itself is re-run and
    # re-checked downstream either way.
    bind = os.path.join(shards_dir, base + ".header.json")
    with open(bind, "w", encoding="utf-8") as fh:
        json.dump({"tu_sha256": sha_file(tu_abs),
                   "header_sha256": sha_file(header)}, fh, indent=1)
        fh.write("\n")

    if args.no_build:
        out.finish("shard-selfhost", 2, 2,
                   extra="split-only E1 (%d shards)" % args.shards)
        return 0

    try:
        lib = ensure_lib(cc.split()[0], work, args.lib)
    except ValueError as exc:
        return fail(str(exc), 5)
    inc_dirs = [args.runtime_dir, tu_dir]
    results, wall, worst, ok = compile_shards(
        cc.split()[0], shard_paths, work, inc_dirs, args.define, args.jobs)
    out.say("shard compile: wall %.1fs, slowest TU %.1fs, all-ok=%s"
            % (wall, worst, ok))
    if not ok:
        return fail("a shard did not compile (see shard name(s) above)", 2)

    out_bin = os.path.abspath(args.out) if args.out else os.path.join(
        shards_dir, base + ".linked" + (".exe" if os.name == "nt" else ""))
    os.makedirs(os.path.dirname(out_bin) or ".", exist_ok=True)
    t1 = time.monotonic()
    link_argv = [cc.split()[0], "-s", "-o", out_bin] \
        + [obj for _src, obj, _dt, _p in sorted(results)] \
        + [lib] + (["-lws2_32", "-Wl,--stack,16777216"] if os.name == "nt" else [])
    proc = subprocess.run(link_argv, cwd=ROOT, capture_output=True,
                          text=True, errors="replace")
    t_link = time.monotonic() - t1
    if proc.returncode != 0:
        tail = ((proc.stdout or "") + (proc.stderr or "")).strip()
        print("\n".join(tail.splitlines()[-25:]))
        return fail("link failed (rc=%d)" % proc.returncode, 3)
    out.say("link %.1fs -> %s" % (t_link, out_bin))

    if not args.verify:
        out.finish("shard-selfhost", 3, 3,
                   extra="split+compile+link E1, no emission check "
                         "(--verify off)")
        return 0
    if args.reference is None and args.expect_sha is None:
        return fail("--verify needs --reference or --expect-sha", 5)
    t2 = time.monotonic()
    try:
        got_c = emit_with(out_bin, work, cc.split()[0], "shard")
    except SystemExit as exc:
        return fail("the linked binary did not emit (rc=%s)" % exc, 4)
    got_sha = sha_file(got_c)
    if args.reference is not None:
        if not os.path.isfile(args.reference):
            return fail("--reference %s does not exist" % args.reference, 5)
        try:
            ref_c = emit_with(args.reference, work, cc.split()[0], "ref")
        except SystemExit as exc:
            return fail("the reference binary did not emit (rc=%s)" % exc,
                        4)
        want_sha = sha_file(ref_c)
    else:
        want_sha = args.expect_sha.lower()
    t_emit = time.monotonic() - t2
    match = got_sha.lower() == want_sha.lower()
    out.say("emission check %.1fs: shardlinked=%s reference=%s"
            % (t_emit, got_sha[:16], want_sha[:16]))
    if not match:
        return fail("R10c emission SHA differs (linked=%s reference=%s)"
                    % (got_sha, want_sha), 4)
    out.finish("shard-selfhost", 4, 4,
               extra="E1 split+%d shards+link+emission MATCH %s"
                     % (args.shards, got_sha[:12]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
