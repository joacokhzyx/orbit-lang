# private - Visibility Modifier

`private` restricts the visibility of a variable, constant, or function to the **current scope or module**. By default, all declarations in Orbit are **public**.

---

## Syntax

```orbit
private const NAME = value
private val name = value
private val mut name = value
private fn function_name() { }
```

---

## Default Visibility

```orbit
// Public (default) - accessible from anywhere
const API_URL = "https://api.orbit.dev"
val config = load_config()

// Private - accessible only within current module
private const SECRET_KEY = "sk_live_abc123"
private val internal_cache = Map.new()
```

---

## Examples

### Private Constants

```orbit
// Public configuration
const PORT = 8080
const HOST = "0.0.0.0"

// Private secrets (not exposed to importers)
private const DB_PASSWORD = "super_secret"
private const JWT_SECRET = "my_jwt_secret_key"
private const ENCRYPTION_KEY = "aes256_key_here"
```

### Private Variables

```orbit
// Module-level private state
private val cache = Map.new()
private val mut request_count = 0

// Public interface
fn get_cached(key: string) {
    return cache.get(key)
}

fn increment_requests() {
    request_count = request_count + 1
}
```

### Private Functions

```orbit
// Public API
fn process_order(order: Order) {
    validate_order(order)
    val total = calculate_total(order)
    return finalize_order(order, total)
}

// Private helpers (not exposed)
private fn validate_order(order: Order) {
    if order.items.length == 0 {
        err 400 "Order must have items"
    }
}

private fn calculate_total(order: Order) -> decimal {
    return order.items.reduce((sum, item) => sum + item.price, 0)
}

private fn finalize_order(order: Order, total: decimal) {
    // Internal processing
}
```

---

## Use Cases

### 1. Hiding Implementation Details

```orbit
// users.orb

// Public: The API that other modules use
fn get_user(id: UUID) -> User {
    val cached = check_cache(id)
    if cached {
        return cached
    }
    
    val user = fetch_from_db(id)
    update_cache(id, user)
    return user
}

// Private: Implementation details hidden from importers
private val user_cache = Map.new()

private fn check_cache(id: UUID) -> User? {
    return user_cache.get(id)
}

private fn update_cache(id: UUID, user: User) {
    user_cache.set(id, user)
}

private fn fetch_from_db(id: UUID) -> User {
    return Users.get(id)
}
```

### 2. Protecting Sensitive Data

```orbit
// auth.orb

private const JWT_SECRET = "your_secret_key"
private const TOKEN_EXPIRY = 86400

fn generate_token(user: User) -> string {
    return jwt.sign({
        user_id: user.id,
        role: user.role
    }, JWT_SECRET, expires: TOKEN_EXPIRY)
}

fn verify_token(token: string) -> TokenPayload? {
    return jwt.verify(token, JWT_SECRET)
}
```

### 3. Module-Level State

```orbit
// request_logger.orb

private val mut total_requests = 0
private val mut error_count = 0

fn log_request(status: int) {
    total_requests = total_requests + 1
    
    if status >= 400 {
        error_count = error_count + 1
    }
}

fn get_stats() {
    return {
        total: total_requests,
        errors: error_count,
        success_rate: (total_requests - error_count) / total_requests
    }
}
```

---

## Visibility Rules

| Declaration | Visible in same module | Visible to importers |
|-------------|------------------------|----------------------|
| `const X` | ✅ | ✅ |
| `private const X` | ✅ | ❌ |
| `val x` | ✅ | ✅ |
| `private val x` | ✅ | ❌ |
| `fn foo()` | ✅ | ✅ |
| `private fn foo()` | ✅ | ❌ |

---

## Best Practices

### 1. Hide What Doesn't Need Exposure

```orbit
// ✅ Good - only expose what's necessary
fn process(data: Data) -> Result { ... }

private fn validate(data: Data) { ... }
private fn transform(data: Data) -> Data { ... }
private fn persist(data: Data) { ... }
```

### 2. Protect Sensitive Configuration

```orbit
// ✅ Good
const PORT = 8080                       // Safe to expose
private const API_SECRET = "secret123"  // Protected

// ❌ Bad
const API_SECRET = "secret123"          // Accidentally exposed!
```

### 3. Use Private for Internal State

```orbit
// ✅ Good - state is encapsulated
private val mut connection_pool = Pool.new(10)

fn get_connection() {
    return connection_pool.acquire()
}
```

---

## Import Behavior

When another module imports yours, only public declarations are accessible:

```orbit
// math.orb
const PI = 3.14159
private const INTERNAL_PRECISION = 15

fn calculate(x: float) -> float { ... }
private fn internal_helper() { ... }
```

```orbit
// app.orb
import './math.orb'

val result = calculate(PI)       // ✅ Works
val x = INTERNAL_PRECISION       // ❌ Compile Error: not visible
internal_helper()                // ❌ Compile Error: not visible
```
