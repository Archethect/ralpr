#!/usr/bin/env bash
# ci-watcher.sh - Wait for CI completion using gh run watch
# Usage: source lib/ci-watcher.sh

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIB_DIR/common.sh"

# ============================================================================
# CI STATUS CHECKING
# ============================================================================

# Get latest workflow run for a branch
get_latest_run_id() {
  local branch="${1:-$(git branch --show-current)}"

  gh run list --branch "$branch" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo ""
}

# Get run status
get_run_status() {
  local run_id="$1"

  gh run view "$run_id" --json status,conclusion --jq '{status: .status, conclusion: .conclusion}' 2>/dev/null || echo '{"status":"unknown","conclusion":"unknown"}'
}

# Check if any workflows exist
has_workflows() {
  local count
  count=$(gh workflow list --json name --jq 'length' 2>/dev/null || echo "0")
  [[ "$count" -gt 0 ]]
}

# ============================================================================
# CI WAITING
# ============================================================================

# Wait for CI to complete on a branch
# Returns: 0 if success, 1 if failed, 2 if timeout, 3 if no workflows
wait_for_ci() {
  local branch="${1:-$(git branch --show-current)}"
  local timeout="${2:-600}"  # Default 10 minutes

  log_phase "Waiting for CI on branch: $branch"

  # Check if workflows exist
  if ! has_workflows; then
    log_warn "No GitHub Actions workflows configured"
    return 3
  fi

  # Wait for runs to appear (may take a moment after push)
  local waited=0
  local initial_wait=60
  local run_id=""

  while [[ $waited -lt $initial_wait ]]; do
    run_id=$(get_latest_run_id "$branch")

    if [[ -n "$run_id" ]]; then
      break
    fi

    log_info "Waiting for CI runs to appear... (${waited}s)"
    sleep 10
    waited=$((waited + 10))
  done

  if [[ -z "$run_id" ]]; then
    log_warn "No CI runs appeared after ${initial_wait}s"
    return 3
  fi

  log_info "Watching run #$run_id..."

  # Use gh run watch with timeout
  if timeout "$timeout" gh run watch "$run_id" --exit-status; then
    log_info "✓ CI passed"
    return 0
  else
    local exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
      log_warn "CI timed out after ${timeout}s"
      return 2
    else
      log_error "✗ CI failed"
      return 1
    fi
  fi
}

# Wait for specific workflow by name
wait_for_workflow() {
  local workflow_name="$1"
  local branch="${2:-$(git branch --show-current)}"
  local timeout="${3:-600}"

  log_phase "Waiting for workflow '$workflow_name' on branch: $branch"

  # Get workflow ID
  local workflow_id
  workflow_id=$(gh workflow list --json name,id --jq ".[] | select(.name == \"$workflow_name\") | .id" 2>/dev/null || echo "")

  if [[ -z "$workflow_id" ]]; then
    log_error "Workflow '$workflow_name' not found"
    return 1
  fi

  # Wait for runs to appear
  local waited=0
  local initial_wait=60
  local run_id=""

  while [[ $waited -lt $initial_wait ]]; do
    run_id=$(gh run list --workflow "$workflow_id" --branch "$branch" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")

    if [[ -n "$run_id" ]]; then
      break
    fi

    log_info "Waiting for workflow runs... (${waited}s)"
    sleep 10
    waited=$((waited + 10))
  done

  if [[ -z "$run_id" ]]; then
    log_warn "No runs appeared for workflow '$workflow_name'"
    return 3
  fi

  log_info "Watching run #$run_id..."

  if timeout "$timeout" gh run watch "$run_id" --exit-status; then
    log_info "✓ Workflow passed"
    return 0
  else
    local exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
      log_warn "Workflow timed out"
      return 2
    else
      log_error "✗ Workflow failed"
      return 1
    fi
  fi
}

# ============================================================================
# CI LOGS
# ============================================================================

# Get failed job logs
get_failed_logs() {
  local run_id="${1:-}"
  local branch="${2:-$(git branch --show-current)}"

  if [[ -z "$run_id" ]]; then
    run_id=$(get_latest_run_id "$branch")
  fi

  if [[ -z "$run_id" ]]; then
    log_error "No run found"
    return 1
  fi

  log_info "Fetching failed logs for run #$run_id..."
  gh run view "$run_id" --log-failed
}

# Get full job logs
get_full_logs() {
  local run_id="${1:-}"
  local branch="${2:-$(git branch --show-current)}"

  if [[ -z "$run_id" ]]; then
    run_id=$(get_latest_run_id "$branch")
  fi

  if [[ -z "$run_id" ]]; then
    log_error "No run found"
    return 1
  fi

  log_info "Fetching full logs for run #$run_id..."
  gh run view "$run_id" --log
}

# ============================================================================
# CI STATUS SUMMARY
# ============================================================================

# Get CI status summary as JSON
get_ci_summary() {
  local branch="${1:-$(git branch --show-current)}"

  local run_id
  run_id=$(get_latest_run_id "$branch")

  if [[ -z "$run_id" ]]; then
    echo '{"status":"no_runs","branch":"'"$branch"'"}'
    return
  fi

  local run_info
  run_info=$(gh run view "$run_id" --json status,conclusion,url,name,createdAt 2>/dev/null || echo '{}')

  echo "$run_info" | jq --arg run_id "$run_id" --arg branch "$branch" '. + {run_id: $run_id, branch: $branch}'
}

# Check if CI is currently running
is_ci_running() {
  local branch="${1:-$(git branch --show-current)}"

  local in_progress
  in_progress=$(gh run list --branch "$branch" --status in_progress --json databaseId --jq 'length' 2>/dev/null || echo "0")

  [[ "$in_progress" -gt 0 ]]
}

# Trigger a workflow dispatch
trigger_workflow() {
  local workflow_name="$1"
  local branch="${2:-$(git branch --show-current)}"

  log_info "Triggering workflow: $workflow_name"

  gh workflow run "$workflow_name" --ref "$branch"
}
