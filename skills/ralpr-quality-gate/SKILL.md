---
name: ralpr-quality-gate
description: Framework-agnostic quality gate. Auto-detects project type and runs tests + lint + typecheck.
---

# Quality Gate

Auto-detect project framework and run appropriate quality checks.

## Detection

Check for config files in working directory:
1. package.json → Node.js (npm test / npx vitest run, npx eslint . or npx biome check, npx tsc --noEmit)
2. Cargo.toml → Rust (cargo test, cargo clippy)
3. pyproject.toml or setup.py → Python (pytest, ruff check . or flake8, mypy .)
4. go.mod → Go (go test ./..., golangci-lint run)
5. Fallback: look for test scripts in any config file

## Process

1. Detect framework from config files
2. Run test suite → capture exit code + output summary
3. Run linter → capture exit code + output summary
4. Run type checker → capture exit code + output summary

## Output

Return JSON:
```json
{
  "verdict": "pass" | "fail",
  "framework": "node" | "rust" | "python" | "go" | "unknown",
  "tests": { "passed": N, "failed": N, "exitCode": N },
  "lint": { "errors": N, "warnings": N, "exitCode": N },
  "typecheck": { "errors": N, "exitCode": N }
}
```
