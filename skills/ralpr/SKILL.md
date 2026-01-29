---
name: ralpr
description: Ralpr - Ralph Autonomous Loop for Pull-request Readiness. Three phases - Implementation → Review → Refactor. Each invocation runs a single iteration.
args: "[--issue <number>] [--pr <number>] [--phase <impl|review|refactor>] [--human-review] [--dry-run]"
---

# Ralpr v2.1

Three-phase architecture: **Implementation → Review → Refactor**

## Agent Registry

| Agent | subagent_type | Purpose |
|-------|---------------|---------|
| Explore | `ralpr:explore-agent` | Map codebase structure |
| Understand | `ralpr:understand-agent` | Extract issue/PR requirements |
| Implement | `ralpr:implement-agent` | TDD implementation |
| QA Reviewer | `ralpr:qa-reviewer` | Test coverage, edge cases |
| Domain Expert | `ralpr:domain-expert` | Architecture, security, bugs |
| Codex Reviewer | `ralpr:codex-reviewer` | Third-party MCP review |

**Only use these exact subagent_type values.**

---

## Scripts & Output

All scripts: `RALPR_SCRIPTS/ralpr <subcommand>` (path provided at session start)

Output contract: Parse `RALPR_RESULT: {...json...}` from stdout last line.

---

## Phase Selection

Select phase based on arguments or PR state:

| Condition | Phase | Documentation |
|-----------|-------|---------------|
| `--issue <N> --phase impl` provided | Implementation | @phase-implementation.md |
| `--pr <N> --phase review` provided | Review | @phase-review.md |
| `--pr <N> --phase refactor` provided | Refactor | @phase-refactor.md |

### State Management

See @iteration-state.md for:
- Reading/writing PR comment state
- State markers: `RALPR_REVIEW_STATE`, `RALPR_REFACTOR_STATE`
- Delete-then-create pattern

### Labels & Comments

See @comment-formats.md for:
- Label retention rules
- Comment templates with icons
- Setting confidence labels

---

## Error Handling

| Situation | Action |
|-----------|--------|
| No default branch | STOP |
| No ready tickets | STOP |
| Already assigned | Pick next |
| Tests/CI fail | Fix & retry, or RELEASE and STOP |
| Agent output invalid | Retry once, then STOP |

**Rule:** Never leave assigned and inactive. Either fix or release.