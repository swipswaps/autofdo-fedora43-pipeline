# TROUBLESHOOTING

Operational failure analysis for the AutoFDO pipeline.  
Each entry covers: the component, the exact error, the root cause, and the fix.

---

## Failure 1 — Required tools not installed

**Component:** All pipeline steps  
**Error:**
```
bash: clang: command not found
bash: llvm-bolt: command not found
bash: perf: command not found
```
**Cause:** Required packages are missing.  
**Fix:**
```bash
sudo dnf install clang llvm llvm-bolt perf
```
`perf2bolt` and `merge-fdata` are installed by the `llvm-bolt` package.

---

## Failure 2 — perf permission denied

**Component:** Step 5 (`perf record`)  
**Error:**
```
perf_event_open(...): Permission denied
You may not have permission to collect stats.
```
**Cause:** Fedora's default `perf_event_paranoid=4` blocks unprivileged hardware counter access.  
**Fix (persistent until reboot):**
```bash
sudo sysctl -w kernel.perf_event_paranoid=1
```
**Fix (permanent across reboots):**
```bash
echo 'kernel.perf_event_paranoid = 1' | sudo tee /etc/sysctl.d/99-perf.conf
sudo sysctl --system
```
Alternatively, run the pipeline with `NO_SUDO_PERF=0` (the default) so `perf record` runs under `sudo`.

---

## Failure 3 — CPU does not support LBR

**Component:** Step 5 (`perf record -j any,u`)  
**Error:**
```
branch sampling not supported
```
or
```
PMU hardware doesn't support sampling/overflow-interrupts
```
**Cause:** Last Branch Records are not available.  Common environments:
- Virtual machines (VMware, VirtualBox, QEMU without PMU passthrough)
- Cloud VMs (AWS, GCP, Azure) without bare-metal instances
- Older CPUs (pre-Haswell Intel, AMD Zen 2 and earlier without BRS)
- Some ARM boards

**Fix:** Set `BOLT_NO_LBR=1` before running the pipeline.  The script detects this automatically via a zero-duration probe; you can also set it manually:
```bash
BOLT_NO_LBR=1 bash autofdo_full_capture.sh
```
`perf2bolt` is then called with `-nl` and BOLT operates on basic sample profiles.  Optimisation gains are smaller (typically 1–5% vs 5–20% with LBR) but the pipeline completes correctly.

To check AMD LBR support:
```bash
grep -E 'brs|amd_lbr_v2' /proc/cpuinfo
# Zen3: brs present
# Zen4: amd_lbr_v2 present
```

---

## Failure 4 — Source directory empty

**Component:** Step 1 (`clang` invocation)  
**Error:**
```
clang: error: no input files
```
or the script exits with:
```
[ERROR] No *.c files found under ./src
```
**Cause:** `src/` does not exist or contains no `.c` files.  
**Fix:**
```bash
make       # generates src/workload.c and validates compilation
make run   # then run the full pipeline
```

---

## Failure 5 — Program crashes during instrumented profiling run

**Component:** Step 2 (instrumented binary execution)  
**Error:**
```
Segmentation fault (core dumped)
```
**Cause:** Instrumentation PGO exposes latent undefined behaviour in the application.  The most common sources are:
- Stack buffer overflows (bounds not checked)
- Race conditions in multi-threaded code
- Use of uninitialised variables
- Use-after-free

The pipeline itself is not at fault.  
**Fix:** Debug the application with:
```bash
clang -O0 -fsanitize=address,undefined -gdwarf-4 -o my_app.debug src/*.c
./my_app.debug
```
Address and UB sanitisers will identify the exact crash site.

---

## Failure 6 — No profile files generated after instrumented run

**Component:** Step 3 (`llvm-profdata merge`)  
**Error:**
```
error: no profile input files
```
or the script exits with:
```
[ERROR] No .profraw files found after instrumented run.
```
**Cause:** The instrumented binary exited before LLVM's atexit handler wrote the profile.  Common causes:
- Binary called `_exit()` directly (bypasses atexit)
- Binary crashed (see Failure 5)
- `LLVM_PROFILE_FILE` environment variable not propagated (fixed in the pipeline; `run_logged` sets it inline)
- Binary was compiled without `compiler-rt` (unusual with the clang driver)

**Check:**
```bash
cat autofdo_logs/step2_profiling_run.stderr
```

---

## Failure 7 — BOLT cannot read debug information

**Component:** Step 7 (`llvm-bolt`)  
**Error:**
```
BOLT-WARNING: cannot find debug information
```
**Cause:** Binary compiled without debug metadata, or with DWARF v5 which BOLT's `-update-debug-sections` does not fully support as of LLVM 19.  
**Fix:** The pipeline explicitly uses `-gdwarf-4` in steps 1 and 4.  If you supply a pre-compiled binary, recompile it with:
```bash
clang -O2 -gdwarf-4 -Wl,--emit-relocs -o my_app src/*.c
```

---

## Failure 8 — perf2bolt fails to resolve symbols

**Component:** Step 6 (`perf2bolt`)  
**Error:**
```
BOLT-WARNING: failed to map profile
BOLT-WARNING: 0 out of N functions in the binary matched the profile
```
**Cause:** The binary passed to `perf2bolt` does not match the binary that was running when `perf record` collected data.  Build ID is checked.  Common causes:
- Binary was rebuilt between step 5 (perf collection) and step 6 (conversion)
- Binary was stripped (`strip -s`) — BOLT requires the symbol table
- PIE address relocation mismatch

**Fix:** Never rebuild or strip the binary between steps 5 and 6.  The pipeline guarantees this by using the same `${PGO_BINARY}` path throughout.  
`strip -g` (remove debug symbols only) is safe; `strip -s` (remove all symbols) is not.

---

## Failure 9 — merge-fdata finds no input files

**Component:** Step 6 (`merge-fdata`)  
**Error:**
```
merge-fdata: no input files
```
**Cause:** `perf2bolt` failed earlier in the loop, producing no `.fdata` files.  
**Fix:** Check each `step6_perf2bolt_N.stderr` log:
```bash
cat autofdo_logs/step6_perf2bolt_1.stderr
```
Resolve the underlying `perf2bolt` failure (see Failure 8 above), then re-run.

---

## Failure 10 — BOLT warns about DWARF v5

**Component:** Step 7 (`llvm-bolt -update-debug-sections`)  
**Error:**
```
BOLT-WARNING: DWARF v5 debug info is not fully supported
```
**Cause:** Default Clang 17+ emits DWARF v5 unless told otherwise.  BOLT's debug-section update logic for v5 is incomplete as of LLVM 19.  
**Fix:** The pipeline forces `-gdwarf-4` in all compile steps.  If building externally, pass `-gdwarf-4` to clang.  Note that BOLT still produces a correct, optimised binary — only `-update-debug-sections` is affected.

---

## Failure 11 — Optimisation gains are minimal or zero

**Component:** `verify.sh` verdict  
**Symptom:**
```
BOLT-WARNING: profile too sparse
```
or verify.sh reports `NO SIGNIFICANT CHANGE`.  
**Cause:** The profiling workload was not representative.  BOLT only moves code it has observed executing; unexercised functions are left in place.  Common causes:
- Workload is too short (runs for < 1 second)
- Workload does not exercise the hot path
- Too few `PERF_RUNS` for statistical convergence

**Fix:**
- Increase `PERF_RUNS=5` or higher
- Use a workload that matches real usage patterns
- For the demo workload, `make` generates a 4M × 8 sort benchmark which is sufficient

---

## Failure 12 — perf sampling frequency rejected

**Component:** Step 5 (`perf record -F 2999`)  
**Error:**
```
invalid sampling frequency
```
or silently clamps the frequency.  
**Cause:** The kernel limits the maximum sampling frequency.  
**Check:**
```bash
cat /proc/sys/kernel/perf_event_max_sample_rate   # typically 100000
```
**Fix:** Lower `PERF_FREQ` to a value below the kernel limit:
```bash
PERF_FREQ=1000 bash autofdo_full_capture.sh
```
Or raise the limit (takes effect until reboot):
```bash
sudo sysctl -w kernel.perf_event_max_sample_rate=50000
```

---

## Failure 13 — Pipeline running in a container

**Component:** Step 5 (`perf record`)  
**Symptom:** `perf record` fails entirely or produces empty data.  
**Cause:** Containers lack access to hardware performance counters by default.  `perf_event_open(2)` is blocked by the container seccomp policy.  
**Fix (Docker):**
```bash
docker run --cap-add=SYS_ADMIN --security-opt seccomp=unconfined ...
```
Or set `BOLT_NO_LBR=1` to fall back to software-only profiling and skip the hardware PMU entirely.

---

## Failure 14 — sudo prompt breaks unattended automation

**Component:** Step 5 (`sudo perf record`)  
**Symptom:** Script hangs waiting for a password, or fails with:
```
sudo: a password is required
```
**Cause:** The pipeline uses `sudo` for `perf record` to access hardware counters.  
**Fixes (choose one):**

Option A — relax `perf_event_paranoid` so `perf` works without sudo:
```bash
sudo sysctl -w kernel.perf_event_paranoid=1
NO_SUDO_PERF=1 bash autofdo_full_capture.sh
```

Option B — grant passwordless sudo for `perf` only:
```bash
# Add to /etc/sudoers.d/perf (replace 'youruser')
youruser ALL=(ALL) NOPASSWD: /usr/bin/perf
```

Option C — non-LBR fallback (no sudo needed):
```bash
BOLT_NO_LBR=1 NO_SUDO_PERF=1 bash autofdo_full_capture.sh
```

---

## Failure 15 — BOLT unsupported relocation type

**Component:** Step 7 (`llvm-bolt`)  
**Error:**
```
BOLT-WARNING: unsupported relocation type
BOLT-WARNING: disabling relocation mode
```
**Cause:** The binary was linked without `--emit-relocs`.  Without ELF relocations BOLT falls back to a restricted mode where it can only reorder code within functions, not move whole functions.  Gains are reduced.  
**Fix:** The pipeline passes `-Wl,--emit-relocs` in both steps 1 and 4.  If building externally:
```bash
clang -O2 -gdwarf-4 -Wl,--emit-relocs -o my_app src/*.c
```
Verify relocations are present:
```bash
readelf -S my_app | grep rela.text
```

---

## Most common failure in practice

The single most frequent failure is:

> **perf branch sampling unavailable** (Failure 3)

because the machine is a VM, cloud instance, or container.

**Quick check:**
```bash
perf record -e cycles:u -j any,u -o /dev/null -- true 2>&1
```
If this returns an error, set `BOLT_NO_LBR=1`.

---

## Diagnostic quick-reference

```bash
# Check all BOLT warnings
grep 'BOLT-WARNING' autofdo_logs/step7_llvm_bolt.stderr

# Check perf2bolt symbol resolution
grep 'matched' autofdo_logs/step6_perf2bolt_1.stderr

# Check elapsed time before/after
grep 'time elapsed' autofdo_logs/step8_perf_stat_baseline.stderr
grep 'time elapsed' autofdo_logs/step8_perf_stat_bolt.stderr

# Check kernel limits
cat /proc/sys/kernel/perf_event_paranoid
cat /proc/sys/kernel/perf_event_max_sample_rate

# Verify LBR availability
perf record -e cycles:u -j any,u -o /dev/null -- true 2>&1
```
