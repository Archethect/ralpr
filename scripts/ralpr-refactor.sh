#!/usr/bin/env bash
# ralpr-refactor.sh - Phase 3: Refactor
# Single iteration with confidence scoring. Target: 95%
#
# Usage:
#   ralpr-refactor.sh --pr 123

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

# Select PR ready for refactor phase
# Filters: review confidence >= REVIEW_THRESHOLD, refactor confidence < REFACTOR_THRESHOLD (or none), unassigned
select_refactor_pr() {
  log_info "Auto-selecting PR for refactor..."

  # Find open PRs with review label, unassigned, where review >= threshold and refactor < threshold
  local selected=""
  while IFS= read -r pr_json; do
    [[ -z "$pr_json" ]] && continue
    local pr_num review_conf refactor_conf
    pr_num=$(echo "$pr_json" | jq -r '.number')

    # Extract review confidence
    review_conf=$(echo "$pr_json" | jq -r '
      [.labels[].name | select(test("^ralpr:review:[0-9]+$"))] |
      if length > 0 then .[0] | split(":")[2] | tonumber else 0 end
    ')

    # Skip if review not done
    if [[ "$review_conf" -lt "$REVIEW_THRESHOLD" ]]; then
      continue
    fi

    # Extract refactor confidence (0 if no refactor label)
    refactor_conf=$(echo "$pr_json" | jq -r '
      [.labels[].name | select(test("^ralpr:refactor:[0-9]+$"))] |
      if length > 0 then .[0] | split(":")[2] | tonumber else 0 end
    ')

    if [[ "$refactor_conf" -lt "$REFACTOR_THRESHOLD" ]]; then
      selected="$pr_num"
      break
    fi
  done < <(gh pr list --state open \
    --json number,title,labels,assignees,createdAt \
    --jq '[.[] | select(.assignees | length == 0) | select(.labels | map(.name) | any(test("^ralpr:review:[0-9]+$")))] | sort_by(.createdAt) | .[]' 2>/dev/null)

  if [[ -z "$selected" ]]; then
    log_info "No PRs ready for refactor (need ralpr:review:${REVIEW_THRESHOLD}+ label, refactor < ${REFACTOR_THRESHOLD})"
    return 1
  fi

  PR_NUMBER="$selected"
  log_info "Selected PR #$PR_NUMBER for refactor"
  return 0
}

# ============================================================================
# REFACTOR PHASE - SINGLE ITERATION
# ============================================================================

run_refactor_phase() {
  log_phase "Starting Refactor Phase for PR #$PR_NUMBER"

  # Validate PR exists
  if ! gh pr view "$PR_NUMBER" --json number > /dev/null 2>&1; then
    log_error "PR #$PR_NUMBER not found"
    return 1
  fi

  # Check if PR has passed review
  local review_confidence
  review_confidence=$(get_confidence_from_label "$PR_NUMBER")

  if [[ -z "$review_confidence" ]] || [[ "$review_confidence" -lt 90 ]]; then
    log_warn "PR #$PR_NUMBER has not passed review phase (confidence: ${review_confidence:-none})"
    log_warn "Run review phase first: ralpr review --pr $PR_NUMBER"
    return 1
  fi

  log_info "PR passed review with confidence: $review_confidence%"

  # Get PR branch
  local branch
  branch=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName')
  log_info "PR branch: $branch"

  # Get base branch
  local base_branch
  base_branch=$(gh pr view "$PR_NUMBER" --json baseRefName --jq '.baseRefName')

  # Set up worktree path
  WORKTREE_PATH="$WORKTREE_BASE/refactor-pr-$PR_NUMBER"

  # Get current iteration for display (don't increment in dry-run)
  local current_iter
  current_iter=$(get_refactor_iteration "$PR_NUMBER")
  local next_iter=$((current_iter + 1))

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would run refactor phase"
    log_info "  PR: #$PR_NUMBER"
    log_info "  Branch: $branch"
    log_info "  Base: $base_branch"
    log_info "  Review confidence: $review_confidence%"
    log_info "  Iteration: $current_iter -> $next_iter"
    log_info "  Worktree: $WORKTREE_PATH"
    ralpr_result '{"status":"dry_run","phase":"refactor","pr_number":'"$PR_NUMBER"',"review_confidence":'"$review_confidence"',"iteration":'"$next_iter"',"worktree_path":"'"$WORKTREE_PATH"'"}'
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
  iteration=$(increment_refactor_iteration "$PR_NUMBER")

  # The actual refactor workflow is driven by the Claude agent following SKILL.md
  # This script just prepares the environment and outputs context for the agent

  local owner_repo
  owner_repo=$(get_owner_repo)

  # Output context for the agent to use
  log_info "Refactor phase context:"
  log_info "  PR: #$PR_NUMBER"
  log_info "  Repository: $owner_repo"
  log_info "  Branch: $branch"
  log_info "  Base: $base_branch"
  log_info "  Review confidence: $review_confidence%"
  log_info "  Iteration: $iteration"
  log_info "  Worktree: $WORKTREE_PATH"
  log_info ""
  log_info "IMPORTANT: When done, clean up with:"
  log_info "  git worktree remove $WORKTREE_PATH --force"

  # Output the setup result for the agent
  ralpr_result "{\"status\":\"ready\",\"phase\":\"refactor\",\"pr_number\":$PR_NUMBER,\"branch\":\"$branch\",\"base_branch\":\"$base_branch\",\"repo\":\"$owner_repo\",\"iteration\":$iteration,\"worktree_path\":\"$WORKTREE_PATH\",\"working_dir\":\"$WORKTREE_PATH\",\"review_confidence\":$review_confidence}"
}

# ============================================================================
# CLI
# ============================================================================

show_help() {
  cat << 'EOF'
ralpr-refactor.sh - Phase 3: Refactor (Single Iteration)

Usage:
  ralpr-refactor.sh [options]

Options:
  --pr N              PR number to refactor (or auto-select)
  --worktree-base D   Base directory for worktrees (default: .worktrees)
  --dry-run           Preview without changes

Prerequisites:
  - PR must have passed review phase (ralpr:review:90+ label)

Workflow:
  1. Create worktree at .worktrees/refactor-pr-<N>
  2. Install dependencies (npm install)
  3. Understand PR and review feedback (spawn understand-agent)
  4. Invoke superpowers:refactor skill
  5. Get skill confidence score
  6. Run quality gates
  7. Push and wait for CI
  8. Calculate confidence score
  9. Set PR label with confidence

Cleanup (REQUIRED):
  When done, always remove the worktree:
    git worktree remove .worktrees/refactor-pr-<N> --force

Confidence Formula:
  confidence = (skill_confidence × 0.70) + (test_stability × 0.30)

Labels:
  - During: ralpr:refactor
  - Done: ralpr:refactor:XX (e.g., ralpr:refactor:96)

Output:
  Returns JSON with: skill_confidence, refactorings_applied, quality_gates,
  commits, confidence, label_set, worktree_path

Examples:
  ralpr-refactor.sh --pr 123
  ralpr-refactor.sh                          # Auto-select PR
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
        log_error "For automated looping: ralpr-orchestrator.sh refactor --pr N --max-loops 5"
        exit 1
        ;;
      --help|-h) show_help; exit 0 ;;
      *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
  done

  # Auto-select PR if not provided
  if [[ -z "$PR_NUMBER" ]]; then
    if ! select_refactor_pr; then
      log_error "No PR available for refactor"
      exit 1
    fi
  fi

  run_refactor_phase
}

main "$@"
