#!/usr/bin/env bash
# confidence.sh - Calculate confidence scores for Ralpr phases
# Usage: source lib/confidence.sh
#
# REVIEW PHASE FORMULA (Cumulative Additive Model):
# Each iteration earns 5-15 points based on quality factors:
#   - Base: +5 (completed iteration)
#   - Tests pass: +4
#   - No high severity: +3 (or +1 if ≤1 high)
#   - All approve: +3 (or +1 if ≥2 approve)
#
# Points have diminishing returns: multiplier = max(0.5, 1 - iteration*0.1)
# Confidence = min(100, 40 + cumulative_score)
#
# Key feature: Confidence only goes UP. No issue tracking needed.

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIB_DIR/common.sh"

# Load config
CONFIG_DIR="${_LIB_DIR%/lib}/config"
if [[ -f "$CONFIG_DIR/ralpr.config.sh" ]]; then
  source "$CONFIG_DIR/ralpr.config.sh"
fi

# ============================================================================
# STATE MANAGEMENT
# ============================================================================

# Get the state file path for a PR
# Usage: get_state_file "$pr_number"
get_state_file() {
  local pr_number="$1"
  local state_dir="${RALPR_OUTPUT_DIR:-.ralpr}/pr-$pr_number"
  echo "$state_dir/confidence-state.json"
}

# Initialize or load confidence state for a PR
# Usage: init_confidence_state "$pr_number" "$phase"
# Returns: JSON state object
init_confidence_state() {
  local pr_number="$1"
  local phase="${2:-review}"
  local state_file
  state_file=$(get_state_file "$pr_number")

  local state_dir
  state_dir=$(dirname "$state_file")

  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    mkdir -p "$state_dir"
    local initial_state
    initial_state=$(cat << EOF
{
  "pr_number": $pr_number,
  "phase": "$phase",
  "iteration": 0,
  "cumulative_score": 0,
  "confidence": 40,
  "iterations": []
}
EOF
)
    echo "$initial_state" > "$state_file"
    echo "$initial_state"
  fi
}

# Save iteration state after each loop
# Usage: save_iteration_state "$pr_number" "$iteration_data_json"
save_iteration_state() {
  local pr_number="$1"
  local iteration_data="$2"
  local state_file
  state_file=$(get_state_file "$pr_number")

  if [[ ! -f "$state_file" ]]; then
    init_confidence_state "$pr_number" >/dev/null
  fi

  # Update state with new iteration (cumulative model)
  local updated_state
  updated_state=$(jq --argjson iter "$iteration_data" '
    .iterations += [$iter] |
    .iteration = ($iter.iteration // (.iteration + 1)) |
    .cumulative_score = ($iter.cumulative_score // .cumulative_score) |
    .confidence = ($iter.confidence // .confidence)
  ' "$state_file")

  echo "$updated_state" > "$state_file"
  echo "$updated_state"
}

# ============================================================================
# GITHUB LABEL STATE
# ============================================================================

# Read previous confidence from GitHub PR labels
# Usage: get_confidence_from_labels "$pr_number" "$phase"
# Returns: confidence score (0-100) or empty if no label found
get_confidence_from_labels() {
  local pr_number="$1"
  local phase="${2:-review}"

  # Get labels from PR
  local labels
  labels=$(gh pr view "$pr_number" --json labels --jq '.labels[].name' 2>/dev/null || echo "")

  # Look for ralpr:<phase>:<confidence> pattern
  local pattern="^ralpr:${phase}:([0-9]+)$"
  while IFS= read -r label; do
    if [[ "$label" =~ $pattern ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<< "$labels"

  echo ""
}

# Get iteration count from state file
# Usage: get_iteration_count "$pr_number"
# Returns: iteration number (0 if no iterations completed)
get_iteration_count() {
  local pr_number="$1"

  local state_file
  state_file=$(get_state_file "$pr_number")

  if [[ -f "$state_file" ]]; then
    jq -r '.iteration // 0' "$state_file" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# Get current state summary for a PR
# Usage: get_state_summary "$pr_number"
# Returns: JSON with iteration, cumulative_score, confidence
get_state_summary() {
  local pr_number="$1"

  local state_file
  state_file=$(get_state_file "$pr_number")

  if [[ -f "$state_file" ]]; then
    jq '{
      iteration: .iteration,
      cumulative_score: .cumulative_score,
      confidence: .confidence
    }' "$state_file"
  else
    # No state file - return defaults
    echo '{"iteration": 0, "cumulative_score": 0, "confidence": 40}'
  fi
}

# ============================================================================
# COMPONENT CALCULATIONS (Cumulative Additive Model)
# ============================================================================

# Calculate iteration points based on quality factors
# Returns: 5-15 points
# Usage: calculate_iteration_points "$tests_passed" "$high_severity_count" "$approved_count" "$total_reviewers"
calculate_iteration_points() {
  local tests_passed="$1"      # true/false
  local high_sev_count="$2"    # count of high/critical severity issues
  local approved_count="$3"    # count of APPROVED verdicts
  local total_reviewers="${4:-3}"  # total reviewer count

  local points=5  # Base: completed iteration

  # Tests pass: +4
  if [[ "$tests_passed" == "true" ]]; then
    points=$((points + 4))
  fi

  # Severity bonus: +3 if no high, +1 if ≤1 high
  if [[ $high_sev_count -eq 0 ]]; then
    points=$((points + 3))
  elif [[ $high_sev_count -le 1 ]]; then
    points=$((points + 1))
  fi

  # Consensus bonus: +3 if all approve, +1 if ≥2 approve
  if [[ $approved_count -eq $total_reviewers ]]; then
    points=$((points + 3))
  elif [[ $approved_count -ge 2 ]]; then
    points=$((points + 1))
  fi

  echo "$points"
}

# Calculate diminishing returns multiplier
# Later iterations are worth less to encourage fixing issues early
# Usage: calculate_multiplier "$iteration"
# Returns: multiplier between 0.5 and 1.0
calculate_multiplier() {
  local iteration="$1"

  # multiplier = max(0.5, 1.0 - iteration * 0.1)
  # iter 0: 1.0, iter 1: 0.9, iter 2: 0.8, ..., iter 5+: 0.5
  local multiplier
  multiplier=$(echo "scale=2; 1.0 - $iteration * 0.1" | bc)

  # Floor at 0.5
  if [[ $(echo "$multiplier < 0.5" | bc) -eq 1 ]]; then
    multiplier="0.5"
  fi

  echo "$multiplier"
}

# Get high severity count from issue counts
# Usage: get_high_severity_count "$critical_count" "$important_count"
get_high_severity_count() {
  local critical="${1:-0}"
  local important="${2:-0}"
  echo $((critical + important))
}

# ============================================================================
# REVIEW PHASE CONFIDENCE (Cumulative Additive Model)
# ============================================================================

# Calculate review confidence from reviewer results
# Usage: calculate_review_confidence "$pr_number" "$qa_json" "$domain_json" "$codex_json" "$tests_passed" "$coverage_pct"
#
# Cumulative Additive Model:
# - Each iteration earns 5-15 points based on quality
# - Points have diminishing returns (multiplier decreases per iteration)
# - Confidence = min(100, 40 + cumulative_score)
# - Confidence only goes UP, never down
calculate_review_confidence() {
  local pr_number="$1"
  local qa_json="$2"
  local domain_json="$3"
  local codex_json="$4"
  local tests_passed="${5:-true}"
  local coverage_pct="${6:-0}"

  # Base confidence from config or default
  local base_confidence="${REVIEW_BASE_CONFIDENCE:-40}"

  # Load current state
  local state
  state=$(init_confidence_state "$pr_number" "review")

  local current_iteration
  current_iteration=$(echo "$state" | jq -r '.iteration // 0')
  local prev_cumulative
  prev_cumulative=$(echo "$state" | jq -r '.cumulative_score // 0')

  # Count verdicts and severity from reviewers
  local approved=0 total_reviewers=0
  local total_critical=0 total_important=0

  for json in "$qa_json" "$domain_json" "$codex_json"; do
    if [[ -z "$json" ]] || [[ "$json" == "null" ]]; then
      continue
    fi

    total_reviewers=$((total_reviewers + 1))

    # Count verdicts
    local verdict
    verdict=$(echo "$json" | jq -r '.verdict // "UNKNOWN"')
    if [[ "$verdict" == "APPROVED" ]]; then
      approved=$((approved + 1))
    fi

    # Count high severity issues (critical + important)
    local critical important
    critical=$(echo "$json" | jq '[.issues.critical // [] | length] | add // 0')
    important=$(echo "$json" | jq '[.issues.important // [] | length] | add // 0')

    total_critical=$((total_critical + critical))
    total_important=$((total_important + important))
  done

  local high_sev_count
  high_sev_count=$(get_high_severity_count "$total_critical" "$total_important")

  # Calculate iteration points (5-15)
  local iteration_points
  iteration_points=$(calculate_iteration_points "$tests_passed" "$high_sev_count" "$approved" "$total_reviewers")

  # Apply diminishing returns multiplier
  local multiplier
  multiplier=$(calculate_multiplier "$current_iteration")

  local points_earned
  points_earned=$(echo "scale=2; $iteration_points * $multiplier" | bc)

  # Calculate new cumulative score and confidence
  local new_cumulative
  new_cumulative=$(echo "scale=2; $prev_cumulative + $points_earned" | bc)

  local confidence_pct
  confidence_pct=$(echo "scale=0; $base_confidence + $new_cumulative / 1" | bc)

  # Cap at 100
  if [[ $confidence_pct -gt 100 ]]; then
    confidence_pct=100
  fi

  # New iteration number
  local new_iteration=$((current_iteration + 1))

  # Save iteration state
  local iteration_data
  iteration_data=$(cat << EOF
{
  "iteration": $new_iteration,
  "cumulative_score": $new_cumulative,
  "confidence": $confidence_pct,
  "breakdown": {
    "base_points": $iteration_points,
    "multiplier": $multiplier,
    "points_earned": $points_earned,
    "tests_passed": $([[ "$tests_passed" == "true" ]] && echo "true" || echo "false"),
    "high_severity_count": $high_sev_count,
    "approved_count": $approved,
    "total_reviewers": $total_reviewers
  }
}
EOF
)
  save_iteration_state "$pr_number" "$iteration_data" >/dev/null 2>&1 || true

  echo "$confidence_pct"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Reset state for a PR (useful for testing or starting fresh)
# Usage: reset_confidence_state "$pr_number"
reset_confidence_state() {
  local pr_number="$1"
  local state_file
  state_file=$(get_state_file "$pr_number")

  if [[ -f "$state_file" ]]; then
    rm -f "$state_file"
  fi

  init_confidence_state "$pr_number" "review"
}

# Get detailed breakdown for display/logging
# Usage: get_confidence_breakdown "$pr_number"
# Returns: JSON with all component scores
get_confidence_breakdown() {
  local pr_number="$1"

  local state_file
  state_file=$(get_state_file "$pr_number")

  if [[ -f "$state_file" ]]; then
    jq '{
      iteration: .iteration,
      cumulative_score: .cumulative_score,
      confidence: .confidence,
      latest_breakdown: .iterations[-1].breakdown,
      iteration_history: [.iterations[] | {
        iteration: .iteration,
        points_earned: .breakdown.points_earned,
        confidence: .confidence
      }]
    }' "$state_file"
  else
    echo '{"iteration": 0, "cumulative_score": 0, "confidence": 40, "latest_breakdown": null, "iteration_history": []}'
  fi
}

# ============================================================================
# REFACTOR PHASE CONFIDENCE
# ============================================================================

# Calculate refactor confidence from skill and tests
# Usage: calculate_refactor_confidence "$skill_confidence" "$test_passed"
#
# Formula:
# confidence = (skill_confidence * 0.70) + (test_stability * 0.30)
#
# where:
# - skill_confidence: 0-1 from refactor skill
# - test_stability: 1.0 if all tests pass, 0.0 if any fail

calculate_refactor_confidence() {
  local skill_confidence="$1"  # 0-100 or 0.0-1.0
  local test_passed="${2:-true}"  # true/false

  # Weights from config or defaults
  local w_skill="${REFACTOR_WEIGHTS_SKILL:-0.70}"
  local w_stability="${REFACTOR_WEIGHTS_STABILITY:-0.30}"

  # Normalize skill confidence to 0-1
  local skill_norm
  if [[ $(echo "$skill_confidence > 1" | bc) -eq 1 ]]; then
    # Already 0-100, convert to 0-1
    skill_norm=$(echo "scale=4; $skill_confidence / 100" | bc)
  else
    skill_norm="$skill_confidence"
  fi

  # Test stability
  local test_stability
  if [[ "$test_passed" == "true" ]]; then
    test_stability="1.0"
  else
    test_stability="0.0"
  fi

  # Calculate confidence
  local confidence
  confidence=$(echo "scale=4; ($skill_norm * $w_skill) + ($test_stability * $w_stability)" | bc)

  # Convert to percentage
  local confidence_pct
  confidence_pct=$(echo "scale=0; $confidence * 100 / 1" | bc)

  # Ensure 0-100 range
  if [[ $confidence_pct -lt 0 ]]; then
    confidence_pct=0
  fi
  if [[ $confidence_pct -gt 100 ]]; then
    confidence_pct=100
  fi

  echo "$confidence_pct"
}

# ============================================================================
# AGGREGATION HELPERS
# ============================================================================

# Count high severity issues from reviewer JSON
# Usage: count_high_severity "$reviewer_json"
count_high_severity() {
  local json="$1"

  if [[ -z "$json" ]] || [[ "$json" == "null" ]]; then
    echo "0"
    return
  fi

  local critical important
  critical=$(echo "$json" | jq '[.issues.critical // [] | length] | add // 0')
  important=$(echo "$json" | jq '[.issues.important // [] | length] | add // 0')

  echo $((critical + important))
}

# Count approved verdicts from multiple reviewers
# Usage: count_approvals "$qa_json" "$domain_json" "$codex_json"
count_approvals() {
  local approved=0

  for json in "$@"; do
    if [[ -z "$json" ]] || [[ "$json" == "null" ]]; then
      continue
    fi

    local verdict
    verdict=$(echo "$json" | jq -r '.verdict // "UNKNOWN"')

    if [[ "$verdict" == "APPROVED" ]]; then
      approved=$((approved + 1))
    fi
  done

  echo "$approved"
}

# Get worst verdict from multiple reviewers
get_worst_verdict() {
  local qa_json="${1:-{}}"
  local domain_json="${2:-{}}"
  local codex_json="${3:-{}}"

  for json in "$qa_json" "$domain_json" "$codex_json"; do
    if [[ -z "$json" ]] || [[ "$json" == "null" ]]; then
      continue
    fi

    local verdict
    verdict=$(echo "$json" | jq -r '.verdict // "UNKNOWN"')

    if [[ "$verdict" == "NEEDS_CHANGES" ]] || [[ "$verdict" == "CHANGES_REQUESTED" ]]; then
      echo "NEEDS_CHANGES"
      return
    fi
  done

  # Check for COMMENTED
  for json in "$qa_json" "$domain_json" "$codex_json"; do
    if [[ -z "$json" ]] || [[ "$json" == "null" ]]; then
      continue
    fi

    local verdict
    verdict=$(echo "$json" | jq -r '.verdict // "UNKNOWN"')

    if [[ "$verdict" == "COMMENTED" ]]; then
      echo "COMMENTED"
      return
    fi
  done

  echo "APPROVED"
}
