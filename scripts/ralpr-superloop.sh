#!/usr/bin/env bash
# ralpr-superloop.sh - Per-loop orchestrator for Ralpr super-loop
#
# Runs inside a tmux pane. Executes the full impl -> review -> refactor pipeline
# for GitHub issues, spawning fresh Docker-isolated Claude sessions for each phase.
#
# Usage: ralpr-superloop.sh --loop-id <id> [--issue <N>] [--max-cycles <N>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/loop-state.sh"
source "$SCRIPT_DIR/lib/github-labels.sh"
source "$SCRIPT_DIR/lib/tmux.sh"
source "$SCRIPT_DIR/../config/ralpr.config.sh"

# ============================================================================
# GLOBALS
# ============================================================================

LOOP_ID=""
INITIAL_ISSUE=""
MAX_CYCLES="${RALPR_LOOP_MAX_CYCLES:-0}"
DOCKER_CMD="${RALPR_DOCKER_CMD:-claude-docker}"
POLL_INTERVAL="${RALPR_LABEL_POLL_INTERVAL:-10}"
POLL_TIMEOUT="${RALPR_LABEL_POLL_TIMEOUT:-60}"
LOG_DIR="${RALPR_LOOP_LOG_DIR:-.ralpr/logs}"

CURRENT_CYCLE=0
CYCLE_HISTORY=()  # Array of "issue:pr:review_conf:refactor_conf" entries

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --loop-id) LOOP_ID="$2"; shift 2 ;;
      --issue) INITIAL_ISSUE="$2"; shift 2 ;;
      --max-cycles) MAX_CYCLES="$2"; shift 2 ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$LOOP_ID" ]]; then
    log_error "Loop ID required (--loop-id)"
    exit 1
  fi
}

# ============================================================================
# PREREQUISITES
# ============================================================================

check_prerequisites() {
  log_info "Checking prerequisites..."

  if ! command -v docker &>/dev/null; then
    log_error "docker is not installed"
    return 1
  fi

  if ! command -v "$DOCKER_CMD" &>/dev/null; then
    log_error "$DOCKER_CMD is not in PATH"
    return 1
  fi

  if ! check_gh_auth; then
    return 1
  fi

  log_info "Prerequisites OK"
}

# ============================================================================
# LOGGING
# ============================================================================

# Get the log directory for the current cycle and phase
_log_file() {
  local phase="$1"
  local iteration="${2:-}"
  local cycle_dir="${LOG_DIR}/${LOOP_ID}/cycle-${CURRENT_CYCLE}"

  mkdir -p "$cycle_dir"

  if [[ -n "$iteration" ]]; then
    echo "${cycle_dir}/${phase}-iter-${iteration}.log"
  else
    echo "${cycle_dir}/${phase}.log"
  fi
}

# ============================================================================
# PANE TITLE
# ============================================================================

_update_pane_title() {
  local status="$1"
  local registry
  registry=$(_loop_registry_file)

  if [[ -f "$registry" ]]; then
    local pane_id
    pane_id=$(jq -r --arg id "$LOOP_ID" '.loops[$id].tmux_pane // empty' "$registry")
    if [[ -n "$pane_id" ]]; then
      set_pane_title "$pane_id" "${LOOP_ID}: ${status}"
    fi
  fi
}

# ============================================================================
# STATE UPDATES
# ============================================================================

_set_state() {
  local phase="$1"
  local extra="${2:-{}}"

  update_loop_state "$LOOP_ID" "$(echo "$extra" | jq \
    --arg phase "$phase" \
    --argjson cycle "$CURRENT_CYCLE" \
    --argjson max "$MAX_CYCLES" \
    --arg id "$LOOP_ID" \
    --arg status "running" \
    '. + {id: $id, phase: $phase, cycle: $cycle, max_cycles: $max, status: $status}')"
}

_set_failed() {
  local reason="$1"
  update_loop_state "$LOOP_ID" "$(jq -n \
    --arg status "failed" \
    --arg reason "$reason" \
    '{status: $status, failure_reason: $reason}')"
}

_set_done() {
  update_loop_state "$LOOP_ID" '{"status":"done"}'
}

# ============================================================================
# DOCKER SESSION EXECUTION
# ============================================================================

# Run a claude-docker session with the given prompt
# Tees output to the log file while showing it in the pane
# Returns the container exit code
run_claude_session() {
  local prompt="$1"
  local log_file="$2"
  local container_name="$3"

  log_info "Spawning: $container_name"
  log_info "Log: $log_file"

  local exit_code=0

  CLAUDE_DOCKER_NAME="$container_name" \
    "$DOCKER_CMD" --no-tty -p "$prompt" 2>&1 | tee "$log_file" || exit_code=$?

  return "$exit_code"
}

# ============================================================================
# ISSUE SELECTION (with race-condition-safe claim-verify pattern)
# ============================================================================

select_and_claim_issue() {
  local specific_issue="${1:-}"

  if [[ -n "$specific_issue" ]]; then
    log_info "Using specified issue #$specific_issue"

    # Claim it
    gh issue edit "$specific_issue" --add-assignee @me 2>/dev/null || true

    # Verify
    local assignee
    assignee=$(gh issue view "$specific_issue" --json assignees -q '.assignees[0].login' 2>/dev/null || echo "")
    local my_login
    my_login=$(gh api user -q '.login' 2>/dev/null || echo "")

    if [[ "$assignee" != "$my_login" ]]; then
      log_warn "Failed to claim issue #$specific_issue (assigned to $assignee)"
      return 1
    fi

    echo "$specific_issue"
    return 0
  fi

  # Auto-select: try up to 5 candidates
  local attempts=0
  while [[ $attempts -lt 5 ]]; do
    local candidate
    candidate=$(gh issue list --state open --assignee "" --label "status:backlog" \
      --limit 1 --json number -q '.[0].number' 2>/dev/null || echo "")

    # If no backlog issues, try without label filter
    if [[ -z "$candidate" ]]; then
      candidate=$(gh issue list --state open --assignee "" \
        --limit 1 --json number -q '.[0].number' 2>/dev/null || echo "")
    fi

    if [[ -z "$candidate" ]]; then
      log_warn "No open unassigned issues found"
      return 1
    fi

    # Claim-verify pattern
    gh issue edit "$candidate" --add-assignee @me 2>/dev/null || true

    local assignee
    assignee=$(gh issue view "$candidate" --json assignees -q '.assignees[0].login' 2>/dev/null || echo "")
    local my_login
    my_login=$(gh api user -q '.login' 2>/dev/null || echo "")

    if [[ "$assignee" == "$my_login" ]]; then
      log_info "Claimed issue #$candidate"
      echo "$candidate"
      return 0
    fi

    # Race lost, release and try next
    log_warn "Race lost on issue #$candidate, trying next..."
    gh issue edit "$candidate" --remove-assignee @me 2>/dev/null || true
    attempts=$((attempts + 1))
  done

  log_error "Failed to claim any issue after $attempts attempts"
  return 1
}

# ============================================================================
# STALE WORKTREE CLEANUP
# ============================================================================

clean_stale_worktrees() {
  log_info "Cleaning stale worktrees..."
  git worktree prune 2>/dev/null || true
}

# ============================================================================
# GITHUB LABEL POLLING
# ============================================================================

# Poll for a label matching a pattern on a PR
# Returns the label value or empty string
poll_for_label() {
  local pr_number="$1"
  local label_prefix="$2"  # e.g., "ralpr:review:" or "ralpr:impl:done"
  local timeout="${3:-$POLL_TIMEOUT}"
  local interval="${4:-$POLL_INTERVAL}"

  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local labels
    labels=$(gh pr view "$pr_number" --json labels --jq '.labels[].name' 2>/dev/null || echo "")

    local match
    match=$(echo "$labels" | grep "^${label_prefix}" | head -1 || echo "")

    if [[ -n "$match" ]]; then
      echo "$match"
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  return 1
}

# Find the PR number that was created for an issue (with ralpr:impl:done label)
find_pr_for_issue() {
  local issue_num="$1"
  local timeout="${2:-$POLL_TIMEOUT}"
  local interval="${3:-$POLL_INTERVAL}"

  local owner repo
  owner=$(get_owner)
  repo=$(get_repo)

  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    # Look for open PRs with ralpr:impl:done that close this issue
    local linked_prs
    linked_prs=$(gh api graphql -f query="$(cat "$SCRIPT_DIR/queries/issue-closing-prs.graphql")" \
      -f owner="$owner" -f repo="$repo" -F issue="$issue_num" \
      --jq '.data.repository.issue.closedByPullRequestsReferences.nodes[].number' 2>/dev/null || echo "")

    for pr_num in $linked_prs; do
      local has_done
      has_done=$(gh pr view "$pr_num" --json labels --jq '.labels[].name' 2>/dev/null | grep "^ralpr:impl:done$" || echo "")

      if [[ -n "$has_done" ]]; then
        echo "$pr_num"
        return 0
      fi
    done

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  return 1
}

# Extract confidence number from a label like "ralpr:review:85"
extract_confidence() {
  local label="$1"
  echo "$label" | grep -oE '[0-9]+$' || echo "0"
}

# ============================================================================
# PHASE EXECUTION
# ============================================================================

# Phase 1: Implementation
# Returns: PR number via stdout, or exits non-zero
run_impl_phase() {
  local issue_num="$1"
  local log_file
  log_file=$(_log_file "impl")
  local container_name="ralpr-${LOOP_ID}-impl-c${CURRENT_CYCLE}"

  _update_pane_title "impl #${issue_num}"
  _set_state "impl" "$(jq -n --argjson issue "$issue_num" '{issue: $issue, phase_iteration: 1}')"

  local prompt="/ralpr --phase impl --issue ${issue_num}"

  if ! run_claude_session "$prompt" "$log_file" "$container_name"; then
    log_warn "Implementation container exited with error"
  fi

  # Poll for the PR with ralpr:impl:done
  log_info "Polling for implementation PR for issue #${issue_num}..."
  local pr_num
  if pr_num=$(find_pr_for_issue "$issue_num" "$POLL_TIMEOUT" "$POLL_INTERVAL"); then
    log_info "Found PR #$pr_num for issue #$issue_num"
    echo "$pr_num"
    return 0
  fi

  log_error "No implementation PR found for issue #$issue_num within timeout"
  return 1
}

# Phase 2: Review (iterative)
# Returns: final confidence via stdout
run_review_phase() {
  local pr_num="$1"
  local max_iters="${REVIEW_MAX_LOOPS:-7}"
  local threshold="${REVIEW_THRESHOLD:-85}"
  local iteration=1

  while [[ $iteration -le $max_iters ]]; do
    _update_pane_title "review:${iteration} PR#${pr_num}"
    _set_state "review" "$(jq -n --argjson pr "$pr_num" --argjson iter "$iteration" '{pr: $pr, phase_iteration: $iter}')"

    local log_file
    log_file=$(_log_file "review" "$iteration")
    local container_name="ralpr-${LOOP_ID}-review-c${CURRENT_CYCLE}-i${iteration}"

    local prompt="/ralpr --phase review --pr ${pr_num}"

    if ! run_claude_session "$prompt" "$log_file" "$container_name"; then
      log_warn "Review container iteration $iteration exited with error"
    fi

    # Check the review confidence label
    local label
    if label=$(poll_for_label "$pr_num" "ralpr:review:" "$POLL_TIMEOUT" "$POLL_INTERVAL"); then
      local conf
      conf=$(extract_confidence "$label")
      log_info "Review iteration $iteration: confidence=$conf% (threshold=$threshold%)"

      if [[ "$conf" -ge "$threshold" ]]; then
        log_info "Review threshold met ($conf% >= $threshold%)"
        echo "$conf"
        return 0
      fi
    else
      log_warn "No review confidence label found after iteration $iteration"
    fi

    # Check stop signal between iterations
    if check_stop_signal "$LOOP_ID"; then
      log_info "Stop signal detected during review phase"
      echo "0"
      return 1
    fi

    iteration=$((iteration + 1))
  done

  log_warn "Max review iterations ($max_iters) reached"
  # Get the final confidence
  local final_label
  if final_label=$(poll_for_label "$pr_num" "ralpr:review:" 5 5); then
    extract_confidence "$final_label"
  else
    echo "0"
  fi
  return 1
}

# Phase 3: Refactor (iterative)
# Returns: final confidence via stdout
run_refactor_phase() {
  local pr_num="$1"
  local max_iters="${REFACTOR_MAX_LOOPS:-5}"
  local threshold="${REFACTOR_THRESHOLD:-85}"
  local iteration=1

  while [[ $iteration -le $max_iters ]]; do
    _update_pane_title "refactor:${iteration} PR#${pr_num}"
    _set_state "refactor" "$(jq -n --argjson pr "$pr_num" --argjson iter "$iteration" '{pr: $pr, phase_iteration: $iter}')"

    local log_file
    log_file=$(_log_file "refactor" "$iteration")
    local container_name="ralpr-${LOOP_ID}-refactor-c${CURRENT_CYCLE}-i${iteration}"

    local prompt="/ralpr --phase refactor --pr ${pr_num}"

    if ! run_claude_session "$prompt" "$log_file" "$container_name"; then
      log_warn "Refactor container iteration $iteration exited with error"
    fi

    # Check the refactor confidence label
    local label
    if label=$(poll_for_label "$pr_num" "ralpr:refactor:" "$POLL_TIMEOUT" "$POLL_INTERVAL"); then
      local conf
      conf=$(extract_confidence "$label")
      log_info "Refactor iteration $iteration: confidence=$conf% (threshold=$threshold%)"

      if [[ "$conf" -ge "$threshold" ]]; then
        log_info "Refactor threshold met ($conf% >= $threshold%)"
        echo "$conf"
        return 0
      fi
    else
      log_warn "No refactor confidence label found after iteration $iteration"
    fi

    # Check stop signal between iterations
    if check_stop_signal "$LOOP_ID"; then
      log_info "Stop signal detected during refactor phase"
      echo "0"
      return 1
    fi

    iteration=$((iteration + 1))
  done

  log_warn "Max refactor iterations ($max_iters) reached"
  local final_label
  if final_label=$(poll_for_label "$pr_num" "ralpr:refactor:" 5 5); then
    extract_confidence "$final_label"
  else
    echo "0"
  fi
  return 1
}

# ============================================================================
# RETRY WRAPPER
# ============================================================================

# Run a phase function with one retry on failure
run_with_retry() {
  local phase_name="$1"
  shift
  local phase_fn="$1"
  shift

  local result
  if result=$("$phase_fn" "$@"); then
    echo "$result"
    return 0
  fi

  log_warn "${phase_name} failed, retrying once..."

  if result=$("$phase_fn" "$@"); then
    echo "$result"
    return 0
  fi

  log_error "${phase_name} failed after retry"
  echo "$result"
  return 1
}

# ============================================================================
# COMPLETION SUMMARY
# ============================================================================

print_completion_summary() {
  local status="$1"  # "done" or "stopped" or "failed"

  local total_cycles=${#CYCLE_HISTORY[@]}

  echo ""
  echo "========================================"
  echo "          LOOP ${LOOP_ID} ${status^^}"
  echo "========================================"
  echo " Cycles completed: ${total_cycles}/${MAX_CYCLES:-0}"
  echo ""

  local idx=1
  for entry in "${CYCLE_HISTORY[@]+"${CYCLE_HISTORY[@]}"}"; do
    local issue pr review_conf refactor_conf
    issue=$(echo "$entry" | cut -d: -f1)
    pr=$(echo "$entry" | cut -d: -f2)
    review_conf=$(echo "$entry" | cut -d: -f3)
    refactor_conf=$(echo "$entry" | cut -d: -f4)

    echo " Cycle ${idx}: Issue #${issue} -> PR #${pr}"
    echo "   impl: done | review: ${review_conf}% | refactor: ${refactor_conf}%"
    echo ""
    idx=$((idx + 1))
  done

  echo " Logs: ${LOG_DIR}/${LOOP_ID}/"
  echo "========================================"
  echo ""
}

# ============================================================================
# MAIN LOOP
# ============================================================================

main() {
  parse_args "$@"

  log_info "Starting super-loop: ${LOOP_ID}"
  log_info "Max cycles: ${MAX_CYCLES} (0=infinite)"

  # Check prerequisites
  if ! check_prerequisites; then
    _set_failed "prerequisites"
    exec bash
  fi

  # Initialize state
  local started_at
  started_at=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
  update_loop_state "$LOOP_ID" "$(jq -n \
    --arg id "$LOOP_ID" \
    --arg status "running" \
    --argjson max "$MAX_CYCLES" \
    --arg started "$started_at" \
    '{id: $id, status: $status, cycle: 0, max_cycles: $max, started_at: $started}')"

  local issue_for_next_cycle="$INITIAL_ISSUE"

  while true; do
    # Check stop signal
    if check_stop_signal "$LOOP_ID"; then
      log_info "Stop signal detected, shutting down..."
      _update_pane_title "stopped"
      print_completion_summary "stopped"
      _set_done
      exec bash
    fi

    # Check cycle limit
    CURRENT_CYCLE=$((CURRENT_CYCLE + 1))
    if [[ "$MAX_CYCLES" -gt 0 && "$CURRENT_CYCLE" -gt "$MAX_CYCLES" ]]; then
      log_info "Max cycles reached ($MAX_CYCLES)"
      _update_pane_title "done"
      print_completion_summary "done"
      _set_done
      exec bash
    fi

    log_phase "=== Cycle $CURRENT_CYCLE ==="

    # Clean stale worktrees
    clean_stale_worktrees

    # ---- PHASE 1: IMPLEMENTATION ----
    local issue_num=""
    if ! issue_num=$(select_and_claim_issue "$issue_for_next_cycle"); then
      log_error "Failed to select/claim an issue"
      _set_failed "no_issue"
      _update_pane_title "failed: no issue"
      print_completion_summary "failed"
      exec bash
    fi

    # Clear initial issue so subsequent cycles auto-select
    issue_for_next_cycle=""

    local pr_num=""
    if ! pr_num=$(run_with_retry "Implementation" run_impl_phase "$issue_num"); then
      log_error "Implementation phase failed for issue #$issue_num"
      # Release the issue
      gh issue edit "$issue_num" --remove-assignee @me 2>/dev/null || true
      _set_failed "impl_failed"
      _update_pane_title "failed: impl #${issue_num}"
      print_completion_summary "failed"
      exec bash
    fi

    _set_state "impl_done" "$(jq -n --argjson issue "$issue_num" --argjson pr "$pr_num" '{issue: $issue, pr: $pr}')"

    # Check stop signal between phases
    if check_stop_signal "$LOOP_ID"; then
      log_info "Stop signal detected after implementation"
      _update_pane_title "stopped"
      print_completion_summary "stopped"
      _set_done
      exec bash
    fi

    # ---- PHASE 2: REVIEW ----
    local review_conf="0"
    if ! review_conf=$(run_with_retry "Review" run_review_phase "$pr_num"); then
      log_error "Review phase failed for PR #$pr_num"
      _set_failed "review_failed"
      _update_pane_title "failed: review PR#${pr_num}"
      print_completion_summary "failed"
      exec bash
    fi

    # Check stop signal between phases
    if check_stop_signal "$LOOP_ID"; then
      log_info "Stop signal detected after review"
      _update_pane_title "stopped"
      print_completion_summary "stopped"
      _set_done
      exec bash
    fi

    # ---- PHASE 3: REFACTOR ----
    local refactor_conf="0"
    if ! refactor_conf=$(run_with_retry "Refactor" run_refactor_phase "$pr_num"); then
      log_error "Refactor phase failed for PR #$pr_num"
      _set_failed "refactor_failed"
      _update_pane_title "failed: refactor PR#${pr_num}"
      print_completion_summary "failed"
      exec bash
    fi

    # ---- CYCLE COMPLETE ----
    CYCLE_HISTORY+=("${issue_num}:${pr_num}:${review_conf}:${refactor_conf}")
    log_info "Cycle $CURRENT_CYCLE complete: Issue #$issue_num -> PR #$pr_num (review: ${review_conf}%, refactor: ${refactor_conf}%)"

    _update_pane_title "cycle ${CURRENT_CYCLE} done"
  done
}

main "$@"
