# Changelog (VS Code extension)

## [Unreleased]

- Highlight: bitwise and shift operators (`& | ^ << >> ~`), now that the lexer
  produces them as real operators.
- Highlight: route decl with `:id`/`{id}` params, object keys (bare and quoted),
  `req.*`/`system.*` builtins, `limit N/unit burst M`, `every N unit`, doc
  `@tags`, import paths; `ok`/`err` no longer fire on field access or keys.
- Autocomplete without a language server: static `req.`/`system.`/`Model.`/HTTP
  completions plus 24 snippets. No hover: anything needing sema would be a guess.
- `Orbit: Format File` (`orbit fmt`, writes only on success) plus format-on-command.
- Output channel `Orbit`, 4-state status bar (checking/clean/N/not-found),
  reused `orbit run` terminal, `orbit.checkOnSave` (default true),
  `orbit.maxProblems` (default 100), save debounce, Save As flow for untitled.
- Tests: `extension_test.js` (vscode stub) and `grammar_test.js` (grammar +
  snippets) run by `npm test`; CI job `vscode-ext` runs tests, a
  version-sync check, and `vsce package`.

## [0.1.0-rc.2]

- Shippable package: `package.json` (`onLanguage:orbit`, languages/grammars/snippets/commands/configuration), `.vscodeignore`, marketplace README. Packaged with `npx @vscode/vsce package`.
- `orbit check` diagnostics on save + `Orbit: Check File`; `Orbit: Build and Run File` runs `orbit run` in a terminal. No language server (`orbit` has no `lsp` subcommand).
- Grammar tracks `compiler/front/lexer.orb`: binary/octal/exponent numbers, `migrations` config key, `true`/`false` only (no `null` literal), fixed char escapes, no phantom `+=`/`?` operators.
- Extension fixes: Windows PATH lookup finds plain `orbit.exe`, `run` is shell-portable (no `ORBIT_CC=` prefix), check saves first and reports unchecked files instead of "no errors".
