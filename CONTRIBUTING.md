# Contributing to Orbit

Thank you for your interest in contributing! This guide will help you get started.

---

## Development Setup

**Prerequisites**:
- [Zig ≥ 0.14](https://ziglang.org/download/) — `zvm install master` or official binaries
- A C compiler: `cc`, `clang`, or `gcc` on PATH
- Git

```bash
git clone https://github.com/orbit-lang/orbit.git
cd orbit/orbit-binary
zig build          # builds the compiler
zig build test     # runs all unit tests
```

---

## Project Structure

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full pipeline overview.

```
src/
├── main.zig          # entry point — start here
├── lexer.zig         # tokeniser
├── parser/           # recursive-descent parser
├── sema/             # semantic analysis & type checking
├── ir/               # intermediate representation
├── codegen/          # C code generator
├── runtime/          # embedded C runtime library
└── terminal/         # compiler UI
```

---

## Code Style

### Zig
- Follow the [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide).
- All `pub fn` must have a `///` doc-comment.
- All source files must start with a `//!` module doc-block.
- Run `zig fmt src/` before committing.

### C
- K&R brace style.
- Every non-static function must have a `/** @brief … */` comment.
- Header guards: `#ifndef ORBIT_<FILE>_H` / `#define ORBIT_<FILE>_H`.

---

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(arena): add epoch snapshot/restore for nested scopes
fix(http): handle zero-length body in orbit_parse_request
docs(kynx): document siege mode thresholds
chore: remove stale pdb artifacts
```

---

## Pull Request Checklist

- [ ] `zig build` succeeds with no warnings.
- [ ] `zig build test` passes all tests.
- [ ] New `pub fn` have `///` doc-comments.
- [ ] New files have a `//!` / `/** @file */` header.
- [ ] CHANGELOG.md updated under `[Unreleased]`.
- [ ] PR description explains *why*, not just *what*.

---

## Reporting Issues

- **Bugs**: include the `.orb` file that triggers the bug, the error output, and your OS/Zig version.
- **Feature requests**: open a Discussion first to align on design before writing code.

---

## License

By contributing you agree your changes will be released under the [Apache 2.0 License](LICENSE).
