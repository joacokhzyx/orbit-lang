#!/usr/bin/env python3
"""Build a real service, start it, and burst a guarded route at it.

The only gate in this repository that runs the compiler's whole product: it
builds `examples/blog_api.orb` with the fixed-point compiler, starts the binary,
waits for it to answer, and fires a burst at `/gate-burst` to check the Kynx
sharded rate limiter answers with the limit rather than letting everything
through. Everything else in CI reasons about the compiler or about text.

It was twenty-five lines of shell in ci-gate.yml: the build, the backgrounding,
the readiness loop, the `trap` to kill the server, and the `cp` of sqlite3.dll
that Windows needs. Two of those are the kind of thing that quietly stops
happening -- a `trap` that never fires when the script is killed by the runner,
a readiness loop that waits on the wrong port after someone changes one -- and
none of it was runnable by hand.

So it is a script, and it is in `make kynx`, which is the point: this is the
gate that proves Orbit builds a working server, and being unable to run it
locally is how a compiler ends up green on every unit test and broken in the
only way that matters.

Unlike `runtime_c_tests.py` this one needs the Orbit compiler, which is why it
is not in T0. It uses the fixed point at the path `dev.py` owns; pass `--compiler`
to point it elsewhere.
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_PORT = 4102
READY_ATTEMPTS = 30


def wait_ready(port: int, attempts: int = READY_ATTEMPTS) -> bool:
    """Poll /health until the server answers or the attempts run out.

    urllib rather than curl: one less dependency for the same thing, and the
    failure mode is a message either way. `except (urllib.error.URLError,
    ConnectionError)` covers the two that actually happen while a process is
    coming up -- refused before it binds, and reset if it dies mid-probe.
    """
    url = f"http://127.0.0.1:{port}/health"
    for _ in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                if r.status == 200:
                    return True
        except (urllib.error.URLError, ConnectionError, OSError):
            pass
        time.sleep(1)
    return False


def stage_sqlite(workdir: pathlib.Path) -> None:
    """Windows needs sqlite3.dll beside the server binary."""
    if os.name != "nt":
        return
    dll = ROOT / "runtime" / "vendor" / "win-x64" / "sqlite3.dll"
    if dll.exists():
        shutil.copyfile(dll, workdir / "sqlite3.dll")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--compiler", default=None,
                    help="the orbit binary (default: ask scripts/dev.py)")
    ap.add_argument("--cc", default=os.environ.get("ORBIT_CC") or "gcc")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--burst-path", default="/gate-burst")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        # The readiness loop must be able to say "not ready" without waiting the
        # full 30 seconds, or a dead server costs half a minute of CI to report.
        started = time.monotonic()
        ready = wait_ready(1, attempts=2)
        elapsed = time.monotonic() - started
        if ready:
            print("self-test FAILED: something answered on 127.0.0.1:1")
            return 1
        if elapsed > 12:
            print(f"self-test FAILED: the readiness loop took {elapsed:.0f}s for "
                  f"2 attempts; it is not honouring the attempt count")
            return 1
        print("Finished kynx-gate self-test: the readiness loop reports "
              "'not ready' in bounded time.")
        return 0

    compiler = args.compiler
    if not compiler:
        proc = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "dev.py"), "fp-path"],
            capture_output=True, text=True)
        compiler = proc.stdout.strip()
        if not compiler or not pathlib.Path(compiler).exists():
            print("Failed: no orbit compiler. Run `make fp`, or pass --compiler.",
                  file=sys.stderr)
            return 2

    work = ROOT / ".orbit" / "work" / "kynx"
    work.mkdir(parents=True, exist_ok=True)
    stage_sqlite(work)
    suffix = ".exe" if os.name == "nt" else ""
    srv = work / ("gate_srv" + suffix)

    env = dict(os.environ)
    env["ORBIT_CC"] = args.cc
    build = subprocess.run(
        [compiler, "build", "examples/blog_api.orb", "-o", str(srv)],
        cwd=str(ROOT), env=env, capture_output=True, text=True)
    sys.stdout.write(build.stdout)
    sys.stderr.write(build.stderr)
    if build.returncode != 0 or not srv.exists():
        print("Failed: blog_api.orb did not build.", file=sys.stderr)
        return 1

    proc = subprocess.Popen([str(srv), str(args.port)], cwd=str(ROOT),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True)
    try:
        if not wait_ready(args.port):
            print(f"Failed: the gate server on port {args.port} never became "
                  f"ready.", file=sys.stderr)
            return 1
        gate = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "kynx_route_limit_gate.py"),
             "--port", str(args.port), "--burst-path", args.burst_path],
            capture_output=True, text=True)
        sys.stdout.write(gate.stdout)
        sys.stderr.write(gate.stderr)
        if gate.returncode != 0:
            print(f"\nFinished kynx-gate: FAILED (exit {gate.returncode})")
            return 1
    finally:
        # Always, including on an exception. The shell used a `trap ... EXIT`,
        # which does not fire when the runner kills the step.
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()

    print("\nFinished kynx-gate: the route-limit burst answered as specified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())