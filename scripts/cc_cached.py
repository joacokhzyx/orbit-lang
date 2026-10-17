#!/usr/bin/env python3
"""A cc wrapper that puts the INNER compilation through the content cache.

`orbit build` forks a C compiler to turn its emitted C into a binary, and that
inner compile is where a test gate's wall time goes: the same emitted unit is
compiled again on every run, from a fresh temporary directory, with the same
flags. scripts/orbit_ccache.py already turns a repeat compile into a file
copy. What was missing was a place to stand, and this is it.

No compiler change is needed to use it, because the compiler already documents
ORBIT_CC as "a wrapper with arguments": it splices that string into the front
of its own cc line (compiler/host/pipeline.orb) and runs the result through a
shell. So ORBIT_CC="<python> <this file>" hands this file the cc arguments
verbatim; it resolves the real compiler from ORBIT_CC_REAL (then CC, then
gcc/clang/cc) and passes the whole invocation to orbit_ccache.compile_cached.

Transparent and silent by construction. The compiler's stdout and stderr are
inherited, not captured, because `orbit build` reads them to tell a missing
toolchain from a rejected program; the compiler's exit status becomes this
process's exit status; and a cache hit prints nothing. A hit is only ever a
copy of the artifact the real compiler produced for byte-identical inputs.

Fail-open in one direction: with no -o target, no named input, or no usable
cache directory, the invocation runs uncached and the cost of the wrapper is
one interpreter start. It never invents an artifact, never rewrites argv, and
never reports a compile that did not happen.

What the key cannot see: headers reached through the toolchain's own default
search paths. Every -I/-isystem/-iquote/-idirafter tree, -include/-imacros
file, named source and link input is hashed (orbit_ccache says how); the
system headers are not, so a system header changing under a warm cache is a
stale hit this cache cannot detect. In this repository the emitted C is
compiled with the runtime directory on -I and includes only its headers, so
the hole is in the general contract, not in the path that uses it here.
"""

import os
import shutil
import subprocess
import sys

import orbit_ccache

_SHIM_BASENAME = "cc_cached.py"


def _split_command(text):
    """The tokens of a command string, as a shell would hand them over.

    The compiler splices this value into a command line and runs it through a
    shell, so what arrives is a command LINE: a bare name, a path (quoted when
    it has spaces), or a wrapper with arguments ("ccache gcc"). The isfile
    probes come first because a plain whitespace split is wrong for the one
    case that matters most, an installed compiler under "Program Files".
    """
    text = text.strip()
    if os.path.isfile(text):
        return [text]
    bare = text.strip("\"'")
    if os.path.isfile(bare):
        return [bare]
    if '"' in text or "'" in text:
        import shlex
        try:
            return shlex.split(text)
        except ValueError:
            pass
    return [tok.strip("\"'") for tok in text.split() if tok.strip("\"'")]


def _is_self(cmd):
    """True when running `cmd` would run this file again."""
    return any(os.path.basename(tok).lower() == _SHIM_BASENAME for tok in cmd)


def real_cc():
    """The compiler to wrap, as an argv prefix, or None when there is none.

    ORBIT_CC_REAL first: that is the name the wiring sets, and it keeps this
    resolution independent of whatever CC means to a given caller. CC is the
    compiler's own second choice, so exporting the pair by hand works too. A
    candidate that would run this file is skipped rather than followed,
    because the wiring sets ORBIT_CC and CC from the same value and wrapping
    the wrapper is a fork bomb.
    """
    for var in ("ORBIT_CC_REAL", "CC"):
        value = (os.environ.get(var) or "").strip()
        if not value:
            continue
        cmd = _split_command(value)
        if cmd and not _is_self(cmd):
            return cmd
    for name in ("gcc", "clang", "cc"):
        found = shutil.which(name)
        if found:
            return [found]
    return None


def run_uncached(cc_argv):
    """Run the invocation the way the compiler would have, and report its status."""
    try:
        return subprocess.run(cc_argv).returncode
    except OSError as e:
        print("cc_cached: cannot run %s (%s)" % (cc_argv[0], e), file=sys.stderr)
        return 127


def main(argv=None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args[:1] in (["self-test"], ["--self-test"]):
        return self_test()
    cc = real_cc()
    if cc is None:
        print("cc_cached: no C compiler found; set ORBIT_CC_REAL (or CC) to "
              "the compiler this wrapper should run", file=sys.stderr)
        return 127
    # `sources` is the statement of what the compile reads that the argv
    # carries. Without it the key would be blind to the content of the very C
    # being compiled, which is the one input that always changes between two
    # builds of one program.
    sources = orbit_ccache.argv_inputs(args, cwd=os.getcwd())
    if not sources:
        return run_uncached(cc + args)
    try:
        orbit_ccache.compile_cached(cc, cc + args, sources)
    except subprocess.CalledProcessError as e:
        return e.returncode if e.returncode is not None else 1
    except OSError as e:
        print("cc_cached: %s" % e, file=sys.stderr)
        return 127
    return 0


# A compiler stand-in: it records every invocation, refuses when told to, and
# otherwise writes an artifact that depends on the bytes of its inputs. No C
# toolchain is involved, so the self-test runs wherever the wrapper does.
_STUB = '''\
import hashlib
import os
import sys

log = os.environ.get("CC_CACHED_STUB_LOG")
if log:
    with open(log, "a", encoding="utf-8", newline="\\n") as f:
        f.write(" ".join(sys.argv[1:]) + "\\n")

args = sys.argv[1:]
if "-DFAIL" in args:
    sys.stderr.write("stub: refusing to compile\\n")
    raise SystemExit(3)

target = None
sources = []
i = 0
while i < len(args):
    if args[i] == "-o" and i + 1 < len(args):
        target = args[i + 1]
        i += 2
        continue
    if not args[i].startswith("-") and os.path.isfile(args[i]):
        sources.append(args[i])
    i += 1

print("stub: %d source(s)" % len(sources))
if target:
    h = hashlib.sha256()
    for src in sources:
        with open(src, "rb") as f:
            h.update(f.read())
        h.update(b"\\0")
    os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)
    with open(target, "w", encoding="utf-8", newline="\\n") as f:
        f.write("stub-artifact:" + h.hexdigest()[:16] + "\\n")
'''


def _entries(root):
    """How many completed cache entries are under `root`."""
    count = 0
    for _dirpath, _dirs, files in os.walk(root):
        count += sum(1 for name in files if name.endswith(".art"))
    return count


def self_test() -> int:
    """Assert the wrapper's properties, with no C compiler and no C file.

    Every assertion is about the wrapper rather than about cc, so the compiler
    is a stub: argv handed over untouched, status and diagnostics propagated,
    a second identical invocation not recompiling, an edited source doing so,
    and the fail-open paths staying open. A self-test that needed a toolchain
    could not run in the places the wrapper has to run.

    The interesting assertion is the fifth one. Restoring a source to its
    earlier bytes must be a HIT, because that is what separates a cache keyed
    on content from one keyed on mtime, and the second kind is the one that
    ships a stale binary while the build looks green.
    """
    import tempfile

    fails = []

    def check(name, ok):
        print(("  ok   " if ok else "  FAIL ") + name)
        if not ok:
            fails.append(name)

    with tempfile.TemporaryDirectory(prefix="cc_cached_selftest_") as td:
        stub = os.path.join(td, "stubcc.py")
        log = os.path.join(td, "calls.log")
        cache = os.path.join(td, "cache")
        source = os.path.join(td, "prog.c")
        target = os.path.join(td, "prog.bin")
        other = os.path.join(td, "other.bin")
        with open(stub, "w", encoding="utf-8", newline="\n") as f:
            f.write(_STUB)
        with open(source, "w", encoding="utf-8", newline="\n") as f:
            f.write("int main(void) { return 0; }\n")

        here = os.path.abspath(__file__)
        base = {k: v for k, v in os.environ.items()
                if k not in ("ORBIT_CC", "ORBIT_CCACHE")}
        base["ORBIT_CCACHE_DIR"] = cache
        base["CC_CACHED_STUB_LOG"] = log
        # The wrapper with arguments, which is the spelling the compiler
        # splices in: ORBIT_CC_REAL is a command line, not a path.
        base["ORBIT_CC_REAL"] = '"%s" "%s"' % (sys.executable, stub)

        def calls():
            try:
                with open(log, encoding="utf-8") as f:
                    return len(f.read().splitlines())
            except OSError:
                return 0

        def run(args, **over):
            env = dict(base)
            env.update(over)
            return subprocess.run([sys.executable, here] + args, env=env,
                                  capture_output=True, text=True,
                                  errors="replace", timeout=120)

        def read(path):
            with open(path, encoding="utf-8") as f:
                return f.read()

        def write(path, text):
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)

        args = ["-O1", source, "-o", target]
        first = run(args)
        check("a successful compile is transparent: status 0, output passed on",
              first.returncode == 0 and "stub: 1 source(s)" in first.stdout)
        check("the compiler's own artifact is what lands",
              os.path.isfile(target)
              and read(target).startswith("stub-artifact:"))
        artifact = read(target)
        check("the first compile ran the compiler", calls() == 1)

        os.remove(target)
        second = run(args)
        check("a repeat invocation does not recompile", calls() == 1)
        check("...and still leaves the artifact in place",
              second.returncode == 0 and os.path.isfile(target)
              and read(target) == artifact)
        check("the pair cost the cache one entry", _entries(cache) == 1)

        write(source, "int main(void) { return 1; }\n")
        run(args)
        check("editing the source recompiles", calls() == 2)
        check("...and the artifact changes", read(target) != artifact)

        write(source, "int main(void) { return 0; }\n")
        os.remove(target)
        run(args)
        check("restoring the bytes is a hit, not a rebuild (content, not mtime)",
              calls() == 2 and read(target) == artifact)

        bad = run(["-DFAIL", source, "-o", target])
        check("a failing compile fails with the compiler's status",
              bad.returncode == 3)
        check("...and its diagnostics reach the caller",
              "refusing to compile" in bad.stderr)

        before = calls()
        no_out = run(["-E", source])
        check("no -o target: the compiler runs, uncached",
              no_out.returncode == 0 and calls() == before + 1)

        stored = _entries(cache)
        no_src = run(["-o", other])
        check("no named input: the compiler runs, uncached",
              no_src.returncode == 0 and calls() == before + 2
              and _entries(cache) == stored)

        off = run(args, ORBIT_CCACHE="0")
        check("ORBIT_CCACHE=0 compiles directly and stores nothing",
              off.returncode == 0 and _entries(cache) == stored)

        # The fork-bomb guard, asserted where it bites: ORBIT_CC_REAL names
        # this file, and CC names the compiler, so the fallback has to walk
        # past the candidate that would re-run this file.
        saved = (os.environ.get("ORBIT_CC_REAL"), os.environ.get("CC"))
        try:
            os.environ["ORBIT_CC_REAL"] = '"%s" "%s"' % (sys.executable, here)
            os.environ["CC"] = '"%s" "%s"' % (sys.executable, stub)
            got = real_cc()
        finally:
            for key, value in zip(("ORBIT_CC_REAL", "CC"), saved):
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        check("a candidate that would re-run this file is skipped",
              got == [sys.executable, stub])

    print("cc cache shim self-test: %s" % ("FAILED: " + ", ".join(fails)
                                           if fails else "OK"))
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
