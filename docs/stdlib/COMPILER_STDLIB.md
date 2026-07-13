# Compiler Standard Library Specification

This document defines the minimal, core-only standard library structure required to support compiling the Orbit compiler.

## Core Modules

*   `core/option.orb`: `Option<T>` structure and helper methods.
*   `core/result.orb`: `Result<T, E>` structure and helper methods.
*   `core/memory.orb`: Interface for Arena allocation and raw memory copies.
*   `core/slices.orb`: Operations on slices (copying, searching, slicing).
*   `core/numeric.orb`: Checked arithmetic and explicit size conversions.
*   `collections/list.orb`: Dynamic array list mapping to underlying allocator.
*   `collections/map.orb`: Hash map with stable traversal iteration ordering.
*   `collections/string_builder.orb`: Optimized buffer for string accumulation.
*   `io/writer.orb` & `io/reader.orb`: Stream abstractions.
*   `io/terminal.orb`: Output logging and simple diagnostic formatters.
*   `fs/file.orb` & `fs/path.orb`: File system operations.
*   `system/args.orb`: Accessing command-line arguments.
*   `binary/endian.orb`: Byte swap helper functions.
*   `binary/writer.orb`: Little-endian serializing functions.
*   `binary/reader.orb`: Little-endian parsing functions.
