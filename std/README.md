# Orbit Standard Library (`std/`)

Importable Orbit sources. Import by path:

```orbit
import "std/string/string.orb"
```

Ownership rule: shared `extern` bindings have exactly one owning
module. Import the owner instead of redeclaring; a program declaring
the same extern twice fails check with "Duplicate symbol".

## Module index

| module | import path | provides |
|---|---|---|
| bytes | `std/bytes/bytes.orb` | `Buffer` byte buffer: `newBuffer`, `appendByte`/`appendSlice`, `writeFrame`/`readFrame`, `readAt`, `sliceBuf`, `availableRead`, `consume`, `clear` |
| lists | `std/collections/lists.orb` | string/int list helpers: `getOr`, `firstOr`, `lastOr`, `containsStr`/`containsInt`, `indexOfStr`/`indexOfInt`, `reverse` |
| convert | `std/convert/convert.orb` | number/text bindings: `intToString`, `charFromCode`; owns `orbit_int_to_string`, `orbit_string_to_int`, `orbit_string_from_char_selfhost` |
| file | `std/fs/file.orb` | path-based file API: `readAll`, `writeAll`, `append`, `exists`, `removeFile`, `listDir` |
| hash | `std/hash/hash.orb` | `sha256Hex`, `hmacSha256` over the runtime crypto |
| io | `std/io/io.orb` | console output: `supportsColor`, hex `gradient` over `std/sys/term/color.orb` styling |
| json | `std/json/json.orb` | `jsonQuote` for interpolating runtime strings into raw JSON templates |
| log | `std/log/log.orb` | stateless logging: `withReq`, `toJsonLine`, `info`, `warn`, `error`, `debug` |
| string | `std/string/string.orb` | string utilities: `startsWith`, `endsWith`, `contains`, `indexOf`, `replace`, `trim`, `toUpper`, `toLower`, `join`, `split`, `padLeft`, `padRight`, `parseIntChecked` |
| jwt | `std/sys/crypto/jwt.orb` | HS256 JWT: `signToken`/`signHs256`, `verifyToken`, `verifyHs256`, `verifyWithKeys`, `decodePayload`, `getExp` |
| process | `std/sys/proc/process.orb` | process and environment: `pid`, `getEnv`/`getEnvOrDefault`, `execStatus`, `exitProcess`; owns `system_env` |
| color | `std/sys/term/color.orb` | TrueColor/ANSI styling: `wrapBold`/`wrapDim`/`wrapUnderline`, `wrapRgbForeground`/`wrapRgbBackground`; owns TrueColor styling |
| assert | `std/test/assert.orb` | exit-code test asserts: `assertTrue`, `assertEqInt`, `assertEqStr`, `*Msg` forms, `failFastHere` |
| time | `std/time/time.orb` | clocks: `uptimeSeconds` plus `tickNs`/`sinceNs`/`sinceMs`/`sinceNsBetween` for sub-second spans |

## Naming convention

Modules live at `std/<name>/<name>.orb`: the directory and the file
share the module name. Three paths predate the convention and are kept
as-is because renaming them would break every existing import:

- `std/collections/lists.orb` (directory `collections`, file `lists`)
- `std/fs/file.orb` (directory `fs`, file `file`)
- `std/test/assert.orb` (directory `test`, file `assert`)

Do not rename any `std/` path to fit the convention; imports are the
contract.

`std/sys/` nests one level deeper (`std/sys/<area>/<module>.orb`)
for platform-adjacent modules that bind OS or runtime surface rather
than pure Orbit logic: `proc/process`, `term/color`, `crypto/jwt`.

## Quarantine

Specified-but-unimplementable modules live in
[`quarantine/`](quarantine/README.md) as `.orb.quarantined` files
(the parser cannot read them, so they must not carry `.orb`). Nothing
imports them. See `quarantine/README.md` for the rules and the current
contents (`option`, `bitwise`).
