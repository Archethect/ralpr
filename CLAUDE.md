# Claude Code — ralpr

Instructions for Claude working ON the ralpr plugin codebase.

## What This Project Is

Ralpr is a bash + markdown Claude Code plugin. It orchestrates autonomous implementation, review, and refactor cycles for GitHub issues and PRs. It is NOT an application — it has zero runtime dependencies.

## Project Structure

| Directory | Purpose |
|-----------|---------|
| `agents/` | System prompts for subagents (every word costs tokens) |
| `skills/` | Skill definition (orchestrator entry point) |
| `docs/` | Authoritative phase workflows and reference docs |
| `scripts/` | Bash CLI (`ralpr` subcommands) and `lib/` helpers |
| `schemas/` | JSON schemas for agent I/O contracts |
| `config/` | Environment variable defaults (`ralpr.config.sh`) |
| `hooks/` | Lifecycle hooks (session start, iteration complete) |
| `commands/` | Thin command invoker (maps slash command to skill) |

## Key Principles

- Agent `.md` files are system prompts — keep them concise, every word costs tokens
- `docs/` is authoritative over `scripts/` — if behavior contradicts docs, docs win
- Zero runtime dependencies — pure bash + markdown
- All bash scripts use `set -euo pipefail`
- Machine-readable output via `RALPR_RESULT: {...}` on stdout last line

## Testing

No test suite exists. Verification approaches:
- `bash -n <script>` for syntax checking
- `/ralpr --dry-run` for smoke testing
- Real integration against a GitHub repo for full testing

## Do NOT Create

- `package.json`, `tsconfig.json`, or any Node/TS config
- Test files or test directories (EXCEPT for TypeScript orchestrator in `src/__tests__/`)
- CI/CD configuration
- Docker files
