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

.PHONY: dev check static all fp fp-path promote promote-diff report list fmt doctor suite parity werror negative help

## dev:     gates proportionate to what the working tree touched (T0+T1 default)
dev:
	$(DEV) dev

## check:   the language and static-analysis gates, unconditionally (T0..T2)
check:
	$(DEV) check

## static:  fmt plus the five static gates; the tier a docs or scripts change needs
static:
	$(DEV) static

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

## fmt:     format the files the fmt gate would fail (compiler, tests, std)
fmt:
	$(DEV) fmt

# Single gates, for when one thing is broken and the rest is noise.
#
# Each asks dev.py for the gate by label instead of rebuilding its command
# line. Five of them used to spell the argv out again and call fp-path once per
# recipe -- a Python subprocess per target just to print a path the runner
# already knows. A filter that equals a label selects that one gate, which is
# why this says doctor_gate and not doctor: `doctor` would also match
# doctor_scope.
#
# The compiler path is quoted: it is built by `$(shell ...)`, and unquoted, sh
# eats the backslash in a Windows path (`C:\Temp\x.exe` becomes `C:Tempx.exe`,
# which Windows then resolves against the current directory). Double quotes
# preserve it, and they cover a temp directory with spaces on any platform.
doctor:
	$(DEV) all --filter doctor_gate
suite:
	$(DEV) all --filter suite
parity:
	$(DEV) all --filter parity
werror:
	$(DEV) all --filter werror
negative:
	$(DEV) all --filter negative

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'