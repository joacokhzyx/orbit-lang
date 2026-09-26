## What this changes

One paragraph. If it changes the emitted C, say so here and explain why the
change is necessary, because that invalidates the canonical and the goldens.

## Which gates you ran, and their output

Name the commands and paste the closing line of each. A PR that has not run
the gates is a draft, not a contribution.

```sh
python scripts/build_selfhost.py --cc gcc --check-stale   # fixed point intact
python scripts/verify_seed.py --cc gcc --release          # 5/5
python scripts/parity_selfhost.py --cc gcc --compiler <fp>  # 32/32
python scripts/test_suite.py --cc gcc --compiler <fp>     # 25/25
python scripts/test_suite.py --cc gcc --compiler <fp> --dir tests/std  # 13/13
python scripts/werror_gate.py --compiler <fp> --cc gcc    # 9/9
python scripts/cli_probe.py --compiler <fp> --work <dir>  # 36/36
python scripts/routes_probe.py                            # 72/72
<fp> fmt --check compiler && <fp> fmt --check tests/suite
<fp> doctor tests/suite
```

## If the emitted C changed

- [ ] I proved the change was necessary, not incidental.
- [ ] `compiler/selfhost/stage3.exe.c` is regenerated in THIS commit
      (`python scripts/build_selfhost.py --promote`).
- [ ] The 32 parity goldens are refreshed in THIS commit
      (`python scripts/parity_selfhost.py --compiler <fp> --update`).
- [ ] `PUBLISHED_C` in `scripts/verify_seed.py` is updated in THIS commit.

The canonical, the goldens and the `.orb` sources move together or not at all.
A stale canonical is a broken build, not a smaller diff.

## If a measurement is involved

- [ ] The command that produced it is in the description.
- [ ] The hardware, the compiler version and the flags are recorded.
- [ ] The spread across runs is reported, including runs that went badly.

## Anything a reviewer should know

Deliberate trade-offs, skipped work, or a debt row you added to
`ENGINEERING.md`.
