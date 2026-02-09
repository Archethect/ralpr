#!/usr/bin/env bash
# ralpr.config.sh - Ralpr v4.0 configuration
# Override any value by setting the environment variable before running Ralpr.

# ============================================================================
# ORCHESTRATOR
# ============================================================================

# Max parallel Agent Teams (each team = one issue/PR)
RALPR_MAX_PARALLEL_TEAMS="${RALPR_MAX_PARALLEL_TEAMS:-3}"

# Seconds between polling for new issues
RALPR_ISSUE_POLL_INTERVAL="${RALPR_ISSUE_POLL_INTERVAL:-60}"

# Seconds between polling for PR events (comments, CI)
RALPR_PR_POLL_INTERVAL="${RALPR_PR_POLL_INTERVAL:-30}"

# ============================================================================
# DOCKER
# ============================================================================

# Base port for noVNC (incremented per container)
RALPR_NOVNC_BASE_PORT="${RALPR_NOVNC_BASE_PORT:-6080}"

# Seconds before a silent container is considered dead
RALPR_CONTAINER_HEARTBEAT_TIMEOUT="${RALPR_CONTAINER_HEARTBEAT_TIMEOUT:-300}"

# ============================================================================
# AGENT TEAMS
# ============================================================================

# Teammate execution mode: in-process | tmux
RALPR_TEAMMATE_MODE="${RALPR_TEAMMATE_MODE:-in-process}"

# Model for Claude Code agents
RALPR_MODEL="${RALPR_MODEL:-opus}"

# Model for Codex agents
RALPR_CODEX_MODEL="${RALPR_CODEX_MODEL:-gpt-5.2-codex}"

# Max turns per stage before forcing handoff
RALPR_STAGE_MAX_TURNS="${RALPR_STAGE_MAX_TURNS:-50}"

# ============================================================================
# QUALITY
# ============================================================================

# Max quality-gate retries per task (impl fix loop)
RALPR_TASK_QUALITY_MAX_ITERATIONS="${RALPR_TASK_QUALITY_MAX_ITERATIONS:-3}"

# Max quality-gate retries at PR level
RALPR_PR_QUALITY_MAX_ITERATIONS="${RALPR_PR_QUALITY_MAX_ITERATIONS:-3}"

# Auto-rebase when merge conflicts detected
RALPR_AUTO_REBASE="${RALPR_AUTO_REBASE:-true}"

# ============================================================================
# TIERS
# ============================================================================

# Force a specific tier (unset = auto-detect from issue labels/complexity)
# Valid: small | medium | large
RALPR_FORCE_TIER="${RALPR_FORCE_TIER:-}"

# ============================================================================
# COST
# ============================================================================

# Dollar amount that triggers a warning comment on the issue
RALPR_COST_WARNING="${RALPR_COST_WARNING:-25}"

# Dollar amount that hard-stops the team
RALPR_COST_HARD_LIMIT="${RALPR_COST_HARD_LIMIT:-100}"

# ============================================================================
# CRASH RECOVERY
# ============================================================================

# Max times to resume a crashed team before giving up
RALPR_MAX_RESUME_ATTEMPTS="${RALPR_MAX_RESUME_ATTEMPTS:-2}"

# ============================================================================
# LEARNING
# ============================================================================

# Enable cross-issue learning (pattern DB)
RALPR_LEARNING_ENABLED="${RALPR_LEARNING_ENABLED:-true}"

# Days before learned patterns expire
RALPR_PATTERN_MAX_AGE_DAYS="${RALPR_PATTERN_MAX_AGE_DAYS:-90}"

# ============================================================================
# NOTIFICATIONS
# ============================================================================

# macOS native notifications (terminal-notifier / osascript)
RALPR_NOTIFY_MACOS="${RALPR_NOTIFY_MACOS:-1}"

# ============================================================================
# BRANCH / PATHS
# ============================================================================

# Branch to base feature branches on
RALPR_BASE_BRANCH="${RALPR_BASE_BRANCH:-main}"

# tmux session name
RALPR_TMUX_SESSION="${RALPR_TMUX_SESSION:-ralpr}"

# Output directory for state, logs, PID files
RALPR_OUTPUT_DIR="${RALPR_OUTPUT_DIR:-.ralpr}"

# Enable verbose debug logging
RALPR_DEBUG="${RALPR_DEBUG:-false}"

# ============================================================================
# ISSUE SELECTION
# ============================================================================

# Priority labels (checked in order)
RALPR_PRIORITY_LABELS="${RALPR_PRIORITY_LABELS:-priority:p0,P0,priority:p1,P1,priority:p2,P2}"

# Bug labels
RALPR_BUG_LABELS="${RALPR_BUG_LABELS:-bug,type:bug,kind:bug}"

# Dependency patterns in issue body (regex)
RALPR_DEPENDENCY_PATTERNS="${RALPR_DEPENDENCY_PATTERNS:-[Dd]epends on:? *#([0-9]+)}"
