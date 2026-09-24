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

Rules (see docs/COMMANDS.md, "Script output conventions"):
- successes and progress go to stdout; failures go to stderr;
- `::error::` annotations print only on GitHub Actions (GITHUB_ACTIONS);
- `--quiet` (via add_quiet) prints only failures and the Finished line;
- no colors, no emojis, no exclamation stacks.
"""

import os
import sys

_QUIET = False


def set_quiet(quiet: bool) -> None:
    """Enable quiet mode (only failures and the Finished line print)."""
    global _QUIET
    _QUIET = bool(quiet)


def is_quiet() -> bool:
    return _QUIET


def is_ci() -> bool:
    """True when running under GitHub Actions."""
    return os.environ.get("GITHUB_ACTIONS", "").lower() == "true"


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
    print(msg, file=sys.stderr, flush=True)


def tip(msg: str) -> None:
    """A next-step hint on stderr (always prints, even in quiet mode)."""
    print("Tip: " + msg, file=sys.stderr, flush=True)


def ci_error(msg: str) -> None:
    """A GitHub error annotation on stdout, only on CI (silent locally)."""
    if is_ci():
        print("::error::" + msg, flush=True)


def finish(tool: str, ok: int, total: int, extra: str = "") -> None:
    """The closing line on stdout, then the failures (if any) on stderr."""
    line = f"Finished {tool}: {ok}/{total} pass"
    if extra:
        line += " " + extra
    print(line, flush=True)


def scrub_ci(text: str, limit: int = 3800) -> str:
    """Encode a payload for a ::error:: annotation (no raw newlines)."""
    return (text.replace("%", "%25").replace("\r", "%0D")
                 .replace("\n", "%0A")[:limit])
