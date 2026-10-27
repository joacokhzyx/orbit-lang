"""The things every script in this directory was deciding for itself.

Twenty scripts here each resolve a C compiler, build an environment, create a
scratch directory, and print a `Finished X: n/n` line. Seven of them set `TEMP`
and `TMP` independently, and that is not a style complaint: `TEMP` is where the
compiler writes its intermediate C, so a scratch directory on the system temp
means the compile cache lands on one filesystem while the C file lands on
another, and a fixed-point binary there disappears when the temp is cleaned. Two
runnable compilers went missing that way during a single session, and
`doctor_scope_gate.py` was writing its scratch to a different disk from the one
holding the cache.

`--cc` and `--compiler` are worse, because the inconsistency is invisible. Fourteen
scripts accept `--cc`, fifteen accept `--compiler`, three accept neither, and
`doctor_gate.py` accepts `--cc` and ignores it. `cli_probe.py` runs the compiler
with `cwd` set to its own work directory, so a relative `--compiler` resolves
against the wrong place and the failure is a `FileNotFoundError` on the gate's own
argument. Anyone driving these from a script has to know which of the two each one
wants.

So: one place that resolves the compiler, one that builds the environment, one
that adds the flags, one that locates the fixed point. Importing this is
deliberately cheap -- it is a sibling module, so `import _common` works from any
script run as `python scripts/foo.py` with no path fiddling.

What this deliberately does NOT centralise: the `Finished X: n/n` line. Each gate
prints its own counts, its own wording and its own thresholds, and folding that
into a shared helper would be a cosmetic change across twenty files with a real
chance of dropping a count that a gate somewhere depends on. The line is uniform
because it is a convention, not because it is code.
"""

import argparse
import os
import pathlib
import shutil
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Where dev.py keeps the fixed point. Not the system temp by accident: see
# fp_path() in scripts/dev.py for why it has to stay outside the repository, and
# why TEMP cannot decide it.
ORBIT = ROOT / ".orbit"
CC_CACHE = ORBIT / "ccache"


def resolve_cc(explicit=None, required=True):
    """The C compiler, in the order the bootstrap itself uses.

    ORBIT_CC, then CC, then the usual names. The order is duplicated from
    build_selfhost.py rather than imported, because importing a bootstrap script
    from the tool that drives it couples the tool's lifetime to that script's
    import-time behaviour, and the order is three lines.
    """
    for candidate in (explicit, os.environ.get("ORBIT_CC"), os.environ.get("CC")):
        if candidate:
            name = candidate.split()[0]
            if shutil.which(name):
                return candidate
    for name in ("gcc", "clang", "cc"):
        if shutil.which(name):
            return name
    if required:
        print("Failed: no C compiler found; set ORBIT_CC or pass --cc "
              "(gcc/clang/cc).", file=sys.stderr)
        raise SystemExit(2)
    return None


def add_common_args(ap):
    """`--cc` and `--compiler`, with the same meaning everywhere.

    Two flags rather than one because they really are two things: `--cc` is the
    C toolchain the compiler shells out to, `--compiler` is the orbit binary
    under test. Nine of the scripts need both, three need only the first, and
    until this existed each one declared whichever it happened to want.
    """
    ap.add_argument("--cc", default=None,
                    help="C compiler (default: ORBIT_CC/CC/gcc/clang/cc)")
    ap.add_argument("--compiler", default=None,
                    help="the orbit binary to test (default: ask scripts/dev.py)")
    return ap


def build_env(work, *, cc=None, parent=None, ccache=None):
    """An environment for a child that writes intermediate C.

    `TEMP` and `TMP` are pointed at `work` and are not optional: the compiler
    reads them at run time and writes `orbit_selfhost_build.c` there. The reason
    they point at the caller's directory rather than a fresh mkdtemp is that
    seven callers were each inventing their own answer, and two of them had
    reasons -- `negative_gate` owns its temp because every build writes the same
    filename into it and a shared temp is a race between gates.

    `ORBIT_CCACHE_DIR` is set only when asked. Passing it to a gate that compiles
    two programs with different flags is fine; passing it to something that runs
    the same unit twice concurrently is a cache-key race, so the caller decides.
    """
    env = dict(parent if parent is not None else os.environ)
    env["TEMP"] = str(work)
    env["TMP"] = str(work)
    if cc:
        env["ORBIT_CC"] = cc
        env["CC"] = cc
    if ccache:
        env["ORBIT_CCACHE_DIR"] = str(ccache)
    return env


def scratch(prefix="orbit_gate_"):
    """A fresh directory that exists, returned as a Path.

    Never reused between calls: a stale `orbit_selfhost_build.c` from a previous
    run is worse than no directory at all, because it looks like a result.
    """
    return pathlib.Path(tempfile.mkdtemp(prefix=prefix))


def _pipe_ok(cc_string):
    """Whether `-pipe` survives the named C driver.

    `-pipe` is a GCC/Clang flag; MSVC's `cl` rejects it, so it is gated on
    the toolchain rather than the platform. A cache wrapper (`ccache gcc`)
    names the wrapper, not the driver, so the first token is skipped when
    it is a known wrapper. Empty (unknown) counts as ok: on Windows the
    default toolchain is gcc and the flag is harmless everywhere else.
    """
    tokens = (cc_string or "").strip().split()
    if (tokens and tokens[0].lower().rsplit("/", 1)[-1].rsplit("\\", 1)[-1]
            .removesuffix(".exe") in ("ccache", "sccache")):
        tokens = tokens[1:]
    prog = tokens[0].lower() if tokens else ""
    prog = prog.rsplit("/", 1)[-1].rsplit("\\", 1)[-1].removesuffix(".exe")
    if not prog:
        return True
    if prog in ("cl", "clang-cl", "icl"):
        return False
    return any(t in prog for t in ("gcc", "g++", "clang", "cc"))


def _ccache_wanted(env):
    """False when the caller turned the C cache off, in the environment given.

    The same spelling rule as scripts/orbit_ccache.py's own switch, but read
    from the environment being built rather than from this process's: a gate
    may assemble its child environment from a copy, and the gate's answer is
    the one the child will live with.
    """
    return str(env.get("ORBIT_CCACHE", "1")).strip().lower() not in (
        "0", "false", "no")


def _wrap_cc(env, cc):
    """Route the compiler's inner cc through scripts/cc_cached.py, in place.

    The inner compile is the other half of a gate's wall time and it is the
    same C on every run, which is what the content cache in orbit_ccache.py is
    for. The compiler reads ORBIT_CC before CC and documents it as a wrapper
    with arguments, so the wrapper goes there and needs no compiler change.

    The real driver stays visible under both other names: ORBIT_CC_REAL for
    the wrapper itself, and CC for whoever asks what the toolchain is. CC is
    deliberately not the wrapper -- `_pipe_ok` would then decide -pipe support
    from an interpreter's name, and a wrapper resolving its driver from its own
    name is how a fork bomb starts. A second pass over an already-wrapped
    environment is a no-op for the same reason.

    The value is a command line with no quotes, because that is what the
    compiler splices into a shell line: quoting the interpreter makes cmd.exe
    read the first token as a program named '"C:/.../python.exe"' and fail the
    build with "the filename, directory name or volume label syntax is
    incorrect" (measured 2026-10-17). An ORBIT_CC whose own path needs quoting
    is a problem the compiler's cc line has with or without this wrapper.
    """
    if "cc_cached.py" in env.get("ORBIT_CC", ""):
        return
    shim = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "cc_cached.py")
    env["ORBIT_CC_REAL"] = cc
    env["ORBIT_CC"] = "%s %s" % (sys.executable, shim)
    env["CC"] = cc


def disposable_test_env(env, cc=None):
    """Fast defaults for binaries a test gate builds, runs once and deletes.

    Every `orbit build` on Windows links a version resource + icon through
    windres/llvm-rc (~60 ms per binary, timed 2026-10-14 on gcc 16.2) and
    compiles its generated C with `-Wall`. Both are correct for a binary
    that ships and pure overhead for one a gate throws away: no gate asserts
    on VERSIONINFO or the icon (only scripts/orbit_ccache.py, the bootstrap
    path, stamps branding, which is where the fp and service binaries are
    covered), and the strict warning gate is scripts/werror_gate.py, which
    recompiles emitted C itself with `-Werror` and never sees these flags.
    `-pipe` only swaps gcc's temp files for pipes (byte-identical `-S`
    output, timed the same day), so it rides along via ORBIT_CCFLAGS_EXTRA,
    the variable the compiler already appends to its inner cc line.

    The same argument covers the C cache: the inner compile of the SAME
    emitted C is what a gate spends its seconds on, so ORBIT_CC becomes
    scripts/cc_cached.py and a repeat run is a file copy. That is a real
    indirection, so it is wired only when the caller NAMES the driver -- the
    `cc` argument, which is what every gate that compiles passes -- and only
    when the cache is wanted (see `_ccache_wanted`). Without that argument the
    toolchain is whatever the ambient environment says, and the one caller
    that relies on it (scripts/test_suite.py, which passes a no-op compiler to
    run without compiling at all) would pay the wrapper for nothing. It also
    fails open on its own: with no usable cache directory the wrapper runs the
    compiler and the only cost is one interpreter start.

    Each knob keeps an escape hatch through the ambient environment: a
    variable the caller already exported always wins over the default, so
    `ORBIT_SKIP_WINDRES=0` restores the stamp, `ORBIT_WARNINGS=1` restores
    `-Wall`, and `ORBIT_CCACHE=0` leaves the compiler exactly where it was for
    one run. `ORBIT_SKIP_WINDRES` is inert until the compiler honours it
    (compiler/host/pipeline.orb still always stamps); setting it here is
    forward-compatible and costs nothing meanwhile.
    """
    named = cc is not None
    if cc is None:
        cc = (env.get("ORBIT_CC_REAL") or env.get("ORBIT_CC")
              or env.get("CC") or "")
    if os.name == "nt" and _pipe_ok(cc):
        extra = env.get("ORBIT_CCFLAGS_EXTRA", "")
        if "-pipe" not in extra.split():
            env["ORBIT_CCFLAGS_EXTRA"] = (extra + " -pipe").strip()
    if "ORBIT_WARNINGS" not in env:
        env["ORBIT_WARNINGS"] = "0"
    if "ORBIT_SKIP_WINDRES" not in env:
        env["ORBIT_SKIP_WINDRES"] = "1"
    # The compiler links the prebuilt runtime archive by default when one is
    # fresh. A gate that does not ask for the link lane keeps the unity build
    # it always had, whether or not an archive happens to sit in .orbit/lib.
    if "ORBIT_LINK_RUNTIME" not in env:
        env["ORBIT_LINK_RUNTIME"] = "0"
    if cc and named and _ccache_wanted(env):
        _wrap_cc(env, cc)
    return env


def fixed_point(cc, build_if_missing=False):
    """The orbit binary to test, from the same rule dev.py uses.

    Delegates rather than recomputes the path, because the path is load-bearing
    in a way that is easy to get subtly wrong: the compiler resolves its runtime
    as <dir of argv[0]>/runtime, so a binary inside the repository makes
    `doctor_gate`'s --fix goldens fail over a missing header AND silently void
    `cli_probe`'s toolchain-misreporting probe. Two ways to compute the same path
    is how that happened.
    """
    proc = subprocess_run([sys.executable,
                          str(ROOT / "scripts" / "dev.py"), "fp-path",
                          "--cc", cc or ""],
                         capture_output=True)
    path = proc.strip()
    if not path or not os.path.exists(path):
        if not build_if_missing:
            return None
        subprocess_run([sys.executable, str(ROOT / "scripts" / "dev.py"), "fp",
                        "--cc", cc or ""], capture_output=True)
        path = subprocess_run([sys.executable,
                               str(ROOT / "scripts" / "dev.py"), "fp-path"],
                              capture_output=True).strip()
    return path or None


def subprocess_run(argv, capture_output=True):
    import subprocess
    proc = subprocess.run(argv, cwd=str(ROOT), capture_output=capture_output,
                          text=True)
    return (proc.stdout or "").strip() if capture_output else proc


def tail(text, lines=8):
    """The last few lines of a diagnostic, for a gate that has to print one.

    stderr first, because `orbit build` writes diagnostics there. A runner that
    prints stdout instead reports "no output" for every build failure, which is
    what scripts/test_suite.py did until the first Windows-only failure arrived
    to expose it.
    """
    if not text:
        return ""
    return "\n".join(text.strip().splitlines()[-lines:])

def self_test() -> int:
    """Assert the shared helpers do what seven gates now assume they do.

    This module is not exempt from D8. It is imported by every gate that builds
    a compiler, so a defect here is seven gates failing at once with a traceback
    in a shared frame -- which is exactly the failure mode where nobody can tell
    which gate is wrong. A self-test that names the broken helper is better than
    an exemption that says "this file cannot fail", which is true of nothing.
    """
    import tempfile

    with tempfile.TemporaryDirectory(prefix="common_selftest_") as td:
        work = pathlib.Path(td)

        # parent={} rather than the real environment: inheriting a cache dir from
        # the parent is correct, and testing it against the ambient one proved
        # that by failing for the right reason. The property worth pinning is
        # that build_env does not ADD one nobody asked for.
        env = build_env(work, cc="gcc", parent={})
        if env["TEMP"] != str(work) or env["TMP"] != str(work):
            print("self-test FAILED: build_env did not point TEMP/TMP at the "
                  "given directory, so the compiler would write its "
                  "intermediate C somewhere else")
            return 1
        if env.get("ORBIT_CC") != "gcc" or env.get("CC") != "gcc":
            print("self-test FAILED: build_env did not export the C compiler "
                  "under both names, which is what pipeline.orb reads")
            return 1
        if "ORBIT_CCACHE_DIR" in env:
            print("self-test FAILED: build_env exported a compile cache "
                  "nobody asked for; a cache key is a race if two callers share "
                  "it")
            return 1

        env2 = build_env(work, cc="clang", ccache=ORBIT / "ccache")
        if env2["ORBIT_CCACHE_DIR"] != str(ORBIT / "ccache"):
            print("self-test FAILED: build_env ignored an explicit cache dir")
            return 1

        got = resolve_cc()
        if not got:
            print("self-test FAILED: resolve_cc found nothing on a machine that "
                  "has just compiled C")
            return 1

        if tail("", 5) != "":
            print("self-test FAILED: tail of an empty diagnostic is not empty")
            return 1
        if tail("a\nb\nc", 2) != "b\nc":
            print("self-test FAILED: tail did not take the last N lines")
            return 1

        # Disposable test binaries default to fast: no -Wall, no windres
        # stamp, -pipe on a Windows gcc. Each default yields to an ambient
        # export, which is the escape hatch a run that wants the slow path
        # uses.
        fast = disposable_test_env({}, cc="gcc")
        if fast.get("ORBIT_WARNINGS") != "0":
            print("self-test FAILED: disposable_test_env did not default "
                  "ORBIT_WARNINGS to 0, so test builds pay -Wall")
            return 1
        if fast.get("ORBIT_SKIP_WINDRES") != "1":
            print("self-test FAILED: disposable_test_env did not default "
                  "ORBIT_SKIP_WINDRES to 1, so test builds pay windres")
            return 1
        if fast.get("ORBIT_LINK_RUNTIME") != "0":
            print("self-test FAILED: disposable_test_env did not default "
                  "ORBIT_LINK_RUNTIME to 0, so a stray archive changes "
                  "what a gate builds")
            return 1
        if disposable_test_env({"ORBIT_LINK_RUNTIME": "1"},
                               cc="gcc").get("ORBIT_LINK_RUNTIME") != "1":
            print("self-test FAILED: disposable_test_env overrode the link "
                  "lane's ORBIT_LINK_RUNTIME=1")
            return 1
        slow = disposable_test_env({"ORBIT_WARNINGS": "1",
                                    "ORBIT_SKIP_WINDRES": "0"},
                                   cc="gcc")
        if (slow.get("ORBIT_WARNINGS") != "1"
                or slow.get("ORBIT_SKIP_WINDRES") != "0"):
            print("self-test FAILED: disposable_test_env overrode an "
                  "explicit ambient knob; the escape hatch is the contract")
            return 1
        # The caller's own extra flags survive verbatim on a driver that
        # cannot take -pipe; on one that can, -pipe is appended, never
        # substituted.
        cl_extra = disposable_test_env({"ORBIT_CCFLAGS_EXTRA": "-O2"}, cc="cl")
        if cl_extra.get("ORBIT_CCFLAGS_EXTRA") != "-O2":
            print("self-test FAILED: disposable_test_env dropped the "
                  "caller's own ORBIT_CCFLAGS_EXTRA")
            return 1
        if os.name == "nt":
            if "-pipe" not in fast.get("ORBIT_CCFLAGS_EXTRA", "").split():
                print("self-test FAILED: disposable_test_env did not add "
                      "-pipe for gcc on Windows")
                return 1
            cl = disposable_test_env({}, cc="cl")
            if "-pipe" in cl.get("ORBIT_CCFLAGS_EXTRA", "").split():
                print("self-test FAILED: disposable_test_env passed -pipe "
                      "to MSVC cl, which rejects it")
                return 1

        # The C cache wrapper. `ORBIT_CCACHE=0` has to leave the compiler where
        # it was, not merely disable the cache: the escape hatch is what a run
        # that suspects the cache reaches for.
        off = disposable_test_env({"ORBIT_CCACHE": "0"}, cc="gcc")
        if "ORBIT_CC_REAL" in off or "cc_cached" in off.get("ORBIT_CC", ""):
            print("self-test FAILED: ORBIT_CCACHE=0 did not leave the C "
                  "compiler alone; the escape hatch is the contract")
            return 1
        wrapped = disposable_test_env({}, cc="gcc")
        if "cc_cached.py" not in wrapped.get("ORBIT_CC", ""):
            print("self-test FAILED: disposable_test_env did not route the "
                  "inner compile through the C cache")
            return 1
        if (wrapped.get("ORBIT_CC_REAL") != "gcc"
                or wrapped.get("CC") != "gcc"):
            print("self-test FAILED: the cache wrapper did not keep the real "
                  "driver reachable under ORBIT_CC_REAL and CC")
            return 1
        if "cc_cached.py" in wrapped.get("CC", ""):
            print("self-test FAILED: CC names the cache wrapper, so the "
                  "wrapper would resolve its driver from itself")
            return 1
        again = disposable_test_env(dict(wrapped))
        if (again.get("ORBIT_CC_REAL") != "gcc"
                or "cc_cached.py" not in again.get("ORBIT_CC", "")):
            print("self-test FAILED: a second pass over an already-wrapped "
                  "environment rewrote the wrapper's own driver")
            return 1
        unnamed = disposable_test_env({"ORBIT_CC": "gcc"})
        if "ORBIT_CC_REAL" in unnamed:
            print("self-test FAILED: disposable_test_env wrapped a driver the "
                  "caller did not name; scripts/test_suite.py passes a no-op "
                  "compiler on that path on purpose")
            return 1

    print("Finished _common self-test: build_env points TEMP/TMP and both "
          "compiler names, exports no cache unless asked, resolves the C "
          "cache wrapper with the real driver still named, resolve_cc found "
          f"'{resolve_cc()}', and tail behaves on empty and short input.")
    return 0


if __name__ == "__main__":
    raise SystemExit(self_test())
