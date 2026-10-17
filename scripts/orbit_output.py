#!/usr/bin/env python3
"""Shared output conventions for Orbit repo scripts.

Style: calm phrases, no [tag] prefixes. Steps read as actions, failures
carry a fact plus a next step, and every tool closes the same way:

    Checking parity r1_route_only ... match
    Testing arith ... exit 0 as expected
    Building seed ...
    Failed arith: got exit 3, want 0
    Tip: run `orbit check tests/suite/arith.orb` to see the error card
    Finished suite: 21/21 pass

Color follows the Orbit palette (the same roles as compiler/tools/palette.orb:
red for failures, yellow for tips, green for passing counts) and only
ever fires on a live terminal: piped output -- every gate, every CI log --
stays byte-identical to plain text. ORBIT_COLOR=always|never overrides the
auto-detection; NO_COLOR and TERM=dumb always win.

Rules (see docs/COMMANDS.md):
- successes and progress go to stdout; failures go to stderr;
- `::error::` annotations print only on GitHub Actions (GITHUB_ACTIONS);
- `--quiet` (via add_quiet) prints only failures and the Finished line;
- no emojis, no exclamation stacks.
"""

import os
import sys

_QUIET = False

# The Orbit palette for scripts. Same roles as compiler/tools/palette.orb; the
# codes match on purpose so a terminal cannot tell which side printed.
_RESET = "\x1b[0m"
_BOLD = "\x1b[1m"
_RED = "\x1b[31m"
_YELLOW = "\x1b[33m"
_GREEN = "\x1b[32m"
_CYAN = "\x1b[36m"
_DIM = "\x1b[90m"


def set_quiet(quiet: bool) -> None:
    """Enable quiet mode (only failures and the Finished line print)."""
    global _QUIET
    _QUIET = bool(quiet)


def is_quiet() -> bool:
    return _QUIET


def is_ci() -> bool:
    """True when running under GitHub Actions."""
    return os.environ.get("GITHUB_ACTIONS", "").lower() == "true"


def _color_override():
    """ORBIT_COLOR=always|never wins; anything else means auto-detect."""
    v = os.environ.get("ORBIT_COLOR", "").strip().lower()
    if v in ("always", "never"):
        return v
    return "auto"


def _auto_color(stream) -> bool:
    """True when styled output may go to stream. Mirrors doctor's rules."""
    if os.environ.get("NO_COLOR", "") != "":
        return False
    try:
        if not stream.isatty():
            return False
    except Exception:
        return False
    term = os.environ.get("TERM", "")
    if term == "dumb":
        return False
    if term == "":
        if os.environ.get("WT_SESSION", "") != "":
            return True
        if os.environ.get("ConEmuANSI", "") == "ON":
            return True
        return False
    for hint in ("color", "256", "xterm", "ansi"):
        if hint in term:
            return True
    return False


def _use_color(stream) -> bool:
    override = _color_override()
    if override == "always":
        return True
    if override == "never":
        return False
    return _auto_color(stream)


def _paint(code: str, msg: str, stream) -> str:
    if not _use_color(stream):
        return msg
    return code + msg + _RESET


def add_quiet(ap) -> None:
    """Add a --quiet flag wired to set_quiet (call after parse: set_quiet(args.quiet))."""
    ap.add_argument("--quiet", action="store_true",
                    help="only failures and the Finished line print")


def say(msg: str) -> None:
    """A progress or success line on stdout (suppressed in quiet mode)."""
    if not _QUIET:
        print(msg, flush=True)


def fail(msg: str) -> None:
    """A failure line on stderr (always prints, even in quiet mode)."""
    print(_paint(_RED, msg, sys.stderr), file=sys.stderr, flush=True)


def tip(msg: str) -> None:
    """A next-step hint on stderr (always prints, even in quiet mode)."""
    print(_paint(_YELLOW, "Tip: " + msg, sys.stderr), file=sys.stderr, flush=True)


def ci_error(msg: str) -> None:
    """A GitHub error annotation on stdout, only on CI (silent locally)."""
    if is_ci():
        print("::error::" + msg, flush=True)


def finish(tool: str, ok: int, total: int, extra: str = "") -> None:
    """The closing line on stdout, then the failures (if any) on stderr."""
    counts = f"{ok}/{total}"
    if _use_color(sys.stdout):
        code = _GREEN if total > 0 and ok == total else _RED
        counts = code + counts + _RESET
    line = f"Finished {tool}: {counts} pass"
    if extra:
        line += " " + extra
    print(line, flush=True)


def scrub_ci(text: str, limit: int = 3800) -> str:
    """Encode a payload for a ::error:: annotation (no raw newlines)."""
    return (text.replace("%", "%25").replace("\r", "%0D")
                 .replace("\n", "%0A")[:limit])
