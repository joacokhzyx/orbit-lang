#!/usr/bin/env python3
"""Content-addressed cache for the bootstrap's C compilations.

The self-host gates recompile the same multi-megabyte C translation unit over
and over. Measured on a 2-core runner with gcc 13.3, compiling the 3.9 MB
canonical unit costs 23.8 s with `-Wall` and 3.7 s with `-w`, and
`verify_seed.py` performs 7 such compilations per run while the stress gate runs
it 8 times in a row: 61 compilations of essentially the same input.

A cache keyed on the exact inputs makes the repeat cost a file copy. The key
covers everything that can change the output:

    cc identity (command + --version)  |  every flag except -o and its value
    |  every input file's content SHA-256  |  the destination basename
    |  every file an include flag can reach: the trees named by
       -I/-isystem/-iquote/-idirafter and the files named by -include/-imacros

The include trees were the key's one hole. Emitted C is compiled with
`-I <runtime dir>` and `#include`s the runtime headers, and the seed unit is
compiled with the runtime directory on the same path, so a key that hashed only
`sources` returned the artifact built against the PREVIOUS header the first time
a header changed: an invisibly stale binary, the one failure mode a build cache
must not have. An include tree that does not fit the walk bounds is refused
rather than skipped, which makes that invocation uncacheable: a missed cache
costs one compile, a wrong key ships a wrong artifact.

Two details matter for honesty here:

- the destination BASENAME is in the key, not the destination directory. The
  linkers embed the output name (as a PDB path on PE targets) and the
  compilers embed the source path, so two builds that differ only by output
  name are genuinely different artifacts. Keying on the directory instead
  would make every run a miss, because the gates use a fresh temporary work
  directory per invocation.
- a hit is a real hit: same compiler, same version, same flags, same bytes
  in. Nothing is keyed on mtime or on anything a stale cache could fake.

What a cache hit does NOT do is turn a determinism check into a tautology.
`verify_seed.py` compares the emitted C of every stage against the canonical C;
that check reads files the compiler wrote and is unaffected. The binary
fixed-point comparison is documented as toolchain-specific and informational
for gcc/clang; callers must report cache hits for it rather than claim a pass
(see `hit_is_reuse`).
"""

import hashlib
import os
import shutil
import subprocess
import sys

_CHUNK = 1 << 20


def cache_root() -> str:
    """Directory holding cached artifacts."""
    override = os.environ.get("ORBIT_CCACHE_DIR", "").strip()
    if override:
        return os.path.abspath(override)
    base = os.environ.get("XDG_CACHE_HOME", "").strip() or os.path.join(
        os.path.expanduser("~"), ".cache")
    return os.path.join(base, "orbit", "cc")


def _probe_name(root: str) -> str:
    """A probe file name no other caller can be holding.

    The pid alone is not enough: threads inside one process call this too, and
    a caller that probes twice is the normal case, so the name carries a nonce
    as well. That is the whole fix -- the probe is a private question and gets
    a private name, instead of a shared `.writable` two callers can fight over.
    """
    return os.path.join(root, ".writable-%d-%s"
                        % (os.getpid(), os.urandom(6).hex()))


def enabled() -> bool:
    """False when ORBIT_CCACHE=0, or when no cache directory is usable.

    The probe file is named after the caller. It used to be one shared
    `.writable`, which is a race as soon as two compilations overlap -- and
    they routinely do, because the suite compiles eight translation units at
    once. One caller then removes the name another is midway through removing,
    or (on Windows) removes it while the other still holds it open: the loser
    sees OSError and reports "no cache" for the rest of its life, so its share
    of the compilations is silently uncached.
    """
    if os.environ.get("ORBIT_CCACHE", "1").strip().lower() in ("0", "false", "no"):
        return False
    try:
        root = cache_root()
        os.makedirs(root, exist_ok=True)
        probe = _probe_name(root)
        with open(probe, "w") as f:
            f.write("")
        try:
            os.remove(probe)
        except OSError:
            # A name this process owns failing to delete cannot make the cache
            # unusable: entries are written under per-pid temp names and moved
            # into place with os.replace, which needs no delete of a shared
            # name. Report what the create actually proved.
            pass
        return True
    except OSError:
        return False


def _cc_identity(cc_cmd) -> str:
    exe = cc_cmd[0]
    try:
        proc = subprocess.run([exe, "--version"], capture_output=True, text=True,
                              errors="replace", timeout=60)
        banner = (proc.stdout or "").strip().splitlines()
        return (exe + "|" + (banner[0] if banner else "unknown")).strip()
    except Exception:
        return exe


def _file_digest(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(_CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


# Flags whose value is a DIRECTORY the translator searches for #include targets.
# The fused spelling (-Iruntime) is legal for these and is the spelling the
# compiler's own cc line uses (pipeline.orb wraps the runtime directory in
# quotes), so both spellings fold to the same directory.
_INCLUDE_DIR_FLAGS = ("-I", "-isystem", "-iquote", "-idirafter")

# Flags whose value is a FILE opened before the translation unit. Their value is
# never fused, so only the separated spelling is recognised: treating
# `-includefoo.h` as one would invent a file name out of `-include-pch`.
_INCLUDE_FILE_FLAGS = ("-include", "-imacros")

# Bounds for walking an include directory. runtime/ and runtime/vendor are 8.5 MB
# and 53 files together, so these are roomy rather than tight; the point is that
# a directory which does not fit REFUSES the key instead of being skipped.
_INCLUDE_WALK_MAX_FILES = 4096
_INCLUDE_WALK_MAX_BYTES = 64 << 20


def _flag_value(argv, i):
    """(flag, value, extra_tokens) for the value-taking flag at argv[i], else None."""
    tok = argv[i]
    for flag in _INCLUDE_DIR_FLAGS:
        if tok == flag:
            return (flag, argv[i + 1], 1) if i + 1 < len(argv) else None
        if tok.startswith(flag) and len(tok) > len(flag):
            return flag, tok[len(flag):], 0
    for flag in _INCLUDE_FILE_FLAGS:
        if tok == flag:
            return (flag, argv[i + 1], 1) if i + 1 < len(argv) else None
    return None


def _unquote(path: str) -> str:
    """Drop one layer of quotes around a path token.

    pipeline.orb writes the runtime directory as -I"<dir>" and that token reaches
    here through a shell, so the quotes are part of the token, not syntax.
    """
    if len(path) >= 2 and path[0] == path[-1] and path[0] in "\"'":
        return path[1:-1]
    return path


def _extra_inputs(argv, cwd):
    """(label, path) for every input an include flag lets the compile read.

    Labels carry the path RELATIVE to the directory that named it, so a header
    moving between two -I directories changes the key even when its bytes do
    not. A directory that is empty or missing still yields its own label: a
    header appearing there later must invalidate the entry. Raises OSError when
    a tree does not fit the walk bounds, which the caller turns into an uncached
    compile.
    """
    out = []
    i = 0
    while i < len(argv):
        got = _flag_value(argv, i)
        if got is None:
            i += 1
            continue
        flag, value, extra = got
        i += 1 + extra
        path = os.path.normpath(os.path.join(cwd, _unquote(value)))
        if flag in _INCLUDE_FILE_FLAGS:
            out.append(("file:" + os.path.basename(path), path))
            continue
        label = os.path.basename(path.rstrip("\\/")) or path
        budget = _INCLUDE_WALK_MAX_BYTES
        count = 0
        for dirpath, dirnames, filenames in os.walk(path):
            dirnames.sort()
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                count += 1
                try:
                    budget -= os.path.getsize(full)
                except OSError:
                    budget -= 0
                if count > _INCLUDE_WALK_MAX_FILES or budget < 0:
                    raise OSError(
                        "include directory %s does not fit the key walk bounds "
                        "(%d files)" % (path, count))
                rel = os.path.relpath(full, path).replace(os.sep, "/")
                out.append(("dir:%s/%s" % (label, rel), full))
        if count == 0:
            out.append(("dir:" + label, None))
    return out


def argv_inputs(argv, cwd=None):
    """The input files the argv itself names: non-flag tokens, minus the target.

    `sources` is the caller's statement of what a compile reads. This is the
    part of that statement the argv carries -- source files and .lib/.a/.res
    link inputs. The destination is excluded by POSITION, not by existence: a
    leftover output from the previous run must never enter the key, or every
    rebuild would key the artifact it is about to replace.

    `cwd` is the directory the compile runs in, and it is not optional in
    spirit: this repository's gates name their sources relative to the root and
    run the compiler from there, so resolving against the caller's own directory
    would drop every source from the key -- a cache that misses is slow, but a
    cache that keys nothing is wrong. Paths come back absolute so the digest
    reads the same file the compiler will.
    """
    base = cwd or os.getcwd()
    target = _out_target(argv)
    target = os.path.abspath(os.path.join(base, target)) if target else None
    inputs = []
    skip = False
    for tok in argv:
        if skip:
            skip = False
            continue
        if tok == "-o":
            skip = True
            continue
        if tok.startswith("-"):
            continue
        full = tok if os.path.isabs(tok) else os.path.join(base, tok)
        if os.path.isfile(full) and os.path.abspath(full) != target:
            inputs.append(full)
    return inputs


def compute_key(cc_cmd, argv, sources, cwd=None) -> str:
    """SHA-256 over every input that can affect the compiled artifact.

    Path arguments are reduced to their BASENAME before hashing. The gates use
    a fresh temporary work directory per invocation, so hashing absolute paths
    would make every run a miss; the basenames are already the contract
    (the compilers embed the source name and the linkers the output name, and
    the gates deliberately keep both constant across stages).

    `cwd` is the directory the compile itself runs in, which is what a relative
    -I path resolves against. It defaults to this process's directory, which is
    right for the callers that do not pass it because they do not pass a cwd to
    the compiler either.
    """
    h = hashlib.sha256()
    h.update(_cc_identity(cc_cmd).encode("utf-8", "replace"))
    h.update(b"\0argv\0")
    for tok in argv:
        if os.path.isabs(tok) or os.sep in tok:
            tok = os.path.basename(tok)
        h.update(tok.encode("utf-8", "replace"))
        h.update(b"\0")
    h.update(b"\0sources\0")
    for src in sorted(sources):
        h.update(os.path.basename(src).encode("utf-8", "replace"))
        h.update(b"\0")
        h.update(_file_digest(src).encode("ascii"))
        h.update(b"\0")
    h.update(b"\0includes\0")
    for label, path in sorted(_extra_inputs(argv, cwd or os.getcwd()),
                              key=lambda item: item[0]):
        h.update(label.encode("utf-8", "replace"))
        h.update(b"\0")
        if path is not None and os.path.isfile(path):
            h.update(_file_digest(path).encode("ascii"))
        else:
            h.update(b"-")
        h.update(b"\0")
    return h.hexdigest()


def _out_target(argv):
    for i, tok in enumerate(argv):
        if tok == "-o" and i + 1 < len(argv):
            return argv[i + 1]
    return None


# --------------------------------------------------------------------------
# Windows binary branding: every .exe linked on Windows carries Orbit's own
# version resource + mark. Fixed metadata, never user input: there is no
# syntax for it, so a .orb file cannot fake the brand.
# --------------------------------------------------------------------------

_ORBIT_COMPANY = "orbit-lang"
_ORBIT_PRODUCT = "Orbit"
_ORBIT_COPYRIGHT = "MIT"


def _orbit_version():
    """The compiler's own version string, read from its source of truth.

    pipeline.orb owns fn orbitVersion; parse it rather than duplicating the
    literal here. None when unparseable: callers skip stamping rather than
    stamping a wrong version.
    """
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        path = os.path.join(os.path.dirname(here), "compiler", "host", "pipeline.orb")
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    import re
    m = re.search(r'fn orbitVersion\(\) -> string \{\s*return "([^"]+)"', text)
    return m.group(1) if m else None


def _version_nums(version):
    """'0.1.0-rc.2' -> '0,1,0,2': leading digits of the first three dot parts,
    trailing digits of the last part. The -rc tail drops out of the numeric
    fields; the full string stays in the text fields."""
    import re
    parts = version.split(".")
    nums = []
    for p in parts[:3]:
        m = re.match(r"\d+", p)
        nums.append(m.group(0) if m else "0")
    last = parts[3] if len(parts) > 3 else (parts[-1] if parts else "")
    m = re.search(r"(\d+)$", last)
    nums.append(m.group(1) if m else "0")
    while len(nums) < 4:
        nums.append("0")
    return ",".join(nums[:4])


def _orbit_rc_text(exe_base, description, version, icon_path):
    nums = _version_nums(version)
    lines = [
        "1 VERSIONINFO",
        "FILEVERSION " + nums,
        "PRODUCTVERSION " + nums,
        "FILEFLAGSMASK 0x3fL",
        "FILEFLAGS 0x0L",
        "FILEOS 0x40004L",
        "FILETYPE 0x1L",
        "FILESUBTYPE 0x0L",
        "BEGIN",
        '    BLOCK "StringFileInfo"',
        "    BEGIN",
        '        BLOCK "040904b0"',
        "        BEGIN",
        '            VALUE "CompanyName", "%s"' % _ORBIT_COMPANY,
        '            VALUE "FileDescription", "%s"' % description,
        '            VALUE "FileVersion", "%s"' % version,
        '            VALUE "InternalName", "%s"' % exe_base,
        '            VALUE "LegalCopyright", "%s"' % _ORBIT_COPYRIGHT,
        '            VALUE "OriginalFilename", "%s"' % exe_base,
        '            VALUE "ProductName", "%s"' % _ORBIT_PRODUCT,
        '            VALUE "ProductVersion", "%s"' % version,
        "        END",
        "    END",
        '    BLOCK "VarFileInfo"',
        "    BEGIN",
        '        VALUE "Translation", 0x409, 1200',
        "    END",
        "END",
    ]
    if icon_path:
        lines.append('IDI_ICON1 ICON "%s"' % icon_path.replace("\\", "/"))
    return "\n".join(lines) + "\n"


def _which_resource_compiler():
    for name in ("windres", "llvm-rc"):
        if shutil.which(name):
            return name
    return None


def windows_stamp(argv, sources, workdir, description, log=None):
    """Append Orbit branding to a cc link: (argv, sources) -> (argv, sources).

    No-op off Windows, when the version is unparseable, or when neither
    windres nor llvm-rc exists (logged; the build proceeds unstamped rather
    than failing for branding alone). The .res joins both argv and sources
    so the content cache keys on it.
    """
    if os.name != "nt":
        return argv, sources
    target = _out_target(argv)
    if target is None:
        return argv, sources
    version = _orbit_version()
    if not version:
        if log:
            log("orbit metadata: cannot parse orbitVersion; shipping unstamped")
        return argv, sources
    rc_tool = _which_resource_compiler()
    if rc_tool is None:
        if log:
            log("orbit metadata: no resource compiler (windres/llvm-rc); shipping unstamped")
        return argv, sources
    exe_base = os.path.basename(target)
    stem = os.path.splitext(exe_base)[0] or "orbit"
    try:
        os.makedirs(workdir, exist_ok=True)
    except OSError:
        return argv, sources
    here = os.path.dirname(os.path.abspath(__file__))
    icon_cand = os.path.join(os.path.dirname(here), "assets", "orbit.ico")
    icon = icon_cand if os.path.isfile(icon_cand) else ""
    rc_path = os.path.join(workdir, stem + ".orbit.rc")
    res_path = os.path.join(workdir, stem + ".orbit.res")
    try:
        with open(rc_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(_orbit_rc_text(exe_base, description, version, icon))
    except OSError:
        return argv, sources
    try:
        if rc_tool == "windres":
            subprocess.run([rc_tool, rc_path, "-O", "coff", "-o", res_path],
                           capture_output=True, timeout=120)
        else:
            subprocess.run([rc_tool, "/FO", res_path, rc_path],
                           capture_output=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        pass
    if not os.path.isfile(res_path):
        if log:
            log("orbit metadata: %s failed; shipping unstamped" % rc_tool)
        return argv, sources
    return argv + [res_path], sources + [res_path]


def _entry(key: str) -> str:
    return os.path.join(cache_root(), key[:2], key)


def _load(key: str):
    """Return (artifact_path, mode) for a completed entry, else (None, None)."""
    entry = _entry(key)
    meta_path = entry + ".meta"
    art_path = entry + ".art"
    if not (os.path.isfile(meta_path) and os.path.isfile(art_path)):
        return None, None
    try:
        with open(meta_path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return None, None
    if not lines or lines[0] != "complete":
        # A torn entry from an interrupted run: never trust it.
        return None, None
    mode = 0o755
    if len(lines) > 1:
        try:
            mode = int(lines[1], 8)
        except ValueError:
            mode = 0o755
    return art_path, mode


def _store(key: str, artifact: str) -> None:
    entry = _entry(key)
    os.makedirs(os.path.dirname(entry), exist_ok=True)
    art_path = entry + ".art"
    tmp_art = art_path + ".tmp%d" % os.getpid()
    shutil.copyfile(artifact, tmp_art)
    os.replace(tmp_art, art_path)
    try:
        mode = os.stat(artifact).st_mode & 0o7777
    except OSError:
        mode = 0o755
    # The meta file is written last and carries the completion marker, so a
    # crash mid-store can only ever leave an entry that reads as a miss.
    tmp_meta = entry + ".meta.tmp%d" % os.getpid()
    with open(tmp_meta, "w", encoding="utf-8", newline="\n") as f:
        f.write("complete\n%o\n" % mode)
    os.replace(tmp_meta, entry + ".meta")


def compile_cached(cc_cmd, argv, sources, log=None, cwd=None,
                   capture_output=False):
    """Run `argv` (a full cc invocation ending in -o TARGET), cached by content.

    Returns (target_path, hit). On a hit the cached artifact is copied to the
    requested target; on a miss `argv` runs and its output is stored.

    `cwd` and `capture_output` pass through to the compiler, and `cwd` is also
    what a relative -I path resolves against, so it has to reach the key: a gate
    that compiles from the repository root and one that compiles from a scratch
    directory are not compiling the same trees. A gate that reports a compile
    failure needs the compiler's own diagnostics, which is what `capture_output`
    gives it.
    """
    run = {"cwd": cwd} if cwd is not None else {}
    if capture_output:
        run.update(capture_output=True, text=True, errors="replace")
    target = _out_target(argv)
    if target is None or not enabled():
        subprocess.run(argv, check=True, **run)
        return target, False

    try:
        key = compute_key(cc_cmd, argv, sources, cwd=cwd)
    except OSError as e:
        if log:
            log("cc cache: cannot key %s (%s); compiling directly" % (target, e))
        subprocess.run(argv, check=True, **run)
        return target, False

    art_path, mode = _load(key)
    if art_path is not None:
        try:
            dest_dir = os.path.dirname(os.path.abspath(target))
            if dest_dir:
                os.makedirs(dest_dir, exist_ok=True)
            shutil.copyfile(art_path, target)
            os.chmod(target, mode)
            if log:
                log("cc cache: reused %s" % os.path.basename(target))
            return target, True
        except OSError as e:
            if log:
                log("cc cache: cannot restore %s (%s); recompiling" % (target, e))

    subprocess.run(argv, check=True, **run)
    if os.path.isfile(target):
        try:
            _store(key, target)
        except OSError as e:
            if log:
                log("cc cache: cannot store %s (%s)" % (os.path.basename(target), e))
    return target, False


def _probe_race(rounds=5, workers=16):
    """Call enabled() `workers` times at once, `rounds` times over.

    Returns (reported_usable, calls). The suite compiles eight translation
    units through the same cache directory at the same time, so this is the
    shape enabled() is actually called in; a probe that only works alone is
    the bug this reproduces. Threads rather than processes because the race is
    over a name in the filesystem, which does not care who removes it.
    """
    from concurrent.futures import ThreadPoolExecutor
    usable = 0
    calls = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for _ in range(rounds):
            got = list(pool.map(lambda _i: enabled(), range(workers)))
            usable += sum(1 for g in got if g)
            calls += len(got)
    return usable, calls


def self_test() -> int:
    """Assert the properties the key must have, on scratch files in a temp dir.

    A cache that cannot fail is not a cache, and the way this one fails is
    silent: a key that omitted an input hands back the artifact the *previous*
    input produced, so the build looks green and ships the old binary. Every
    assertion below is a change that MUST move the key, except the two that
    must not -- a control (identical inputs, identical key) and the output
    exclusion -- because a key that always changed would pass the rest.

    Hashes, and one scratch cache directory of the self-test's own. No compiler
    runs and the real cache directory is never touched, so this costs
    milliseconds and can run anywhere.
    """
    import tempfile

    fails = []

    def check(name, ok):
        print(("  ok   " if ok else "  FAIL ") + name)
        if not ok:
            fails.append(name)

    def key(argv, sources, cwd):
        return compute_key([sys.executable], argv, sources, cwd=cwd)

    with tempfile.TemporaryDirectory(prefix="ccache_selftest_") as td:
        root = os.path.join(td, "proj")
        inc = os.path.join(root, "inc")
        os.makedirs(inc)
        header = os.path.join(inc, "probe.h")
        appeared = os.path.join(inc, "appeared.h")
        source = os.path.join(root, "prog.c")
        target = os.path.join(root, "prog.bin")
        forced = os.path.join(root, "forced.h")

        def write(path, text):
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)

        write(header, "#define PROBE 0\n")
        write(source, '#include "probe.h"\nint main(void) { return PROBE; }\n')

        argv = ["-O0", "-I", inc, source, "-o", target]
        k0 = key(argv, [source], root)
        check("identical inputs, identical key",
              k0 == key(argv, [source], root))

        # The defect this self-test exists for. probe.h is not in `sources`;
        # only the -I directory names it.
        write(header, "#define PROBE 1\n")
        check("editing a header under -I moves the key",
              key(argv, [source], root) != k0)
        write(header, "#define PROBE 0\n")
        check("restoring the header restores the key",
              key(argv, [source], root) == k0)

        write(appeared, "#define APPEARED 1\n")
        check("a header appearing under -I moves the key",
              key(argv, [source], root) != k0)
        os.remove(appeared)

        write(source, '#include "probe.h"\nint main(void) { return PROBE + 1; }\n')
        check("editing a source moves the key", key(argv, [source], root) != k0)
        write(source, '#include "probe.h"\nint main(void) { return PROBE; }\n')

        # The two spellings the compiler itself writes: pipeline.orb emits
        # -I"<dir>", and a shell may hand it over fused. The key is over the
        # argv, so the spellings need not agree with each other; what must hold
        # is that the tree behind each one is read.
        for label, variant in (("quoted", ["-O0", '-I"%s"' % inc, source,
                                          "-o", target]),
                               ("fused", ["-O0", "-I" + inc, source,
                                          "-o", target])):
            before = key(variant, [source], root)
            write(header, "#define PROBE 2\n")
            walked = key(variant, [source], root) != before
            write(header, "#define PROBE 0\n")
            check("a %s -I path still walks the tree it names" % label, walked)

        write(forced, "#define FORCED 0\n")
        forced_argv = ["-O0", "-include", forced, "-I", inc, source, "-o", target]
        kf = key(forced_argv, [source], root)
        write(forced, "#define FORCED 1\n")
        check("editing a -include file moves the key",
              key(forced_argv, [source], root) != kf)

        write(target, "leftover from the previous run\n")
        check("a leftover output does not enter the key",
              key(argv, [source], root) == k0)
        check("argv_inputs keeps the source and drops the target and -I value",
              argv_inputs(argv, cwd=root) == [source])
        rel = ["-O0", "-I", "inc", "prog.c", "-o", "prog.bin"]
        check("a relative source resolves against the compile's cwd",
              argv_inputs(rel, cwd=root) == [source])

        # The probe, in the shape it is called in. A caller that cannot see its
        # own cache does not fail; it compiles directly, so a race here costs
        # speed and says nothing.
        saved = os.environ.get("ORBIT_CCACHE_DIR")
        probe_dir = os.path.join(td, "cache")
        os.environ["ORBIT_CCACHE_DIR"] = probe_dir
        try:
            usable, calls = _probe_race()
        finally:
            if saved is None:
                os.environ.pop("ORBIT_CCACHE_DIR", None)
            else:
                os.environ["ORBIT_CCACHE_DIR"] = saved
        check("a usable cache survives %d concurrent probes" % calls,
              usable == calls)
        check("concurrent probes never share a name",
              len({_probe_name(probe_dir) for _ in range(16)}) == 16)

    print("cc cache self-test: %s" % ("FAILED: " + ", ".join(fails) if fails
                                      else "OK"))
    return 1 if fails else 0


def main(argv=None) -> int:
    """`self-test` proves the key's properties; no argument reports state."""
    args = list(sys.argv[1:] if argv is None else argv)
    if args[:1] == ["self-test"]:
        return self_test()
    root = cache_root()
    total, entries = 0, 0
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.endswith(".art"):
                entries += 1
                try:
                    total += os.path.getsize(os.path.join(dirpath, name))
                except OSError:
                    pass
    print("cc cache: %s" % root)
    print("cc cache: %d entries, %.1f MB, enabled=%s" % (entries, total / 1e6, enabled()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
