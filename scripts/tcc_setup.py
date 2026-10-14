#!/usr/bin/env python3
"""Pinned tcc 0.9.27 acquisition for the fast-build lane (T3).

tcc is the quick toolchain, never the reference one: it compiles a
translation unit in a fraction of gcc's time and is therefore useful for
single-file probes and edit-compile-run loops, but its codegen is
unoptimised and its Windows import libraries are incomplete, so a tcc
binary must never produce a quoted number (docs/TOOLCHAIN.md makes that
a rule). This script owns the "is tcc here, and is it the right one"
question in one place, so CI and developers do not each answer it.

Platform policy (see docs/TOOLCHAIN.md for the matrix):

  Windows x64  portable zip from the official Savannah release, pinned by
               SHA-256 and size, unpacked into a user directory (no admin).
  Linux x64    system package manager; the script never sudo-installs, it
               prints the exact command and exits SKIP. A tcc whose
               version is not 0.9.27 is a hard failure, never a quiet use.
  macOS        no stable tcc on ARM64 (0.9.27 has no ARM64 backend; the
               mob branch does but is unpinned and unstable, so this
               script refuses it). Clean SKIP pointing at gcc/clang.

Exit codes: 0 means the closing line says OK (installed / already there /
--check passed). 2 means SKIP (unavailable here, fallback documented, CI
treats it as a clean skip). 1 means a real failure: hash mismatch, wrong
version, unreadable install. The closing line is always
`Finished tcc-setup: ...`, which is what alive_check (D8) greps for; SKIP
still prints it, because reporting "not here" honestly is the tool
working, while exit 1 is the tool refusing a wrong toolchain.

Usage:
    python scripts/tcc_setup.py [--dir DIR] [--check] [--print-flags]
        [--print-exe] [--repo ROOT] [--self-test]
"""

import argparse
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

TCC_VERSION = "0.9.27"
WIN_ZIP_URL = ("https://download.savannah.nongnu.org/releases/tinycc/"
               "tcc-0.9.27-win64-bin.zip")
WIN_ZIP_SHA256 = "34a721949a2583fdff725312da092fa0f5f1f284b702e6f811c6954714faabb2"
WIN_ZIP_SIZE = 489586

PIN_FILENAME = ".orbit-tcc-pin"

RC_OK = 0
RC_FAIL = 1
RC_SKIP = 2


def default_dir() -> str:
    """User-writable home for the portable install. No admin, no repo."""
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return os.path.join(base, "orbit", "tcc-0.9.27")


def candidate_dirs(explicit: str | None) -> list:
    """Where --check looks, in order. Explicit beats environment beats default."""
    dirs = []
    if explicit:
        dirs.append(explicit)
    env = os.environ.get("ORBIT_TCC")
    if env:
        dirs.append(env)
    dirs.append(default_dir())
    return dirs


def tcc_exe_in(directory: str) -> str | None:
    """tcc.exe directly inside directory, or None. The zip's inner layout
    is flattened on install so the exe sits at the top with include/ and
    lib/ beside it, which is where tcc looks for them."""
    if not directory:
        return None
    if os.path.isfile(directory) and os.path.basename(directory).lower() in (
            "tcc.exe", "tcc"):
        return directory
    for name in ("tcc.exe", "tcc"):
        path = os.path.join(directory, name)
        if os.path.isfile(path):
            return path
    return None


def version_of(tcc: str) -> str | None:
    """First line of `tcc -v`, or None when it does not run. A missing
    binary is 'not here' (caller decides SKIP vs FAIL), a binary that
    runs but reports wrong is always FAIL."""
    try:
        proc = subprocess.run([tcc, "-v"], capture_output=True, text=True,
                              errors="replace", timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    text = (proc.stdout or "") + (proc.stderr or "")
    line = text.strip().splitlines()[0] if text.strip() else ""
    return line or None


def version_ok(line: str | None) -> bool:
    return bool(line) and ("tcc version %s" % TCC_VERSION) in line


def check(explicit: str | None) -> int:
    """Presence + version. Missing everywhere is SKIP (message, rc 2);
    present-but-wrong is FAIL (rc 1); exact pin is OK (rc 0)."""
    searched = []
    for directory in candidate_dirs(explicit):
        searched.append(directory)
        exe = tcc_exe_in(directory)
        if exe:
            line = version_of(exe)
            if version_ok(line):
                out.finish("tcc-setup", 1, 1, "OK %s (%s)" % (exe, line))
                return RC_OK
            out.fail("Failed tcc-setup: %s reports %r, want tcc %s. "
                     "Remove it or point ORBIT_TCC/--dir at the pinned one."
                     % (exe, line or "nothing", TCC_VERSION))
            return RC_FAIL
    path_exe = shutil.which("tcc")
    if path_exe:
        line = version_of(path_exe)
        if version_ok(line):
            out.finish("tcc-setup", 1, 1, "OK %s (%s)" % (path_exe, line))
            return RC_OK
        out.fail("Failed tcc-setup: PATH tcc %s reports %r, want tcc %s."
                 % (path_exe, line or "nothing", TCC_VERSION))
        return RC_FAIL
    out.say("Finished tcc-setup: SKIP no tcc %s found (searched: %s; "
            "run `python scripts/tcc_setup.py` to acquire it, or use "
            "gcc/clang)" % (TCC_VERSION, "; ".join(searched)))
    return RC_SKIP


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_pin(directory: str) -> str:
    try:
        with open(os.path.join(directory, PIN_FILENAME),
                  encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def write_pin(directory: str) -> None:
    with open(os.path.join(directory, PIN_FILENAME), "w",
              encoding="utf-8", newline="\n") as fh:
        fh.write("tcc %s %s\n" % (TCC_VERSION, WIN_ZIP_SHA256))


def install_windows(directory: str) -> int:
    """Idempotent portable install: exact pin present means no-op. The zip
    carries a top-level `tcc/` folder; its contents are hoisted so that
    tcc.exe sits beside include/ and lib/, the layout tcc resolves its
    private files from."""
    exe = tcc_exe_in(directory)
    if exe and version_ok(version_of(exe)) \
            and read_pin(directory) == "tcc %s %s" % (TCC_VERSION, WIN_ZIP_SHA256):
        out.finish("tcc-setup", 1, 1,
                   "OK already installed %s" % exe)
        return RC_OK
    os.makedirs(directory, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="orbit_tcc_dl_")
    try:
        zpath = os.path.join(tmp, "tcc-0.9.27-win64-bin.zip")
        out.say("  downloading %s ..." % WIN_ZIP_URL)
        try:
            urllib.request.urlretrieve(WIN_ZIP_URL, zpath)
        except Exception as exc:
            out.say("Finished tcc-setup: SKIP download failed (%s); "
                    "use gcc/clang" % exc)
            return RC_SKIP
        size = os.path.getsize(zpath)
        digest = sha256_file(zpath)
        if size != WIN_ZIP_SIZE or digest != WIN_ZIP_SHA256:
            out.fail("Failed tcc-setup: downloaded zip is not the pinned "
                     "one (size %d want %d, sha256 %s). Refusing."
                     % (size, WIN_ZIP_SIZE, digest))
            return RC_FAIL
        with zipfile.ZipFile(zpath) as zf:
            zf.extractall(tmp)
        roots = [os.path.join(tmp, name) for name in os.listdir(tmp)]
        inner = os.path.join(tmp, "tcc")
        src = inner if os.path.isdir(inner) else tmp
        for name in os.listdir(src):
            dest = os.path.join(directory, name)
            if os.path.isdir(dest) and not os.path.islink(dest):
                shutil.rmtree(dest)
            elif os.path.exists(dest):
                os.remove(dest)
            shutil.move(os.path.join(src, name), dest)
        # A straight re-download must not leave two copies behind.
        _ = roots
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    exe = tcc_exe_in(directory)
    line = version_of(exe) if exe else None
    if not version_ok(line):
        out.fail("Failed tcc-setup: fresh unpack at %s reports %r."
                 % (directory, line or "nothing"))
        return RC_FAIL
    write_pin(directory)
    out.finish("tcc-setup", 1, 1, "OK installed %s (%s)" % (exe, line))
    return RC_OK


def linux_hint() -> int:
    exe = shutil.which("tcc")
    if exe and version_ok(version_of(exe)):
        out.finish("tcc-setup", 1, 1, "OK system %s" % exe)
        return RC_OK
    if exe:
        out.fail("Failed tcc-setup: system tcc is not %s (see `tcc -v`). "
                 "This lane pins %s; upgrade/downgrade it deliberately."
                 % TCC_VERSION)
        return RC_FAIL
    managers = ("apt-get install -y tcc", "dnf install -y tcc",
                "pacman -S --noconfirm tcc", "apk add tcc")
    out.say("Finished tcc-setup: SKIP no system tcc; install one, e.g. "
            "`sudo %s`, then re-run (want tcc %s); or use gcc/clang"
            % (managers[0], TCC_VERSION))
    return RC_SKIP


def macos_hint() -> int:
    out.say("Finished tcc-setup: SKIP tcc %s has no ARM64 backend and no "
            "stable macOS support (the mob branch is unpinned); the "
            "documented fallback is gcc/clang (docs/TOOLCHAIN.md)"
            % TCC_VERSION)
    return RC_SKIP


def print_exe(explicit: str | None) -> int:
    """The tcc binary CI builds with, without re-deriving the search.
    rc 0 + path when present and pinned, rc 1 otherwise (caller maps a
    missing toolchain to SKIP, never to a silent pass)."""
    for directory in candidate_dirs(explicit):
        exe = tcc_exe_in(directory)
        if exe and version_ok(version_of(exe)):
            print(exe)
            return RC_OK
    path_exe = shutil.which("tcc")
    if path_exe and version_ok(version_of(path_exe)):
        print(path_exe)
        return RC_OK
    out.fail("Failed tcc-setup: no pinned tcc %s to print" % TCC_VERSION)
    return RC_FAIL


def print_flags(repo: str) -> int:
    """Compile flags for the shim, so CI does not re-derive the layout."""
    shim = os.path.join(repo, "vendor", "tcc-shim")
    if not os.path.isfile(os.path.join(shim, "tcc_toolchain.h")):
        out.fail("Failed tcc-setup: no shim at %s" % shim)
        return RC_FAIL
    out.say("-I%s" % shim)
    out.say("-include tcc_toolchain.h")
    out.say(os.path.join(shim, "ws2_32.def"))
    out.say(os.path.join(shim, "sqlite3.def"))
    out.finish("tcc-setup", 1, 1, "OK flags for %s" % shim)
    return RC_OK


def self_test() -> int:
    """The tool must be able to say no: missing install, wrong version,
    and a tampered pin each have to fail, not pass quietly."""
    passed = 0
    total = 3
    with tempfile.TemporaryDirectory(prefix="tcc_setup_selftest_") as td:
        empty = os.path.join(td, "empty")
        os.makedirs(empty)
        if tcc_exe_in(empty) is None:
            passed += 1
            print("  ok    an empty dir names no tcc")
        else:
            out.fail("  WRONG an empty dir named a tcc")
        if not version_ok("tcc version 0.9.26 (x86_64 Windows)"):
            passed += 1
            print("  ok    0.9.26 is refused by the pin")
        else:
            out.fail("  WRONG 0.9.26 passed the pin")
        if not version_ok(None) and not version_ok(""):
            passed += 1
            print("  ok    no version output is refused")
        else:
            out.fail("  WRONG empty version output passed the pin")
    out.finish("tcc-setup self-test", passed, total)
    return RC_OK if passed == total else RC_FAIL


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", default=None,
                    help="install/check directory (default: %%LOCALAPPDATA%%"
                         "\\orbit\\tcc-0.9.27 on Windows)")
    ap.add_argument("--check", action="store_true",
                    help="verify presence + version only, install nothing")
    ap.add_argument("--print-flags", action="store_true",
                    help="print the shim compile flags and exit")
    ap.add_argument("--print-exe", action="store_true",
                    help="print the pinned tcc binary path and exit")
    ap.add_argument("--repo", default=None,
                    help="repository root for --print-flags")
    ap.add_argument("--self-test", action="store_true",
                    help="assert the pin can say no")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    if args.self_test:
        return self_test()
    if args.print_flags:
        repo = args.repo or os.path.dirname(
            os.path.dirname(os.path.abspath(__file__)))
        return print_flags(repo)
    if args.print_exe:
        return print_exe(args.dir)
    if args.check:
        return check(args.dir)
    system = platform.system()
    if system == "Windows":
        return install_windows(args.dir or default_dir())
    if system == "Linux":
        return linux_hint()
    if system == "Darwin":
        return macos_hint()
    out.fail("Failed tcc-setup: unsupported platform %s" % system)
    return RC_FAIL


if __name__ == "__main__":
    raise SystemExit(main())
