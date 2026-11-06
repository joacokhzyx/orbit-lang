## What this changes

One paragraph. If it changes the emitted C, say so here and explain why the
change is necessary, because that invalidates the canonical and the goldens.

## Which gates you ran, and their output

Name the commands and paste the closing line of each. A PR that has not run
the gates is a draft, not a contribution.

```sh
python scripts/trust.py build --cc gcc --check-stale   # fixed point intact
python scripts/trust.py verify --cc gcc --release
python scripts/corpus_gates.py parity --cc gcc --compiler <fp>
python scripts/corpus_gates.py suite --cc gcc --compiler <fp>
python scripts/corpus_gates.py suite --cc gcc --compiler <fp> --dir tests/std
python scripts/corpus_gates.py werror --compiler <fp> --cc gcc
python scripts/doctor_gates.py cli-probe --compiler <fp> --work <dir>
python scripts/measure.py routes
<fp> fmt --check compiler && <fp> fmt --check tests/suite
<fp> doctor tests/suite
```

## If the emitted C changed

- [ ] I proved the change was necessary, not incidental.
- [ ] `compiler/selfhost/stage3.exe.c` is regenerated in THIS commit
      (`python scripts/trust.py build --promote`).
- [ ] The 33 parity goldens are refreshed in THIS commit
      (`python scripts/corpus_gates.py parity --compiler <fp> --update`).
- [ ] `PUBLISHED_C` in `scripts/trust.py` is updated in THIS commit.

The canonical, the goldens and the `.orb` sources move together or not at all.
A stale canonical is a broken build, not a smaller diff.

## If a measurement is involved

- [ ] The command that produced it is in the description.
- [ ] The hardware, the compiler version and the flags are recorded.
- [ ] The spread across runs is reported, including runs that went badly.

## Anything a reviewer should know

Deliberate trade-offs, skipped work, or a debt row you added to
`ENGINEERING.md`.
