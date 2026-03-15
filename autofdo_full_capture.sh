#!/usr/bin/env bash
# =============================================================================
# autofdo_full_capture.sh
# Fedora 43 – Full-visibility AutoFDO-style profile-guided optimization
#
# Pipeline:
#   1. Clang instrumentation PGO build  (-fprofile-instr-generate)
#   2. Workload profiling run           (collects default-%p.profraw)
#   3. Instrumentation PGO merge        (llvm-profdata merge)
#   4. PGO-guided rebuild               (-fprofile-instr-use, --emit-relocs)
#   5. perf LBR sampling on PGO binary  (perf record -j any,u)
#   6. BOLT profile conversion          (perf2bolt → perf.fdata, merge-fdata)
#   7. BOLT post-link optimization      (llvm-bolt, ext-tsp, cdsort)
#   8. Validation run with perf stat    (perf stat -d --repeat 5)
#
# All stdout and stderr are tee'd to both terminal and per-step log files so
# that event messages, warnings, diagnostic output, and hidden tool messages
# are fully visible.  Log files survive the script unconditionally; artefacts
# in WORKDIR are preserved on failure for post-mortem inspection.
#
# Prerequisites (Fedora 43):
#   sudo dnf install clang llvm llvm-bolt perf
#
# Usage:
#   chmod +x autofdo_full_capture.sh
#   SRC_DIR=/path/to/src APP_NAME=myapp ./autofdo_full_capture.sh
#
# All tunables are documented in the CONFIGURATION section below.
# =============================================================================

set -euo pipefail
# Default IFS.  Explicit quoting is used throughout; IFS is not manipulated
# because doing so interacts badly with array expansions in subtle ways.

# ---------------------------------------------------------------------------
# LOGGING HELPERS
# ---------------------------------------------------------------------------
# All log output goes to stderr so it never contaminates a pipe from the
# binary under test.  Timestamp prefix makes log files grep-parseable.

log_info()  { printf '[INFO  %(%T)T] %s\n' -1 "$*" >&2; }
log_warn()  { printf '[WARN  %(%T)T] %s\n' -1 "$*" >&2; }
log_error() { printf '[ERROR %(%T)T] %s\n' -1 "$*" >&2; }

# ---------------------------------------------------------------------------
# CONFIGURATION  (override via environment)
# ---------------------------------------------------------------------------

# Directory containing *.c source files.  Must exist and be non-empty.
SRC_DIR="${SRC_DIR:-./src}"

# Output binary base name (no directory component).
APP_NAME="${APP_NAME:-my_app}"

# Working directory: PGO/BOLT artefacts.  Created if absent.
WORKDIR="${WORKDIR:-./autofdo_workdir}"

# Log directory: one stdout + one stderr file per step.  Never removed.
LOG_DIR="${LOG_DIR:-./autofdo_logs}"

# Number of perf LBR sampling runs.  More runs → richer branch profile.
# Minimum useful value is 1; 3 is a good default for representative coverage.
PERF_RUNS="${PERF_RUNS:-3}"

# perf sampling frequency in Hz.  A prime avoids aliasing with program loops.
# Must not exceed /proc/sys/kernel/perf_event_max_sample_rate (default 100000).
PERF_FREQ="${PERF_FREQ:-2999}"

# Clang optimisation level for both the instrumented and PGO-guided builds.
OPT_LEVEL="${OPT_LEVEL:--O2}"

# Extra CFLAGS appended to every clang invocation (optional).
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"

# Set to "1" to skip sudo for perf record.
# Requires /proc/sys/kernel/perf_event_paranoid <= 1 for LBR access.
NO_SUDO_PERF="${NO_SUDO_PERF:-0}"

# Set to "1" to add -nl to perf2bolt (non-LBR fallback for VMs/containers).
# BOLT optimisations are weaker without LBR but the pipeline still completes.
BOLT_NO_LBR="${BOLT_NO_LBR:-0}"

# ---------------------------------------------------------------------------
# DERIVED PATHS  (internal; not user-configurable)
# ---------------------------------------------------------------------------

INSTR_BINARY="${WORKDIR}/${APP_NAME}.instr"   # step 1 output
PGO_BINARY="${WORKDIR}/${APP_NAME}.pgo"        # step 4 output
BOLT_BINARY="${WORKDIR}/${APP_NAME}.bolt"      # step 7 output

PROFDATA="${WORKDIR}/default.profdata"         # step 3 output

PERF_DATA_BASE="${WORKDIR}/perf"               # per-run: ${PERF_DATA_BASE}.N.data
PERF_FDATA_BASE="${WORKDIR}/perf"              # per-run: ${PERF_FDATA_BASE}.N.fdata
PERF_FDATA_FINAL="${WORKDIR}/perf.merged.fdata" # step 6 final profile

# ---------------------------------------------------------------------------
# GUARD: required tools
# ---------------------------------------------------------------------------

_check_tool() {
    # $1 = binary name, $2 = dnf package name
    if ! command -v "$1" &>/dev/null; then
        log_error "Required tool not found: $1"
        log_error "  sudo dnf install $2"
        exit 1
    fi
}

_check_tool clang        clang
_check_tool llvm-profdata llvm
_check_tool llvm-bolt    llvm-bolt
_check_tool perf2bolt    llvm-bolt
_check_tool merge-fdata  llvm-bolt
_check_tool perf         perf

# ---------------------------------------------------------------------------
# GUARD: LBR hardware probe
# ---------------------------------------------------------------------------
# Attempt a zero-duration perf record with -j any,u.  If the kernel rejects
# it, warn and set BOLT_NO_LBR automatically so the rest of the pipeline can
# continue with the non-LBR fallback path.

if [[ "${BOLT_NO_LBR}" != "1" ]]; then
    _lbr_test_output=$(
        sudo perf record -e cycles:u -j any,u -o /dev/null -- true 2>&1
    ) || true
    if echo "${_lbr_test_output}" | grep -qiE 'not supported|unsupported|Permission'; then
        log_warn "LBR branch sampling unavailable on this system."
        log_warn "Detected: ${_lbr_test_output}"
        log_warn "Setting BOLT_NO_LBR=1 (non-LBR fallback).  Optimisation quality is reduced."
        log_warn "To suppress this probe: set BOLT_NO_LBR=1 before running."
        BOLT_NO_LBR=1
    fi
fi

# ---------------------------------------------------------------------------
# GUARD: source files
# ---------------------------------------------------------------------------

if [[ ! -d "${SRC_DIR}" ]]; then
    log_error "SRC_DIR does not exist: ${SRC_DIR}"
    exit 1
fi

# Collect source files using find + mapfile to handle spaces and special chars.
# nullglob semantics via find; empty result is caught below.
mapfile -d '' SRC_FILES < <(
    find "${SRC_DIR}" -maxdepth 1 -name '*.c' -print0
)

if [[ ${#SRC_FILES[@]} -eq 0 ]]; then
    log_error "No *.c files found under ${SRC_DIR}"
    log_error "  Run 'make' first to generate src/workload.c"
    exit 1
fi

log_info "Source files found: ${#SRC_FILES[@]} (in ${SRC_DIR})"

# ---------------------------------------------------------------------------
# DIRECTORY SETUP
# ---------------------------------------------------------------------------

mkdir -p "${WORKDIR}"
mkdir -p "${LOG_DIR}"

# Purge leftover profraw files from any previous run so the instrumented
# binary does not append stale counter data into the new profile.
find "${WORKDIR}" -maxdepth 1 -name 'default-*.profraw' -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# EXIT TRAP
# ---------------------------------------------------------------------------
# On abnormal exit the trap logs the failing step.  Artefacts in WORKDIR and
# LOG_DIR are always preserved so failures can be diagnosed after the fact.

_on_exit() {
    local code=$?
    if [[ ${code} -ne 0 ]]; then
        log_warn "Pipeline exited with status ${code}."
        log_warn "Artefacts preserved in : ${WORKDIR}"
        log_warn "Logs preserved in       : ${LOG_DIR}"
        log_warn "Run 'bash verify.sh' once failures are resolved."
    fi
}
trap _on_exit EXIT

# ---------------------------------------------------------------------------
# run_logged  <stem>  <cmd> [args…]
# ---------------------------------------------------------------------------
# Runs <cmd> [args…] and tees both stdout and stderr to per-step log files
# while simultaneously mirroring both streams to the terminal.
#
# Exit-code fidelity under set -euo pipefail:
#   Process substitutions (>(…)) are asynchronous.  We capture the subshell
#   PID with $!, then call 'wait $subshell_pid' to collect its exit code.
#   Without the explicit PID, 'wait' with no argument waits for all background
#   jobs and returns the exit code of the last one, which may not be the
#   subshell.  The explicit PID form is correct.

run_logged() {
    local stem="$1"; shift
    local stdout_log="${LOG_DIR}/${stem}.stdout"
    local stderr_log="${LOG_DIR}/${stem}.stderr"

    log_info "CMD : $*"
    log_info "STDOUT → ${stdout_log}"
    log_info "STDERR → ${stderr_log}"

    # The subshell is backgrounded so we can capture its PID with $!.
    # set -e is in effect inside the subshell; any failing command propagates
    # as the subshell exit code collected by 'wait'.
    (
        "$@" \
            > >(tee -a "${stdout_log}") \
            2> >(tee -a "${stderr_log}" >&2)
    ) &
    local subshell_pid=$!
    # Wait for the specific subshell PID, not the tee processes.
    wait "${subshell_pid}"
}

# ---------------------------------------------------------------------------
# STEP 1: INSTRUMENTED BUILD
# ---------------------------------------------------------------------------
# -fprofile-instr-generate  inserts LLVM instrumentation counters.
# -gdwarf-4                 DWARF v4; BOLT's -update-debug-sections has
#                           incomplete DWARF v5 support as of LLVM 19.
# --emit-relocs             preserves ELF relocations so BOLT can reorganise
#                           functions as well as basic blocks within functions.
#                           Without this BOLT operates in a restricted mode.
# shellcheck disable=SC2086  – OPT_LEVEL and EXTRA_CFLAGS are intentionally
#                              word-split to allow multi-word values like "-O2 -march=native"

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
# LLVM_PROFILE_FILE=%p inserts the process PID so forking workloads produce
# distinct files.  All files are collected in WORKDIR for the merge step.

log_info "=== STEP 2: Instrumented profiling run ==="

LLVM_PROFILE_FILE="${WORKDIR}/default-%p.profraw" \
    run_logged "step2_profiling_run" \
    "${INSTR_BINARY}"

# Verify that at least one profraw file was written.  A clean exit without
# profraw output means LLVM_PROFILE_FILE was ignored (e.g. static binary
# built without compiler-rt) or the binary crashed before atexit handlers ran.
mapfile -d '' PROFRAW_FILES < <(
    find "${WORKDIR}" -maxdepth 1 -name 'default-*.profraw' -print0
)

if [[ ${#PROFRAW_FILES[@]} -eq 0 ]]; then
    log_error "No .profraw files found after instrumented run."
    log_error "  Check that clang-rt is linked (default when using clang driver)."
    log_error "  Check ${LOG_DIR}/step2_profiling_run.stderr for crash output."
    exit 1
fi

log_info "Collected ${#PROFRAW_FILES[@]} .profraw file(s)"

# ---------------------------------------------------------------------------
# STEP 3: MERGE INSTRUMENTATION PROFILES
# ---------------------------------------------------------------------------
# llvm-profdata merge converts one or more raw counter files into a single
# indexed .profdata binary.  This is strictly instrumentation PGO data;
# it is NOT the same format as AutoFDO/sampling profiles.

log_info "=== STEP 3: Merge instrumentation profiles ==="

run_logged "step3_profdata_merge" \
    llvm-profdata merge \
        --output="${PROFDATA}" \
        "${PROFRAW_FILES[@]}"

# ---------------------------------------------------------------------------
# STEP 4: PGO-GUIDED REBUILD
# ---------------------------------------------------------------------------
# The compiler consumes the merged profile to improve:
#   • inlining decisions   (hot callsites get aggressive inlining)
#   • branch layout        (likely paths in fall-through direction)
#   • loop unrolling       (hot loops unrolled further)
#   • code splitting       (cold code moved away from hot code)
#
# -fprofile-correction    tolerates minor drift from concurrent or
#                         non-deterministic execution.
# --emit-relocs           same rationale as step 1; required for BOLT to
#                         achieve maximum layout freedom.
# No -fcoverage-mapping   coverage mapping is for coverage reports only and
#                         adds ~10% binary size with zero performance benefit.

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
# STEP 5: LBR BRANCH-SAMPLING WITH perf
# ---------------------------------------------------------------------------
# BOLT requires Last Branch Record (LBR) data for full CFG edge profiling.
# -e cycles:u          sample user-space cycles (process under test only)
# -j any,u             capture LBR with user-space filter; this is more
#                      precise than bare '-b' for user-space binaries and
#                      matches the approach in LLVM's OptimizingClang.md
# -F ${PERF_FREQ}      sampling frequency in Hz
# -N                   do not inherit counters to child processes
# -o <file>            per-run output file (unique name avoids clobbering)
#
# Non-LBR fallback: when BOLT_NO_LBR=1 (set by the LBR probe above or by
# the user), '-j any,u' is replaced with plain '-e cycles:u'.  perf2bolt is
# then invoked with -nl so it reads basic-sample profiles.

log_info "=== STEP 5: perf LBR branch-sampling (${PERF_RUNS} run(s)) ==="

PERF_DATA_FILES=()

_perf_sudo=""
[[ "${NO_SUDO_PERF}" != "1" ]] && _perf_sudo="sudo"

for (( i = 1; i <= PERF_RUNS; i++ )); do
    _perf_out="${PERF_DATA_BASE}.${i}.data"
    log_info "  Run ${i}/${PERF_RUNS} → ${_perf_out}"

    if [[ "${BOLT_NO_LBR}" == "1" ]]; then
        # Non-LBR path: basic sample profile (reduced BOLT quality)
        # shellcheck disable=SC2086
        run_logged "step5_perf_run_${i}" \
            ${_perf_sudo} perf record \
                -e cycles:u \
                -F "${PERF_FREQ}" \
                -N \
                -o "${_perf_out}" \
                -- "${PGO_BINARY}"
    else
        # LBR path: full taken-branch edge profiling
        # shellcheck disable=SC2086
        run_logged "step5_perf_run_${i}" \
            ${_perf_sudo} perf record \
                -e cycles:u \
                -j any,u \
                -F "${PERF_FREQ}" \
                -N \
                -o "${_perf_out}" \
                -- "${PGO_BINARY}"
    fi

    # Transfer ownership back from root so perf2bolt can read the file.
    if [[ "${NO_SUDO_PERF}" != "1" ]]; then
        sudo chown "$(id -un):" "${_perf_out}"
    fi

    PERF_DATA_FILES+=( "${_perf_out}" )
done

# ---------------------------------------------------------------------------
# STEP 6: CONVERT perf.data → BOLT profile
# ---------------------------------------------------------------------------
# perf2bolt reads perf.data + the profiled binary and emits a compact .fdata
# file.  Build ID verification ensures the data matches the binary.
#
# -nl flag: pass when LBR is unavailable (non-LBR basic sample profile).
#
# When PERF_RUNS > 1, each perf.data is converted independently then merged
# with merge-fdata, which accumulates branch counts across runs.

log_info "=== STEP 6: Convert perf data → BOLT profile ==="

_p2b_extra=""
[[ "${BOLT_NO_LBR}" == "1" ]] && _p2b_extra="-nl"

FDATA_FILES=()

for (( i = 1; i <= PERF_RUNS; i++ )); do
    _fdata_out="${PERF_FDATA_BASE}.${i}.fdata"
    log_info "  perf2bolt run ${i}/${PERF_RUNS} → ${_fdata_out}"

    # shellcheck disable=SC2086
    run_logged "step6_perf2bolt_${i}" \
        perf2bolt \
            -p "${PERF_DATA_FILES[$((i-1))]}" \
            -o "${_fdata_out}" \
            ${_p2b_extra} \
            "${PGO_BINARY}"

    FDATA_FILES+=( "${_fdata_out}" )
done

# Merge all .fdata files into a single profile.
# merge-fdata writes to stdout by default; -o writes to a named file.
# The -o flag is present in the current upstream source (see LLVM bolt/tools/).
if [[ ${PERF_RUNS} -gt 1 ]]; then
    log_info "  Merging ${PERF_RUNS} .fdata files → ${PERF_FDATA_FINAL}"
    run_logged "step6_merge_fdata" \
        merge-fdata \
            -o "${PERF_FDATA_FINAL}" \
            "${FDATA_FILES[@]}"
else
    # Single run: skip merge, use the one .fdata directly.
    PERF_FDATA_FINAL="${FDATA_FILES[0]}"
    log_info "  Single run: using ${PERF_FDATA_FINAL} directly"
fi

# ---------------------------------------------------------------------------
# STEP 7: BOLT POST-LINK OPTIMISATION
# ---------------------------------------------------------------------------
# llvm-bolt reorganises functions and basic blocks for i-cache and iTLB
# efficiency.  All BOLT-INFO / BOLT-WARNING diagnostics go to stderr and are
# captured by run_logged.
#
# Flag rationale (LLVM bolt/README.md + bolt/docs/OptimizingClang.md):
#   -data=<fdata>             the BOLT edge profile
#   -reorder-blocks=ext-tsp   Extended TSP; best known block ordering
#   -reorder-functions=cdsort Cache-Density Sort; upstream default (LLVM 19+)
#   -split-functions          separate hot and cold regions per function
#   -split-all-cold           move ALL cold basic blocks to cold section
#   -split-eh                 move EH landing pads to cold section
#   -icf=1                    Identical Code Folding (1 pass)
#   -use-gnu-stack            preserve GNU_STACK PT_NOTE; prevents NX faults
#   -dyno-stats               per-function transformation statistics to stderr
#   -v                        verbose: all BOLT-INFO messages to stderr

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
# perf stat -d adds hardware cache-event groups (L1-icache, iTLB, LLC)
# that are not included in the default counter set.  These are the counters
# most affected by BOLT's layout changes, making -d essential for meaningful
# before/after comparison.
#
# --repeat 5 runs the binary 5 times and reports mean ± stddev, reducing
# the influence of OS scheduling noise on the elapsed-time measurement.
#
# Both binaries exit with '|| true' so a non-zero return from the workload
# (e.g. sorted-array checksum mismatch) does not abort the pipeline here.

log_info "=== STEP 8: Validation — perf stat comparison ==="

log_info "  Baseline (PGO binary):"
run_logged "step8_perf_stat_baseline" \
    perf stat -d --repeat 5 -- "${PGO_BINARY}" || true

log_info "  Optimised (BOLT binary):"
run_logged "step8_perf_stat_bolt" \
    perf stat -d --repeat 5 -- "${BOLT_BINARY}" || true

# ---------------------------------------------------------------------------
# PIPELINE SUMMARY
# ---------------------------------------------------------------------------

log_info "=== Pipeline complete ==="
log_info ""
log_info "Artefacts:"
log_info "  ${INSTR_BINARY}  (instrumented)"
log_info "  ${PGO_BINARY}    (PGO-optimised)"
log_info "  ${BOLT_BINARY}   (BOLT-optimised)"
log_info ""
log_info "Logs: ${LOG_DIR}/"
log_info "  step1_build_instr.{stdout,stderr}"
log_info "  step2_profiling_run.{stdout,stderr}"
log_info "  step3_profdata_merge.{stdout,stderr}"
log_info "  step4_build_pgo.{stdout,stderr}"
log_info "  step5_perf_run_N.{stdout,stderr}"
log_info "  step6_perf2bolt_N.{stdout,stderr}"
log_info "  step6_merge_fdata.{stdout,stderr}"
log_info "  step7_llvm_bolt.{stdout,stderr}    ← BOLT-INFO / BOLT-WARNING"
log_info "  step8_perf_stat_baseline.{stdout,stderr}"
log_info "  step8_perf_stat_bolt.{stdout,stderr}"
log_info ""
log_info "Next step:"
log_info "  bash verify.sh"
