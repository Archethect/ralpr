#!/usr/bin/env bash
# common.sh - Shared functions for Ralpr 2.0 scripts
# Usage: source "$(dirname "$0")/lib/common.sh"

set -euo pipefail

# Colors for output (only if terminal supports it)
if [[ -t 2 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  NC='\033[0m' # No Color
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  NC=''
fi

# Log to stderr (human-readable)
log_info() {
  echo -e "${GREEN}[INFO]${NC} $*" >&2
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_phase() {
  echo -e "${CYAN}[PHASE]${NC} $*" >&2
}

log_debug() {
  if [[ "${RALPR_DEBUG:-false}" == "true" ]]; then
    echo -e "${BLUE}[DEBUG]${NC} $*" >&2
  fi
}

# Output RALPR_RESULT JSON to stdout (machine-readable)
# Usage: ralpr_result '{"status":"ok","value":42}'
ralpr_result() {
  echo "RALPR_RESULT: $1"
}

# Get repo owner from GitHub
get_owner() {
  gh repo view --json owner --jq '.owner.login'
}

# Get repo name from GitHub
get_repo() {
  gh repo view --json name --jq '.name'
}

# Get owner/repo in one call
get_owner_repo() {
  gh repo view --json nameWithOwner --jq '.nameWithOwner'
}

# Check if gh CLI is authenticated
check_gh_auth() {
  if ! gh auth status &>/dev/null; then
    log_error "GitHub CLI not authenticated"
    log_error "Run: gh auth login"
    return 1
  fi
}

# Check if git working directory is clean
check_git_clean() {
  if [[ -n "$(git status --porcelain)" ]]; then
    log_error "Working directory not clean"
    log_error "Commit or stash changes first"
    return 1
  fi
}

# Get the default branch from GitHub API
get_default_branch() {
  gh api repos/:owner/:repo --jq '.default_branch'
}

# Get the branch to base features on (configurable override)
get_base_branch() {
  if [[ -n "${RALPR_BASE_BRANCH:-}" ]]; then
    echo "$RALPR_BASE_BRANCH"
    return
  fi
  get_default_branch
}

# Get current branch name
get_current_branch() {
  git branch --show-current
}

# Get the script directory (where ralpr is located)
get_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# Get plugin root directory
get_plugin_dir() {
  local script_dir
  script_dir=$(get_script_dir)
  echo "${script_dir%/scripts/lib}"
}

# Check if a label exists on the repo (returns 0 if exists, 1 if not)
label_exists() {
  local label="$1"
  gh label list --json name --jq ".[].name" | grep -qx "$label"
}

# Create label if it doesn't exist
ensure_label() {
  local label="$1"
  local color="${2:-0366d6}"
  local description="${3:-}"

  if ! label_exists "$label"; then
    log_info "Creating label: $label"
    gh label create "$label" --color "$color" --description "$description" 2>/dev/null || true
  fi
}

# Slugify a string for branch names
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 30
}

# Parse RALPR_RESULT from command output
# Usage: result=$(run_ralpr_command | parse_ralpr_result)
parse_ralpr_result() {
  grep "^RALPR_RESULT:" | sed 's/^RALPR_RESULT: //'
}

# Extract field from JSON
# Usage: value=$(echo "$json" | json_field "status")
json_field() {
  local field="$1"
  jq -r ".$field // empty"
}

# Get PR number from URL or current branch
get_pr_number() {
  local pr_num="${1:-}"

  if [[ -n "$pr_num" ]]; then
    echo "$pr_num"
    return
  fi

  # Try to get from current branch
  local branch
  branch=$(get_current_branch)
  gh pr view "$branch" --json number --jq '.number' 2>/dev/null || echo ""
}

# Check if running in a worktree
is_worktree() {
  [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] && \
  [[ -f "$(git rev-parse --git-dir)/commondir" ]]
}

# Get main repo path from worktree
get_main_repo() {
  if is_worktree; then
    git rev-parse --path-format=absolute --git-common-dir | sed 's/\/.git$//'
  else
    git rev-parse --show-toplevel
  fi
}

# Validate JSON against expected fields
# Usage: validate_json "$json" "status" "confidence"
validate_json() {
  local json="$1"
  shift

  for field in "$@"; do
    if ! echo "$json" | jq -e ".$field" > /dev/null 2>&1; then
      log_error "Missing required field: $field"
      return 1
    fi
  done
}

# Safe arithmetic that handles empty values
safe_add() {
  local a="${1:-0}"
  local b="${2:-0}"
  echo $((a + b))
}

# Calculate percentage
percentage() {
  local part="${1:-0}"
  local total="${2:-1}"

  if [[ "$total" -eq 0 ]]; then
    echo "0"
    return
  fi

  echo "scale=0; ($part * 100) / $total" | bc
}

# Format timestamp for logging
timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

# Retry a command with exponential backoff
# Usage: retry 3 5 command args...
retry() {
  local max_attempts="$1"
  local delay="$2"
  shift 2

  local attempt=1
  while [[ $attempt -le $max_attempts ]]; do
    if "$@"; then
      return 0
    fi

    log_warn "Attempt $attempt failed, retrying in ${delay}s..."
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done

  log_error "Command failed after $max_attempts attempts"
  return 1
}

# Load a prompt template and substitute variables
# Usage: load_prompt "review-iteration-prompt" ITERATION=1 PR_NUMBER=123 ...
# Template files use {{VAR}} placeholders
load_prompt() {
  local template_name="$1"
  shift

  # Get the lib directory (where this file is located)
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local template_file="${lib_dir}/../templates/${template_name}.md"

  if [[ ! -f "$template_file" ]]; then
    log_error "Template not found: $template_file"
    return 1
  fi

  local content
  content=$(cat "$template_file")

  # Substitute each VAR=value argument
  for arg in "$@"; do
    local var="${arg%%=*}"
    local value="${arg#*=}"
    content="${content//\{\{$var\}\}/$value}"
  done

  echo "$content"
}
