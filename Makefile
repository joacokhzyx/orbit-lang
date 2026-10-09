# One entry point for the Orbit developer loop.
#
# Every target is a thin call into scripts/dev.py. That is deliberate: a target
# that carried logic of its own would be logic with two copies, and the flow is
# already specified twice in this repository -- once in prose in ENGINEERING.md
# section 8, once as inline steps in .github/workflows/ci-gate.yml -- which is
# how those two came to disagree about what "clean" means.
#
# Windows runners do not have make, so CI calls scripts/dev.py directly. This
# file is for people, and for the muscle memory of typing one word.

PY ?= python3
DEV = $(PY) scripts/dev.py
CC ?= gcc

.PHONY: dev check all fp fp-path promote promote-diff report list fmt doctor suite parity werror negative help

## dev:     gates proportionate to what the working tree touched (T0+T1 default)
dev:
	$(DEV) dev

## check:   the language and static-analysis gates, unconditionally (T0..T2)
check:
	$(DEV) check

## all:     everything this script drives, including the root of trust (T0..T3)
all:
	$(DEV) all

## fp:      build the fixed-point compiler and print its path and version
fp:
	$(DEV) fp

## fp-path: print the fixed-point compiler's path, building it if needed
fp-path:
	@$(DEV) fp-path

## promote: replace the committed canonical and PUBLISHED_C (the only way to)
promote:
	$(DEV) promote

## promote-diff: what the canonical actually did, with register renumbering flattened
promote-diff:
	$(DEV) promote-diff

## report:  the CI report-only measurements (census, diff-fuzz, routes probe)
report:
	$(DEV) report

## list:    show what dev would run, without running it
list:
	$(DEV) list

## fmt:     format the compiler sources and the test suite in place
fmt:
	$(DEV) fp >/dev/null && "$$($(DEV) fp-path)" fmt compiler && "$$($(DEV) fp-path)" fmt tests/suite

# Single gates, for when one thing is broken and the rest is noise.
doctor:
	$(PY) scripts/doctor_gate.py --compiler $(shell $(DEV) fp-path)
suite:
	$(PY) scripts/test_suite.py --cc $(CC) --compiler $(shell $(DEV) fp-path)
parity:
	$(PY) scripts/parity_selfhost.py --cc $(CC) --compiler $(shell $(DEV) fp-path)
werror:
	$(PY) scripts/werror_gate.py --cc $(CC) --compiler $(shell $(DEV) fp-path)
negative:
	$(PY) scripts/negative_gate.py --cc $(CC) --compiler $(shell $(DEV) fp-path)

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'