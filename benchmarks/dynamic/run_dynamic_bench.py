#!/usr/bin/env python3
"""Dynamic cross-language HTTP benchmark: Orbit vs Go vs Rust vs Node vs C.

Runs each server on its own loopback port, loads it with `hey` (3 rounds,
round-robin to reduce thermal/ordering bias), and prints a table with mean
req/s, stddev, and p50/p95 latency.  Every server serves the same hello-world
endpoint: GET / -> 200 OK, body "OK", Content-Type application/json.
"""

import os
import re
import statistics
import subprocess
import sys
import time

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(BASE, "..", ".."))
OUT = os.path.join(BASE, ".out")
ORBIT_EXE = os.path.join(ROOT, "zig-out", "bin", "orbit.exe")

CONCURRENCY = int(os.environ.get("ORBIT_BENCH_CONCURRENCY", "50"))
DURATION = os.environ.get("ORBIT_BENCH_DURATION", "5s")
ROUNDS = int(os.environ.get("ORBIT_BENCH_ROUNDS", "3"))

SERVERS = [
    {
        "name": "orbit",
        "port": 4100,
        "build": [ORBIT_EXE, "build", os.path.join(BASE, "orbit_server.orb"),
                  "-o", os.path.join(OUT, "orbit_server.exe")],
        "run": [os.path.join(OUT, "orbit_server.exe")],
        "notes": "N-worker select() loops (auto = CPU cores)",
    },
    {
        "name": "go",
        "port": 4101,
        "build": ["go", "build", "-o", os.path.join(OUT, "go_server.exe"),
                  os.path.join(BASE, "go_server.go")],
        "run": [os.path.join(OUT, "go_server.exe")],
        "notes": "net/http default (goroutines)",
    },
    {
        "name": "node",
        "port": 4102,
        "build": None,
        "run": ["node", os.path.join(BASE, "node_server.js")],
        "notes": "libuv event loop, single-thread",
    },
    {
        "name": "rust",
        "port": 4103,
        "build": ["cargo", "build", "--release",
                  "--manifest-path", os.path.join(BASE, "rust_server", "Cargo.toml")],
        "run": [os.path.join(OUT, "rust_server.exe")],
        "notes": "std TcpListener, thread-per-connection",
        "artifact": os.path.join(BASE, "rust_server", "target", "release", "rust_server.exe"),
    },
    {
        "name": "c",
        "port": 4104,
        "build": ["zig", "cc", "-O2", os.path.join(BASE, "c_server.c"),
                  "-o", os.path.join(OUT, "c_server.exe"), "-lws2_32"],
        "run": [os.path.join(OUT, "c_server.exe")],
        "notes": "single-thread select() event loop",
    },
]


def sh(cmd, timeout=300):
    print("  $ " + " ".join(cmd))
    # cwd=BASE so `orbit.atlas` (logs/kynx disabled for the benchmark) is picked up.
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=BASE)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise RuntimeError("command failed: " + " ".join(cmd))
    return r


def build_all():
    os.makedirs(OUT, exist_ok=True)
    for s in SERVERS:
        if s["build"] is None:
            continue
        print(f"Building {s['name']}...")
        sh(s["build"])
        if s.get("artifact"):
            import shutil
            shutil.copy2(s["artifact"], os.path.join(OUT, "rust_server.exe"))


def wait_ready(url, timeout=10.0):
    import urllib.request
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(url, timeout=1).read()
            return True
        except Exception:
            time.sleep(0.2)
    return False


def start_server(s):
    proc = subprocess.Popen(s["run"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ok = wait_ready(f"http://127.0.0.1:{s['port']}/")
    if not ok:
        proc.kill()
        raise RuntimeError(f"server {s['name']} never became ready")
    return proc


def run_hey(s):
    url = f"http://127.0.0.1:{s['port']}/"
    cmd = ["hey", "-z", DURATION, "-c", str(CONCURRENCY), url]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(f"hey failed for {s['name']}: {r.stderr[:500]}")
    out = r.stdout
    m = re.search(r"Requests/sec:\s*([\d.]+)", out)
    if not m:
        raise RuntimeError(f"hey output parse failed for {s['name']}")
    rps = float(m.group(1))
    p50 = p95 = 0.0
    for line in out.splitlines():
        mm = re.match(r"\s*(\d+)%%?\s+in\s+([\d.]+)\s+secs", line)
        if mm:
            pct = int(mm.group(1))
            lat_ms = float(mm.group(2)) * 1000.0
            if pct == 50:
                p50 = lat_ms
            elif pct == 95:
                p95 = lat_ms
    return {"rps": rps, "p50_ms": p50, "p95_ms": p95}


def main():
    build_all()
    results = {s["name"]: [] for s in SERVERS}

    warmup_procs = []
    for s in SERVERS:
        warmup_procs.append((s, start_server(s)))
    print("warmup (2s each)...")
    for s, proc in warmup_procs:
        subprocess.run(["hey", "-z", "2s", "-c", str(CONCURRENCY), f"http://127.0.0.1:{s['port']}/"],
                       capture_output=True, timeout=60)
        proc.kill()
        proc.wait()
    del warmup_procs

    for round_no in range(ROUNDS):
        for s in SERVERS:
            proc = start_server(s)
            try:
                res = run_hey(s)
            finally:
                proc.kill()
                proc.wait()
            results[s["name"]].append(res)
            print(f"  round {round_no + 1} {s['name']}: {res['rps']:.0f} req/s  "
                  f"p50={res['p50_ms']:.3f}ms p95={res['p95_ms']:.3f}ms")

    header = ("| Server | Req/s (mean \u00b1 std) | p50 (ms) | p95 (ms) | Notes |\n"
              "|---|---|---|---|---|\n")
    lines = [header]
    for s in SERVERS:
        rs = results[s["name"]]
        rps = [r["rps"] for r in rs]
        p50 = statistics.mean(r["p50_ms"] for r in rs)
        p95 = statistics.mean(r["p95_ms"] for r in rs)
        mean = statistics.mean(rps)
        stdev = statistics.stdev(rps) if len(rps) > 1 else 0.0
        lines.append(f"| {s['name']} | {mean:,.0f} \u00b1 {stdev:,.0f} | {p50:.3f} | {p95:.3f} | {s['notes']} |\n")

    print("\n=== RESULTS ===")
    for line in lines:
        print(line, end="")

    report_path = os.path.join(BASE, "results.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write("# Dynamic HTTP benchmark (hello-world)\n\n")
        f.write(f"- Load: `hey -z {DURATION} -c {CONCURRENCY}`, {ROUNDS} rounds per server, round-robin\n")
        f.write(f"- Endpoint: GET / -> 200 OK, body \"OK\", Content-Type application/json\n")
        f.write(f"- Date: {time.strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        f.writelines(lines)
    print(f"\nReport written to {report_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())