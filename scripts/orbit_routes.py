#!/usr/bin/env python3
"""Shared route-path normalization for Orbit repo scripts.

Every tool that takes a route as a command-line argument must survive the
MSYS2 / Git Bash argument translation that happens on Windows CI runners.
Under `shell: bash` the MSYS2 runtime rewrites any argument that looks like
an absolute POSIX path into a Windows path before handing it to a native
program, so

    python scripts/kynx_route_limit_gate.py --burst-path /gate-burst

reaches the script as

    --burst-path C:/Program Files/Git/gate-burst

and the built URL then fails with
"URL can't contain control characters ... (found at least ' ')".

The translation is a prefix rewrite, so the route the caller meant survives
untouched at the end of the argument. This module strips that prefix back off.
Callers should ALSO export MSYS2_ARG_CONV_EXCL/MSYS_NO_PATHCONV so the
rewrite never happens; this is the second line of defence for invocations that
cannot set the environment (bare "python foo.py --path /x" in a user's shell,
a task runner, a container entrypoint).

Rules:
- a missing leading slash is added, so "--path health" and "--path /health"
  are the same route;
- a drive letter and a recognized MSYS/Git installation root are removed,
  keeping the tail byte-for-byte (route literals may legitimately contain
  backslashes, see tests/parity/probes/r15_route_quote.orb, so the tail is
  never rewritten);
- anything still carrying whitespace or a control character is REJECTED with
  an actionable message rather than silently repaired;
- ":" and "\" are valid in a route (":id" params, escaped literals) and are
  never treated as errors.
"""

import re

# Installation roots the MSYS2 runtime may prepend, longest first so that
# "program files (x86)/git" wins over "program files/git".
_MSYS_ROOTS = (
    "program files (x86)/git",
    "program files/git",
    "program/git/mingw64/bin",
    "git/mingw64/bin",
    "mingw64/bin",
    "msys64/usr/bin",
    "msys64/mingw64/bin",
    "usr/bin",
)

_DRIVE_RE = re.compile(r"^[A-Za-z]:")


class RoutePathError(ValueError):
    """Raised when a route argument cannot be repaired into a valid path."""


def _strip_msys_prefix(raw: str) -> str:
    """Remove a drive letter and/or MSYS2/Git installation prefix.

    Detection is conservative: a value is only treated as translated when it
    carries a drive letter or contains whitespace, because no valid route can
    contain whitespace. The returned tail is sliced out of `raw` unchanged.
    """
    if not (_DRIVE_RE.match(raw) or any(c.isspace() for c in raw)):
        return raw
    probe = raw.replace("\\", "/").lower()
    best = -1
    best_root = ""
    for root in _MSYS_ROOTS:
        idx = probe.rfind(root)
        if idx > best:
            best, best_root = idx, root
    if best >= 0:
        cut = best + len(best_root)
    else:
        # No installation root: drop the drive letter only, so "C:/health"
        # (what some other translation layers emit) reads as "/health".
        m = _DRIVE_RE.match(raw)
        cut = m.end() if m else 0
    return raw[cut:].lstrip("/ \t\\")


def normalize_route_path(raw, default: str = "/", what: str = "route path") -> str:
    """Return `raw` as an absolute route path, or raise RoutePathError.

    `raw` may be None or empty, in which case `default` is used.
    """
    if raw is None:
        raw = ""
    value = str(raw).strip().strip("\"'")
    if not value:
        value = default
    value = _strip_msys_prefix(value).strip()
    if not value:
        value = "/"
    if not value.startswith("/"):
        value = "/" + value
    value = re.sub(r"/{2,}", "/", value)
    bad = [c for c in value if c.isspace() or ord(c) < 0x20 or ord(c) == 0x7F]
    if bad:
        raise RoutePathError(
            "%s %r contains whitespace or control characters (from %r). "
            "Pass the route without a drive-letter or installation prefix, "
            "e.g. --path health, and export MSYS_NO_PATHCONV=1 on Windows shells."
            % (what, value, raw)
        )
    return value


def main(argv=None) -> int:
    import sys

    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        print("usage: orbit_routes.py PATH [PATH...]", file=sys.stderr)
        return 2
    rc = 0
    for a in args:
        try:
            print(normalize_route_path(a))
        except RoutePathError as e:
            print("Failed: %s" % e, file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
