#!/usr/bin/env bash
# Orbit selfhost/FE parity gate (W1). Byte-identity contract:
#   both exit 0   -> generated C must be byte-identical
#   both exit !=0 -> captured stderr must be byte-identical
#   any other combo -> FAIL
#
# Usage: bash tests/parity/run_parity.sh [probe_dir]
#   FE   = zig-out/bin/orbit.exe (Zig frontend)
#   SH   = compiler/selfhost/stage3.exe (self-hosted pipeline; must exist,
#          i.e. run `python scripts/verify_seed.py --bootstrap` first)
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROBE_DIR="${1:-$ROOT/tests/parity/probes}"
FE="$ROOT/zig-out/bin/orbit.exe"
SH="$ROOT/compiler/selfhost/stage3.exe"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$FE" ] || { echo "FE missing: $FE"; exit 2; }
[ -x "$SH" ] || { echo "SH missing: $SH (run verify_seed.py --bootstrap first)"; exit 2; }

total=0; c_ok=0; diag_ok=0; fail=0
declare -a bad=()

for probe in "$PROBE_DIR"/*.orb; do
    name="$(basename "$probe" .orb)"
    total=$((total + 1))

    mkdir -p "$WORK/fe" "$WORK/sh"
    fe_log="$WORK/$name.fe.log"; sh_log="$WORK/$name.sh.log"

    # FE
    TEMP="$WORK/fe" TMP="$WORK/fe" "$FE" build "$probe" -o "$WORK/$name.fe.exe" >"$fe_log" 2>&1
    fe_exit=$?
    if [ -f "$WORK/fe/orbit_selfhost_build.c" ]; then fe_c="$WORK/fe/orbit_selfhost_build.c"
    elif [ -f "$WORK/fe/orbit/temp_build.c" ]; then fe_c="$WORK/fe/orbit/temp_build.c"
    else fe_c=""; fi

    # SH
    TEMP="$WORK/sh" TMP="$WORK/sh" "$SH" "$probe" >"$sh_log" 2>&1
    sh_exit=$?
    if [ -f "$WORK/sh/orbit_selfhost_build.c" ]; then sh_c="$WORK/sh/orbit_selfhost_build.c"
    else sh_c=""; fi

    status=""
    if [ "$fe_exit" -eq 0 ] && [ "$sh_exit" -eq 0 ]; then
        if [ -n "$fe_c" ] && [ -n "$sh_c" ] && cmp -s "$fe_c" "$sh_c"; then
            c_ok=$((c_ok + 1)); status="C-IDENTICAL"
        else
            fail=$((fail + 1)); status="C-DIFF"; bad+=("$name")
        fi
    elif [ "$fe_exit" -ne 0 ] && [ "$sh_exit" -ne 0 ]; then
        if cmp -s "$fe_log" "$sh_log"; then
            diag_ok=$((diag_ok + 1)); status="DIAG-IDENTICAL"
        else
            fail=$((fail + 1)); status="DIAG-DIFF"; bad+=("$name")
        fi
    else
        fail=$((fail + 1)); status="EXIT-MISMATCH(fe=$fe_exit sh=$sh_exit)"; bad+=("$name")
    fi
    printf "%-24s %s\n" "$name" "$status"
done

echo "RESULT: $((c_ok + diag_ok))/$total identical (C=$c_ok diag=$diag_ok fail=$fail)"
if [ "$fail" -ne 0 ]; then
    printf 'FAILED: %s\n' "${bad[*]}"
    exit 1
fi
exit 0