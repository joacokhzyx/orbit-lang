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
| `option.orb.quarantined` | a generic tagged union — the parser has no type parameter list on `union`, and there is no monomorphisation (a generic `model` typechecks and then emits a C `T` that does not exist) |
| `bitwise.orb.quarantined` | bitwise operators — `^` and `~` are invalid characters in the lexer, `&` and `|` are tokens but not binary operators, `<<` and `>>` lex as two separate tokens |
