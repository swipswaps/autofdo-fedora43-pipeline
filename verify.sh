#!/usr/bin/env bash
# =============================================================================
# verify.sh
# AutoFDO pipeline – post-run performance report generator
#
# Reads per-step log files written by autofdo_full_capture.sh and produces
# a structured comparison of:
#   • Binary sizes at each pipeline stage
#   • BOLT transformation statistics (BOLT-INFO / BOLT-WARNING lines)
#   • perf stat counters: PGO baseline vs BOLT-optimised binary
#   • Derived delta table with signed percentages and IPC
#
# perf stat is invoked with -d (detailed), which adds L1-icache-load-misses
# and iTLB-load-misses to the default counter set.  The pipeline (step 8)
# must also use -d for these fields to be present in the log.
#
# Usage:
#   bash verify.sh
#   LOG_DIR=/path/to/logs bash verify.sh
#
# Exit codes:
#   0 – report generated successfully
#   1 – required log files missing or clearly malformed
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
# TERMINAL COLOURS  (suppressed when not a tty)
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'
    DIM=$'\e[2m'
    GREEN=$'\e[32m'
    CYAN=$'\e[36m'
    YELLOW=$'\e[33m'
    RED=$'\e[31m'
    RESET=$'\e[0m'
else
    BOLD='' DIM='' GREEN='' CYAN='' YELLOW='' RED='' RESET=''
fi

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

section() {
    printf '\n%s%s=== %s ===%s\n' "${BOLD}" "${CYAN}" "$*" "${RESET}"
}

row() {
    printf '  %-40s %s\n' "$1" "$2"
}

warn() {
    printf '%s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$*" >&2
}

die() {
    printf '%s[ERROR]%s %s\n' "${RED}" "${RESET}" "$*" >&2
    exit 1
}

require_file() {
    if [[ ! -f "$1" ]] || [[ ! -s "$1" ]]; then
        die "Required log file missing or empty: $1"
    fi
}

file_size_human() {
    [[ -f "$1" ]] || { echo "(not found)"; return; }
    local b
    b=$(stat --format='%s' "$1" 2>/dev/null || echo 0)
    if   (( b < 1024 ));    then printf '%d B'   "${b}"
    elif (( b < 1048576 )); then printf '%d KiB' "$(( b / 1024 ))"
    else                         printf '%d MiB' "$(( b / 1048576 ))"
    fi
}

percent_delta() {
    awk -v b="$1" -v o="$2" 'BEGIN {
        if (b == 0) { print "n/a"; exit }
        pct = (o - b) / b * 100.0
        sign = (pct >= 0) ? "+" : ""
        printf "%s%.1f %%", sign, pct
    }'
}

# extract_perf_counter <logfile> <event-keyword>
# Extracts the numeric count from a 'perf stat -d' human-readable stderr log.
#
# perf stat human output format (one event per line):
#   "     1,234,567      cycles:u        #  3.45 GHz"
# The first non-blank field is the count; may contain comma separators.
# We match on lines containing the keyword that also begin with a digit.
# Returns "0" if not found.
extract_perf_counter() {
    local logfile="$1"
    local keyword="$2"
    awk -v kw="${keyword}" '
        /^[[:space:]]*[0-9]/ && $0 ~ kw {
            gsub(/,/, "", $1)
            if ($1 ~ /^[0-9]+(\.[0-9]+)?$/) { print $1; exit }
        }
    ' "${logfile}" 2>/dev/null || echo "0"
}

# extract_perf_time <logfile>
# Extracts elapsed wall-clock seconds from the perf stat summary line.
# With --repeat N, the value on the summary line is the mean.
extract_perf_time() {
    awk '/seconds time elapsed/ {
        gsub(/,/, "", $1)
        if ($1 ~ /^[0-9]+(\.[0-9]+)?$/) { print $1; exit }
    }' "$1" 2>/dev/null || echo "0"
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

printf '\n%s%sAutoFDO Pipeline – Verification Report%s\n' \
    "${BOLD}" "${GREEN}" "${RESET}"
printf '%sGenerated : %s%s\n' "${DIM}" "$(date)" "${RESET}"
printf '%sLOG_DIR   : %s%s\n' "${DIM}" "${LOG_DIR}" "${RESET}"
printf '%sWORKDIR   : %s%s\n' "${DIM}" "${WORKDIR}" "${RESET}"

# ---------------------------------------------------------------------------
# SECTION 1: Binary sizes
# ---------------------------------------------------------------------------
section "Binary Sizes"
row "Instrumented (.instr):"  "$(file_size_human "${BINARY_INSTR}")"
row "PGO-optimised (.pgo):"   "$(file_size_human "${BINARY_PGO}")"
row "BOLT-optimised (.bolt):" "$(file_size_human "${BINARY_BOLT}")"

# ---------------------------------------------------------------------------
# SECTION 2: BOLT transformation statistics
# ---------------------------------------------------------------------------
section "BOLT Transformation Statistics"

bolt_info_count=$(grep -c 'BOLT-INFO'              "${LOG_BOLT_STDERR}" 2>/dev/null || echo 0)
bolt_warn_count=$(grep -c 'BOLT-WARNING\|BOLT-WARN' "${LOG_BOLT_STDERR}" 2>/dev/null || echo 0)

printf '  BOLT-INFO lines   : %s\n' "${bolt_info_count}"
printf '  BOLT-WARNING lines: %s\n' "${bolt_warn_count}"

if (( bolt_warn_count > 0 )); then
    warn "BOLT warnings present — inspect ${LOG_BOLT_STDERR}"
    grep 'BOLT-WARNING\|BOLT-WARN' "${LOG_BOLT_STDERR}" | head -5 | sed 's/^/    /'
fi

echo
echo "  Layout / transform entries:"
grep 'BOLT-INFO' "${LOG_BOLT_STDERR}" \
    | grep -E 'layout|fold|ICF|save|reorder|function|block|relocation|enabling|mode' \
    | sed 's/^/    /' \
    || echo "    (none matched — check ${LOG_BOLT_STDERR})"

# ---------------------------------------------------------------------------
# SECTION 3: perf stat raw counters
# ---------------------------------------------------------------------------
section "perf stat – Raw Counters  (perf stat -d --repeat 5)"
printf '  %s(L1-icache and iTLB counters require -d in step 8)%s\n' "${DIM}" "${RESET}"

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

_hfmt='  %-28s %22s  %22s\n'
printf "${_hfmt}" "Counter"          "PGO baseline"  "BOLT optimised"
printf "${_hfmt}" "-------"          "------------"  "--------------"
printf "${_hfmt}" "CPU cycles"       "${B_CYC}"      "${O_CYC}"
printf "${_hfmt}" "Instructions"     "${B_INS}"      "${O_INS}"
printf "${_hfmt}" "Branch misses"    "${B_BRM}"      "${O_BRM}"
printf "${_hfmt}" "L1-icache misses" "${B_ICM}"      "${O_ICM}"
printf "${_hfmt}" "iTLB misses"      "${B_ITL}"      "${O_ITL}"
printf "${_hfmt}" "LLC-load misses"  "${B_LLC}"      "${O_LLC}"
printf "${_hfmt}" "Elapsed time (s)" "${B_SEC}"      "${O_SEC}"

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

_dfmt='  %-28s %12s   %s\n'
printf "${_dfmt}" "Metric"           "Delta"    "Interpretation"
printf "${_dfmt}" "------"           "-----"    "--------------"
printf "${_dfmt}" "CPU cycles"       "${D_CYC}" "negative = fewer cycles = faster"
printf "${_dfmt}" "Instructions"     "${D_INS}" "small change expected"
printf "${_dfmt}" "Branch misses"    "${D_BRM}" "negative = better prediction"
printf "${_dfmt}" "L1-icache misses" "${D_ICM}" "negative = better i-cache layout"
printf "${_dfmt}" "iTLB misses"      "${D_ITL}" "negative = tighter code footprint"
printf "${_dfmt}" "LLC-load misses"  "${D_LLC}" "negative = less memory traffic"
printf "${_dfmt}" "Elapsed time"     "${D_SEC}" "negative = faster wall-clock"
printf '\n'
printf '  %-28s %12s   %12s\n' "IPC (instructions/cycle)" "${IPC_B}" "${IPC_O}"

# ---------------------------------------------------------------------------
# SECTION 5: Data-quality warnings
# ---------------------------------------------------------------------------
section "Data Quality Checks"

_any_warn=0

if [[ "${B_CYC}" == "0" ]] || [[ "${O_CYC}" == "0" ]]; then
    warn "CPU cycle counts are 0."
    warn "  sudo sysctl -w kernel.perf_event_paranoid=1  then re-run the pipeline."
    _any_warn=1
fi

if [[ "${B_ICM}" == "0" ]] || [[ "${O_ICM}" == "0" ]]; then
    warn "L1-icache-load-misses are 0."
    warn "  Requires perf stat -d in step 8.  autofdo_full_capture.sh already uses it."
    warn "  On some CPUs: perf list cache  to find the exact event name."
    _any_warn=1
fi

if [[ "${B_ITL}" == "0" ]] || [[ "${O_ITL}" == "0" ]]; then
    warn "iTLB-load-misses are 0 — same root cause as L1-icache above."
    _any_warn=1
fi

if [[ "${B_SEC}" == "0" ]] || [[ "${O_SEC}" == "0" ]]; then
    warn "Elapsed time is 0.  perf stat summary line not found."
    warn "  Check: grep 'time elapsed' ${LOG_STAT_BASE}"
    _any_warn=1
fi

bolt_reloc=$(grep -c 'BOLT-INFO: enabling relocation mode' \
    "${LOG_BOLT_STDERR}" 2>/dev/null || echo 0)
if [[ "${bolt_reloc}" == "0" ]]; then
    warn "BOLT did not run in relocation mode."
    warn "  Maximum gains require linking with -Wl,--emit-relocs."
    warn "  autofdo_full_capture.sh adds this flag; rebuild if it was missing."
    _any_warn=1
fi

if [[ "${_any_warn}" == "0" ]]; then
    printf '  %sAll data quality checks passed.%s\n' "${GREEN}" "${RESET}"
fi

# ---------------------------------------------------------------------------
# SECTION 6: Verdict
# ---------------------------------------------------------------------------
section "Verdict"

verdict=$(awk -v b="${B_SEC}" -v o="${O_SEC}" 'BEGIN {
    if (b == 0 || o == 0) {
        print "UNKNOWN — elapsed time data missing (see Data Quality section)"
        exit
    }
    pct = (o - b) / b * 100.0
    if      (pct < -1.0) printf "FASTER by %.1f%% wall-clock time\n",  -pct
    else if (pct >  1.0) printf "SLOWER by %.1f%% — check TROUBLESHOOTING.md (Failure 11)\n", pct
    else                 print  "NO SIGNIFICANT CHANGE (within +/-1%% — try PERF_RUNS=5)"
}')

printf '  BOLT-optimised binary is: %s%s%s\n' "${BOLD}" "${verdict}" "${RESET}"

printf '\n  Log files:\n'
printf '    BOLT diagnostics : %s\n' "${LOG_BOLT_STDERR}"
printf '    perf baseline    : %s\n' "${LOG_STAT_BASE}"
printf '    perf optimised   : %s\n' "${LOG_STAT_BOLT}"
printf '\n  Useful greps:\n'
printf '    grep BOLT-INFO %s\n'                "${LOG_BOLT_STDERR}"
printf '    grep "time elapsed" %s %s\n'        "${LOG_STAT_BASE}" "${LOG_STAT_BOLT}"
printf '    grep "branch-misses" %s %s\n'       "${LOG_STAT_BASE}" "${LOG_STAT_BOLT}"
printf '\n'
