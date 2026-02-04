#!/usr/bin/env bash
# tmux.sh - tmux session and pane management for Ralpr super-loop
# Usage: source lib/tmux.sh

set -euo pipefail

_TMUX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_TMUX_LIB_DIR/common.sh"

# Load config for session name
source "$_TMUX_LIB_DIR/../../config/ralpr.config.sh"

_tmux_session() {
  echo "${RALPR_TMUX_SESSION:-ralpr-loops}"
}

# ============================================================================
# CHECKS
# ============================================================================

# Verify tmux is installed
check_tmux() {
  if ! command -v tmux &>/dev/null; then
    log_error "tmux is not installed. Install it with: brew install tmux (macOS) or apt install tmux (Linux)"
    return 1
  fi
}

# Check if the ralpr-loops session exists
session_exists() {
  local session
  session=$(_tmux_session)
  tmux has-session -t "$session" 2>/dev/null
}

# ============================================================================
# SESSION MANAGEMENT
# ============================================================================

# Create the ralpr-loops session if it doesn't exist, or verify it exists
# Returns 0 if session is ready
ensure_session() {
  local session
  session=$(_tmux_session)

  check_tmux || return 1

  if session_exists; then
    log_debug "tmux session '$session' already exists"
    return 0
  fi

  log_info "Creating tmux session: $session"
  tmux new-session -d -s "$session" -n loops

  # Configure session UX
  tmux set-option -t "$session" mouse on
  tmux set-option -t "$session" default-terminal "screen-256color"
  tmux set-option -t "$session" pane-border-status top
  tmux set-option -t "$session" pane-border-format " #{pane_index}: #{pane_title} "
  tmux set-option -t "$session" status-right " Detach: Ctrl-B D | Scroll: Ctrl-B [ "
  tmux set-option -t "$session" history-limit 50000

  log_info "tmux session '$session' created"
}

# ============================================================================
# PANE MANAGEMENT
# ============================================================================

# Add a new pane running the given command, return the pane ID
# If this is the first loop, reuses the initial idle pane; otherwise splits.
add_pane() {
  local cmd="$1"
  local session
  session=$(_tmux_session)

  local pane_count
  pane_count=$(tmux list-panes -t "${session}:loops" 2>/dev/null | wc -l | tr -d ' ')

  local pane_id

  if [[ "$pane_count" -eq 1 ]]; then
    # Check if initial pane is truly idle: must be a shell AND have no children.
    # A loop running a bash script also shows pane_current_command=bash,
    # so checking the command alone is not enough.
    local initial_pane_cmd initial_pane_pid
    initial_pane_cmd=$(tmux display-message -p -t "${session}:loops.0" '#{pane_current_command}' 2>/dev/null || echo "")
    initial_pane_pid=$(tmux display-message -p -t "${session}:loops.0" '#{pane_pid}' 2>/dev/null || echo "")

    local is_idle=false
    if [[ "$initial_pane_cmd" =~ ^-?(bash|zsh)$ ]] && [[ -n "$initial_pane_pid" ]]; then
      local child_count
      child_count=$(pgrep -P "$initial_pane_pid" 2>/dev/null | wc -l | tr -d ' ')
      [[ "${child_count:-0}" -eq 0 ]] && is_idle=true
    fi

    if [[ "$is_idle" == "true" ]]; then
      # Reuse the initial idle pane
      pane_id=$(tmux display-message -p -t "${session}:loops.0" '#{pane_id}')
      tmux send-keys -t "$pane_id" "$cmd" Enter
    else
      # Pane is busy (already running a loop), split
      pane_id=$(tmux split-window -t "${session}:loops" -P -F '#{pane_id}' "$cmd")
    fi
  else
    # Multiple panes, always split
    pane_id=$(tmux split-window -t "${session}:loops" -P -F '#{pane_id}' "$cmd")
  fi

  echo "$pane_id"
}

# Rebalance the pane layout to a tiled grid
rebalance_layout() {
  local session
  session=$(_tmux_session)

  tmux select-layout -t "${session}:loops" tiled 2>/dev/null || true
}

# Set the title of a pane
set_pane_title() {
  local pane_id="$1"
  local title="$2"

  tmux select-pane -t "$pane_id" -T "$title" 2>/dev/null || true
}

# Kill a specific pane
kill_pane() {
  local pane_id="$1"

  tmux kill-pane -t "$pane_id" 2>/dev/null || true
}

# ============================================================================
# ATTACH/DETACH
# ============================================================================

# Smart attach: detect if already in tmux and switch, otherwise attach
attach_session() {
  local session
  session=$(_tmux_session)

  if ! session_exists; then
    log_error "No ralpr-loops session found. Start a loop first with: ralpr loop start"
    return 1
  fi

  if [[ -n "${TMUX:-}" ]]; then
    # Already inside tmux, switch client
    tmux switch-client -t "$session"
  else
    # Not in tmux, attach
    tmux attach-session -t "$session"
  fi
}
