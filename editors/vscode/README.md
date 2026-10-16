# Orbit Programming Language

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Status](https://img.shields.io/badge/Status-0.1.0--rc.2-green.svg)](../../docs/STATUS.md)
![Orbit Banner](https://raw.githubusercontent.com/joacokhzyx/orbit-lang/main/editors/vscode/banner.png)

Syntax highlighting and `orbit check` diagnostics for **Orbit** - a statically
typed language for APIs and microservices.

This extension ships no icon theme on purpose: VSCode has no API for an
extension to paint one icon inside another theme (open request since 2016),
and a bundled theme would force you off the one you use. The Orbit mark for
`.orb` files lives in `icons/orb.png`.

## File icons

Map the extension in your current theme's settings:

**Material Icon Theme** (any icon name from its gallery works):

```json
"material-icon-theme.files.associations": {
    "*.orb": "code"
}
```

**vscode-icons**, with the actual Orbit mark. Copy `icons/orb.png` from this
extension folder to a `vsicons-custom-icons` folder as
`file_type_orbit.png`, then:

```json
"vsicons.customIconFolderPath": "<the folder holding vsicons-custom-icons>",
"vsicons.associations.files": [
    { "icon": "orbit", "extensions": ["orb"], "format": "png" }
]
```

and run `Icons: Apply Icons Customization` from the command palette.

## There is no language server

This extension does not start one, and it is not a missing feature waiting on
a version bump. `orbit` has no `lsp` subcommand:

```console
$ orbit lsp
Unknown command: lsp
Usage: orbit <command> [options]
...
$ echo $?
2
```

An earlier version of this extension spawned `orbit lsp` anyway, so every
activation ended in an error notification and the extension did nothing. If you
want completion, hover text or go-to-definition, they have to be built inside
the compiler first; until then what is here is what the compiler can actually
do.

## What it does

- **Highlighting** for the keywords `orbit` actually lexes, taken from
  `matchKeyword` in `compiler/lexer.orb` - including hex, binary and octal,
  digit-separated numbers with `e/E` exponents, `"""` raw strings, `'c'`
  character literals and `${...}` interpolation holes.
- **Diagnostics on save.** The extension runs `orbit check <file>` and puts
  what comes back in the Problems panel. Save a clean file and the list
  empties.
- **`Orbit: Check File`** from the Command Palette, or click the status bar
  item. Saves first, because `check` reads from disk.
- **`Orbit: Format File`**, which runs `orbit fmt <file>` (`fmt` rewrites only
  on success; a parse error warns and leaves the buffer alone). Also wired as
  the document formatter, so "Format Document" works.
- **`Orbit: Build and Run File`**, which reuses one terminal and runs
  `orbit run <file>` so the server keeps the terminal.
- **Completion without a language server.** A static provider suggests the 14
  real `std/` paths inside `import "..."`, the 8 `req.*` and 8 `system.*`
  members after their dot, the 5 model methods after `Note.`, HTTP methods
  after `route `, and keywords/types/builtins at top level - plus 24 snippets.
  There is deliberately no hover or go-to-definition: without the compiler's
  type table those would be guesses, and a guessed type is how `check`-clean
  programs segfault.
- **Output channel `Orbit`** for skipped-check text; the status bar shows
  checking, clean, N problems, or not-found.

If no `orbit` binary is found, the extension says so once, leaves the status
bar greyed out, and keeps highlighting. It does not throw.

## Quickstart & Installation

### Option 1: Automated Script Installation

If you installed Orbit via the automated installer, the VS Code extension was registered automatically:

**Windows (PowerShell)**:
```powershell
powershell -ExecutionPolicy Bypass -File scripts/install.ps1
```

**Linux / macOS (Bash)**:
```bash
bash scripts/install.sh
```

### Option 2: Manual VSIX Installation

1. Build the extension package:
   ```bash
   cd editors/vscode
   npx @vscode/vsce package
   ```
2. Install in VS Code:
   ```bash
   code --install-extension orbit-*.vsix
   ```

> Run from the repository root so `std/` imports resolve (the compiler
> checks the binary dir, its parent, then the working directory).

---

## Configuration Settings

| Setting | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `orbit.executablePath` | `string` | `""` | Absolute path to the `orbit` or `orbit.exe` binary. Empty searches `PATH`, then `~/.orbit/bin`, then the workspace root. A path that does not exist warns once and falls back to the search. |
| `orbit.checkOnSave` | `boolean` | `true` | Run `orbit check` on save and show diagnostics in the Problems panel. |
| `orbit.maxProblems` | `number` | `100` | Maximum diagnostics kept per file. |

---

## Syntax Highlighting Preview

Everything below is a program `orbit check` accepts. A `port` declaration is
read - it is the default port the generated server binds, and `argv[1]` still
overrides it - while `cors`, `db`, `env` and `migrations` are **parsed and
then discarded**, so they are syntax to read, not settings to rely on. There
is no `database` declaration (only `db`), and decorators such as `@auth`
carry no semantics on their own; auth is `req.bearer_token()` /
`req.has_role()`.

```orbit
// A port declaration is read: the server binds it unless argv[1] wins.
port 3000

model User {
    id: string
    email: string
    role: string
}

route GET "/users" {
    val users = User.all()
    return ok 200 users
}

// Types are lowercase, plus List/Map/Result/Response. `Int` is E1006, not a type.
fn count(xs: list<string>) -> int {
    return xs.len()
}
```

Types the compiler knows: `int`, `float`, `string`, `bool`, `void`,
`list`/`map`/`object`/`result`/`response` (plus `list<T>` element
annotations), with `List`, `Map`, `Result`, `Response` as the same four
capitalised spellings. See [the language reference](../../docs/LANGUAGE_REFERENCE.md).

## Running the parser test

The diagnostic parser has no VS Code dependency and no test framework:

```bash
node editors/vscode/test/diagnostics_test.js
# or from editors/vscode:
npm test
```

## Developing

```bash
cd editors/vscode
node ./test/diagnostics_test.js   # parser fixtures, verbatim `orbit check` output
npx @vscode/vsce package          # produces orbit-*.vsix
```

See [CHANGELOG.md](CHANGELOG.md) for what changed in this package.

---

## License

Distributed under the **MIT License**. See [LICENSE](LICENSE) for more information.
