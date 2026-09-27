# Writing a library others can import

There is no package manager, no manifest, and no module system in the sense
most languages mean by that word. What there is, is a set of rules you can
follow. This page is those rules, and what I verified about each one.

Everything here was checked on `orbit 0.1.0-rc.2` (fixed-point build, gcc
13.3.0, Linux x86-64) by running the compiler. Where I could not run
something, it says UNTESTED rather than asserting it.

## The rules

1. **One flat global namespace.** Every function, model, enum, const and type
   in every transitively imported file shares one namespace. There is no
   prefixing, no aliasing, and no scoping of imports.
2. **A name may be declared once across the whole import graph.** Two modules
   that declare the same name is a hard error, not a shadow.
3. **`private` does not restrict anything at an import boundary.** It is
   accepted on `fn` and ignored; on a `type` it is a parse error.
4. **Imports are by path.** Relative paths resolve against the importing
   file. `std/...` and `lib/...` resolve against three fixed roots.
5. **A library cannot declare its dependencies.** There is nothing to
   declare them in.

## 1. The namespace is flat and collisions are fatal

This is the rule that will actually stop you. Two modules, one name:

```orbit
// a.orb
fn helper() -> int { return 1 }
```

```orbit
// b.orb
fn helper() -> int { return 2 }
```

```orbit
// main.orb
import "a.orb"
import "b.orb"
fn main() -> int { return 0 }
```

```console
$ orbit check main.orb
Semantic error: Duplicate symbol: helper
$ echo $?
1
```

`declareSymbol` walks the current scope and reports `Duplicate symbol: <name>`
the moment it sees a second one (`compiler/sema.orb:277`, report at `:283`).
The check is on the symbol's name alone - no module, no origin, no overload. It
does not matter which file is imported first, and it fires even if the two
functions have different signatures.

**What to do about it.** Prefix every public name with your library's name.
`json_parse`, `jwt_sign`, `term_color` - not `parse`, `sign`, `color`. There
is no way around this and the compiler will not warn you in advance, so the
prefix is on you.

Two things follow from the flatness that are worth knowing:

- **A transitive import is a real dependency.** If your library imports
  `std/string/string.orb`, anything that imports your library also gets
  whatever that module declares, and can collide with its own names.
- **A dead import is not free.** Nothing tree-shakes and nothing is scoped, so
  importing a module for one function brings all of its names in - and all of
  its code. I declared three functions in a module, called one of them, and
  both unused ones were in the generated C.

## 2. `private` is decorative

```orbit
// q.orb
private fn secret() -> int { return 42 }
```

```orbit
// r.orb
import "q.orb"
fn main() -> int { print(secret())  return 0 }
```

```console
$ orbit check r.orb
Checked r.orb: no errors.
```

`private` is consumed by the parser and then never consulted again. On a
function it is accepted and dropped; on a type declaration it is rejected
outright:

```console
$ orbit check s.orb        # private type Foo { a: int }
Parser error at line 1: 'private' is not supported on types yet.
```

So there is no way to write a module with a private helper. Either accept that
every name in your file is public, or keep helpers in a file that nothing
imports.

## 3. What is a module, physically

A module is one `.orb` file. The resolver flattens every transitively
imported file into a single AST (`compiler/resolver.orb`), so "module" means
"a file you import", not "a unit of encapsulation" - there is no encapsulation
at all.

Relative imports resolve against **the importing file**, not the working
directory, so they work from anywhere:

```orbit
// app.orb
import "./lib/http/util.orb"
```

```console
$ cd /somewhere/else && orbit check /path/to/app.orb
Checked /path/to/app.orb: no errors.
```

Nested relative imports work the same way: a module at `lib/http/mid.orb`
importing `"./util.orb"` finds `lib/http/util.orb`. Verified.

There is no `use` with an alias - `use "a.orb"` is a parse error
(`Expected module name`). And there is no manifest: I looked for an
`orbit.mod`, an `orbit.toml` or anything the resolver reads, and there is none.
Dependencies are implicit in the import lines and nothing validates them
except the compiler failing to read a file.

## 4. `std/` resolves against three roots, and that is the install trap

A `std/...` or `lib/...` import is looked up in exactly this order
(`resolveStdPath`, `compiler/resolver.orb:69-90`):

1. the **compiler binary's own directory**,
2. that directory's **parent**,
3. the **current working directory**.

Nothing else. No environment variable, no search path you can set, no
`ORBIT_STD` escape hatch.

**Consequence: a released compiler cannot import `std/`.** The release ships
three things - the platform binary, `orbit_bootstrap.c`, and the seed
artifacts. There is no `std/` in it (see [Release Artifacts](RELEASES.md)), and
no installation step puts one next to the binary. So this is the state of a
freshly downloaded compiler:

```console
$ cd /tmp                       # a directory with no std/
$ orbit check prog.orb          # prog.orb: import "std/string/string.orb"
Import error: Could not read imported module: std/string/string.orb
$ echo $?
1
```

The same program, run from a directory that happens to have a `std/`, works:

```console
$ cd /path/to/orbit-lang
$ orbit check /tmp/prog.orb
Checked /tmp/prog.orb: no errors.
```

This is why every gate in the repository runs from the repository root, and
why it has never been caught: in CI the working directory always contains
`std/`, so the third root always answers. **The failure only appears for a user
who installed the compiler, which is exactly the person who is not in CI.**

The workaround today is to put a copy of `std/` beside the binary or beside its
parent, or to run from a directory that has one. If you are shipping the
compiler yourself, do that as an explicit install step and say so.

There is a second, smaller version of the same assumption in the build step:
`orbit build` invokes the C compiler with the literal relative include path
`-I"runtime"`, so the **working directory** also has to contain a `runtime/`
directory. A program that compiles in the repository root fails elsewhere with
`fatal error: socket_compat.h: No such file or directory`. Same family, same
cause, same reason no gate sees it.

## 5. How to write a library, then

Given all of that, a library that other people can actually import looks like
this:

- **Prefix every declaration** with the library's short name. This is the only
  defence against rule 1.
- **Keep the file self-contained.** Import only what you use, and prefer
  `std/` over `lib/` - both resolve the same way, but `std/` is the tree the
  gates exercise.
- **Do not rely on `private`.** If a helper must not be part of your surface,
  put it in a file you never import, or name it so nobody will.
- **Document the expected layout** next to your library: which `std/` copy the
  importer needs and where. Today that is the whole install story.
- **State your compiler version.** There is no compatibility range machinery
  (see [Versioning](VERSIONING.md)), so pin the release you were written
  against. `orbit --version` exists and is the thing to check.

A worked example, deliberately boring:

```orbit
// jsonpath/text.orb
//
// Every public name carries the jsonpath_ prefix: the import namespace is
// global and a bare `text` would collide with anything.

fn jsonpath_text_len(s: string) -> int {
    return s.len()
}

fn jsonpath_text_prefixed(s: string) -> bool {
    return s.len() >= 0
}
```

The prefix is not a style preference. It is the difference between a library
that imports and one that produces `Duplicate symbol: text`.

## What would change this

Two of the five rules are compiler work rather than documentation, and both
are visible in the findings on the project board:

- **The value model** - one machine word per value, no runtime tag, and the
  C cast chosen from the static type alone - is why a library's function
  signatures have to be annotated carefully at every boundary. See
  [the value model](ARCHITECTURE.md#the-value-model-one-machine-word-no-tag).
- **Name resolution and `unknown` becoming detectable** is the work that
  would let the resolver report a collision at the import site with both
  origins named, instead of a bare `Duplicate symbol`.

I would not build a package manager on top of the current resolver. Fixing
the resolution and the type story first is what makes one worth having.

## See also

- [Modules](LANGUAGE_REFERENCE.md#modules) - the import syntax itself
- [Known Limitations](KNOWN_LIMITATIONS.md) - what else does not work
- [Release Artifacts](RELEASES.md) - what a release actually contains
- [the value model](ARCHITECTURE.md#the-value-model-one-machine-word-no-tag)
