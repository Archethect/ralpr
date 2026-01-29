#!/usr/bin/env bash
# github-labels.sh - Ralpr label management for PR phases
# Usage: source lib/github-labels.sh
#
# Compatible with bash 3.2+ (macOS default)

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIB_DIR/common.sh"

# ============================================================================
# LABEL DEFINITIONS (bash 3.2 compatible - no associative arrays)
# ============================================================================

# Get color for Ralpr label
get_label_color() {
  local label="$1"
  case "$label" in
    ralpr:implementation) echo "1f883d" ;;   # Green
    ralpr:impl:done)      echo "238636" ;;   # Dark green
    ralpr:review)         echo "a371f7" ;;   # Purple
    ralpr:refactor)       echo "d29922" ;;   # Orange
    ralpr:blocked)        echo "d73a4a" ;;   # Red
    ralpr:needs-human)    echo "e99695" ;;   # Light red
    ralpr:review:*)       echo "238636" ;;   # Green for confidence labels
    ralpr:refactor:*)     echo "238636" ;;   # Green for confidence labels
    *)                    echo "0366d6" ;;   # Default blue
  esac
}

# List all Ralpr labels
list_ralpr_labels() {
  echo "ralpr:implementation"
  echo "ralpr:impl:done"
  echo "ralpr:review"
  echo "ralpr:refactor"
  echo "ralpr:blocked"
  echo "ralpr:needs-human"
}

# ============================================================================
# LABEL MANAGEMENT
# ============================================================================

# Ensure all Ralpr labels exist on the repo
setup_ralpr_labels() {
  log_info "Setting up Ralpr labels..."

  for label in $(list_ralpr_labels); do
    local color
    color=$(get_label_color "$label")
    ensure_label "$label" "$color" "Ralpr automated label"
  done

  log_info "Ralpr labels configured"
}

# Get current Ralpr label on a PR
get_ralpr_label() {
  local pr_number="$1"

  gh pr view "$pr_number" --json labels --jq '.labels[].name' 2>/dev/null | grep "^ralpr:" | head -1 || echo ""
}

# Remove all Ralpr labels from a PR (preserves iteration labels)
remove_all_ralpr_labels() {
  local pr_number="$1"

  local current_labels
  current_labels=$(gh pr view "$pr_number" --json labels --jq '.labels[].name' 2>/dev/null | grep "^ralpr:" || true)

  for label in $current_labels; do
    # Preserve iteration labels (ralpr:review:iter:N, ralpr:refactor:iter:N)
    if echo "$label" | grep -qE '^ralpr:(review|refactor):iter:[0-9]+$'; then
      continue
    fi
    gh pr edit "$pr_number" --remove-label "$label" 2>/dev/null || true
  done
}

# Remove only confidence labels for a specific phase (preserves impl:done and other phase labels)
remove_phase_confidence_labels() {
  local pr_number="$1"
  local phase="$2"

  gh pr view "$pr_number" --json labels --jq '.labels[].name' 2>/dev/null | \
    grep "^ralpr:${phase}:[0-9]\+$" | \
    while read -r label; do
      gh pr edit "$pr_number" --remove-label "$label" 2>/dev/null || true
    done
}

# ============================================================================
# ITERATION TRACKING
# ============================================================================

# Get current review iteration from label (returns 0 if no iteration label)
get_review_iteration() {
  local pr_number="$1"

  local label
  label=$(gh pr view "$pr_number" --json labels --jq '.labels[].name' 2>/dev/null | grep "^ralpr:review:iter:" | head -1 || echo "")

  if [ -n "$label" ]; then
    echo "$label" | sed 's/.*:iter://'
  else
    echo "0"
  fi
}

# Set review iteration label (increments current iteration)
increment_review_iteration() {
  local pr_number="$1"

  local current_iter
  current_iter=$(get_review_iteration "$pr_number")
  local new_iter=$((current_iter + 1))

  local old_label="ralpr:review:iter:$current_iter"
  local new_label="ralpr:review:iter:$new_iter"

  log_info "Review iteration: $current_iter -> $new_iter"

  # Remove old iteration label if exists
  if [ "$current_iter" -gt 0 ]; then
    gh pr edit "$pr_number" --remove-label "$old_label" 2>/dev/null || true
  fi

  # Create and add new iteration label
  ensure_label "$new_label" "6e7681" "Ralpr review iteration $new_iter"
  gh pr edit "$pr_number" --add-label "$new_label" 2>/dev/null || true

  echo "$new_iter"
}

# Get current refactor iteration from label (returns 0 if no iteration label)
get_refactor_iteration() {
  local pr_number="$1"

  local label
  label=$(gh pr view "$pr_number" --json labels --jq '.labels[].name' 2>/dev/null | grep "^ralpr:refactor:iter:" | head -1 || echo "")

  if [ -n "$label" ]; then
    echo "$label" | sed 's/.*:iter://'
  else
    echo "0"
  fi
}

# Set refactor iteration label (increments current iteration)
increment_refactor_iteration() {
  local pr_number="$1"

  local current_iter
  current_iter=$(get_refactor_iteration "$pr_number")
  local new_iter=$((current_iter + 1))

  local old_label="ralpr:refactor:iter:$current_iter"
  local new_label="ralpr:refactor:iter:$new_iter"

  log_info "Refactor iteration: $current_iter -> $new_iter"

  # Remove old iteration label if exists
  if [ "$current_iter" -gt 0 ]; then
    gh pr edit "$pr_number" --remove-label "$old_label" 2>/dev/null || true
  fi

  # Create and add new iteration label
  ensure_label "$new_label" "6e7681" "Ralpr refactor iteration $new_iter"
  gh pr edit "$pr_number" --add-label "$new_label" 2>/dev/null || true

  echo "$new_iter"
}

# Set phase label on PR (removes other Ralpr labels first)
set_phase_label() {
  local pr_number="$1"
  local phase="$2"

  # Validate phase
  case "$phase" in
    implementation|impl:done|review|refactor|blocked|needs-human)
      ;;
    *)
      log_error "Invalid phase: $phase"
      return 1
      ;;
  esac

  local label="ralpr:$phase"
  local color
  color=$(get_label_color "$label")

  log_info "Setting label: $label on PR #$pr_number"

  # Remove existing Ralpr labels
  remove_all_ralpr_labels "$pr_number"

  # Ensure label exists
  ensure_label "$label" "$color" "Ralpr phase label"

  # Add new label
  gh pr edit "$pr_number" --add-label "$label"
}

# Set review confidence label (ralpr:review:XX)
# Preserves ralpr:impl:done label - only removes old review confidence labels
set_review_confidence_label() {
  local pr_number="$1"
  local confidence="$2"

  # Validate confidence is a number 0-100
  if ! echo "$confidence" | grep -qE '^[0-9]+$' || [ "$confidence" -lt 0 ] || [ "$confidence" -gt 100 ]; then
    log_error "Invalid confidence: $confidence (must be 0-100)"
    return 1
  fi

  local label="ralpr:review:$confidence"

  log_info "Setting confidence label: $label on PR #$pr_number"

  # Remove ONLY old review confidence labels (preserves impl:done)
  remove_phase_confidence_labels "$pr_number" "review"

  # Create label if needed (green for high confidence, yellow for medium)
  local color="238636"  # Green
  if [ "$confidence" -lt 90 ]; then
    color="d29922"  # Orange
  fi
  if [ "$confidence" -lt 70 ]; then
    color="d73a4a"  # Red
  fi

  ensure_label "$label" "$color" "Ralpr review confidence: $confidence%"

  # Add label
  gh pr edit "$pr_number" --add-label "$label"
}

# Set refactor confidence label (ralpr:refactor:XX)
# Preserves ralpr:impl:done AND review confidence labels - only removes old refactor confidence labels
set_refactor_confidence_label() {
  local pr_number="$1"
  local confidence="$2"

  # Validate confidence
  if ! echo "$confidence" | grep -qE '^[0-9]+$' || [ "$confidence" -lt 0 ] || [ "$confidence" -gt 100 ]; then
    log_error "Invalid confidence: $confidence (must be 0-100)"
    return 1
  fi

  local label="ralpr:refactor:$confidence"

  log_info "Setting confidence label: $label on PR #$pr_number"

  # Remove ONLY old refactor confidence labels (preserves impl:done AND review labels)
  remove_phase_confidence_labels "$pr_number" "refactor"

  # Create label if needed
  local color="238636"  # Green
  if [ "$confidence" -lt 95 ]; then
    color="d29922"  # Orange
  fi
  if [ "$confidence" -lt 80 ]; then
    color="d73a4a"  # Red
  fi

  ensure_label "$label" "$color" "Ralpr refactor confidence: $confidence%"

  # Add label
  gh pr edit "$pr_number" --add-label "$label"
}

# Get current phase from PR labels
get_current_phase() {
  local pr_number="$1"

  local label
  label=$(get_ralpr_label "$pr_number")

  case "$label" in
    ralpr:implementation)
      echo "implementation"
      ;;
    ralpr:impl:done)
      echo "impl:done"
      ;;
    ralpr:review)
      echo "review"
      ;;
    ralpr:review:*)
      echo "review:complete"
      ;;
    ralpr:refactor)
      echo "refactor"
      ;;
    ralpr:refactor:*)
      echo "refactor:complete"
      ;;
    ralpr:blocked)
      echo "blocked"
      ;;
    ralpr:needs-human)
      echo "needs-human"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# Get confidence score from label (if any)
get_confidence_from_label() {
  local pr_number="$1"

  local label
  label=$(get_ralpr_label "$pr_number")

  # Extract number from ralpr:review:XX or ralpr:refactor:XX
  if echo "$label" | grep -qE '^ralpr:(review|refactor):[0-9]+$'; then
    echo "$label" | sed 's/.*://'
  else
    echo ""
  fi
}

# Determine next phase based on current state
get_next_phase() {
  local pr_number="$1"

  local current
  current=$(get_current_phase "$pr_number")

  case "$current" in
    unknown|implementation)
      echo "impl:done"
      ;;
    impl:done)
      echo "review"
      ;;
    review|review:complete)
      echo "refactor"
      ;;
    refactor|refactor:complete)
      echo "done"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# Check if PR is ready for auto-selection for a phase
is_ready_for_phase() {
  local pr_number="$1"
  local target_phase="$2"

  local current
  current=$(get_current_phase "$pr_number")

  case "$target_phase" in
    review)
      # Ready for review if implementation is done
      [ "$current" = "impl:done" ]
      ;;
    refactor)
      # Ready for refactor if review confidence >= 90
      if [ "$current" = "review:complete" ]; then
        local conf
        conf=$(get_confidence_from_label "$pr_number")
        [ -n "$conf" ] && [ "$conf" -ge 90 ]
      else
        return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}
