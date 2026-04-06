# Functions in Orbit

Functions are reusable blocks of code that perform specific tasks. Orbit supports standard functions, arrow functions, and async functions.

---

## Standard Functions

### Syntax

```orbit
fn name(param: Type, ...) -> ReturnType {
    // body
    return value
}
```

### Examples

```orbit
// Simple function
fn greet(name: string) -> string {
    return "Hello, " + name + "!"
}

// Multiple parameters
fn add(a: int, b: int) -> int {
    return a + b
}

// No return value
fn log_action(action: string) {
    print("[LOG] " + action)
}

// Boolean return
fn is_adult(age: int) -> bool {
    return age >= 18
}
```

### Calling Functions

```orbit
val message = greet("Luna")        // "Hello, Luna!"
val sum = add(5, 3)                // 8
log_action("User logged in")       // Prints: [LOG] User logged in
val adult = is_adult(25)           // true
```

---

## Arrow Functions

Concise syntax for small, inline functions.

### Syntax

```orbit
// Single expression (implicit return)
val name = (params) => expression

// Multi-line
val name = (params) => {
    // body
    return value
}
```

### Examples

```orbit
// Single expression
val double = (x) => x * 2
val square = (x) => x * x
val greet = (name) => "Hello, " + name

// With multiple params
val add = (a, b) => a + b
val max = (a, b) => if a > b { a } else { b }

// Multi-line arrow function
val process = (data) => {
    val validated = validate(data)
    val transformed = transform(validated)
    return transformed
}
```

### Use Cases

```orbit
// Callbacks
val doubled = numbers.map(n => n * 2)
val adults = users.filter(u => u.age >= 18)
val total = prices.reduce((sum, p) => sum + p, 0)

// Event handlers
on_click = () => print("Clicked!")
on_error = (err) => log.error(err.message)
```

---

## Async Functions

For operations that need to wait for external resources.

### Syntax

```orbit
async fn name(params) -> ReturnType {
    val result = await async_operation()
    return result
}
```

### Examples

```orbit
// Async database operation
async fn get_user_with_posts(id: UUID) -> UserWithPosts {
    val user = await Users.get(id)
    val posts = await Posts.where(author_id: id)
    
    return { user, posts }
}

// Async HTTP request
async fn fetch_weather(city: string) -> Weather {
    val response = await http.get("https://api.weather.com/" + city)
    return response.json()
}

// Parallel execution
async fn load_dashboard(user_id: UUID) {
    // Execute in parallel
    val [user, notifications, stats] = await [
        Users.get(user_id),
        Notifications.where(user_id: user_id).take(5),
        calculate_stats(user_id)
    ]
    
    return { user, notifications, stats }
}
```

### Calling Async Functions

```orbit
// Inside another async function
async fn main() {
    val user = await get_user_with_posts(id)
    print(user.name)
}

// In routes
route GET "/users/:id/full" {
    val data = await get_user_with_posts(id)
    return ok data
}

// Fire and forget (don't await)
route POST "/users" (name: string, email: Email) {
    val user = Users.add({ name, email })
    
    // Send email in background (don't wait)
    async send_welcome_email(user)
    
    return ok user
}
```

---

## Function Parameters

### Required Parameters

```orbit
fn greet(name: string) -> string {
    return "Hello, " + name
}

greet()        // ❌ Error: missing argument
greet("Luna")  // ✅ "Hello, Luna"
```

### Optional Parameters (with defaults)

```orbit
fn greet(name: string, greeting: string = "Hello") -> string {
    return greeting + ", " + name
}

greet("Luna")              // "Hello, Luna"
greet("Luna", "Welcome")   // "Welcome, Luna"
```

### Rest Parameters (Future)

```orbit
fn sum(...numbers: array<int>) -> int {
    return numbers.reduce((a, b) => a + b, 0)
}

sum(1, 2, 3, 4, 5)  // 15
```

---

## Private Functions

Hide implementation details:

```orbit
// Public API
fn process_order(order: Order) -> Receipt {
    validate_order(order)
    val total = calculate_total(order)
    return generate_receipt(order, total)
}

// Private helpers
private fn validate_order(order: Order) {
    if order.items.length == 0 {
        err 400 "Order must have items"
    }
}

private fn calculate_total(order: Order) -> decimal {
    return order.items
        .map(item => item.price * item.quantity)
        .reduce((a, b) => a + b, 0)
}

private fn generate_receipt(order: Order, total: decimal) -> Receipt {
    return {
        order_id: order.id,
        total: total,
        date: Date.now()
    }
}
```

---

## Patterns

### Guard Clauses

```orbit
fn process_user(id: UUID) -> User {
    val user = Users.get(id)
    
    if !user {
        err 404 "User not found"
    }
    
    if !user.active {
        err 403 "User is inactive"
    }
    
    return user
}
```

### Pipeline Processing

```orbit
fn process_data(raw: string) -> Result {
    val parsed = parse(raw)
    val validated = validate(parsed)
    val transformed = transform(validated)
    val saved = save(transformed)
    
    return saved
}
```

### Builder Pattern

```orbit
fn build_query() -> Query {
    return Query.new()
        .select("id", "name", "email")
        .from("users")
        .where("active", true)
        .order("name", "asc")
        .limit(10)
}
```

---

## Complete Example

```orbit
use db.sqlite
use crypto

db.init("auth.db")

model User {
    id: UUID @primary
    email: Email @unique
    password: string
    name: string
    created_at: Timestamp @auto
}

// Validation helpers
val is_valid_password = (password) => password.length >= 8

private fn hash_password(password: string) -> string {
    return crypto.bcrypt(password)
}

private fn verify_password(plain: string, hashed: string) -> bool {
    return crypto.verify(plain, hashed)
}

// Public registration function
fn register_user(name: string, email: Email, password: string) -> User {
    if !is_valid_password(password) {
        err 400 "Password must be at least 8 characters"
    }
    
    if Users.where(email: email).exists() {
        err 409 "Email already registered"
    }
    
    val user = Users.add({
        name: name,
        email: email,
        password: hash_password(password)
    })
    
    return user
}

// Public authentication function
async fn authenticate(email: Email, password: string) -> AuthResult {
    val user = Users.where(email: email).first() ? unauthorized "Invalid credentials"
    
    if !verify_password(password, user.password) {
        err 401 "Invalid credentials"
    }
    
    val token = await generate_token(user)
    
    return { user, token }
}

// Routes using functions
route POST "/auth/register" (name: string, email: Email, password: string) {
    val user = register_user(name, email, password)
    return ok { id: user.id } with status 201
}

route POST "/auth/login" (email: Email, password: string) {
    val result = await authenticate(email, password)
    return ok { token: result.token }
}
```
