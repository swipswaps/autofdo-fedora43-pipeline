#!/usr/bin/env bash
# =============================================================================
# tools/inspect_layout.sh
# Binary layout inspection: compare function ordering before and after BOLT
#
# The conversation proposed re-running llvm-bolt with -print-layout, which
# fails on BOLT-output binaries ("binary already BOLTed"). The correct
# approach is:
#
#   1. nm + sort: show function order by address (works on any ELF binary)
#   2. readelf -s: full symbol table with sizes
#   3. perf report: show which functions consumed the most CPU time
#      (requires the perf.data from step 5)
#
# Together these reveal exactly what BOLT reordered and why it improved
# instruction-cache locality.
#
# Usage:
#   bash tools/inspect_layout.sh <baseline_binary> <bolt_binary> [perf_data]
#
#   bash tools/inspect_layout.sh \
#       autofdo_workdir/my_app.pgo \
#       autofdo_workdir/my_app.bolt \
#       autofdo_workdir/perf.1.data
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
    printf 'Usage: %s <baseline> <bolt_binary> [perf_data]\n' "$0" >&2
    exit 1
fi

BASELINE="$1"
BOLT_BIN="$2"
PERF_DATA="${3:-}"

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
for _b in "${BASELINE}" "${BOLT_BIN}"; do
    [[ -f "${_b}" ]] || { printf 'ERROR: not found: %s\n' "${_b}" >&2; exit 1; }
done

command -v nm      &>/dev/null || { printf 'ERROR: nm not found. sudo dnf install binutils\n' >&2; exit 1; }
command -v readelf &>/dev/null || { printf 'ERROR: readelf not found. sudo dnf install binutils\n' >&2; exit 1; }

# ---------------------------------------------------------------------------
# SECTION 1: Function order by address
# ---------------------------------------------------------------------------
# nm -n sorts symbols by address (ascending), showing the physical layout
# order in the text segment.  Filtering to 'T' (text/code) symbols excludes
# data and undefined symbols.
# For the BOLT binary, cold-split functions appear as <name>.cold — these
# should appear far from their hot counterparts, confirming hot/cold splitting.

_print_layout() {
    local binary="$1"
    local label="$2"
    printf '\n=== %s: Function layout (by address) ===\n' "${label}"
    nm -n --defined-only "${binary}" 2>/dev/null \
        | awk '$2 == "T" || $2 == "t" { printf "  0x%s  %s\n", $1, $3 }' \
        | head -60
    local total
    total=$(nm --defined-only "${binary}" 2>/dev/null \
        | awk '$2 == "T" || $2 == "t"' | wc -l)
    printf '  ... (%d text symbols total; showing first 60)\n' "${total}"
}

_print_layout "${BASELINE}" "PGO baseline"
_print_layout "${BOLT_BIN}" "BOLT optimised"

# ---------------------------------------------------------------------------
# SECTION 2: Largest functions by size
# ---------------------------------------------------------------------------
# readelf -s shows symbol size in bytes.  Large functions that shrank after
# BOLT indicate dead-code folding (ICF); functions that grew indicate inlining.

_print_top_functions() {
    local binary="$1"
    local label="$2"
    printf '\n=== %s: Top 20 functions by size ===\n' "${label}"
    readelf -s "${binary}" 2>/dev/null \
        | awk '$4 == "FUNC" && $5 == "GLOBAL" { print $3, $8 }' \
        | sort -rn \
        | head -20 \
        | awk '{ printf "  %8s bytes  %s\n", $1, $2 }'
}

_print_top_functions "${BASELINE}" "PGO baseline"
_print_top_functions "${BOLT_BIN}" "BOLT optimised"

# ---------------------------------------------------------------------------
# SECTION 3: Hot/cold split verification
# ---------------------------------------------------------------------------
# After BOLT with -split-functions, cold blocks are renamed <func>.cold.
# Counting these confirms BOLT actually split functions.

printf '\n=== BOLT: Hot/cold split verification ===\n'
cold_count=$(nm --defined-only "${BOLT_BIN}" 2>/dev/null \
    | awk '$2 == "T" || $2 == "t"' \
    | grep -c '\.cold' || printf '0')
hot_count=$(nm --defined-only "${BOLT_BIN}" 2>/dev/null \
    | awk '$2 == "T" || $2 == "t"' \
    | grep -vc '\.cold' || printf '0')

printf '  Hot functions  : %s\n' "${hot_count}"
printf '  Cold fragments : %s\n' "${cold_count}"

if (( cold_count == 0 )); then
    printf '  NOTE: 0 cold fragments — BOLT may not have run in split mode,\n'
    printf '        or the binary had insufficient profile coverage.\n'
fi

# ---------------------------------------------------------------------------
# SECTION 4: BOLT metadata verification
# ---------------------------------------------------------------------------
# A BOLTed binary contains .note.bolt_info and .bolt.org.eh_frame sections.
# Verifying these confirms the binary was actually processed by BOLT.

printf '\n=== BOLT: Section metadata ===\n'
readelf -S "${BOLT_BIN}" 2>/dev/null \
    | grep -iE 'bolt|\.note' \
    | sed 's/^/  /' \
    || printf '  (no BOLT sections found — binary may not be BOLTed)\n'

# ---------------------------------------------------------------------------
# SECTION 5: perf report (optional, requires perf.data)
# ---------------------------------------------------------------------------
# Shows which functions were hottest during the profiling run that BOLT used.
# Comparing hot functions vs their new layout addresses shows the effect.

if [[ -n "${PERF_DATA}" ]]; then
    if [[ ! -f "${PERF_DATA}" ]]; then
        printf '\n[inspect] WARNING: perf data not found: %s\n' "${PERF_DATA}" >&2
    elif ! command -v perf &>/dev/null; then
        printf '\n[inspect] WARNING: perf not found; skipping perf report\n' >&2
    else
        printf '\n=== perf report: Top 20 hot functions (from %s) ===\n' \
            "${PERF_DATA}"
        perf report \
            --input="${PERF_DATA}" \
            --stdio \
            --no-children \
            --sort=symbol \
            2>/dev/null \
            | grep -v '^#' \
            | head -25 \
            | sed 's/^/  /'
    fi
fi

printf '\n=== Layout inspection complete ===\n'
printf '  Baseline : %s\n' "${BASELINE}"
printf '  BOLT     : %s\n' "${BOLT_BIN}"
[[ -n "${PERF_DATA}" ]] && printf '  perf data: %s\n' "${PERF_DATA}"
