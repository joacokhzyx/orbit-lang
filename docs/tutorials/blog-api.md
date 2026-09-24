# Tutorial: Blog API with Auth

You'll build a small blog API: list posts, search by author, and
publish through a key-checked route. The runnable file is
`examples/blog_api.orb`; every expected output below comes from a
real run of that file on `orbit 0.1.0` (Windows, September 2026).

## The service

```orbit
model Note {
    id: string
    title: string
    body: string
    author_id: string
    created_at: string
    is_private: bool
}

route GET "/posts" {
    val posts = Note.all()
    return ok 200 posts
}

route GET "/posts/search" {
    val author = req.query("author")
    if (author == "") {
        return ok 200 Note.all()
    }
    val found = Note.where("author_id = ?", author)
    return ok 200 found
}

route POST "/posts" {
    val key = req.query("key")
    if (key != "dev-key-1") {
        err 401 "a valid ?key= value is required to publish"
    }
    val payload = req.body()
    if (payload == "" || payload == "{}") {
        err 400 "post a JSON body with id, title, and body"
    }
    return ok 201 payload
}
```

Two honest notes before you run it:

- The model is `Note`, not `Post`: the runtime creates the
  `notes` table on startup (custom tables aren't created yet), so
  reads work with zero setup.
- Auth is a shared key in `?key=`. `req.bearer_token()` exists
  but returns an empty reply at runtime in 0.1.0, so this
  tutorial doesn't use it. Details: [Known Limitations](../KNOWN_LIMITATIONS.md).

## Build and run

```powershell
.\orbit.exe build examples\blog_api.orb -o blog_api.exe
Copy-Item runtime\vendor\win-x64\sqlite3.dll .   # Windows only: DB services need it next to the exe
.\blog_api.exe 8080
```

Linux/macOS (UNTESTED on this machine - same commands the CI
path uses, adjust for your shell):

```sh
./orbit build examples/blog_api.orb -o blog_api
./blog_api 8080
```

First start takes a couple of seconds while SQLite opens and
seeds (`Ready in 1744.3 ms` in my run); restarts answer in
milliseconds (`Ready in 8.1 ms`).

## Expected outputs

List posts - seeded rows, no setup:

```sh
curl http://127.0.0.1:8080/posts
```

```text
200 [{"id":"note_101","title":"Orbit Architecture Notes", …},
     {"id":"note_102","title":"Superluminal Optimizer Guide", …}]
```

Search by author - the `?` keeps input parameterized:

```sh
curl "http://127.0.0.1:8080/posts/search?author=usr_dev"
```

```text
200 [{"id":"note_102", …}]
```

Publish without the key - rejected:

```sh
curl -X POST -H "Content-Type: application/json" \
  -d '{"id":"p9","title":"T","body":"B"}' \
  http://127.0.0.1:8080/posts
```

```text
401 a valid ?key= value is required to publish
```

Publish with the key - accepted and echoed:

```sh
curl -X POST -H "Content-Type: application/json" \
  -d '{"id":"p9","title":"T","body":"B"}' \
  "http://127.0.0.1:8080/posts?key=dev-key-1"
```

```text
201 {"id":"p9","title":"T","body":"B"}
```

Empty body with the key - caught by validation:

```text
400
```

One quirk I hit while testing: an empty POST body arrives as
`"{}"`, not `""`, which is why the route checks both. The route
echoes the accepted entry instead of storing it; for persistent
writes see `Model.create()` in `examples/posts_crud.orb`, which
stores the row and answers `false` only on duplicate ids.

## What you practiced

Routes, query values, `if/else`, request bodies, status codes
(200/201/401/400), parameterized `where`, and key-checked
publishing - all against live SQLite reads.
