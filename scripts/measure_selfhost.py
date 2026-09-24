#!/usr/bin/env python3
"""Measure self-host bootstrap resource usage without changing the compiler.

Phase 0 instrument: external RSS/time/size sampler per build phase so the
peak on low-RAM machines can be attributed before any optimization lands.

What it does:
  static      : file sizes, SHA, counts of risky patterns (out+concat,
                list grows, arena allocs). No subprocess, safe on any RAM.
  amalgamate  : runs scripts/amalgamate.py on the canonical C, samples RSS.
  seed-cc     : compiles the amalgamated TU with the C compiler, samples RSS.
  orbit-build : runs seed.exe build compiler/main.orb, samples the orbit
                process tree separately from its inner cc child.
  iter-cc     : recompiles the emitted C with our own cc invocation.

Defaults are deliberately light: only static+amalgamate run unless
--allow-heavy is passed, so an 8 GB machine never OOMs by accident.

Outputs:
  --out-jsonl PATH  machine-readable per-phase records (default: work/measure.jsonl)
  --out-md PATH     markdown summary table (default: work/measure.md)

Usage:
    python scripts/measure_selfhost.py
    python scripts/measure_selfhost.py --allow-heavy --phases static,amalgamate,seed-cc
    python scripts/measure_selfhost.py --allow-heavy --phases all --cc gcc
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANONICAL_C = os.path.join(ROOT, "compiler", "selfhost", "stage3.exe.c")
AMALGAMATE = os.path.join(ROOT, "scripts", "amalgamate.py")
MAIN_ORB = os.path.join("compiler", "main.orb")
RUNTIME_DIR = os.path.join(ROOT, "runtime")
COMPILER_DIR = os.path.join(ROOT, "compiler")

SUPPRESS_FLAGS = ["-O0", "-w", "-Wno-int-conversion",
                  "-Wno-incompatible-pointer-types", "-DORBIT_WITH_EXEC"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def detect_cc():
    env_cc = os.environ.get("ORBIT_CC")
    if env_cc:
        return env_cc
    for cand in ("gcc", "clang", "cc"):
        if shutil.which(cand):
            return cand
    if shutil.which("zig"):
        return "zig cc"
    return "gcc"


# ---------------------------------------------------------------------------
# System memory (stdlib only, psutil optional)
# ---------------------------------------------------------------------------

def system_snapshot():
    """Return (total_mb, avail_mb) or (None, None) when unavailable."""
    try:
        import psutil  # type: ignore
        vm = psutil.virtual_memory()
        return (vm.total // (1 << 20), vm.available // (1 << 20))
    except Exception:
        pass
    if sys.platform == "win32":
        try:
            import ctypes

            class MEMORYSTATUSEX(ctypes.Structure):
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

            stat = MEMORYSTATUSEX()
            stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
                total = int(stat.ullTotalPhys) // (1 << 20)
                avail = int(stat.ullAvailPhys) // (1 << 20)
                return (total, avail)
        except Exception:
            return (None, None)
    else:
        try:
            with open("/proc/meminfo") as f:
                txt = f.read()
            total = avail = None
            for line in txt.splitlines():
                if line.startswith("MemTotal:"):
                    total = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"):
                    avail = int(line.split()[1]) // 1024
            return (total, avail)
        except Exception:
            return (None, None)
    return (None, None)


# ---------------------------------------------------------------------------
# Process tree RSS sampler (stdlib only)
# ---------------------------------------------------------------------------

def _win_child_pids(root_pid):
    """Return set of descendant pids via Toolhelp snapshot. Best effort."""
    try:
        import ctypes
        from ctypes import wintypes
        TH32CS_SNAPPROCESS = 0x00000002
        kernel32 = ctypes.windll.kernel32
        CreateToolhelp32Snapshot = kernel32.CreateToolhelp32Snapshot
        Process32First = kernel32.Process32FirstW
        Process32Next = kernel32.Process32NextW
        CloseHandle = kernel32.CloseHandle

        class PROCESSENTRY32(ctypes.Structure):
            _fields_ = [
                ("dwSize", wintypes.DWORD),
                ("cntUsage", wintypes.DWORD),
                ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_void_p),
                ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", wintypes.LONG),
                ("dwFlags", wintypes.DWORD),
                ("szExeFile", wintypes.WCHAR * 260),
            ]

        snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
        if snap == wintypes.HANDLE(-1).value:
            return set(), {}
        try:
            parent = {}
            names = {}
            entry = PROCESSENTRY32()
            entry.dwSize = ctypes.sizeof(PROCESSENTRY32)
            ok = Process32First(snap, ctypes.byref(entry))
            while ok:
                parent[entry.th32ProcessID] = entry.th32ParentProcessID
                names[entry.th32ProcessID] = entry.szExeFile
                ok = Process32Next(snap, ctypes.byref(entry))
            out = set()
            changed = True
            frontier = {root_pid}
            while changed:
                changed = False
                for pid, ppid in parent.items():
                    if ppid in frontier and pid not in frontier:
                        frontier.add(pid)
                        out.add(pid)
                        changed = True
            return out, names
        finally:
            CloseHandle(snap)
    except Exception:
        return set(), {}


def _win_rss_mb(pid):
    try:
        import ctypes
        from ctypes import wintypes

        class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
            _fields_ = [
                ("cb", wintypes.DWORD),
                ("PageFaultCount", wintypes.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        kernel32 = ctypes.windll.kernel32
        psapi = ctypes.windll.psapi
        h = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return None, ""
        try:
            counters = PROCESS_MEMORY_COUNTERS()
            counters.cb = ctypes.sizeof(counters)
            if psapi.GetProcessMemoryInfo(h, ctypes.byref(counters), counters.cb):
                exe = ""
                try:
                    buf = ctypes.create_unicode_buffer(260)
                    if psapi.GetModuleBaseNameW(h, None, buf, 260):
                        exe = buf.value
                except Exception:
                    exe = ""
                return (counters.WorkingSetSize // (1 << 20), exe.lower())
            return None, ""
        finally:
            kernel32.CloseHandle(h)
    except Exception:
        return None, ""


def _posix_rss_mb(pid):
    try:
        with open("/proc/%d/status" % pid) as f:
            exe = ""
            try:
                exe = os.path.basename(os.readlink("/proc/%d/exe" % pid)).lower()
            except Exception:
                exe = ""
            for line in f:
                if line.startswith("VmRSS:"):
                    kb = int(line.split()[1])
                    return (kb // 1024, exe)
        return None, ""
    except Exception:
        return None, ""


def _posix_child_pids(root_pid):
    out = set()
    try:
        for name in os.listdir("/proc"):
            if not name.isdigit():
                continue
            pid = int(name)
            try:
                with open("/proc/%d/stat" % pid) as f:
                    parts = f.read().rsplit(")", 1)[1].split()
                    ppid = int(parts[1])
                    if ppid == root_pid:
                        out.add(pid)
                        out |= _posix_child_pids(pid)
            except Exception:
                continue
    except Exception:
        pass
    return out


def is_cc_name(exe_lower):
    for token in ("cc1", "cc1plus", "gcc", "clang", "zig", "collect2", "ld", "as", "cl", "link"):
        if token in exe_lower:
            return True
    return False


class TreeSampler(threading.Thread):
    """Sample a process tree every interval_ms; track per-class peaks."""

    def __init__(self, root_pid, interval_ms=100):
        super().__init__(daemon=True)
        self.root_pid = root_pid
        self.interval = max(20, interval_ms) / 1000.0
        self.stop_flag = threading.Event()
        self.peak_total_mb = 0
        self.peak_orbit_mb = 0
        self.peak_cc_mb = 0
        self.samples = 0
        self.min_avail_mb = None

    def run(self):
        while not self.stop_flag.is_set():
            try:
                self._sample_once()
            except Exception:
                pass
            time.sleep(self.interval)

    def stop(self):
        self.stop_flag.set()
        self.join(timeout=2.0)

    def _sample_once(self):
        if sys.platform == "win32":
            children, names = _win_child_pids(self.root_pid)
            pids = {self.root_pid} | set(children)
            total = 0
            orbit = 0
            ccm = 0
            for pid in pids:
                rss, exe = _win_rss_mb(pid)
                if rss is None:
                    continue
                if not exe:
                    exe = str(names.get(pid, "")).lower()
                total += rss
                if is_cc_name(exe):
                    ccm += rss
                elif exe == "":
                    # Unnamed helper during cc phases is almost always
                    # cc1/collect2/ld spawned by the driver; attribute to
                    # cc so orbit-vs-cc split stays meaningful.
                    ccm += rss
                else:
                    orbit += rss
        else:
            pids = {self.root_pid} | _posix_child_pids(self.root_pid)
            total = 0
            orbit = 0
            ccm = 0
            for pid in pids:
                rss, exe = _posix_rss_mb(pid)
                if rss is None:
                    continue
                total += rss
                if is_cc_name(exe):
                    ccm += rss
                else:
                    orbit += rss
        _, avail = system_snapshot()
        self.samples += 1
        if total > self.peak_total_mb:
            self.peak_total_mb = total
        if orbit > self.peak_orbit_mb:
            self.peak_orbit_mb = orbit
        if ccm > self.peak_cc_mb:
            self.peak_cc_mb = ccm
        if avail is not None:
            if self.min_avail_mb is None or avail < self.min_avail_mb:
                self.min_avail_mb = avail


def run_sampled(argv, cwd, env_extra=None, interval_ms=100, label=""):
    """Run argv with tree sampling; return dict with peaks and timing."""
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    print("Running %s ..." % (label or " ".join(argv[:4])), flush=True)
    total_mb, avail_before = system_snapshot()
    t0 = time.time()
    proc = subprocess.Popen(argv, cwd=cwd, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace")
    sampler = TreeSampler(proc.pid, interval_ms=interval_ms)
    sampler.start()
    try:
        out, _ = proc.communicate()
    finally:
        sampler.stop()
    wall = time.time() - t0
    _, avail_after = system_snapshot()
    if out and out.strip():
        tail = "\n".join(out.rstrip().splitlines()[-15:])
        print(tail)
    return {
        "rc": proc.returncode,
        "wall_s": round(wall, 2),
        "peak_tree_mb": sampler.peak_total_mb,
        "peak_orbit_mb": sampler.peak_orbit_mb,
        "peak_cc_mb": sampler.peak_cc_mb,
        "sys_total_mb": total_mb,
        "sys_avail_before_mb": avail_before,
        "sys_avail_min_mb": sampler.min_avail_mb,
        "sys_avail_after_mb": avail_after,
        "samples": sampler.samples,
    }


# ---------------------------------------------------------------------------
# Static analysis (no subprocess)
# ---------------------------------------------------------------------------

def count_in_file(path, pattern, flags=0):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            txt = f.read()
        return len(re.findall(pattern, txt, flags))
    except OSError:
        return 0


def static_record():
    rec = {"phase": "static"}
    total_mb, avail_mb = system_snapshot()
    rec["sys_total_mb"] = total_mb
    rec["sys_avail_mb"] = avail_mb
    files = {}
    total_orb = 0
    for name in sorted(os.listdir(COMPILER_DIR)):
        if name.endswith(".orb"):
            p = os.path.join(COMPILER_DIR, name)
            try:
                sz = os.path.getsize(p)
            except OSError:
                sz = 0
            files[name] = sz
            total_orb += sz
    rec["compiler_orb_bytes"] = total_orb
    rec["compiler_orb_files"] = files
    try:
        rec["canonical_c_bytes"] = os.path.getsize(CANONICAL_C)
        rec["canonical_c_sha"] = sha256(CANONICAL_C)
    except OSError:
        rec["canonical_c_bytes"] = 0
        rec["canonical_c_sha"] = ""
    rt_total = 0
    for name in sorted(os.listdir(RUNTIME_DIR)):
        if name.endswith(".c") or name.endswith(".h"):
            try:
                rt_total += os.path.getsize(os.path.join(RUNTIME_DIR, name))
            except OSError:
                pass
    rec["runtime_bytes"] = rt_total
    cb = os.path.join(COMPILER_DIR, "c_backend.orb")
    rec["c_backend_out_concat"] = count_in_file(cb, r"out\s*=\s*out\s*\+")
    rec["c_backend_bytes"] = files.get("c_backend.orb", 0)
    builder = os.path.join(COMPILER_DIR, "builder.orb")
    rec["builder_bytes"] = files.get("builder.orb", 0)
    # Risky idioms across compiler sources.
    rec["string_concat_all"] = 0
    rec["list_grow_sites"] = 0
    for name in files:
        p = os.path.join(COMPILER_DIR, name)
        rec["string_concat_all"] += count_in_file(p, r"out\s*=\s*out\s*\+|\+\s*\"")
        if name in ("resolver.orb", "builder.orb", "parser.orb"):
            rec["list_grow_sites"] += count_in_file(p, r"\.push\(")
    rt = os.path.join(RUNTIME_DIR, "collections.c")
    rec["runtime_concat_def"] = count_in_file(rt, r"orbit_string_concat")
    rec["runtime_list_grow_def"] = count_in_file(rt, r"orbit_list_grow")
    fe = os.path.join(COMPILER_DIR, "frontend")
    if os.path.isdir(fe):
        rec["frontend_bytes"] = sum(
            os.path.getsize(os.path.join(fe, n)) for n in os.listdir(fe)
            if n.endswith(".orb"))
    else:
        rec["frontend_bytes"] = 0
    return rec


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Measure self-host resource usage (Phase 0)")
    ap.add_argument("--cc", default=None, help="C compiler (default: auto-detect)")
    ap.add_argument("--work", default=None, help="work dir (default: temp)")
    ap.add_argument("--keep", action="store_true", help="keep work dir")
    ap.add_argument("--interval-ms", type=int, default=100, help="RSS sample period")
    ap.add_argument("--phases", default="static,amalgamate",
                    help="comma list of static,amalgamate,seed-cc,orbit-build,iter-cc,all")
    ap.add_argument("--allow-heavy", action="store_true",
                    help="permit cc/orbit subprocess phases (needs RAM)")
    ap.add_argument("--out-jsonl", default=None, help="JSONL output path")
    ap.add_argument("--out-md", default=None, help="markdown output path")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    phases = [p.strip() for p in args.phases.split(",") if p.strip()]
    if phases == ["all"]:
        phases = ["static", "amalgamate", "seed-cc", "orbit-build", "iter-cc"]
    heavy = {"seed-cc", "orbit-build", "iter-cc"}
    if not args.allow_heavy and any(p in heavy for p in phases):
        out.fail("Failed measure: refusing heavy phases without --allow-heavy on this machine.")
        out.tip("run with --phases static,amalgamate or add --allow-heavy.")
        return 2

    if args.work:
        work = os.path.abspath(args.work)
        os.makedirs(work, exist_ok=True)
    else:
        work = tempfile.mkdtemp(prefix="orbit_measure_")
    if not args.keep and not args.work:
        import atexit
        atexit.register(lambda: shutil.rmtree(work, ignore_errors=True))

    out_jsonl = args.out_jsonl or os.path.join(work, "measure.jsonl")
    out_md = args.out_md or os.path.join(work, "measure.md")
    os.makedirs(os.path.dirname(os.path.abspath(out_jsonl)) or ".", exist_ok=True)

    cc = args.cc or detect_cc()
    cc_cmd = cc.split()
    plat_link = ["-lws2_32"] if os.name == "nt" else []
    exe = ".exe" if sys.platform == "win32" else ""

    records = []
    total_mb, avail_mb = system_snapshot()
    out.say("Measuring from root: %s" % ROOT)
    out.say("Measuring with cc: %s" % cc)
    out.say("Machine: total=%s MB avail=%s MB" % (total_mb, avail_mb))
    out.say("Work dir: %s" % work)

    def emit(rec):
        records.append(rec)
        with open(out_jsonl, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")

    if "static" in phases:
        rec = static_record()
        rec["cc"] = cc
        emit(rec)
        out.say("Measured static: orb=%d KB canon=%d KB runtime=%d KB out_concat=%d" % (
            rec["compiler_orb_bytes"] // 1024,
            rec["canonical_c_bytes"] // 1024,
            rec["runtime_bytes"] // 1024,
            rec["c_backend_out_concat"]))

    amal = os.path.join(work, "orbit_bootstrap.c")
    if "amalgamate" in phases:
        t0 = time.time()
        r = run_sampled([sys.executable, AMALGAMATE, "--entry", CANONICAL_C,
                         "--out", amal],
                        cwd=ROOT, interval_ms=args.interval_ms,
                        label="amalgamate canonical")
        rec = {"phase": "amalgamate", "cc": cc}
        rec.update(r)
        try:
            rec["out_bytes"] = os.path.getsize(amal)
        except OSError:
            rec["out_bytes"] = 0
        rec["in_bytes"] = rec.get("canonical_c_bytes", 0) or 0
        try:
            rec["in_bytes"] = os.path.getsize(CANONICAL_C)
        except OSError:
            pass
        emit(rec)
        if r["rc"] != 0:
            out.fail("Failed measure: amalgamate failed, stopping.")
            write_markdown(out_md, read_all_records(out_jsonl), cc)
            return 2
    else:
        if os.path.isfile(amal) is False and any(p in heavy for p in phases):
            out.fail("Failed measure: need amalgamate output for heavy phases.")
            out.tip("add amalgamate to --phases.")
            return 2

    seed_exe = os.path.join(work, "seed" + exe)
    if "seed-cc" in phases:
        r = run_sampled([*cc_cmd, *SUPPRESS_FLAGS, "-o", seed_exe, amal,
                         *plat_link],
                        cwd=ROOT, interval_ms=args.interval_ms,
                        label="build seed from amalgamated TU")
        rec = {"phase": "seed-cc", "cc": cc}
        rec.update(r)
        try:
            rec["in_bytes"] = os.path.getsize(amal)
        except OSError:
            rec["in_bytes"] = 0
        try:
            rec["out_bytes"] = os.path.getsize(seed_exe)
        except OSError:
            rec["out_bytes"] = 0
        emit(rec)
        if r["rc"] != 0:
            out.fail("Failed measure: seed-cc failed, stopping.")
            write_markdown(out_md, read_all_records(out_jsonl), cc)
            return 2

    iter_c = None
    if "orbit-build" in phases:
        if not os.path.isfile(seed_exe):
            out.fail("Failed measure: seed exe missing for orbit-build.")
            out.tip("add seed-cc to --phases.")
            return 2
        tmp = os.path.join(work, "tmp_build")
        os.makedirs(tmp, exist_ok=True)
        inter_c = os.path.join(tmp, "orbit_selfhost_build.c")
        env_extra = {"TEMP": tmp, "TMP": tmp, "ORBIT_CC": cc, "CC": cc}
        out_exe = os.path.join(work, "iter1" + exe)
        r = run_sampled([seed_exe, "build", MAIN_ORB, "-o", out_exe],
                        cwd=ROOT, env_extra=env_extra,
                        interval_ms=args.interval_ms,
                        label="seed build main.orb (orbit + inner cc)")
        rec = {"phase": "orbit-build", "cc": cc}
        rec.update(r)
        try:
            rec["out_c_bytes"] = os.path.getsize(inter_c)
            rec["out_c_sha"] = sha256(inter_c)
            iter_c = inter_c
        except OSError:
            rec["out_c_bytes"] = 0
            rec["out_c_sha"] = ""
        try:
            rec["out_bytes"] = os.path.getsize(out_exe)
        except OSError:
            rec["out_bytes"] = 0
        emit(rec)
        if r["rc"] != 0 and rec["out_c_bytes"] == 0:
            out.fail("Failed measure: orbit-build failed with no C emitted, stopping.")
            write_markdown(out_md, read_all_records(out_jsonl), cc)
            return 2

    if "iter-cc" in phases:
        src = iter_c
        if src is None:
            cand = os.path.join(work, "tmp_build", "orbit_selfhost_build.c")
            if os.path.isfile(cand):
                src = cand
        if src is None or not os.path.isfile(src):
            out.fail("Failed measure: no emitted C for iter-cc.")
            out.tip("add orbit-build to --phases.")
            return 2
        out_exe = os.path.join(work, "iter1_rebuilt" + exe)
        r = run_sampled([*cc_cmd, *SUPPRESS_FLAGS, "-I",
                         os.path.join(ROOT, "runtime"),
                         "-o", out_exe, src, *plat_link],
                        cwd=ROOT, interval_ms=args.interval_ms,
                        label="build iter compiler from its own C")
        rec = {"phase": "iter-cc", "cc": cc}
        rec.update(r)
        try:
            rec["in_bytes"] = os.path.getsize(src)
        except OSError:
            rec["in_bytes"] = 0
        try:
            rec["out_bytes"] = os.path.getsize(out_exe)
        except OSError:
            rec["out_bytes"] = 0
        emit(rec)
        if r["rc"] != 0:
            out.fail("Failed measure: iter-cc failed.")
            write_markdown(out_md, read_all_records(out_jsonl), cc)
            return 2

    write_markdown(out_md, read_all_records(out_jsonl), cc)
    out.say("Wrote %s and %s" % (out_jsonl, out_md))
    return 0


def read_all_records(path):
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    continue
    except OSError:
        pass
    return out


def write_markdown(path, records, cc):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("# Self-host resource measurement (Phase 0)\n\n")
        f.write("cc: `%s`  platform: `%s`\n\n" % (cc, sys.platform))
        f.write("| phase | wall_s | peak_tree_MB | peak_orbit_MB | peak_cc_MB | in/out |\n")
        f.write("|---|---|---|---|---|---|\n")
        for r in records:
            if r.get("phase") == "static":
                f.write("| static | - | - | - | - | orb=%d KB canon=%d KB runtime=%d KB out_concat=%d |\n" % (
                    r.get("compiler_orb_bytes", 0) // 1024,
                    r.get("canonical_c_bytes", 0) // 1024,
                    r.get("runtime_bytes", 0) // 1024,
                    r.get("c_backend_out_concat", 0)))
            else:
                inout = ""
                if "in_bytes" in r or "out_bytes" in r:
                    ib = r.get("in_bytes", 0) // 1024
                    ob = r.get("out_bytes", 0) // 1024
                    inout = "in=%d KB out=%d KB" % (ib, ob)
                if "out_c_bytes" in r:
                    inout += " c=%d KB" % (r.get("out_c_bytes", 0) // 1024)
                f.write("| %s | %s | %s | %s | %s | %s |\n" % (
                    r.get("phase"), r.get("wall_s"),
                    r.get("peak_tree_mb"), r.get("peak_orbit_mb"),
                    r.get("peak_cc_mb"), inout))
        f.write("\n peak_tree_MB = orbit + cc tree WorkingSet peak during the phase.\n")


if __name__ == "__main__":
    raise SystemExit(main())
