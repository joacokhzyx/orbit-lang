# Sovereignty Levels

This document defines the phases of independence (sovereignty levels) for the Orbit programming language compiler and toolchain.

| Level | Definition | Status | Notes |
| --- | --- | --- | --- |
| **L0 Seed** | Zig builds the initial seed compiler | **Active** | The initial compiler binary is built via the Zig compiler. |
| **L1 Self-hosting source** | Compiler written in Orbit | **Active** | `compiler/main.orb` compiles itself using Steel. |
| **L2 Bootstrap fixed point** | Stage 2 == Stage 3 | **Active** | Verified by the bootstrap pipeline tool. |
| **L3 Native subset** | Photon Native emits a subset of machine code | **Active** | Relocatable x86-64 binary writers for ELF/COFF exist. |
| **L4 Compiler-native** | Photon Native compiles the compiler | **Planned** | Stage 1 compiled natively. |
| **L5 Object sovereignty** | Orbit emits relocatable objects directly | **Active** | Native backend generates `.o` and `.obj` files. |
| **L6 Linker sovereignty** | Orbit links executables directly | **Planned** | Native linker to bypass external linkers. |
| **| L7 Toolchain sovereignty** | No external C compiler or linker required | **Planned** | Completely sovereign compilation chain. |
| **L8 Diverse verification** | Diverse Double Compilation (DDC) | **Planned** | Eliminates Trusting Trust threats. |
