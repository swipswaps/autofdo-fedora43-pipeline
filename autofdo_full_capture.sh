#!/usr/bin/env bash
# =============================================================================
# autofdo_full_capture.sh
# Fedora 43 – Full-visibility AutoFDO-style profile-guided optimization
#
# Pipeline:
#   1. Clang instrumentation PGO build  (-fprofile-instr-generate)
#   2. Workload profiling run           (collects default-%p.profraw)
#   3. Instrumentation PGO merge        (llvm-profdata merge)
#   4. PGO-guided rebuild               (-fprofile-instr-use, -Wl,--emit-relocs)
#   5. perf LBR sampling                (perf record -j any,u; auto-falls back)
#   6. BOLT profile conversion          (perf2bolt per run, merge-fdata)
#   7. BOLT post-link optimization      (llvm-bolt, ext-tsp, cdsort)
#   8. Validation                       (perf stat -d --repeat 5, both binaries)
#
# Every stdout and stderr stream is tee'd to per-step log files AND the
# terminal so no diagnostic, warning, or hidden message is ever lost.
#
# Prerequisites (Fedora 43):
#   sudo dnf install clang llvm llvm-bolt perf
#
# Usage:
#   chmod +x autofdo_full_capture.sh
#   SRC_DIR=/path/to/src APP_NAME=myapp ./autofdo_full_capture.sh
#
# All tunables are documented in the CONFIGURATION section.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# LOGGING  – all output to stderr; timestamp prefix makes logs grep-parseable
# ---------------------------------------------------------------------------
log_info()  { printf '[INFO  %(%T)T] %s\n' -1 "$*" >&2; }
log_warn()  { printf '[WARN  %(%T)T] %s\n' -1 "$*" >&2; }
log_error() { printf '[ERROR %(%T)T] %s\n' -1 "$*" >&2; }

# ---------------------------------------------------------------------------
# CONFIGURATION  (override via environment)
# ---------------------------------------------------------------------------
SRC_DIR="${SRC_DIR:-./src}"            # directory containing *.c sources
APP_NAME="${APP_NAME:-my_app}"         # output binary base name
WORKDIR="${WORKDIR:-./autofdo_workdir}"# PGO/BOLT artefacts; created if absent
LOG_DIR="${LOG_DIR:-./autofdo_logs}"   # per-step log files; never removed
PERF_RUNS="${PERF_RUNS:-3}"            # LBR sampling runs (more = richer profile)
PERF_FREQ="${PERF_FREQ:-2999}"         # sampling Hz (prime avoids aliasing)
OPT_LEVEL="${OPT_LEVEL:--O2}"          # clang -OX flag
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"       # appended to every clang invocation
# Set NO_SUDO_PERF=1 if perf_event_paranoid<=1; else pipeline uses sudo perf
NO_SUDO_PERF="${NO_SUDO_PERF:-0}"
# Set BOLT_NO_LBR=1 to force non-LBR fallback (VMs, containers, old CPUs)
BOLT_NO_LBR="${BOLT_NO_LBR:-0}"

# ---------------------------------------------------------------------------
# DERIVED PATHS
# ---------------------------------------------------------------------------
INSTR_BINARY="${WORKDIR}/${APP_NAME}.instr"
PGO_BINARY="${WORKDIR}/${APP_NAME}.pgo"
BOLT_BINARY="${WORKDIR}/${APP_NAME}.bolt"
PROFDATA="${WORKDIR}/default.profdata"
PERF_DATA_BASE="${WORKDIR}/perf"       # per-run: ${PERF_DATA_BASE}.N.data
PERF_FDATA_BASE="${WORKDIR}/perf"      # per-run: ${PERF_FDATA_BASE}.N.fdata
PERF_FDATA_FINAL="${WORKDIR}/perf.merged.fdata"

# ---------------------------------------------------------------------------
# GUARD: required tools
# ---------------------------------------------------------------------------
_check_tool() {
    command -v "$1" &>/dev/null && return
    log_error "Required tool not found: $1"
    log_error "  sudo dnf install $2"
    exit 1
}
_check_tool clang         clang
_check_tool llvm-profdata llvm
_check_tool llvm-bolt     llvm-bolt
_check_tool perf2bolt     llvm-bolt
_check_tool merge-fdata   llvm-bolt
_check_tool perf          perf

# ---------------------------------------------------------------------------
# GUARD: LBR hardware probe
# ---------------------------------------------------------------------------
# Run a zero-duration perf record; if the kernel rejects -j any,u then
# auto-enable the non-LBR fallback.  Uses a temp file rather than /dev/null
# because some kernel versions refuse /dev/null as a perf output path.
if [[ "${BOLT_NO_LBR}" != "1" ]]; then
    _lbr_probe_tmp=$(mktemp "${WORKDIR:-.}"/lbr-probe-XXXXXX 2>/dev/null \
                     || mktemp /tmp/lbr-probe-XXXXXX)
    _lbr_test_output=$(
        sudo perf record -e cycles:u -j any,u -o "${_lbr_probe_tmp}" -- true 2>&1
    ) || true
    rm -f "${_lbr_probe_tmp}"
    if echo "${_lbr_test_output}" | grep -qiE 'not supported|unsupported|Permission denied'; then
        log_warn "LBR branch sampling unavailable: ${_lbr_test_output}"
        log_warn "Setting BOLT_NO_LBR=1 (non-LBR fallback; reduced gains)."
        BOLT_NO_LBR=1
    fi
fi

# ---------------------------------------------------------------------------
# GUARD: source files
# ---------------------------------------------------------------------------
if [[ ! -d "${SRC_DIR}" ]]; then
    log_error "SRC_DIR does not exist: ${SRC_DIR}"
    log_error "  Run 'make' first to generate ${SRC_DIR}/workload.c"
    exit 1
fi

mapfile -d '' SRC_FILES < <(find "${SRC_DIR}" -maxdepth 1 -name '*.c' -print0)

if [[ ${#SRC_FILES[@]} -eq 0 ]]; then
    log_error "No *.c files found under ${SRC_DIR}"
    log_error "  Run 'make' to generate ${SRC_DIR}/workload.c"
    exit 1
fi
log_info "Source files: ${#SRC_FILES[@]} file(s) in ${SRC_DIR}"

# ---------------------------------------------------------------------------
# DIRECTORY SETUP
# ---------------------------------------------------------------------------
mkdir -p "${WORKDIR}"
mkdir -p "${LOG_DIR}"

# Remove stale profraw files so the instrumented binary starts fresh.
find "${WORKDIR}" -maxdepth 1 -name 'default-*.profraw' -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# EXIT TRAP  – preserves artefacts and logs; never deletes either
# ---------------------------------------------------------------------------
_on_exit() {
    local code=$?
    [[ ${code} -eq 0 ]] && return
    log_warn "Pipeline exited with status ${code}."
    log_warn "Artefacts: ${WORKDIR}"
    log_warn "Logs     : ${LOG_DIR}"
    log_warn "Run 'bash verify.sh' after resolving failures."
}
trap _on_exit EXIT

# ---------------------------------------------------------------------------
# run_logged <stem> <cmd> [args…]
# ---------------------------------------------------------------------------
# Runs <cmd>, tee-ing stdout → ${LOG_DIR}/${stem}.stdout and
# stderr → ${LOG_DIR}/${stem}.stderr while mirroring both to the terminal.
#
# Exit-code correctness:
#   The command runs in a backgrounded subshell so we capture its PID via $!.
#   'wait "${_pid}"' collects the subshell exit code.
#   A second bare 'wait' then drains the two async tee processes so log files
#   are fully flushed before the next step opens them.
run_logged() {
    local stem="$1"; shift
    local stdout_log="${LOG_DIR}/${stem}.stdout"
    local stderr_log="${LOG_DIR}/${stem}.stderr"
    log_info "CMD    : $*"
    log_info "STDOUT : ${stdout_log}"
    log_info "STDERR : ${stderr_log}"
    (
        "$@" \
            > >(tee -a "${stdout_log}") \
            2> >(tee -a "${stderr_log}" >&2)
    ) &
    local _pid=$!
    wait "${_pid}"     # collect subshell exit code (propagates via set -e)
    wait               # drain tee processes so log files are fully flushed
}

# ---------------------------------------------------------------------------
# STEP 1: INSTRUMENTED BUILD
# ---------------------------------------------------------------------------
# -fprofile-instr-generate  inject LLVM counter instrumentation
# -gdwarf-4                 DWARF v4; BOLT -update-debug-sections is
#                           incomplete for v5 as of LLVM 19
# -Wl,--emit-relocs         preserve ELF relocations so BOLT can reorder
#                           whole functions (relocation mode = maximum gains)
# shellcheck disable=SC2086  – OPT_LEVEL / EXTRA_CFLAGS intentionally word-split
log_info "=== STEP 1: Instrumented build ==="
# shellcheck disable=SC2086
run_logged "step1_build_instr" \
    clang ${OPT_LEVEL} \
        -fprofile-instr-generate \
        -gdwarf-4 \
        -Wl,--emit-relocs \
        ${EXTRA_CFLAGS} \
        -o "${INSTR_BINARY}" \
        "${SRC_FILES[@]}"

# ---------------------------------------------------------------------------
# STEP 2: PROFILING RUN
# ---------------------------------------------------------------------------
# LLVM_PROFILE_FILE=%p produces one file per PID; handles forking workloads.
log_info "=== STEP 2: Instrumented profiling run ==="
LLVM_PROFILE_FILE="${WORKDIR}/default-%p.profraw" \
    run_logged "step2_profiling_run" \
    "${INSTR_BINARY}"

mapfile -d '' PROFRAW_FILES < <(
    find "${WORKDIR}" -maxdepth 1 -name 'default-*.profraw' -print0
)
if [[ ${#PROFRAW_FILES[@]} -eq 0 ]]; then
    log_error "No .profraw files after instrumented run."
    log_error "  Check ${LOG_DIR}/step2_profiling_run.stderr for crash output."
    exit 1
fi
log_info "Collected ${#PROFRAW_FILES[@]} .profraw file(s)"

# ---------------------------------------------------------------------------
# STEP 3: MERGE INSTRUMENTATION PROFILES
# ---------------------------------------------------------------------------
# llvm-profdata merge produces one indexed .profdata from N .profraw files.
# This is instrumentation PGO data – NOT AutoFDO/sampling format.
log_info "=== STEP 3: Merge instrumentation profiles ==="
run_logged "step3_profdata_merge" \
    llvm-profdata merge \
        --output="${PROFDATA}" \
        "${PROFRAW_FILES[@]}"

# ---------------------------------------------------------------------------
# STEP 4: PGO-GUIDED REBUILD
# ---------------------------------------------------------------------------
# -fprofile-instr-use   feed merged profile → better inlining, branch layout,
#                       loop unrolling, hot/cold splitting
# -fprofile-correction  tolerate minor counter drift (concurrent workloads)
# No -fcoverage-mapping – coverage instrumentation adds ~10% binary size with
#                         zero performance benefit
log_info "=== STEP 4: PGO-guided rebuild ==="
# shellcheck disable=SC2086
run_logged "step4_build_pgo" \
    clang ${OPT_LEVEL} \
        -fprofile-instr-use="${PROFDATA}" \
        -fprofile-correction \
        -gdwarf-4 \
        -Wl,--emit-relocs \
        ${EXTRA_CFLAGS} \
        -o "${PGO_BINARY}" \
        "${SRC_FILES[@]}"

# ---------------------------------------------------------------------------
# STEP 5: perf LBR BRANCH-SAMPLING
# ---------------------------------------------------------------------------
# -e cycles:u    sample user-space CPU cycles (process under test only)
# -j any,u       LBR filter: any branch, user-space only
#                (more precise than bare -b for user-space binaries;
#                 matches LLVM's OptimizingClang.md recommendation)
# -F PERF_FREQ   sampling frequency; prime value avoids aliasing with loops
# -N             do not inherit counters to child processes
#
# Non-LBR fallback: BOLT_NO_LBR=1 drops -j any,u; perf2bolt gets -nl.
log_info "=== STEP 5: perf branch-sampling (${PERF_RUNS} run(s)) ==="

# Build optional-args arrays so run_logged receives them correctly without
# unquoted word-split fragility.
if [[ "${NO_SUDO_PERF}" == "1" ]]; then
    _perf_prefix=()
else
    _perf_prefix=(sudo)
fi

if [[ "${BOLT_NO_LBR}" == "1" ]]; then
    _lbr_flags=()
else
    _lbr_flags=(-j any,u)
fi

PERF_DATA_FILES=()
for (( i = 1; i <= PERF_RUNS; i++ )); do
    _perf_out="${PERF_DATA_BASE}.${i}.data"
    log_info "  Run ${i}/${PERF_RUNS} → ${_perf_out}"
    run_logged "step5_perf_run_${i}" \
        "${_perf_prefix[@]}" perf record \
            -e cycles:u \
            "${_lbr_flags[@]}" \
            -F "${PERF_FREQ}" \
            -N \
            -o "${_perf_out}" \
            -- "${PGO_BINARY}"
    # Transfer ownership from root back to the calling user.
    if [[ "${NO_SUDO_PERF}" != "1" ]]; then
        sudo chown "$(id -un):" "${_perf_out}"
    fi
    PERF_DATA_FILES+=( "${_perf_out}" )
done

# ---------------------------------------------------------------------------
# STEP 6: CONVERT perf.data → BOLT profile
# ---------------------------------------------------------------------------
# perf2bolt: reads perf.data + binary → compact .fdata edge-profile.
# Build ID is verified; the binary must not be rebuilt between steps 5 and 6.
# -nl flag: non-LBR path (basic sample addresses; weaker but valid).
#
# Each perf.data file is converted independently; merge-fdata accumulates
# branch counts across all runs into a single richer profile.
log_info "=== STEP 6: Convert perf data → BOLT profile ==="

if [[ "${BOLT_NO_LBR}" == "1" ]]; then
    _p2b_flags=(-nl)
else
    _p2b_flags=()
fi

FDATA_FILES=()
for (( i = 1; i <= PERF_RUNS; i++ )); do
    _fdata_out="${PERF_FDATA_BASE}.${i}.fdata"
    log_info "  perf2bolt run ${i}/${PERF_RUNS} → ${_fdata_out}"
    run_logged "step6_perf2bolt_${i}" \
        perf2bolt \
            -p "${PERF_DATA_FILES[$((i-1))]}" \
            -o "${_fdata_out}" \
            "${_p2b_flags[@]}" \
            "${PGO_BINARY}"
    FDATA_FILES+=( "${_fdata_out}" )
done

if [[ ${PERF_RUNS} -gt 1 ]]; then
    log_info "  Merging ${PERF_RUNS} .fdata files → ${PERF_FDATA_FINAL}"
    run_logged "step6_merge_fdata" \
        merge-fdata \
            -o "${PERF_FDATA_FINAL}" \
            "${FDATA_FILES[@]}"
else
    PERF_FDATA_FINAL="${FDATA_FILES[0]}"
    log_info "  Single run: using ${PERF_FDATA_FINAL} directly"
fi

# ---------------------------------------------------------------------------
# STEP 7: BOLT POST-LINK OPTIMISATION
# ---------------------------------------------------------------------------
# Flag rationale (LLVM bolt/README.md + bolt/docs/OptimizingClang.md):
#   -reorder-blocks=ext-tsp   Extended TSP; best known block ordering heuristic
#   -reorder-functions=cdsort Cache-Density Sort; upstream default (LLVM 19+)
#   -split-functions          separate hot/cold regions per function
#   -split-all-cold           move ALL cold blocks to cold section
#   -split-eh                 move EH landing pads to cold section
#   -icf=1                    Identical Code Folding (1 pass)
#   -use-gnu-stack            preserve GNU_STACK PT_NOTE; prevents NX faults
#   -dyno-stats               per-function transformation stats → stderr
#   -v                        all BOLT-INFO messages → stderr
log_info "=== STEP 7: BOLT post-link optimisation ==="
run_logged "step7_llvm_bolt" \
    llvm-bolt "${PGO_BINARY}" \
        -o "${BOLT_BINARY}" \
        -data="${PERF_FDATA_FINAL}" \
        -reorder-blocks=ext-tsp \
        -reorder-functions=cdsort \
        -split-functions \
        -split-all-cold \
        -split-eh \
        -icf=1 \
        -use-gnu-stack \
        -dyno-stats \
        -v

# ---------------------------------------------------------------------------
# STEP 8: VALIDATION — perf stat comparison
# ---------------------------------------------------------------------------
# perf stat -d adds hardware cache counter groups (L1-icache, iTLB, LLC)
# that are not in the default set.  These are the counters most affected by
# BOLT layout changes and are required for meaningful before/after comparison.
#
# --repeat 5: run 5 times, report mean ± stddev to reduce scheduling noise.
#
# Exit codes from the binaries are ignored (|| true) because a non-zero
# workload exit (e.g. sort checksum) must not abort the pipeline here.
# perf stat itself failing is a separate concern; verify.sh detects zero counts.
log_info "=== STEP 8: Validation — perf stat comparison ==="

log_info "  Baseline (PGO binary):"
run_logged "step8_perf_stat_baseline" \
    perf stat -d --repeat 5 -- "${PGO_BINARY}" || true

log_info "  Optimised (BOLT binary):"
run_logged "step8_perf_stat_bolt" \
    perf stat -d --repeat 5 -- "${BOLT_BINARY}" || true

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
log_info "=== Pipeline complete ==="
log_info ""
log_info "Artefacts:"
log_info "  ${INSTR_BINARY}  (instrumented)"
log_info "  ${PGO_BINARY}    (PGO-optimised)"
log_info "  ${BOLT_BINARY}   (BOLT-optimised)"
log_info ""
log_info "Logs in ${LOG_DIR}/:"
log_info "  step1_build_instr          step5_perf_run_N"
log_info "  step2_profiling_run        step6_perf2bolt_N"
log_info "  step3_profdata_merge       step6_merge_fdata"
log_info "  step4_build_pgo            step7_llvm_bolt  ← BOLT-INFO here"
log_info "                             step8_perf_stat_{baseline,bolt}"
log_info ""
log_info "Next: bash verify.sh"
