#!/usr/bin/env sh
# build_seed.sh - Build the C bootstrap seed (Phase S1, SOVER-0).
#
#   dist/orbit_bootstrap.c  self-contained C source (compiler + runtime)
#   dist/orbit_seed         the resulting bootstrap compiler
#
# Compiler detection order:
#   1. $ORBIT_CC  environment override (e.g. export ORBIT_CC=gcc)
#   2. gcc
#   3. clang
#   4. cc
#   5. zig cc  (bundled clang)
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SEED_SRC="$ROOT/dist/orbit_bootstrap.c"
SEED_OUT="$ROOT/dist/orbit_seed"

if [ ! -f "$SEED_SRC" ]; then
  echo "[seed] dist/orbit_bootstrap.c not found; running amalgamation..."
  if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
    echo "error: python is required to regenerate the amalgamation." >&2
    exit 1
  fi
  PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
  "$PY" "$ROOT/scripts/amalgamate.py"
fi

CC=""
if [ -n "$ORBIT_CC" ]; then
  CC="$ORBIT_CC"
elif command -v gcc >/dev/null 2>&1; then
  CC=gcc
elif command -v clang >/dev/null 2>&1; then
  CC=clang
elif command -v cc >/dev/null 2>&1; then
  CC=cc
elif command -v zig >/dev/null 2>&1; then
  CC="zig cc"
fi

if [ -z "$CC" ]; then
  echo "error: no C compiler found. Install gcc/clang or set ORBIT_CC." >&2
  exit 1
fi

echo "[seed] compiler: $CC"
$CC -O2 -w -Wno-int-conversion -Wno-incompatible-pointer-types -o "$SEED_OUT" "$SEED_SRC"
echo "[seed] built: $SEED_OUT"