#!/usr/bin/env python3
"""Snapshots of the compiler's rich and color screens, and the interrupt probe.

Usage:
    python scripts/ui_snapshots.py --compiler <orbit-binary> --cc <gcc> [--work DIR]
    python scripts/ui_snapshots.py --compiler <orbit-binary> --cc <gcc> --update
    python scripts/ui_snapshots.py --compiler <orbit-binary> --skip-probe

Each screen runs twice, with ORBIT_UI=rich ORBIT_UI_MOTION=0 (truecolor) and
with ORBIT_UI=color, in a scratch directory. Output is stdout and stderr in one
stream, CRLF folded to LF. Escape sequences stay, so a changed color is a
changed snapshot. Digits that belong to a time or a size and the cells of a
stage bar vary from run to run and are masked. The result is compared with
tests/ui/<screen>.<tier>.txt. --update rewrites those files.

The probe starts an animated build, sends it a console break and requires the
stream to end with cursor-show then reset (docs/CLI_UI.md). It needs a console
to send the break to and reports "probe skipped" when the platform offers none.
"""

import argparse
import difflib
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
from _common import resolve_cc

ROOT = pathlib.Path(__file__).resolve().parent.parent
SNAPSHOTS = ROOT / "tests" / "ui"

FIXTURES = {
    "hello.orb": 'fn main() {\n    print("hello")\n}\n',
    "sema_error.orb": 'fn main() {\n    val x: int = "s"\n    print("hi")\n}\n',
    "parse_error.orb": 'fn main() {\n    val total = 1 + * 2\n}\n',
    "unformatted.orb": 'fn main() {\nprint("hi")\n}\n',
    "scan/messy.orb": 'fn main() {\n    print("hi")   \n}\n',
    "scan/clean.orb": 'fn main() {\n    print("hi")\n}\n',
}

# name, argv, expected exit, fixture files to copy into a fresh directory first
SCREENS = [
    ("build", ["build", "hello.orb", "-o", "hello.exe", "--backend=c"], 0),
    ("run", ["run", "." + os.sep + "hello.orb", "--backend=c"], 0),
    ("build-sema-error", ["build", "sema_error.orb", "-o", "x.exe", "--backend=c"], 1),
    ("build-parse-error", ["build", "parse_error.orb", "-o", "x.exe", "--backend=c"], 1),
    ("check", ["check", "hello.orb"], 0),
    ("check-error", ["check", "sema_error.orb"], 1),
    ("doctor", ["doctor", "scan"], 1),
    ("fmt", ["fmt", "unformatted.orb"], 0),
    ("fmt-check", ["fmt", "--check", "scan"], 1),
    ("help", ["--help"], 0),
    ("bare", [], 0),
    ("version", ["--version"], 0),
]

TIERS = [("rich", {"ORBIT_UI": "rich", "COLORTERM": "truecolor"}),
         ("color", {"ORBIT_UI": "color"})]

# Variables that would change a tier or a color between machines.
SCRUB = ("NO_COLOR", "CI", "GITHUB_ACTIONS", "WT_SESSION", "TERM_PROGRAM", "COLORTERM",
         "ORBIT_UI", "ORBIT_UI_MOTION", "ORBIT_COLOR", "ORBIT_BACKEND", "ORBIT_SKIP_CC")

ESC = r"(?:\x1b\[[0-9;]*m)"
MASKS = [
    # Stage bars: the filled share follows the timings.
    (re.compile("%s*[▰▱](?:%s*[▰▱])*" % (ESC, ESC)), "<bar>"),
    (re.compile(r"\[(?:%s|[#\-])+\]" % ESC), "[<bar>]"),
    # The probe line names a compiler of the machine.
    (re.compile(r"^toolchain: found .*$", re.M), "toolchain: found <cc>"),
    # Times and sizes, with the padding that right-aligns them.
    (re.compile(r" *(?<![0-9.])\d+(?:\.\d+)?(?= (?:ms|KB)\b)"), " N"),
]


def normalize(text: str, scratch: str) -> str:
    text = text.replace("\r\n", "\n")
    for spelling in (scratch, scratch.replace("\\", "/")):
        text = text.replace(spelling, ".")
    text = text.replace("\\", "/")
    for pattern, repl in MASKS:
        text = pattern.sub(repl, text)
    return "\n".join(settle_card_padding(line) for line in text.split("\n"))


# A card row pads to its border, so a time of two digits leaves one space fewer
# than a time of one. After masking, the run before the border on such a row is
# one space.
MASKED_NUMBER = re.compile(r" N (?:ms|KB)")
BORDER_TAIL = re.compile(r" {2,}((?:\x1b\[[0-9;]*m)*[│|](?:\x1b\[[0-9;]*m)*)$")


def settle_card_padding(line: str) -> str:
    if MASKED_NUMBER.search(line):
        return BORDER_TAIL.sub(r" \1", line)
    return line


def child_env(extra: dict, cc: str, work: pathlib.Path) -> dict:
    env = dict(os.environ)
    for key in SCRUB:
        env.pop(key, None)
    # The compiler writes its intermediate C to a fixed name under TEMP, so a
    # build running beside this one (the lane gates) would overwrite it.
    scratch = work / "tmp"
    scratch.mkdir(parents=True, exist_ok=True)
    env["TEMP"] = env["TMP"] = str(scratch)
    env.update({"TERM": "xterm-256color", "ORBIT_UI_MOTION": "0", "ORBIT_BACKEND": "c",
                "ORBIT_LINK_RUNTIME": "0", "ORBIT_CCACHE": "0", "ORBIT_CC": cc})
    env.update(extra)
    return env


def stage_dir(work: pathlib.Path, name: str) -> pathlib.Path:
    d = work / name
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    for rel, text in FIXTURES.items():
        target = d / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8", newline="\n")
    # The compiler resolves the runtime relative to a directory it does not ship in.
    runtime = d / "runtime"
    runtime.mkdir()
    for src in (ROOT / "runtime").iterdir():
        if src.is_file() and src.suffix in (".c", ".h"):
            shutil.copyfile(src, runtime / src.name)
    return d


def run_screen(compiler: str, cc: str, work: pathlib.Path, name: str, argv: list, tier_env: dict):
    d = stage_dir(work, name)
    proc = subprocess.run([compiler] + argv, cwd=str(d), env=child_env(tier_env, cc, work),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
    return proc.returncode, normalize(proc.stdout.decode("utf-8", errors="replace"), str(d))


def show(text: str) -> None:
    """Print captured output on any console, escapes and non-ASCII made visible."""
    sys.stdout.write(text.replace(chr(27), "\\e").encode("ascii", "backslashreplace").decode("ascii"))
    sys.stdout.flush()


def check_snapshots(args, work: pathlib.Path) -> tuple:
    ok = 0
    total = 0
    SNAPSHOTS.mkdir(parents=True, exist_ok=True)
    for name, argv, want_rc in SCREENS:
        for tier_name, tier_env in TIERS:
            total += 1
            label = "%s.%s" % (name, tier_name)
            rc, text = run_screen(args.compiler, args.cc, work, name, argv, tier_env)
            path = SNAPSHOTS / (label + ".txt")
            if rc != want_rc:
                out.fail("Failed %s: exit %d, want %d" % (label, rc, want_rc))
                show(text)
                continue
            if args.update:
                path.write_text(text, encoding="utf-8", newline="\n")
                out.say("Wrote %s" % path.relative_to(ROOT).as_posix())
                ok += 1
                continue
            if not path.exists():
                out.fail("Failed %s: no snapshot at %s" % (label, path.relative_to(ROOT).as_posix()))
                out.tip("run scripts/ui_snapshots.py --update and read the file before committing it")
                continue
            want = path.read_text(encoding="utf-8")
            if want == text:
                out.say("Checking %s ... match" % label)
                ok += 1
                continue
            out.fail("Failed %s: output differs from %s" % (label, path.relative_to(ROOT).as_posix()))
            diff = difflib.unified_diff(want.splitlines(), text.splitlines(), "snapshot", "output", lineterm="", n=1)
            for line in list(diff)[:24]:
                show(line + "\n")
    return ok, total


def read_until(needle: bytes, sink: bytearray, deadline: float) -> bool:
    while time.monotonic() < deadline:
        if needle in bytes(sink):
            return True
        time.sleep(0.05)
    return needle in bytes(sink)


def probe_interrupt(args, work: pathlib.Path) -> tuple:
    """Break an animated build and read what the terminal would have been told."""
    d = stage_dir(work, "probe")
    env = child_env({"ORBIT_UI": "rich", "ORBIT_UI_MOTION": "force", "COLORTERM": "truecolor",
                     "ORBIT_SKIP_CC": "1"}, args.cc, work)
    flags = 0
    if os.name == "nt":
        flags = subprocess.CREATE_NEW_PROCESS_GROUP
    src = str(ROOT / "compiler" / "host" / "main.orb")
    proc = subprocess.Popen([args.compiler, "build", src, "-o", str(d / "probe.exe")], cwd=str(ROOT),
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, creationflags=flags)
    seen = bytearray()

    def pump():
        while True:
            chunk = proc.stderr.read(512)
            if not chunk:
                return
            seen.extend(chunk)

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    if not read_until(b"\x1b[?25l", seen, time.monotonic() + 20):
        proc.kill()
        out.fail("Failed interrupt-probe: no frame was painted (cursor-hide not seen)")
        return 0, 1
    time.sleep(0.6)
    try:
        if os.name == "nt":
            os.kill(proc.pid, signal.CTRL_BREAK_EVENT)
        else:
            proc.send_signal(signal.SIGINT)
    except OSError as exc:
        proc.kill()
        out.say("Interrupt-probe skipped: no console to send a break to (%s)" % exc)
        return 0, 0
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        out.fail("Failed interrupt-probe: the build did not stop after the break")
        return 0, 1
    reader.join(timeout=5)
    tail = bytes(seen)
    restore = b"\x1b[?25h\x1b[0m"
    if not tail.endswith(restore):
        out.fail("Failed interrupt-probe: stream ends with %r, want %r" % (tail[-24:], restore))
        return 0, 1
    if tail.count(b"\x1b[?25l") != 1:
        out.fail("Failed interrupt-probe: cursor-hide written %d times" % tail.count(b"\x1b[?25l"))
        return 0, 1
    out.say("Checking interrupt-probe ... cursor shown and styles reset after a break")
    return 1, 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--compiler", required=True, help="path to the orbit binary under test")
    ap.add_argument("--cc", default=None, help="C compiler for the build screens")
    ap.add_argument("--work", default=None, help="scratch directory")
    ap.add_argument("--update", action="store_true", help="rewrite tests/ui/*.txt from the current output")
    ap.add_argument("--skip-probe", action="store_true", help="do not run the interrupt probe")
    args = ap.parse_args()
    args.cc = resolve_cc(args.cc)
    args.compiler = str(pathlib.Path(args.compiler).resolve())
    work = pathlib.Path(args.work) if args.work else pathlib.Path(tempfile.mkdtemp(prefix="orbit_ui_"))
    work.mkdir(parents=True, exist_ok=True)
    ok, total = check_snapshots(args, work)
    if not args.skip_probe and not args.update:
        pok, ptotal = probe_interrupt(args, work)
        ok += pok
        total += ptotal
    out.finish("ui-snapshots", ok, total)
    return 0 if ok == total else 1


if __name__ == "__main__":
    sys.exit(main())
