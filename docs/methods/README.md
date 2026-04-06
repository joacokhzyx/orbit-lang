# Built-in Methods in Orbit

Orbit provides a rich set of built-in methods for common operations.

---

## String Methods

```orbit
val text = "  Hello, Orbit!  "

text.trim()              // "Hello, Orbit!"
text.upper()             // "  HELLO, ORBIT!  "
text.lower()             // "  hello, orbit!  "
text.length              // 17
text.replace("Orbit", "World")
text.split(", ")         // ["Hello", "Orbit!"]
text.starts_with("Hello")
text.ends_with("!")
text.contains("Orbit")
text.slice(2, 7)         // "Hello"
```

---

## Array Methods

```orbit
val arr = [1, 2, 3, 4, 5]

arr.length               // 5
arr.map(n => n * 2)      // [2, 4, 6, 8, 10]
arr.filter(n => n > 2)   // [3, 4, 5]
arr.find(n => n > 3)     // 4
arr.some(n => n > 4)     // true
arr.every(n => n > 0)    // true
arr.reduce((a, b) => a + b, 0)  // 15
arr.includes(3)          // true
arr.first()              // 1
arr.last()               // 5
arr.join(", ")           // "1, 2, 3, 4, 5"
arr.sort()               // [1, 2, 3, 4, 5]
arr.reverse()            // [5, 4, 3, 2, 1]
arr.slice(1, 3)          // [2, 3]
```

---

## Math Methods

```orbit
Math.random()            // 0.0 - 1.0
Math.random(1, 100)      // 1 - 100
Math.floor(3.7)          // 3
Math.ceil(3.2)           // 4
Math.round(3.5)          // 4
Math.abs(-5)             // 5
Math.pow(2, 8)           // 256
Math.sqrt(16)            // 4
Math.min(1, 2, 3)        // 1
Math.max(1, 2, 3)        // 3
```

---

## Date Methods

```orbit
val now = Date.now()
val today = Date.today()

now.format("YYYY-MM-DD")
now.add(1, "day")
now.subtract(7, "days")
now.is_before(other)
now.is_after(other)
```

---

## JSON Methods

```orbit
val obj = { name: "Luna", age: 25 }

obj.json()               // '{"name":"Luna","age":25}'
obj.json(pretty: true)   // Formatted

val str = '{"name":"Luna"}'
str.parse()              // { name: "Luna" }
```

---

## Crypto Methods

```orbit
use crypto

crypto.hash("text", "sha256")
crypto.bcrypt("password")
crypto.verify("password", hash)
crypto.random_string(32)
crypto.uuid()
```

---

## HTTP Methods

```orbit
use http

http.get(url)
http.post(url, { body: data })
http.put(url, { body: data })
http.delete(url)

response.status
response.body
response.headers
response.ok
```
