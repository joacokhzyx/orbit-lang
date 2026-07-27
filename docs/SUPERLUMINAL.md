# Superluminal

Superluminal is the compile-time optimization and code synthesis engine of Orbit. Its core subcomponent, CTEVAL (Compile-Time Universal Evaluator), automatically identifies and executes pure computational graphs inside the compiler, replacing complex function calls with integer or memory constants.

Unlike traditional compilers that require manual programmer annotations (`constexpr` in C++, `const fn` in Rust), Superluminal operates transparently on the Intermediate Representation (IR).

---

## Pipeline Architecture

Superluminal operates between IR construction (`src/ir/builder.zig`) and MIR lowering (`src/backend/mir/builder.zig`).

```
  ┌───────────────────┐
  │   IR Module       │
  └─────────┬─────────┘
            │
            ▼
  ┌───────────────────┐
  │ Purity Analysis   │  Scans side-effects, I/O, globals, DB, HTTP
  └─────────┬─────────┘
            │
            ▼
  ┌───────────────────┐
  │ CTEVAL Evaluator  │  Runs pure IR call graphs in memoized interpreter
  └─────────┬─────────┘
            │
            ▼
  ┌───────────────────┐
  │ Constant Folding  │  Replaces call + arg sequence with load_const
  └─────────┬─────────┘
            │
            ▼
  ┌───────────────────┐
  │ Optimized MIR     │
  └───────────────────┘
```

---

## Purity Analysis Engine

A function is classified as **pure** if and only if:
1. It does not perform file, network, or console I/O (`print`, `orbit_file_write`, `http_write`).
2. It does not query or mutate databases (`db_query`, `db_set`).
3. It does not mutate global state or read non-deterministic inputs (`orbit_clock_ns`).
4. All callee functions in its internal call graph are also pure.

```zig
pub fn isPureFunction(func: *const IRFunction, module: *const IRModule) bool {
    for (func.instructions.items) |instr| {
        switch (instr.opcode) {
            .db_get, .db_set, .db_all, .db_where,
            .http_response, .alloc, .free => return false,
            .call => {
                if (instr.operand1 == .symbol) {
                    const callee_name = instr.operand1.symbol;
                    if (module.getFunction(callee_name)) |callee| {
                        if (!isPureFunction(callee, module)) return false;
                    } else {
                        return false; // External ABI call
                    }
                }
            },
            else => {},
        }
    }
    return true;
}
```

---

## Memoized Evaluation Engine

Superluminal executes pure IR instructions inside an in-compiler virtual interpreter (`src/superluminal/cteval.zig`).

To prevent exponential time complexity during recursive evaluation (such as naive Fibonacci $O(2^N)$), Superluminal memoizes all intermediate call arguments and return values:

$$\text{MemoTable}: (\text{FunctionID}, \text{ArgVector}) \longrightarrow \text{ReturnValue}$$

```
Evaluating fib(35)...
  -> Check memo table for (fib, [35]) -> Miss
  -> Check memo table for (fib, [34]) -> Miss
  ...
  -> Evaluates in O(N) interpreter steps
  -> Result: 9227465 cached and returned
```

### Safety Thresholds

To guarantee compilation deterministic completion and prevent infinite loops during build time:

- **Max Recursion Depth**: 4,096 call frames
- **Max Instruction Steps**: 10,000,000 steps
- **Time Threshold**: 500 ms execution budget per evaluation

If any threshold is exceeded, Superluminal aborts compile-time evaluation and falls back to standard runtime codegen.

---

## Constant Replacement Transformation

Given an IR call site where all arguments are statically known constants and the target function is pure:

### Before Superluminal Optimization

```assembly
; IR Call Sequence
arg r_1, 35
r_2 = call fibonacci
arg r_2
call print
```

### After Superluminal Optimization

```assembly
; Transformed IR Output
r_2 = load_const 9227465
arg r_2
call print
```

Runtime CPU execution time for the calculation drops from microsecond-level recursion to **0 nanoseconds**.

---

## Performance Metrics

| Optimization Pass | Scope | Typical Speedup | Binary Footprint Impact |
| :--- | :--- | :--- | :--- |
| **CTEVAL** | Call graph evaluation | 100% reduction for pure functions | Reduces code size (eliminates function bodies) |
| **Constant Folding** | Arithmetic & logical expressions | $O(1)$ constant propagation | Reduces instruction count |
| **Strength Reduction** | Power-of-two multiplication / division | 2–3x faster opcode execution | Replaces `imul` with `shl` / `shr` |
