#!/usr/bin/env bash
# ralpr-implementation.sh - Phase 1: Implementation
# No loops, no confidence scores. Just implement and ship.
#
# Usage:
#   ralpr-implementation.sh --issue 123

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/github-labels.sh"
source "$SCRIPT_DIR/lib/quality-gates.sh"
source "$SCRIPT_DIR/lib/ci-watcher.sh"

# Load config
source "$SCRIPT_DIR/../config/ralpr.config.sh"

# ============================================================================
# GLOBALS
# ============================================================================

ISSUE_NUMBER=""
DRY_RUN=false
HUMAN_REVIEW=false

# State
DEFAULT_BRANCH=""
WORKTREE_PATH=""
BRANCH_NAME=""
PR_NUMBER=""

# ============================================================================
# PHASE 1 WORKFLOW
# ============================================================================

# Step 1: Setup and prerequisites
phase1_setup() {
  log_phase "Phase 1.1: Setup"

  # Check prerequisites
  if ! check_gh_auth; then
    log_error "GitHub CLI not authenticated"
    return 1
  fi

  if ! check_git_clean; then
    log_error "Working directory not clean"
    return 1
  fi

  # Get default branch
  DEFAULT_BRANCH=$(get_base_branch)
  if [[ -z "$DEFAULT_BRANCH" ]]; then
    log_error "Could not determine default branch"
    return 1
  fi

  log_info "Default branch: $DEFAULT_BRANCH"

  # Fetch latest
  git fetch origin "$DEFAULT_BRANCH"

  log_info "Setup complete"
}

# Step 2: Select issue (if not provided)
phase1_select() {
  log_phase "Phase 1.2: Select Issue"

  if [[ -n "$ISSUE_NUMBER" ]]; then
    log_info "Using specified issue #$ISSUE_NUMBER"
  else
    # Auto-select using ralpr select
    local result
    result=$("$SCRIPT_DIR/ralpr" select 2>&1 | parse_ralpr_result)

    local status
    status=$(echo "$result" | jq -r '.status')

    if [[ "$status" != "selected" ]]; then
      log_error "No issue available for selection"
      return 1
    fi

    ISSUE_NUMBER=$(echo "$result" | jq -r '.number')
    log_info "Auto-selected issue #$ISSUE_NUMBER"
  fi

  # Verify issue exists
  if ! gh issue view "$ISSUE_NUMBER" --json number > /dev/null 2>&1; then
    log_error "Issue #$ISSUE_NUMBER not found"
    return 1
  fi
}

# Step 3: Claim issue
phase1_claim() {
  log_phase "Phase 1.3: Claim Issue"

  local result
  result=$("$SCRIPT_DIR/ralpr" claim issue "$ISSUE_NUMBER" 2>&1 | parse_ralpr_result)

  local status
  status=$(echo "$result" | jq -r '.status')

  if [[ "$status" == "error" ]]; then
    local code
    code=$(echo "$result" | jq -r '.code')
    if [[ "$code" == "already_assigned" ]]; then
      log_error "Issue #$ISSUE_NUMBER is already assigned"
      return 1
    fi
    log_error "Failed to claim issue: $(echo "$result" | jq -r '.message')"
    return 1
  fi

  log_info "Claimed issue #$ISSUE_NUMBER"
}

# Step 4: Create branch/worktree
phase1_branch() {
  log_phase "Phase 1.4: Create Branch"

  local branch_args="--issue $ISSUE_NUMBER"

  local result
  result=$("$SCRIPT_DIR/ralpr" branch $branch_args 2>&1 | parse_ralpr_result)

  local status
  status=$(echo "$result" | jq -r '.status')

  if [[ "$status" == "error" ]]; then
    log_error "Failed to create branch"
    return 1
  fi

  BRANCH_NAME=$(echo "$result" | jq -r '.branch')

  if [[ "$status" == "created" ]] && [[ $(echo "$result" | jq -r '.worktree') == "true" ]]; then
    WORKTREE_PATH=$(echo "$result" | jq -r '.worktree_path')
    log_info "Created worktree at $WORKTREE_PATH"

    # Change to worktree
    cd "$WORKTREE_PATH"

    # Install dependencies
    if [[ -f "package.json" ]]; then
      log_info "Installing dependencies..."
      npm install
    fi

    # Verify baseline tests pass
    log_info "Verifying baseline tests..."
    if ! run_tests .; then
      log_warn "Baseline tests failing - proceeding anyway"
    fi
  else
    log_info "Created branch: $BRANCH_NAME"
  fi
}

# Step 5: Explore codebase
phase1_explore() {
  log_phase "Phase 1.5: Explore Codebase"

  log_info "This step is handled by spawning explore-agent in main agent"
  # The main Ralpr skill will spawn this agent
  # Output: map_path for use in later phases
}

# Step 6: Understand issue
phase1_understand() {
  log_phase "Phase 1.6: Understand Issue"

  log_info "This step is handled by spawning understand-agent in main agent"
  # The main Ralpr skill will spawn this agent
  # Output: acceptance_criteria, constraints, edge_cases
}

# Step 7: Implement (TDD)
phase1_implement() {
  log_phase "Phase 1.7: Implement"

  log_info "This step is handled by spawning implement-agent in main agent"
  # The main Ralpr skill will spawn this agent
  # Output: commits, files_changed, test_summary
}

# Step 8: Quality gates
phase1_quality_gates() {
  log_phase "Phase 1.8: Quality Gates"

  if ! run_all_quality_gates .; then
    log_error "Quality gates failed"
    return 1
  fi

  log_info "All quality gates passed"
}

# Step 9: Create PR
phase1_create_pr() {
  log_phase "Phase 1.9: Create PR"

  log_info "This step creates the PR after implementation"

  # The PR title and body will be constructed by the main agent
  # using data from understand and implement agents
}

# Step 10: Wait for CI
phase1_ci() {
  log_phase "Phase 1.10: CI Gate"

  local ci_result
  ci_result=$(wait_for_ci "$BRANCH_NAME")
  local exit_code=$?

  case $exit_code in
    0)
      log_info "CI passed"
      ;;
    1)
      log_error "CI failed"
      return 1
      ;;
    2)
      log_warn "CI timed out"
      return 2
      ;;
    3)
      log_info "No CI workflows configured"
      ;;
  esac
}

# Step 11: Finalize
phase1_finalize() {
  log_phase "Phase 1.11: Finalize"

  if [[ -n "$PR_NUMBER" ]]; then
    # Set completion label
    set_phase_label "$PR_NUMBER" "impl:done"
    log_info "Set label: ralpr:impl:done"

    if [[ "$HUMAN_REVIEW" == "true" ]]; then
      local owner
      owner=$(gh api repos/:owner/:repo --jq '.owner.login')
      gh pr edit "$PR_NUMBER" --add-reviewer "$owner"
      log_info "Requested human review from $owner"
    fi
  fi

  log_info "Phase 1 complete"
}

# Cleanup on error or success
phase1_cleanup() {
  log_phase "Cleanup"

  # Release assignment if we have an issue
  if [[ -n "$ISSUE_NUMBER" ]]; then
    "$SCRIPT_DIR/ralpr" release issue "$ISSUE_NUMBER" 2>/dev/null || true
  fi

  # Clean up worktree if created
  if [[ -n "$WORKTREE_PATH" ]] && [[ -d "$WORKTREE_PATH" ]]; then
    local main_repo
    main_repo=$(get_main_repo)
    cd "$main_repo"
    git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
    git worktree prune 2>/dev/null || true
  fi

  log_info "Cleanup complete"
}

# ============================================================================
# MAIN ORCHESTRATION (for standalone use)
# ============================================================================

run_phase1() {
  # This function is called when running standalone
  # In normal operation, the main ralpr CLI delegates to this script

  trap phase1_cleanup EXIT

  phase1_setup || { log_error "Setup failed"; exit 1; }
  phase1_select || { log_error "Selection failed"; exit 1; }
  phase1_claim || { log_error "Claim failed"; exit 1; }
  phase1_branch || { log_error "Branch creation failed"; exit 1; }

  log_info "Phase 1 shell setup complete"
  log_info "Remaining steps (explore, understand, implement) must be run by main agent"

  # Output state for main agent
  ralpr_result "{\"status\":\"ready\",\"issue_number\":$ISSUE_NUMBER,\"branch\":\"$BRANCH_NAME\",\"worktree_path\":\"${WORKTREE_PATH:-null}\",\"default_branch\":\"$DEFAULT_BRANCH\"}"
}

# ============================================================================
# CLI
# ============================================================================

show_help() {
  cat << 'EOF'
ralpr-implementation.sh - Phase 1: Implementation

Usage:
  ralpr-implementation.sh [options]

Options:
  --issue N         Work on specific issue (required or auto-select)
  --human-review    Request human review on PR
  --dry-run         Preview without changes

Workflow:
  1. Setup - Check prerequisites, fetch latest
  2. Select - Choose issue (or use --issue)
  3. Claim - Assign issue to self
  4. Branch - Create feature branch/worktree
  5. Explore - Map codebase (agent)
  6. Understand - Extract requirements (agent)
  7. Implement - TDD implementation (agent)
  8. Quality - Run tests, lint, typecheck
  9. PR - Create pull request
  10. CI - Wait for CI to pass
  11. Finalize - Set labels, cleanup

Examples:
  ralpr-implementation.sh --issue 123
  ralpr-implementation.sh --human-review
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue) ISSUE_NUMBER="$2"; shift 2 ;;
      --human-review) HUMAN_REVIEW=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --help|-h) show_help; exit 0 ;;
      *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
  done

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would run Phase 1 for issue #${ISSUE_NUMBER:-auto-select}"
    exit 0
  fi

  run_phase1
}

main "$@"
