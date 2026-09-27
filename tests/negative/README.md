# Negative compilation corpus

Every program in this directory **must fail** `orbit check`. They are the
negative half of the test battery, and until now they did not exist: the repo
had 32 parity probes, five of which recorded parse diagnostics, and **not one
test asserting a type error**. That is why three audit rounds in a row found
defects every gate passed — a `union` match missing a variant, `.at()` on a
list of ints, `print(undeclaredThing)`. All of those compile clean.

Run it:

```sh
python scripts/negative_gate.py --compiler /tmp/orbit_fp
```

## Header directives

Each file declares exactly one, in a header comment.

| directive | meaning |
|---|---|
| `// expect-error: <substring>` | `orbit check` must exit non-zero **and** the diagnostic must contain `<substring>`. |
| `// known-defect: <ref>` | The program must be rejected and today is not. The gate asserts the **bug is still present**: `orbit check` must still exit zero. |

`known-defect` is a ratchet, not a waiver. The summary line prints how many are
outstanding, and the day the compiler starts rejecting one the gate fails and
tells you to swap in `expect-error:` with the real diagnostic. Nothing improves
silently in either direction.

## Why the substring is asserted

A gate that only checks "exit non-zero" cannot tell a rejection from a crash,
and it absorbs every diagnostic rewording. Asserting the text means a better
error message fails the gate until the header is updated — which is the point.
A diagnostic nobody reads is a diagnostic nobody pinned.

## Naming

`nNN_snake_case.orb`, matching `tests/parity/probes`. The number is stable so a
case can be cited; the name after the underscore is what the gate prints.

## Adding a case

Write the smallest program that exhibits the defect. If `orbit check` accepts
it, it is a `known-defect` case and it needs a reference — a `FINDINGS.md` id if
one exists, otherwise the name of the check that is missing. If `orbit check`
rejects it, put the real diagnostic substring in the header. Do not invent a
diagnostic: a case that cannot pass because the compiler is wrong is a finding,
and the honest thing to do is file it and pin the current behaviour.
