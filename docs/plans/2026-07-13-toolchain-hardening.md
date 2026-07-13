# Toolchain Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate compilation fragility by implementing formal extern function declarations, versioning the runtime ABI, exposing stable argc/argv/env APIs, isolating external toolchain processes, and ensuring endian-safe serializations without breaking the bootstrap fixed point.

**Architecture:**
- Introduce a formal `extern` syntactic element to the Orbit compiler parser and semantic analyzer.
- Exclude `extern` declared functions from prototype and body emissions in the C codegen backend by checking the symbol properties (not string matching).
- Version the C runtime and encapsulate the command-line argument and environment logic behind a clean ABI function interface.
- Isolate the host compiler (`zig cc`) spawn logic behind a clean `Toolchain` class interface in `src/main.zig`.

**Tech Stack:** Zig, Orbit C runtime, PE/COFF, ELF.

---

### Task 1: Add syntactic support for `extern` functions in parser

**Files:**
- Modify: `src/token.zig:30-60`
- Modify: `src/lexer.zig:150-180`
- Modify: `src/parser/declaration_parser.zig:80-120`

**Step 1: Write a unit test for parsing `extern` functions**
Add a test in `src/tests.zig` parsing `extern fn orbit_os_env(var_name: string) -> string`.

**Step 2: Run test to verify it fails**
`zig build test` should fail.

**Step 3: Implement lexing and parsing of `extern` token**
Register `extern` as a keyword and parse `extern fn` declarations.

**Step 4: Run test to verify it passes**
`zig build test` passes.

**Step 5: Commit**
`git add -A; git commit -m "feat(parser): support parsing extern function declarations"`

---

### Task 2: Update Sema to register `extern` attributes

**Files:**
- Modify: `src/sema/type_checker.zig`
- Modify: `src/ast.zig`

**Step 1: Write a test verifying semantic analysis of `extern` functions**
Verify that the `extern` attribute is correctly propagated to the function symbol in Sema.

**Step 2: Run test to verify it fails**
`zig build test` fails.

**Step 3: Implement Sema checks for `extern`**
Add the `is_extern` boolean flag to functions and mark them during Sema checking.

**Step 4: Run test to verify it passes**
`zig build test` passes.

**Step 5: Commit**
`git add -A; git commit -m "feat(sema): track is_extern attribute on function symbols"`

---

### Task 3: Exclude `extern` declarations from C Backend prototype and definition generation

**Files:**
- Modify: `src/codegen/c_backend.zig`

**Step 1: Write a test verifying that C backend does not emit C prototypes or bodies for extern functions**
Test that `extern fn orbit_os_env(...)` produces no prototype or code block in C backend output.

**Step 2: Run test to verify it fails**
`zig build test` fails.

**Step 3: Implement skip check using `is_extern` property**
Replace the string-matching `std.mem.startsWith(u8, func.name, "orbit_")` skip logic with `if (func.is_extern) continue;`.

**Step 4: Run test to verify it passes**
`zig build test` passes.

**Step 5: Commit**
`git add -A; git commit -m "refactor(codegen): use is_extern property to skip code generation for runtime functions"`

---

### Task 4: Expose argc/argv/env through runtime ABI functions

**Files:**
- Modify: `src/runtime/os.c`
- Modify: `src/runtime/runtime.h`
- Modify: `src/codegen/runtime_loader.zig`

**Step 1: Write a test confirming C runtime argc/argv functions are linked and callable**
Add a test in `src/tests.zig`.

**Step 2: Run test to verify it fails**
`zig build test` fails.

**Step 3: Define runtime functions and update template**
Expose `orbit_os_argc()`, `orbit_os_arg()`, and `orbit_os_env()` behind stable APIs. Remove direct access to raw global variables.

**Step 4: Run test to verify it passes**
`zig build test` passes.

**Step 5: Commit**
`git add -A; git commit -m "feat(runtime): encapsulate argc/argv/env behind stable ABI functions"`

---

### Task 5: Migrate Orbit compiler files to use `extern` syntax

**Files:**
- Modify: `compiler/main.orb`

**Step 1: Add `extern` keyword to Orbit functions**
Update declarations of `orbit_os_argc`, `orbit_os_argv`, `orbit_os_exec`, and `orbit_os_env` to use the formal `extern` syntax.

**Step 2: Compile and verify bootstrap**
Run the bootstrap pipeline and verify Stage 2/3 byte-identity.

**Step 3: Commit**
`git add -A; git commit -m "feat(selfhost): migrate compiler code to use formal extern syntax"`
