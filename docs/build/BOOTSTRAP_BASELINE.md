# Bootstrap Baseline

This document contains the immutable baseline state of the Orbit bootstrap chain prior to hardening. Any change to the compiler that impacts the generated C code will alter these hashes, which requires documenting the new fixed point.

## Environment Details

- **Host Compiler:** Zig compiler with C backend support
- **Target:** `x86_64-windows-msvc`
- **Reference Backend:** Steel (C code generation)
- **Runtime ABI Version:** V1 (Initial argc/argv support via global propagation)

## Baseline Hashes and Sizes

| Artifact | Size (Bytes) | SHA-256 Hash |
| --- | --- | --- |
| `stage1.exe` | 27,648 | `4e6d0c233085b047913c5b085c9f3872138902fe0a06d18a7436f7ed1d96907c` |
| `stage2.exe` | 27,648 | `4e6d0c233085b047913c5b085c9f3872138902fe0a06d18a7436f7ed1d96907c` |
| `stage3.exe` | 27,648 | `4e6d0c233085b047913c5b085c9f3872138902fe0a06d18a7436f7ed1d96907c` |

## Verification Status

- **Stage 2 == Stage 3:** Byte-identical (Verified)
- **Stage 1 == Stage 2:** Byte-identical (Verified due to delegation mode)

## Duration Metrics

- **Stage 1 Build:** ~81 ms
- **Stage 2 Build:** ~75 ms
- **Stage 3 Build:** ~108 ms
