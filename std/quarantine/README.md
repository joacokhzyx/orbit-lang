# Quarantine

Modules that are **specified but not implemented**. A module lands here
when the language cannot yet express the feature it describes and the
alternative would be to ship something that looks like the
feature and is not.

## Why these are not `.orb`

`.orb` is the toolchain's marker for "this is loadable Orbit source":
the import resolver will load it and `orbit fmt` will parse it. A file
that the parser cannot read must not carry that extension, or it breaks
`orbit fmt --check std` on every run and can be `import`ed into a
program only to produce a parse error.

So quarantined modules use `.orb.quarantined` and live in this one
directory instead of beside the modules that work. Nothing imports them,
nothing formats them, and the header of each says exactly which language
feature is missing, with the repro, and what lifting the quarantine
requires.

A quarantined module is not deleted. Deleting loses the only written
record that the feature was wanted; the git history alone does not say
*which* feature or *why* it is impossible today.

## What does not belong here

- A syntax slip (a semicolon, a keyword used as an identifier, `or`
  instead of `||`). Fix it, test it, and it is a real module.
- A function that computes something other than what its name says. That
  is not a missing feature, it is a lie; **delete it**.
- A module already provided by the language. Delete the shadow.

## Current contents

Empty. The directory and these rules stay for the next module the language
cannot express; `orbit fmt --check std` and the import resolver still treat
`.orb` as "loadable", so a specified-but-unimplementable module still has to
land here rather than beside the modules that work.

## Lifted

`bitwise.orb.quarantined` was the counter-example to the rule above: a
syntax slip (`val`, a keyword, used as a parameter name) sitting in
quarantine instead of being fixed and tested. Lifted 2026-10-18: it is
`std/sys/bytes/bitwise.orb` again, `tests/std/test_bitwise.orb` covers
the vectors its header published, and the import-all imports it. Git
keeps the record that the module was wanted; this section says where it
went.

`option.orb.quarantined` is `std/option/option.orb`, lifted 2026-11-02.
The missing feature was a generic tagged union, and it closed in three
parts: the parser reading a type parameter list on `union` (2026-11-01),
the variant registry keyed by the owner the program wrote rather than by the
bare variant name, so two instances could coexist (2026-11-01,
`docs/KNOWN_LIMITATIONS.md`), and the substitution itself -- an instance
minted from the position that *writes* the type, so `Option<int>` and
`Option<string>` are two declared tag sets with two payload types
(2026-11-02, `8e229fe`). `tests/std/test_option.orb` covers the three
positions that write a type, and
`tests/negative/n118_generic_union_needs_a_written_type_for_none.orb`
pins the payload-less `None` that no written type names, which is still
refused with `E1006`. The import-all imports the module, because a union
declared in one file and instantiated in another is the case the header of
that quarantine file could only describe.

