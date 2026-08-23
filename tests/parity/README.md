# Parity / stability battery (W1 → W2)

Originally the W1 battery proved **byte-identity between the two compiler
lineages** (Zig FE vs self-host) across 25 probes. With the Zig seed retired
(SOVER-1) the contract became a **stability contract against committed goldens**
(W2): every probe compiled by the fixed-point self-host compiler must reproduce
its recorded outcome exactly.

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

The goldens were seeded from the W1-validated 25/25 state, so the historical
cross-lineage assurance carries over.

## Running

```sh
# Emit the fixed-point compiler from the committed canonical C.
python scripts/build_selfhost.py --cc "$CC" --check-stale
python scripts/verify_seed.py --cc "$CC" --emit-fixed-point /tmp/orbit_fp

# Compare against goldens (CI gate).
python scripts/parity_selfhost.py --cc "$CC" --compiler /tmp/orbit_fp
```

Exit code is `0` only when `25/25` probes match their goldens.

## After an intentional compiler change

```sh
python scripts/parity_selfhost.py --cc "$CC" --compiler /tmp/orbit_fp --update
```

Review the golden diff, then commit goldens together with the compiler change
(the same change must also refresh `compiler/selfhost/stage3.exe.c` via
`build_selfhost.py --promote`).
