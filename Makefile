# =============================================================================
# Makefile
# AutoFDO pipeline – demo workload build and pipeline entry points
#
# Targets:
#   make              – generate src/workload.c and validate it compiles
#   make run          – run the full 8-step AutoFDO pipeline
#   make verify       – parse logs and print the before/after perf report
#   make lint         – shellcheck all .sh files
#   make clean        – remove WORKDIR artefacts (preserves logs and src/)
#   make distclean    – remove WORKDIR, LOG_DIR, and src/
#
# Override variables on the command line:
#   make CC=clang-21 OPT_LEVEL=-O3 PERF_RUNS=5 run
# =============================================================================

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------
CC        := clang
# Reference build uses -O0 so we can verify the source compiles without
# the pipeline's optimisation flags.
CFLAGS    := -O0 -gdwarf-4 -Wall -Wextra

# ---------------------------------------------------------------------------
# Paths  (must match autofdo_full_capture.sh defaults)
# ---------------------------------------------------------------------------
SRC_DIR  := src
WORKDIR  := autofdo_workdir
LOG_DIR  := autofdo_logs

APP_NAME       := my_app
WORKLOAD_SRC   := $(SRC_DIR)/workload.c
REF_BINARY     := $(WORKDIR)/$(APP_NAME).ref

# ---------------------------------------------------------------------------
# Pipeline tunables  (forwarded as environment variables to the script)
# ---------------------------------------------------------------------------
OPT_LEVEL  ?= -O2
PERF_RUNS  ?= 3
EXTRA_CFLAGS ?=

# ---------------------------------------------------------------------------
# Default target: generate workload source and build reference binary
# ---------------------------------------------------------------------------
.PHONY: all
all: $(REF_BINARY)

# ---------------------------------------------------------------------------
# Workload source generation
# ---------------------------------------------------------------------------
# Writes a branch-heavy iterative merge-sort benchmark that:
#   • sorts N=4,000,000 integers per iteration
#   • repeats REPEATS=8 times with different seeds
#   • writes elapsed time to stdout (parseable by perf stat)
#   • is large enough to produce a statistically useful LBR profile
#
# The file is generated once; distclean removes it.

$(WORKLOAD_SRC):
	@mkdir -p $(SRC_DIR)
	@cat > $@ << 'CSRC'
/* Auto-generated benchmark workload for AutoFDO pipeline testing.        */
/* Iterative merge-sort over 4 M integers, 8 repetitions.                 */
/* Branch-heavy and cache-sensitive: good for LBR + BOLT profiling.       */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define NELEMS   4000000U
#define REPEATS  8U

/* Merge src[l..m) and src[m..r) into src[l..r) using tmp as scratch. */
static void merge(int *restrict a, int *restrict tmp,
                  size_t l, size_t m, size_t r)
{
    size_t i = l, j = m, k = l;
    while (i < m && j < r)
        tmp[k++] = (a[i] <= a[j]) ? a[i++] : a[j++];
    while (i < m) tmp[k++] = a[i++];
    while (j < r) tmp[k++] = a[j++];
    memcpy(a + l, tmp + l, (r - l) * sizeof(int));
}

/* Bottom-up iterative merge-sort. */
static void mergesort(int *restrict a, int *restrict tmp, size_t n)
{
    for (size_t w = 1; w < n; w *= 2)
        for (size_t l = 0; l < n; l += 2 * w)
            merge(a, tmp, l,
                  (l + w     < n) ? l + w     : n,
                  (l + 2 * w < n) ? l + 2 * w : n);
}

int main(void)
{
    int *data = malloc(NELEMS * sizeof(int));
    int *tmp  = malloc(NELEMS * sizeof(int));
    if (!data || !tmp) {
        fputs("OOM\n", stderr);
        free(data); free(tmp);
        return 1;
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    for (unsigned r = 0; r < REPEATS; r++) {
        /* Use a different seed each pass to avoid branch-predictor saturation
         * on an already-sorted array. */
        srand(r * 0x9e3779b9u);
        for (size_t i = 0; i < NELEMS; i++)
            data[i] = rand();
        mergesort(data, tmp, NELEMS);
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);

    double sec = (double)(t1.tv_sec  - t0.tv_sec)
               + (double)(t1.tv_nsec - t0.tv_nsec) * 1e-9;
    printf("elapsed: %.3f s\n", sec);

    free(data);
    free(tmp);
    return 0;
}
CSRC
	@echo "[make] Generated $(WORKLOAD_SRC)"

# ---------------------------------------------------------------------------
# Reference build  (validates the source compiles before handing to pipeline)
# ---------------------------------------------------------------------------
$(REF_BINARY): $(WORKLOAD_SRC)
	@mkdir -p $(WORKDIR)
	$(CC) $(CFLAGS) -o $@ $<
	@echo "[make] Reference binary: $@  (plain build, no PGO/BOLT)"
	@echo "[make] Run 'make run' to execute the full pipeline."

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------
.PHONY: run
run: $(WORKLOAD_SRC)
	SRC_DIR=$(SRC_DIR)         \
	APP_NAME=$(APP_NAME)       \
	WORKDIR=$(WORKDIR)         \
	LOG_DIR=$(LOG_DIR)         \
	OPT_LEVEL='$(OPT_LEVEL)'  \
	PERF_RUNS=$(PERF_RUNS)     \
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
	shellcheck \
	    --severity=warning \
	    --exclude=SC2086 \
	    autofdo_full_capture.sh verify.sh repo_push.sh

# SC2086 is excluded globally because OPT_LEVEL and EXTRA_CFLAGS are
# intentionally word-split to allow multi-word values like "-O3 -march=native".

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
	@echo "[make] Removed $(LOG_DIR) and $(SRC_DIR)"
