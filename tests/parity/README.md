# Parity / stability battery

The contract is stability against committed goldens: every probe built by the
fixed-point compiler must reproduce its recorded outcome exactly. No silent
drift.

| Probe exit | Golden records |
|---|---|
| `0` | SHA-256 of the generated C |
| `!= 0` | normalized compiler diagnostics (LF endings, forward slashes) |

Probes live in `tests/parity/probes/`, goldens in `tests/parity/golden/`.
Naming:

- `rN_*` route-bearing programs (router + server codegen)
- `cN_*` model / combined route+model programs
- `eN_*` intentional compile errors (diagnostics stability)
- `trivial*` minimal `fn main` programs (non-route preamble)
- `stab2_probe` the full STAB-2 drift probe (routes + models + unions)

The goldens were seeded from the original validated state, so the historical
cross-lineage assurance carries over.

## Running

```sh
# Emit the fixed-point compiler from the committed canonical C.
python scripts/build_selfhost.py --cc "$CC" --check-stale
python scripts/verify_seed.py --cc "$CC" --emit-fixed-point /tmp/orbit_fp

# Compare against goldens (CI gate).
python scripts/parity_selfhost.py --cc "$CC" --compiler /tmp/orbit_fp
```

Exit code is `0` only when all 32 probes match their goldens.

## After an intentional compiler change

```sh
python scripts/parity_selfhost.py --cc "$CC" --compiler /tmp/orbit_fp --update
```

Review the golden diff, then commit goldens together with the compiler change
(the same change must also refresh `compiler/selfhost/stage3.exe.c` via
`build_selfhost.py --promote`).
