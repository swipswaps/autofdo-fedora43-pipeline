#!/usr/bin/env bash
# =============================================================================
# repo_push.sh
# Create GitHub repository and push all pipeline files
#
# Assumptions:
#   • git is installed
#   • GitHub CLI (gh) is installed and 'gh auth login' has been completed
#   • The following files exist in the current directory:
#       autofdo_full_capture.sh
#       verify.sh
#       Makefile
#       README.md
#       TROUBLESHOOTING.md
#       repo_push.sh          (this file)
#
# Usage:
#   bash repo_push.sh
#   REPO_NAME=my-custom-name bash repo_push.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# LOGGING HELPERS
# ---------------------------------------------------------------------------

log_info()  { printf '[INFO  %(%T)T] %s\n' -1 "$*" >&2; }
log_error() { printf '[ERROR %(%T)T] %s\n' -1 "$*" >&2; }

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

GITHUB_USER="swipswaps"
REPO_NAME="${REPO_NAME:-autofdo-fedora43-pipeline}"
REPO_DESC="Fedora 43 AutoFDO pipeline: Clang PGO + perf LBR + LLVM BOLT with full stdout/stderr capture"
DEFAULT_BRANCH="main"

# Files that must exist before we touch git.
REQUIRED_FILES=(
    autofdo_full_capture.sh
    verify.sh
    Makefile
    README.md
    TROUBLESHOOTING.md
    repo_push.sh
)

# ---------------------------------------------------------------------------
# GUARD: required tools
# ---------------------------------------------------------------------------

_check_tool() {
    command -v "$1" &>/dev/null || {
        log_error "Required tool not found: $1"
        log_error "  Install: $2"
        exit 1
    }
}

_check_tool git "sudo dnf install git"
_check_tool gh  "https://cli.github.com — sudo dnf install gh"

# ---------------------------------------------------------------------------
# GUARD: required files
# ---------------------------------------------------------------------------

log_info "Checking required files..."
_missing=0
for _f in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${_f}" ]]; then
        log_error "Missing required file: ${_f}"
        _missing=1
    fi
done
(( _missing == 0 )) || exit 1
log_info "All required files present."

# ---------------------------------------------------------------------------
# GUARD: gh auth
# ---------------------------------------------------------------------------

log_info "Verifying GitHub CLI authentication..."
if ! gh auth status &>/dev/null; then
    log_error "GitHub CLI is not authenticated."
    log_error "  Run: gh auth login"
    exit 1
fi
log_info "GitHub CLI authenticated."

# ---------------------------------------------------------------------------
# GIT INITIALISATION
# ---------------------------------------------------------------------------

# Only initialise if .git does not already exist.
if [[ ! -d ".git" ]]; then
    log_info "Initialising git repository (branch: ${DEFAULT_BRANCH})..."
    git init -b "${DEFAULT_BRANCH}"
else
    log_info "Existing .git directory found; skipping init."
fi

# ---------------------------------------------------------------------------
# .gitignore
# ---------------------------------------------------------------------------
# Prevent profiling artefacts (which can be gigabytes) from entering the repo.

log_info "Writing .gitignore..."
cat > .gitignore << 'EOF'
# Compiled object files
*.o
*.a
*.so

# LLVM instrumentation profiles
*.profraw
*.profdata

# perf data files  (can be multi-GB)
*.data
perf.*
perf.data*

# BOLT profiling
*.fdata

# Pipeline working directories
autofdo_workdir/
autofdo_logs/

# Editor temporaries
*~
*.swp
.DS_Store
EOF

# ---------------------------------------------------------------------------
# EXECUTABLE PERMISSIONS
# ---------------------------------------------------------------------------

log_info "Setting executable permissions..."
chmod +x autofdo_full_capture.sh verify.sh repo_push.sh

# ---------------------------------------------------------------------------
# STAGE AND COMMIT
# ---------------------------------------------------------------------------

log_info "Staging files..."
git add \
    autofdo_full_capture.sh \
    verify.sh \
    Makefile \
    README.md \
    TROUBLESHOOTING.md \
    repo_push.sh \
    .gitignore

# Only commit if there is something staged (idempotent re-runs skip this).
if git diff --cached --quiet; then
    log_info "Nothing to commit — working tree already clean."
else
    log_info "Creating initial commit..."
    git commit -m \
        "Initial commit: Fedora 43 AutoFDO pipeline (Clang PGO + perf LBR + LLVM BOLT)"
fi

# ---------------------------------------------------------------------------
# CREATE GITHUB REPOSITORY AND PUSH
# ---------------------------------------------------------------------------
# gh repo create with --source=. sets the remote and pushes in one step.
# If the repository already exists this command will fail; that is intentional
# (do not silently overwrite an existing repo).

log_info "Creating GitHub repository: ${GITHUB_USER}/${REPO_NAME}..."
gh repo create "${GITHUB_USER}/${REPO_NAME}" \
    --public \
    --description "${REPO_DESC}" \
    --source=. \
    --remote=origin \
    --push

# ---------------------------------------------------------------------------
# VERIFY
# ---------------------------------------------------------------------------

log_info "Verifying remote..."
git remote -v

log_info "Pipeline complete."
printf '\nRepository URL:\n  https://github.com/%s/%s\n' \
    "${GITHUB_USER}" "${REPO_NAME}"
