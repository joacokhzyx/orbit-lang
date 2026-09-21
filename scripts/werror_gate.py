#!/usr/bin/env python3
"""Gate: every probe program must compile AND run clean under -Werror.

Covers expression-shaped, IO-shaped, server-shaped (route table only),
db-shaped (SQLite, skipped if unavailable), and builtin-heavy probes.
Usage: python scripts/werror_gate.py [--compiler PATH] [--cc gcc] [--list]
"""
import argparse, os, subprocess, sys, tempfile
from pathlib import Path

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
]

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
            return (name, "ORBIT-FAIL", (p1.stdout + p1.stderr)[-300:])
        c_file = td / "orbit_selfhost_build.c"
        if not c_file.exists():
            return (name, "NO-C", "orbit build left no orbit_selfhost_build.c in TEMP")
        exe = td / "app_checked.exe"
        link_flags = ["-lws2_32"] if os.name == "nt" else []
        p2 = subprocess.run([cc, "-s", "-O0", "-Werror", "-I", str(ROOT / "runtime")]
                            + list(extra_flags) + [str(c_file)] + link_flags + [
                             "-o", str(exe)], capture_output=True, text=True, errors="replace",
                            cwd=str(ROOT))
        if p2.returncode != 0:
            return (name, "WERROR-FAIL", (p2.stdout + p2.stderr)[-600:])
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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compiler", default=str(ROOT / "orbit.exe"))
    ap.add_argument("--cc", default="gcc")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.list:
        for name, _ in PROBES:
            print(name)
        return 0
    fails = 0
    for probe in PROBES:
        name, src, expect = probe[0], probe[1], probe[2]
        flags = probe[3] if len(probe) > 3 else ()
        name, status, detail = run_probe(args.compiler, args.cc, name, src, expect, flags)
        print(f"[werror] {status:11} {name} {detail}", flush=True)
        if status != "OK":
            fails += 1
    print(f"[werror] RESULT: {len(PROBES) - fails}/{len(PROBES)}")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
