import sys
import uvicorn

MOD = 1_000_000_007


def fib(n: int) -> int:
    if n < 0:
        return 0
    if n > 1_000_000:
        n = 1_000_000
    if n == 0:
        return 0
    if n == 1:
        return 1
    a, b = 0, 1
    for _ in range(2, n + 1):
        a, b = b, (a + b) % MOD
    return b


async def app(scope, receive, send):
    if scope["type"] != "http":
        return

    method = scope.get("method", "")
    path = scope.get("path", "")
    query_string = scope.get("query_string", b"").decode("utf-8", errors="replace")

    def parse_query_n(qs: str):
        for part in qs.split("&"):
            if part.startswith("n="):
                try:
                    return int(part[2:])
                except ValueError:
                    return None
        return None

    if method != "GET":
        body = b"Not Found\n"
        await send({
            "type": "http.response.start",
            "status": 404,
            "headers": [
                (b"content-type", b"text/plain"),
                (b"content-length", str(len(body)).encode()),
            ],
        })
        await send({"type": "http.response.body", "body": body})
        return

    if path == "/":
        body = b"OK\n"
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [
                (b"content-type", b"text/plain"),
                (b"content-length", b"3"),
            ],
        })
        await send({"type": "http.response.body", "body": body})
        return

    if path == "/fib":
        n = parse_query_n(query_string)
        if n is None:
            body = b"Not Found\n"
            await send({
                "type": "http.response.start",
                "status": 404,
                "headers": [
                    (b"content-type", b"text/plain"),
                    (b"content-length", str(len(body)).encode()),
                ],
            })
            await send({"type": "http.response.body", "body": body})
            return
        result = fib(n)
        body = f"{result}\n".encode()
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [
                (b"content-type", b"text/plain"),
                (b"content-length", str(len(body)).encode()),
            ],
        })
        await send({"type": "http.response.body", "body": body})
        return

    body = b"Not Found\n"
    await send({
        "type": "http.response.start",
        "status": 404,
        "headers": [
            (b"content-type", b"text/plain"),
            (b"content-length", str(len(body)).encode()),
        ],
    })
    await send({"type": "http.response.body", "body": body})


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(1)
    try:
        port = int(sys.argv[1])
    except ValueError:
        sys.exit(1)

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=port,
        log_level="critical",
        access_log=False,
    )
