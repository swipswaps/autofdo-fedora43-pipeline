# autofdo-fedora43-pipeline

Fedora 43 · Clang instrumentation PGO → perf LBR sampling → LLVM BOLT post-link optimisation  
Full stdout/stderr capture for every tool in the pipeline.

---

## Repository layout

```
.
├── autofdo_full_capture.sh   main pipeline (8 steps, full log capture)
├── verify.sh                 parse logs, print before/after delta report
├── Makefile                  build demo workload, wire make run/verify/lint
├── repo_push.sh              create GitHub repo and push (gh CLI)
├── TROUBLESHOOTING.md        15 failure cases with causes and fixes
└── README.md                 this file
```

---

## Optimisation pipeline

```
Source (*.c)
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 1  Clang instrumented build                           │
│          -fprofile-instr-generate -gdwarf-4 -Wl,--emit-relocs│
└──────────────────────┬──────────────────────────────────────┘
                       │  binary: my_app.instr
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 2  Workload run (profraw collection)                  │
│          LLVM_PROFILE_FILE=default-%p.profraw               │
└──────────────────────┬──────────────────────────────────────┘
                       │  files: default-<pid>.profraw
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 3  llvm-profdata merge                                │
│          .profraw → .profdata                               │
└──────────────────────┬──────────────────────────────────────┘
                       │  file: default.profdata
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 4  PGO-guided rebuild                                 │
│          -fprofile-instr-use -fprofile-correction           │
│          -gdwarf-4 -Wl,--emit-relocs                        │
└──────────────────────┬──────────────────────────────────────┘
                       │  binary: my_app.pgo
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 5  perf LBR branch-sampling                           │
│          perf record -e cycles:u -j any,u -F 2999 -N        │
│          (PERF_RUNS times, unique output per run)           │
│          auto-fallback to -nl when LBR is unavailable       │
└──────────────────────┬──────────────────────────────────────┘
                       │  files: perf.1.data … perf.N.data
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 6  perf2bolt  +  merge-fdata                          │
│          perf.data → perf.N.fdata (per run)                 │
│          merge-fdata -o → perf.merged.fdata                 │
└──────────────────────┬──────────────────────────────────────┘
                       │  file: perf.merged.fdata
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 7  llvm-bolt                                          │
│          -reorder-blocks=ext-tsp                            │
│          -reorder-functions=cdsort                          │
│          -split-functions -split-all-cold -split-eh         │
│          -icf=1 -use-gnu-stack -dyno-stats -v               │
└──────────────────────┬──────────────────────────────────────┘
                       │  binary: my_app.bolt
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  STEP 8  perf stat -d --repeat 5                            │
│          PGO baseline vs BOLT binary                        │
│          captures: cycles, instructions, branch-misses,     │
│          L1-icache-load-misses, iTLB-load-misses, LLC-misses│
└─────────────────────────────────────────────────────────────┘
                               ↓
                          bash verify.sh
```

---

## Why this pipeline exceeds AutoFDO alone

Android's AutoFDO performs sampling-guided compilation.  This pipeline adds three stacked layers:

| Layer | Tool | What it does |
|---|---|---|
| 1 | Clang instrumentation PGO | Counter-exact branch and call frequency data |
| 2 | perf LBR sampling | Real taken-branch edge profiles for BOLT |
| 3 | LLVM BOLT | Physical binary rewrite for i-cache and iTLB locality |

Each layer addresses a different bottleneck.  Combining all three consistently achieves larger improvements than AutoFDO alone.

---

## Prerequisites

```bash
sudo dnf install clang llvm llvm-bolt perf
```

`perf2bolt` and `merge-fdata` are included in the `llvm-bolt` package on Fedora 43.

### LBR hardware requirement

| Platform | Requirement |
|---|---|
| Intel | Haswell or later (most machines since ~2013) |
| AMD Zen 3 | BRS feature (`grep brs /proc/cpuinfo`) |
| AMD Zen 4 | `amd_lbr_v2` feature (`grep amd_lbr_v2 /proc/cpuinfo`) |
| VM / container | LBR **not** available — pipeline auto-detects and falls back |

When LBR is unavailable the pipeline automatically sets `BOLT_NO_LBR=1` and calls `perf2bolt -nl`.  Optimisation gains are smaller but the pipeline still completes.

---

## Quick start

```bash
# 1. Clone the repository
git clone https://github.com/swipswaps/autofdo-fedora43-pipeline
cd autofdo-fedora43-pipeline

# 2. Generate the demo workload and validate it compiles
make

# 3. Run the full 8-step pipeline
make run

# 4. View the before/after performance report
make verify
```

### Custom source tree

```bash
SRC_DIR=/path/to/myproject/src \
APP_NAME=myapp \
WORKDIR=/tmp/autofdo \
LOG_DIR=/tmp/autofdo_logs \
bash autofdo_full_capture.sh
```

---

## Tunable environment variables

| Variable | Default | Description |
|---|---|---|
| `SRC_DIR` | `./src` | Directory containing `*.c` source files |
| `APP_NAME` | `my_app` | Output binary base name |
| `WORKDIR` | `./autofdo_workdir` | PGO / BOLT artefacts |
| `LOG_DIR` | `./autofdo_logs` | Per-step stdout + stderr logs |
| `PERF_RUNS` | `3` | Number of LBR sampling runs |
| `PERF_FREQ` | `2999` | perf sampling frequency (Hz) |
| `OPT_LEVEL` | `-O2` | Clang optimisation flag |
| `EXTRA_CFLAGS` | _(empty)_ | Appended to every `clang` invocation |
| `NO_SUDO_PERF` | `0` | Set to `1` if `perf_event_paranoid` ≤ 1 |
| `BOLT_NO_LBR` | `0` | Set to `1` to force non-LBR fallback |

---

## Log layout

Every step writes two files:

```
autofdo_logs/
  step1_build_instr.{stdout,stderr}      ← clang warnings/errors
  step2_profiling_run.{stdout,stderr}    ← application output
  step3_profdata_merge.{stdout,stderr}
  step4_build_pgo.{stdout,stderr}        ← PGO feedback messages
  step5_perf_run_N.{stdout,stderr}       ← perf verbose output
  step6_perf2bolt_N.{stdout,stderr}      ← symbol resolution
  step6_merge_fdata.{stdout,stderr}
  step7_llvm_bolt.{stdout,stderr}        ← BOLT-INFO / BOLT-WARNING
  step8_perf_stat_baseline.{stdout,stderr}
  step8_perf_stat_bolt.{stdout,stderr}
```

All streams are tee'd to both terminal and log file simultaneously so no diagnostic output is ever hidden.

**Inspect BOLT transformation statistics:**
```bash
grep 'BOLT-INFO' autofdo_logs/step7_llvm_bolt.stderr
```

**Compare elapsed time:**
```bash
grep 'time elapsed' autofdo_logs/step8_perf_stat_baseline.stderr
grep 'time elapsed' autofdo_logs/step8_perf_stat_bolt.stderr
```

---

## Pushing to GitHub

```bash
bash repo_push.sh
```

Requires `gh auth login` to have been completed.  Pushes all six repo files to `github.com/swipswaps/autofdo-fedora43-pipeline`.

---

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for all 15 documented failure modes with exact error messages, root causes, and fixes.

The most common failure is LBR unavailability (virtual machines and containers).  The pipeline detects this automatically and falls back gracefully.

---

## References

- [LLVM BOLT README](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
- [LLVM BOLT – Optimizing Clang](https://github.com/llvm/llvm-project/blob/main/bolt/docs/OptimizingClang.md)
- [LLVM BOLT – Optimizing Linux kernel](https://github.com/llvm/llvm-project/blob/main/bolt/docs/OptimizingLinux.md)
- [Linux kernel AutoFDO documentation](https://docs.kernel.org/dev-tools/autofdo.html)
- [Clang sampling PGO user guide](https://clang.llvm.org/docs/UsersManual.html#profile-guided-optimization)
- [Android AutoFDO – Phoronix](https://www.phoronix.com/news/Android-Using-Linux-AutoFDO)
