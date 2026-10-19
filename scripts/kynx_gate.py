#!/usr/bin/env python3
"""Kynx live gates and load tools: one file, four subcommands.

This used to be four scripts that all assumed a live Orbit server:

  scripts/kynx_live_gate.py        build a service, start it, burst it (the gate)
  scripts/kynx_route_limit_gate.py three phases against a running server
  scripts/kynx_burst_probe.py      manual burst probe, needs a live server
  scripts/night_load.py            stdlib-only TCP HTTP/1.1 keep-alive load generator

They are one tool now because three of the four only ever ran as phases of
the first: the live gate built the server and then shelled out to the
route-limit gate, which shelled out to the load generator. Two nested
subprocess hops to call code that lives in the same directory, with stdout
forwarded line by line. The subcommands keep their flags and their output;
what changed is that phases are function calls now, not processes.

Subcommands:

  live          build examples/blog_api.orb, start it, run route-limit at it.
                Then a service that declares its own port: started with no
                argv it must bind the declared port, and an argv port must
                still win. Then a request above the Kynx lease: it must be
                answered 503, and the service must keep serving, because a
                refusal at the request boundary is one failed request and not
                a dead process. The only gate here that runs the compiler's
                whole product.
  route-limit   three phases against a RUNNING server (operator starts it):
                A) 200 requests @ ~10 rps, zero errors;
                B) 25 rapid GETs at the guarded route -> >=1 x 429 with
                   Retry-After (route-level, under the global burst);
                C) after 2 s, 5 GETs -> all 200 (no ban).
  burst         manual burst probe against a running server.
  load          the stdlib-only load generator (no third-party dependencies).

`--self-test` runs every subcommand's core against a dead port and asserts
each fails cleanly and fast: a probe that hangs or throws a traceback when
its target is gone is a probe that cannot be trusted when its target is
there.
"""

import argparse
import contextlib
import io
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
from orbit_routes import RoutePathError, normalize_route_path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PORT = 4102
READY_ATTEMPTS = 30


# --------------------------------------------------------------------------
# Shared: server lifecycle and one-GET helpers.
# --------------------------------------------------------------------------
def wait_ready(port: int, attempts: int = READY_ATTEMPTS) -> bool:
    """Poll /health until the server answers or the attempts run out.

    urllib rather than curl: one less dependency for the same thing, and the
    failure mode is a message either way. `except (urllib.error.URLError,
    ConnectionError)` covers the two that actually happen while a process is
    coming up -- refused before it binds, and reset if it dies mid-probe.
    """
    url = f"http://127.0.0.1:{port}/health"
    for i in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=1) as r:
                if r.status == 200:
                    return True
        except (urllib.error.URLError, ConnectionError, OSError):
            pass
        # No sleep after the last attempt: the verdict is already known.
        # timeout=1 (not 2): a healthy local /health answers in ms; only a
        # hung or dead server ever reaches the timeout, and failing fast
        # there is the point.
        if i < attempts - 1:
            time.sleep(1)
    return False


def stage_sqlite(workdir: pathlib.Path) -> None:
    """Windows needs sqlite3.dll beside the server binary."""
    if os.name != "nt":
        return
    dll = pathlib.Path(ROOT) / "runtime" / "vendor" / "win-x64" / "sqlite3.dll"
    if dll.exists():
        shutil.copyfile(dll, workdir / "sqlite3.dll")


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


def url_for(host, port, path):
    return "http://%s:%d%s" % (host, port, normalize_route_path(path))


# --------------------------------------------------------------------------
# load: stdlib-only TCP HTTP/1.1 keep-alive load generator.
#
# Shared infra for the night-speed crew. No third-party dependencies.
#
# Each worker thread owns one persistent TCP connection (HTTP/1.1
# keep-alive) and issues requests sequentially. Latency is measured with
# time.perf_counter around send+receive of a single response.
#
# Error model: a request counts as failed when the transport breaks OR the
# response status is not 2xx (per-IP rate limiters answer 429, which must
# show up in error_rate instead of being silently counted as success).
#
# Source IPs: by default every connection originates from the loopback
# address the OS picks (127.0.0.1). With --source-ips N, connections bind
# round-robin to 127.0.0.2..127.0.(N+1) so the load simulates N distinct
# clients against per-IP admission control. Warmup always uses the
# unbound address, keeping the measurement pool's per-IP budgets intact.
#
# Output: human table on stdout plus optional JSON (--json out.json).
# Exit codes: 0 ok, 1 measured nothing or usage error via argparse (2).
# --------------------------------------------------------------------------
def percentile(sorted_vals, pct):
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return float(sorted_vals[0])
    k = (len(sorted_vals) - 1) * (pct / 100.0)
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    if f == c:
        return float(sorted_vals[f])
    return float(sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f))


def recv_exact(sock, n, buf):
    """Read exactly n bytes (body) using leftover buffer first."""
    while len(buf) >= n:
        chunk = buf[:n]
        del buf[:n]
        return chunk
    data_out = bytearray(buf)
    del buf[:]
    while len(data_out) < n:
        data = sock.recv(n - len(data_out))
        if not data:
            raise ConnectionError("closed while reading body")
        data_out.extend(data)
    return bytes(data_out)


def read_response(sock, buf):
    """Read one HTTP/1.1 response; return (status_code, body_len)."""
    # Read until end of headers.
    while True:
        idx = buf.find(b"\r\n\r\n")
        if idx >= 0:
            break
        data = sock.recv(16384)
        if not data:
            raise ConnectionError("closed while reading headers")
        buf.extend(data)
    hdr_end = buf.find(b"\r\n\r\n")
    hdr = bytes(buf[:hdr_end])
    del buf[:hdr_end + 4]
    # Status line: HTTP/1.1 200 OK
    first_crlf = hdr.find(b"\r\n")
    status_line = hdr if first_crlf < 0 else hdr[:first_crlf]
    parts = status_line.split(b" ", 2)
    status = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 0
    # Content-Length (default 0).
    content_length = 0
    for line in hdr.split(b"\r\n")[1:]:
        if line[:15].lower() == b"content-length:":
            try:
                content_length = int(line[15:].strip() or 0)
            except ValueError:
                content_length = 0
            break
    if content_length > 0:
        recv_exact(sock, content_length, buf)
    return status, content_length


def open_connection(host, port, timeout, src_ip=None):
    """Connect to (host, port), optionally binding the source address first."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        if src_ip is not None:
            sock.bind((src_ip, 0))
        sock.settimeout(timeout)
        sock.connect((host, port))
    except OSError:
        sock.close()
        raise
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass
    return sock


def worker(idx, args, stop_at, max_reqs, latencies, transport, status_counts, lock, req_counter):
    """One keep-alive connection. In --requests mode each thread owns a fixed
    quota (no shared counter), so per-connection counts are exact and
    per-IP admission budgets stay predictable. Duration mode shares a
    global counter instead."""
    req = (
        "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: keep-alive\r\n"
        "User-Agent: night_load/1.0\r\nAccept: */*\r\n\r\n"
        % (args.method, args.path, args.host)
    ).encode()
    buf = bytearray()
    local_lat = []
    local_transport = 0
    local_status = {}
    src_ip = None
    if args.source_ips > 0:
        src_ip = "127.0.0.%d" % (2 + (idx % args.source_ips))
    # Fixed quota in --requests mode; shared counter in duration mode.
    quota = None
    if args.requests > 0:
        per, rem = divmod(args.requests, args.connections)
        quota = per + (1 if idx < rem else 0)
    # Optional pacing: spread this connection's requests so the aggregate
    # across all connections averages args.rps (0 = as fast as possible).
    pace_interval = 0.0
    if args.rps > 0:
        pace_interval = args.connections / args.rps
    try:
        sock = open_connection(args.host, args.port, args.timeout, src_ip)
    except OSError:
        with lock:
            transport[0] += quota if quota is not None else 1
        return
    done = 0
    while True:
        if quota is not None:
            if done >= quota:
                break
            done += 1
        else:
            with lock:
                if req_counter[0] >= max_reqs:
                    break
                if stop_at is not None and time.monotonic() >= stop_at:
                    break
                req_counter[0] += 1
        t0 = time.perf_counter()
        try:
            sock.sendall(req)
            status, _ = read_response(sock, buf)
            dt_ms = (time.perf_counter() - t0) * 1000.0
            local_lat.append(dt_ms)
            local_status[status] = local_status.get(status, 0) + 1
        except (OSError, ConnectionError, ValueError):
            local_transport += 1
            # Reconnect and continue.
            try:
                sock.close()
            except OSError:
                pass
            buf = bytearray()
            try:
                sock = open_connection(args.host, args.port, args.timeout, src_ip)
            except OSError:
                break
        if pace_interval > 0:
            nap = pace_interval - (time.perf_counter() - t0)
            if nap > 0:
                time.sleep(nap)
    try:
        sock.close()
    except OSError:
        pass
    with lock:
        latencies.extend(local_lat)
        transport[0] += local_transport
        for k, v in local_status.items():
            status_counts[k] = status_counts.get(k, 0) + v


def load_parse_args(argv):
    p = argparse.ArgumentParser(description="stdlib-only HTTP/1.1 keep-alive load generator")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--path", default="/")
    p.add_argument("--method", default="GET")
    p.add_argument("--connections", type=int, default=8)
    p.add_argument("--duration", type=float, default=10.0)
    p.add_argument("--requests", type=int, default=0,
                   help="total request cap (0 = run for --duration)")
    p.add_argument("--timeout", type=float, default=5.0)
    p.add_argument("--source-ips", type=int, default=0,
                   help="distinct 127.0.0.x sources (0 = OS default only)")
    p.add_argument("--rps", type=float, default=0,
                   help="target aggregate requests/sec, paced per connection (0 = as fast as possible)")
    p.add_argument("--warmup", type=float, default=1.0,
                   help="warmup seconds before measurement (connections reused)")
    p.add_argument("--json", default=None, help="write JSON report to file")
    a = p.parse_args(argv)
    if a.port <= 0 or a.port > 65535:
        p.error("port must be 1..65535")
    if a.connections <= 0 or a.connections > 256:
        p.error("connections must be 1..256")
    if a.source_ips < 0 or a.source_ips > 250:
        p.error("source-ips must be 0..250")
    if a.duration <= 0:
        p.error("duration must be > 0")
    # Repair the route before any socket opens: under Git Bash a leading slash
    # arrives as a Windows path (scripts/orbit_routes.py).
    try:
        a.path = normalize_route_path(a.path, what="--path")
    except RoutePathError as e:
        p.error(str(e))
    return a


def load_warmup(args):
    """Open one keep-alive connection and issue a few requests (discarded)."""
    if args.warmup <= 0:
        # Nothing to warm: the loop below would not iterate once, so all a
        # warmup=0 run does here is open and close one TCP connection.
        return
    try:
        sock = socket.create_connection((args.host, args.port), timeout=args.timeout)
        sock.settimeout(args.timeout)
        req = (
            "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: keep-alive\r\n\r\n"
            % (args.method, args.path, args.host)
        ).encode()
        buf = bytearray()
        end = time.monotonic() + args.warmup
        while time.monotonic() < end:
            try:
                sock.sendall(req)
                read_response(sock, buf)
            except (OSError, ConnectionError, ValueError):
                break
        sock.close()
    except OSError as e:
        print("Failed to connect to %s:%d (%s)" % (args.host, args.port, e),
              file=sys.stderr)


def load_main(argv=None):
    args = load_parse_args(argv if argv is not None else sys.argv[1:])
    load_warmup(args)
    latencies = []
    transport = [0]
    status_counts = {}
    lock = threading.Lock()
    req_counter = [0]
    max_reqs = args.requests if args.requests > 0 else 10 ** 12
    stop_at = None if args.requests > 0 else (time.monotonic() + args.duration)
    t_start = time.perf_counter()
    threads = []
    for i in range(args.connections):
        t = threading.Thread(target=worker, args=(i, args, stop_at, max_reqs, latencies,
                                                  transport, status_counts, lock, req_counter))
        t.daemon = True
        threads.append(t)
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.perf_counter() - t_start
    completed = len(latencies)
    lat_sorted = sorted(latencies)
    rps = completed / elapsed if elapsed > 0 else 0.0
    p50 = percentile(lat_sorted, 50)
    p95 = percentile(lat_sorted, 95)
    p99 = percentile(lat_sorted, 99)
    ok_2xx = sum(v for k, v in status_counts.items() if 200 <= k < 300)
    failed = transport[0] + (completed - ok_2xx)
    total = completed + transport[0]
    err_rate = (failed / total) if total else 0.0
    report = {
        "host": args.host,
        "port": args.port,
        "path": args.path,
        "method": args.method,
        "connections": args.connections,
        "source_ips": args.source_ips,
        "duration_s": round(elapsed, 3),
        "completed": completed,
        "ok_2xx": ok_2xx,
        "transport_errors": transport[0],
        "failed": failed,
        "error_rate": round(err_rate, 5),
        "rps": round(rps, 1),
        "p50_ms": round(p50, 3),
        "p95_ms": round(p95, 3),
        "p99_ms": round(p99, 3),
        "status_counts": {str(k): v for k, v in sorted(status_counts.items())},
    }
    out.say("Loading %s:%d %s x%d (source ips: %d) ..." % (
        args.host, args.port, args.path, args.connections, args.source_ips))
    print("  completed=%d ok_2xx=%d transport_errors=%d error_rate=%.3f%% elapsed=%.2fs" % (
        completed, ok_2xx, transport[0], err_rate * 100.0, elapsed))
    print("  rps=%.1f p50=%.3fms p95=%.3fms p99=%.3fms" % (rps, p50, p95, p99))
    print("  status=%s" % json.dumps(report["status_counts"]))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
        print("  json=%s" % args.json)
    if completed == 0:
        # A load tool that reports success against a dead port is a number
        # nobody can use: the p50 above is 0.000 because nothing was measured,
        # not because the server was fast. It used to exit 0 here, and it is
        # in no CI step, so nothing noticed. Measured nothing is not a pass.
        out.fail("Failed night_load: %d request(s) attempted, 0 completed, so "
                 "every number above describes nothing."
                 % (completed + transport[0]))
        out.tip("is the server up? `orbit build examples/blog_api.orb -o /tmp/srv "
                "&& /tmp/srv 4102`, then --port 4102")
        print("Finished night-load: 0 requests completed, nothing measured")
        return 1
    print("Finished night-load: %d completed, %d transport errors, error rate "
          "%.1f%%" % (completed, transport[0], err_rate * 100.0))
    return 0


# --------------------------------------------------------------------------
# route-limit: per-route limits under live traffic (needs a live server).
#
# Phase A (healthy): 200 requests @ ~10 rps via the load generator -> zero
#     errors (runs against --path, default /health).
# Phase B (burst): 25 rapid sequential GETs against --burst-path
#     (default: same as --path) -> >=1 x 429 from the ROUTE bucket
#     (25 < global 50-burst, so any 429 is route-level) with Retry-After.
#     The fixture route /gate-burst carries limit 5/s burst 5, so the burst
#     only needs to complete within ~4 s to trip denies (it takes ~ms).
# Phase C (no ban): after 2 s, 5 sequential GETs -> all 200 (a ban would 429
#     for 5 minutes).
#
# Exit 0 iff all phases pass. Server lifecycle stays with the operator.
# --------------------------------------------------------------------------
def phase_a(args):
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = load_main(["--host", args.host, "--port", str(args.port),
                            "--path", args.path, "--connections", "2",
                            "--requests", "200", "--rps", "10",
                            "--warmup", "0", "--timeout", "1",
                            "--json", args._json_tmp])
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else 2
    except Exception as e:  # noqa: BLE001 - a load crash is a failed phase
        print("Failed: load run raised %r" % (e,), file=sys.stderr)
        rc = 1
    print(buf.getvalue().strip())
    if rc != 0:
        out.fail("Phase A failed: load run exited rc=%d" % rc)
        return False
    with open(args._json_tmp, encoding="utf-8") as f:
        rep = json.load(f)
    ok = rep.get("completed") == 200 and rep.get("error_rate") == 0.0
    # transport_errors and duration_s are the two fields that decide which
    # mechanism this is, and this line used to print neither. A run that
    # completes 34 of 200 with status={'200': 34} looks like a slow runner
    # until you divide it out: failed == transport_errors, so 34 + 166 == 200
    # means 166 attempts died at the transport layer and none of them were
    # refusals or denials. p95 is here because latency is computed over the
    # successes only -- a sub-millisecond p95 next to a four-figure transport
    # count is the signature of a server that stopped answering rather than
    # one that got slower.
    detail = ("completed=%s/%s transport_errors=%s error_rate=%s "
              "elapsed=%ss p95=%sms status=%s" % (
                  rep.get("completed"), rep.get("completed", 0) + rep.get("transport_errors", 0),
                  rep.get("transport_errors"), rep.get("error_rate"),
                  rep.get("duration_s"), rep.get("p95_ms"),
                  rep.get("status_counts")))
    if ok:
        out.say("Phase A passed: " + detail)
    else:
        out.fail("Phase A failed: " + detail)
    return ok


def phase_b(args):
    url = url_for(args.host, args.port, args.burst_path)
    ok200 = 0
    deny429 = 0
    retry_after = None
    bad_body = 0
    t0 = time.time()
    for _ in range(25):
        status, ra, body = get(url, timeout=1.0)
        if status == 200:
            ok200 += 1
        elif status == 429:
            deny429 += 1
            if retry_after is None:
                retry_after = ra
            if body != b"429 Too Many Requests - Kynx admission control":
                bad_body += 1
        else:
            out.fail("Phase B failed: unexpected status %r" % (status,))
            return False
    try:
        ra_s = int((retry_after or "").strip())
    except ValueError:
        ra_s = -1
    ok = deny429 >= 1 and ok200 + deny429 == 25 and ra_s >= 1 and bad_body == 0
    elapsed = time.time() - t0
    if ok:
        out.say("Phase B passed: ok=%d denied=%d retry_after=%r elapsed=%.2fs" % (
            ok200, deny429, retry_after, elapsed))
    else:
        out.fail("Phase B failed: ok=%d denied=%d retry_after=%r bad_body=%d elapsed=%.2fs" % (
            ok200, deny429, retry_after, bad_body, elapsed))
    return ok


def phase_c(args):
    time.sleep(2.0)
    url = url_for(args.host, args.port, args.burst_path)
    results = [get(url, timeout=1.0)[0] for _ in range(5)]
    ok = all(s == 200 for s in results)
    if ok:
        out.say("Phase C passed: post-burst statuses=%s" % (results,))
    else:
        out.fail("Phase C failed: post-burst statuses=%s" % (results,))
    return ok


def routelimit_main(argv=None):
    ap = argparse.ArgumentParser(description="Kynx route-limit gate (needs a live server)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--path", default="/health")
    ap.add_argument("--burst-path", default=None,
                    help="route for burst/no-ban phases (default: same as --path)")
    args = ap.parse_args(argv)
    if not args.burst_path:
        args.burst_path = args.path
    # Repair routes before anything opens a socket: under Git Bash a leading
    # slash arrives as a Windows path (scripts/orbit_routes.py).
    try:
        args.path = normalize_route_path(args.path, what="--path")
        args.burst_path = normalize_route_path(args.burst_path, what="--burst-path")
    except RoutePathError as e:
        out.fail("Failed: %s" % e)
        return 2
    # Phase A writes its JSON report to a temp file; it used to be handed to a
    # night_load subprocess, now it is an in-process call (see phase_a).
    args._json_tmp = os.path.join(tempfile.mkdtemp(prefix="kynx_gate_"), "a.json")
    # All three phases run whatever the others did. This used to be
    # `b = phase_b(args) if a else False`, which meant a Phase A failure
    # suppressed the two phases that would have described it -- and the
    # handoff for the Windows Kynx gate recorded "phases B and C pass on
    # Windows" from a run in which neither had executed. A phase that cannot
    # run cannot report, and the gate then looks like it knows less than it
    # does. Phase B stops at its first unexpected status, so a dead server
    # costs it nothing.
    a = phase_a(args)
    b = phase_b(args)
    c = phase_c(args)
    passed = bool(a and b and c)
    if passed:
        print("Finished kynx gate: PASS")
    else:
        out.fail("Finished kynx gate: FAIL")
    return 0 if passed else 1


# --------------------------------------------------------------------------
# burst: demonstrate admission control end-to-end against a running server.
#
# Starts N requests against a running Orbit server and asserts that once
# the configured per-IP window budget is spent, Kynx answers 429.
#
# Exit 0 iff at least one 429 was observed (gate proven) or the server
# answered everything without exceeding its budget (documented via --strict).
# --------------------------------------------------------------------------
burst_lock = Counter()


def burst_fire(host, port, path, timeout):
    try:
        req = urllib.request.Request(f"http://{host}:{port}{path}", headers={"Connection": "close"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            burst_lock[r.status] += 1
    except urllib.error.HTTPError as e:
        burst_lock[e.code] += 1
    except Exception:
        burst_lock["err"] += 1


def burst_main(argv=None):
    ap = argparse.ArgumentParser(description="Kynx burst probe (needs a live server)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3000)
    ap.add_argument("--path", default="/")
    ap.add_argument("--requests", type=int, default=300)
    ap.add_argument("--threads", type=int, default=16)
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--strict", action="store_true",
                    help="fail if NO 429 observed even when budget not exhausted")
    args = ap.parse_args(argv)
    try:
        args.path = normalize_route_path(args.path, what="--path")
    except RoutePathError as e:
        out.fail("Failed: %s" % e)
        return 2

    burst_lock.clear()
    threads = []
    for _i in range(args.requests):
        t = threading.Thread(target=burst_fire, args=(args.host, args.port, args.path, args.timeout))
        t.start()
        threads.append(t)
        if len(threads) >= args.threads:
            threads[0].join()
            threads = threads[1:]
    for t in threads:
        t.join()

    out.say(f"Probed {args.requests} requests against "
            f"{args.host}:{args.port}{args.path}: {dict(burst_lock)}")
    got_429 = burst_lock.get(429, 0)
    ok = got_429 > 0 or (not args.strict and sum(v for k, v in burst_lock.items() if isinstance(k, int)) == args.requests)
    if got_429:
        out.say(f"Finished burst probe: PASS, admission control engaged ({got_429} x 429)")
    elif ok:
        out.say("Finished burst probe: PASS, under budget so no 429 expected")
    else:
        out.fail("Finished burst probe: FAIL, no 429 observed "
                 "(server may be under budget; raise --requests or drop --strict)")
    return 0 if ok else 1


# --------------------------------------------------------------------------
# live: build a real service, start it, and burst a guarded route at it.
#
# The only gate in this repository that runs the compiler's whole product: it
# builds `examples/blog_api.orb` with the fixed-point compiler, starts the binary,
# waits for it to answer, and fires a burst at `/gate-burst` to check the Kynx
# sharded rate limiter answers with the limit rather than letting everything
# through. Everything else in CI reasons about the compiler or about text.
#
# The same gate also covers the `port` declaration end to end, on a fixture
# that declares one. Started with no argv, /health must answer on the declared
# port: the server reads the declaration rather than the old fixed 3000.
# Started with an argv port, /health must answer there instead, because argv
# has always overridden the default and still does. Both are wait_ready
# assertions, so each half fails red on a server that comes up on the wrong
# port instead of asserting text about the emission.
#
# It covers the request boundary too, on a third fixture. A Kynx lease caps
# one request's arena, and a request that asks for more than the cap must be
# answered 503 and leave the process serving (ENGINEERING.md section 7,
# kynx-lease-abort). The fixture's route grows one string past the lease's
# 16 MB default, which is a request asking for more than its share; no C-level
# test needs to reach into the allocator to produce it. On the pre-boundary
# compiler the refusal ended the process: /grow then reports a transport error
# instead of 503, and the /health after it never answers, so both assertions
# fail red rather than asserting text about the emission.
#
# Unlike `runtime_c_tests.py` this one needs the Orbit compiler, which is why it
# is not in T0. It uses the fixed point at the path `dev.py` owns; pass `--compiler`
# to point it elsewhere. Run it as `python scripts/kynx_gate.py live`.
# --------------------------------------------------------------------------
def stop_server(proc: subprocess.Popen) -> None:
    """terminate, 10 s, kill: the shape live_main's `finally` already used."""
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()


def start_and_wait(srv: pathlib.Path, argv: list, port: int,
                   log_path: pathlib.Path):
    """Start a built server; return (Popen, log handle) once /health answers.

    None when it never became ready, so the caller reports which port was
    expected. The server's output goes to `log_path` for the reason the gate
    server's does: a pipe nobody reads fills up, and the server blocks in
    write() forever instead of answering.
    """
    log = open(log_path, "w", encoding="utf-8", errors="replace")
    proc = subprocess.Popen([str(srv)] + argv, cwd=str(ROOT),
                            stdout=log, stderr=subprocess.STDOUT)
    if not wait_ready(port):
        stop_server(proc)
        log.close()
        return None
    return proc, log


def live_main(args):
    compiler = args.compiler
    if not compiler:
        proc = subprocess.run(
            [sys.executable, str(pathlib.Path(ROOT) / "scripts" / "dev.py"), "fp-path"],
            capture_output=True, text=True)
        compiler = proc.stdout.strip()
        if not compiler or not pathlib.Path(compiler).exists():
            print("Failed: no orbit compiler. Run `make fp`, or pass --compiler.",
                  file=sys.stderr)
            return 2

    work = pathlib.Path(ROOT) / ".orbit" / "work" / "kynx"
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

    # The server's output goes to a file, never to a pipe nobody reads. This
    # gate used to pass stdout=PIPE and then never read it, and on Windows that
    # pipe holds 4352 bytes against Linux's 65536. The service writes about
    # 118 bytes per request, so the pipe filled at request ~38 and the server
    # blocked in write() for good: every later request timed out, Phase A
    # reported completed=34 error_rate=0.83, and the log showed p50=0.2ms --
    # a perfectly healthy server that had stopped answering. Linux needed ~554
    # requests to fill the pipe and Phase A only asks for 200, which is the
    # whole reason it read as a Windows defect. The file also means the
    # service's own output is readable when the gate fails, instead of being
    # discarded.
    srv_log_path = work / "gate_srv.log"
    srv_log = open(srv_log_path, "w", encoding="utf-8", errors="replace")
    proc = subprocess.Popen([str(srv), str(args.port)], cwd=str(ROOT),
                            stdout=srv_log, stderr=subprocess.STDOUT)
    try:
        if not wait_ready(args.port):
            print(f"Failed: the gate server on port {args.port} never became "
                  f"ready.", file=sys.stderr)
            return 1
        gate_rc = routelimit_main(["--port", str(args.port),
                                   "--burst-path", args.burst_path])
        if gate_rc != 0:
            print("\nFinished kynx-gate: FAILED "
                  f"(exit {gate_rc})")
            srv_log.flush()
            try:
                tail = srv_log_path.read_text(
                    encoding="utf-8", errors="replace").splitlines()[-25:]
                if tail:
                    print(f"\n--- last {len(tail)} lines of {srv_log_path.name} ---",
                          file=sys.stderr)
                    for line in tail:
                        print("  " + line, file=sys.stderr)
            except OSError:
                pass
            return 1
    finally:
        # Always, including on an exception. The shell used a `trap ... EXIT`,
        # which does not fire when the runner kills the step.
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        srv_log.close()

    # The `port` declaration: no-argv binds the declared port, argv wins.
    declared = args.port + 1
    override = args.port + 2
    decl_src = work / "port_declared.orb"
    decl_srv = work / ("port_declared" + suffix)
    decl_src.write_text(
        "// Written by kynx_gate live: the declaration is the default the\n"
        "// server binds with no argv; an argv port still overrides it.\n"
        f"port {declared}\n\n"
        'route GET "/health" {\n'
        '    return ok 200 "ok"\n'
        "}\n",
        encoding="utf-8")
    build = subprocess.run(
        [compiler, "build", str(decl_src), "-o", str(decl_srv)],
        cwd=str(ROOT), env=env, capture_output=True, text=True)
    sys.stdout.write(build.stdout)
    sys.stderr.write(build.stderr)
    if build.returncode != 0 or not decl_srv.exists():
        print("Failed: the port_declared fixture did not build.", file=sys.stderr)
        return 1

    started = start_and_wait(decl_srv, [], declared,
                             work / "port_declared.log")
    if started is None:
        print(f"Failed: the port_declared server never answered on the "
              f"declared port {declared}; the `port` declaration is not "
              f"reaching the emitted server (log: port_declared.log).",
              file=sys.stderr)
        return 1
    proc, log = started
    try:
        print(f"port declaration: answered on the declared port {declared}.")
    finally:
        stop_server(proc)
        log.close()

    started = start_and_wait(decl_srv, [str(override)], override,
                             work / "port_declared_argv.log")
    if started is None:
        print(f"Failed: argv port {override} did not override the declared "
              f"{declared} (log: port_declared_argv.log).", file=sys.stderr)
        return 1
    proc, log = started
    try:
        print(f"port override: answered on the argv port {override}.")
    finally:
        stop_server(proc)
        log.close()

    # The request boundary (ENGINEERING.md section 7, kynx-lease-abort): a
    # request that asks for more than its Kynx lease allows is answered, not
    # fatal. The route grows one string past the lease's 16 MB default, which
    # is a request asking for more than its share. Before the boundary, the
    # refusal ended the process, so /grow answers with a transport error (no
    # 503) and /health never answers at all.
    ovf = args.port + 3
    ovf_src = work / "lease_overflow.orb"
    ovf_srv = work / ("lease_overflow" + suffix)
    ovf_src.write_text(
        "// Written by kynx_gate live: a request that asks for more than its\n"
        "// Kynx lease allows must be answered 503, not end the process. The\n"
        "// loop grows one string past the 16 MB lease: 4000 appends trip the\n"
        "// cap around iteration 1833, at 16 770 112 of 16 777 216 bytes.\n"
        "\n"
        'route GET "/grow" {\n'
        '    var s = ""\n'
        "    var i = 0\n"
        "    while i < 4000 {\n"
        '        s = s + "0123456789"\n'
        "        i = i + 1\n"
        "    }\n"
        "    return ok 200 s\n"
        "}\n"
        "\n"
        'route GET "/health" {\n'
        '    return ok 200 "ok"\n'
        "}\n",
        encoding="utf-8")
    build = subprocess.run(
        [compiler, "build", str(ovf_src), "-o", str(ovf_srv)],
        cwd=str(ROOT), env=env, capture_output=True, text=True)
    sys.stdout.write(build.stdout)
    sys.stderr.write(build.stderr)
    if build.returncode != 0 or not ovf_srv.exists():
        print("Failed: the lease_overflow fixture did not build.", file=sys.stderr)
        return 1

    started = start_and_wait(ovf_srv, [str(ovf)], ovf,
                             work / "lease_overflow.log")
    if started is None:
        print(f"Failed: the lease_overflow server never answered on port "
              f"{ovf} (log: lease_overflow.log).", file=sys.stderr)
        return 1
    proc, log = started
    try:
        status, _retry, body = get(f"http://127.0.0.1:{ovf}/grow")
        if status != 503:
            print(f"Failed: a request above the lease was answered {status!r}, "
                  f"not 503: a refusal at the request boundary must be an "
                  f"answer, not a dead process. Body: {body[:200]!r} "
                  f"(log: lease_overflow.log).", file=sys.stderr)
            return 1
        health, _h_retry, _h_body = get(f"http://127.0.0.1:{ovf}/health")
        if health != 200:
            print(f"Failed: the lease_overflow server did not survive the "
                  f"refusal: /health answered {health!r} (log: "
                  f"lease_overflow.log).", file=sys.stderr)
            return 1
        print("request boundary: a request above the lease was answered 503 ("
              + repr(body.decode("utf-8", "replace")[:70])
              + "); /health still answered 200.")
    finally:
        stop_server(proc)
        log.close()

    print("\nFinished kynx-gate: the route-limit burst answered as specified,"
          " the declared port answered under both runs, and the request"
          " boundary answered 503 without taking the service down.")
    return 0


# --------------------------------------------------------------------------
# --self-test: every subcommand must fail cleanly and fast against a dead port.
# --------------------------------------------------------------------------
def self_test() -> int:
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
    probes = [
        ("route-limit", lambda: routelimit_main(
            ["--port", "9", "--burst-path", "/gate-burst"])),
        ("burst", lambda: burst_main(
            ["--port", "9", "--requests", "2", "--threads", "2", "--timeout", "1"])),
        ("load", lambda: load_main(
            ["--port", "9", "--requests", "2", "--duration", "1",
             "--warmup", "0", "--timeout", "1"])),
    ]
    for name, fn in probes:
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                rc = fn()
        except SystemExit as e:
            rc = e.code if isinstance(e.code, int) else 2
        except Exception as e:  # noqa: BLE001 - a crash here is the finding
            print("self-test FAILED: %s raised %r" % (name, e))
            return 1
        if rc == 0:
            print("self-test FAILED: %s passed against a dead port" % name)
            return 1
    print("Finished kynx-gate self-test: readiness bounded; route-limit, burst "
          "and load all fail cleanly against a dead port.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Kynx live gates and load tools (needs a live server "
                    "except for --self-test)")
    ap.add_argument("--self-test", action="store_true",
                    help="prove every subcommand fails cleanly against a dead port")
    sub = ap.add_subparsers(dest="cmd", metavar="<subcommand>")

    p_live = sub.add_parser("live", help="build, start and burst the gate service")
    p_live.add_argument("--compiler", default=None,
                        help="the orbit binary (default: ask scripts/dev.py)")
    p_live.add_argument("--cc", default=os.environ.get("ORBIT_CC") or "gcc")
    p_live.add_argument("--port", type=int, default=DEFAULT_PORT)
    p_live.add_argument("--burst-path", default="/gate-burst")

    p_rl = sub.add_parser("route-limit", help="three phases against a running server")
    p_rl.add_argument("--host", default="127.0.0.1")
    p_rl.add_argument("--port", type=int, default=DEFAULT_PORT)
    p_rl.add_argument("--path", default="/health")
    p_rl.add_argument("--burst-path", default=None)

    p_burst = sub.add_parser("burst", help="manual burst probe against a running server")
    p_burst.add_argument("--host", default="127.0.0.1")
    p_burst.add_argument("--port", type=int, default=3000)
    p_burst.add_argument("--path", default="/")
    p_burst.add_argument("--requests", type=int, default=300)
    p_burst.add_argument("--threads", type=int, default=16)
    p_burst.add_argument("--timeout", type=float, default=5.0)
    p_burst.add_argument("--strict", action="store_true")

    p_load = sub.add_parser("load", help="stdlib-only HTTP load generator")
    p_load.add_argument("--host", default="127.0.0.1")
    p_load.add_argument("--port", type=int, required=True)
    p_load.add_argument("--path", default="/")
    p_load.add_argument("--method", default="GET")
    p_load.add_argument("--connections", type=int, default=8)
    p_load.add_argument("--duration", type=float, default=10.0)
    p_load.add_argument("--requests", type=int, default=0)
    p_load.add_argument("--timeout", type=float, default=5.0)
    p_load.add_argument("--source-ips", type=int, default=0)
    p_load.add_argument("--rps", type=float, default=0)
    p_load.add_argument("--warmup", type=float, default=1.0)
    p_load.add_argument("--json", default=None)
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if args.cmd == "live":
        return live_main(args)
    if args.cmd == "route-limit":
        return routelimit_main([
            "--host", args.host, "--port", str(args.port),
            "--path", args.path] + (
            ["--burst-path", args.burst_path] if args.burst_path else []))
    if args.cmd == "burst":
        return burst_main([
            "--host", args.host, "--port", str(args.port),
            "--path", args.path, "--requests", str(args.requests),
            "--threads", str(args.threads), "--timeout", str(args.timeout)] + (
            ["--strict"] if args.strict else []))
    if args.cmd == "load":
        return load_main([
            "--host", args.host, "--port", str(args.port),
            "--path", args.path, "--method", args.method,
            "--connections", str(args.connections),
            "--duration", str(args.duration),
            "--requests", str(args.requests),
            "--timeout", str(args.timeout),
            "--source-ips", str(args.source_ips),
            "--rps", str(args.rps), "--warmup", str(args.warmup)] + (
            ["--json", args.json] if args.json else []))
    ap.error("a subcommand is required: live, route-limit, burst or load")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
