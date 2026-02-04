#!/usr/bin/env bash
# ralpr.config.sh - Ralpr 3.0 configuration
# This file is sourced by Ralpr scripts to get configurable values
#
# Override by setting environment variables before running Ralpr

# ============================================================================
# PHASE 2: REVIEW
# ============================================================================

# Confidence threshold to pass review (0-100)
REVIEW_THRESHOLD="${REVIEW_THRESHOLD:-85}"

# Maximum review loop iterations
REVIEW_MAX_LOOPS="${REVIEW_MAX_LOOPS:-7}"

# Base confidence for review phase (starting point)
REVIEW_BASE_CONFIDENCE="${REVIEW_BASE_CONFIDENCE:-40}"

# ============================================================================
# PHASE 3: REFACTOR
# ============================================================================

# Confidence threshold to pass refactor (0-100)
REFACTOR_THRESHOLD="${REFACTOR_THRESHOLD:-85}"

# Maximum refactor loop iterations
REFACTOR_MAX_LOOPS="${REFACTOR_MAX_LOOPS:-5}"

# Confidence weights for refactor phase (must sum to 1.0)
REFACTOR_WEIGHTS_SKILL="${REFACTOR_WEIGHTS_SKILL:-0.70}"
REFACTOR_WEIGHTS_STABILITY="${REFACTOR_WEIGHTS_STABILITY:-0.30}"

# ============================================================================
# BRANCH SETTINGS
# ============================================================================

# Branch to base feature branches on (overrides GitHub default)
# Set to "main" if GitHub default is "release" but features should start from "main"
RALPR_BASE_BRANCH="${RALPR_BASE_BRANCH:-main}"

# ============================================================================
# CLAUDE SETTINGS
# ============================================================================

# Allowed tools for review/refactor sessions
CLAUDE_ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-Task,Bash,Read,Edit,Write,Glob,Grep,Skill}"

# ============================================================================
# DEBUG SETTINGS
# ============================================================================

# Enable verbose debug logging
RALPR_DEBUG="${RALPR_DEBUG:-false}"

# ============================================================================
# PATHS
# ============================================================================

# Output directory for Ralpr state/logs
RALPR_OUTPUT_DIR="${RALPR_OUTPUT_DIR:-.ralpr}"

# ============================================================================
# SUPER LOOP (v3.0)
# ============================================================================

# tmux session name for loop monitoring
RALPR_TMUX_SESSION="${RALPR_TMUX_SESSION:-ralpr-loops}"

# Default max cycles per loop (0 = infinite)
RALPR_LOOP_MAX_CYCLES="${RALPR_LOOP_MAX_CYCLES:-0}"

# Log directory for loop output
RALPR_LOOP_LOG_DIR="${RALPR_LOOP_LOG_DIR:-.ralpr/logs}"

# Loop state directory (registry + per-loop state)
RALPR_LOOP_STATE_DIR="${RALPR_LOOP_STATE_DIR:-.ralpr/loops}"

# Docker wrapper command for spawning Claude sessions
RALPR_DOCKER_CMD="${RALPR_DOCKER_CMD:-claude-docker}"

# GitHub label polling interval (seconds)
RALPR_LABEL_POLL_INTERVAL="${RALPR_LABEL_POLL_INTERVAL:-10}"

# GitHub label polling timeout (seconds)
RALPR_LABEL_POLL_TIMEOUT="${RALPR_LABEL_POLL_TIMEOUT:-60}"

# ============================================================================
# ISSUE SELECTION
# ============================================================================

# Priority labels: pipe-separated tiers, comma-separated within tier
# Tiers are evaluated in order (first tier = highest priority)
RALPR_PRIORITY_LABELS="${RALPR_PRIORITY_LABELS:-priority:p0,P0|priority:p1,P1|priority:p2,P2}"

# Bug labels (comma-separated)
RALPR_BUG_LABELS="${RALPR_BUG_LABELS:-bug,type:bug,kind:bug}"

# Dependency patterns (comma-separated regex, each with capture group for issue number)
RALPR_DEPENDENCY_PATTERNS="${RALPR_DEPENDENCY_PATTERNS:-[Dd]epends on:? *#([0-9]+),[Bb]locked by:? *#([0-9]+)}"
