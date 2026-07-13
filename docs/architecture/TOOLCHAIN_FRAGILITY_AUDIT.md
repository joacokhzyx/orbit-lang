# Toolchain Fragility Audit

This audit evaluates the current Orbit compilation pipeline and bootstrap sequence to identify external toolchain dependencies, implicit runtime assumptions, and fragile workarounds.

## Identified Fragilities

### 1. Brittle Runtime Symbol Exclusion (Codegen)
- **Status:** Fragile string matching.
- **Location:** `src/codegen/c_backend.zig` (forward declarations loop).
- **Mechanism:** Skips signature and definition generation for any function whose name starts with `"orbit_"` (excluding `"orbit_main"`).
- **Risk:** High. If a user defines a function named `orbit_helper()`, the compiler will silently skip generating its prototype and definition, leading to compilation errors or link-time failures.

### 2. Implicit argc/argv Global Variable Interface
- **Status:** Uncontracted global variables.
- **Location:** `src/codegen/runtime_loader.zig` and `src/runtime/os.c`.
- **Mechanism:** The generated C `main` function references `extern char** _orbit_argv;` and `extern int _orbit_argc;` and modifies them.
- **Risk:** Any change in variable names or linkage model breaks compile-time and runtime compatibility.

### 3. Hardcoded External Toolchain Invocations
- **Status:** Assumes host compiler and linker are present.
- **Location:** `src/main.zig`.
- **Mechanism:** Directly spawns `zig cc` for compiling C files and linking.
- **Risk:** The compilation process is tightly coupled to the presence of the `zig` command-line executable in the system environment.

### 4. Lack of Binary Format Distinction
- **Status:** Relocatable objects are distinct from executable images.
- **Location:** `src/backend/coff/coff.zig` and `src/backend/elf/elf.zig`.
- **Mechanism:** Emitters produce relocatable object files (`.obj`/`.o`), but the compiler currently delegates the generation of actual executables (`.exe`) to `zig cc`.
- **Risk:** Conflating COFF objects with PE executables, or ELF objects with ELF executables. We must strictly separate them in terminology and architecture.
