#!/usr/bin/env python3
"""Gate: every probe program must compile AND run clean under -Werror.

Covers expression-shaped, IO-shaped, server-shaped (route table only),
db-shaped (SQLite, skipped if unavailable), and builtin-heavy probes.
Usage: python scripts/werror_gate.py [--compiler PATH] [--cc gcc] [--list]
"""
import argparse, os, subprocess, sys, tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = Path(__file__).resolve().parent.parent
PROBES = [
    ("arith", "fn main() -> int {\n    return (6 * 7) + 1 - 1\n}", 42),
    ("string_eq", 'fn main() -> int {\n    val a = "orbit"\n    val b = "orb" + "it"\n    if a == b {\n        return 5\n    }\n    return 6\n}', 5),
    ("while_loop", "fn main() -> int {\n    var i = 0\n    while i < 5 {\n        i = i + 1\n    }\n    return i\n}", 5),
    ("try_ok", "fn make_success() -> result {\n    val value: result = ok(41)\n    return value\n}\nfn main() -> int {\n    make_success()\n    return 1\n}", 1),
    ("try_catch", 'fn make_failure() -> result {\n    val value: result = err("invalid input", 7)\n    return value\n}\nfn read_failure() -> int {\n    val value: int = try make_failure() catch {\n        return 7\n    }\n    return value\n}\nfn main() -> int {\n    return read_failure()\n}', 7),
    ("string_ops", 'fn main() -> int {\n    val s = "ab" + "cd"\n    return s.len()\n}', 4),
    ("http_routes", 'fn helper() -> int {\n    return 5\n}\nroute GET "/p" {\n    val n = helper()\n    val s = "n=" + n\n    return ok 200 s\n}\nfn main() -> int {\n    return 0\n}', "serve",
     ("-DORBIT_WITH_NET",)),
    ("bool_logic", "fn main() -> int {\n    if 1 < 2 && 2 < 3 {\n        return 5\n    }\n    return 6\n}", 5),
    ("model_ctor", "model Rect {\n    width: int\n    height: int\n}\nfn main() -> int {\n    val r = Rect(3, 4)\n    return r.width + r.height\n}", 7),
    # A nested object literal is the only construct that reaches
    # orbit_object_set_object: the setter is chosen by the value register's
    # type, and "object" is only the type of a field whose value is itself a
    # literal. The cast chain in c_backend.orb had an arm each for int, float
    # and bool and fell through to (const char*) for everything after them, so
    # this one line handed a const char* to an OrbitObject* parameter. Every
    # other probe here is a model, a route or an arithmetic expression, so
    # STAB-3 never reached it and the language suite was the only red thing --
    # on the toolchains that promote the warning, and only on those.
    ("object_literal_nested", 'fn main() -> int {\n    val o = { deep: { deeper: 7 } }\n    return o.deep.deeper\n}', 7),
    # A response body reaches orbit_response_json as a `const char*`. Sema can
    # only reject a body whose type it can prove, so an expression inferring as
    # `unknown` used to arrive as a bare register and hand an int to a pointer
    # parameter -- the int-to-pointer conversion this gate exists to catch, and
    # a segfault on the first request. A mismatched arithmetic expression is the
    # shape no type rule can pin down, which is why the fix converts by the
    # register type the backend settled on instead of by what sema guessed.
    ("response_body_unknown_type", "fn body() -> response {\n    return ok 200 1 + true\n}\nfn main() -> int {\n    body()\n    return 0\n}", 0,
     ("-DORBIT_WITH_NET",)),
]

def tail_with_head(text, limit=1200):
    r"""Keep the head of a compiler's output, not the tail.

    This gate existed for five consecutive CI runs to report a failure whose
    cause was invisible in its own output. clang puts the diagnostic on the
    FIRST line -- "'getenv': This function or variable may be unsafe" -- and
    then four lines of note: chain showing which macro in which MSVC header
    expanded it. Keeping the last 600 characters kept the notes and threw away
    the sentence naming the function, so the log said

        Failed arith [WERROR-FAIL]: ...icrosoft Visual Studio\...vcruntime.h:358

    which is the middle of a filename. A gate that cannot show its own
    diagnostic is a gate that cannot be acted on, and the whole run went red
    five times over a cause nobody could read.

    So: the head is kept, because that is where the answer is, and the tail is
    kept too when the output is long enough that the head alone would lose the
    summary.
    """
    if len(text) <= limit:
        return text
    head = text[:limit - 200]
    tail = text[-200:]
    return head + "\n... [%d characters elided] ...\n" % (len(text) - limit) + tail


def run_probe(compiler, cc, name, src, expect, extra_flags=()):
    with tempfile.TemporaryDirectory(prefix="werror_") as td:
        td = Path(td)
        (td / "main.orb").write_text(src)
        env = dict(os.environ)
        env.update({"TEMP": str(td), "TMP": str(td)})
        p1 = subprocess.run([str(compiler), "build", str(td / "main.orb"),
                             "-o", str(td / "app.exe")], env=env,
                            capture_output=True, text=True, errors="replace")
        if p1.returncode != 0:
            return (name, "ORBIT-FAIL", tail_with_head(p1.stdout + p1.stderr, 900))
        c_file = td / "orbit_selfhost_build.c"
        if not c_file.exists():
            return (name, "NO-C", "orbit build left no orbit_selfhost_build.c in TEMP")
        exe = td / "app_checked.exe"
        link_flags = ["-lws2_32"] if os.name == "nt" else []
        # No -s here. It is a link-time strip for a binary this gate builds,
        # runs and throws away, so it bought nothing, and it is not portable:
        # gcc and clang-on-Linux accept it, but clang's Windows/MSVC driver
        # rejects it outright, which under -Werror surfaced as
        # "argument unused during compilation: '-s'" and failed all 9 probes.
        p2 = subprocess.run([cc, "-O0", "-Werror", "-I", str(ROOT / "runtime")]
                            + list(extra_flags) + [str(c_file)] + link_flags + [
                             "-o", str(exe)], capture_output=True, text=True, errors="replace",
                            cwd=str(ROOT))
        if p2.returncode != 0:
            return (name, "WERROR-FAIL", tail_with_head(p2.stdout + p2.stderr, 1400))
        try:
            p3 = subprocess.run([str(exe)], capture_output=True, text=True, errors="replace",
                                timeout=15)
        except subprocess.TimeoutExpired:
            if expect == "serve":
                return (name, "OK", "server kept running past 15s, -Werror compile clean")
            return (name, "EXIT-FAIL", "timed out after 15s")
        if p3.returncode != expect:
            return (name, "EXIT-FAIL", f"exit={p3.returncode} want={expect}")
        return (name, "OK", f"exit={p3.returncode}")

def self_test():
    """The gate's own reporting, checked.

    This gate went red five times in a row on Windows without anybody being
    able to read why, because it kept the tail of clang's output and clang
    writes the diagnostic on the first line. A gate that cannot show its own
    failure is a gate that cannot be acted on, so the truncation is now a
    function with a test, and the test is the thing that would have caught it
    in the first run instead of the fifth.
    """
    fails = 0

    def check(label, ok):
        nonlocal fails
        if ok:
            out.say(f"  ok    {label}")
        else:
            out.fail(f"  BROKEN {label}")
            fails += 1

    # The exact shape that hid the cause: a one-line diagnostic, then notes.
    diagnostic = "'getenv': This function or variable may be unsafe. Consider using _dupenv_s instead.\n"
    notes = ("C:\\...\\vcruntime.h:358:55: note: expanded from macro '_CRT_INSECURE_DEPRECATE'\n"
             "  358 | #define _CRT_INSECURE_DEPRECATE(_Replacement) _CRT_DEPRECATE_TEXT(\n"
             "1 error generated.\n")
    noise = notes + ("filler line about something unrelated\n" * 200)

    got = tail_with_head(diagnostic + noise, 1400)
    check("the diagnostic line survives truncation", diagnostic.strip() in got)
    check("the summary survives too", "1 error generated" in got)
    check("the middle is elided rather than silently dropped",
          "elided" in got)

    # Short output must come back untouched, or the elision marker would show
    # up on every probe that passes.
    short = "one line\n"
    check("short output is returned unchanged", tail_with_head(short, 1400) == short)

    # The old behaviour is the bug, so assert it is gone rather than only
    # asserting the new behaviour is present.
    old = (diagnostic + noise)[-600:]
    check("the tail-only behaviour this replaced would have lost it",
          diagnostic.strip() not in old)

    # And a null/empty input must not explode: a probe that produced no output
    # is a real case, not a hypothetical one.
    check("empty input does not raise", tail_with_head("", 1400) == "")

    out.finish("werror gate self-test", 6 - fails, 6)
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", default=str(ROOT / "orbit.exe"))
    ap.add_argument("--cc", default="gcc")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.list:
        for probe in PROBES:
            print(probe[0])
        return 0
    fails = 0
    for probe in PROBES:
        name, src, expect = probe[0], probe[1], probe[2]
        flags = probe[3] if len(probe) > 3 else ()
        name, status, detail = run_probe(args.compiler, args.cc, name, src, expect, flags)
        if status == "OK":
            out.say(f"Checking {name} ... ok ({detail})")
        else:
            out.fail(f"Failed {name} [{status}]: {detail}")
            fails += 1
    out.finish("werror", len(PROBES) - fails, len(PROBES))
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
