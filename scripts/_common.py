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

    print("Finished _common self-test: build_env points TEMP/TMP and both "
          "compiler names, exports no cache unless asked, resolve_cc found "
          f"'{resolve_cc()}', and tail behaves on empty and short input.")
    return 0


if __name__ == "__main__":
    raise SystemExit(self_test())
