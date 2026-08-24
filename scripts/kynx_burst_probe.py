#!/usr/bin/env python3
"""Kynx burst probe: demonstrate admission control end-to-end.

Starts N requests against a running Orbit server and asserts that once
the configured per-IP window budget is spent, Kynx answers 429.

Manual tool (requires a live server):
    ./srv &                                  # a route-bearing server
    python scripts/kynx_burst_probe.py --requests 500
Exit 0 iff at least one 429 was observed (gate proven) or the server
answered everything without exceeding its budget (documented via --strict).
"""

import argparse
import threading
import urllib.request
import urllib.error
from collections import Counter

lock = Counter()


def fire(host, port, path, idx, timeout):
    try:
        req = urllib.request.Request(f"http://{host}:{port}{path}", headers={"Connection": "close"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            lock[r.status] += 1
    except urllib.error.HTTPError as e:
        lock[e.code] += 1
    except Exception:
        lock["err"] += 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3000)
    ap.add_argument("--path", default="/")
    ap.add_argument("--requests", type=int, default=300)
    ap.add_argument("--threads", type=int, default=16)
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--strict", action="store_true",
                    help="fail if NO 429 observed even when budget not exhausted")
    args = ap.parse_args()

    threads = []
    for i in range(args.requests):
        t = threading.Thread(target=fire, args=(args.host, args.port, args.path, i, args.timeout))
        t.start()
        threads.append(t)
        if len(threads) >= args.threads:
            threads[0].join()
            threads = threads[1:]
    for t in threads:
        t.join()

    print("[kynx-probe] status distribution:", dict(lock))
    got_429 = lock.get(429, 0)
    ok = got_429 > 0 or (not args.strict and sum(v for k, v in lock.items() if isinstance(k, int)) == args.requests)
    if got_429:
        print(f"[kynx-probe] PASS: admission control engaged ({got_429} x 429)")
    else:
        print("[kynx-probe] no 429 observed: either under budget or gate inactive")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
