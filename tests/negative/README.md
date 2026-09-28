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
| `// no-diagnostic:` | Optional, on a `known-defect:` case only, and **instead of** the two above. The program must still build and must still die without saying anything: non-zero exit, nothing on stdout or stderr. This is for the class where the wrong answer is a crash, which a `wrong-value:` cannot hold. |

A case may pin at most one of `wrong-value:`, `cc-rejects:` and
`no-diagnostic:` — they are three ways of saying what the program actually does,
and a header that claims two of them is describing a program nobody has.

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

`wrong-value:` deliberately pins nothing when the wrong answer is an address —
those move per run and per machine, and a pin that fires at random teaches
people to ignore it. A **crash** used to be in that position too and no longer
is: `no-diagnostic:` pins the observable instead of the number, so
`print((7) / 0)` is a ratchet that fires the day a diagnostic arrives (a
diagnostic is a message) and the day it starts printing one. It is
mechanism-neutral on purpose: a signal on POSIX, an exception status on Windows,
the same observable either way, so the case does not need a different pin per
runner. What is still unpinned is an address, and the header says so when that
is the case (`n33`).

## Where this fits: the division of labour

Two tools, and they are not interchangeable. Getting this wrong is how 99
programs that compile clean, run, and give the wrong answer sat in the repo as
fuzzer output for a whole wave.

| | what it asks | what it cannot see |
|---|---|---|
| `scripts/negative_gate.py` (this directory) | what the **compiler must reject**. Every program here must fail `orbit check`, with a pinned diagnostic. | a program that computes the wrong number. Just over half the cases here are programs the compiler wrongly *accepts*, so this gate's own verdict is often "still broken" — it holds the defect, it does not detect it. |
| `scripts/diff_fuzz.py` | what the **compiler computes**, against a reference implementation in Python with the same truncating semantics. | anything it has no case for. It generates integer arithmetic, integer literals, division by zero, string escapes and floats; it has never looked at a list, a map, a model or a control-flow edge. |
| `scripts/unknown_ratchet.py` | the static measure: what share of emitted instructions the front end typed `unknown`. | the behaviour. 75% of that can be right. |

The hole is the shape both of the other two leave: a **compile-only** gate cannot
see a wrong value, and a **crash-only** fuzzer cannot either, because a wrong
answer is not an event. `scripts/fuzz_frontend.py` looks for crashes; a crash
announces itself. `print(1.5)` returns 1 and nothing anywhere says a word. That
hole is where all 99 were, and it is not a gap in coverage so much as a gap in
*kind*: nothing in the battery had ever executed a program and compared the
value to anything.

So: a case belongs here when the defect is that the compiler **accepts** a
program, and it belongs in the fuzzer's corpus when the defect is that it
**computes** something else. Most of the cases here are the first kind and could
not be found by the second tool at all, because the fuzzer never asks whether a
program should have compiled.

## The fuzzer's findings, and where each one lives

`scripts/diff_fuzz.py` found 99 disagreements in 8 classes across 676 cases. Five
of those classes are bugs, and each has a case here. Three are **decisions**,
and they deliberately have none — the argument is below. The count is held one
way by `scripts/diff_fuzz_ratchet.py` against `scripts/baselines/diff_fuzz.json`
(75 disagreements, corpus sha `c68b57fa13ecb2d5`).

| fuzzer class | n | verdict | pin |
|---|---|---|---|
| `float/truncated-to-an-integer` | 43 | bug — nothing justifies it | `n40` (the literal half), `n35` (the transport half, core) |
| `div-zero/signal-instead-of-a-diagnostic` | 16 | bug — loud, but a diagnostic is owed | `n41_division_by_zero_is_not_a_diagnostic` |
| `int-literal/out-of-range-literal-is-accepted` | 9 | bug | `n29_int_literal_out_of_range` (pinned in wave 2) |
| `int-literal/unsupported-form-is-silently-wrong-in-a-binding` | 6 | bug — and the loud half is not the story | `n43_unsupported_literal_form_in_a_binding` |
| `string-escape/hex-zero-is-never-decoded` | 1 | bug — the documentation has already decided it | `n42_hex_escape_zero_is_never_decoded` |
| `string-escape/c-escape-is-kept-as-two-characters` | 17 | **decision** | asserted in the fuzzer's corpus |
| `string-escape/malformed-hex-escape-is-kept-literal` | 6 | **decision** | asserted in the fuzzer's corpus |
| `string-escape/unknown-escape-is-kept-literal` | 1 | **decision** | asserted in the fuzzer's corpus |

The float class is the one with two cases, and the reason is written into both
headers: a value that is already wrong before it reaches a call, and a transport
that loses the fraction on the way through one, are two mechanisms and fixing one
does not fix the other. Every other class is one mechanism, one case.

### Why the three escape classes are decisions and `\x00` is not

`docs/LANGUAGE_REFERENCE.md` says, in full: *"An ordinary string supports `\n`,
`\t`, `\r`, `\"`, `\\`, and the byte escape `\xHH` with two hex digits … Anything
malformed stays literal."* That is a total rule, and the three decision classes
are what it predicts:

- **`\a` is two characters** (17 cases). `\a` is not one of the six. C says BEL,
  and a reader who has just learned `\n` has every reason to expect the rest of
  the table. But "decode what C decodes" is not a smaller rule, it is a much
  larger one: C's set carries rules of its own — `\0` opens an octal escape, `\x`
  is greedy, `\e` is not standard at all — and every escape still outside it is a
  guess about what the author meant. Keeping what is not in the table needs no
  table of its own, which is why it is the safe default and not merely the
  convenient one.
- **`\x` and `\x4` and `\xZZ` stay literal** (6 cases). These *are* malformed
  instances of a supported escape, and the documentation says exactly what
  happens to those. The finding here was never the behaviour; it was that the
  fallback was invisible. It is written down now.
- **`\q` stays literal** (1 case). Same rule, and the one place the choice is
  least likeable: the author made a typo and the language cannot tell them. It
  still cannot, and a diagnostic is the only better answer, which is a change to
  the *escape set*, not a contradiction of the rule.

And `\x00` is a bug for a reason none of the above apply to: `00` is two hex
digits, so it is inside the rule the language documents, and the compiler does
not decode it. `unescapeStringBody` tests `hi * 16 + lo > 0`, which rejects the
value zero as though it were malformed. There is no reading of the documentation
under which `\x00` stays literal, so this is the implementation contradicting a
decision that has already been made — which is the whole difference between the
two kinds.

The practical consequence, and the reason the fuzzer was changed rather than the
findings filed: a tool that reports 17 permanent disagreements nobody will ever
fix trains people to ignore the tool, and the day it finds something real nobody
will read it. So the reference now implements the documented rule instead of
C's, which turns 24 "disagreements" into 24 **asserted agreements** — a stronger
pin than a note, because if the escape behaviour ever changes the count goes up
and the ratchet fires. Reversing the decision stays possible and stays
deliberate: edit the table in `scripts/diff_fuzz.py`, and the corpus sha moves
with it, so the baseline has to be re-written on purpose.

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
unknown census says 46% of what the front end cannot type reaches codegen with
no diagnostic at all, and those are `call` and `member` expressions, which is to
say: wrong answers, not crashes. If it does not build, `cc-rejects:` names the
C symbol or C type the emitter invented. If the wrong answer is a crash,
`no-diagnostic:` holds the death and fires when a message arrives. If the wrong
answer is an address, say so in the header instead of pinning a number that
moves.

**One case per class, not one per instance.** The differential fuzzer produced 99
disagreements in 8 classes. Forty-three of them are `print(1.5)` printing `1`;
forty-three files asserting that is a corpus nobody reads, and it is a corpus
that costs a build per file. A case pins the *mechanism* and names the width in
its header. Add a second case only when there is a second mechanism.

## What is in here today

37 cases: 20 are `expect-error:` — the program is rejected, with a pinned
diagnostic — and 17 are `known-defect:` ratchets. Of those 17, 9 also pin what
the program does: 6 a wrong value, 2 the C step's rejection, 1 that it dies
without a message. The split is not a balance to aim for: the priority list for
this corpus was the census's silent class, and a silent defect is by definition
one the compiler accepts.

A number in a document goes stale, which is F-0021 and it is why this section
exists at all. Recompute it rather than trust it:

```sh
python scripts/negative_gate.py --compiler <orbit> --list
```
