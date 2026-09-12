# Tutorial: File Server and Uploads

You'll run a small file service: list files, serve text content,
and accept uploads. The runnable file is
`examples/file_server.orb`; every expected output below comes
from a real run on `orbit 0.1.0` (Windows, September 2026).

## Honest scope first

Multipart parsing and disk persistence aren't implemented in
0.1.0 — `req.file()` returns a placeholder path and saves
nothing, so this tutorial doesn't use it. Uploads here are raw
request bodies: the server measures what arrived and answers with
the byte count. If you need real multipart uploads today, Orbit
can't do that yet ([Known Limitations](../KNOWN_LIMITATIONS.md)).

## The service

```orbit
route GET "/files" {
    return ok 200 "{\"files\":[{\"name\":\"welcome.txt\",\"size\":29},{\"name\":\"notes.txt\",\"size\":41}]}"
}

route GET "/files/content" {
    val name = req.query("name")
    if (name == "welcome.txt") {
        return ok 200 "Welcome to the Orbit file server."
    }
    if (name == "notes.txt") {
        return ok 200 "Small texts served directly from routes."
    }
    err 404 "no such file"
}

route POST "/upload" {
    val key = req.query("key")
    if (key != "dev-key-1") {
        err 401 "a valid ?key= value is required to upload"
    }
    val payload = req.body()
    if (payload == "") {
        err 400 "post the file content as the raw request body"
    }
    val size = payload.len()
    return ok 201 "{\"received_bytes\":" + size + "}"
}
```

No database is used, so on Windows you don't need `sqlite3.dll`
for this one.

## Build and run

```powershell
.\orbit.exe build examples\file_server.orb -o file_server.exe
.\file_server.exe 8080
```

Linux/macOS (UNTESTED on this machine):

```sh
./orbit build examples/file_server.orb -o file_server
./file_server 8080
```

## Expected outputs

```sh
curl http://127.0.0.1:8080/files
```

```text
200 {"files":[{"name":"welcome.txt","size":29},{"name":"notes.txt","size":41}]}
```

```sh
curl "http://127.0.0.1:8080/files/content?name=welcome.txt"
```

```text
200 Welcome to the Orbit file server.
```

```sh
curl "http://127.0.0.1:8080/files/content?name=nope.txt"
```

```text
404
```

Upload twelve bytes (the count is exact — `"hello upload"`
is 12 characters):

```sh
curl -X POST -H "Content-Type: text/plain" -d "hello upload" \
  "http://127.0.0.1:8080/upload?key=dev-key-1"
```

```text
201 {"received_bytes":12}
```

Without the key:

```text
401
```

## What you practiced

Static JSON responses, query-driven dispatch, raw-body reads,
`.len()`, key-checked uploads with measured receipts — and where
the current boundary sits between "received" and "stored".
