# =============================================================================
# Makefile
# AutoFDO pipeline – demo workload build and pipeline entry points
#
# Targets:
#   make            – generate src/workload.c and validate it compiles
#   make run        – run the full 8-step AutoFDO pipeline
#   make verify     – parse logs and print the before/after perf report
#   make lint       – shellcheck all .sh files
#   make clean      – remove WORKDIR artefacts (logs and src/ preserved)
#   make distclean  – remove WORKDIR, LOG_DIR, src/, and generated binaries
#
# Override on the command line:
#   make CC=clang-21 OPT_LEVEL=-O3 PERF_RUNS=5 run
# =============================================================================

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------
CC      := clang
# -O0: validate compilation only; pipeline uses OPT_LEVEL for the real builds
CFLAGS  := -O0 -gdwarf-4 -Wall -Wextra

# ---------------------------------------------------------------------------
# Paths  (must match autofdo_full_capture.sh defaults)
# ---------------------------------------------------------------------------
SRC_DIR      := src
WORKDIR      := autofdo_workdir
LOG_DIR      := autofdo_logs
APP_NAME     := my_app
WORKLOAD_SRC := $(SRC_DIR)/workload.c
REF_BINARY   := $(WORKDIR)/$(APP_NAME).ref

# ---------------------------------------------------------------------------
# Pipeline tunables  (forwarded to the script as environment variables)
# ---------------------------------------------------------------------------
OPT_LEVEL    ?= -O2
PERF_RUNS    ?= 3
EXTRA_CFLAGS ?=

# ---------------------------------------------------------------------------
# Default target
# ---------------------------------------------------------------------------
.PHONY: all
all: $(REF_BINARY)

# ---------------------------------------------------------------------------
# Workload source generation via gen_workload.py
# ---------------------------------------------------------------------------
# gen_workload.py is a standalone Python script that writes src/workload.c.
# It is called here as a single recipe command, which is the correct pattern
# for multi-line file generation in Makefiles (each recipe tab-line is a
# separate shell invocation; here-documents spanning lines do not work).
$(WORKLOAD_SRC): gen_workload.py
	python3 gen_workload.py $(WORKLOAD_SRC)

# ---------------------------------------------------------------------------
# Reference build  (validates source compiles before handing to pipeline)
# ---------------------------------------------------------------------------
$(REF_BINARY): $(WORKLOAD_SRC)
	@mkdir -p $(WORKDIR)
	$(CC) $(CFLAGS) -o $@ $<
	@echo "[make] Reference binary: $@"
	@echo "[make] Source compiles cleanly. Run 'make run' for the full pipeline."

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------
.PHONY: run
run: $(WORKLOAD_SRC)
	SRC_DIR=$(SRC_DIR)             \
	APP_NAME=$(APP_NAME)           \
	WORKDIR=$(WORKDIR)             \
	LOG_DIR=$(LOG_DIR)             \
	OPT_LEVEL='$(OPT_LEVEL)'      \
	PERF_RUNS=$(PERF_RUNS)         \
	EXTRA_CFLAGS='$(EXTRA_CFLAGS)' \
	bash autofdo_full_capture.sh

# ---------------------------------------------------------------------------
# Verification report
# ---------------------------------------------------------------------------
.PHONY: verify
verify:
	APP_NAME=$(APP_NAME) \
	WORKDIR=$(WORKDIR)   \
	LOG_DIR=$(LOG_DIR)   \
	bash verify.sh

# ---------------------------------------------------------------------------
# Lint
# ---------------------------------------------------------------------------
.PHONY: lint
lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "[make] shellcheck not found.  sudo dnf install ShellCheck"; exit 1; }
	shellcheck --severity=warning \
		--exclude=SC2086 \
		autofdo_full_capture.sh verify.sh repo_push.sh
# SC2086 excluded globally: OPT_LEVEL and EXTRA_CFLAGS are intentionally
# word-split to allow multi-word values like "-O3 -march=native".

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf $(WORKDIR)
	@echo "[make] Removed $(WORKDIR)  (logs and source preserved)"

.PHONY: distclean
distclean: clean
	rm -rf $(LOG_DIR) $(SRC_DIR)
	@echo "[make] Removed $(LOG_DIR), $(SRC_DIR)"

# ---------------------------------------------------------------------------
# Benchmark harness
# ---------------------------------------------------------------------------
.PHONY: bench-baseline bench-bolt bench-compare bench

bench-baseline: $(REF_BINARY)
	bash bench/benchmark_runner.sh $(WORKDIR)/$(APP_NAME).pgo baseline

bench-bolt:
	bash bench/benchmark_runner.sh $(WORKDIR)/$(APP_NAME).bolt bolt

bench-compare:
	python3 tools/compare_results.py \
		results/baseline.json results/bolt.json --print

bench: bench-baseline bench-bolt bench-compare

# ---------------------------------------------------------------------------
# Layout inspection
# ---------------------------------------------------------------------------
.PHONY: inspect
inspect:
	bash tools/inspect_layout.sh \
		$(WORKDIR)/$(APP_NAME).pgo \
		$(WORKDIR)/$(APP_NAME).bolt \
		$(WORKDIR)/perf.1.data
