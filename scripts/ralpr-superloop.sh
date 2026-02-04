#!/usr/bin/env bash
# ralpr-superloop.sh - Per-loop orchestrator for Ralpr super-loop
#
# Runs inside a tmux pane. Executes the full impl -> review -> refactor pipeline
# for GitHub issues, spawning fresh Docker-isolated Claude sessions for each phase.
#
# Usage: ralpr-superloop.sh --loop-id <id> [--issue <N>] [--pr <N>] [--max-cycles <N>]

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
INITIAL_PR=""
MAX_CYCLES="${RALPR_LOOP_MAX_CYCLES:-0}"
DOCKER_CMD="${RALPR_DOCKER_CMD:-claude-docker}"
POLL_INTERVAL="${RALPR_LABEL_POLL_INTERVAL:-10}"
POLL_TIMEOUT="${RALPR_LABEL_POLL_TIMEOUT:-60}"
LOG_DIR="${RALPR_LOOP_LOG_DIR:-.ralpr/logs}"

CURRENT_CYCLE=0
CYCLE_HISTORY=()  # Array of "issue:pr:review_conf:refactor_conf" entries

# ============================================================================
# TEMP-FILE RETURN VALUES
# Phase functions write return values here instead of stdout, so that stdout
# remains free for script(1) / tmux pane display.
# ============================================================================

# Write a phase return value to a temp file
_write_result() {
  local value="$1"
  local result_dir="${LOG_DIR}/${LOOP_ID}"
  mkdir -p "$result_dir"
  echo "$value" > "${result_dir}/.result"
}

# Read and consume the phase return value
_read_result() {
  local result_file="${LOG_DIR}/${LOOP_ID}/.result"
  if [[ -f "$result_file" ]]; then
    cat "$result_file"
    rm -f "$result_file"
  fi
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --loop-id) LOOP_ID="$2"; shift 2 ;;
      --issue) INITIAL_ISSUE="$2"; shift 2 ;;
      --pr) INITIAL_PR="$2"; shift 2 ;;
      --max-cycles) MAX_CYCLES="$2"; shift 2 ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$LOOP_ID" ]]; then
    log_error "Loop ID required (--loop-id)"
    exit 1
  fi

  if [[ -n "$INITIAL_ISSUE" && -n "$INITIAL_PR" ]]; then
    log_error "Cannot specify both --issue and --pr"
    exit 1
  fi
}

# ============================================================================
# PREREQUISITES
# ============================================================================

check_prerequisites() {
  log_info "Checking prerequisites..."

  # Must be inside a git repo with a GitHub remote
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    log_error "Not inside a git repository (cwd: $(pwd))"
    return 1
  fi

  if ! gh repo view --json name &>/dev/null; then
    log_error "No GitHub remote found for this repository"
    return 1
  fi

  log_info "Repo: $(gh repo view --json nameWithOwner -q '.nameWithOwner')"

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

# Coerce a value to a valid integer, default 0
_safe_num() {
  local val="${1:-0}"
  if [[ "$val" =~ ^-?[0-9]+$ ]]; then
    echo "$val"
  else
    echo "0"
  fi
}

_set_state() {
  local phase="$1"
  local extra="${2:-}"

  # Validate extra is valid JSON; fall back to empty object
  if [[ -z "$extra" ]] || ! echo "$extra" | jq empty 2>/dev/null; then
    extra='{}'
  fi

  local cycle max_val
  cycle=$(_safe_num "$CURRENT_CYCLE")
  max_val=$(_safe_num "$MAX_CYCLES")

  local merged
  if ! merged=$(echo "$extra" | jq \
    --arg phase "$phase" \
    --argjson cycle "$cycle" \
    --argjson max "$max_val" \
    --arg id "$LOOP_ID" \
    --arg status "running" \
    '. + {id: $id, phase: $phase, cycle: $cycle, max_cycles: $max, status: $status}'); then
    log_warn "State update failed (jq error), skipping"
    return 0
  fi

  if [[ -z "$merged" ]]; then
    log_warn "State update produced empty JSON, skipping"
    return 0
  fi

  update_loop_state "$LOOP_ID" "$merged"
}

_set_failed() {
  local reason="$1"
  local data
  if ! data=$(jq -n \
    --arg status "failed" \
    --arg reason "$reason" \
    '{status: $status, failure_reason: $reason}'); then
    # Fallback if jq itself fails
    data='{"status":"failed","failure_reason":"unknown"}'
  fi
  update_loop_state "$LOOP_ID" "$data"
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

  # stream-json gives real-time events; tee captures full JSON to the log file;
  # stream-renderer.sh formats a TUI-lite view for the tmux pane.
  # Without -it, a broken pipe won't stop the container — explicit cleanup needed.
  CLAUDE_DOCKER_NAME="$container_name" \
    "$DOCKER_CMD" --no-tty --output-format stream-json --verbose \
    -p "$prompt" 2>&1 \
    | tee "$log_file" \
    | "$SCRIPT_DIR/lib/stream-renderer.sh" || exit_code=$?

  # Ensure container is stopped (pipe break leaves it running without -it)
  docker stop "$container_name" 2>/dev/null || true

  return "$exit_code"
}

# ============================================================================
# SELECTION & CLAIMING (delegates to `ralpr select` + `ralpr claim`)
# ============================================================================

# Unified selection: delegates to `ralpr select` for priority-chain logic,
# then calls `ralpr claim` to atomically claim the result.
# Writes JSON to a temp file: {type, number, phase, pr, issue}
# Returns 0 on success, 1 on failure.
# File-based claim lock — prevents parallel loops on the same host from
# selecting the same ticket. Uses mkdir (atomic on all filesystems).
_CLAIM_LOCK_DIR=".ralpr/claim.lock"

_acquire_claim_lock() {
  local max_wait=60
  local waited=0
  while ! mkdir "$_CLAIM_LOCK_DIR" 2>/dev/null; do
    # Check for stale lock (owner process died)
    if [[ -f "$_CLAIM_LOCK_DIR/pid" ]]; then
      local lock_pid
      lock_pid=$(cat "$_CLAIM_LOCK_DIR/pid" 2>/dev/null || echo "")
      if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        log_warn "Removing stale claim lock (pid $lock_pid is dead)"
        rm -rf "$_CLAIM_LOCK_DIR"
        continue
      fi
    fi
    if [[ $waited -ge $max_wait ]]; then
      log_warn "Claim lock timeout after ${max_wait}s"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo $$ > "$_CLAIM_LOCK_DIR/pid"
}

_release_claim_lock() {
  rm -rf "$_CLAIM_LOCK_DIR" 2>/dev/null || true
}

select_and_claim() {
  local select_args=()

  if [[ -n "$INITIAL_ISSUE" ]]; then
    select_args+=(--issue "$INITIAL_ISSUE")
  elif [[ -n "$INITIAL_PR" ]]; then
    select_args+=(--pr "$INITIAL_PR")
  fi

  local attempts=0
  while [[ $attempts -lt 3 ]]; do
    # Acquire lock so parallel loops on the same host serialise selection
    if ! _acquire_claim_lock; then
      log_warn "Could not acquire claim lock, retrying..."
      attempts=$((attempts + 1))
      sleep 2
      continue
    fi

    local select_output
    select_output=$("$SCRIPT_DIR/ralpr" select ${select_args[@]+"${select_args[@]}"} 2>&1) || true

    # Parse the RALPR_RESULT JSON from the last line
    local result_json
    result_json=$(echo "$select_output" | grep '^RALPR_RESULT: ' | tail -1 | sed 's/^RALPR_RESULT: //')

    if [[ -z "$result_json" ]] || ! echo "$result_json" | jq empty 2>/dev/null; then
      log_warn "ralpr select returned no valid result (attempt $((attempts + 1))/3)"
      _release_claim_lock
      attempts=$((attempts + 1))
      sleep 2
      continue
    fi

    local sel_status sel_type sel_number sel_phase
    sel_status=$(echo "$result_json" | jq -r '.status // "error"')
    sel_type=$(echo "$result_json" | jq -r '.type // "issue"')
    sel_number=$(echo "$result_json" | jq -r '.number // empty')
    sel_phase=$(echo "$result_json" | jq -r '.phase // empty')

    if [[ "$sel_status" == "none" || "$sel_status" == "error" || -z "$sel_number" ]]; then
      log_warn "No tickets available for selection"
      _release_claim_lock
      return 1
    fi

    log_info "Selected $sel_type #$sel_number (phase: ${sel_phase:-impl})"

    # Attempt to claim
    local claim_output
    claim_output=$("$SCRIPT_DIR/ralpr" claim "$sel_type" "$sel_number" 2>&1) || true

    local claim_json
    claim_json=$(echo "$claim_output" | grep '^RALPR_RESULT: ' | tail -1 | sed 's/^RALPR_RESULT: //')

    local claim_status
    claim_status=$(echo "$claim_json" | jq -r '.status // "error"' 2>/dev/null)

    if [[ "$claim_status" == "claimed" ]]; then
      log_info "Claimed $sel_type #$sel_number"
      _release_claim_lock

      # Build result with phase info
      local result_type="$sel_type"
      local result_phase="${sel_phase:-impl}"
      local result_issue="" result_pr=""

      if [[ "$sel_type" == "issue" ]]; then
        result_issue="$sel_number"
        result_phase="impl"
        # Quick check for existing PR
        local existing_pr
        existing_pr=$(find_pr_for_issue_quick "$sel_number")
        if [[ -n "$existing_pr" ]]; then
          result_pr="$existing_pr"
          result_phase=$(detect_phase_for_pr "$existing_pr")
        fi
      else
        result_pr="$sel_number"
        if [[ -z "$result_phase" ]]; then
          result_phase=$(detect_phase_for_pr "$sel_number")
        fi
      fi

      _write_result "{\"type\":\"$result_type\",\"number\":$sel_number,\"phase\":\"$result_phase\",\"issue\":${result_issue:-null},\"pr\":${result_pr:-null}}"
      return 0
    fi

    # Claim failed (race with another host/user), release lock and retry
    _release_claim_lock
    log_warn "Claim failed for $sel_type #$sel_number, retrying..."
    attempts=$((attempts + 1))
    sleep 2
  done

  log_error "Failed to claim after $attempts attempts"
  return 1
}

# Quick single-shot check for an existing PR linked to an issue (no polling)
find_pr_for_issue_quick() {
  local issue_num="$1"
  local owner repo
  owner=$(get_owner)
  repo=$(get_repo)

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
}

# Detect the appropriate phase for a PR based on its labels
detect_phase_for_pr() {
  local pr_num="$1"
  local threshold_review="${REVIEW_THRESHOLD:-85}"
  local threshold_refactor="${REFACTOR_THRESHOLD:-85}"

  local labels
  labels=$(gh pr view "$pr_num" --json labels --jq '.labels[].name' 2>/dev/null || echo "")

  # Check if impl is done
  local has_impl_done
  has_impl_done=$(echo "$labels" | grep "^ralpr:impl:done$" || echo "")
  if [[ -z "$has_impl_done" ]]; then
    echo "impl"
    return 0
  fi

  # Check review confidence (exclude iter: labels)
  local review_label review_conf=0
  review_label=$(echo "$labels" | grep "^ralpr:review:[0-9]" | head -1 || echo "")
  if [[ -n "$review_label" ]]; then
    review_conf=$(echo "$review_label" | grep -oE '[0-9]+$' || echo "0")
  fi

  if [[ "$review_conf" -lt "$threshold_review" ]]; then
    echo "review"
    return 0
  fi

  # Check refactor confidence (exclude iter: labels)
  local refactor_label refactor_conf=0
  refactor_label=$(echo "$labels" | grep "^ralpr:refactor:[0-9]" | head -1 || echo "")
  if [[ -n "$refactor_label" ]]; then
    refactor_conf=$(echo "$refactor_label" | grep -oE '[0-9]+$' || echo "0")
  fi

  if [[ "$refactor_conf" -lt "$threshold_refactor" ]]; then
    echo "refactor"
    return 0
  fi

  echo "done"
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
    # Match confidence labels (prefix + number) but exclude iteration labels (prefix + "iter:")
    match=$(echo "$labels" | grep "^${label_prefix}[0-9]" | head -1 || echo "")

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
  local extra
  extra=$(jq -n --argjson issue "$(_safe_num "$issue_num")" '{issue: $issue, phase_iteration: 1}') || extra='{}'
  _set_state "impl" "$extra"

  local prompt="/ralpr --phase impl --issue ${issue_num}"

  if ! run_claude_session "$prompt" "$log_file" "$container_name"; then
    log_warn "Implementation container exited with error"
  fi

  # Poll for the PR with ralpr:impl:done
  log_info "Polling for implementation PR for issue #${issue_num}..."
  local pr_num
  if pr_num=$(find_pr_for_issue "$issue_num" "$POLL_TIMEOUT" "$POLL_INTERVAL"); then
    log_info "Found PR #$pr_num for issue #$issue_num"
    _write_result "$pr_num"
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
    local extra
    extra=$(jq -n --argjson pr "$(_safe_num "$pr_num")" --argjson iter "$(_safe_num "$iteration")" '{pr: $pr, phase_iteration: $iter}') || extra='{}'
    _set_state "review" "$extra"

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
        _write_result "$conf"
        return 0
      fi
    else
      log_warn "No review confidence label found after iteration $iteration"
    fi

    # Check stop signal between iterations
    if check_stop_signal "$LOOP_ID"; then
      log_info "Stop signal detected during review phase"
      _write_result "0"
      return 1
    fi

    iteration=$((iteration + 1))
  done

  log_warn "Max review iterations ($max_iters) reached"
  # Get the final confidence
  local final_label
  if final_label=$(poll_for_label "$pr_num" "ralpr:review:" 5 5); then
    _write_result "$(extract_confidence "$final_label")"
  else
    _write_result "0"
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
    local extra
    extra=$(jq -n --argjson pr "$(_safe_num "$pr_num")" --argjson iter "$(_safe_num "$iteration")" '{pr: $pr, phase_iteration: $iter}') || extra='{}'
    _set_state "refactor" "$extra"

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
        _write_result "$conf"
        return 0
      fi
    else
      log_warn "No refactor confidence label found after iteration $iteration"
    fi

    # Check stop signal between iterations
    if check_stop_signal "$LOOP_ID"; then
      log_info "Stop signal detected during refactor phase"
      _write_result "0"
      return 1
    fi

    iteration=$((iteration + 1))
  done

  log_warn "Max refactor iterations ($max_iters) reached"
  local final_label
  if final_label=$(poll_for_label "$pr_num" "ralpr:refactor:" 5 5); then
    _write_result "$(extract_confidence "$final_label")"
  else
    _write_result "0"
  fi
  return 1
}

# ============================================================================
# RETRY WRAPPER
# ============================================================================

# Run a phase function with one retry on failure.
# Phase functions write return values via _write_result(), not stdout.
# stdout is free for script(1) to render in the tmux pane.
run_with_retry() {
  local phase_name="$1"
  shift
  local phase_fn="$1"
  shift

  if "$phase_fn" "$@"; then
    return 0
  fi

  log_warn "${phase_name} failed, retrying once..."

  if "$phase_fn" "$@"; then
    return 0
  fi

  log_error "${phase_name} failed after retry"
  return 1
}

# ============================================================================
# COMPLETION SUMMARY
# ============================================================================

print_completion_summary() {
  local status="$1"  # "done" or "stopped" or "failed"
  local status_upper
  status_upper=$(echo "$status" | tr '[:lower:]' '[:upper:]')

  local total_cycles=${#CYCLE_HISTORY[@]}

  echo ""
  echo "========================================"
  echo "          LOOP ${LOOP_ID} ${status_upper}"
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

    # Format confidence values (handle "skip" without %)
    local rv_display="${review_conf}"
    [[ "$review_conf" != "skip" ]] && rv_display="${review_conf}%"
    local rf_display="${refactor_conf}"
    [[ "$refactor_conf" != "skip" ]] && rf_display="${refactor_conf}%"

    echo "   impl: done | review: ${rv_display} | refactor: ${rf_display}"
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

  echo ""
  echo "========================================"
  echo "  RALPR Super Loop: ${LOOP_ID}"
  echo "========================================"
  echo "  Detach:  Ctrl-B D"
  echo "  Scroll:  Ctrl-B [  (then q to exit)"
  echo "  Mouse:   scroll wheel / trackpad"
  echo "  Kill:    ralpr loop stop ${LOOP_ID}"
  echo "========================================"
  echo ""

  log_info "Starting super-loop: ${LOOP_ID}"
  log_info "Working directory: $(pwd)"
  log_info "Max cycles: ${MAX_CYCLES} (0=infinite)"

  # Startup jitter: random delay (0-10s) to stagger parallel loops
  local jitter=$(( RANDOM % 11 ))
  log_info "Startup jitter: ${jitter}s"
  sleep "$jitter"

  # Check prerequisites
  if ! check_prerequisites; then
    _set_failed "prerequisites"
    exec bash
  fi

  # Clear stale state from previous runs of this loop ID
  rm -f "$(_loop_state_file "$LOOP_ID")"

  # Initialize state
  local started_at
  started_at=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
  local init_data
  init_data=$(jq -n \
    --arg id "$LOOP_ID" \
    --arg status "running" \
    --argjson max "$(_safe_num "$MAX_CYCLES")" \
    --arg started "$started_at" \
    '{id: $id, status: $status, cycle: 0, max_cycles: $max, started_at: $started}') || init_data='{"status":"running","cycle":0}'
  update_loop_state "$LOOP_ID" "$init_data"

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

    # ---- SELECT & CLAIM ----
    if ! select_and_claim; then
      log_error "Failed to select/claim a ticket"
      _set_failed "no_ticket"
      _update_pane_title "failed: no ticket"
      print_completion_summary "failed"
      exec bash
    fi

    local selection_json
    selection_json=$(_read_result)
    local sel_type sel_phase issue_num pr_num
    sel_type=$(echo "$selection_json" | jq -r '.type // "issue"')
    sel_phase=$(echo "$selection_json" | jq -r '.phase // "impl"')
    issue_num=$(echo "$selection_json" | jq -r '.issue // empty')
    pr_num=$(echo "$selection_json" | jq -r '.pr // empty')

    # Clear initial args so subsequent cycles auto-select
    INITIAL_ISSUE=""
    INITIAL_PR=""

    local review_conf="skip"
    local refactor_conf="skip"

    # ---- PHASE ROUTER ----

    # Phase 1: Implementation (if needed)
    if [[ "$sel_phase" == "impl" ]]; then
      if [[ -z "$issue_num" || "$issue_num" == "null" ]]; then
        log_error "No issue number for implementation phase"
        _set_failed "no_issue"
        _update_pane_title "failed: no issue"
        print_completion_summary "failed"
        exec bash
      fi

      if ! run_with_retry "Implementation" run_impl_phase "$issue_num"; then
        log_error "Implementation phase failed for issue #$issue_num"
        gh issue edit "$issue_num" --remove-assignee @me 2>/dev/null || true
        _set_failed "impl_failed"
        _update_pane_title "failed: impl #${issue_num}"
        print_completion_summary "failed"
        exec bash
      fi
      pr_num=$(_read_result)

      local extra
      extra=$(jq -n --argjson issue "$(_safe_num "$issue_num")" --argjson pr "$(_safe_num "$pr_num")" '{issue: $issue, pr: $pr}') || extra='{}'
      _set_state "impl_done" "$extra"

      # Check stop signal between phases
      if check_stop_signal "$LOOP_ID"; then
        log_info "Stop signal detected after implementation"
        _update_pane_title "stopped"
        print_completion_summary "stopped"
        _set_done
        exec bash
      fi

      # Fall through to review
      sel_phase="review"
    fi

    # Phase 2: Review (if needed)
    if [[ "$sel_phase" == "review" ]]; then
      if [[ -z "$pr_num" || "$pr_num" == "null" ]]; then
        log_error "No PR number for review phase"
        _set_failed "no_pr"
        _update_pane_title "failed: no PR"
        print_completion_summary "failed"
        exec bash
      fi

      if ! run_with_retry "Review" run_review_phase "$pr_num"; then
        log_error "Review phase failed for PR #$pr_num"
        _set_failed "review_failed"
        _update_pane_title "failed: review PR#${pr_num}"
        print_completion_summary "failed"
        exec bash
      fi
      review_conf=$(_read_result)

      # Check stop signal between phases
      if check_stop_signal "$LOOP_ID"; then
        log_info "Stop signal detected after review"
        _update_pane_title "stopped"
        print_completion_summary "stopped"
        _set_done
        exec bash
      fi

      # Fall through to refactor
      sel_phase="refactor"
    fi

    # Phase 3: Refactor (if needed)
    if [[ "$sel_phase" == "refactor" ]]; then
      if [[ -z "$pr_num" || "$pr_num" == "null" ]]; then
        log_error "No PR number for refactor phase"
        _set_failed "no_pr"
        _update_pane_title "failed: no PR"
        print_completion_summary "failed"
        exec bash
      fi

      if ! run_with_retry "Refactor" run_refactor_phase "$pr_num"; then
        log_error "Refactor phase failed for PR #$pr_num"
        _set_failed "refactor_failed"
        _update_pane_title "failed: refactor PR#${pr_num}"
        print_completion_summary "failed"
        exec bash
      fi
      refactor_conf=$(_read_result)
    fi

    # ---- CYCLE COMPLETE ----
    CYCLE_HISTORY+=("${issue_num:-0}:${pr_num:-0}:${review_conf}:${refactor_conf}")
    log_info "Cycle $CURRENT_CYCLE complete: Issue #${issue_num:-?} -> PR #${pr_num:-?} (review: ${review_conf}%, refactor: ${refactor_conf}%)"

    _update_pane_title "cycle ${CURRENT_CYCLE} done"
  done
}

main "$@"
