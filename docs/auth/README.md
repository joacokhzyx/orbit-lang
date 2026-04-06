# Authentication in Orbit

Orbit provides a **declarative, role-based authentication system** using decorators and role definitions. Secure your routes with minimal code.

---

## Quick Start

```orbit
use auth

// Require any authenticated user
@auth
route GET "/me" {
    return ok auth.user
}

// Require admin role
@admin
route GET "/admin/dashboard" {
    return ok { users: Users.count() }
}
```

---

## Setup

### Import Auth Module

```orbit
use auth
use auth.jwt    // For JWT-based auth
use auth.basic  // For Basic auth (future)
use auth.oauth  // For OAuth (future)
```

### Configure JWT

```orbit
use auth.jwt

// In your config
private const JWT_SECRET = "your-secret-key"
private const JWT_EXPIRY = 86400  // 24 hours

auth.jwt.configure({
    secret: JWT_SECRET,
    expiry: JWT_EXPIRY
})
```

---

## Role Definitions

Define roles as **reusable conditions**:

### Syntax

```orbit
role NAME = condition
role NAME(param) = condition_with_param
```

### Examples

```orbit
// Simple role based on user property
role admin = user.role == "admin"
role moderator = user.role == "moderator" or user.role == "admin"
role verified = user.verified == true
role premium = user.subscription == "premium"

// Role with parameter (dynamic)
role owner(resource_id) = user.id == resource_id
role post_author(post_id) = user.id == Posts.get(post_id).author_id
role team_member(team_id) = Teams.get(team_id).members.includes(user.id)
```

---

## Applying Roles to Routes

### Single Role

```orbit
@auth
route GET "/profile" {
    return ok auth.user
}

@admin
route GET "/admin/users" {
    return ok Users.all()
}

@verified
route POST "/posts" {
    // Only verified users can create posts
}
```

### Multiple Roles (OR Logic)

```orbit
// Either admin OR the owner can edit
@admin, @owner(id)
route PUT "/users/:id" (name: string) {
    Users.set(id, { name })
    return ok "Updated"
}

// Admin, moderator, or post author
@admin, @moderator, @post_author(id)
route DELETE "/posts/:id" {
    Posts.del(id)
    return ok "Deleted"
}
```

### Parameterized Roles

```orbit
role owner(user_id) = auth.user.id == user_id

@owner(id)
route PUT "/users/:id" {
    // Only the user themselves can access
}

@owner(id)
route DELETE "/users/:id" {
    // Only the user themselves can delete their account
}
```

---

## The auth Object

When a user is authenticated, access their data via `auth`:

```orbit
auth.user         // The authenticated user object
auth.user.id      // User ID
auth.user.email   // User email
auth.user.role    // User role
auth.token        // The JWT token (if applicable)
```

### Example

```orbit
@auth
route GET "/me" {
    return ok {
        id: auth.user.id,
        email: auth.user.email,
        role: auth.user.role,
        name: auth.user.name
    }
}
```

---

## Login/Logout Flow

### Registration

```orbit
route POST "/auth/register" (name: string, email: Email, password: string) {
    // Validation
    password.length < 8 ? bad_request "Password too short"
    Users.where(email: email).exists() ? conflict "Email taken"
    
    // Create user
    val user = Users.add({
        name: name,
        email: email,
        password: crypto.bcrypt(password),
        role: "user"
    })
    
    // Generate token
    val token = auth.jwt.sign({
        user_id: user.id,
        email: user.email,
        role: user.role
    })
    
    return ok { user: { id: user.id, name, email }, token }
}
```

### Login

```orbit
route POST "/auth/login" (email: Email, password: string) {
    val user = Users.where(email: email).first() ? unauthorized "Invalid credentials"
    
    if !crypto.verify(password, user.password) {
        unauthorized "Invalid credentials"
    }
    
    val token = auth.jwt.sign({
        user_id: user.id,
        email: user.email,
        role: user.role
    })
    
    return ok { token }
}
```

### Get Current User

```orbit
@auth
route GET "/auth/me" {
    val user = Users.get(auth.user.id) ? not_found "User not found"
    
    return ok {
        id: user.id,
        name: user.name,
        email: user.email,
        role: user.role
    }
}
```

### Change Password

```orbit
@auth
route POST "/auth/password" (current: string, new_password: string) {
    val user = Users.get(auth.user.id)
    
    if !crypto.verify(current, user.password) {
        unauthorized "Current password is incorrect"
    }
    
    new_password.length < 8 ? bad_request "New password too short"
    
    Users.set(auth.user.id, {
        password: crypto.bcrypt(new_password)
    })
    
    return ok "Password updated"
}
```

---

## Advanced Patterns

### Resource-Based Authorization

```orbit
model Post {
    id: UUID @primary
    title: string
    content: string
    author_id: UUID
    published: bool = false
}

// Role: User is the post author
role post_owner(post_id) = auth.user.id == Posts.get(post_id).author_id

// Anyone can read published posts
route GET "/posts/:id" {
    val post = Posts.get(id) ? not_found "Post not found"
    
    if !post.published and post.author_id != auth.user?.id {
        not_found "Post not found"
    }
    
    return ok post
}

// Only author or admin can update
@admin, @post_owner(id)
route PUT "/posts/:id" {
    val data = req { title: string, content: string }
    Posts.set(id, data)
    return ok "Updated"
}

// Only author or admin can delete
@admin, @post_owner(id)
route DELETE "/posts/:id" {
    Posts.del(id)
    return ok "Deleted"
}
```

### Team-Based Access

```orbit
model Team {
    id: UUID @primary
    name: string
    owner_id: UUID
}

model TeamMember {
    team_id: UUID
    user_id: UUID
    role: string  // "member", "admin"
}

role team_owner(team_id) = auth.user.id == Teams.get(team_id).owner_id

role team_admin(team_id) = TeamMembers
    .where(team_id: team_id, user_id: auth.user.id, role: "admin")
    .exists()

role team_member(team_id) = TeamMembers
    .where(team_id: team_id, user_id: auth.user.id)
    .exists()

// Only team members can view
@team_member(id)
route GET "/teams/:id" {
    val team = Teams.get(id)
    val members = TeamMembers.where(team_id: id)
    return ok { team, members }
}

// Only team owner or admin can manage
@team_owner(id), @team_admin(id)
route POST "/teams/:id/members" (user_id: UUID) {
    TeamMembers.add({ team_id: id, user_id, role: "member" })
    return ok "Member added"
}
```

---

## Complete Example

```orbit
use db.sqlite
use auth.jwt
use crypto

db.init("app.db")

// --- Models ---
model User {
    id: UUID @primary
    email: Email @unique
    password: string
    name: string
    role: string = "user"
    verified: bool = false
    created_at: Timestamp @auto
}

model Post {
    id: UUID @primary
    title: string
    content: string
    author_id: UUID
    published: bool = false
    created_at: Timestamp @auto
}

// --- Role Definitions ---
role admin = auth.user.role == "admin"
role verified = auth.user.verified == true
role post_author(post_id) = auth.user.id == Posts.get(post_id).author_id

// --- Auth Configuration ---
private const JWT_SECRET = "super_secret_key_change_in_production"
auth.jwt.configure({ secret: JWT_SECRET, expiry: 86400 })

// --- Auth Routes ---
route POST "/auth/register" (name: string, email: Email, password: string) {
    password.length < 8 ? bad_request "Password too short"
    Users.where(email: email).exists() ? conflict "Email taken"
    
    val user = Users.add({
        name, email,
        password: crypto.bcrypt(password)
    })
    
    val token = auth.jwt.sign({ user_id: user.id, role: user.role })
    
    return ok { id: user.id, token } with status 201
}

route POST "/auth/login" (email: Email, password: string) {
    val user = Users.where(email: email).first() ? unauthorized "Invalid"
    !crypto.verify(password, user.password) ? unauthorized "Invalid"
    
    val token = auth.jwt.sign({ user_id: user.id, role: user.role })
    
    return ok { token }
}

@auth
route GET "/auth/me" {
    val user = Users.get(auth.user.id)
    return ok { id: user.id, name: user.name, email: user.email }
}

// --- Protected Routes ---
@verified
route POST "/posts" {
    val data = req { title: string, content: string }
    
    val post = Posts.add({
        title: data.title,
        content: data.content,
        author_id: auth.user.id
    })
    
    return ok post with status 201
}

@admin, @post_author(id)
route PUT "/posts/:id" {
    val post = Posts.get(id) ? not_found "Post not found"
    val data = req { title: string, content: string }
    
    Posts.set(id, data)
    return ok "Updated"
}

@admin, @post_author(id)
route DELETE "/posts/:id" {
    Posts.get(id) ? not_found "Post not found"
    Posts.del(id)
    return ok "Deleted"
}

// --- Admin Only ---
@admin
route GET "/admin/users" {
    return ok Users.all()
}

@admin
route DELETE "/admin/users/:id" {
    Users.get(id) ? not_found "User not found"
    Users.del(id)
    return ok "User deleted"
}
```
