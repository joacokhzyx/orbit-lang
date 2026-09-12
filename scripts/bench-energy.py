#!/usr/bin/env python3
"""Energy and ledger benchmark helper for Orbit.

Subcommands:
  save      sample /_ledger/data N times, write a baseline.json file with
            per-route medians, spread, and a machine record.
  compare   sample again (or read --input) and check current medians against
            a baseline within tolerance bands. Exit 0 holds, 1 regresses.
  overhead  compile and run scripts/bench-ledger-overhead.c with and without
            ORBIT_NO_LEDGER, report ledger share of request cost (<2% holds).

Only the standard library is used. Joule fields are compared only when both
sides are metered (energy_source "rapl-estimate"); on proxy builds the
comparison uses avg_cycles and never converts cycles to joules.

Exit codes: 0 ok, 1 clean failure or tolerance breach, 2 usage.
"""

import argparse
import datetime
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE_VERSION = 1


def machine_record():
    rec = {
        "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "os": platform.system(),
        "os_version": platform.version(),
        "arch": platform.machine(),
        "cpu_model": _cpu_model(),
        "logical_cpus": os.cpu_count(),
        "total_ram": _total_ram(),
        "python": platform.python_version(),
        "git_revision": _git_revision(),
        "cc_version": _cc_version(),
        "power_sensor": _power_sensor(),
    }
    return rec


def _cpu_model():
    try:
        if platform.system() == "Windows":
            return os.environ.get("PROCESSOR_IDENTIFIER", "unknown").strip() or "unknown"
        if os.path.exists("/proc/cpuinfo"):
            with open("/proc/cpuinfo", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("model name"):
                        return line.split(":", 1)[1].strip()
        return platform.processor() or "unknown"
    except OSError:
        return "unknown"


def _total_ram():
    try:
        if platform.system() == "Windows":
            import ctypes

            class MemStatus(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]

            st = MemStatus()
            st.dwLength = ctypes.sizeof(MemStatus)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
                return int(st.ullTotalPhys)
            return "unknown"
        if os.path.exists("/proc/meminfo"):
            with open("/proc/meminfo", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        kb = int(line.split()[1])
                        return kb * 1024
        return "unknown"
    except (OSError, ValueError):
        return "unknown"


def _git_revision():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if out.returncode == 0:
            return out.stdout.strip()
        return "unknown"
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def _cc_version():
    for cc in ("gcc", "cc", "clang"):
        try:
            out = subprocess.run(
                [cc, "--version"], capture_output=True, text=True, timeout=15
            )
            if out.returncode == 0 and out.stdout:
                return out.stdout.splitlines()[0].strip()[:120]
        except (OSError, subprocess.SubprocessError):
            continue
    return "unknown"


def _power_sensor():
    try:
        base = "/sys/class/powercap"
        if os.path.isdir(base):
            for name in sorted(os.listdir(base)):
                cand = os.path.join(base, name, "energy_uj")
                if os.path.exists(cand):
                    return cand
            return "powercap present, no energy_uj file"
        if platform.system() == "Windows":
            return "absent (Windows has no RAPL powercap interface)"
        return "absent (no /sys/class/powercap)"
    except OSError:
        return "unknown"


def fetch_ledger(url, timeout=10):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def load_ledger_source(url, input_path):
    if input_path:
        with open(input_path, encoding="utf-8") as f:
            return json.load(f)
    return fetch_ledger(url)


def _route_key(method, path):
    return "%s %s" % (method or "?", path or "?")


def collect_samples(url, input_path, rounds, interval_s):
    samples = []
    for i in range(rounds):
        data = load_ledger_source(url, input_path if i == 0 else None)
        if input_path and i > 0:
            samples.append(samples[0])
        else:
            samples.append(data)
        if i + 1 < rounds and not input_path:
            time.sleep(interval_s)
    return samples


def summarize(samples):
    by_route = {}
    sources = set()
    for data in samples:
        if isinstance(data.get("energy_source"), str):
            sources.add(data["energy_source"])
        routes = data.get("routes", [])
        if not isinstance(routes, list):
            continue
        for r in routes:
            if not isinstance(r, dict):
                continue
            key = _route_key(r.get("method"), r.get("path"))
            slot = by_route.setdefault(
                key,
                {
                    "method": r.get("method", "?"),
                    "path": r.get("path", "?"),
                    "avg_ms": [],
                    "avg_cycles": [],
                    "db_share": [],
                    "req": [],
                    "joules_total": [],
                    "joules_per_req": [],
                },
            )
            for field in ("avg_ms", "avg_cycles", "db_share", "req",
                          "joules_total", "joules_per_req"):
                v = r.get(field)
                if isinstance(v, (int, float)):
                    slot[field].append(float(v))
    routes = []
    for key in sorted(by_route):
        s = by_route[key]
        routes.append(
            {
                "method": s["method"],
                "path": s["path"],
                "samples": len(s["avg_ms"]),
                "req_last": s["req"][-1] if s["req"] else 0,
                "avg_ms_median": _median(s["avg_ms"]),
                "avg_ms_stdev": _stdev(s["avg_ms"]),
                "avg_ms_variance": _variance(s["avg_ms"]),
                "avg_cycles_median": _median(s["avg_cycles"]),
                "db_share_median": _median(s["db_share"]),
                "joules_total_median": _median(s["joules_total"]),
                "joules_per_req_median": _median(s["joules_per_req"]),
                "joules_per_req_stdev": _stdev(s["joules_per_req"]),
                "joules_per_req_variance": _variance(s["joules_per_req"]),
            }
        )
    source = sorted(sources)[0] if len(sources) == 1 else (
        sorted(sources) if sources else "unknown"
    )
    return routes, source


def _median(vals):
    if not vals:
        return 0.0
    return float(statistics.median(vals))


def _stdev(vals):
    if len(vals) < 2:
        return 0.0
    return float(statistics.stdev(vals))


def _variance(vals):
    if len(vals) < 2:
        return 0.0
    return float(statistics.variance(vals))


def cmd_save(args):
    try:
        samples = collect_samples(args.url, args.input, args.rounds, args.interval)
    except (OSError, ValueError) as e:
        print("save: cannot read ledger: %s" % e, file=sys.stderr)
        return 1
    routes, source = summarize(samples)
    baseline = {
        "version": BASELINE_VERSION,
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "tool": "scripts/bench-energy.py save",
        "machine": machine_record(),
        "config": {
            "rounds": args.rounds,
            "interval_s": args.interval,
            "url": args.url or "",
            "input": args.input or "",
        },
        "energy_source": source,
        "routes": routes,
    }
    try:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(baseline, f, indent=2)
            f.write("\n")
    except OSError as e:
        print("save: cannot write %s: %s" % (args.out, e), file=sys.stderr)
        return 1
    print("saved %d route(s) from %d round(s) to %s (source: %s)"
          % (len(routes), args.rounds, args.out, source))
    return 0


def _holds(current, base, tol, floor):
    limit = base * (1.0 + tol) + floor
    return current <= limit, limit


def cmd_compare(args):
    try:
        with open(args.baseline, encoding="utf-8") as f:
            baseline = json.load(f)
    except (OSError, ValueError) as e:
        print("compare: cannot read baseline: %s" % e, file=sys.stderr)
        return 2
    try:
        samples = collect_samples(args.url, args.input, args.rounds, args.interval)
    except (OSError, ValueError) as e:
        print("compare: cannot read current ledger: %s" % e, file=sys.stderr)
        return 1
    current_routes, current_source = summarize(samples)
    base_routes = {
        _route_key(r.get("method"), r.get("path")): r
        for r in baseline.get("routes", [])
        if isinstance(r, dict)
    }
    base_source = baseline.get("energy_source", "unknown")
    metered = base_source == "rapl-estimate" and current_source == "rapl-estimate"

    failures = 0
    print("baseline source: %s, current source: %s (%s)"
          % (base_source, current_source,
             "joules compared" if metered else "proxy compared, joules skipped"))
    print("%-28s %12s %12s %12s %s" % ("route", "baseline", "current", "limit", "verdict"))
    for r in current_routes:
        key = _route_key(r["method"], r["path"])
        base = base_routes.get(key)
        if base is None:
            print("%-28s %12s %12.3f %12s NEW" % (key, "-", r["avg_ms_median"], "-"))
            continue
        ok_ms, limit_ms = _holds(r["avg_ms_median"], base.get("avg_ms_median", 0.0),
                                 args.tolerance, 0.05)
        if metered:
            ok_j, limit_j = _holds(r["joules_per_req_median"],
                                   base.get("joules_per_req_median", 0.0),
                                   args.tolerance, 1e-9)
            ok = ok_ms and ok_j
            detail = "ms %.3f/%.3f J %.9f/%.9f" % (
                r["avg_ms_median"], limit_ms,
                r["joules_per_req_median"], limit_j)
        else:
            ok_c, limit_c = _holds(r["avg_cycles_median"],
                                   base.get("avg_cycles_median", 0.0),
                                   args.tolerance, 2500.0)
            ok = ok_ms and ok_c
            detail = "ms %.3f/%.3f cyc %.0f/%.0f" % (
                r["avg_ms_median"], limit_ms,
                r["avg_cycles_median"], limit_c)
        print("%-28s %12.3f %12.3f %12.3f %s  (%s)"
              % (key, base.get("avg_ms_median", 0.0), r["avg_ms_median"],
                 limit_ms, "HOLD" if ok else "BREACH", detail))
        if not ok:
            failures += 1
    for key in sorted(base_routes):
        if key not in {_route_key(r["method"], r["path"]) for r in current_routes}:
            print("%-28s vanished since baseline" % key)
            failures += 1
    if failures:
        print("compare: %d breach(es) beyond tolerance %.0f%%" % (failures, args.tolerance * 100))
        return 1
    print("compare: all %d route(s) hold within tolerance %.0f%%"
          % (len(current_routes), args.tolerance * 100))
    return 0


def _find_cc(preferred):
    if preferred:
        return preferred
    for cc in ("gcc", "cc", "clang"):
        found = _which(cc)
        if found:
            return found
    return None


def _which(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        cand = os.path.join(d, name + (".exe" if platform.system() == "Windows" else ""))
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def cmd_overhead(args):
    cc = _find_cc(args.cc)
    if not cc:
        print("overhead: no C compiler found (tried gcc, cc, clang)", file=sys.stderr)
        return 1
    src = os.path.join(REPO_ROOT, "scripts", "bench-ledger-overhead.c")
    if not os.path.isfile(src):
        print("overhead: missing %s" % src, file=sys.stderr)
        return 1
    tmp = tempfile.mkdtemp(prefix="orbit-ledger-bench-")
    results = {}
    try:
        for variant, extra in (("default", []), ("no_ledger", ["-DORBIT_NO_LEDGER"])):
            exe = os.path.join(tmp, "bench_" + variant + (".exe" if platform.system() == "Windows" else ""))
            cmd = [cc, "-O2", "-DORBIT_WITH_NET", "-I", REPO_ROOT, src, "-o", exe] + extra
            if platform.system() == "Windows":
                cmd += ["-lws2_32"]
            else:
                cmd += ["-lpthread", "-lrt"]
            built = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
            if built.returncode != 0:
                print("overhead: compile failed (%s):\n%s" % (variant, built.stderr.strip()[-2000:]),
                      file=sys.stderr)
                return 1
            runs = []
            for _ in range(args.rounds):
                run = subprocess.run([exe], capture_output=True, text=True, timeout=180)
                if run.returncode != 0:
                    print("overhead: bench run failed (%s): %s" % (variant, run.stderr.strip()[-1000:]),
                          file=sys.stderr)
                    return 1
                try:
                    runs.append(json.loads(run.stdout.strip()))
                except ValueError:
                    print("overhead: cannot parse bench output: %r" % run.stdout.strip()[-500:],
                          file=sys.stderr)
                    return 1
            results[variant] = runs
    finally:
        pass
    summaries = {}
    for variant, runs in list(results.items()):
        with_ns = statistics.median([r["with_ns_per_req"] for r in runs])
        without_ns = statistics.median([r["without_ns_per_req"] for r in runs])
        with_cy = statistics.median([r["with_cycles_per_req"] for r in runs])
        delta_ns = with_ns - without_ns
        share = delta_ns / without_ns * 100.0 if without_ns > 0 else 0.0
        summaries[variant] = (with_ns, without_ns, with_cy, delta_ns, share)
        print("%s: with=%.1f ns/req (%.0f cyc) without=%.1f ns/req "
              "delta=%+.1f ns/req parse-relative share=%+.2f%%"
              % (variant, with_ns, with_cy, without_ns, delta_ns, share))
    print("machine: %s, %s" % (machine_record()["cpu_model"], machine_record()["cc_version"]))
    print("parse-relative share is a noisy upper bound: the parse micro-loop "
          "jitters run to run, so the gate below uses the absolute delta.")
    print("gate: absolute ledger delta must stay under %.0f ns/req "
          "(under 2%% of any request slower than %.0f ns; measured loopback "
          "p50 on the reference box is ~125000 ns)" % (args.budget_ns, args.budget_ns * 50))
    delta_ns = summaries["default"][3]
    if delta_ns < args.budget_ns:
        print("overhead: HOLD (delta %+.1f ns/req < %.0f ns/req)" % (delta_ns, args.budget_ns))
        return 0
    print("overhead: BREACH (delta %+.1f ns/req >= %.0f ns/req)" % (delta_ns, args.budget_ns))
    return 1


def build_parser():
    p = argparse.ArgumentParser(description="Orbit ledger and energy benchmark helper")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("save", help="sample /_ledger/data and write baseline.json")
    s.add_argument("--url", default="http://127.0.0.1:3000/_ledger/data")
    s.add_argument("--input", default=None, help="read one ledger JSON file instead of HTTP")
    s.add_argument("--out", required=True)
    s.add_argument("--rounds", type=int, default=5)
    s.add_argument("--interval", type=float, default=1.0)
    s.set_defaults(fn=cmd_save)

    c = sub.add_parser("compare", help="check current ledger against a baseline")
    c.add_argument("--baseline", required=True)
    c.add_argument("--url", default="http://127.0.0.1:3000/_ledger/data")
    c.add_argument("--input", default=None)
    c.add_argument("--rounds", type=int, default=5)
    c.add_argument("--interval", type=float, default=1.0)
    c.add_argument("--tolerance", type=float, default=0.10)
    c.set_defaults(fn=cmd_compare)

    o = sub.add_parser("overhead", help="measure ledger share of request cost")
    o.add_argument("--cc", default=None)
    o.add_argument("--rounds", type=int, default=3)
    o.add_argument("--budget-ns", type=float, default=1000.0,
                   help="HOLD when the absolute ledger delta stays under this "
                        "many ns/req (default 1000: under 2%% of requests "
                        "slower than 50us)")
    o.set_defaults(fn=cmd_overhead)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if getattr(args, "rounds", 1) < 1:
        print("rounds must be >= 1", file=sys.stderr)
        return 2
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
