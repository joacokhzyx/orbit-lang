# Routes in Orbit

Routes are the core building blocks for HTTP APIs in Orbit. They define how your application responds to client requests.

---

## Syntax

```orbit
route METHOD "/path" {
    // handler body
}

// With inline parameters (few params)
route METHOD "/path" (param: Type, ...) {
    // handler body
}

// With req block (many params)
route METHOD "/path" {
    val data = req {
        param1: Type
        param2: Type
    }
    // handler body
}
```

---

## HTTP Methods

| Method | Use Case | Example |
|--------|----------|---------|
| `GET` | Retrieve data | `route GET "/users"` |
| `POST` | Create data | `route POST "/users"` |
| `PUT` | Replace data | `route PUT "/users/:id"` |
| `PATCH` | Partial update | `route PATCH "/users/:id"` |
| `DELETE` | Remove data | `route DELETE "/users/:id"` |

---

## Examples

### Basic GET

```orbit
route GET "/ping" {
    return ok "pong"
}

route GET "/users" {
    val users = Users.all()
    return ok users
}
```

### GET with Path Parameters

```orbit
route GET "/users/:id" {
    val user = Users.get(id) ? not_found "User not found"
    return ok user
}

route GET "/posts/:category/:slug" {
    val post = Posts.where(category: category, slug: slug).first()
    return ok post
}
```

### POST with Inline Parameters

```orbit
route POST "/users" (name: string, email: Email) {
    val user = Users.add({ name, email })
    return ok user with status 201
}
```

### POST with req Block

```orbit
route POST "/users/register" {
    val data = req {
        name: string
        email: Email
        password: string
        age: int
        newsletter: bool
    }
    
    val hashed = crypto.hash(data.password)
    
    val user = Users.add({
        name: data.name,
        email: data.email,
        password: hashed,
        age: data.age
    })
    
    return ok { id: user.id, message: "User created" } with status 201
}
```

### PUT (Full Update)

```orbit
route PUT "/users/:id" (name: string, email: Email, age: int) {
    Users.set(id, { name, email, age })
    return ok "User updated"
}
```

### PATCH (Partial Update)

```orbit
route PATCH "/users/:id" {
    val data = req {
        name: string?
        email: Email?
    }
    
    val user = Users.get(id) ? not_found "User not found"
    
    Users.set(id, {
        name: data.name ?? user.name,
        email: data.email ?? user.email
    })
    
    return ok "User updated"
}
```

### DELETE

```orbit
route DELETE "/users/:id" {
    val user = Users.get(id) ? not_found "User not found"
    Users.del(id)
    return ok "User deleted"
}
```

---

## Path Parameters

Extract dynamic segments from the URL using `:paramName`:

```orbit
route GET "/users/:id" {
    // 'id' is automatically available as a string
    val user = Users.get(id)
    return ok user
}

route GET "/orgs/:org_id/teams/:team_id/members/:member_id" {
    // All three parameters available
    val member = Members.where(
        org_id: org_id,
        team_id: team_id,
        id: member_id
    ).first()
    
    return ok member
}
```

---

## Query Parameters

Access query string with `query`:

```orbit
route GET "/search" {
    val q = query.q ? bad_request "Search query required"
    val page = query.page ?? 1
    val limit = query.limit ?? 20
    
    val results = Posts
        .where(title: q)
        .order(created_at: "desc")
        .take(limit)
        .skip((page - 1) * limit)
    
    return ok results
}
```

---

## Request Handling

### Inline Parameters (Recommended for ≤3 params)

```orbit
route POST "/login" (email: Email, password: string) {
    val user = Users.where(email: email).first() ? unauthorized "Invalid credentials"
    
    if !crypto.verify(password, user.password) {
        err 401 "Invalid credentials"
    }
    
    val token = auth.jwt.sign({ user_id: user.id })
    return ok { token }
}
```

### req Block (Recommended for >3 params)

```orbit
route POST "/products" {
    private val data = req {
        name: string
        description: string
        price: decimal
        category_id: UUID
        tags: array<string>
        metadata: object
    }
    
    val product = Products.add(data)
    return ok product with status 201
}
```

### Assigning req to Variable

```orbit
route POST "/orders" {
    private const order_data = req {
        items: array<OrderItem>
        shipping_address: Address
        payment_method: string
    }
    
    val order = Orders.add(order_data)
    return ok order
}
```

---

## Response Handling

### Simple Responses

```orbit
return ok "Success"                    // 200 with text
return ok { name: "Luna" }             // 200 with JSON
return ok users                        // 200 with array
```

### With Status Code

```orbit
return ok "Created" with status 201
return ok user with status 201
```

### Error Responses

```orbit
err 400 "Bad request"
err 401 "Unauthorized"
err 403 "Forbidden"
err 404 "Not found"
err 500 "Internal error"

// Or use shortcuts
not_found "User not found"
bad_request "Invalid input"
unauthorized "Please login"
forbidden "Access denied"
```

### Shortcut Pattern (Rescue Operator)

```orbit
val user = Users.get(id) ? not_found "User not found"
val data = req.body() ? bad_request "Invalid data"
```

---

## Authentication

Use decorators to protect routes:

```orbit
// Define roles
role admin = user.role == "admin"
role owner(id) = user.id == id

// Apply to routes
@auth
route GET "/me" {
    return ok auth.user
}

@admin
route GET "/admin/stats" {
    return ok { users: Users.count() }
}

@owner(id)
route PUT "/users/:id" (name: string) {
    Users.set(id, { name })
    return ok "Updated"
}

// Multiple roles (OR logic)
@admin, @owner(id)
route DELETE "/posts/:id" {
    Posts.del(id)
    return ok "Deleted"
}
```

---

## See Also

- [Request Handling](./request.md)
- [Response Handling](./response.md)
- [Authentication](../auth/README.md)
- [Error Handling](../errors/README.md)
