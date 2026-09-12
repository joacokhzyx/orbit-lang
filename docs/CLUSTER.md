Scope: SINGLE-HOST multiprocess orchestration only. No gossip, no leader election, no cross-host routing.

`orbit cluster` v1 launches and supervises N copies of one compiled Orbit
service on the local machine. Each node is its own OS process listening on
its own port (`port-base + node id`). There is no shared state between
nodes, no proxying, and no automatic failover. Anything involving more than
one host is out of scope for v1.

## Commands

All commands run from the directory that holds the service file. State is
kept in `.orbit/cluster.json` (git-ignored); logs default to
`.orbit/logs/node-<id>.log`.

```
orbit cluster up --nodes N --port-base P [--log-dir D] [--service S]
orbit cluster status
orbit cluster drain <node>
orbit cluster restart --rolling
orbit cluster down
orbit cluster logs <node>
```

`up` compiles the service exactly once (via the existing
`compileSourceWithFile` path) to `.orbit/cluster-service` (plus `.exe` on
Windows), then starts N detached processes as
`"<binary>" <port>` with stdout/stderr appended to per-node logs. The
compiled server reads its port from `argv[1]`, so one binary serves all
ports. `up` refuses when `.orbit/cluster.json` already exists. Defaults:
`--log-dir .orbit/logs`, `--service service.orb`. `--nodes` accepts 1..64.

`status` prints one line per node: id, port, pid, `alive` or `dead`, plus a
`draining` flag when set. Exit 0 when the state file is readable, even if
some nodes are dead; exit 1 when there is no state file.

`drain <node>` records the node as draining and sends a graceful stop. The
generated server stops accepting new connections on SIGTERM and exits after
in-flight requests complete. Drained nodes are not restarted and are skipped
by `restart --rolling`. There is no respawn: once the process exits it stays
down until a `restart --rolling` (which replaces it) or a new `up`.

`restart --rolling` walks nodes in id order: graceful stop, wait for exit
(up to 10 s, then SIGKILL and 5 s more), start a replacement on the same
port with the same log file (appended), verify health, then move to the next
node. On any failure it aborts immediately and leaves remaining nodes
untouched. Draining nodes are skipped.

`down` sends a graceful stop to every node, waits 3 s, force-stops
survivors, waits 2 s, reports per-node results, and removes the state file.
Exit 1 if any pid is still alive or the state file could not be removed.
`down` with no state file is a no-op that exits 0. Log files are kept.

`logs <node>` prints the node's log file. It works after `down` (logs are
kept; the log directory falls back to `.orbit/logs` when no state file
exists).

Exit codes: 0 success, 1 operational failure (compile/spawn/health/kill
errors, unknown node, unreadable state), 2 CLI usage error (missing or
invalid flags, unknown subcommand).

## State file

`.orbit/cluster.json` is valid JSON with a fixed internal layout, for
example:

```json
{"version": 1, "service": ".orbit/cluster-service", "port_base": 8100, "log_dir": ".orbit/logs", "nodes": [{"id": 0, "port": 8100, "pid": 4242}, {"id": 1, "port": 8101, "pid": 4243}], "draining": []}
```

The layout is internal, not a public API. Do not hand-edit it while nodes
are running. `port_base` records the base port; `draining` lists node ids
with a pending graceful stop.

## Health definition

Health is process liveness only: pid present in the OS process table. No
HTTP check is performed. Rationale: the `fetch()` builtin seen in examples
is a route-handler builtin whose runtime implementation is a stub returning
fixed mock JSON (`runtime/builtins.c`), so it cannot verify a listening
port; it is also unavailable to plain programs such as the compiler itself.
`up` and `restart --rolling` treat a node as healthy when its pid probes
alive immediately and still probes alive after a 2-second settle delay.
A node that crashes on startup (for example a port already in use, which
the server reports on stderr into its log) therefore fails health within
about 12 seconds.

## Process mechanics

`orbit_os_spawn` (used by `orbit run`) wraps `system()`/`popen`, which block
until the child exits, so it cannot launch daemons. Cluster v1 adds two
runtime functions instead:

- `orbit_os_spawn_bg(command, logfile) -> pid`: POSIX `fork` + `setsid`,
  stdio redirected (stdin from /dev/null, stdout/stderr appended to the log
  file), then `sh -c "exec <command>"`. The `exec` prefix replaces the
  shell so the returned pid is the server process itself. Windows
  `CreateProcess` with `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP` and
  the standard handles on the log file (append mode, so restarts keep
  history). Returns the child pid, or -1 on failure.
- `orbit_os_kill(pid, mode) -> int`: mode 0 is forceful (SIGKILL /
  `TerminateProcess`), mode 1 is graceful (SIGTERM / `TerminateProcess`),
  mode 2 probes only (`kill(pid, 0)` with a `waitpid` reap check for own
  exited children so a just-crashed node reads as dead rather than as a
  lingering zombie; `OpenProcess` + `WaitForSingleObject(0)` on Windows).
  Returns 1 on success (probe: alive), 0 on failure (probe: dead/absent).

Both follow the established extern pattern: declaration in
`compiler/extern.orb`, return type in `feBuildTimeCallType`
(`compiler/c_backend.orb`), CTE rejection in `isRuntimeFunction`
(`compiler/cteval.orb`), implementation in `runtime/os.c`, wrapper in
`runtime/selfhost.c`.

## Platform differences

On POSIX, graceful stop (SIGTERM) runs the generated server's drain handler:
new connections are refused, in-flight requests complete, then the process
exits. On Windows, `TerminateProcess` is immediate and the drain handler
does not run: connections drop and in-flight requests are lost. The Windows
console handler only fires for console Ctrl events, which a detached
process never receives, so there is no graceful path on Windows in v1.
`drain` and the graceful phase of `restart`/`down` are therefore best-effort
stops on Windows; the commands still report per-node outcomes honestly.

Polling sleeps use `sleep 1` on POSIX and `timeout /T 1` on Windows via the
existing exec path (the compiler binary is built with `ORBIT_WITH_EXEC`).
Directory creation uses `mkdir -p` / `mkdir`.

## Limits

- One cluster per directory (one state file). A second `up` is rejected
  until `down` removes the state.
- No supervisor: crashed nodes stay down until `restart --rolling`.
- Concurrent `up` invocations share the compiler's single intermediate C
  file (`orbit_selfhost_build.c`); do not run two at once.
- Node ids are dense from 0; `drain`/`logs` accept only recorded ids.
- Ports are checked for range (1..65535) but not pre-scanned; a conflict
  surfaces as a failed health check with the bind error in the node log.
