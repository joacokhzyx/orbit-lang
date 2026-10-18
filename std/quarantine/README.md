# Quarantine

Modules that are **specified but not implemented**. A module lands here
when the language cannot yet express the feature it describes and the
honest alternative would be to ship something that looks like the
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

| module | missing language feature |
|---|---|
| `option.orb.quarantined` | a generic tagged union: `union` takes no type parameter list (so `union Option<T>` is a parse error), nothing infers the argument at construction (a variant constructor names the variant, not the union), and the variant registry is flat by variant name, so two instances would collide. A generic `model` is not the pattern to copy here — it monomorphises today, and its literal names the model, which is exactly what a variant constructor does not do |

## Lifted

`bitwise.orb.quarantined` was the counter-example to the rule above: a
syntax slip (`val`, a keyword, used as a parameter name) sitting in
quarantine instead of being fixed and tested. Lifted 2026-10-18: it is
`std/sys/bytes/bitwise.orb` again, `tests/std/test_bitwise.orb` covers
the vectors its header published, and the import-all imports it. Git
keeps the record that the module was wanted; this section says where it
went.
