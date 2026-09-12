#!/usr/bin/env python3
"""night_load.py — stdlib-only TCP HTTP/1.1 keep-alive load generator.

Shared infra for the night-speed crew. No third-party dependencies.

Each worker thread owns one persistent TCP connection (HTTP/1.1
keep-alive) and issues requests sequentially. Latency is measured with
time.perf_counter around send+receive of a single response.

Error model: a request counts as failed when the transport breaks OR the
response status is not 2xx (per-IP rate limiters answer 429, which must
show up in error_rate instead of being silently counted as success).

Source IPs: by default every connection originates from the loopback
address the OS picks (127.0.0.1). With --source-ips N, connections bind
round-robin to 127.0.0.2..127.0.(N+1) so the load simulates N distinct
clients against per-IP admission control. Warmup always uses the
unbound address, keeping the measurement pool's per-IP budgets intact.

Usage:
    python scripts/night_load.py --port 4100 --duration 10 --connections 8
    python scripts/night_load.py --port 4100 --requests 20000 --connections 8 --path /
    python scripts/night_load.py --port 4100 --requests 400 --connections 8 --source-ips 8

Output: human table on stdout plus optional JSON (--json out.json).
Exit codes: 0 ok, 2 usage error (matches DECISIONS.md).
"""
import argparse
import json
import socket
import sys
import threading
import time


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
    out = bytearray(buf)
    del buf[:]
    while len(out) < n:
        data = sock.recv(n - len(out))
        if not data:
            raise ConnectionError("closed while reading body")
        out.extend(data)
    return bytes(out)


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
    try:
        sock = open_connection(args.host, args.port, args.timeout, src_ip)
    except OSError:
        with lock:
            transport[0] += max_reqs  # all assigned requests failed
        return
    while True:
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
    try:
        sock.close()
    except OSError:
        pass
    with lock:
        latencies.extend(local_lat)
        transport[0] += local_transport
        for k, v in local_status.items():
            status_counts[k] = status_counts.get(k, 0) + v


def parse_args(argv):
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
    return a


def warmup(args):
    """Open one keep-alive connection and issue a few requests (discarded)."""
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
        print("warmup: cannot connect to %s:%d (%s)" % (args.host, args.port, e),
              file=sys.stderr)


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    warmup(args)
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
    print("night_load: %s:%d %s x%d src_ips=%d" % (
        args.host, args.port, args.path, args.connections, args.source_ips))
    print("  completed=%d ok_2xx=%d transport_errors=%d error_rate=%.3f%% elapsed=%.2fs" % (
        completed, ok_2xx, transport[0], err_rate * 100.0, elapsed))
    print("  rps=%.1f p50=%.3fms p95=%.3fms p99=%.3fms" % (rps, p50, p95, p99))
    print("  status=%s" % json.dumps(report["status_counts"]))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
        print("  json=%s" % args.json)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit as e:
        raise
    except Exception as e:
        print("night_load: failed: %s" % e, file=sys.stderr)
        sys.exit(1)
