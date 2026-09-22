#!/usr/bin/env python3
"""Kynx C6 load gate: per-route limits under live traffic (needs a live server).

    <orbit_fp> build examples/blog_api.orb -o blog_api_c6[.exe]
    ./blog_api_c6 4102
    python scripts/kynx_route_limit_gate.py --port 4102

Phase A (healthy): 200 requests @ ~10 rps via night_load.py -> zero errors.
Phase B (burst): 25 rapid sequential GETs -> >=1 x 429 from the ROUTE bucket
    (25 < global 50-burst, so any 429 is route-level) with Retry-After.
Phase C (no ban): after 2 s, 5 sequential GETs -> all 200 (a ban would 429
    for 5 minutes).

Exit 0 iff all phases pass. Server lifecycle stays with the operator.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NIGHT_LOAD = os.path.join(ROOT, "scripts", "night_load.py")


def get(url, timeout=5.0):
    """One GET; return (status, retry_after_or_None, body_bytes)."""
    req = urllib.request.Request(url, headers={"Connection": "close"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, None, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Retry-After"), e.read()
    except Exception as e:
        return "err:%s" % e, None, b""


def phase_a(args):
    tmp = os.path.join(tempfile.mkdtemp(prefix="kynx_gate_"), "a.json")
    proc = subprocess.run(
        [sys.executable, NIGHT_LOAD, "--host", args.host, "--port", str(args.port),
         "--path", args.path, "--connections", "2", "--requests", "200",
         "--rps", "10", "--warmup", "0", "--json", tmp],
        capture_output=True, text=True, errors="replace",
    )
    print(proc.stdout.strip())
    if proc.returncode != 0:
        print("[gate-A] FAIL: night_load rc=%d" % proc.returncode)
        print((proc.stderr or "").strip()[-500:])
        return False
    with open(tmp, encoding="utf-8") as f:
        rep = json.load(f)
    ok = rep.get("completed") == 200 and rep.get("error_rate") == 0.0
    print("[gate-A] completed=%s error_rate=%s status=%s -> %s" % (
        rep.get("completed"), rep.get("error_rate"),
        rep.get("status_counts"), "PASS" if ok else "FAIL"))
    return ok


def phase_b(args):
    url = "http://%s:%d%s" % (args.host, args.port, args.path)
    ok200 = 0
    deny429 = 0
    retry_after = None
    bad_body = 0
    for _ in range(25):
        status, ra, body = get(url)
        if status == 200:
            ok200 += 1
        elif status == 429:
            deny429 += 1
            if retry_after is None:
                retry_after = ra
            if body != b"429 Too Many Requests - Kynx admission control":
                bad_body += 1
        else:
            print("[gate-B] FAIL: unexpected status %r" % (status,))
            return False
    try:
        ra_s = int((retry_after or "").strip())
    except ValueError:
        ra_s = -1
    ok = deny429 >= 1 and ok200 + deny429 == 25 and ra_s >= 1 and bad_body == 0
    print("[gate-B] ok=%d denied=%d retry_after=%r bad_body=%d -> %s" % (
        ok200, deny429, retry_after, bad_body, "PASS" if ok else "FAIL"))
    return ok


def phase_c(args):
    time.sleep(2.0)
    url = "http://%s:%d%s" % (args.host, args.port, args.path)
    results = [get(url)[0] for _ in range(5)]
    ok = all(s == 200 for s in results)
    print("[gate-C] post-burst statuses=%s -> %s" % (results, "PASS" if ok else "FAIL"))
    return ok


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Kynx C6 live load gate")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4102)
    ap.add_argument("--path", default="/health")
    args = ap.parse_args(argv)
    a = phase_a(args)
    b = phase_b(args) if a else False
    c = phase_c(args) if b else False
    print("[gate] RESULT: %s" % ("PASS" if (a and b and c) else "FAIL"))
    return 0 if (a and b and c) else 1


if __name__ == "__main__":
    raise SystemExit(main())
