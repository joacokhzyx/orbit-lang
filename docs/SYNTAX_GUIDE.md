# Orbit Syntax Reference

Orbit features a clean, type-inferred, C-like syntax designed to compile directly to hardened native code.

## Variables and Types

Variables in Orbit are type-inferred during Semantic Analysis (SEMA):

```orbit
var name = "Orbit"
var version = 0.1
var is_release = true
```

## Functions and Routing

Orbit provides a dedicated `route` keyword to declare HTTP endpoints:

```orbit
route "/health" {
    return ok 200 "Healthy"
}
```

Routes implicitly return `response` objects.

## Error Recovery (`rescue`)

Use the `rescue` block to handle exceptions and errors:

```orbit
var file_content = safeRead("config.json") rescue {
    return "DEFAULT_CONFIG"
}
```
