# AGENTS.md — ralpr

Project conventions for all AI coding assistants working on this plugin.

## Bash Style

- Shebang: `#!/usr/bin/env bash`
- Always: `set -euo pipefail`
- `local` for all function variables
- `snake_case` for functions and variables
- `UPPER_CASE` for constants and environment variables
- Quote all variable expansions: `"${var}"`
- Use log helpers from `lib/common.sh` (`log_info`, `log_error`, `log_debug`)
- Machine output via `ralpr_result` helper (writes `RALPR_RESULT: {...}` to stdout)

## Markdown Agent Formatting

- YAML frontmatter: `name`, `description`, `model`, `color`
- Concise prompts — every word costs tokens
- Structure: Input → Process → Output → MUST / MUST NOT

## JSON Schemas

- Live in `schemas/`
- Descriptive file names matching agent I/O (e.g., `reviewer-input.json`, `reviewer-output.json`)
- Include `required` arrays

## Commit Format

```
<type>(<scope>): <description>
```

Types: `feat`, `fix`, `refactor`, `docs`, `chore`

Scopes: `agents`, `scripts`, `docs`, `config`, `schemas`, `skill`, `hooks`, `loop`

## Architecture Rules

- `commands/` → `skills/` chain is thin (just invocation, no logic)
- Phase docs (`docs/phase-*.md`) are authoritative over scripts
- Scripts source `lib/common.sh` for shared functions
- Configuration lives in `config/ralpr.config.sh`
- New agents must be registered in `skills/ralpr` (SKILL.md Agent Registry table)

## Branching

- `main` — active development
- `release` — stable releases

## GitHub CLI

- **Always** use `gh` CLI for GitHub operations
- **Never** use MCP GitHub plugin tools
