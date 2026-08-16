# Dynamic HTTP benchmark (hello-world)

- Load: `hey -z 5s -c 50`, 3 rounds per server, round-robin
- Endpoint: GET / -> 200 OK, body "OK", Content-Type application/json
- Date: 2026-08-16 05:41:30

| Server | Req/s (mean ± std) | p50 (ms) | p95 (ms) | Notes |
|---|---|---|---|---|
| orbit | 8,522 ± 739 | 4.500 | 13.800 | N-worker select() loops (auto = CPU cores) |
| go | 5,992 ± 542 | 7.567 | 18.167 | net/http default (goroutines) |
| node | 6,692 ± 145 | 4.700 | 25.400 | libuv event loop, single-thread |
| rust | 11,260 ± 88 | 3.500 | 9.533 | std TcpListener, thread-per-connection |
| c | 9,954 ± 102 | 3.600 | 12.967 | single-thread select() event loop |
