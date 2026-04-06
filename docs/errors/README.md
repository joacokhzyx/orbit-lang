# Error Handling in Orbit

Orbit provides a clean, expressive error handling system designed for backend APIs. Errors are semantic, concise, and developer-friendly.

---

## Quick Reference

```orbit
// Generic error
err 404 "User not found"
err 500 "Internal server error"

// Semantic shortcuts
not_found "User not found"
bad_request "Invalid input"
unauthorized "Please login"
forbidden "Access denied"

// Rescue operator (?)
val user = Users.get(id) ? not_found "User not found"
```

---

## Error Syntax

### Basic err Statement

```orbit
err STATUS_CODE "message"
```

```orbit
err 400 "Bad request"
err 401 "Unauthorized"
err 403 "Forbidden"
err 404 "Not found"
err 409 "Conflict"
err 422 "Validation failed"
err 500 "Internal server error"
err 503 "Service unavailable"
```

---

## Semantic Shortcuts

Orbit provides shortcuts for common HTTP errors:

| Shortcut | Status Code | Use Case |
|----------|-------------|----------|
| `bad_request` | 400 | Invalid input, validation errors |
| `unauthorized` | 401 | Missing or invalid authentication |
| `forbidden` | 403 | Authenticated but not permitted |
| `not_found` | 404 | Resource doesn't exist |
| `conflict` | 409 | Duplicate resource, state conflict |
| `unprocessable` | 422 | Semantic validation errors |
| `internal` | 500 | Server errors |

### Examples

```orbit
not_found "User not found"
bad_request "Email is required"
unauthorized "Please provide a valid token"
forbidden "You don't have permission to access this resource"
conflict "A user with this email already exists"
```

---

## Rescue Operator (?)

The `?` operator provides inline error handling—if the value is null/false, it throws the specified error.

### Syntax

```orbit
val variable = expression ? error_shortcut "message"
```

### Examples

```orbit
// If Users.get(id) returns null, throw 404
val user = Users.get(id) ? not_found "User not found"

// If req.body() fails, throw 400
val data = req.body() ? bad_request "Invalid request body"

// Chain multiple rescues
val user = Users.get(id) ? not_found "User not found"
val profile = user.profile ? not_found "Profile not found"
val avatar = profile.avatar ? not_found "Avatar not found"
```

### Comparison

```orbit
// ❌ Verbose approach
val user = Users.get(id)
if !user {
    err 404 "User not found"
}

// ✅ Clean with rescue operator
val user = Users.get(id) ? not_found "User not found"
```

---

## Patterns

### Guard Clauses

```orbit
route POST "/posts" {
    val data = req {
        title: string
        content: string
    }
    
    // Guard clauses at the top
    data.title.length < 3 ? bad_request "Title too short"
    data.title.length > 100 ? bad_request "Title too long"
    data.content.length < 10 ? bad_request "Content too short"
    
    // Happy path continues
    val post = Posts.add(data)
    return ok post
}
```

### Validation Errors

```orbit
route POST "/users" (email: Email, password: string) {
    // Validate input
    password.length < 8 ? bad_request "Password must be at least 8 characters"
    !password.contains(r"[A-Z]") ? bad_request "Password must contain uppercase"
    !password.contains(r"[0-9]") ? bad_request "Password must contain a number"
    
    // Check for duplicates
    Users.where(email: email).exists() ? conflict "Email already registered"
    
    // Create user
    val user = Users.add({ email, password: hash(password) })
    return ok user with status 201
}
```

### Resource Existence

```orbit
route GET "/users/:id" {
    val user = Users.get(id) ? not_found "User not found"
    return ok user
}

route PUT "/users/:id" (name: string) {
    val user = Users.get(id) ? not_found "User not found"
    Users.set(id, { name })
    return ok "Updated"
}

route DELETE "/users/:id" {
    val user = Users.get(id) ? not_found "User not found"
    Users.del(id)
    return ok "Deleted"
}
```

### Authorization

```orbit
route PUT "/posts/:id" {
    val post = Posts.get(id) ? not_found "Post not found"
    
    // Check ownership
    if post.author_id != auth.user.id {
        forbidden "You can only edit your own posts"
    }
    
    val data = req { title: string, content: string }
    Posts.set(id, data)
    
    return ok "Updated"
}
```

### Conditional Errors

```orbit
route POST "/orders" {
    val data = req {
        product_id: UUID
        quantity: int
    }
    
    val product = Products.get(data.product_id) ? not_found "Product not found"
    
    // Business logic errors
    if product.stock < data.quantity {
        err 400 "Insufficient stock. Available: " + product.stock
    }
    
    if data.quantity > 10 {
        err 400 "Maximum 10 items per order"
    }
    
    // Create order
    val order = Orders.add({
        product_id: data.product_id,
        quantity: data.quantity,
        total: product.price * data.quantity
    })
    
    return ok order
}
```

---

## Error Response Format

All errors return a consistent JSON structure:

```json
{
    "error": {
        "status": 404,
        "message": "User not found"
    }
}
```

---

## Complete Example

```orbit
use db.sqlite
use auth

db.init("blog.db")

model Post {
    id: UUID @primary
    title: string
    content: string
    author_id: UUID
    published: bool = false
    created_at: Timestamp @auto
}

// Define owner role
role owner(id) = auth.user.id == Posts.get(id).author_id

// Create post
@auth
route POST "/posts" {
    val data = req {
        title: string
        content: string
    }
    
    // Validation
    data.title.length < 5 ? bad_request "Title must be at least 5 characters"
    data.title.length > 200 ? bad_request "Title too long"
    data.content.length < 50 ? bad_request "Content must be at least 50 characters"
    
    val post = Posts.add({
        title: data.title,
        content: data.content,
        author_id: auth.user.id
    })
    
    return ok post with status 201
}

// Get single post
route GET "/posts/:id" {
    val post = Posts.get(id) ? not_found "Post not found"
    
    // Only return if published or owner
    if !post.published and post.author_id != auth.user?.id {
        not_found "Post not found"
    }
    
    return ok post
}

// Update post (owner only)
@owner(id)
route PUT "/posts/:id" {
    val post = Posts.get(id) ? not_found "Post not found"
    
    val data = req {
        title: string
        content: string
    }
    
    data.title.length < 5 ? bad_request "Title too short"
    
    Posts.set(id, {
        title: data.title,
        content: data.content
    })
    
    return ok "Post updated"
}

// Publish post (owner only)
@owner(id)
route POST "/posts/:id/publish" {
    val post = Posts.get(id) ? not_found "Post not found"
    
    if post.published {
        conflict "Post is already published"
    }
    
    Posts.set(id, { published: true })
    
    return ok "Post published"
}

// Delete post (owner only)
@owner(id)
route DELETE "/posts/:id" {
    val post = Posts.get(id) ? not_found "Post not found"
    Posts.del(id)
    return ok "Post deleted"
}
```

---

## HTTP Status Codes Reference

| Code | Name | When to Use |
|------|------|-------------|
| 400 | Bad Request | Invalid input, malformed request |
| 401 | Unauthorized | Missing or invalid authentication |
| 403 | Forbidden | Authenticated but not permitted |
| 404 | Not Found | Resource doesn't exist |
| 409 | Conflict | Duplicate, state conflict |
| 422 | Unprocessable | Semantic validation failure |
| 429 | Too Many Requests | Rate limiting |
| 500 | Internal Error | Server-side failure |
| 503 | Service Unavailable | Maintenance, overload |
