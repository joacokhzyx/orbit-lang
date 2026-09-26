#!/usr/bin/env python3
"""Route-argument normalization probe (STAB: Windows shell translation).

Under Git Bash on a Windows runner, MSYS2 rewrites any argument that looks
like an absolute POSIX path into a Windows path before a native program sees
it. That broke the Kynx live gate with

    Phase B failed: unexpected status "err:URL can't contain control
    characters. '/Program Files/Git/gate-burst' (found at least ' ')"

This probe pins the contract of scripts/orbit_routes.py so the repair cannot
regress: every tool that takes a route from the command line normalizes it
the same way, on every platform.

Usage:
    python scripts/routes_probe.py

Exits 0 iff every case matches.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
from orbit_routes import RoutePathError, normalize_route_path

# (name, raw, expected, must_raise)
CASES = [
    # Already-correct absolute routes pass through untouched.
    ("plain", "/health", "/health", False),
    ("burst", "/gate-burst", "/gate-burst", False),
    ("root", "/", "/", False),
    ("nested", "/v1/catalog/items", "/v1/catalog/items", False),
    # ':' param segments and escaped backslashes are legal route content.
    ("colon-param", "/notes/:id", "/notes/:id", False),
    ("brace-param", "/notes/{id}", "/notes/{id}", False),
    ("escaped-backslash", "/we\\ird\\path", "/we\\ird\\path", False),
    # A missing leading slash is added so both spellings are one route.
    ("no-leading-slash", "gate-burst", "/gate-burst", False),
    ("no-leading-slash-nested", "v1/notes", "/v1/notes", False),
    ("empty-uses-default", "", "/", False),
    ("none-uses-default", None, "/", False),
    # Duplicate separators collapse.
    ("double-slash", "//posts//1", "/posts/1", False),
    # The Git Bash / MSYS2 rewrite, in every shape it is observed. These are
    # the exact strings that reached the gate as 'C:/Program Files/Git/...'.
    ("msys-drive-forward", "C:/Program Files/Git/gate-burst", "/gate-burst", False),
    ("msys-drive-backslash", "C:\\Program Files\\Git\\gate-burst", "/gate-burst", False),
    ("msys-no-drive", "/Program Files/Git/gate-burst", "/gate-burst", False),
    ("msys-dos-drive", "/c/Program Files/Git/gate-burst", "/gate-burst", False),
    ("msys-x86", "/Program Files (x86)/Git/gate-burst", "/gate-burst", False),
    ("msys-lowercase-drive", "c:/program files/git/gate-burst", "/gate-burst", False),
    ("drive-only", "C:/health", "/health", False),
    ("msys-root-only", "/Program Files/Git/", "/", False),
    # Quoting a route must not change it.
    ("quoted", '"/gate-burst"', "/gate-burst", False),
    ("single-quoted", "'/gate-burst'", "/gate-burst", False),
    # Unrepairable input is rejected, never silently turned into a bad URL.
    ("spaces-unrepairable", "C:/some other place/x", None, True),
    ("bare-spaces", "gate burst", None, True),
    ("tab", "/gate\tburst", None, True),
    ("newline", "/gate\nburst", None, True),
    ("nul", "/gate\x00burst", None, True),
]


def roundtrip_cases():
    """The invariant that matters: translating a route and repairing it is a
    no-op. MSYS2 rewrites `/R` to `<Git install>/R`; normalize_route_path must
    map that back to `/R` for every route the tools accept, so no route is ever
    silently changed by the repair."""
    roots = ("C:/Program Files/Git", "C:/Program Files (x86)/Git",
             "/c/Program Files/Git", "/Program Files/Git",
             "C:\\Program Files\\Git")
    routes = ["/", "/health", "/gate-burst", "/v1/catalog/items", "/notes/:id",
              "/notes/{id}", "/we\\ird\\path", "/upload", "/loop"]
    return [(("roundtrip %s @ %s" % (r, root)), root + r, r, False)
            for root in roots for r in routes]


def main() -> int:
    cases = CASES + roundtrip_cases()
    ok = 0
    for name, raw, want, must_raise in cases:
        try:
            got = normalize_route_path(raw)
        except RoutePathError as e:
            if must_raise:
                out.say("Normalizing %s ... rejected as expected" % name)
                ok += 1
            else:
                out.fail("Failed %s: %r was rejected (%s)" % (name, raw, e))
            continue
        if must_raise:
            out.fail("Failed %s: %r accepted as %r but must be rejected" % (name, raw, got))
        elif got == want:
            out.say("Normalizing %s -> %s ... ok" % (name, got))
            ok += 1
        else:
            out.fail("Failed %s: %r normalized to %r, want %r" % (name, raw, got, want))
    out.finish("routes-probe", ok, len(cases))
    return 0 if ok == len(cases) else 1


if __name__ == "__main__":
    raise SystemExit(main())
