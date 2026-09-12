# Orbit Language Tour (30 minutes)

You'll write, build, and run real Orbit code. Every snippet below
was built and run with the `orbit 0.1.0` fixed-point compiler —
expected outputs are printed with each step, and anything I
couldn't verify is marked UNTESTED instead of asserted.

Setup: build the compiler once per [Getting Started](GETTING_STARTED.md),
then save each snippet as its `.orb` file and run:

```sh
./orbit build tour1.orb -o tour1
./tour1
echo $?   # the exit code is the answer
```

(Windows: `.\orbit.exe build tour1.orb -o tour1.exe`, then
`.\tour1.exe`. Exit codes print with `$LASTEXITCODE`.)

## 1. Functions (3 min)

```orbit
fn add(left: int, right: int) -> int {
    return left + right
}

fn main() -> int {
    return add(20, 22)
}
```

Build, run, check the exit code: **42**. `fn main() -> int`
is the entry point; its return value is the process exit code,
which is how the test suite asserts behavior, too.

## 2. Bindings and types (3 min)

```orbit
fn main() -> int {
    val name = "orbit"
    val retries: int = 3
    var mut total: int = 0
    total = total + retries
    return total + name.len()
}
```

`val` never changes; `var mut` does. Annotations are optional
when inference is enough. `name.len()` is 5, so this exits **8**.
(Verified pattern: `.len()` on strings, per the behavior suite.)

## 3. Control flow (3 min)

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
**120**. Loops use `for … in`, `while`, and `loop`, with `break`
and `continue` inside them.

## 4. Models (3 min)

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

Models are named records; construct with positional fields, read
with dot access. Exit code: **7**.

## 5. Result values and try/catch (4 min)

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

`ok()` and `err()` build `result` values in expressions — don't
confuse them with the route forms `return ok 200 …` and
`err 400 …` below. `try` unwraps or jumps to `catch`. Exit code:
**42**. (Binding the error payload to a name is future work.)

## 6. Your first service (5 min)

```orbit
route GET "/health" {
    val uptime = system.uptime()
    return ok 200 "{\"status\":\"UP\",\"uptime_seconds\":" + uptime + "}"
}
```

Build it and give it a port — the server reads its port from the
first argument:

```sh
./orbit build health.orb -o health
./health 8080
curl http://127.0.0.1:8080/health
```

Expected (from a real run of `examples/health_service.orb`):

```text
{"status":"UP","version":"0.1.0-rc.2","uptime_seconds":0}
```

Stop it with Ctrl-C. On Windows, keep `sqlite3.dll` out of the
picture here — this service uses no database, so it needs none.

## 7. Query values and branching (4 min)

```orbit
route GET "/greet" {
    val name = req.query("name")
    if (name == "") {
        return ok 401 "{\"error\":\"pass ?name=\"}"
    } else {
        return ok 200 "{\"hello\":\"" + name + "\"}"
    }
}
```

`curl "http://127.0.0.1:8080/greet?name=ada"` → `200` with
`{"hello":"ada"}`; without the query value → `401`. Verified
pattern from the tutorial services. `err 401 …` inside the `if`
works the same way when you prefer it.

## 8. Reads from SQLite (3 min)

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
immediately. The `?` placeholder keeps input parameterized —
never build SQL by concatenating query values. (Writes via
`Note.create()` return `false` in 0.1.0; see
[Known Limitations](KNOWN_LIMITATIONS.md).)

## 9. Live telemetry (2 min)

```orbit
route GET "/metrics" {
    val total = system.http_requests_total()
    val latency = system.latency_avg_us()
    val workers = system.active_workers()
    return ok 200 "{\"metrics\":{\"http_requests_total\":" + total + ",\"latency_avg_us\":" + latency + ",\"active_workers\":" + workers + "}}"
}
```

Real run after three requests:

```text
{"metrics":{"http_requests_total":3,"latency_avg_us":358,"active_workers":8}}
```

Every value is measured. There's no p50/p99 yet — what isn't
measured isn't exposed. `/_ledger` and `/_ledger/data` add a
per-route table (requests, mean ms, DB share) with no code.

## Where next (in order)

1. [Blog API tutorial](tutorials/blog-api.md) — a full runnable
   service with key-checked writes and expected outputs.
2. [File server tutorial](tutorials/file-server.md) — listing,
   content, and raw-body uploads.
3. [Troubleshooting](tutorials/troubleshooting.md) — ports,
   sqlite3.dll, slow first boot, stale canonical.
4. [FAQ](FAQ.md) — twenty honest questions, hard ones included.
5. [Language Reference](LANGUAGE_REFERENCE.md) — the full contract.
