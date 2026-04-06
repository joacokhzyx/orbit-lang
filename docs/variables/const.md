# const - Compile-time Constants

Constants are values that are **fixed at compile time** and embedded directly into the binary. They offer maximum performance and absolute immutability.

---

## Syntax

```orbit
const NAME = value
private const NAME = value
```

---

## Characteristics

| Property | Description |
|----------|-------------|
| **Defined** | At compile time (before program runs) |
| **Mutability** | Never - physically impossible to change |
| **Performance** | Maximum - value is inlined, no memory lookup |
| **Memory** | Zero runtime allocation |

---

## Examples

### Basic Constants

```orbit
const PI = 3.14159
const MAX_USERS = 10000
const API_VERSION = "v2"
const DEBUG_MODE = false
```

### Configuration

```orbit
const DB_HOST = "localhost"
const DB_PORT = 5432
const DB_NAME = "orbit_production"

const TIMEOUT_SECONDS = 30
const MAX_RETRIES = 3
```

### Private Constants

```orbit
private const SECRET_KEY = "sk_live_abc123"
private const ENCRYPTION_SALT = "orbit_salt_2026"
```

---

## Why Use const?

### 1. Performance (Inlining)

The compiler doesn't create a memory cell for `const` values. Instead, it **replaces** every usage with the actual value:

```orbit
const MULTIPLIER = 10

fn calculate(x: int) -> int {
    return x * MULTIPLIER
}

// Compiler transforms this to:
// return x * 10
```

### 2. Dead Code Elimination

The compiler can remove unreachable code based on constants:

```orbit
const DEBUG = false

fn process() {
    if DEBUG {
        print("Debug: Processing...")  // This entire block is removed
    }
    
    // Only this code remains in the binary
    execute()
}
```

### 3. Safety

Constants cannot be modified, even accidentally:

```orbit
const MAX_SCORE = 100

fn update_score(score: int) {
    MAX_SCORE = 200  // ❌ Compile Error: cannot assign to constant
}
```

---

## const vs val

| Aspect | const | val |
|--------|-------|-----|
| When defined | Compile time | Runtime |
| Value source | Must be literal or computable at compile | Can be function result |
| Performance | Fastest (inlined) | Fast (single lookup) |
| Use case | Fixed configuration | Calculated values |

```orbit
// const: Value known at compile time
const VERSION = "1.0.0"

// val: Value calculated at runtime
val timestamp = Date.now()
val user = Users.get(id)
```

---

## Naming Convention

Constants should use `SCREAMING_SNAKE_CASE`:

```orbit
// ✅ Good
const MAX_CONNECTIONS = 100
const API_BASE_URL = "https://api.orbit.dev"

// ❌ Avoid
const maxConnections = 100
const apiBaseUrl = "https://api.orbit.dev"
```

---

## Common Patterns

### Feature Flags

```orbit
const FEATURE_NEW_UI = true
const FEATURE_ANALYTICS = false

route GET "/dashboard" {
    if FEATURE_NEW_UI {
        return render_new_dashboard()
    }
    return render_old_dashboard()
}
```

### Environment Configuration

```orbit
const ENV = "production"
const PORT = 8080
const LOG_LEVEL = "info"

const DB_URL = if ENV == "production" {
    "postgres://prod.db.com/orbit"
} else {
    "sqlite://dev.db"
}
```

### Limits and Boundaries

```orbit
const MAX_FILE_SIZE = 10 * 1024 * 1024  // 10 MB
const MAX_USERNAME_LENGTH = 32
const MIN_PASSWORD_LENGTH = 8
const MAX_LOGIN_ATTEMPTS = 5
```
