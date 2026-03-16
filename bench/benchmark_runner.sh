#!/usr/bin/env bash
# =============================================================================
# bench/benchmark_runner.sh
# Deterministic benchmark harness for the AutoFDO pipeline
#
# Fixes over the naive version:
#   • BENCH_PERF_EVENTS is parsed into a proper -e array (not a raw string)
#   • Turbo disable/restore handles both Intel pstate and AMD cpufreq
#   • EXIT trap restores turbo so the system isn't left degraded on failure
#   • CPU core guard: skips taskset if BENCH_CPU_CORE is empty or offline
#   • Emits results as JSON to results/<label>.json for archiving
#   • Uses perf stat -j (JSON output) for machine-parseable counter data
#
# Usage:
#   bash bench/benchmark_runner.sh <binary> <label>
#   bash bench/benchmark_runner.sh autofdo_workdir/my_app.pgo  baseline
#   bash bench/benchmark_runner.sh autofdo_workdir/my_app.bolt bolt
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Load configuration (safe to override via env before calling this script)
# ---------------------------------------------------------------------------
BENCH_REPEATS="${BENCH_REPEATS:-7}"
BENCH_CPU_CORE="${BENCH_CPU_CORE:-2}"
BENCH_DISABLE_TURBO="${BENCH_DISABLE_TURBO:-auto}"
BENCH_PERF_EVENTS="${BENCH_PERF_EVENTS:-cycles
instructions
branch-misses
L1-icache-load-misses
iTLB-load-misses
LLC-load-misses}"

# Source config file if present (overrides defaults above)
if [[ -f "${SCRIPT_DIR}/benchmark_config.env" ]]; then
    # shellcheck source=bench/benchmark_config.env
    source "${SCRIPT_DIR}/benchmark_config.env"
fi

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
    printf 'Usage: %s <binary> <label>\n' "$0" >&2
    printf '  <binary>  path to the executable to benchmark\n' >&2
    printf '  <label>   output label, e.g. "baseline" or "bolt"\n' >&2
    exit 1
fi

TARGET_BINARY="$1"
LABEL="$2"
RESULTS_DIR="${REPO_ROOT}/results"
OUTPUT_JSON="${RESULTS_DIR}/${LABEL}.json"

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
[[ -f "${TARGET_BINARY}" ]] || { printf 'ERROR: binary not found: %s\n' "${TARGET_BINARY}" >&2; exit 1; }
[[ -x "${TARGET_BINARY}" ]] || { printf 'ERROR: binary not executable: %s\n' "${TARGET_BINARY}" >&2; exit 1; }
command -v perf     &>/dev/null || { printf 'ERROR: perf not found. sudo dnf install perf\n' >&2; exit 1; }
command -v python3  &>/dev/null || { printf 'ERROR: python3 not found\n' >&2; exit 1; }

mkdir -p "${RESULTS_DIR}"

# ---------------------------------------------------------------------------
# Build perf -e argument array from BENCH_PERF_EVENTS
# ---------------------------------------------------------------------------
# Parse the multiline BENCH_PERF_EVENTS string into an array of -e flags.
# Blank lines and leading/trailing whitespace are ignored.
PERF_E_ARGS=()
while IFS= read -r _event; do
    _event="${_event//[[:space:]]/}"          # strip all whitespace
    [[ -z "${_event}" ]] && continue          # skip blank lines
    PERF_E_ARGS+=( -e "${_event}" )
done <<< "${BENCH_PERF_EVENTS}"

if [[ ${#PERF_E_ARGS[@]} -eq 0 ]]; then
    printf 'ERROR: no perf events configured in BENCH_PERF_EVENTS\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# CPU core validation
# ---------------------------------------------------------------------------
# Disable pinning if BENCH_CPU_CORE is empty or the core is not online.
_use_taskset=0
if [[ -n "${BENCH_CPU_CORE}" ]]; then
    _online="/sys/devices/system/cpu/cpu${BENCH_CPU_CORE}/online"
    if [[ -f "${_online}" ]] && [[ "$(cat "${_online}")" == "1" ]]; then
        _use_taskset=1
    elif [[ ! -f "${_online}" ]] && (( BENCH_CPU_CORE < $(nproc) )); then
        # cpu0 has no 'online' file on most kernels (always online)
        _use_taskset=1
    else
        printf '[bench] WARNING: CPU core %s not online; disabling taskset\n' \
            "${BENCH_CPU_CORE}" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Turbo disable with platform detection and EXIT restore
# ---------------------------------------------------------------------------
# Tracks what we changed so the EXIT trap can undo it.
_turbo_intel=""
_turbo_amd=""

_disable_turbo() {
    local intel_path="/sys/devices/system/cpu/intel_pstate/no_turbo"
    local amd_path="/sys/devices/system/cpu/cpufreq/boost"

    if [[ -f "${intel_path}" ]]; then
        _turbo_intel=$(cat "${intel_path}")
        echo 1 | sudo tee "${intel_path}" > /dev/null
        printf '[bench] Intel turbo disabled (no_turbo=1)\n' >&2
    elif [[ -f "${amd_path}" ]]; then
        _turbo_amd=$(cat "${amd_path}")
        echo 0 | sudo tee "${amd_path}" > /dev/null
        printf '[bench] AMD boost disabled (boost=0)\n' >&2
    else
        printf '[bench] WARNING: no turbo control found; skipping\n' >&2
    fi
}

_restore_turbo() {
    local intel_path="/sys/devices/system/cpu/intel_pstate/no_turbo"
    local amd_path="/sys/devices/system/cpu/cpufreq/boost"

    if [[ -n "${_turbo_intel}" ]] && [[ -f "${intel_path}" ]]; then
        echo "${_turbo_intel}" | sudo tee "${intel_path}" > /dev/null
        printf '[bench] Intel turbo restored (no_turbo=%s)\n' "${_turbo_intel}" >&2
    fi
    if [[ -n "${_turbo_amd}" ]] && [[ -f "${amd_path}" ]]; then
        echo "${_turbo_amd}" | sudo tee "${amd_path}" > /dev/null
        printf '[bench] AMD boost restored (boost=%s)\n' "${_turbo_amd}" >&2
    fi
}

# Always restore turbo on exit (success, failure, or signal)
trap _restore_turbo EXIT

case "${BENCH_DISABLE_TURBO}" in
    true|auto) _disable_turbo ;;
    false)     printf '[bench] Turbo control skipped (BENCH_DISABLE_TURBO=false)\n' >&2 ;;
    *)         printf '[bench] WARNING: unknown BENCH_DISABLE_TURBO value: %s\n' \
                   "${BENCH_DISABLE_TURBO}" >&2 ;;
esac

# ---------------------------------------------------------------------------
# Run benchmark
# ---------------------------------------------------------------------------
printf '[bench] Binary    : %s\n' "${TARGET_BINARY}" >&2
printf '[bench] Label     : %s\n' "${LABEL}" >&2
printf '[bench] Repeats   : %s\n' "${BENCH_REPEATS}" >&2
printf '[bench] CPU core  : %s\n' "$(( _use_taskset )) && echo ${BENCH_CPU_CORE} || echo '(all cores)'" >&2
printf '[bench] Events    : %s\n' "${#PERF_E_ARGS[@]} event(s)" >&2
printf '[bench] Output    : %s\n' "${OUTPUT_JSON}" >&2

# Capture perf stat JSON output to a temp file; JSON mode writes to stderr
_perf_json_tmp=$(mktemp /tmp/bench-perf-XXXXXX.json)
trap '_restore_turbo; rm -f "${_perf_json_tmp}"' EXIT

_perf_cmd=( perf stat -j -r "${BENCH_REPEATS}" "${PERF_E_ARGS[@]}" )

if (( _use_taskset )); then
    _perf_cmd=( taskset -c "${BENCH_CPU_CORE}" "${_perf_cmd[@]}" )
fi

# perf stat -j writes JSON to stderr; redirect stderr to the temp file
# while also mirroring to the terminal for visibility.
"${_perf_cmd[@]}" -- "${TARGET_BINARY}" \
    2> >(tee "${_perf_json_tmp}" >&2) &
_perf_pid=$!
wait "${_perf_pid}"
wait   # drain tee

# ---------------------------------------------------------------------------
# Parse perf stat JSON → results/<label>.json
# ---------------------------------------------------------------------------
# perf stat -j emits one JSON object per line per event, then a summary.
# We aggregate into a single document with a metrics map.
python3 - "${_perf_json_tmp}" "${OUTPUT_JSON}" "${LABEL}" "${TARGET_BINARY}" \
    "${BENCH_REPEATS}" << 'PYEOF'
import json, sys, re, os
from datetime import datetime, timezone

perf_json_path = sys.argv[1]
output_path    = sys.argv[2]
label          = sys.argv[3]
binary         = sys.argv[4]
repeats        = int(sys.argv[5])

metrics = {}
wall_time = None

with open(perf_json_path) as fh:
    for line in fh:
        line = line.strip()
        if not line or not line.startswith('{'):
            # Try to extract wall-clock time from the human-readable summary
            m = re.search(r'([\d.]+)\s+seconds time elapsed', line)
            if m:
                wall_time = float(m.group(1))
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        event = obj.get('event', '').strip()
        count = obj.get('counter-value')
        if event and count is not None:
            try:
                metrics[event] = float(count)
            except (ValueError, TypeError):
                metrics[event] = None

result = {
    "label":      label,
    "binary":     os.path.abspath(binary),
    "timestamp":  datetime.now(timezone.utc).isoformat(),
    "repeats":    repeats,
    "wall_time_s": wall_time,
    "metrics":    metrics,
}

with open(output_path, 'w') as fh:
    json.dump(result, fh, indent=2)
    fh.write('\n')

print(f'[bench] Written: {output_path}')
PYEOF

rm -f "${_perf_json_tmp}"

printf '[bench] Done. Results: %s\n' "${OUTPUT_JSON}" >&2
