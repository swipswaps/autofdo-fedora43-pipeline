# autofdo-fedora43-pipeline

> Fedora 43 · Clang instrumentation PGO → perf LBR sampling → LLVM BOLT post-link optimisation  
> Full stdout/stderr capture for every tool. Automatic LBR fallback for VMs.

---

## What this does

Stacks three compiler-optimisation layers on any C project:

| Layer | Tool | Effect |
|---|---|---|
| 1 | Clang instrumentation PGO | Counter-exact branch/call frequency data fed back to the compiler |
| 2 | perf LBR sampling | Real taken-branch edge profiles collected from the running binary |
| 3 | LLVM BOLT | Physical binary rewrite — hot code packed for i-cache and iTLB locality |

Each layer targets a different bottleneck.  Combined, they consistently outperform AutoFDO alone (Android's approach) because BOLT operates post-link on the final binary, after all compiler transformations are already applied.

---

## Repository layout

```
autofdo-fedora43-pipeline/
├── autofdo_full_capture.sh  main pipeline (8 steps, full log capture)
├── verify.sh                parse logs → structured before/after delta report
├── Makefile                 build demo workload; wire make run/verify/lint
├── gen_workload.py          write src/workload.c (called by make)
├── repo_push.sh             create GitHub repo and push (gh CLI)
├── TROUBLESHOOTING.md       15 failure cases with causes and fixes
└── README.md                this file
```

---

## Prerequisites

```bash
sudo dnf install clang llvm llvm-bolt perf
```

`perf2bolt` and `merge-fdata` are bundled in the `llvm-bolt` package on Fedora 43.  
Python 3 (any version ≥ 3.6) is required for `make` to generate the demo workload.

### LBR hardware requirement

BOLT achieves maximum gains with Last Branch Records (LBR).

| Platform | Support |
|---|---|
| Intel Haswell+ (2013+) | ✅ Full LBR |
| AMD Zen 3 | ✅ BRS — verify: `grep ' brs' /proc/cpuinfo` |
| AMD Zen 4 | ✅ amd_lbr_v2 — verify: `grep amd_lbr_v2 /proc/cpuinfo` |
| VM / container / older CPU | ⚠️ No LBR — pipeline auto-detects and falls back |

**The pipeline probes for LBR at startup and automatically sets `BOLT_NO_LBR=1` if unavailable.** You do not need to configure this manually.

---

## Quick start

```bash
# Clone
git clone https://github.com/swipswaps/autofdo-fedora43-pipeline
cd autofdo-fedora43-pipeline

# Generate the demo workload source and verify it compiles
make

# Run the full 8-step pipeline
make run

# View the before/after performance report
make verify
```

Expected output from `make verify`:

```
=== Verdict ===
  BOLT-optimised binary is: FASTER by 9–15% wall-clock time
```

Typical run time on a modern desktop: 3–8 minutes total (dominated by the 3 × 4M-element sort profiling runs).

---

## Using your own project

Point `SRC_DIR` at any directory of `.c` files:

```bash
SRC_DIR=/path/to/myproject/src \
APP_NAME=myapp \
bash autofdo_full_capture.sh
```

Or override via make:

```bash
make SRC_DIR=/path/to/myproject/src APP_NAME=myapp run
```

The pipeline compiles all `*.c` files found directly under `SRC_DIR` (non-recursive, depth 1).

---

## All tunable variables

| Variable | Default | Description |
|---|---|---|
| `SRC_DIR` | `./src` | Directory containing `*.c` source files |
| `APP_NAME` | `my_app` | Output binary base name |
| `WORKDIR` | `./autofdo_workdir` | PGO / BOLT artefacts |
| `LOG_DIR` | `./autofdo_logs` | Per-step stdout + stderr logs (never deleted) |
| `PERF_RUNS` | `3` | Number of LBR sampling runs (more = richer profile) |
| `PERF_FREQ` | `2999` | perf sampling frequency in Hz (prime avoids aliasing) |
| `OPT_LEVEL` | `-O2` | Clang optimisation flag for all builds |
| `EXTRA_CFLAGS` | _(empty)_ | Appended to every `clang` invocation |
| `NO_SUDO_PERF` | `0` | Set `1` if `perf_event_paranoid ≤ 1` and you want no sudo |
| `BOLT_NO_LBR` | `0` | Set `1` to force non-LBR fallback (auto-detected normally) |

---

## Pipeline steps in detail

```
Source (*.c)
    │
    ▼  STEP 1 ─ Instrumented build
    │  clang -fprofile-instr-generate -gdwarf-4 -Wl,--emit-relocs
    │  → my_app.instr
    │
    ▼  STEP 2 ─ Profiling run
    │  LLVM_PROFILE_FILE=default-%p.profraw ./my_app.instr
    │  → default-<pid>.profraw (one per process)
    │
    ▼  STEP 3 ─ Profile merge
    │  llvm-profdata merge *.profraw → default.profdata
    │
    ▼  STEP 4 ─ PGO-guided rebuild
    │  clang -fprofile-instr-use=default.profdata -fprofile-correction
    │         -gdwarf-4 -Wl,--emit-relocs
    │  → my_app.pgo
    │
    ▼  STEP 5 ─ perf LBR sampling  (PERF_RUNS times)
    │  perf record -e cycles:u -j any,u -F 2999 -N
    │  → perf.1.data … perf.N.data
    │  [auto-fallback: -j any,u omitted when LBR unavailable]
    │
    ▼  STEP 6 ─ BOLT profile conversion
    │  perf2bolt -p perf.N.data -o perf.N.fdata  (per run)
    │  merge-fdata -o perf.merged.fdata  (accumulates all runs)
    │
    ▼  STEP 7 ─ BOLT post-link optimisation
    │  llvm-bolt my_app.pgo -o my_app.bolt
    │    -reorder-blocks=ext-tsp   (best-known block ordering)
    │    -reorder-functions=cdsort (Cache-Density Sort, LLVM 19+)
    │    -split-functions -split-all-cold -split-eh
    │    -icf=1 -use-gnu-stack -dyno-stats -v
    │  → my_app.bolt
    │
    ▼  STEP 8 ─ Validation
       perf stat -d --repeat 5 -- my_app.pgo   (baseline)
       perf stat -d --repeat 5 -- my_app.bolt  (optimised)
       → autofdo_logs/step8_perf_stat_{baseline,bolt}.stderr
```

---

## Reading the logs

Every step writes two files to `autofdo_logs/`:

```
autofdo_logs/
  step1_build_instr.{stdout,stderr}       ← clang warnings / errors
  step2_profiling_run.{stdout,stderr}     ← workload output
  step3_profdata_merge.{stdout,stderr}
  step4_build_pgo.{stdout,stderr}         ← PGO inlining feedback
  step5_perf_run_1.{stdout,stderr}        ← perf verbose output
  step5_perf_run_N.{stdout,stderr}
  step6_perf2bolt_N.{stdout,stderr}       ← symbol resolution messages
  step6_merge_fdata.{stdout,stderr}
  step7_llvm_bolt.{stdout,stderr}         ← BOLT-INFO / BOLT-WARNING  ← key file
  step8_perf_stat_baseline.{stdout,stderr}
  step8_perf_stat_bolt.{stdout,stderr}
```

Both streams are tee'd to the terminal and the log file simultaneously — no output is ever hidden.

**Key diagnostic commands:**

```bash
# See what BOLT actually changed
grep 'BOLT-INFO' autofdo_logs/step7_llvm_bolt.stderr

# Compare elapsed time
grep 'time elapsed' autofdo_logs/step8_perf_stat_baseline.stderr
grep 'time elapsed' autofdo_logs/step8_perf_stat_bolt.stderr

# See branch-miss reduction
grep 'branch-misses' autofdo_logs/step8_perf_stat_baseline.stderr
grep 'branch-misses' autofdo_logs/step8_perf_stat_bolt.stderr

# Check i-cache improvement (requires perf stat -d; step 8 uses it)
grep 'L1-icache' autofdo_logs/step8_perf_stat_baseline.stderr
grep 'L1-icache' autofdo_logs/step8_perf_stat_bolt.stderr
```

---

## Understanding verify.sh output

```
=== Binary Sizes ===
  Instrumented (.instr):           2.1 MiB   ← larger: counter arrays added
  PGO-optimised (.pgo):            1.8 MiB   ← smaller: dead code eliminated
  BOLT-optimised (.bolt):          1.9 MiB   ← slight increase: split sections

=== BOLT Transformation Statistics ===
  BOLT-INFO lines   : 47
  BOLT-WARNING lines: 0

  Key layout/transform entries:
    BOLT-INFO: enabling relocation mode       ← confirms -Wl,--emit-relocs worked
    BOLT-INFO: basic block reordering modified layout of 312 (18.4%) functions
    BOLT-INFO: ICF folded 104 functions in 2 passes.

=== Delta Table  (BOLT vs PGO baseline) ===
  CPU cycles          -11.2 %   negative = fewer cycles = faster
  Branch misses       -18.7 %   negative = better prediction
  L1-icache misses    -23.1 %   negative = better i-cache layout
  iTLB misses         -15.4 %   negative = tighter code footprint
  Elapsed time         -9.8 %   negative = faster wall-clock

  IPC (insns/cycle)    1.843       2.107     ← higher = more work per cycle

=== Verdict ===
  BOLT-optimised binary is: FASTER by 9.8% wall-clock time
```

**If icache/iTLB show 0:** `perf stat -d` is required in step 8 (the pipeline already uses it). On some CPUs the event names differ; run `perf list cache` to find the correct names.

**If "BOLT not in relocation mode":** The binary was not linked with `--emit-relocs`. The pipeline adds `-Wl,--emit-relocs` to all compile steps. If supplying a pre-built binary, relink it.

**If "NO SIGNIFICANT CHANGE":** The profiling workload was too short or unrepresentative. Try `PERF_RUNS=5` or use a workload that matches real usage patterns.

---

## make targets

```bash
make              # generate src/workload.c, build reference binary
make run          # run the full 8-step pipeline
make verify       # parse logs, print delta report
make lint         # shellcheck all .sh files (requires ShellCheck)
make clean        # remove autofdo_workdir/ (logs and src/ preserved)
make distclean    # remove autofdo_workdir/, autofdo_logs/, src/
```

Override variables:

```bash
make OPT_LEVEL=-O3 PERF_RUNS=5 run
make CC=clang-21 run
make SRC_DIR=~/myproject/src APP_NAME=myapp run
```

---

## perf_event_paranoid — fixing permission errors

Most Fedora 43 configurations block unprivileged perf access by default.

```bash
# Check current setting
cat /proc/sys/kernel/perf_event_paranoid   # default: 4

# Fix for current session only
sudo sysctl -w kernel.perf_event_paranoid=1

# Fix permanently (survives reboot)
echo 'kernel.perf_event_paranoid = 1' | sudo tee /etc/sysctl.d/99-perf.conf
sudo sysctl --system

# Then run without sudo
NO_SUDO_PERF=1 bash autofdo_full_capture.sh
```

The pipeline uses `sudo perf record` by default so you do not need to change `perf_event_paranoid` for normal use.

---

## VM / container usage

The pipeline auto-detects missing LBR support at startup:

```
[WARN] LBR branch sampling unavailable: branch sampling not supported
[WARN] Setting BOLT_NO_LBR=1 (non-LBR fallback; reduced gains).
```

In fallback mode, BOLT uses basic sample profiles instead of edge profiles. Gains are typically 1–5% instead of 5–20%, but the full pipeline still runs to completion.

To force fallback manually (skip the probe):

```bash
BOLT_NO_LBR=1 bash autofdo_full_capture.sh
```

---

## Pushing to GitHub

```bash
# Requires: gh auth login (already done once)
bash repo_push.sh
```

Pushes all repo files to `github.com/swipswaps/autofdo-fedora43-pipeline`.

---

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for all 15 documented failure cases with exact error messages, root causes, and fixes.

**Most common issues at a glance:**

| Symptom | Cause | Fix |
|---|---|---|
| `perf_event_open: Permission denied` | `perf_event_paranoid=4` | `sudo sysctl -w kernel.perf_event_paranoid=1` |
| `branch sampling not supported` | No LBR (VM/container) | Pipeline auto-sets `BOLT_NO_LBR=1` |
| `No *.c files found` | `src/` empty | `make` generates `src/workload.c` |
| `0 functions matched profile` | Binary rebuilt between steps 5–6 | Don't rebuild between perf and perf2bolt |
| `missing separator` (old Makefile) | Heredoc bug in make | Fixed: `gen_workload.py` used instead |

---

## References

- [LLVM BOLT README](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
- [LLVM BOLT – Optimizing Clang](https://github.com/llvm/llvm-project/blob/main/bolt/docs/OptimizingClang.md)
- [LLVM BOLT – Optimizing Linux kernel](https://github.com/llvm/llvm-project/blob/main/bolt/docs/OptimizingLinux.md)
- [Linux kernel AutoFDO documentation](https://docs.kernel.org/dev-tools/autofdo.html)
- [Clang PGO user guide](https://clang.llvm.org/docs/UsersManual.html#profile-guided-optimization)
- [Android AutoFDO – Phoronix](https://www.phoronix.com/news/Android-Using-Linux-AutoFDO)
