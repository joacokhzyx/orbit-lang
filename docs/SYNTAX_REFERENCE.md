# 🪐 Orbit Language - Syntax Reference

> **Version:** 0.1.0  
> **Last Updated:** January 2026

---

## Quick Syntax Reference

### Variables

```orbit
const MAX = 100              // Compile-time constant
val name = "Luna"            // Runtime immutable
val mut count = 0            // Mutable variable
private val secret = "key"   // Private visibility
```

### Functions

```orbit
// Standard function
fn greet(name: string) -> string {
    return "Hello, " + name
}

// Arrow function
val double = (x) => x * 2

// Async function
async fn fetch_data() {
    val data = await http.get(url)
    return data
}
```

### Routes

```orbit
// GET with path params
route GET "/users/:id" {
    val user = Users.get(id) ? not_found "User not found"
    return ok user
}

// POST with inline params (few params)
route POST "/login" (email: Email, password: string) {
    // ...
}

// POST with req block (many params)
route POST "/register" {
    val data = req {
        name: string
        email: Email
        password: string
    }
    // ...
}
```

### Database

```orbit
// Init
use db.sqlite
db.init("app.db")

// Models
model User {
    id: UUID @primary
    email: Email @unique
    name: string
}

// Queries
Users.all()
Users.get(id)
Users.where(active: true).order(name: "asc").take(10)

// Operations
Users.add({ name, email })
Users.set(id, { name })
Users.del(id)
```

### Error Handling

```orbit
// Generic errors
err 404 "Not found"

// Semantic shortcuts
not_found "User not found"
bad_request "Invalid input"
unauthorized "Please login"
forbidden "Access denied"

// Rescue operator
val user = Users.get(id) ? not_found "User not found"
```

### Authentication

```orbit
// Role definitions
role admin = auth.user.role == "admin"
role owner(id) = auth.user.id == id

// Protected routes
@auth
route GET "/me" { ... }

@admin
route GET "/admin" { ... }

@admin, @owner(id)
route PUT "/users/:id" { ... }
```

---

## Design Decisions Summary

| Concept | Syntax | Reasoning |
|---------|--------|-----------|
| Variables | `const`, `val`, `val mut` | Clear intent, safety-first |
| Visibility | `private` modifier | Public by default |
| Request data | `req {}` or inline `()` | DX-focused flexibility |
| Routes | `route METHOD "/path"` | Professional, explicit |
| Errors | `err N "msg"` + shortcuts | Semantic, readable |
| Rescue | `? error "msg"` | Inline null handling |
| Roles | `@role` decorators | Declarative, clean |
| DB ops | `.add()`, `.set()`, `.del()` | Short, consistent verbs |
| Queries | `.where()`, `.order()`, `.take()` | Fluid, SQL-like |

---

## File Structure

```
orbit-binary/
├── docs/
│   ├── README.md           # Main documentation
│   ├── variables/
│   │   ├── README.md       # Variables overview
│   │   ├── const.md        # Constants
│   │   ├── val.md          # Immutables
│   │   ├── mut.md          # Mutables
│   │   └── private.md      # Visibility
│   ├── routes/
│   │   └── README.md       # HTTP routes
│   ├── database/
│   │   └── README.md       # Database operations
│   ├── functions/
│   │   └── README.md       # Functions & arrows
│   ├── errors/
│   │   └── README.md       # Error handling
│   ├── auth/
│   │   └── README.md       # Authentication
│   ├── types/
│   │   └── README.md       # Type system
│   ├── methods/
│   │   └── README.md       # Built-in methods
│   └── operators/
│       └── README.md       # Operators
├── src/                     # Compiler source (Zig)
└── test.orb                # Example code
```

---

## Philosophy

1. **Backend-First**: Designed exclusively for APIs and servers
2. **Safety by Default**: Immutable by default, explicit mutability
3. **Developer Experience**: Clean syntax, minimal boilerplate
4. **Performance**: Compiles to native code via Zig
5. **Semantic**: Code reads like documentation

---

*If it compiles, it scales.* 🚀
