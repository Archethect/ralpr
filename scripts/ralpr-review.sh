#!/usr/bin/env bash
# ralpr-review.sh - Phase 2: Review
# Single iteration with confidence scoring. Target: 90%
#
# Usage:
#   ralpr-review.sh --pr 123

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/github-labels.sh"
source "$SCRIPT_DIR/lib/quality-gates.sh"
source "$SCRIPT_DIR/lib/ci-watcher.sh"
source "$SCRIPT_DIR/lib/confidence.sh"

# Load config
source "$SCRIPT_DIR/../config/ralpr.config.sh"

# ============================================================================
# GLOBALS
# ============================================================================

PR_NUMBER=""
DRY_RUN=false
WORKING_DIR="."
WORKTREE_BASE=".worktrees"
WORKTREE_PATH=""

# ============================================================================
# AUTO-SELECTION
# ============================================================================

# Select PR ready for review phase
# Filters: has ralpr:impl:done, review confidence < REVIEW_THRESHOLD (or none), unassigned
select_review_pr() {
  log_info "Auto-selecting PR for review..."

  # Find PRs with ralpr:impl:done label, unassigned, where review confidence < threshold
  local selected=""
  while IFS= read -r pr_json; do
    [[ -z "$pr_json" ]] && continue
    local pr_num review_conf
    pr_num=$(echo "$pr_json" | jq -r '.number')

    # Extract review confidence from labels (0 if no review label)
    review_conf=$(echo "$pr_json" | jq -r '
      [.labels[].name | select(test("^ralpr:review:[0-9]+$"))] |
      if length > 0 then .[0] | split(":")[2] | tonumber else 0 end
    ')

    if [[ "$review_conf" -lt "$REVIEW_THRESHOLD" ]]; then
      selected="$pr_num"
      break
    fi
  done < <(gh pr list --state open --label "ralpr:impl:done" \
    --json number,title,labels,assignees,createdAt \
    --jq '[.[] | select(.assignees | length == 0)] | sort_by(.createdAt) | .[]' 2>/dev/null)

  if [[ -z "$selected" ]]; then
    log_info "No PRs with ralpr:impl:done label needing review found"
    return 1
  fi

  PR_NUMBER="$selected"
  log_info "Selected PR #$PR_NUMBER for review"
  return 0
}

# ============================================================================
# REVIEW PHASE - SINGLE ITERATION
# ============================================================================

run_review_phase() {
  log_phase "Starting Review Phase for PR #$PR_NUMBER"

  # Validate PR exists
  if ! gh pr view "$PR_NUMBER" --json number > /dev/null 2>&1; then
    log_error "PR #$PR_NUMBER not found"
    return 1
  fi

  # Get PR branch
  local branch
  branch=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName')
  log_info "PR branch: $branch"

  # Get base branch
  local base_branch
  base_branch=$(gh pr view "$PR_NUMBER" --json baseRefName --jq '.baseRefName')

  # Set up worktree path
  WORKTREE_PATH="$WORKTREE_BASE/review-pr-$PR_NUMBER"

  # Get current iteration for display (don't increment in dry-run)
  local current_iter
  current_iter=$(get_review_iteration "$PR_NUMBER")
  local next_iter=$((current_iter + 1))

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would run review phase"
    log_info "  PR: #$PR_NUMBER"
    log_info "  Branch: $branch"
    log_info "  Base: $base_branch"
    log_info "  Iteration: $current_iter -> $next_iter"
    log_info "  Worktree: $WORKTREE_PATH"
    ralpr_result '{"status":"dry_run","phase":"review","pr_number":'"$PR_NUMBER"',"iteration":'"$next_iter"',"worktree_path":"'"$WORKTREE_PATH"'"}'
    return 0
  fi

  # Create worktree for isolation
  mkdir -p "$WORKTREE_BASE"

  if git worktree list | grep -q "$WORKTREE_PATH"; then
    log_warn "Worktree already exists at $WORKTREE_PATH, removing it first..."
    git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
  fi

  log_info "Fetching PR branch from origin..."
  git fetch origin "$branch"

  log_info "Creating worktree at $WORKTREE_PATH..."
  if ! git worktree add "$WORKTREE_PATH" "$branch"; then
    log_error "Failed to create worktree"
    ralpr_result '{"status":"error","code":"worktree_fail","message":"Failed to create worktree"}'
    return 1
  fi

  # Pull latest changes from remote
  log_info "Pulling latest changes from remote..."
  (cd "$WORKTREE_PATH" && git pull origin "$branch")

  # Install dependencies in worktree
  log_info "Installing dependencies in worktree..."
  if [[ -f "$WORKTREE_PATH/package.json" ]]; then
    (cd "$WORKTREE_PATH" && npm install)
  fi

  # Track iteration (increment from current)
  local iteration
  iteration=$(increment_review_iteration "$PR_NUMBER")

  # The actual review workflow is driven by the Claude agent following SKILL.md
  # This script just prepares the environment and outputs context for the agent

  local owner_repo
  owner_repo=$(get_owner_repo)

  # Output context for the agent to use
  log_info "Review phase context:"
  log_info "  PR: #$PR_NUMBER"
  log_info "  Repository: $owner_repo"
  log_info "  Branch: $branch"
  log_info "  Base: $base_branch"
  log_info "  Iteration: $iteration"
  log_info "  Worktree: $WORKTREE_PATH"
  log_info ""
  log_info "IMPORTANT: When done, clean up with:"
  log_info "  git worktree remove $WORKTREE_PATH --force"

  # Output the setup result for the agent
  ralpr_result "{\"status\":\"ready\",\"phase\":\"review\",\"pr_number\":$PR_NUMBER,\"branch\":\"$branch\",\"base_branch\":\"$base_branch\",\"repo\":\"$owner_repo\",\"iteration\":$iteration,\"worktree_path\":\"$WORKTREE_PATH\",\"working_dir\":\"$WORKTREE_PATH\"}"
}

# ============================================================================
# CLI
# ============================================================================

show_help() {
  cat << 'EOF'
ralpr-review.sh - Phase 2: Review (Single Iteration)

Usage:
  ralpr-review.sh [options]

Options:
  --pr N              PR number to review (or auto-select)
  --worktree-base D   Base directory for worktrees (default: .worktrees)
  --dry-run           Preview without changes

Workflow:
  1. Create worktree at .worktrees/review-pr-<N>
  2. Install dependencies (npm install)
  3. Understand PR changes (spawn understand-agent)
  4. Run 3 reviewers in parallel:
     - QA reviewer (tests, edge cases)
     - Domain expert (architecture, security)
     - Codex reviewer (code quality)
  5. Aggregate issues (dedupe by file:line)
  6. Apply high-confidence fixes
  7. Run quality gates
  8. Push and wait for CI
  9. Calculate confidence score
  10. Set PR label with confidence

Cleanup (REQUIRED):
  When done, always remove the worktree:
    git worktree remove .worktrees/review-pr-<N> --force

Confidence Formula (Cumulative Additive Model):
  Each iteration earns 5-15 points (base 5 + tests 4 + severity 3 + consensus 3).
  Diminishing returns: multiplier = max(0.5, 1.0 - iteration * 0.1).
  confidence = min(100, 40 + cumulative_points)

Labels:
  - During: ralpr:review
  - Done: ralpr:review:XX (e.g., ralpr:review:92)

Output:
  Returns JSON with: issues_found, issues_fixed, quality_gates, commits,
  confidence, label_set, worktree_path

Examples:
  ralpr-review.sh --pr 123
  ralpr-review.sh                          # Auto-select PR
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr) PR_NUMBER="$2"; shift 2 ;;
      --worktree-base) WORKTREE_BASE="$2"; shift 2 ;;
      --working-dir)
        log_warn "--working-dir is deprecated. Worktrees are now used for isolation."
        shift 2
        ;;
      --dry-run) DRY_RUN=true; shift ;;
      --max-loops|--threshold)
        log_error "Error: $1 is no longer supported. The skill runs single iterations."
        log_error "For automated looping: ralpr-orchestrator.sh review --pr N --max-loops 10"
        exit 1
        ;;
      --help|-h) show_help; exit 0 ;;
      *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
  done

  # Auto-select PR if not provided
  if [[ -z "$PR_NUMBER" ]]; then
    if ! select_review_pr; then
      log_error "No PR available for review"
      exit 1
    fi
  fi

  run_review_phase
}

main "$@"
