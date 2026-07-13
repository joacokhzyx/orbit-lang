# Defending Against the Trusting Trust Attack

This document outlines Orbit's strategy for defending against compiler backdoor insertion via the trusting trust attack (Thompson, 1984).

## Diverse Double Compilation (DDC)

Orbit implements Diverse Double Compilation:
1. Compile the self-hosted Orbit source code with the original Zig-based compiler (Stage 0), producing executable $A$.
2. Compile the self-hosted Orbit source code with an independent compiler path (e.g. C backend + gcc/clang), producing executable $B$.
3. Use $A$ and $B$ to compile the compiler source again, producing $A_{self}$ and $B_{self}$.
4. If $A_{self}$ and $B_{self}$ are byte-identical (excluding timestamps and path metadatas), it mathematically proves that neither compiler injected a backdoor into the output executable.
