# val - Runtime Immutables

`val` declares a variable that is **calculated at runtime** but **cannot be changed** after its initial assignment. This is the **default and recommended** way to declare variables in Orbit.

---

## Syntax

```orbit
val name = expression
private val name = expression
```

---

## Characteristics

| Property | Description |
|----------|-------------|
| **Defined** | At runtime (when the line executes) |
| **Mutability** | Immutable after first assignment |
| **Performance** | High - single memory allocation |
| **Thread Safety** | Safe to share between threads |

---

## Examples

### Basic Usage

```orbit
val name = "Luna"
val age = 25
val is_active = true
val scores = [95, 87, 92]
```

### Calculated Values

```orbit
val timestamp = Date.now()
val user = Users.get(id)
val total = prices.reduce((sum, p) => sum + p, 0)
val hash = crypto.sha256(password)
```

### From Function Results

```orbit
fn calculate_tax(amount: decimal) -> decimal {
    return amount * 0.21
}

val subtotal = 100.00
val tax = calculate_tax(subtotal)
val total = subtotal + tax
```

---

## Why Use val?

### 1. Predictability

When you see `val`, you know the value will never change. This reduces cognitive load:

```orbit
val user = Users.get(id)

// 100 lines of code later...

// You KNOW 'user' is still the same object
print(user.name)
```

### 2. Thread Safety

In concurrent programming, immutable values are safe to share:

```orbit
val config = load_config()

// Safe to pass to multiple async operations
async process_a(config)
async process_b(config)
async process_c(config)
```

### 3. Prevents Accidental Modification

```orbit
val user = Users.get(id)

user = Users.get(other_id)  // ❌ Compile Error: cannot reassign 'val'
```

---

## val vs val mut

```orbit
// Immutable - cannot change
val name = "Luna"
name = "Nova"  // ❌ Compile Error

// Mutable - can change
val mut counter = 0
counter = counter + 1  // ✅ OK
```

---

## Common Patterns

### Guard Clauses with Rescue Operator

```orbit
route GET "/users/:id" {
    val user = Users.get(id) ? not_found "User not found"
    val profile = user.profile ? not_found "Profile not found"
    
    return ok { user, profile }
}
```

### Destructuring

```orbit
val { name, email } = user
val [first, second, ...rest] = items
```

### Conditional Assignment

```orbit
val status = if score > 100 { "winner" } else { "player" }

val greeting = match time_of_day {
    "morning" => "Good morning!",
    "afternoon" => "Good afternoon!",
    _ => "Hello!"
}
```

### Request Data

```orbit
route POST "/users" {
    val data = req {
        name: string
        email: Email
    }
    
    val user = Users.add({
        name: data.name,
        email: data.email
    })
    
    return ok user
}
```

---

## Private val

Use `private` to restrict visibility:

```orbit
private val internal_cache = Map.new()
private val session_key = generate_key()

// Accessible only within current module
fn get_cached(key: string) {
    return internal_cache.get(key)
}
```

---

## Best Practices

### 1. Prefer val Over mut

```orbit
// ✅ Good - immutable by default
val result = calculate(data)


// ⚠️ Only when necessary
val mut accumulator = 0
```

### 2. Meaningful Names

```orbit
// ✅ Good
val user_count = Users.count()
val active_sessions = Sessions.where(active: true).count()

// ❌ Avoid
val x = Users.count()
val n = Sessions.where(active: true).count()
```

### 3. Single Responsibility

```orbit
// ✅ Good - one purpose per variable
val raw_data = fetch_data()
val validated_data = validate(raw_data)
val processed_data = process(validated_data)

// ❌ Avoid - reusing with mut
val mut data = fetch_data()
data = validate(data)
data = process(data)
```
