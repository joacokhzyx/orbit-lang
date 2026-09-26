# Frequently Asked Questions

Short answers, plain words. Where the answer is "not yet" or
"I don't know," it says so - that's the point of this page.

## Basics

**1. What is Orbit?**
A statically typed language for APIs and microservices. It
compiles fast and needs little to run, so it stays fast even
under load. I'm building it to test whether servers can do the
same work with less energy - still measuring how far that goes.

**2. Is Orbit ready for production?**
No. It's 0.1.0 pre-release research. Reads work, writes don't
yet, auth helpers are broken at runtime, and there's no
migration story. Good for learning and experimenting; don't
bet a business on it.

**3. What do I need to build it?**
A C compiler (gcc, clang, or MSVC), Python 3.10+, and git.
That's it - no giant dependencies. See [Getting Started](GETTING_STARTED.md).

**4. How is this different from Go, Rust, or Node?**
I don't compare against other languages with claims - only
with same-machine, same-workload measurements, published with
method. Those measurements don't exist yet in publishable form.
What I can say structurally: Orbit compiles to readable C99,
reclaims memory per request with arenas, and measures its own
resource use out of the box.

**5. Is Orbit "green" / eco-friendly?**
It's an engineering project whose result could be less energy
per request - not an ecological identity. I don't claim energy
savings until they're measured with hardware, workload, and
method recorded. Anyone telling you otherwise about 0.1.0 is
ahead of the data.

## Language

**6. What can I build today?**
Read-heavy JSON services over SQLite: routes, query values,
request bodies, filtered queries, status codes, live telemetry.
The [Tour](TOUR.md) takes 30 minutes; the tutorials go further.

**7. What can't Orbit do yet?**
The honest list: persistent writes (`create()` returns false),
bearer-token auth (empty replies), path parameters (`:id`
never matches), multipart uploads (stub), custom DB tables,
migrations, latency percentiles, joules on Windows, graceful
drain on Windows, multi-host clustering. Full list with
workarounds: [Known Limitations](KNOWN_LIMITATIONS.md).

**8. Why do writes fail? Can't you just fix it?**
Reads and writes share the runtime but take different code
paths, and the write path returns `false` in this build with
the cause still under investigation. I document it instead of
hiding it. Compiler and runtime fixes land through the
bootstrap gates, which is slow on purpose.

**9. Is the language stable? Will my code compile next month?**
No stability promise before 1.0. Minor releases in the 0.x
series may include documented breaking changes (see
[Versioning](VERSIONING.md)). Pin your compiler version in CI.

**10. Does Orbit have generics / async / pattern matching?**
Unions and `async fn` exist in the reference; collection APIs,
concurrency ergonomics, and module imports are still settling.
Keep business logic simple, cover it with tests, and file an
issue when you hit a wall - I read everything.

## Running services

**11. How do I set the port?**
Pass it as the first argument: `./service 8080`. Default is
3000. There's no config-file port yet.

**12. Where's the database file?**
`orbit.db` in the service's working directory, created on
first start with four tables and demo seed rows. Back it up by
copying the file while the service is stopped.

**13. Why did my DB service exit with no message on Windows?**
`sqlite3.dll` must sit next to the exe. Copy it from
`runtime/vendor/win-x64/`. Non-DB services don't need it.

**14. How do I run two copies?**
`orbit cluster up --nodes 2 --port-base 8100 --service
service.orb` - single host only, no failover. Verified walkthrough:
[Deploy tutorial](tutorials/deploy-single-binary.md).

**15. How do I know it's healthy?**
`GET /health` if you write one, process liveness via
`cluster status`, and live counters at `/metrics` and
`/_ledger/data`. There are no built-in alerts or dashboards.

## Measuring

**16. Is Orbit faster than X?**
I don't know yet in any publishable sense. I have no
cross-language measurement of Orbit against anything, so
I am not going to imply one. Ask again after someone
publishes a run with the hardware, the flags, the workload
and the spread.

**17. What does "stays fast under load" mean concretely?**
Today: Kynx admission control sheds load (429s past budget)
and per-request arenas bound memory growth. With numbers and
method attached - otherwise it's just words, and words
are not evidence.

**18. Can I measure energy per request?**
On Linux with RAPL or a wall meter, yes, following the guide.
On Windows, no joules - report CPU time and memory as labeled
proxies. My docs never convert one to the other.

## Project

**19. Who builds Orbit, and why should I trust it?**
I'm Joaquín, building solo in Argentina on modest hardware -
which is the point: the constraint is the design brief. Trust
comes from the verification gates (bootstrap, parity,
behavior suite all in CI) and from publishing limits next to
features, not from my claims.

**20. How can I help?**
Run the [Tour](TOUR.md), file issues with repros (small `.orb`
files plus expected vs actual), and grow the behavior suite -
one focused test per behavior. Start with
[Contributing](../CONTRIBUTING.md). Bug reports with failing
examples help more than feature requests right now.
