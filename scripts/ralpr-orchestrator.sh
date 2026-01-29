#!/usr/bin/env bash
# ralpr-orchestrator.sh - External orchestration tool for automated looping
#
# This script is NOT referenced from the Ralpr skill - the skill is stateless
# and runs single iterations. Power users can invoke this directly for automated
# multi-iteration runs that spawn fresh Claude sessions per iteration.
#
# The skill (/ralpr) always runs a single iteration. Use this script when you
# want automated looping until a confidence threshold is met.
#
# Usage:
#   ralpr-orchestrator.sh review --pr 123 --max-loops 7 --threshold 90
#   ralpr-orchestrator.sh refactor --pr 123 --max-loops 5 --threshold 95

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/github-labels.sh"
source "$SCRIPT_DIR/lib/confidence.sh"
source "$SCRIPT_DIR/lib/ci-watcher.sh"
source "$SCRIPT_DIR/lib/quality-gates.sh"

# Load config
source "$SCRIPT_DIR/../config/ralpr.config.sh"

# ============================================================================
# GLOBALS
# ============================================================================

PHASE=""
PR_NUMBER=""
MAX_LOOPS=""
THRESHOLD=""
WORKING_DIR="."
DRY_RUN=false

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Run a single review iteration in fresh Claude session
run_review_iteration() {
  local iteration="$1"
  local pr_number="$2"
  local working_dir="$3"

  log_phase "Review iteration $iteration for PR #$pr_number"

  local owner_repo
  owner_repo=$(get_owner_repo)
  local base_branch
  base_branch=$(get_default_branch)

  # Build the prompt for this iteration
  local prompt
  prompt=$(cat << EOF
Ralpr Review Phase - Iteration $iteration for PR #$pr_number

You are running Ralpr Review Phase iteration $iteration.

## Context
- PR: $pr_number
- Repository: $owner_repo
- Base branch: $base_branch
- Working directory: $working_dir
- This is a FRESH session - previous context is not available

## Your Tasks

1. **Understand the PR** - Spawn understand-agent:
   \`\`\`
   Task(
     subagent_type="ralpr:understand-agent",
     prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "pr", "pr_number": $pr_number, "repo": "$owner_repo", "map_path": "docs/.codebase-map.json"}',
     description="Analyze PR changes"
   )
   \`\`\`

2. **Run 3 reviewers IN PARALLEL**:
   \`\`\`
   Task(subagent_type="ralpr:qa-reviewer", prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": $pr_number, "branch": "$(git branch --show-current)", "base_branch": "$base_branch", "working_dir": "$working_dir", "map_path": "docs/.codebase-map.json"}', description="QA review")
   Task(subagent_type="ralpr:domain-expert", prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": $pr_number, "branch": "$(git branch --show-current)", "base_branch": "$base_branch", "working_dir": "$working_dir", "map_path": "docs/.codebase-map.json"}', description="Domain review")
   Task(subagent_type="ralpr:codex-reviewer", prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": $pr_number, "branch": "$(git branch --show-current)", "base_branch": "$base_branch", "working_dir": "$working_dir"}', description="Codex review")
   \`\`\`

3. **Aggregate issues** - Dedupe by file:line, prioritize by severity

4. **Apply fixes** - For high-confidence suggestions (>0.8), apply the fix

5. **Run quality gates**:
   - npm test
   - npm run lint
   - npm run typecheck (if TypeScript)

6. **Commit and push** if any fixes applied:
   \`\`\`bash
   git add -A
   git commit -m "fix: address review feedback - iteration $iteration

   Co-Authored-By: Claude <noreply@anthropic.com>"
   git push
   \`\`\`

7. **Calculate confidence** using the formula:
   \`\`\`
   confidence = (convergence × 0.30) + (resolution × 0.25) + (consensus × 0.20) + (test_quality × 0.15) + (severity_trend × 0.10)
   \`\`\`
   Note: First iteration caps at ~57% to ensure convergence proof.

8. **Set PR label** with confidence score:
   \`\`\`bash
   gh pr edit $pr_number --add-label "ralpr:review:\$CONFIDENCE"
   \`\`\`

## Output Format

After completing all tasks, output EXACTLY this JSON (no other text):

\`\`\`json
{
  "iteration": $iteration,
  "reviewers": {
    "qa": <qa_reviewer_output>,
    "domain": <domain_expert_output>,
    "codex": <codex_reviewer_output>
  },
  "issues_found": <total_count>,
  "issues_fixed": <fixed_count>,
  "quality_gates": {
    "tests": "passed|failed|skipped",
    "lint": "passed|failed|skipped",
    "typecheck": "passed|failed|skipped"
  },
  "commits": [<list of commit SHAs if any>],
  "confidence": <calculated_confidence_0_100>,
  "label_set": "ralpr:review:<confidence>"
}
\`\`\`
EOF
)

  # Run Claude with the prompt
  local result
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would run Claude with review prompt"
    result='{"iteration": '"$iteration"', "reviewers": {}, "issues_found": 0, "issues_fixed": 0, "quality_gates": {"tests": "skipped", "lint": "skipped", "typecheck": "skipped"}, "commits": []}'
  else
    # Run in a fresh Claude session
    result=$(claude --print "$prompt" \
      --allowedTools "$CLAUDE_ALLOWED_TOOLS" \
      --max-turns 50 \
      2>&1 | tail -n 1)
  fi

  echo "$result"
}

# Run a single refactor iteration in fresh Claude session
run_refactor_iteration() {
  local iteration="$1"
  local pr_number="$2"
  local working_dir="$3"

  log_phase "Refactor iteration $iteration for PR #$pr_number"

  local owner_repo
  owner_repo=$(get_owner_repo)
  local base_branch
  base_branch=$(get_default_branch)

  # Build the prompt for this iteration
  local prompt
  prompt=$(cat << EOF
Ralpr Refactor Phase - Iteration $iteration for PR #$pr_number

You are running Ralpr Refactor Phase iteration $iteration.

## Context
- PR: $pr_number
- Repository: $owner_repo
- Base branch: $base_branch
- Working directory: $working_dir
- This is a FRESH session - previous context is not available

## Your Tasks

1. **Understand the PR** - Spawn understand-agent:
   \`\`\`
   Task(
     subagent_type="ralpr:understand-agent",
     prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "pr", "pr_number": $pr_number, "repo": "$owner_repo", "map_path": "docs/.codebase-map.json"}',
     description="Analyze PR for refactoring"
   )
   \`\`\`

2. **Invoke the refactor skill**:
   \`\`\`
   Skill(skill="superpowers:refactor")
   \`\`\`

3. **Get skill confidence** - The refactor skill should report its confidence level (0-100)

4. **Run quality gates**:
   - npm test
   - npm run lint
   - npm run typecheck (if TypeScript)

5. **Commit and push** if any refactoring applied:
   \`\`\`bash
   git add -A
   git commit -m "refactor: improve code quality - iteration $iteration

   Co-Authored-By: Claude <noreply@anthropic.com>"
   git push
   \`\`\`

6. **Calculate confidence** using the formula:
   \`\`\`
   confidence = (skill_confidence × 0.70) + (test_stability × 0.30)
   \`\`\`

7. **Set PR label** with confidence score:
   \`\`\`bash
   gh pr edit $pr_number --add-label "ralpr:refactor:\$CONFIDENCE"
   \`\`\`

## Output Format

After completing all tasks, output EXACTLY this JSON (no other text):

\`\`\`json
{
  "iteration": $iteration,
  "skill_confidence": <0-100>,
  "refactorings_applied": <count>,
  "quality_gates": {
    "tests": "passed|failed|skipped",
    "lint": "passed|failed|skipped",
    "typecheck": "passed|failed|skipped"
  },
  "commits": [<list of commit SHAs if any>],
  "confidence": <calculated_confidence_0_100>,
  "label_set": "ralpr:refactor:<confidence>"
}
\`\`\`
EOF
)

  # Run Claude with the prompt
  local result
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would run Claude with refactor prompt"
    result='{"iteration": '"$iteration"', "skill_confidence": 95, "refactorings_applied": 0, "quality_gates": {"tests": "skipped", "lint": "skipped", "typecheck": "skipped"}, "commits": []}'
  else
    # Run in a fresh Claude session
    result=$(claude --print "$prompt" \
      --allowedTools "$CLAUDE_ALLOWED_TOOLS" \
      --max-turns 50 \
      2>&1 | tail -n 1)
  fi

  echo "$result"
}

# ============================================================================
# REVIEW PHASE ORCHESTRATION
# ============================================================================

orchestrate_review() {
  local pr_number="$1"
  local max_loops="${2:-$REVIEW_MAX_LOOPS}"
  local threshold="${3:-$REVIEW_THRESHOLD}"
  local working_dir="${4:-.}"

  log_phase "Starting Review Phase for PR #$pr_number"
  log_info "Max loops: $max_loops, Threshold: $threshold%"

  # Initialize confidence state for this PR
  init_confidence_state "$pr_number" "review" >/dev/null

  # Note: Claude session now sets labels directly via gh pr edit
  # The orchestrator only manages loop iteration

  local iteration=1
  local final_confidence=0

  while [[ $iteration -le $max_loops ]]; do
    log_info "=== Review Iteration $iteration of $max_loops ==="

    # Run iteration in fresh session
    local result
    result=$(run_review_iteration "$iteration" "$pr_number" "$working_dir")

    # Parse result
    local qa_json domain_json codex_json
    qa_json=$(echo "$result" | jq -r '.reviewers.qa // {}')
    domain_json=$(echo "$result" | jq -r '.reviewers.domain // {}')
    codex_json=$(echo "$result" | jq -r '.reviewers.codex // {}')

    # Get test results for confidence calculation
    local tests_passed
    tests_passed=$(echo "$result" | jq -r '.quality_gates.tests // "skipped"')
    local test_passed_bool="false"
    [[ "$tests_passed" == "passed" ]] && test_passed_bool="true"

    # Calculate confidence (new formula uses PR number for state tracking)
    local confidence
    confidence=$(calculate_review_confidence "$pr_number" "$qa_json" "$domain_json" "$codex_json" "$test_passed_bool" "0")
    final_confidence=$confidence

    log_info "Iteration $iteration confidence: $confidence%"

    # Check if threshold met
    if [[ $confidence -ge $threshold ]]; then
      log_info "✓ Confidence threshold met ($confidence% >= $threshold%)"
      # Note: Label set by Claude session, not orchestrator

      # Wait for CI
      log_info "Waiting for CI..."
      if wait_for_ci; then
        log_info "✓ CI passed"
      else
        log_warn "CI failed or timed out"
      fi

      ralpr_result "{\"status\":\"approved\",\"phase\":\"review\",\"confidence\":$confidence,\"iterations\":$iteration}"
      return 0
    fi

    # Check for any commits (fixes applied)
    local commits_count
    commits_count=$(echo "$result" | jq '[.commits // []] | length')

    if [[ "$commits_count" -gt 0 ]]; then
      # Wait for CI before next iteration
      log_info "Fixes applied, waiting for CI..."
      wait_for_ci || true
    fi

    iteration=$((iteration + 1))
  done

  # Max loops exhausted
  log_warn "Max loops reached. Final confidence: $final_confidence%"
  # Note: Final label should have been set by last Claude session

  if [[ $final_confidence -ge 70 ]]; then
    ralpr_result "{\"status\":\"partial\",\"phase\":\"review\",\"confidence\":$final_confidence,\"iterations\":$max_loops,\"recommendation\":\"manual_review\"}"
  else
    ralpr_result "{\"status\":\"failed\",\"phase\":\"review\",\"confidence\":$final_confidence,\"iterations\":$max_loops,\"recommendation\":\"escalate_to_human\"}"
  fi

  return 1
}

# ============================================================================
# REFACTOR PHASE ORCHESTRATION
# ============================================================================

orchestrate_refactor() {
  local pr_number="$1"
  local max_loops="${2:-$REFACTOR_MAX_LOOPS}"
  local threshold="${3:-$REFACTOR_THRESHOLD}"
  local working_dir="${4:-.}"

  log_phase "Starting Refactor Phase for PR #$pr_number"
  log_info "Max loops: $max_loops, Threshold: $threshold%"

  # Note: Claude session now sets labels directly via gh pr edit
  # The orchestrator only manages loop iteration

  local iteration=1
  local final_confidence=0

  while [[ $iteration -le $max_loops ]]; do
    log_info "=== Refactor Iteration $iteration of $max_loops ==="

    # Run iteration in fresh session
    local result
    result=$(run_refactor_iteration "$iteration" "$pr_number" "$working_dir")

    # Parse result
    local skill_confidence
    skill_confidence=$(echo "$result" | jq -r '.skill_confidence // 0')

    local tests_passed
    tests_passed=$(echo "$result" | jq -r '.quality_gates.tests // "skipped"')
    local test_passed_bool="false"
    [[ "$tests_passed" == "passed" ]] && test_passed_bool="true"

    # Calculate confidence
    local confidence
    confidence=$(calculate_refactor_confidence "$skill_confidence" "$test_passed_bool")
    final_confidence=$confidence

    log_info "Iteration $iteration confidence: $confidence% (skill: $skill_confidence%, tests: $tests_passed)"

    # Check if threshold met
    if [[ $confidence -ge $threshold ]]; then
      log_info "✓ Confidence threshold met ($confidence% >= $threshold%)"
      # Note: Label set by Claude session, not orchestrator

      # Wait for CI
      log_info "Waiting for CI..."
      if wait_for_ci; then
        log_info "✓ CI passed"
      else
        log_warn "CI failed or timed out"
      fi

      ralpr_result "{\"status\":\"approved\",\"phase\":\"refactor\",\"confidence\":$confidence,\"iterations\":$iteration}"
      return 0
    fi

    # Check for any commits (refactoring applied)
    local commits_count
    commits_count=$(echo "$result" | jq '[.commits // []] | length')

    if [[ "$commits_count" -gt 0 ]]; then
      # Wait for CI before next iteration
      log_info "Refactoring applied, waiting for CI..."
      wait_for_ci || true
    fi

    iteration=$((iteration + 1))
  done

  # Max loops exhausted
  log_warn "Max loops reached. Final confidence: $final_confidence%"
  # Note: Final label should have been set by last Claude session

  if [[ $final_confidence -ge 85 ]]; then
    ralpr_result "{\"status\":\"partial\",\"phase\":\"refactor\",\"confidence\":$final_confidence,\"iterations\":$max_loops,\"recommendation\":\"acceptable\"}"
  else
    ralpr_result "{\"status\":\"failed\",\"phase\":\"refactor\",\"confidence\":$final_confidence,\"iterations\":$max_loops,\"recommendation\":\"manual_refactor\"}"
  fi

  return 1
}

# ============================================================================
# MAIN
# ============================================================================

show_help() {
  cat << 'EOF'
ralpr-orchestrator.sh - Session manager for Ralpr phases

Usage:
  ralpr-orchestrator.sh <phase> [options]

Phases:
  review     Run review phase with parallel reviewers
  refactor   Run refactor phase with refactor skill

Options:
  --pr N              PR number to process (required)
  --max-loops N       Maximum loop iterations (default: 7 for review, 5 for refactor)
  --threshold N       Confidence threshold (default: 90 for review, 95 for refactor)
  --working-dir DIR   Working directory (default: current)
  --dry-run           Preview without making changes

Examples:
  ralpr-orchestrator.sh review --pr 123
  ralpr-orchestrator.sh review --pr 123 --max-loops 10 --threshold 85
  ralpr-orchestrator.sh refactor --pr 456 --threshold 90
EOF
}

main() {
  if [[ $# -lt 1 ]]; then
    show_help
    exit 1
  fi

  PHASE="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr) PR_NUMBER="$2"; shift 2 ;;
      --max-loops) MAX_LOOPS="$2"; shift 2 ;;
      --threshold) THRESHOLD="$2"; shift 2 ;;
      --working-dir) WORKING_DIR="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --help|-h) show_help; exit 0 ;;
      *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
  done

  # Validate required arguments
  if [[ -z "$PR_NUMBER" ]]; then
    log_error "PR number required (--pr N)"
    exit 1
  fi

  case "$PHASE" in
    review)
      MAX_LOOPS="${MAX_LOOPS:-$REVIEW_MAX_LOOPS}"
      THRESHOLD="${THRESHOLD:-$REVIEW_THRESHOLD}"
      orchestrate_review "$PR_NUMBER" "$MAX_LOOPS" "$THRESHOLD" "$WORKING_DIR"
      ;;
    refactor)
      MAX_LOOPS="${MAX_LOOPS:-$REFACTOR_MAX_LOOPS}"
      THRESHOLD="${THRESHOLD:-$REFACTOR_THRESHOLD}"
      orchestrate_refactor "$PR_NUMBER" "$MAX_LOOPS" "$THRESHOLD" "$WORKING_DIR"
      ;;
    *)
      log_error "Unknown phase: $PHASE"
      show_help
      exit 1
      ;;
  esac
}

main "$@"
