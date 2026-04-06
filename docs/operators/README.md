# Operators in Orbit

---

## Arithmetic Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `+` | Addition | `5 + 3` → `8` |
| `-` | Subtraction | `5 - 3` → `2` |
| `*` | Multiplication | `5 * 3` → `15` |
| `/` | Division | `6 / 2` → `3` |
| `%` | Modulo | `7 % 3` → `1` |

---

## Comparison Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `==` | Equal | `5 == 5` → `true` |
| `!=` | Not equal | `5 != 3` → `true` |
| `<` | Less than | `3 < 5` → `true` |
| `>` | Greater than | `5 > 3` → `true` |
| `<=` | Less or equal | `3 <= 3` → `true` |
| `>=` | Greater or equal | `5 >= 5` → `true` |

---

## Logical Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `and` | Logical AND | `true and false` → `false` |
| `or` | Logical OR | `true or false` → `true` |
| `!` | Logical NOT | `!true` → `false` |

---

## Assignment Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `=` | Assign | `val x = 5` |
| `+=` | Add and assign | `x += 3` |
| `-=` | Subtract and assign | `x -= 2` |
| `*=` | Multiply and assign | `x *= 2` |
| `/=` | Divide and assign | `x /= 2` |

---

## Special Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `?` | Rescue (null check) | `val x = y ? err "msg"` |
| `??` | Null coalescing | `val x = y ?? default` |
| `?.` | Optional chaining | `user?.profile?.name` |
| `=>` | Arrow function | `(x) => x * 2` |
| `->` | Return type | `fn foo() -> int` |

---

## String Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `+` | Concatenation | `"Hello" + " World"` |
| `${}` | Interpolation | `"Hello ${name}"` |

---

## Examples

```orbit
// Arithmetic
val sum = 10 + 5
val product = 10 * 5

// Comparison
if score > 100 {
    print("Winner!")
}

// Logical
if active and verified {
    allow_access()
}

// Rescue operator
val user = Users.get(id) ? not_found "Not found"

// Null coalescing
val name = user.nickname ?? user.name

// Optional chaining
val city = user?.address?.city
```
