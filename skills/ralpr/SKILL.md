---
name: ralpr
description: Ralpr - Ralph Autonomous Loop for Pull-request Readiness. Three phases - Implementation → Review → Refactor. Each invocation runs a single iteration.
args: "[--issue <number>] [--pr <number>] [--phase <impl|review|refactor>] [--human-review] [--dry-run]"
---

# Ralpr v2.1

Three-phase architecture: **Implementation → Review → Refactor**

## Mandatory Protocol

You MUST follow these steps **sequentially** — no parallel execution, no skipping.

**Step 1 — Read phase docs FIRST.** Before running ANY script or spawning ANY agent, read ALL `@`-referenced documentation for your phase. This is BLOCKING — do not proceed until you have read every referenced doc.

**Step 2 — Pass arguments to scripts.** All `--issue` and `--pr` arguments are optional. If the user provided a specific number, pass it. Otherwise, the scripts will auto-select.

**Step 3 — Execute phase workflow.** Follow the phase documentation step-by-step.

**Critical** - ALWAYS work in worktrees (described in every phase), otherwise parallel agents might work on the same branch resulting in collisions!

## Authority Rules

1. **Docs over scripts.** Documentation (`SKILL.md`, `phase-*.md`, `comment-formats.md`, `iteration-state.md`) is authoritative. If script behavior or output contradicts docs, follow docs and flag the discrepancy to the user.
2. **Fix-by-default.** The default action for every issue is FIX. Skipping requires structured justification per phase-review.md Step 11. Deferral to future tickets is NOT a valid skip reason. Severity thresholds: CRITICAL/HIGH — fix if >= 2 reviewers agree (no skip without user approval). MEDIUM — fix if >= 2 reviewers agree. If a fix seems impossible (e.g., missing infrastructure, out-of-scope dependency), STOP and ask the user — never rationalize skipping.
3. **Use only documented labels.** Only set labels documented in @../../docs/comment-formats.md for confidence/phase tracking. Scripts may create auxiliary labels (e.g., iteration tracking) — these are operational and read-only for agents. Do not manually create or remove them.
4. **User directives are binding.** Comments from the PR author, maintainers, or CODEOWNERS that express requirements (e.g., "add E2E tests", "must validate input") are treated as CRITICAL issues. They cannot be skipped without:
   a. Explicit approval from the same user in a follow-up comment, OR
   b. A documented technical impossibility (missing infrastructure, external dependency)
   "Out of scope" and "future ticket" are NEVER valid reasons to skip user directives.

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

Select phase based on arguments. Issue/PR numbers are optional — scripts auto-select if omitted.

| Condition | Phase | Documentation |
|-----------|-------|---------------|
| `[--issue <N>] --phase impl` provided | Implementation | @../../docs/phase-implementation.md |
| `--pr <N> --phase review` provided | Review | @../../docs/phase-review.md |
| `--pr <N> --phase refactor` provided | Refactor | @../../docs/phase-refactor.md |

### State Management

See @../../docs/iteration-state.md for:
- Reading/writing PR comment state
- State markers: `RALPR_REVIEW_STATE`, `RALPR_REFACTOR_STATE`
- Delete-then-create pattern

### Labels & Comments

See @../../docs/comment-formats.md for:
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