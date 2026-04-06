# Orbit Modular Architecture

## Overview
This document describes the new modular architecture of the Orbit compiler after the refactoring from monolithic files to a clean, maintainable structure.

## Directory Structure

```
orbit-binary/
├── src/
│   ├── main.zig                 (~226 lines) - Entry point & CLI
│   ├── lexer.zig                (~458 lines) - Tokenization
│   ├── token.zig                (~180 lines) - Token definitions
│   ├── ast.zig                  (~280 lines) - AST node definitions
│   ├── atlas.zig                (~100 lines) - Atlas config parser
│   ├── parser.zig               (~150 lines) - Main parser coordinator
│   ├── sema.zig                 (~740 lines) - Semantic analysis
│   ├── codegen_c.zig            (~200 lines) - Main C codegen coordinator
│   │
│   ├── parser/                  - Parser modules
│   │   ├── expression_parser.zig    (~340 lines) - Expression parsing
│   │   ├── statement_parser.zig     (~240 lines) - Statement parsing
│   │   └── declaration_parser.zig   (~260 lines) - Declaration parsing
│   │
│   ├── codegen/                 - Code generation modules
│   │   ├── runtime_loader.zig       (~90 lines)  - Runtime inclusion
│   │   ├── expression_gen.zig       (~140 lines) - Expression codegen
│   │   ├── statement_gen.zig        (~200 lines) - Statement codegen
│   │   ├── route_gen.zig            (~100 lines) - Route codegen
│   │   └── model_gen.zig            (~80 lines)  - Model codegen
│   │
│   ├── ir/                      - Intermediate Representation
│   │   ├── ir.zig                   (~130 lines) - IR definitions
│   │   └── builder.zig              (~200 lines) - AST to IR builder
│   │
│   └── runtime/                 - C Runtime (modular)
│       ├── runtime.h                (~20 lines)  - Main runtime header
│       ├── types.c                  (~12 lines)  - Type definitions
│       ├── arena.c                  (~55 lines)  - Arena allocator
│       ├── database.c               (~290 lines) - SQLite operations
│       ├── file.c                   (~35 lines)  - File I/O
│       ├── http.c                   (~60 lines)  - HTTP primitives
│       └── kynx.c                   (~80 lines)  - Security layer
```

## Key Improvements

### 1. Modularization
- **Before**: `codegen_c.zig` was 1350 lines
- **After**: Split into 6 modules (~610 lines total, more maintainable)

- **Before**: `parser.zig` was 1265 lines
- **After**: Split into 4 modules (~990 lines total, clearer separation)

### 2. Runtime Extraction
- **Before**: C runtime embedded as strings in Zig code
- **After**: Separate `.c` files that can be edited independently
- **Benefit**: Better syntax highlighting, easier debugging, cleaner separation

### 3. IR Layer Added
- **New**: Intermediate Representation between AST and C codegen
- **Purpose**: Enables future optimizations (constant folding, dead code elimination)
- **Architecture**: AST → IR → Optimizer → C Codegen

### 4. Fixed Issues
- ✅ Real timing measurements (replaced hardcoded zeros)
- ✅ Indentation consistency
- ✅ Modular architecture (no file > 500 lines except sema.zig at 740)

## Compilation Pipeline

```
Source Code (.orb)
    ↓
Lexer (lexer.zig)
    ↓
Tokens
    ↓
Parser (parser.zig + parser/*)
    ↓
AST (ast.zig)
    ↓
Semantic Analysis (sema.zig)
    ↓
IR Builder (ir/builder.zig)
    ↓
IR Module (ir/ir.zig)
    ↓
[Future: Optimizer]
    ↓
C Codegen (codegen_c.zig + codegen/*)
    ↓
C Code + Runtime (runtime/*)
    ↓
Zig CC Compiler
    ↓
Native Binary
```

## Module Responsibilities

### Parser Modules
- **expression_parser.zig**: Handles all expression parsing with precedence climbing
- **statement_parser.zig**: Parses statements (if, for, while, return, etc.)
- **declaration_parser.zig**: Parses top-level declarations (model, route, fn)

### Codegen Modules
- **runtime_loader.zig**: Loads and includes C runtime files
- **expression_gen.zig**: Generates C code for expressions
- **statement_gen.zig**: Generates C code for statements
- **route_gen.zig**: Generates HTTP route handlers
- **model_gen.zig**: Generates model structs and collections

### Runtime Modules
- **arena.c**: Per-request memory allocation (O(1) cleanup)
- **database.c**: SQLite integration with ORM methods
- **file.c**: File I/O operations
- **http.c**: HTTP request/response handling
- **kynx.c**: Autonomous DDoS protection and rate limiting

## Next Steps

1. **Modularize sema.zig** (740 lines → split into type_checker, scope_manager, etc.)
2. **Implement IR Optimizer** (constant folding, dead code elimination)
3. **Add Tests** (unit tests for each module)
4. **Cross-platform Runtime** (conditional compilation for Linux/Windows)
5. **Self-Hosting** (begin rewriting compiler in Orbit)

## Benefits

- **Maintainability**: Each module has a single, clear responsibility
- **Testability**: Smaller modules are easier to unit test
- **Readability**: No file exceeds 500 lines (except sema.zig)
- **Extensibility**: Easy to add new features without touching unrelated code
- **Collaboration**: Multiple developers can work on different modules
- **Performance**: Real timing measurements for accurate profiling
