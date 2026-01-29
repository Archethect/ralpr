#!/usr/bin/env bash
# quality-gates.sh - Auto-detect and run test/lint/typecheck/ci
# Usage: source lib/quality-gates.sh

set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIB_DIR/common.sh"

# ============================================================================
# DETECTION: Auto-detect commands from package.json, Makefile, etc.
# ============================================================================

# Detect test command
detect_test_command() {
  local working_dir="${1:-.}"

  # Check package.json
  if [[ -f "$working_dir/package.json" ]]; then
    if jq -e '.scripts.test' "$working_dir/package.json" > /dev/null 2>&1; then
      echo "npm test"
      return
    fi
  fi

  # Check for foundry (Solidity)
  if [[ -f "$working_dir/foundry.toml" ]]; then
    echo "forge test"
    return
  fi

  # Check for Cargo.toml (Rust)
  if [[ -f "$working_dir/Cargo.toml" ]]; then
    echo "cargo test"
    return
  fi

  # Check Makefile
  if [[ -f "$working_dir/Makefile" ]] && grep -q "^test:" "$working_dir/Makefile"; then
    echo "make test"
    return
  fi

  # Check for pytest
  if [[ -f "$working_dir/pyproject.toml" ]] || [[ -f "$working_dir/pytest.ini" ]]; then
    echo "pytest"
    return
  fi

  echo ""
}

# Detect lint command
detect_lint_command() {
  local working_dir="${1:-.}"

  # Check package.json
  if [[ -f "$working_dir/package.json" ]]; then
    if jq -e '.scripts.lint' "$working_dir/package.json" > /dev/null 2>&1; then
      echo "npm run lint"
      return
    fi
  fi

  # Check for foundry
  if [[ -f "$working_dir/foundry.toml" ]]; then
    echo "forge fmt --check"
    return
  fi

  # Check Cargo.toml
  if [[ -f "$working_dir/Cargo.toml" ]]; then
    echo "cargo clippy -- -D warnings"
    return
  fi

  # Check Makefile
  if [[ -f "$working_dir/Makefile" ]] && grep -q "^lint:" "$working_dir/Makefile"; then
    echo "make lint"
    return
  fi

  # Check for ruff (Python)
  if [[ -f "$working_dir/pyproject.toml" ]] && grep -q "ruff" "$working_dir/pyproject.toml"; then
    echo "ruff check ."
    return
  fi

  echo ""
}

# Detect typecheck command
detect_typecheck_command() {
  local working_dir="${1:-.}"

  # Check package.json
  if [[ -f "$working_dir/package.json" ]]; then
    # Check for explicit typecheck script
    if jq -e '.scripts.typecheck' "$working_dir/package.json" > /dev/null 2>&1; then
      echo "npm run typecheck"
      return
    fi

    # Check for tsc script
    if jq -e '.scripts.tsc' "$working_dir/package.json" > /dev/null 2>&1; then
      echo "npm run tsc"
      return
    fi

    # Check if TypeScript is a devDependency
    if jq -e '.devDependencies.typescript // .dependencies.typescript' "$working_dir/package.json" > /dev/null 2>&1; then
      if [[ -f "$working_dir/tsconfig.json" ]]; then
        echo "npx tsc --noEmit"
        return
      fi
    fi
  fi

  # Check Cargo.toml (Rust has built-in types, but check anyway)
  if [[ -f "$working_dir/Cargo.toml" ]]; then
    echo "cargo check"
    return
  fi

  # Check for mypy (Python)
  if [[ -f "$working_dir/pyproject.toml" ]] && grep -q "mypy" "$working_dir/pyproject.toml"; then
    echo "mypy ."
    return
  fi

  echo ""
}

# ============================================================================
# EXECUTION: Run quality gates
# ============================================================================

# Run tests and return status
run_tests() {
  local working_dir="${1:-.}"
  local test_cmd

  test_cmd=$(detect_test_command "$working_dir")

  if [[ -z "$test_cmd" ]]; then
    log_warn "No test command detected, skipping tests"
    return 0
  fi

  log_info "Running tests: $test_cmd"

  pushd "$working_dir" > /dev/null
  if eval "$test_cmd"; then
    log_info "✓ Tests passed"
    popd > /dev/null
    return 0
  else
    log_error "✗ Tests failed"
    popd > /dev/null
    return 1
  fi
}

# Run linting and return status
run_lint() {
  local working_dir="${1:-.}"
  local lint_cmd

  lint_cmd=$(detect_lint_command "$working_dir")

  if [[ -z "$lint_cmd" ]]; then
    log_warn "No lint command detected, skipping lint"
    return 0
  fi

  log_info "Running lint: $lint_cmd"

  pushd "$working_dir" > /dev/null
  if eval "$lint_cmd"; then
    log_info "✓ Lint passed"
    popd > /dev/null
    return 0
  else
    log_error "✗ Lint failed"
    popd > /dev/null
    return 1
  fi
}

# Run type checking and return status
run_typecheck() {
  local working_dir="${1:-.}"
  local typecheck_cmd

  typecheck_cmd=$(detect_typecheck_command "$working_dir")

  if [[ -z "$typecheck_cmd" ]]; then
    log_debug "No typecheck command detected, skipping"
    return 0
  fi

  log_info "Running typecheck: $typecheck_cmd"

  pushd "$working_dir" > /dev/null
  if eval "$typecheck_cmd"; then
    log_info "✓ Typecheck passed"
    popd > /dev/null
    return 0
  else
    log_error "✗ Typecheck failed"
    popd > /dev/null
    return 1
  fi
}

# Run all quality gates
# Returns 0 if all pass, 1 if any fail
run_all_quality_gates() {
  local working_dir="${1:-.}"
  local failed=0

  log_phase "Running quality gates..."

  if ! run_tests "$working_dir"; then
    failed=1
  fi

  if ! run_lint "$working_dir"; then
    failed=1
  fi

  if ! run_typecheck "$working_dir"; then
    failed=1
  fi

  if [[ $failed -eq 0 ]]; then
    log_info "✓ All quality gates passed"
  else
    log_error "✗ Quality gates failed"
  fi

  return $failed
}

# Get quality gate summary as JSON
get_quality_summary() {
  local working_dir="${1:-.}"
  local test_status="skipped"
  local lint_status="skipped"
  local typecheck_status="skipped"

  # Run tests
  if [[ -n "$(detect_test_command "$working_dir")" ]]; then
    if run_tests "$working_dir" 2>/dev/null; then
      test_status="passed"
    else
      test_status="failed"
    fi
  fi

  # Run lint
  if [[ -n "$(detect_lint_command "$working_dir")" ]]; then
    if run_lint "$working_dir" 2>/dev/null; then
      lint_status="passed"
    else
      lint_status="failed"
    fi
  fi

  # Run typecheck
  if [[ -n "$(detect_typecheck_command "$working_dir")" ]]; then
    if run_typecheck "$working_dir" 2>/dev/null; then
      typecheck_status="passed"
    else
      typecheck_status="failed"
    fi
  fi

  # Determine overall status
  local overall="passed"
  if [[ "$test_status" == "failed" ]] || [[ "$lint_status" == "failed" ]] || [[ "$typecheck_status" == "failed" ]]; then
    overall="failed"
  fi

  cat << EOF
{
  "overall": "$overall",
  "tests": "$test_status",
  "lint": "$lint_status",
  "typecheck": "$typecheck_status"
}
EOF
}
