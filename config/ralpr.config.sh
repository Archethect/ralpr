#!/usr/bin/env bash
# ralpr.config.sh - Ralpr 2.0 configuration
# This file is sourced by Ralpr scripts to get configurable values
#
# Override by setting environment variables before running Ralpr

# ============================================================================
# PHASE 1: IMPLEMENTATION
# ============================================================================

# Enable worktree isolation (recommended for parallel work)
IMPL_WORKTREE_ENABLED="${IMPL_WORKTREE_ENABLED:-true}"

# Default worktree directory
IMPL_WORKTREE_BASE="${IMPL_WORKTREE_BASE:-.worktrees}"

# ============================================================================
# PHASE 2: REVIEW
# ============================================================================

# Confidence threshold to pass review (0-100)
REVIEW_THRESHOLD="${REVIEW_THRESHOLD:-85}"

# Maximum review loop iterations
REVIEW_MAX_LOOPS="${REVIEW_MAX_LOOPS:-7}"

# Confidence weights (must sum to 1.0)
# - convergence:     Are we finding fewer issues over time?
# - resolution:      Are we fixing what we find?
# - consensus:       Do reviewers agree?
# - test_quality:    Tests passing + code coverage
# - severity_trend:  Is max severity decreasing?
REVIEW_WEIGHTS_CONVERGENCE="${REVIEW_WEIGHTS_CONVERGENCE:-0.30}"
REVIEW_WEIGHTS_RESOLUTION="${REVIEW_WEIGHTS_RESOLUTION:-0.25}"
REVIEW_WEIGHTS_CONSENSUS="${REVIEW_WEIGHTS_CONSENSUS:-0.20}"
REVIEW_WEIGHTS_TEST_QUALITY="${REVIEW_WEIGHTS_TEST_QUALITY:-0.15}"
REVIEW_WEIGHTS_SEVERITY_TREND="${REVIEW_WEIGHTS_SEVERITY_TREND:-0.10}"

# ============================================================================
# PHASE 3: REFACTOR
# ============================================================================

# Confidence threshold to pass refactor (0-100)
REFACTOR_THRESHOLD="${REFACTOR_THRESHOLD:-85}"

# Maximum refactor loop iterations
REFACTOR_MAX_LOOPS="${REFACTOR_MAX_LOOPS:-5}"

# Confidence weights (must sum to 1.0)
REFACTOR_WEIGHTS_SKILL="${REFACTOR_WEIGHTS_SKILL:-0.70}"      # Skill confidence
REFACTOR_WEIGHTS_STABILITY="${REFACTOR_WEIGHTS_STABILITY:-0.30}"  # Test stability

# ============================================================================
# CI SETTINGS
# ============================================================================

# CI wait timeout in seconds
CI_TIMEOUT="${CI_TIMEOUT:-600}"

# CI poll interval in seconds (when not using gh run watch)
CI_POLL_INTERVAL="${CI_POLL_INTERVAL:-30}"

# ============================================================================
# AGENT SETTINGS
# ============================================================================

# Maximum turns for subagents
AGENT_MAX_TURNS_EXPLORE="${AGENT_MAX_TURNS_EXPLORE:-20}"
AGENT_MAX_TURNS_UNDERSTAND="${AGENT_MAX_TURNS_UNDERSTAND:-15}"
AGENT_MAX_TURNS_IMPLEMENT="${AGENT_MAX_TURNS_IMPLEMENT:-100}"
AGENT_MAX_TURNS_REVIEWER="${AGENT_MAX_TURNS_REVIEWER:-30}"

# ============================================================================
# CLAUDE SETTINGS
# ============================================================================

# Claude model to use for fresh sessions
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"

# Allowed tools for review/refactor sessions
CLAUDE_ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-Task,Bash,Read,Edit,Write,Glob,Grep,Skill}"

# ============================================================================
# DEBUG SETTINGS
# ============================================================================

# Enable verbose debug logging
RALPR_DEBUG="${RALPR_DEBUG:-false}"

# Keep intermediate files for debugging
RALPR_KEEP_TEMP="${RALPR_KEEP_TEMP:-false}"

# ============================================================================
# PATHS
# ============================================================================

# Output directory for Ralpr state/logs
RALPR_OUTPUT_DIR="${RALPR_OUTPUT_DIR:-.ralpr}"

# Codebase map location
RALPR_MAP_PATH="${RALPR_MAP_PATH:-docs/.codebase-map.json}"
