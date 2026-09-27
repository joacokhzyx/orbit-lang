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
| `// wrong-value: <stdout>` | Optional, on a `known-defect:` case only. The program is built and run, and its stdout must still be exactly this (`\n` separates lines). |
| `// cc-rejects: <substring>` | Optional, on a `known-defect:` case only. The front end must stay silent **and** the C toolchain must still reject the output with `<substring>`. |

## What a ratchet is, and what to do when one fires

A **ratchet** is a case that asserts a bug is *still there*. `known-defect:` is
the compiler-level one: the program must be one the language rejects and the
gate requires `orbit check` to keep accepting it, so the day the front end
learns the rule the gate goes red. `wrong-value:` and `cc-rejects:` ratchet the
other half, the part a user actually sees — the number the program computes, and
whether the C step still says no.

**It is not a waiver.** A waiver is a case marked "skip" or "known broken" that
stops asserting anything: the day the bug grows a second symptom, or the fix
regresses, nothing says so. A ratchet inverts the polarity. It fails *on the
fix*. That is the whole point: the alternative is a gate that is green both when
the defect is there and when somebody quietly removed half of it, which is a
gate that cannot tell you anything.

So when one fires, the failure is the good news, and the fix is bookkeeping, not
suppression:

1. Read the failure. It prints both the value the header wants and the value the
   program now gives, and whether the front end started rejecting it.
2. If the program now compiles clean, change `known-defect:` to `expect-error:`
   and put the **real new diagnostic** in the header. Never guess it — run
   `orbit check` and copy it.
3. If the wrong answer changed, decide which it is. It is the fix: delete the
   `wrong-value:` line and, if the case is now asserting correct behaviour,
   move the program to `tests/suite/` where a passing exit code is the
   expectation. It is a regression: that new number is the bug.
4. Never respond by loosening the header to match what the compiler does. A
   header edited to agree with a wrong answer is indistinguishable from a
   waiver, and it is the one move that makes the corpus worthless.

`wrong-value:` deliberately pins nothing when the wrong answer is an address or
a crash — those move per run and per machine, and a pin that fires at random
teaches people to ignore it. Those cases still assert the class (the front end
accepts the program) and say in the header what was measured.

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

**Then pin the answer, not just the acceptance.** A case that only records
"`orbit check` is clean" is a weak case: it cannot tell a wrong value from a
right one, which is the whole reason the corpus exists. If the program runs and
prints a number, that number belongs in the header as `wrong-value:` — the
unknown census says 46.6% of what the front end cannot type reaches codegen
with no diagnostic at all, and those are `call` and `member` expressions, which
is to say: wrong answers, not crashes. If it does not build, `cc-rejects:` names
the C symbol or C type the emitter invented. If the wrong answer is an address
or a crash, say so in the header instead of pinning a number that moves.

## What is in here today

34 cases. 15 are `expect-error:` — the program is rejected, with a pinned
diagnostic. 19 are `known-defect:` ratchets, and 7 of those additionally pin
what the program computes or what the C step says. The split is not a balance
to aim for: the priority list for this corpus was the census's silent class,
and a silent defect is by definition one the compiler accepts.
