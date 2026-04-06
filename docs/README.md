# 🪐 Orbit Language Documentation

> **Orbit** is a backend-first programming language designed for extreme scalability, safety, and production performance. If it compiles, it scales.

---

## Table of Contents

1. [Getting Started](#getting-started)
2. [Variables](./variables/README.md)
   - [const](./variables/const.md)
   - [val](./variables/val.md)
   - [mut](./variables/mut.md)
   - [private](./variables/private.md)
3. [Functions](./functions/README.md)
   - [Standard Functions](./functions/standard.md)
   - [Arrow Functions](./functions/arrow.md)
   - [Async Functions](./functions/async.md)
4. [Routes](./routes/README.md)
   - [HTTP Methods](./routes/methods.md)
   - [Request Handling](./routes/request.md)
   - [Response Handling](./routes/response.md)
5. [Database](./database/README.md)
   - [Initialization](./database/init.md)
   - [Models](./database/models.md)
   - [Queries](./database/queries.md)
   - [Operations](./database/operations.md)
6. [Error Handling](./errors/README.md)
7. [Authentication](./auth/README.md)
8. [Types](./types/README.md)
9. [Operators](./operators/README.md)
10. [Built-in Methods](./methods/README.md)

---

## Getting Started

### Hello World

```orbit
fn main() {
    print("Hello, Orbit!")
}
```

### Basic HTTP Server

```orbit
use db.sqlite

db.init("app.db")

route GET "/ping" {
    return ok "pong"
}

route GET "/users" {
    val users = Users.all()
    return ok users
}
```

### Run Your App

```bash
orbit run app.orb
orbit build app.orb --release
```

---

## Core Philosophy

| Principle | Description |
|-----------|-------------|
| **Backend-First** | Designed exclusively for APIs, microservices, and server workloads |
| **Safety by Default** | If it compiles, it's production-ready |
| **Developer Experience** | Clean syntax, minimal boilerplate, maximum productivity |
| **Performance** | Compiles to native code via Zig, runs on bare metal |

---

## Quick Reference

### Variables

```orbit
const MAX_USERS = 1000          // Compile-time constant
val name = "Luna"               // Immutable (runtime)
val mut counter = 0             // Mutable
private val secret = "key"      // Private immutable
```

### Routes

```orbit
route GET "/users" {
    return ok Users.all()
}

route POST "/users" (name: string, email: Email) {
    val user = Users.add({ name, email })
    return ok user
}
```

### Database

```orbit
model User {
    id: UUID @primary
    name: string
    email: Email @unique
}

val user = Users.get(id) ? not_found "User not found"
Users.add({ name: "Luna", email: "luna@orbit.dev" })
Users.set(id, { name: "Nova" })
Users.del(id)
```

### Error Handling

```orbit
val user = Users.get(id) ? not_found "User not found"
val data = req.body() ? bad_request "Invalid data"

err 500 "Internal server error"
```

---

## License

MIT © LunaVerseX
