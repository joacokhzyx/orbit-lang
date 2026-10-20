# Orbit formatter (`orbit fmt`)

This document is the contract for `orbit fmt`. It records the de facto style
inferred from the repository, rule by rule, with evidence. The formatter
implements exactly what is written here.

Corpus: recursive `*.orb` under `compiler/` (26 files), `tests/suite/` (73),
`std/` (19) and `tests/std/` (23), plus `examples/*.orb` (13, minus
`orbit_full_expansion.orb`). 154 files -- the exact list the fmt gate verifies
(`make all` prints `fmt ... (154 files, ...)`).
The rules below were inferred from that corpus with strings and comments
stripped, so stylish string contents (JSON payloads, URLs) do not pollute
them. The evidence lines say what the corpus shows, not how many times, so
they stay readable as the corpus grows.

## What the formatter is

`orbit fmt` is token-based. It reuses the self-hosted lexer
(`compiler/front/lexer.orb`, `compiler/front/token.orb`), preserves every token, every
string/character literal byte, and every comment, and only rewrites
whitespace: indentation, intra-line spacing, and line breaks. Because the
generated C contains no source line directives and string contents are never
touched, formatting cannot change codegen.

Validation gate: `fmt` accepts exactly what `orbit check` accepts. The input
is parsed, imports are resolved, and the program is typechecked with the same
pipeline (`checkSourceWithFile`). Anything else is reported (same messages as
`check`) and the file is left untouched.

## Commands and exit codes

- `orbit fmt <file.orb>` formats one file. The whole output is built in
  memory and written only on full success. A failure never leaves a partial
  file. Prints `Formatted <path>.`, or `Already formatted <path>.` when no
  change was needed. `--quiet` silences both lines. Single-file mode has
  no `--verbose` output beyond them.
- `orbit fmt --check <file.orb|dir>` prints the paths of files that need
  formatting (one per line, sorted) and exits 1. When everything is
  formatted it prints nothing and exits 0. `--verbose` adds a
  `scanned N files, M need formatting` line. A directory is scanned
  recursively for `*.orb` files. Inputs that fail validation are listed and
  also get the usual diagnostics on stderr.
- `orbit fmt --help` prints usage. Missing arguments or unknown flags print
  usage and exit 2. Operational failures (unreadable file, malformed input,
  unwritable output) exit 1. Success exits 0.

## Style rules

### 1. Indentation: 4 spaces, recomputed from brace depth

Evidence: every indented line in the corpus uses a multiple of 4 spaces
(0/4/8/12/...); zero tab-indented lines; zero trailing
whitespace lines. Indentation is recomputed from `{` depth, so
mis-indented input is fixed (the corpus itself has a few such lines, e.g.
single-statement `if` bodies that drift, which `fmt` aligns).

Only `{` / `}` change depth. `(` / `[` never span lines in the corpus (zero
lone `)` or `]` lines), so call, index, list-literal, and generic-argument
contents are joined onto one line with single spaces.

### 2. Braces: same line as the construct, `}` placement preserved

Evidence: every `keyword-or-paren {` same-line opening in the corpus, zero
lone `{` lines.
An opening brace is always joined to the preceding token with one space:
`) {`, `else {`, `=> {`, `name {`, `@auth {`.

- `{}` stays together with no inner space (`_ => {}`, `[]`-style empties).
  Every empty-`{}` site in the corpus is inline. A multi-line empty block
  (`{\n}`) collapses to `{}` (rare, against many inline sites, so the majority
  wins).
- Otherwise the inside of a same-line `{ ... }` block gets one space on
  each side: `{ st.success = false; return false }`.
- A multi-line block puts a newline after `{` (unless the source kept code
  on the brace line, which is preserved, e.g. nested single-line `if`/`else`
  chains). The closing `}` keeps its source line break: newline before
  `}` when the source had one, otherwise ` }` (cascading `} } } }` closers
  are preserved).
- No blank line is ever added or kept directly after `{` or directly before
  `}` (0 occurrences in the corpus).

### 3. `else` aligns with the block it closes

Evidence: every `} else` / `} else if` same-line closer in the corpus closes
a multi-line block, and every `else` / `else if` line that starts a new line
follows a single-line block. Zero violations either way.

- After a multi-line block: `} else {`, `} else if cond {` (joined even if
  the input split them).
- After a single-line block: newline plus `else` / `else if` at the same
  indent as the `if`:
  ```
  if v.value.indexOf("TAG_") != -1 { inf = getEnumNameFromTag(v.value) }
  else { inf = "string" }
  ```
  An empty `{}` block is the exception: it reads as a unit, so `else` joins
  (`if x {} else { ... }`; no corpus sites, keeps the output a fixed point).
- `catch` always stays attached to its `try` expression with spaces
  (`try make_failure() catch {`; `} catch` never occurs).

### 4. Spacing inside lines

- Binary operators and `=` get exactly one space on each side: `=`, `==`,
  `!=`, `<`, `<=`, `>`, `>=`, `<<`, `>>`, `+`, `-`, `*`, `/`, `%`, `&&`,
  `||`, `|`, `^`, `->`, `=>`. Evidence: zero unspaced occurrences outside
  strings, for every one of them, `|` union pipes included. The bitwise
  and shift operators occur spaced in `tests/suite/bitwise_operators.orb`.
- Unary `!`, `-` and `~` attach to their operand with no space after
  (`!req.has_role("admin")`, `-(-5)`, `~mask`). Every unary `!` in the
  corpus is written that way. A `-` is unary after an operator, `=`, `(`,
  `[`, `{`, `,`, `;`, `=>`, `->`, `:`, `|`, another `-`/`!`, a keyword, or
  at a statement start. Elsewhere it is binary. `~` has no binary form, so
  it always attaches. (Spacing never affects meaning: the token stream is
  unchanged.)
- `&` is two spellings: the prefix sigil (pointer types, e.g. `: &Foo`)
  attaches with no space after, like `!`, and the binary operator
  (bitwise-and) gets one space on each side. The lookback that decides is
  the unary minus's: after a keyword, an opening delimiter or the start of
  the file it is the sigil. After a value (a word, `)`, `]`, `}`) it is the
  operator. The prefix spelling does not occur in the corpus. The operator
  does, spaced, in `tests/suite/bitwise_operators.orb`.
- `:` has no space before and one space after (`name: type`, `x: int = 3`).
  Zero violations. `::` never occurs.
- `,` has no space before and one space after (`f(a, b)`). No bare comma
  outside strings. A trailing comma directly before `)` / `]` keeps
  no space after it.
- `;` separates same-line statements with one space after
  (`{ a; b }`; every corpus site is mid-line). At block level a newline
  after `;` or `,` is preserved (one per line, as in `enum`/`union`
  variant lists). Inside `(`/`[` contents it is joined with a space (the
  corpus never spans those).
- `.` never takes spaces (`a.b()`, `ports[0]`). Zero spaced occurrences.
- `(`/`)`/`[`/`]` have no inner spaces (`f(a, b)`, `[]`, `()`). `[` attaches
  to the previous token (`ports[0]`; a `return []` site keeps its space
  after the keyword). `(` attaches directly except after a keyword
  (`if (x) {`, `return (x)`), but `ok` and `err`
  are call-like value keywords and attach (`ok(41)`, `err("msg", 7)`), never
  spaced. After operators, `,`, `:`, `=>`, `->`, `{`, or `}` the
  space before `(`/`[` comes from the operator rule (`= (`, `, (`).
- Two adjacent words/literals are separated by one space (`fn main`,
  `route GET "/health"`, `return ok 200 ...`, `val mut total`).
- Conditions keep their source parentheses: bare `if x == y {` and
  parenthesised `if (x) {` are both left as written. Only inner spacing is
  normalised.

### 5. Blank lines: preserved, at most one, never inserted

Evidence: exactly one blank line separates nearly all top-level
declarations. The exceptions are structural (consecutive `import` lines,
`port`/`cors`/`db`/`env` groups, comment-attached declarations, stacked
single-line models) plus a handful of missing blanks. Stray blanks are rare:
one mid-file double blank, one file missing its final newline, and a few
files with one (or two) extra blank lines at end of file.

- Two or more consecutive blank lines collapse to one.
- No blank line is added after `{`, before `}`, at the start of the file,
  or between declarations. Existing ones (max one) are kept.
- The file ends with exactly one trailing newline (LF). A corpus file that
  lacks it gets one.

### 6. Line endings, tabs, BOM, comments, strings

- Output uses LF (`\n`) only, matching the committed canonical form (the
  working-tree CRLF comes from `core.autocrlf`). Tabs become indentation
  spaces. Trailing whitespace is stripped. Carriage returns are dropped.
- On Windows checkouts, `.gitattributes` pins `*.orb` to `text eol=lf` so
  fresh clones materialize LF files and `fmt --check` stays quiet. Files
  already materialized as CRLF keep working (status stays clean) but are
  listed by `--check` until re-materialized. Reformatting them once
  converts them to LF.
- A UTF-8 BOM is preserved when present (one suite file relies on BOM
  tolerance). It is never added.
- Comments are preserved verbatim and re-attached by position: same-line
  trailing comments keep one space before `//` (locally aligned ones are
  normalised), own-line comments
  keep their line (indented to the current level). `/* ... */`
  comments in the corpus stay inline. Comment text is never reformatted.
- String, character, integer, and float literal text is emitted byte for
  byte, including `${...}` interpolation and escapes. The formatter never
  wraps long lines (the corpus has lines far past 120 columns, including a
  1000+ column union alias). It never joins or splits string contents.

## Normalise vs leave alone (summary)

Normalised: indent width and consistency, and spacing around every operator /
colon / comma / semicolon / dot / paren / bracket / brace / arrow. This covers
`(`/`[` joining, `{` joining, `else` placement after `}` (rule 3) and the
trailing-comment gap (one space). It also covers blank-line collapsing,
leading/trailing blank stripping, CRLF/tabs/trailing whitespace, the single
trailing newline and BOM preservation.

Left alone: the token stream (names, keywords, literals, punctuation choice),
condition parentheses, and statement-per-line layout (single-line blocks stay
single-line, multi-line stay multi-line). Also left alone: blank lines between
declarations (never inserted), long lines (never wrapped), comment and string
contents, and the rarity of the `&` prefix (grammar-derived, no corpus sites).

## Risks

- `compiler/selfhost/stage3.exe.c` (canonical C) goes stale after any
  compiler change by design: refreshing it needs
  `scripts/build_selfhost.py --promote` (a long build).
- `--check <dir>` lists files with `find ... | sort` (POSIX) or
  `cmd /c dir /s /b ... | sort` (Windows) through the same shell-exec
  helper the build driver uses. Paths containing double quotes are not
  supported. An unreadable path (or a directory with no `.orb` files)
  reports `Error: Could not read input path:` with exit 1 rather than
  silently passing.
- The `&` prefix rule and the continuation-line indent have no corpus
  sites. Both follow the grammar and the surrounding rules and are
  documented as such.
