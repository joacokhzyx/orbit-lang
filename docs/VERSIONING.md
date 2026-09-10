# Versioning and Compatibility

This document defines how Orbit versions the language, compiler, runtime, and standard library. It is intentionally conservative while the public language contract is still being consolidated.

## Version Format

Orbit releases use:

```text
MAJOR.MINOR.PATCH[-pre-release]
```

Examples:

- `0.1.0` is the first versioned development release.
- `0.1.0-rc.2` is the second release candidate for `0.1.0`.
- `1.0.0` marks the first release under the stable compatibility policy.

Pre-release identifiers are ordered after the base version. A release candidate is not a promise that every planned feature is complete; it means the contents of that candidate are being evaluated for the named release.

## Components

The compiler, runtime, and standard library are released as one Orbit distribution. They share the same version number unless a release note explicitly states otherwise.

The version applies to:

- the Orbit compiler executable;
- the generated-code contract used by the compiler;
- the bundled C runtime;
- the standard library modules;
- the documented command-line interface.

The canonical C seed and fixed-point verification artifacts are implementation and release artifacts. They do not receive an independent public version.

## Compatibility Levels

### Patch releases

A patch release may contain:

- bug fixes that preserve accepted source behavior;
- diagnostic improvements that do not change successful compilation;
- runtime fixes that preserve the documented API;
- documentation and build reproducibility fixes.

### Minor releases

A minor release may contain:

- new language syntax or library APIs;
- new runtime capabilities;
- new diagnostics and opt-in configuration;
- behavior changes required to correct an undocumented or unsafe implementation defect.

Existing documented programs should continue to compile unless a release note identifies a compatibility exception.

### Major releases

A major release may contain:

- removal or incompatible changes to documented language behavior;
- changes to the generated-code or runtime ABI that require source or build changes;
- changes to memory, error, concurrency, or ownership semantics;
- removal of documented command-line options.

The project remains in the `0.x` series while these contracts are being stabilized. During this period, minor releases may include carefully documented breaking changes that would require a major release after `1.0.0`.

## Release Candidates

A release candidate must identify:

- the compiler and runtime revision;
- supported platforms and C compilers;
- known limitations;
- verification results for bootstrap, fixed point, parity, and behavior tests;
- changes since the previous candidate.

A candidate must not be described as stable when an open issue can silently miscompile valid source, invalidate the fixed point, or make a documented runtime operation unsafe.

## Compatibility Policy

Documentation is the source of the public compatibility contract. Internal compiler modules, generated C layout, and experimental features are not stable APIs unless explicitly documented as such.

When a change affects documented behavior, the same change should update:

1. the language reference or runtime documentation;
2. an executable example or regression test;
3. the release notes;
4. the fixed-point and parity artifacts when compiler source changes.

See [Command Reference](COMMANDS.md) for the verification commands and [Engineering Contract](../ENGINEERING.md) for the invariants that govern compiler changes.
