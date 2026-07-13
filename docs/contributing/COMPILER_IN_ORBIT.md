# Compiling Orbit with Orbit

This guide describes how to work with the self-hosted Orbit codebase.

## Codebase Organization

*   `compiler/lexer.orb`: Source code tokenizer.
*   `compiler/parser.orb`: Syntax analyzer.
*   `compiler/sema.orb`: Semantic validation and type inference.
*   `compiler/ir.orb`: High-level intermediate representation.
*   `compiler/main.orb`: Entry point and driver.

## Testing Guidelines

*   Run `orbit test` inside the compiler directory.
*   Always test changes using both the C backend (Steel) and the native backend (Photon Native) to ensure compiler outputs are equivalent.
