# mut - Mutable Variables

`mut` is a **modifier** that allows a `val` to be reassigned after its initial declaration. Use it when you genuinely need to change a value over time.

---

## Syntax

```orbit
val mut name = initial_value
private val mut name = initial_value
```

> **Note:** `mut` is not a type—it's a modifier that changes the behavior of `val`.

---

## Characteristics

| Property | Description |
|----------|-------------|
| **Defined** | At runtime |
| **Mutability** | Can be reassigned any number of times |
| **Performance** | Slightly lower than `val` (requires tracking) |
| **Use Case** | Counters, accumulators, state |

---

## Examples

### Counter

```orbit
val mut count = 0

count = count + 1
count = count + 1
count = count + 1

print(count)  // 3
```

### Accumulator

```orbit
val mut total = 0.0

for item in cart.items {
    total = total + item.price
}

print("Total: $" + total)
```

### State Management

```orbit
val mut status = "pending"

if validated {
    status = "approved"
} else {
    status = "rejected"
}
```

---

## Why Use val mut?

### 1. Loops and Iteration

```orbit
val mut sum = 0
val mut i = 0

while i < 100 {
    sum = sum + i
    i = i + 1
}
```

### 2. Conditional Updates

```orbit
val mut message = "Processing..."

if success {
    message = "Complete!"
} else {
    message = "Failed."
}
```

### 3. Retry Logic

```orbit
val mut attempts = 0
val mut result = null

while attempts < 3 and result == null {
    result = try_operation()
    attempts = attempts + 1
}
```

---

## val vs val mut

```orbit
// Immutable (default, preferred)
val name = "Luna"

// Mutable (explicit, intentional)
val mut score = 0
```

| Aspect | val | val mut |
|--------|-----|---------|
| Reassignment | ❌ Not allowed | ✅ Allowed |
| Thread safety | ✅ Safe | ⚠️ Requires care |
| Debugging | Easier (value never changes) | Harder (track changes) |
| Default choice | ✅ Yes | Only when needed |

---

## Common Patterns

### Loop Counter

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

### Building a Result

```orbit
fn build_report(users: array<User>) -> string {
    val mut report = "# User Report\n\n"
    
    for user in users {
        report = report + "- " + user.name + "\n"
    }
    
    return report
}
```

### Stateful Processing

```orbit
fn process_queue() {
    val mut processed = 0
    val mut errors = 0
    
    for job in queue.items {
        val result = process(job)
        
        if result.success {
            processed = processed + 1
        } else {
            errors = errors + 1
        }
    }
    
    return { processed, errors }
}
```

### Game/Simulation State

```orbit
fn simulate_mission() {
    val mut fuel = 100.0
    val mut altitude = 0
    val mut velocity = 0
    
    while fuel > 0 and altitude < 100000 {
        velocity = velocity + 10
        altitude = altitude + velocity
        fuel = fuel - 0.5
    }
    
    return { altitude, fuel, velocity }
}
```

---

## Best Practices

### 1. Minimize Mutable Scope

```orbit
// ✅ Good - mutable only where needed
fn calculate_total(items: array<Item>) -> decimal {
    val mut total = 0.0
    
    for item in items {
        total = total + item.price
    }
    
    return total
}

// Use the result immutably
val final_total = calculate_total(cart.items)
```

### 2. Document Intent

```orbit
// ✅ Clear why it's mutable
val mut retry_count = 0  // Incremented on each failed attempt

// ✅ Use descriptive names
val mut accumulated_score = 0
val mut remaining_lives = 3
```

### 3. Consider Alternatives

Sometimes you can avoid `mut` with functional patterns:

```orbit
// ❌ Mutable approach
val mut sum = 0
for n in numbers {
    sum = sum + n
}

// ✅ Functional approach (no mut needed)
val sum = numbers.reduce((acc, n) => acc + n, 0)
```

---

## When NOT to Use mut

### ❌ Single Assignment

```orbit
// ❌ Unnecessary mut
val mut name = get_name()

// ✅ Just use val
val name = get_name()
```

### ❌ Avoiding Proper Structure

```orbit
// ❌ Overusing mut for "flexibility"
val mut data = null
data = fetch()
data = transform(data)
data = validate(data)

// ✅ Clear data flow
val raw = fetch()
val transformed = transform(raw)
val validated = validate(transformed)
```

---

## Thread Safety Warning

Mutable variables require care in concurrent contexts:

```orbit
// ⚠️ Dangerous - race condition possible
val mut shared_counter = 0

async process_a() {
    shared_counter = shared_counter + 1  // Race!
}

async process_b() {
    shared_counter = shared_counter + 1  // Race!
}

// ✅ Safe - use atomic operations or channels
val counter = Atomic.new(0)
counter.increment()
```
