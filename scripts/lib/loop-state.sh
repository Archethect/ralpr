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
# REGISTRY MANAGEMENT (with file locking)
# ============================================================================

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

# Get the next loop ID and increment the counter (atomic with flock)
next_loop_id() {
  local registry
  registry=$(_loop_registry_file)

  init_loop_registry

  local next_id
  (
    flock -x 200
    next_id=$(jq -r '.next_id' "$registry")
    jq ".next_id = $((next_id + 1))" "$registry" > "${registry}.tmp"
    mv "${registry}.tmp" "$registry"
    echo "$next_id"
  ) 200>"${registry}.lock"
}

# Register a new loop in the registry
register_loop() {
  local id="$1"
  local pid="$2"
  local pane="$3"
  local registry
  registry=$(_loop_registry_file)

  init_loop_registry

  local created_at
  created_at=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

  (
    flock -x 200
    jq --arg id "$id" --argjson pid "$pid" --arg pane "$pane" --arg ts "$created_at" \
      '.loops[$id] = {"pid": $pid, "tmux_pane": $pane, "created_at": $ts}' \
      "$registry" > "${registry}.tmp"
    mv "${registry}.tmp" "$registry"
  ) 200>"${registry}.lock"

  # Create the loop state directory
  mkdir -p "$(_loop_dir "$id")"
  log_debug "Registered loop $id (pid=$pid, pane=$pane)"
}

# Remove a loop from the registry
unregister_loop() {
  local id="$1"
  local registry
  registry=$(_loop_registry_file)

  [[ ! -f "$registry" ]] && return 0

  (
    flock -x 200
    jq --arg id "$id" 'del(.loops[$id])' "$registry" > "${registry}.tmp"
    mv "${registry}.tmp" "$registry"
  ) 200>"${registry}.lock"

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

  mkdir -p "$loop_dir"

  local now
  now=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

  if [[ -f "$state_file" ]]; then
    jq --argjson new "$data" --arg ts "$now" \
      '. * $new | .last_activity = $ts' \
      "$state_file" > "${state_file}.tmp"
    mv "${state_file}.tmp" "$state_file"
  else
    echo "$data" | jq --arg ts "$now" '. + {last_activity: $ts}' > "$state_file"
  fi
}

# Read loop state (returns JSON or empty object)
read_loop_state() {
  local id="$1"
  local state_file
  state_file=$(_loop_state_file "$id")

  if [[ -f "$state_file" ]]; then
    cat "$state_file"
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
    local reg_data state_data

    reg_data=$(jq -r --arg id "$id" '.loops[$id]' "$registry")
    state_data=$(read_loop_state "$id")

    # Merge registry data with state data
    echo "$reg_data" | jq --argjson state "$state_data" --arg id "$id" \
      '{id: $id} + . + $state'
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
    gh issue edit "$issue" --remove-assignee @me 2>/dev/null || true
  fi
  if [[ -n "$pr" ]]; then
    log_info "Releasing PR #$pr assignment..."
    gh pr edit "$pr" --remove-assignee @me 2>/dev/null || true
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
