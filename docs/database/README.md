# Database in Orbit

Orbit provides a **first-class database experience** with a fluid, intuitive API. Define models, run queries, and manage data with minimal code.

---

## Getting Started

### 1. Initialize Database

```orbit
use db.sqlite

db.init("app.db")
```

### Available Drivers

```orbit
use db.sqlite      // SQLite (file-based)
use db.postgres    // PostgreSQL
use db.mysql       // MySQL/MariaDB
use db.mongo       // MongoDB (future)
```

---

## Models

Models define your database schema. Orbit automatically creates tables.

### Basic Model

```orbit
model User {
    id: UUID @primary
    name: string
    email: string
    created_at: Timestamp
}
```

### With Constraints

```orbit
model User {
    id: UUID @primary
    username: string @unique
    email: Email @unique
    password: string
    role: string = "user"
    score: int = 0
    verified: bool = false
    created_at: Timestamp @auto
    updated_at: Timestamp @auto
}
```

### Model Decorators

| Decorator | Description |
|-----------|-------------|
| `@primary` | Primary key |
| `@unique` | Unique constraint |
| `@auto` | Auto-generated (timestamps) |
| `@index` | Create index |
| `@nullable` | Allow null values |

### Relationships (Future)

```orbit
model Post {
    id: UUID @primary
    title: string
    content: string
    author_id: UUID @references(User.id)
}

model Comment {
    id: UUID @primary
    text: string
    post_id: UUID @references(Post.id)
    author_id: UUID @references(User.id)
}
```

---

## Queries

Orbit uses a **fluid query builder** for readable, chainable operations.

### Basic Retrieval

```orbit
// Get all records
val users = Users.all()

// Get by ID
val user = Users.get(id)

// Get first/last
val first = Users.first()
val last = Users.last()

// Check existence
val exists = Users.exists(id)

// Count records
val count = Users.count()
```

### Filtering with where

```orbit
// Single condition
val admins = Users.where(role: "admin")

// Multiple conditions (AND)
val active_admins = Users.where(role: "admin", active: true)

// All active users
val active = Users.where(active: true)
```

### Ordering with order

```orbit
// Ascending
val users = Users.order(name: "asc")

// Descending
val recent = Users.order(created_at: "desc")

// Multiple fields
val sorted = Users.order(role: "asc", name: "asc")
```

### Limiting with take

```orbit
// Get first 10
val top10 = Users.take(10)

// Pagination
val page2 = Users.skip(10).take(10)
```

### Chaining

```orbit
val results = Users
    .where(active: true)
    .where(role: "admin")
    .order(created_at: "desc")
    .take(5)

val paginated = Posts
    .where(published: true)
    .order(views: "desc")
    .skip(20)
    .take(10)
```

---

## Operations

### Create (add)

```orbit
// Simple add
val user = Users.add({
    name: "Luna",
    email: "luna@orbit.dev"
})

// With all fields
val user = Users.add({
    name: data.name,
    email: data.email,
    password: crypto.hash(data.password),
    role: "user",
    verified: false
})

// Returns the created record with ID
print(user.id)  // UUID
```

### Read (get)

```orbit
// By ID
val user = Users.get(id)

// With rescue operator
val user = Users.get(id) ? not_found "User not found"

// Find one by condition
val admin = Users.where(role: "admin").first()
```

### Update (set)

```orbit
// Update by ID
Users.set(id, { name: "Nova" })

// Update multiple fields
Users.set(id, {
    name: data.name,
    email: data.email,
    updated_at: Date.now()
})

// Conditional update pattern
val user = Users.get(id) ? not_found "User not found"
Users.set(id, { score: user.score + 10 })
```

### Delete (del)

```orbit
// Delete by ID
Users.del(id)

// Safe delete with check
val user = Users.get(id) ? not_found "User not found"
Users.del(id)
```

---

## Advanced Patterns

### Mutable Queries

```orbit
val mut user = Users.get(id) ? not_found "User not found"
user.name = "New Name"
user.save()  // Requires val mut
```

### Transactions (Future)

```orbit
db.transaction {
    val user = Users.add({ name: "Luna" })
    val profile = Profiles.add({ user_id: user.id })
    val settings = Settings.add({ user_id: user.id })
}
```

### Raw Queries (Escape Hatch)

```orbit
val results = db.raw("SELECT * FROM users WHERE score > ?", [100])
```

---

## Complete Example

```orbit
use db.sqlite

db.init("shop.db")

model Product {
    id: UUID @primary
    name: string
    price: decimal
    stock: int = 0
    category: string
    created_at: Timestamp @auto
}

model Order {
    id: UUID @primary
    product_id: UUID
    quantity: int
    total: decimal
    status: string = "pending"
    created_at: Timestamp @auto
}

// Get featured products
route GET "/products/featured" {
    val products = Products
        .where(stock: > 0)
        .order(created_at: "desc")
        .take(10)
    
    return ok products
}

// Create order
route POST "/orders" (product_id: UUID, quantity: int) {
    val product = Products.get(product_id) ? not_found "Product not found"
    
    if product.stock < quantity {
        err 400 "Insufficient stock"
    }
    
    val total = product.price * quantity
    
    val order = Orders.add({
        product_id: product_id,
        quantity: quantity,
        total: total
    })
    
    // Update stock
    Products.set(product_id, {
        stock: product.stock - quantity
    })
    
    return ok order with status 201
}

// Get order stats
route GET "/stats" {
    val total_orders = Orders.count()
    val total_products = Products.count()
    val pending = Orders.where(status: "pending").count()
    
    return ok {
        orders: total_orders,
        products: total_products,
        pending: pending
    }
}
```

---

## Query Reference

| Method | Description | Example |
|--------|-------------|---------|
| `.all()` | Get all records | `Users.all()` |
| `.get(id)` | Get by primary key | `Users.get(id)` |
| `.first()` | Get first record | `Users.first()` |
| `.last()` | Get last record | `Users.last()` |
| `.count()` | Count records | `Users.count()` |
| `.exists(id)` | Check existence | `Users.exists(id)` |
| `.where(...)` | Filter records | `Users.where(active: true)` |
| `.order(...)` | Sort records | `Users.order(name: "asc")` |
| `.take(n)` | Limit results | `Users.take(10)` |
| `.skip(n)` | Offset results | `Users.skip(20)` |
| `.add({})` | Create record | `Users.add({ name })` |
| `.set(id, {})` | Update record | `Users.set(id, { name })` |
| `.del(id)` | Delete record | `Users.del(id)` |
