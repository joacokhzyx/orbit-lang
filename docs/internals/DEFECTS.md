# Defect and finding index

## F-code index

Findings are stable identifiers for defect classes. Each points at the
negative case header that owns it — the header's `// what:` comment is the
full write-up.

| finding | owns it | state |
|---|---|---|
| F-0001 — match over a union missing a variant falls through silently | `n01_union_missing_arm.orb` | fixed, pinned |
| F-0002 — lists had no element type; reads dereferenced the wrong type | `list_mixed_element_kinds.orb`, boundary half in `n39` | fixed, including the `list`-parameter boundary (F-0009): helpers spell `list<T>` and each call site compiles its own proven instance |
| F-0004 — calling an undeclared extern reached the C step as a call to a symbol nothing declares | `n22_undeclared_function_call.orb` | fixed, pinned |
| F-0009 — a `list` parameter with no element type: reads inside the helper are untyped and crash | `n39_list_parameter_has_no_element_type.orb` (now the generic form, refusing the incoherent call) | fixed (generic functions: `n39` pins the coherence refusal; `generic_functions.orb` + `std_lists_generic.orb` prove the sound spelling; a bare `list` stays lenient for dynamic values, the way `unknown` is) |
| F-0011 — capitalised/unknown type names accepted at the annotation, diagnosed late or misleadingly | `n30_capitalised_type_annotation.orb`, `n34_capitalised_type_parameter.orb` | fixed (E1006), pinned |
| F-0015 — parameter types recorded but never compared at call sites | `n33_call_argument_type_unchecked.orb` | fixed (E1005), pinned |
| F-0016 — `.at()` past the end answered 0 (the NUL byte) with no diagnostic | `n32_at_out_of_range.orb` | fixed (E1002), pinned |
| F-0018 — frontend member/call expressions with no type rule reached codegen silently | no negative case (frontend-only; E2004/E2005) | fixed in lowering |
| F-0021 — numbers in documents go stale | counts in `tests/negative/README.md` and siblings; recompute with `python scripts/corpus_gates.py negative --compiler <orbit> --list` | process note, not a defect |
| F-0023 — literal-zero division is SIGFPE, not a diagnostic | `n41_division_by_zero_is_not_a_diagnostic.orb` | fixed for literal divisors (E1004); a variable divisor is a checked trap (exit 2) |
| F-0024 — `for` over a never-set dynamic field miscompiles (read answers `""`, loop walks it as a list: garbage `.len()`, segfault iteration) | `n59_for_over_unknown_field.orb` | fixed (model-field reads answer declared types, and unprovable iterables are check errors) |
| F-0025 - assignment target is never checked: a `val` store, a type mismatch, and an undeclared name all pass `check` | `n90_val_reassignment.orb`, `n91_assignment_type_mismatch.orb`, `n92_assignment_target_undeclared.orb` | fixed (E1009), pinned |
