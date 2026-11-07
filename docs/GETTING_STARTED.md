# Getting Started

This guide builds the Orbit compiler and runs a first program. You don't need much - a C compiler and Python are enough.

## 1. Prerequisites

Install:

- Git
- Python 3.10 or newer
- GCC, Clang, or MSVC

Platform details are listed in [Platform Support](SUPPORTED.md#platforms).

## 2. Build Orbit

Clone the repository and enter its root:

```sh
git clone https://github.com/joacokhzyx/orbit-lang.git
cd orbit-lang
```

Build the compiler from the repository sources:

### Windows PowerShell

```powershell
python scripts/trust.py build --out orbit.exe
```

### Linux or macOS

```sh
python3 scripts/trust.py build --out orbit
```

When automatic compiler detection is insufficient, pass `--cc gcc`, `--cc clang`, or `--cc cl` explicitly. You can also set `ORBIT_CC`. See [Platform Support](SUPPORTED.md#platforms).

The commands above create a local executable in the repository root. Unless you install Orbit or add that directory to `PATH`, invoke the compiler using its local path as shown below.

If you are contributing to the compiler itself, finish this guide first, then continue with the [contributor trust appendix](#appendix-contributor-trust-workflow) at the bottom.

## 3. Write a First Program

Create `hello.orb`:

```orbit
fn main() -> int {
    return 0
}
```

Build it with the compiler you just built:

```sh
./orbit build hello.orb -o hello
```

On Windows, the output normally uses an `.exe` suffix:

```powershell
.\orbit.exe build hello.orb -o hello.exe
```

Run it:

```sh
./hello
```

```powershell
.\hello.exe
```

## 4. Try an HTTP Example

The repository includes service examples in [examples/README.md](../examples/README.md). Start with `health_service.orb` for a service without database setup:

```sh
./orbit build examples/health_service.orb -o health_service
./health_service 8080
```

On Windows:

```powershell
.\orbit.exe build examples/health_service.orb -o health_service.exe
.\health_service.exe 8080
```

The first argument is the port; with none, the service uses 3000 (or the `port` its file declares). Open <http://localhost:8080/health> and the service answers `{"status":"UP","version":"0.1.0","uptime_seconds":N}`. `0` asks the system for a free port, and the banner prints the one it got.

Database examples require the SQLite support described in [Platform Support](SUPPORTED.md#platforms).

## 5. Editor Setup

The installer registers the VS Code extension automatically. For a manual setup, see [VS Code Integration](../editors/vscode/README.md).

## Troubleshooting

Toolchain problems are covered in [Platform Support](SUPPORTED.md#platforms). Symptoms
you'll meet while running a service are in the
[troubleshooting tutorial](tutorials/troubleshooting.md).

## Appendix: contributor trust workflow

This section is for contributors changing the compiler itself. Newcomers stop after section 5.

Build a fixed-point compiler from the committed canonical C source, then verify convergence and the canonical. Replace the compiler path with `orbit.exe` on Windows or `orbit` on Linux/macOS, and pick a C compiler for `<gcc-or-clang>`:

```sh
python scripts/trust.py build --out <path-to-orbit>
python scripts/trust.py verify --cc <gcc-or-clang> --emit-fixed-point <path-to-orbit>
python scripts/corpus_gates.py parity --cc <gcc-or-clang> --compiler <path-to-orbit>
python scripts/corpus_gates.py suite --cc <gcc-or-clang> --compiler <path-to-orbit>
```

The parity command compares the compiler output with committed probe goldens. The behavior suite compiles and runs the executable programs under `tests/suite/`. The full model is described in [Self-Hosting](internals/SELF_HOSTING.md) and [Sovereignty](internals/SOVEREIGNTY.md).

## A thirty-minute tour

### 1. Functions (3 min)

```orbit
fn add(left: int, right: int) -> int {
    return left + right
}

fn main() -> int {
    return add(20, 22)
}
```

Build, run, check the exit code: **42**. `fn main() -> int`
is the entry point. Its return value is the process exit code,
which is how the test suite asserts behavior, too.

### 2. Bindings and types (3 min)

```orbit
fn main() -> int {
    val name = "orbit"
    val retries: int = 3
    var mut total: int = 0
    total = total + retries
    return total + name.len()
}
```

`val` never changes. `var mut` does. Annotations are optional
when inference is enough. `name.len()` is 5, so this exits **8**.
(Verified pattern: `.len()` on strings, per the behavior suite.)

### 3. Control flow (3 min)

```orbit
fn fact(n: int) -> int {
    if n <= 1 {
        return 1
    }
    return n * fact(n - 1)
}

fn main() -> int {
    return fact(5)
}
```

Recursion, `if`, and comparison work as you'd expect. Exit code:
**120**. Loops use `for … in` and `while`, with `break` and
`continue` inside them.

### 4. Models (3 min)

```orbit
model Rect {
    width: int
    height: int
}

fn main() -> int {
    val r = Rect(3, 4)
    return r.width + r.height
}
```

Models are named records. Construct with positional fields, read
with dot access. Exit code: **7**.

### 5. Result values and try/catch (4 min)

```orbit
fn load_value() -> result {
    val value: result = ok(41)
    return value
}

fn read_value() -> int {
    val value: int = try load_value() catch {
        return 0
    }
    return value
}

fn main() -> int {
    return read_value() + 1
}
```

`ok()` and `err()` build `result` values in expressions - don't
confuse them with the route forms `return ok 200 …` and
`err 400 …` below. `try` unwraps or jumps to `catch`. Exit code:
**42**. Naming a variable after `catch` binds the error message:
`try load_value() catch e { print(e) }`.

### 6. Your first service (5 min)

```orbit
route GET "/health" {
    val uptime = system.uptime()
    return ok { status: "UP", uptime_seconds: uptime }
}
```

Build it and give it a port - the server reads its port from the
first argument:

```sh
./orbit build health.orb -o health
./health 8080
curl http://127.0.0.1:8080/health
```

Windows (PowerShell):

```powershell
.\orbit.exe build health.orb -o health.exe
.\health.exe 8080
curl.exe http://127.0.0.1:8080/health
```

On Windows use `curl.exe` (bare `curl` is an alias for
`Invoke-WebRequest`). The `curl` examples in steps 7-9 work the same
way on either platform.

Expected (from a real run of `examples/health_service.orb`):

```text
{"status":"UP","version":"0.1.0","uptime_seconds":0}
```

Stop it with Ctrl-C on either platform. On Windows, keep `sqlite3.dll` out of the
picture here - this service uses no database, so it needs none.

### 7. Query values and branching (4 min)

```orbit
route GET "/greet" {
    val name = req.query("name")
    if (name == "") {
        err 401 """{"error":"pass ?name="}"""
    } else {
        return ok { hello: name }
    }
}
```

`curl "http://127.0.0.1:8080/greet?name=ada"` → `200` with
`{"hello":"ada"}`. Without the query value → `401`. Verified
pattern from the tutorial services. `err 401 …` inside the `if`
works the same way when you prefer it.

### 8. Reads from SQLite (3 min)

```orbit
model Note {
    id: string
    title: string
    body: string
    author_id: string
    created_at: string
    is_private: bool
}

route GET "/notes" {
    val notes = Note.all()
    return ok 200 notes
}

route GET "/by-author" {
    val who = req.query("author")
    val found = Note.where("author_id = ?", who)
    return ok 200 found
}
```

On first start the runtime creates `orbit.db` in the working
directory and seeds demo rows, so `GET /notes` answers `200`
immediately. The `?` placeholder keeps input parameterized -
never build SQL by concatenating query values. Writes via
`Note.create()` store the row and answer `true` (duplicates
answer `false`). See [Known Limitations](internals/LIMITATIONS_LOG.md).

### 9. Live telemetry (2 min)

```orbit
route GET "/metrics" {
    val total = system.http_requests_total()
    val latency = system.latency_avg_us()
    val workers = system.active_workers()
    return ok { metrics: { http_requests_total: total, latency_avg_us: latency, active_workers: workers } }
}
```

Real run after three requests:

```text
{"metrics":{"http_requests_total":3,"latency_avg_us":358,"active_workers":8}}
```

Every value is measured. A percentile is estimated inside the histogram bucket
that holds it: `system.latency_p50_us()`, `latency_p95_us()` and
`latency_p99_us()` read a 100 µs-resolution histogram that also sums each
bucket's microseconds, so the answer sits where the rank falls between the
bucket's edges rather than at its top. `/_ledger` and
`/_ledger/data` add a per-route table (requests, mean ms, DB share) with
no code.

### Where next (in order)

1. [Blog API tutorial](tutorials/blog-api.md) - a full runnable
   service with key-checked writes and expected outputs.
2. [File server tutorial](tutorials/file-server.md) - listing,
   content, and raw-body uploads.
3. [Troubleshooting](tutorials/troubleshooting.md) - ports,
   sqlite3.dll, slow first boot, stale canonical.
4. [FAQ](SUPPORTED.md#frequently-asked-questions) - twenty questions, hard ones included.
5. [Language Reference](LANGUAGE_REFERENCE.md) - the full contract.
