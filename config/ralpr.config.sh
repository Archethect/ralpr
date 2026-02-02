#!/usr/bin/env bash
# ralpr.config.sh - Ralpr 2.1 configuration
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
