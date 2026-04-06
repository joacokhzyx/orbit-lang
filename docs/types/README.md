# Types in Orbit

Orbit features a **strong, static type system** with built-in validation types.

---

## Primitive Types

| Type | Description | Example |
|------|-------------|---------|
| `string` | UTF-8 text | `"Hello"` |
| `int` | Integer | `42` |
| `float` | Floating point | `3.14` |
| `bool` | Boolean | `true` |
| `decimal` | Precise decimal | `19.99` |

---

## Validated Types

| Type | Validates | Example |
|------|-----------|---------|
| `Email` | Email format | `"user@example.com"` |
| `URL` | Valid URL | `"https://orbit.dev"` |
| `UUID` | UUID v4 format | `"550e8400-..."` |
| `Phone` | Phone number | `"+1234567890"` |
| `IP` | IPv4/IPv6 | `"192.168.1.1"` |

---

## Date/Time Types

| Type | Description |
|------|-------------|
| `Date` | Date only |
| `Time` | Time only |
| `DateTime` | Date and time |
| `Timestamp` | Unix timestamp |

---

## Collection Types

```orbit
val numbers: array<int> = [1, 2, 3]
val config: map<string, string> = { "key": "value" }
val tags: set<string> = {"a", "b"}
```

---

## Optional Types

```orbit
val name: string? = null

model User {
    nickname: string?  // Optional
}
```

---

## Type Decorators

| Decorator | Description |
|-----------|-------------|
| `@primary` | Primary key |
| `@unique` | Unique constraint |
| `@auto` | Auto-generated |
| `@default(v)` | Default value |
