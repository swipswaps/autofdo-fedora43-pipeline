#!/usr/bin/env bash
# =============================================================================
# verify.sh
# AutoFDO pipeline – post-run performance report
#
# Parses log files from autofdo_full_capture.sh and produces a structured
# before/after comparison: binary sizes, BOLT transformation stats, perf
# counter deltas, IPC, and a verdict.
#
# Usage:
#   bash verify.sh
#   LOG_DIR=/path/to/logs bash verify.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-./autofdo_logs}"
WORKDIR="${WORKDIR:-./autofdo_workdir}"
APP_NAME="${APP_NAME:-my_app}"

BINARY_INSTR="${WORKDIR}/${APP_NAME}.instr"
BINARY_PGO="${WORKDIR}/${APP_NAME}.pgo"
BINARY_BOLT="${WORKDIR}/${APP_NAME}.bolt"

LOG_BOLT_STDERR="${LOG_DIR}/step7_llvm_bolt.stderr"
LOG_STAT_BASE="${LOG_DIR}/step8_perf_stat_baseline.stderr"
LOG_STAT_BOLT="${LOG_DIR}/step8_perf_stat_bolt.stderr"

# ---------------------------------------------------------------------------
# COLOURS  (suppressed when not a tty)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; GREEN=$'\e[32m'
    CYAN=$'\e[36m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; RESET=$'\e[0m'
else
    BOLD=''; DIM=''; GREEN=''; CYAN=''; YELLOW=''; RED=''; RESET=''
fi

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
section() { printf '\n%s%s=== %s ===%s\n' "${BOLD}" "${CYAN}" "$1" "${RESET}"; }
warn()    { printf '%s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$1" >&2; }
die()     { printf '%s[ERROR]%s %s\n' "${RED}" "${RESET}" "$1" >&2; exit 1; }

require_file() {
    [[ -f "$1" && -s "$1" ]] || die "Required log file missing or empty: $1"
}

file_size_human() {
    [[ -f "$1" ]] || { printf '(not found)'; return; }
    local b
    b=$(stat --format='%s' "$1" 2>/dev/null || echo 0)
    if   (( b < 1024 ));    then printf '%d B'   "${b}"
    elif (( b < 1048576 )); then printf '%d KiB' "$(( b / 1024 ))"
    else                         printf '%d MiB' "$(( b / 1048576 ))"
    fi
}

percent_delta() {
    # $1 = baseline, $2 = optimised → signed percent string
    awk -v b="$1" -v o="$2" 'BEGIN {
        if (b == 0) { print "n/a"; exit }
        pct = (o - b) / b * 100.0
        printf "%s%.1f %%", (pct >= 0 ? "+" : ""), pct
    }'
}

# extract_perf_counter <logfile> <event-keyword>
# Parses a 'perf stat -d' human-readable stderr log.
# Format: "     1,234,567      event-name     # ..."
# Lines with a leading digit are data lines; comments begin with #.
# Strips thousand-separators from field 1 and returns the count.
extract_perf_counter() {
    awk -v kw="$2" '
        /^[[:space:]]*[0-9]/ && $0 ~ kw {
            gsub(/,/, "", $1)
            if ($1 ~ /^[0-9]+(\.[0-9]+)?$/) { print $1; exit }
        }
    ' "$1" 2>/dev/null || printf '0'
}

# extract_perf_time <logfile>
# "   0.123456789 seconds time elapsed"  → "0.123456789"
# With --repeat N this is the mean.
extract_perf_time() {
    awk '/seconds time elapsed/ {
        gsub(/,/, "", $1)
        if ($1 ~ /^[0-9]+(\.[0-9]+)?$/) { print $1; exit }
    }' "$1" 2>/dev/null || printf '0'
}

# ---------------------------------------------------------------------------
# PRE-FLIGHT
# ---------------------------------------------------------------------------
[[ -d "${LOG_DIR}" ]] || die "LOG_DIR does not exist: ${LOG_DIR}"
require_file "${LOG_BOLT_STDERR}"
require_file "${LOG_STAT_BASE}"
require_file "${LOG_STAT_BOLT}"

# ---------------------------------------------------------------------------
# HEADER
# ---------------------------------------------------------------------------
printf '\n%s%sAutoFDO Pipeline – Verification Report%s\n' "${BOLD}" "${GREEN}" "${RESET}"
printf '%sGenerated : %s%s\n' "${DIM}" "$(date)" "${RESET}"
printf '%sLOG_DIR   : %s%s\n' "${DIM}" "${LOG_DIR}" "${RESET}"
printf '%sWORKDIR   : %s%s\n' "${DIM}" "${WORKDIR}" "${RESET}"

# ---------------------------------------------------------------------------
# SECTION 1: Binary sizes
# ---------------------------------------------------------------------------
section "Binary Sizes"
printf '  %-40s %s\n' "Instrumented (.instr):"  "$(file_size_human "${BINARY_INSTR}")"
printf '  %-40s %s\n' "PGO-optimised (.pgo):"   "$(file_size_human "${BINARY_PGO}")"
printf '  %-40s %s\n' "BOLT-optimised (.bolt):" "$(file_size_human "${BINARY_BOLT}")"

# ---------------------------------------------------------------------------
# SECTION 2: BOLT transformation statistics
# ---------------------------------------------------------------------------
section "BOLT Transformation Statistics"
bolt_info_count=$(grep -c 'BOLT-INFO'              "${LOG_BOLT_STDERR}" 2>/dev/null || printf '0')
bolt_warn_count=$(grep -c 'BOLT-WARNING\|BOLT-WARN' "${LOG_BOLT_STDERR}" 2>/dev/null || printf '0')

printf '  BOLT-INFO lines   : %s\n' "${bolt_info_count}"
printf '  BOLT-WARNING lines: %s\n' "${bolt_warn_count}"

if (( bolt_warn_count > 0 )); then
    warn "BOLT warnings present — inspect ${LOG_BOLT_STDERR}"
    grep 'BOLT-WARNING\|BOLT-WARN' "${LOG_BOLT_STDERR}" | head -5 | sed 's/^/    /'
fi

printf '\n  Key layout/transform entries:\n'
grep 'BOLT-INFO' "${LOG_BOLT_STDERR}" \
    | grep -E 'layout|fold|ICF|save|reorder|function|block|relocation|enabling|mode' \
    | sed 's/^/    /' \
    || printf '    (none matched — check %s)\n' "${LOG_BOLT_STDERR}"

# ---------------------------------------------------------------------------
# SECTION 3: perf stat raw counters
# ---------------------------------------------------------------------------
section "perf stat – Raw Counters  (perf stat -d --repeat 5)"
printf '  %s(L1-icache / iTLB / LLC counters require -d flag in step 8)%s\n' \
    "${DIM}" "${RESET}"

B_CYC=$(extract_perf_counter "${LOG_STAT_BASE}" "cycles")
B_INS=$(extract_perf_counter "${LOG_STAT_BASE}" "instructions")
B_BRM=$(extract_perf_counter "${LOG_STAT_BASE}" "branch-misses")
B_ICM=$(extract_perf_counter "${LOG_STAT_BASE}" "L1-icache-load-misses")
B_ITL=$(extract_perf_counter "${LOG_STAT_BASE}" "iTLB-load-misses")
B_LLC=$(extract_perf_counter "${LOG_STAT_BASE}" "LLC-load-misses")
B_SEC=$(extract_perf_time    "${LOG_STAT_BASE}")

O_CYC=$(extract_perf_counter "${LOG_STAT_BOLT}" "cycles")
O_INS=$(extract_perf_counter "${LOG_STAT_BOLT}" "instructions")
O_BRM=$(extract_perf_counter "${LOG_STAT_BOLT}" "branch-misses")
O_ICM=$(extract_perf_counter "${LOG_STAT_BOLT}" "L1-icache-load-misses")
O_ITL=$(extract_perf_counter "${LOG_STAT_BOLT}" "iTLB-load-misses")
O_LLC=$(extract_perf_counter "${LOG_STAT_BOLT}" "LLC-load-misses")
O_SEC=$(extract_perf_time    "${LOG_STAT_BOLT}")

# Inline format strings avoid SC2059 (printf with variable format)
printf '  %-28s %22s  %22s\n' "Counter"          "PGO baseline"  "BOLT optimised"
printf '  %-28s %22s  %22s\n' "-------"          "------------"  "--------------"
printf '  %-28s %22s  %22s\n' "CPU cycles"       "${B_CYC}"      "${O_CYC}"
printf '  %-28s %22s  %22s\n' "Instructions"     "${B_INS}"      "${O_INS}"
printf '  %-28s %22s  %22s\n' "Branch misses"    "${B_BRM}"      "${O_BRM}"
printf '  %-28s %22s  %22s\n' "L1-icache misses" "${B_ICM}"      "${O_ICM}"
printf '  %-28s %22s  %22s\n' "iTLB misses"      "${B_ITL}"      "${O_ITL}"
printf '  %-28s %22s  %22s\n' "LLC-load misses"  "${B_LLC}"      "${O_LLC}"
printf '  %-28s %22s  %22s\n' "Elapsed time (s)" "${B_SEC}"      "${O_SEC}"

# ---------------------------------------------------------------------------
# SECTION 4: Delta table
# ---------------------------------------------------------------------------
section "Delta Table  (BOLT vs PGO baseline)"

D_CYC=$(percent_delta "${B_CYC}" "${O_CYC}")
D_INS=$(percent_delta "${B_INS}" "${O_INS}")
D_BRM=$(percent_delta "${B_BRM}" "${O_BRM}")
D_ICM=$(percent_delta "${B_ICM}" "${O_ICM}")
D_ITL=$(percent_delta "${B_ITL}" "${O_ITL}")
D_LLC=$(percent_delta "${B_LLC}" "${O_LLC}")
D_SEC=$(percent_delta "${B_SEC}" "${O_SEC}")

IPC_B=$(awk -v i="${B_INS}" -v c="${B_CYC}" \
    'BEGIN { if (c>0) printf "%.3f", i/c; else print "n/a" }')
IPC_O=$(awk -v i="${O_INS}" -v c="${O_CYC}" \
    'BEGIN { if (c>0) printf "%.3f", i/c; else print "n/a" }')

printf '  %-28s %12s   %s\n' "Metric"           "Delta"    "Interpretation"
printf '  %-28s %12s   %s\n' "------"           "-----"    "--------------"
printf '  %-28s %12s   %s\n' "CPU cycles"       "${D_CYC}" "negative = fewer cycles = faster"
printf '  %-28s %12s   %s\n' "Instructions"     "${D_INS}" "small change expected"
printf '  %-28s %12s   %s\n' "Branch misses"    "${D_BRM}" "negative = better prediction"
printf '  %-28s %12s   %s\n' "L1-icache misses" "${D_ICM}" "negative = better i-cache layout"
printf '  %-28s %12s   %s\n' "iTLB misses"      "${D_ITL}" "negative = tighter code footprint"
printf '  %-28s %12s   %s\n' "LLC-load misses"  "${D_LLC}" "negative = less memory traffic"
printf '  %-28s %12s   %s\n' "Elapsed time"     "${D_SEC}" "negative = faster wall-clock"
printf '\n'
printf '  %-28s %12s   %12s\n' "IPC (insns/cycle)" "${IPC_B}" "${IPC_O}"

# ---------------------------------------------------------------------------
# SECTION 5: Data-quality warnings
# ---------------------------------------------------------------------------
section "Data Quality Checks"
_warn_count=0

_dq_warn() { warn "$1"; (( _warn_count++ )) || true; }

[[ "${B_CYC}" == "0" || "${O_CYC}" == "0" ]] &&
    _dq_warn "CPU cycle counts are 0. Fix: sudo sysctl -w kernel.perf_event_paranoid=1"

[[ "${B_ICM}" == "0" || "${O_ICM}" == "0" ]] &&
    _dq_warn "L1-icache-load-misses are 0. Requires perf stat -d (step 8 uses it). Check: perf list cache"

[[ "${B_ITL}" == "0" || "${O_ITL}" == "0" ]] &&
    _dq_warn "iTLB-load-misses are 0 — same root cause as L1-icache above."

[[ "${B_SEC}" == "0" || "${O_SEC}" == "0" ]] &&
    _dq_warn "Elapsed time is 0. Check: grep 'time elapsed' ${LOG_STAT_BASE}"

bolt_reloc=$(grep -c 'BOLT-INFO: enabling relocation mode' \
    "${LOG_BOLT_STDERR}" 2>/dev/null || printf '0')
[[ "${bolt_reloc}" == "0" ]] &&
    _dq_warn "BOLT not in relocation mode. For max gains: link with -Wl,--emit-relocs (pipeline already does this; rebuild if missing)."

if (( _warn_count == 0 )); then
    printf '  %sAll data quality checks passed.%s\n' "${GREEN}" "${RESET}"
fi

# ---------------------------------------------------------------------------
# SECTION 6: Verdict
# ---------------------------------------------------------------------------
section "Verdict"
verdict=$(awk -v b="${B_SEC}" -v o="${O_SEC}" 'BEGIN {
    if (b == 0 || o == 0) {
        print "UNKNOWN — elapsed time missing (see Data Quality above)"; exit
    }
    pct = (o - b) / b * 100.0
    if      (pct < -1.0) printf "FASTER by %.1f%% wall-clock\n", -pct
    else if (pct >  1.0) printf "SLOWER by %.1f%% — see TROUBLESHOOTING.md Failure 11\n", pct
    else                 print  "NO SIGNIFICANT CHANGE (within +/-1%% — try PERF_RUNS=5)"
}')
printf '  BOLT-optimised binary is: %s%s%s\n' "${BOLD}" "${verdict}" "${RESET}"

printf '\n  Useful greps:\n'
printf '    grep BOLT-INFO %s\n'                       "${LOG_BOLT_STDERR}"
printf '    grep "time elapsed" %s %s\n'               "${LOG_STAT_BASE}" "${LOG_STAT_BOLT}"
printf '    grep "branch-misses" %s %s\n'              "${LOG_STAT_BASE}" "${LOG_STAT_BOLT}"
printf '    grep "L1-icache" %s %s\n\n'                "${LOG_STAT_BASE}" "${LOG_STAT_BOLT}"
