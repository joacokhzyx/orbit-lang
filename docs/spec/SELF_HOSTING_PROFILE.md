# Orbit Self-Hosting Language Profile

This document specifies the minimal subset of the Orbit programming language required to write and compile the self-hosted Orbit compiler itself. 

## Profile Feature Support Matrix

| Feature | Parser | Sema | IR | MIR | Native | Steel | Stdlib | Tests |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| Modules & Imports | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Functions & Recursion | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Mut/Const Variables | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Structs/Models | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Enums & Tagged Unions | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Exhaustive Match | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Result & Option | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Slices & Arrays | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Lists & Maps | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Strings & Byte Buffers| Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Explicit Int Types (i8-i64, u8-u64) | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Bitwise Ops & Shifts | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Controlled Pointers | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Extern Declarations | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| File I/O & CLI Args | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Memory Allocation | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
