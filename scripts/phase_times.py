#!/usr/bin/env python3
"""Wall and CPU time per compiler phase, for a program you name.

The compiler already reports where its stages end when ORBIT_MEM_REPORT is set:
pipeline.orb calls reportMemStage after parse, resolve, sema, buildAST and
generateC+generateCHeader, and each call writes one `[mem] <stage> ...` line to
stderr. This script stamps the arrival of those lines, so a phase boundary that
exists in the binary can be measured without touching compiler sources.

The boundaries, in the order pipeline.orb writes them:

  parse      start -> `[mem] parse`      parseProgram
  resolve    -> `[mem] resolve`          resolveModuleAST
  sema       -> `[mem] sema`             analyze + reportResolutionGaps
  builder    -> `[mem] build`            buildAST
  c-emit     -> `[mem] codegen`          optimizeIRModule + cteOptimize
                                         + generateC + generateCHeader
  emit-write -> the `cc ` line           verifyModuleTypes + write the C and
                                         the shard header + app resource
  cc         -> process exit             the C compiler and the linker

Two phases are bundled and are named that way in the output. `c-emit` bundles
the two optimizer passes with C emission: there is no reportMemStage call
between them, and adding one would change compiler sources. `emit-write`
bundles the IR type verification with writing the intermediate C.

`check` is measured as its own process. The check path calls neither
reportMemStage nor the builder, so it has no internal split; the split above is
the same front end running inside `build`, which is why `check` and
parse+resolve+sema are both reported and should be close.

The `cc` boundary is the `cc <command>` line that `--verbose` prints on stdout
immediately before the compiler runs. It is the only observable edge between
Orbit's work and the C toolchain's, and it is what makes a full build splittable
into one process instead of two.

CPU time is per process, not per phase. A job object totals the process and its
children (the C compiler is a child), and the stage stamps are wall edges only,
so `check` and `total` carry CPU and the phases between them do not. On Windows
the accounting advances with the scheduler quantum, so a process shorter than
about 15 ms can read 0.0 s; `hello`'s check is one.

Usage:
    python scripts/phase_times.py --compiler PATH
    python scripts/phase_times.py --compiler PATH --runs 20 --only main
    python scripts/phase_times.py --compiler PATH --self-test
    python scripts/phase_times.py --compiler PATH --json out.json

A run that cannot produce a stage is a failure, not a blank cell: a missing
`[mem]` line, a missing `cc` line, or a non-zero exit is counted and the
closing line is red.
"""

import argparse
import ctypes
import json
import math
import os
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import orbit_output as out
from _common import build_env, resolve_cc

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_WORK = os.path.join(ROOT, "scratch", "phase")
MAIN_ORB = os.path.join("compiler", "host", "main.orb")

STAGE_RE = re.compile(r"^\[mem\] (parse|resolve|sema|build|codegen)(?: |$)")
# The stage order pipeline.orb writes. A phase is scored only when every earlier
# boundary arrived, so a truncated build cannot be read as a fast one.
STAGE_ORDER = ["parse", "resolve", "sema", "build", "codegen"]
PHASE_ORDER = ["check", "parse", "resolve", "sema", "builder", "c-emit",
               "emit-write", "cc", "total"]
PROGRAM_ORDER = ["hello", "gen10k", "main"]

# The 10k-function program. Deliberately flat and bodyless: it exists to put
# 10,000 function bodies through the front end, the builder and the emitter, and
# nothing else. Chaining or recursion would measure the call graph instead.
GEN10K_TEMPLATE = (
    "fn gen_{i}() -> int {{\n"
    "    return {i}\n"
    "}}\n\n"
)
GEN10K_MAIN = (
    "fn main() -> int {\n"
    "    print(gen_1() + gen_5000() + gen_10000())\n"
    "    return 0\n"
    "}\n"
)


# ---------------------------------------------------------------------------
# CPU accounting for a process and its children
# ---------------------------------------------------------------------------

class _JobAccounting:
    """Windows: a job object totals the CPU of every process in it.

    `subprocess` can report one process's times after it exits, not its
    children's, and the phase that matters most (`cc`) is a child. Counting
    GetProcessTimes on the tree while it runs misses work; a job object keeps
    the total for exited members too. The process is assigned a few
    milliseconds after spawn, so any grandchild started in that window escapes
    the total -- the compiler spends seconds before it starts the C compiler,
    so in practice the whole `cc` subtree is counted, and a run whose
    assignment failed reports cpu as unavailable instead of guessing.
    """

    JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION = 1
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9

    class _Basic(ctypes.Structure):
        _fields_ = [
            ("TotalUserTime", ctypes.c_int64),
            ("TotalKernelTime", ctypes.c_int64),
            ("ThisPeriodTotalUserTime", ctypes.c_int64),
            ("ThisPeriodTotalKernelTime", ctypes.c_int64),
            ("TotalPageFaultCount", ctypes.c_uint32),
            ("TotalProcesses", ctypes.c_uint32),
            ("ActiveProcesses", ctypes.c_uint32),
            ("TotalTerminatedProcesses", ctypes.c_uint32),
        ]

    class _IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in (
            "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
            "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

    class _Extended(ctypes.Structure):
        _fields_ = [
            ("PerProcessUserTimeLimit", ctypes.c_int64),
            ("PerJobUserTimeLimit", ctypes.c_int64),
            ("LimitFlags", ctypes.c_uint32),
            ("MinimumWorkingSetSize", ctypes.c_size_t),
            ("MaximumWorkingSetSize", ctypes.c_size_t),
            ("ActiveProcessLimit", ctypes.c_uint32),
            ("Affinity", ctypes.c_size_t),
            ("PriorityClass", ctypes.c_uint32),
            ("SchedulingClass", ctypes.c_uint32),
        ]

    def __init__(self):
        self.handle = None
        self.error = ""
        self.kernel32 = None

    def attach(self, proc):
        try:
            self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            k32 = self.kernel32
            k32.CreateJobObjectW.restype = ctypes.c_void_p
            self.handle = k32.CreateJobObjectW(None, None)
            if not self.handle:
                self.error = "CreateJobObject failed"
                return
            ext = self._Extended()
            ext.LimitFlags = 0  # accounting only, no limits imposed
            k32.SetInformationJobObject(ctypes.c_void_p(self.handle),
                                        self.JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
                                        ctypes.byref(ext), ctypes.sizeof(ext))
            ok = k32.AssignProcessToJobObject(ctypes.c_void_p(self.handle),
                                              ctypes.c_void_p(int(proc._handle)))
            if not ok:
                self.error = ("AssignProcessToJobObject failed (%d)"
                              % ctypes.get_last_error())
        except Exception as exc:  # pragma: no cover - defensive on odd hosts
            self.error = str(exc)

    def cpu_seconds(self):
        if not self.handle:
            return None
        try:
            info = self._Basic()
            ok = self.kernel32.QueryInformationJobObject(
                ctypes.c_void_p(self.handle),
                self.JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION,
                ctypes.byref(info), ctypes.sizeof(info), None)
            if not ok:
                return None
            # FILETIME ticks: 100 ns each.
            return (info.TotalUserTime + info.TotalKernelTime) / 1e7
        except Exception:
            return None

    def close(self):
        if self.handle:
            try:
                self.kernel32.CloseHandle(ctypes.c_void_p(self.handle))
            except Exception:
                pass
            self.handle = None


def _child_cpu_delta():
    """POSIX: RUSAGE_CHILDREN totals every reaped child, so sequential runs
    give a clean delta. Not used on Windows, where it is a no-op."""
    try:
        import resource
        r = resource.getrusage(resource.RUSAGE_CHILDREN)
        return r.ru_utime + r.ru_stime
    except Exception:
        return None


# ---------------------------------------------------------------------------
# One measured process
# ---------------------------------------------------------------------------

class Run:
    """One child process: exit code, wall, CPU, and timestamped output lines."""

    def __init__(self, argv, cwd, env, timeout):
        self.argv = argv
        self.rc = None
        self.wall = None
        self.cpu = None
        self.cpu_note = ""
        self.lines = []          # (seconds since start, "out"|"err", text)
        self.output = ""
        self.timed_out = False
        self._timeout = timeout
        self._cwd = cwd
        self._env = env
        self._run()

    def _run(self):
        started = time.perf_counter()
        proc = subprocess.Popen(
            self.argv, cwd=self._cwd, env=self._env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, errors="replace", bufsize=1,
        )
        job = None
        posix_before = None
        if os.name == "nt":
            job = _JobAccounting()
            job.attach(proc)
        else:
            posix_before = _child_cpu_delta()

        lock = threading.Lock()
        collected = []

        def pump(stream, name):
            for line in stream:
                stamp = time.perf_counter() - started
                with lock:
                    collected.append((stamp, name, line.rstrip("\r\n")))

        threads = [
            threading.Thread(target=pump, args=(proc.stdout, "out"), daemon=True),
            threading.Thread(target=pump, args=(proc.stderr, "err"), daemon=True),
        ]
        for t in threads:
            t.start()
        try:
            proc.wait(timeout=self._timeout)
        except subprocess.TimeoutExpired:
            self.timed_out = True
            proc.kill()
            proc.wait()
        for t in threads:
            t.join(timeout=5)
        self.wall = time.perf_counter() - started
        self.rc = proc.returncode
        if job is not None:
            self.cpu = job.cpu_seconds()
            self.cpu_note = job.error
            job.close()
        else:
            after = _child_cpu_delta()
            if posix_before is not None and after is not None:
                self.cpu = after - posix_before
        with lock:
            self.lines = sorted(collected, key=lambda item: item[0])
        self.output = "\n".join(text for _t, _n, text in self.lines)

    def find(self, predicate):
        for stamp, _name, text in self.lines:
            if predicate(text):
                return stamp, text
        return None

    def exit_seconds(self):
        """When the process stopped doing work. The last line is the last
        evidence of life; the gap between it and wait() is not the program's."""
        return self.lines[-1][0] if self.lines else self.wall


def stage_stamps(run):
    """stage -> arrival seconds, only for stages that arrived in order."""
    found = {}
    for stamp, _name, text in run.lines:
        m = STAGE_RE.match(text)
        if m:
            found.setdefault(m.group(1), stamp)
    ordered = {}
    previous = 0.0
    for stage in STAGE_ORDER:
        if stage not in found or found[stage] < previous:
            break
        ordered[stage] = found[stage]
        previous = found[stage]
    return ordered


def cc_stamp(run):
    """Arrival of `cc <command>`, printed by --verbose just before the toolchain
    runs. `rc <path>` (the app resource) can precede it on Windows."""
    hit = run.find(lambda text: text.startswith("cc ") and " -o " in text)
    return hit


def phases_of_check(run):
    return {"check": (run.wall, run.cpu)}


def phases_of_build(run):
    """Every phase that can be isolated from one build process."""
    stamps = stage_stamps(run)
    cc_hit = cc_stamp(run)
    end = run.exit_seconds()
    vals = {}
    if "parse" in stamps:
        vals["parse"] = stamps["parse"]
    if "resolve" in stamps:
        vals["resolve"] = stamps["resolve"] - stamps["parse"]
    if "sema" in stamps:
        vals["sema"] = stamps["sema"] - stamps["resolve"]
    if "build" in stamps:
        vals["builder"] = stamps["build"] - stamps["sema"]
    if "codegen" in stamps:
        vals["c-emit"] = stamps["codegen"] - stamps["build"]
    if cc_hit is not None and "codegen" in stamps:
        vals["emit-write"] = cc_hit[0] - stamps["codegen"]
    if cc_hit is not None:
        vals["cc"] = end - cc_hit[0]
    vals["total"] = run.wall
    phases = {}
    for name in PHASE_ORDER:
        if name in vals:
            cpu = run.cpu if name == "total" else None
            phases[name] = (max(0.0, vals[name]), cpu)
    return phases


# ---------------------------------------------------------------------------
# Programs
# ---------------------------------------------------------------------------

def write_gen10k(path, count=10000):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for i in range(1, count + 1):
            f.write(GEN10K_TEMPLATE.format(i=i))
        f.write(GEN10K_MAIN)


def programs(work, cc):
    """name -> source path, after materialising the two generated programs."""
    os.makedirs(work, exist_ok=True)
    hello = os.path.join(work, "hello.orb")
    with open(hello, "w", encoding="utf-8", newline="\n") as f:
        f.write("fn main() -> int {\n"
                "    print(\"hello, orbit\")\n"
                "    return 0\n"
                "}\n")
    gen10k = os.path.join(work, "gen_10k.orb")
    if not os.path.isfile(gen10k):
        write_gen10k(gen10k)
    return {
        "hello": hello,
        "gen10k": gen10k,
        "main": os.path.join(ROOT, MAIN_ORB),
    }


def build_argv(compiler, source, binary):
    return [compiler, "build", source, "-o", binary, "--verbose"]


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

def percentile(values, p):
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    k = max(0, min(len(vals) - 1, math.ceil(p / 100.0 * len(vals)) - 1))
    return vals[k]


def ms(seconds):
    return "-" if seconds is None else "%.1f" % (seconds * 1000.0)


def rc_label(rcs):
    """Distinct exit codes, with the count when one of them is not zero."""
    if not rcs:
        return "-"
    bad = [rc for rc in rcs if rc != 0]
    if not bad:
        return "0"
    return "%s x%d" % (bad[0], len(bad))


# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------

def measure_program(name, source, compiler, cc, work, runs, timeout, say):
    binary = os.path.join(work, name + ".exe" if os.name == "nt" else name)
    env = build_env(work, cc=cc)
    env["ORBIT_MEM_REPORT"] = "1"
    # -Wall stays on: it is what a user build gets. The bootstrap turns it off
    # for its own 5 MB unit, which is a different question from this one.
    env.pop("ORBIT_WARNINGS", None)
    env.pop("ORBIT_SKIP_CC", None)

    check_argv = [compiler, "check", source]
    check_env = dict(env)
    check_env.pop("ORBIT_MEM_REPORT", None)

    # The first build is the cold sample and the warm-up in one: file cache is
    # cold for this program, and its result is reported separately, not pooled.
    say("  %s: cold build + check ..." % name)
    cold_build = Run(build_argv(compiler, source, binary), ROOT, env, timeout)
    cold_check = Run(check_argv, ROOT, check_env, timeout)
    cold = {
        "build": cold_build,
        "check": cold_check,
        "phases": phases_of_build(cold_build),
    }
    failures = []
    if cold_build.rc != 0:
        failures.append("%s: cold build exit %s" % (name, cold_build.rc))
    if cold_check.rc != 0:
        failures.append("%s: cold check exit %s" % (name, cold_check.rc))

    say("  %s: %d measured run(s) ..." % (name, runs))
    samples = {phase: [] for phase in PHASE_ORDER}
    rcs = []
    check_rcs = []
    build_rcs = []
    for index in range(1, runs + 1):
        build = Run(build_argv(compiler, source, binary), ROOT, env, timeout)
        check = Run(check_argv, ROOT, check_env, timeout)
        rcs.append(("check", check.rc, index))
        rcs.append(("build", build.rc, index))
        check_rcs.append(check.rc)
        build_rcs.append(build.rc)
        if check.rc != 0:
            failures.append("%s: run %d check exit %s" % (name, index, check.rc))
        if build.rc != 0:
            failures.append("%s: run %d build exit %s, %d output line(s)"
                            % (name, index, build.rc, len(build.lines)))
        for phase, (wall, cpu) in phases_of_check(check).items():
            samples[phase].append((wall, cpu))
        for phase, (wall, cpu) in phases_of_build(build).items():
            samples[phase].append((wall, cpu))
        say("    run %d: build %s ms, check %s ms, rc %s/%s"
            % (index, ms(build.wall), ms(check.wall), check.rc, build.rc))
        if index == runs:
            last = {"build": build, "check": check}

    return {
        "name": name,
        "source": os.path.relpath(source, ROOT),
        "samples": samples,
        "cold": cold,
        "rcs": rcs,
        "check_rcs": check_rcs,
        "build_rcs": build_rcs,
        "failures": failures,
        "cpu_note": last["build"].cpu_note if runs else "",
        "cc_command": (cc_stamp(last["build"])[1] if runs and
                       cc_stamp(last["build"]) else ""),
    }


def print_program(result, say):
    samples = result["samples"]
    totals = [wall for wall, _cpu in samples.get("total", [])]
    total_p50 = percentile(totals, 50)
    cold_phases = result["cold"]["phases"]
    cold_total = result["cold"]["build"].wall

    say("")
    say("%s  (%s)" % (result["name"], result["source"]))
    say("  %-12s %3s %11s %11s %10s %10s %8s %7s"
        % ("phase", "n", "wall p50", "wall p99", "cpu p50", "cpu p99",
           "rc", "% tot"))
    for phase in PHASE_ORDER:
        rows = samples.get(phase, [])
        if not rows:
            continue
        walls = [w for w, _c in rows]
        cpus = [c for _w, c in rows]
        share = "-"
        if phase != "check" and phase != "total" and total_p50:
            p50 = percentile(walls, 50)
            if p50 is not None:
                share = "%.0f%%" % (100.0 * p50 / total_p50)
        rc = rc_label(result["check_rcs"] if phase == "check"
                      else result["build_rcs"])
        say("  %-12s %3d %11s %11s %10s %10s %8s %7s"
            % (phase, len(rows), ms(percentile(walls, 50)),
               ms(percentile(walls, 99)), ms(percentile(cpus, 50)),
               ms(percentile(cpus, 99)), rc, share))
    say("  cold (first invocation, not pooled): build %s ms, check %s ms"
        % (ms(cold_total), ms(result["cold"]["check"].wall)))
    cold_cells = " ".join("%s=%s" % (p, ms(cold_phases[p][0]))
                          for p in PHASE_ORDER if p in cold_phases)
    say("  cold phases: %s" % cold_cells)
    if result["cpu_note"]:
        say("  cpu unavailable: %s" % result["cpu_note"])
    if result["cc_command"]:
        say("  cc: %s" % result["cc_command"])


def write_json(path, results, meta):
    doc = {"meta": meta, "programs": []}
    for result in results:
        entry = {"name": result["name"], "source": result["source"],
                 "rcs": result["rcs"], "failures": result["failures"],
                 "cold": {"build_wall": result["cold"]["build"].wall,
                          "check_wall": result["cold"]["check"].wall,
                          "phases": {k: v[0] for k, v in
                                     result["cold"]["phases"].items()}},
                 "phases": {}}
        for phase, rows in result["samples"].items():
            entry["phases"][phase] = {
                "n": len(rows),
                "wall": [w for w, _c in rows],
                "cpu": [c for _w, c in rows],
                "wall_p50": percentile([w for w, _c in rows], 50),
                "wall_p99": percentile([w for w, _c in rows], 99),
                "cpu_p50": percentile([c for _w, c in rows if c is not None], 50),
                "cpu_p99": percentile([c for _w, c in rows if c is not None], 99),
            }
        doc["programs"].append(entry)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")


# ---------------------------------------------------------------------------
# Self-test: the harness must be able to fail
# ---------------------------------------------------------------------------

def self_test(compiler, cc, work, timeout, say):
    """Two ways this tool must say no. Both run; both must behave.

    1. A compiler path that is not a file is refused before any measurement,
       with exit 2 and a message, not an empty table.
    2. A program that cannot build produces a non-zero rc, is recorded as a
       failure, and stops the run from closing green.
    """
    passed = 0
    total = 0

    total += 1
    bogus = os.path.join(work, "no-such-compiler.exe")
    rc, message = validate_compiler(bogus)
    if rc == 2 and "not a file" in message:
        say("  ok    invalid compiler path refused: %s" % message)
        passed += 1
    else:
        out.fail("Failed phase-times: invalid compiler path returned %d (%s)"
                 % (rc, message))
        say("  FAIL  invalid compiler path: rc %d, %r" % (rc, message))

    total += 1
    bad = os.path.join(work, "cannot_build.orb")
    with open(bad, "w", encoding="utf-8", newline="\n") as f:
        f.write("fn main() -> int {\n    print(\"unterminated\n}\n")
    say("  building a program with a syntax error ...")
    run = Run([compiler, "build", bad, "-o",
               os.path.join(work, "cannot_build.exe")],
              ROOT, build_env(work, cc=cc), timeout)
    if run.rc != 0:
        say("  ok    non-zero build recorded: exit %d, %d line(s) of output"
            % (run.rc, len(run.lines)))
        passed += 1
    else:
        out.fail("Failed phase-times: a program with a syntax error exited 0")
        say("  FAIL  non-zero build: exit 0")

    out.finish("phase-times", passed, total, "(self-test)")
    return 0 if passed == total else 1


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def validate_compiler(path):
    """Return (rc, message). rc 0 means the path exists and speaks `orbit`."""
    if not path:
        return 2, "no --compiler given"
    full = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
    if not os.path.exists(full):
        return 2, "not a file: %s" % path
    if os.path.isdir(full):
        return 2, "not a file: %s is a directory" % path
    try:
        proc = subprocess.run([full, "--version"], capture_output=True,
                              text=True, timeout=60)
    except Exception as exc:
        return 2, "could not run %s (%s)" % (path, exc)
    first = (proc.stdout or proc.stderr or "").strip().splitlines()
    line = first[0] if first else ""
    if proc.returncode != 0 or not line.startswith("orbit"):
        return 2, "%s did not answer `--version` with an orbit banner (%r)" % (
            path, line)
    return 0, line


def main():
    ap = argparse.ArgumentParser(
        description="Wall and CPU time per compiler phase, for three programs.")
    ap.add_argument("--compiler", required=True,
                    help="path to an existing orbit compiler binary")
    ap.add_argument("--cc", default=None,
                    help="C compiler the inner build uses (default: ORBIT_CC/CC on PATH)")
    ap.add_argument("--runs", type=int, default=5,
                    help="measured runs after one warm-up (default 5)")
    ap.add_argument("--only", action="append", default=None,
                    choices=PROGRAM_ORDER,
                    help="measure only this program; repeatable")
    ap.add_argument("--work", default=DEFAULT_WORK,
                    help="scratch directory (default scratch/phase)")
    ap.add_argument("--timeout", type=int, default=1800,
                    help="per-process timeout in seconds (default 1800)")
    ap.add_argument("--json", default=None, help="write the samples as JSON")
    ap.add_argument("--self-test", action="store_true",
                    help="check that the harness can fail, then exit")
    out.add_quiet(ap)
    args = ap.parse_args()
    out.set_quiet(args.quiet)

    work = os.path.abspath(args.work)
    os.makedirs(work, exist_ok=True)

    rc, message = validate_compiler(args.compiler)
    if rc != 0:
        out.fail("Failed phase-times: %s" % message)
        out.tip("pass --compiler PATH to an existing orbit binary, for example "
                ".orbit/shared/chain3.exe on Windows")
        return 2
    compiler = os.path.abspath(args.compiler)
    say = out.say
    say("Measuring with %s (%s)" % (compiler, message))
    say("Work dir: %s" % work)

    cc = resolve_cc(args.cc)

    if args.self_test:
        return self_test(compiler, cc, work, args.timeout, say)

    say("C compiler for the inner build: %s" % cc)

    wanted = args.only or PROGRAM_ORDER
    sources = programs(work, cc)
    results = []
    failures = []
    for name in PROGRAM_ORDER:
        if name not in wanted:
            continue
        result = measure_program(name, sources[name], compiler, cc, work,
                                 max(1, args.runs), args.timeout, say)
        results.append(result)
        failures.extend(result["failures"])

    for result in results:
        print_program(result, say)

    if args.json:
        write_json(os.path.abspath(args.json), results, {
            "compiler": compiler,
            "compiler_version": message,
            "cc": cc,
            "platform": sys.platform,
            "runs": args.runs,
            "note": "p99 over n=5 is the largest sample; raise --runs for a "
                    "percentile that is not the maximum.",
        })
        say("")
        say("Wrote %s" % args.json)

    say("")
    total = len(results)
    ok = sum(1 for r in results if not r["failures"])
    if failures:
        for line in failures:
            out.fail("Failed %s" % line)
    out.finish("phase-times", ok, total,
               "(%d program(s), %d run(s), %s)"
               % (total, max(1, args.runs), sys.platform))
    return 0 if ok == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
