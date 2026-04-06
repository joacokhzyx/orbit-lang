# Variables in Orbit

Orbit uses a **clear and intentional** variable system designed for safety, performance, and developer experience.

---

## Overview

| Keyword | Mutability | When Defined | Use Case |
|---------|------------|--------------|----------|
| `const` | Never | Compile-time | Configuration, limits, fixed values |
| `val` | Never (after assignment) | Runtime | Function results, calculated values |
| `val mut` | Yes | Runtime | Counters, accumulators, state |

---

## Quick Reference

```orbit
// Compile-time constant (inlined into binary)
const MAX_VELOCITY = 28000
const API_VERSION = "v2"

// Runtime immutable (calculated once, never changes)
val startTime = Date.now()
val user = Users.get(id)

// Runtime mutable (can be reassigned)
val mut counter = 0
val mut fuel = 100.0

counter = counter + 1  // ✅ Allowed
startTime = Date.now() // ❌ Compile Error: cannot reassign 'val'
```

---

## Visibility Modifier

By default, all variables are **public**. Use `private` to restrict access:

```orbit
// Public (default)
const API_URL = "https://api.orbit.dev"
val name = "Luna"

// Private (only accessible within current scope/module)
private const SECRET_KEY = "abc123"
private val internal_state = compute()
```

---

## Detailed Documentation

- [const - Compile-time Constants](./const.md)
- [val - Runtime Immutables](./val.md)
- [mut - Mutable Variables](./mut.md)
- [private - Visibility Modifier](./private.md)

---

## Best Practices

### 1. Default to Immutability

```orbit
// ✅ Prefer val
val user = Users.get(id)
val result = calculate(data)

// ⚠️ Only use mut when necessary
val mut attempts = 0
while attempts < 3 {
    attempts = attempts + 1
}
```

### 2. Use const for Configuration

```orbit
const MAX_RETRIES = 3
const TIMEOUT_MS = 5000
const DB_NAME = "production.db"
```

### 3. Keep Mutable Scope Small

```orbit
fn process_items(items: array<Item>) {
    val mut total = 0  // Mutable only within this function
    
    for item in items {
        total = total + item.price
    }
    
    return total
}
```

---

## Common Patterns

### Configuration Constants

```orbit
const PORT = 8080
const HOST = "0.0.0.0"
const MAX_CONNECTIONS = 1000
const DEBUG = false

fn main() {
    print("Starting server on " + HOST + ":" + PORT)
}
```

### Calculated Values

```orbit
route GET "/stats" {
    val user_count = Users.count()
    val active_users = Users.where(active: true).count()
    val ratio = active_users / user_count
    
    return ok { user_count, active_users, ratio }
}
```

### State Management

```orbit
fn countdown(from: int) {
    val mut current = from
    
    while current > 0 {
        print(current)
        current = current - 1
    }
    
    print("Liftoff!")
}
```
