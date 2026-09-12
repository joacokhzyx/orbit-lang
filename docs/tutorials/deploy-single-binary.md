# Tutorial: Deploy a Single Binary (Windows + Linux)

Orbit compiles to one native executable. This tutorial takes
`examples/health_service.orb` — no database, no setup — from
build to a running service, on both platforms. Windows commands
are verified on this machine; Linux commands follow the same
documented path but are marked UNTESTED where I couldn't run
them.

## 1. Build

Windows (verified):

```powershell
python scripts\build_selfhost.py --cc gcc --out orbit.exe
.\orbit.exe build examples\health_service.orb -o health_service.exe
```

Linux (UNTESTED here — same path CI uses):

```sh
python3 scripts/build_selfhost.py --cc gcc --out orbit
./orbit build examples/health_service.orb -o health_service
```

The compiler step emits C, then your platform C compiler
produces the binary. Expect the compiler build to take a few
minutes (it's a 68k-line C file); the service build takes under
a minute.

## 2. What to ship

| File | Windows | Linux |
|---|---|---|
| Service binary | `health_service.exe` | `health_service` |
| SQLite runtime | `sqlite3.dll` beside the exe | system `libsqlite3` (usually present) |
| Data dir (writable) | `orbit.db` is created here | same |

The SQLite row matters: database services (`catalog_service`,
`sqlite_notes`, `blog_api`) exit silently on Windows when
`sqlite3.dll` isn't next to the exe — no log, no message. I
hit exactly that during testing. Non-DB services like
`health_service` don't need it.

## 3. Run it

```powershell
.\health_service.exe 8080
```

```text
Orbit 0.1.0

- Local: http://localhost:8080
- Workers: 8
- Secured by Kynx.

✓ Starting...
✓ Ready in 4.8 ms
```

Check it:

```powershell
curl http://127.0.0.1:8080/health
```

```text
{"status":"UP","version":"0.1.0-rc.2","uptime_seconds":0}
```

The port comes from the first argument. With no argument the
service uses its default (3000). Pick the port per environment —
an argument beats a config file here.

## 4. Keep it running (UNTESTED — review before using)

Windows, Task Scheduler or a service wrapper of your choice;
run from a dedicated writable directory so `orbit.db` (when
used) lives with the service, not with your home folder.

Linux, a minimal systemd unit:

```ini
[Unit]
Description=Orbit health service
After=network.target

[Service]
ExecStart=/srv/orbit/health_service 8080
WorkingDirectory=/srv/orbit
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

I haven't run this unit — treat it as a starting point, not a
tested recipe. `WorkingDirectory` matters because the database
file is created in the working directory.

## 5. Two instances on one box (verified)

`orbit cluster` runs N copies on this machine — no shared
state, no proxying, single host only. Verified end to end:

```powershell
.\orbit.exe cluster up --nodes 2 --port-base 8150 --service examples\health_service.orb
```

```text
cluster up: 2 nodes (.orbit/cluster-service.exe, ports 8150..8151)
  node 0: port 8150 pid 5052 alive
  node 1: port 8151 pid 4092 alive
```

```powershell
.\orbit.exe cluster status
```

```text
cluster: 2 nodes (single host)
  node 0: port 8150 pid 5052 alive
  node 1: port 8151 pid 4092 alive
```

Both nodes answered `/health` with `200`. Shut it down:

```powershell
.\orbit.exe cluster down
```

```text
  node 0: stopped.
  node 1: stopped.
cluster down: all 2 nodes stopped, state removed.
```

State lives in `.orbit/` (git-ignored); logs stay in
`.orbit/logs/` after `down`. One cluster per directory.
`drain` and rolling restart are best-effort stops on Windows
(drain is kill there) — see [Known Limitations](../KNOWN_LIMITATIONS.md).
