# Terminal UI

The compiler draws its progress and its results in three tiers. The tier is
chosen once per stream, so a redirected stdout with a live stderr gets a plain
result and a styled progress block. `compiler/tools/ui.orb` holds the tiers,
the glyphs and the layout; `runtime/console.c` holds what only the OS can say.

## Tiers

| Tier | Chosen when | Output |
|---|---|---|
| rich | the stream is a console, escapes are enabled on that handle, the console takes UTF-8, the terminal has 256 colors, and none of CI, `NO_COLOR` or `TERM=dumb` is set | Unicode glyphs, rounded cards, `▰▱` stage bars with a violet-to-cyan gradient, animated progress |
| color | the stream is a console with escapes, but UTF-8 or 256 colors is missing | the same layout, static, ASCII glyphs, `[####----]` bars, basic 16-color styles |
| plain | anything else: a pipe or file, `CI`, `NO_COLOR`, `TERM=dumb`, `--color never`, escapes could not be enabled | the output the compiler printed before the tiers existed, byte for byte |

Plain is not a screen of its own. Each command keeps its previous code path and
branches into `ui.orb` only when the tier is not plain. The doctor goldens and
`cli_probe.py` hold that output and none of them changed with the tiers.

The measured facts come from `orbit_ui_caps(fd)` in `runtime/console.c`. It
returns three bits per stream: console, escapes enabled on that handle (the call
enables them), and UTF-8 output. On Windows that is `GetConsoleMode`,
`SetConsoleMode` with `ENABLE_VIRTUAL_TERMINAL_PROCESSING` and
`SetConsoleOutputCP(65001)`, so a stream whose mode cannot be set falls to
plain. On POSIX a TTY counts as a console with escapes, and UTF-8 comes from
`LC_ALL`, `LC_CTYPE` or `LANG`.

Truecolor is used when `COLORTERM` is `truecolor` or `24bit`, when
`WT_SESSION` is set, or when `TERM_PROGRAM` is `vscode`, `WezTerm` or
`iTerm.app`. Other 256-color terminals get a six-step ramp. A Windows console
with escapes counts as 256 colors.

## Overrides

| Setting | Effect |
|---|---|
| `ORBIT_UI=rich`, `color`, `plain` | forces the tier on every stream, whatever the terminal says |
| `--color never` | plain |
| `--color always` | skips the `CI`, `NO_COLOR` and `TERM` checks, still needs a console; a pipe keeps the colors it had |
| `--color auto` | the detection above |
| `ORBIT_UI_MOTION=0` | reduced motion: the rich layout with final frames only |
| `ORBIT_UI_MOTION=force` | animates into a pipe; the interrupt probe uses it |

## Screens

- `orbit build` and `orbit run` draw a header and one row per stage on stderr:
  parse, resolve, check, ir, then `native` (R6, link included) or `c` and
  `link`. A bar has 12 cells and is proportional to the slowest stage. The
  result line goes to stdout: output path, total time, `.text` size of the image
  and backend. `run` adds a dim rule before the program's own output.
- Error cards are rounded boxes with `file:line:col`, the message, one line of
  context on each side, a colored underline under the token, the hint after an
  arrow, and the error kind in the bottom edge. Diagnostics without a code or a
  position keep their one-line form.
- `orbit check`, `fmt` and `doctor` end in a card with counts (files, errors,
  warnings, formatted or unchanged) and the time. The per-finding lines and the
  paths printed by `fmt --check` are unchanged.
- `orbit --help`, `orbit --version` and bare `orbit` print a banner and, for
  help, the commands in three groups.

Cards are as wide as the console minus two columns, with the console width
clamped to 40..120 and 80 when it is unknown.

## Motion

In the rich tier with a console on stderr, one thread repaints the build block
about 12 times a second and sleeps on an event between frames. The compiler
passes the whole block as text; byte `0x01` in it becomes the orbital frame and
`0x02` the running milliseconds of the active stage. The calls are
`orbit_ui_anim_start`, `orbit_ui_anim_stage` and `orbit_ui_anim_stop`.

The cursor is hidden while the thread runs. The sequence `ESC[?25h ESC[0m`
restores it on a normal stop, on `exit`, on Ctrl-C and Ctrl-Break (the console
control handler on Windows, `SIGINT` and `SIGTERM` on POSIX) and in the
unhandled-exception filter. While the block is animated, R6's diagnostic is
captured and printed after the block settles.

The thread and the other terminal calls exist only in the runtime built for the
compiler (`ORBIT_WITH_EXEC`). `console.o` is 368 bytes of `.text` in the archive
for user programs and 4360 bytes in the compiler's.

## Preview

```text
orbit build hello.orb -o hello
ORBIT_UI=rich orbit build hello.orb -o hello      # force the rich tier
ORBIT_UI=color orbit build hello.orb -o hello     # the ASCII tier
ORBIT_UI=rich ORBIT_UI_MOTION=0 orbit check bad.orb
ORBIT_UI=plain orbit build hello.orb -o hello     # the old output
```

## Snapshots

`scripts/ui_snapshots.py` runs twelve screens in the rich tier
(`ORBIT_UI=rich ORBIT_UI_MOTION=0`, truecolor) and in the color tier
(`ORBIT_UI=color`) and compares them with `tests/ui/<screen>.<tier>.txt`.
Escape sequences stay in the files, so a changed color is a changed snapshot.
Times, sizes and the cells of a bar vary between runs and are masked.

```text
python scripts/ui_snapshots.py --compiler <orbit> --cc <gcc>           # check
python scripts/ui_snapshots.py --compiler <orbit> --cc <gcc> --update  # rewrite, then read the diff
```

The same script runs an animated build of `compiler/host/main.orb`, sends it a
console break and requires the stream to end with `ESC[?25h ESC[0m`. It reports
"skipped" when the platform offers no console to send the break to. `dev.py`
runs it as the `ui_snapshots` gate in tier 1.
