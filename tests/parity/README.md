# Parity battery (W1)

Byte-identity contract between the two compiler lineages that must both be
`true` for the STAB-2 gate to pass:

| FE exit | SH exit | Contract |
|---|---|---|
| 0 | 0 | generated C must be byte-identical |
| != 0 | != 0 | captured stderr diagnostics must be byte-identical |
| any other combo | | FAIL |

Probes live in `tests/parity/probes/`. Naming:

- `rN_*` route-bearing programs (router + server codegen)
- `cN_*` model / combined route+model programs
- `eN_*` intentional compile errors (diagnostics format parity)
- `trivial*` minimal `fn main` programs (non-route preamble parity)
- `stab2_probe` the full STAB-2 drift probe (routes + models + unions)

## Running (Windows)

```powershell
python scripts/verify_seed.py --bootstrap   # (re)builds stage1/2/3.exe
powershell -File tests/parity/run_parity.ps1
```

## Running (bash / CI)

```bash
python3 scripts/verify_seed.py --bootstrap
bash tests/parity/run_parity.sh
```

Exit code is 0 only when `25/25` probes are byte-identical (C or diagnostics).