#!/usr/bin/env bash
# loop-state.sh - Loop registry and state file management for Ralpr super-loop
# Usage: source lib/loop-state.sh

set -euo pipefail

_LOOP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LOOP_LIB_DIR/common.sh"

# Load config for state directory path
source "$_LOOP_LIB_DIR/../../config/ralpr.config.sh"

# ============================================================================
# PATHS
# ============================================================================

_loop_state_dir() {
  echo "${RALPR_LOOP_STATE_DIR:-.ralpr/loops}"
}

_loop_registry_file() {
  echo "$(_loop_state_dir)/registry.json"
}

_loop_dir() {
  local id="$1"
  echo "$(_loop_state_dir)/$id"
}

_loop_state_file() {
  local id="$1"
  echo "$(_loop_dir "$id")/state.json"
}

_loop_stop_file() {
  local id="$1"
  echo "$(_loop_dir "$id")/stop"
}

# ============================================================================
# REGISTRY MANAGEMENT (with mkdir-based locking — POSIX portable)
# ============================================================================

# Acquire an exclusive lock using mkdir (atomic on all POSIX systems).
# Spins with short sleeps; gives up after ~5 seconds then forces stale cleanup.
_acquire_lock() {
  local lockdir="$1"
  local attempts=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 50 ]]; then
      log_debug "Removing stale lock: $lockdir"
      rm -rf "$lockdir"
      if mkdir "$lockdir" 2>/dev/null; then
        return 0
      fi
      log_error "Failed to acquire lock after stale cleanup: $lockdir"
      return 1
    fi
    sleep 0.1
  done
}

_release_lock() {
  local lockdir="$1"
  rm -rf "$lockdir"
}

# Initialize the loop registry if it doesn't exist
init_loop_registry() {
  local state_dir
  state_dir=$(_loop_state_dir)
  local registry
  registry=$(_loop_registry_file)

  mkdir -p "$state_dir"

  if [[ ! -f "$registry" ]]; then
    echo '{"next_id":1,"loops":{}}' | jq . > "$registry"
    log_debug "Created loop registry at $registry"
  fi
}

# Get the next loop ID and increment the counter (atomic with mkdir lock)
next_loop_id() {
  local registry
  registry=$(_loop_registry_file)
  local lockdir="${registry}.lock"

  init_loop_registry

  _acquire_lock "$lockdir" || return 1

  local next_id
  next_id=$(jq -r '.next_id' "$registry")
  jq ".next_id = $((next_id + 1))" "$registry" > "${registry}.tmp"
  mv "${registry}.tmp" "$registry"

  _release_lock "$lockdir"
  echo "$next_id"
}

# Register a new loop in the registry
register_loop() {
  local id="$1"
  local pid="$2"
  local pane="$3"
  local registry
  registry=$(_loop_registry_file)
  local lockdir="${registry}.lock"

  init_loop_registry

  local created_at
  created_at=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

  _acquire_lock "$lockdir" || return 1

  jq --arg id "$id" --argjson pid "$pid" --arg pane "$pane" --arg ts "$created_at" \
    '.loops[$id] = {"pid": $pid, "tmux_pane": $pane, "created_at": $ts}' \
    "$registry" > "${registry}.tmp"
  mv "${registry}.tmp" "$registry"

  _release_lock "$lockdir"

  # Create the loop state directory
  mkdir -p "$(_loop_dir "$id")"
  log_debug "Registered loop $id (pid=$pid, pane=$pane)"
}

# Remove a loop from the registry
unregister_loop() {
  local id="$1"
  local registry
  registry=$(_loop_registry_file)
  local lockdir="${registry}.lock"

  [[ ! -f "$registry" ]] && return 0

  _acquire_lock "$lockdir" || return 1

  jq --arg id "$id" 'del(.loops[$id])' "$registry" > "${registry}.tmp"
  mv "${registry}.tmp" "$registry"

  _release_lock "$lockdir"

  log_debug "Unregistered loop $id"
}

# ============================================================================
# STATE FILE MANAGEMENT
# ============================================================================

# Update loop state (merges provided JSON into existing state)
update_loop_state() {
  local id="$1"
  local data="$2"
  local state_file
  state_file=$(_loop_state_file "$id")
  local loop_dir
  loop_dir=$(_loop_dir "$id")

  # Validate data is valid JSON before attempting merge
  if [[ -z "$data" ]] || ! echo "$data" | jq empty 2>/dev/null; then
    log_warn "update_loop_state: invalid JSON data, skipping"
    return 0
  fi

  mkdir -p "$loop_dir"

  local now
  now=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

  if [[ -f "$state_file" ]]; then
    jq --argjson new "$data" --arg ts "$now" \
      '. * $new | .last_activity = $ts' \
      "$state_file" > "${state_file}.tmp"
  else
    echo "$data" | jq --arg ts "$now" '. + {last_activity: $ts}' > "${state_file}.tmp"
  fi
  mv "${state_file}.tmp" "$state_file"
}

# Read loop state (returns valid JSON or empty object)
read_loop_state() {
  local id="$1"
  local state_file
  state_file=$(_loop_state_file "$id")

  if [[ -f "$state_file" ]]; then
    # Capture output; only use it if jq succeeded (avoids partial JSON on race)
    local content
    if content=$(jq '.' "$state_file" 2>/dev/null); then
      echo "$content"
    else
      echo '{}'
    fi
  else
    echo '{}'
  fi
}

# ============================================================================
# STOP SIGNAL
# ============================================================================

# Create a stop signal for a loop
create_stop_signal() {
  local id="$1"
  local stop_file
  stop_file=$(_loop_stop_file "$id")

  mkdir -p "$(_loop_dir "$id")"
  touch "$stop_file"
  log_info "Stop signal created for loop $id"
}

# Check if a stop signal exists
check_stop_signal() {
  local id="$1"
  local stop_file
  stop_file=$(_loop_stop_file "$id")

  [[ -f "$stop_file" ]]
}

# ============================================================================
# LISTING & CLEANUP
# ============================================================================

# List all registered loops with enriched state data
# Output: one JSON object per line
list_all_loops() {
  local registry
  registry=$(_loop_registry_file)

  [[ ! -f "$registry" ]] && return 0

  local loop_ids
  loop_ids=$(jq -r '.loops | keys[]' "$registry" 2>/dev/null)

  for id in $loop_ids; do
    local reg_data state_data pid

    reg_data=$(jq -r --arg id "$id" '.loops[$id]' "$registry")
    state_data=$(read_loop_state "$id")
    pid=$(echo "$reg_data" | jq -r '.pid // empty')

    # Merge registry data with state data, then override status if PID is dead
    local merged
    merged=$(echo "$reg_data" | jq -c --argjson state "$state_data" --arg id "$id" \
      '{id: $id} + . + $state')

    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      merged=$(echo "$merged" | jq -c '.status = "dead"')
    fi

    echo "$merged"
  done
}

# Clean up a loop: remove state directory and release GitHub assignments
cleanup_loop() {
  local id="$1"
  local loop_dir
  loop_dir=$(_loop_dir "$id")

  # Read state to find any assigned issue/PR
  local state
  state=$(read_loop_state "$id")

  local issue pr
  issue=$(echo "$state" | jq -r '.issue // empty')
  pr=$(echo "$state" | jq -r '.pr // empty')

  # Release GitHub assignments
  if [[ -n "$issue" ]]; then
    log_info "Releasing issue #$issue assignment..."
    gh issue edit "$issue" --remove-assignee @me >/dev/null 2>&1 || true
  fi
  if [[ -n "$pr" ]]; then
    log_info "Releasing PR #$pr assignment..."
    gh pr edit "$pr" --remove-assignee @me >/dev/null 2>&1 || true
  fi

  # Remove state directory
  if [[ -d "$loop_dir" ]]; then
    rm -rf "$loop_dir"
    log_debug "Removed state directory: $loop_dir"
  fi

  # Unregister from registry
  unregister_loop "$id"

  log_info "Cleaned up loop $id"
}

# Purge all dead loops from the registry
# Returns the number of loops purged
purge_dead_loops() {
  local registry
  registry=$(_loop_registry_file)

  [[ ! -f "$registry" ]] && echo "0" && return 0

  local loop_ids
  loop_ids=$(jq -r '.loops | keys[]' "$registry" 2>/dev/null)
  [[ -z "$loop_ids" ]] && echo "0" && return 0

  local count=0
  for id in $loop_ids; do
    local pid
    pid=$(jq -r --arg id "$id" '.loops[$id].pid // empty' "$registry")

    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      cleanup_loop "$id"
      count=$((count + 1))
    fi
  done

  echo "$count"
}
