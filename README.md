# Ralpr

**Autonomous three-phase loop that takes GitHub issues to merge-ready PRs.**

![Version](https://img.shields.io/badge/version-v2.1.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Claude Code Plugin](https://img.shields.io/badge/Claude_Code-Plugin-orange)

## What is Ralpr?

Ralpr (Ralph Autonomous Loop for Pull-request Readiness) is a Claude Code plugin that autonomously implements GitHub issues and iteratively reviews the resulting PRs until they reach merge-ready confidence levels.

- **Three-phase loop**: Implementation, Review, Refactor — each phase runs as an independent Claude Code session
- **Parallel AI reviewers**: Three specialized agents (QA, Domain Expert, Codex) review code simultaneously
- **Fix-by-default**: Every issue found is fixed, not deferred — skipping requires structured justification
- **Fresh context per iteration**: Each loop iteration spawns a new Claude session to prevent context drift
- **Cumulative confidence scoring**: Confidence only goes up, measured against configurable thresholds

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Ralpr Pipeline                                  │
│                                                                         │
│  GitHub    ┌──────────┐    PR     ┌──────────────┐    ┌──────────────┐ │
│  Issue ──▶ │ Phase 1  │ ──────▶  │   Phase 2    │ ─▶ │   Phase 3    │ │
│            │   Impl   │          │   Review     │    │   Refactor   │ │
│            │ (1 pass) │          │ (loop → 90%) │    │ (loop → 95%) │ │
│            └──────────┘          └──────────────┘    └──────────────┘ │
│                                         │                    │         │
│                                         ▼                    ▼         │
│                                    Merge-ready PR                      │
└─────────────────────────────────────────────────────────────────────────┘

Phase 2 — Parallel Review Agents:

  ┌─────────────────┐
  │  QA Reviewer     │──┐
  │  (test coverage) │  │
  └─────────────────┘  │    ┌───────────┐    ┌───────────────┐
                        ├──▶ │ Aggregate │──▶ │ Fix-by-Default│──▶ Confidence
  ┌─────────────────┐  │    │ & Score   │    │   Decision    │    Score
  │  Domain Expert   │──┤    └───────────┘    └───────────────┘
  │  (arch/security) │  │
  └─────────────────┘  │
                        │
  ┌─────────────────┐  │
  │  Codex Reviewer  │──┘
  │  (3rd-party AI)  │
  └─────────────────┘
```

## Prerequisites

### System Tools

| Tool | Min Version | Check Command | Purpose |
|------|-------------|---------------|---------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | latest | `claude --version` | Runtime |
| [`gh`](https://cli.github.com/) | any | `gh auth status` | GitHub API |
| [`git`](https://git-scm.com/) | 2.20+ | `git --version` | Worktree support |
| [`jq`](https://jqlang.github.io/jq/) | any | `jq --version` | JSON parsing |
| `bc` | any | `echo "1+1" \| bc` | Confidence math |

### Required Claude Code Plugins

| Plugin | Source | Install Command | Used In |
|--------|--------|-----------------|---------|
| `superpowers` | Official marketplace | `/plugin install superpowers` | Phase 3 — `superpowers:refactor` skill |
| `pr-review-toolkit` | Official marketplace | `/plugin install pr-review-toolkit` | Phase 3 — `pr-review-toolkit:code-simplifier` agent |

### Required MCP Server

| Server | Tool Used | Setup |
|--------|-----------|-------|
| [Codex CLI](https://github.com/openai/codex) | `mcp__codex__codex` | Install Codex CLI, set `OPENAI_API_KEY`, configure as MCP server in Claude Code |

The Codex MCP server is used by the `codex-reviewer` agent in Phase 2 to get an independent third-party review from OpenAI's model.

> **Note:** Ralpr itself has zero npm/node dependencies. Project-specific tools (npm, cargo, pytest, forge, etc.) are auto-detected by quality gates.

## Installation

### Option A: Marketplace (recommended)

```bash
# Inside Claude Code:
/plugin marketplace add Archethect/ralpr    # Add marketplace
/plugin install ralpr                        # Install plugin
```

### Option B: Local development

```bash
git clone https://github.com/Archethect/ralpr.git
claude --plugin-dir ./ralpr
```

### Post-install verification

```bash
# Start Claude Code in any GitHub repo, then:
/ralpr --dry-run
```

You should see a dry-run summary confirming prerequisites are met.

## Quick Start

```bash
# 1. Open Claude Code in a GitHub repo
cd your-github-repo && claude

# 2. Run Ralpr on an issue
/ralpr --issue 42

# 3. Watch it work:
#    - Implements the issue (TDD: RED → GREEN → REFACTOR)
#    - Creates a PR labeled ralpr:impl:done
#    - Reviews with 3 parallel AI agents, fixes issues
#    - Refactors for code quality

# 4. Result: PR with confidence labels
#    ralpr:impl:done
#    ralpr:review:90+
#    ralpr:refactor:95+
```

## Usage Reference

```
/ralpr [--issue <N>] [--pr <N>] [--phase <impl|review|refactor>] [--human-review] [--dry-run]
```

| Flag | Description | Example |
|------|-------------|---------|
| `--issue <N>` | Target a specific GitHub issue | `/ralpr --issue 42` |
| `--pr <N>` | Target a specific pull request | `/ralpr --pr 123 --phase review` |
| `--phase <phase>` | Run a specific phase: `impl`, `review`, or `refactor` | `/ralpr --phase refactor --pr 123` |
| `--human-review` | Request human review on the created PR | `/ralpr --issue 42 --human-review` |
| `--dry-run` | Preview what would happen without making changes | `/ralpr --dry-run` |

**Examples:**

```bash
# Full pipeline — auto-selects an open issue
/ralpr

# Implement a specific issue
/ralpr --issue 42

# Run only the review phase on an existing PR
/ralpr --phase review --pr 123

# Run only the refactor phase
/ralpr --phase refactor --pr 123

# Auto-select a review-ready PR
/ralpr --phase review

# Dry run to check prerequisites
/ralpr --dry-run
```

## How It Works

### Phase 1: Implementation

Single pass, no loops. Implements a GitHub issue using strict TDD methodology.

**Workflow:** Select issue → Claim → Create worktree → Explore codebase → Extract requirements → Implement (RED → GREEN → REFACTOR) → Quality gates → Create PR → Wait for CI → Label `ralpr:impl:done`

The implementation agent writes failing tests first, then writes the minimum code to pass them, then refactors. Quality gates (tests, lint, typecheck) must pass before the PR is created.

### Phase 2: Review

Iterative loop targeting **90% confidence**. Three reviewers run in parallel, findings are aggregated, and issues are fixed following a fix-by-default philosophy.

**Workflow per iteration:** Setup worktree → Explore → Read prior state → Understand PR changes → Run 3 reviewers in parallel → Aggregate findings → Apply fix-by-default decision framework → Fix issues → Quality gates → Push → CI → Calculate confidence → Set label → Write state

**Confidence model (cumulative additive):**
- Starts at 40% base confidence
- Each iteration earns 5–15 points based on: tests passing (+4), no high-severity issues (+3), reviewer consensus (+3)
- Diminishing returns: multiplier = max(0.5, 1.0 - iteration * 0.1)
- Confidence only goes up, never down
- Typical: 4 perfect iterations → 91%, 7 average iterations → 90%

**Fix-by-default rules:**
- CRITICAL/HIGH severity: must fix if >= 2 reviewers agree (no skip without user approval)
- MEDIUM severity: must fix if >= 2 reviewers agree
- Circuit breaker: if > 50% of MEDIUM+ issues are marked SKIP, stop and re-evaluate

### Phase 3: Refactor

Iterative loop targeting **95% confidence**. Uses the `superpowers:refactor` skill and `pr-review-toolkit:code-simplifier` agent to simplify code.

**Workflow per iteration:** Setup worktree → Explore → Read prior state → Understand PR → Run code simplifier → Quality gates → Push → CI → Calculate confidence → Set label → Write state

**Confidence formula:**
```
confidence = (skill_confidence * 0.70) + (test_stability * 0.30)
```

Where `skill_confidence` is the refactor skill's self-assessed quality (0–100) and `test_stability` is 100 if all tests pass, 0 otherwise.

## Agents

| Agent | `subagent_type` | Model | Phase | Role |
|-------|-----------------|-------|-------|------|
| Explore | `ralpr:explore-agent` | Haiku | All | Maps codebase structure, persists to file |
| Understand | `ralpr:understand-agent` | Opus | All | Extracts requirements from issues/PRs |
| Implement | `ralpr:implement-agent` | Opus | 1 | TDD implementation (RED → GREEN → REFACTOR) |
| QA Reviewer | `ralpr:qa-reviewer` | Opus | 2 | Test coverage, edge cases, error handling |
| Domain Expert | `ralpr:domain-expert` | Opus | 2 | Architecture, security, bugs, conventions |
| Codex Reviewer | `ralpr:codex-reviewer` | Opus | 2 | Third-party review via OpenAI Codex MCP |

## Configuration

All settings are configured via environment variables. Defaults are defined in `config/ralpr.config.sh`.

### Review Phase

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_THRESHOLD` | `85` | Confidence % required to pass review |
| `REVIEW_MAX_LOOPS` | `7` | Maximum review iterations |
| `REVIEW_BASE_CONFIDENCE` | `40` | Starting confidence score |

### Refactor Phase

| Variable | Default | Description |
|----------|---------|-------------|
| `REFACTOR_THRESHOLD` | `85` | Confidence % required to pass refactor |
| `REFACTOR_MAX_LOOPS` | `5` | Maximum refactor iterations |
| `REFACTOR_WEIGHTS_SKILL` | `0.70` | Weight for skill confidence (sum to 1.0) |
| `REFACTOR_WEIGHTS_STABILITY` | `0.30` | Weight for test stability (sum to 1.0) |

### General

| Variable | Default | Description |
|----------|---------|-------------|
| `RALPR_OUTPUT_DIR` | `.ralpr` | Directory for state files and logs |
| `RALPR_DEBUG` | `false` | Enable verbose debug logging |
| `CLAUDE_ALLOWED_TOOLS` | `Task,Bash,Read,Edit,Write,Glob,Grep,Skill` | Tools available to spawned Claude sessions |

Override any variable before running:

```bash
REVIEW_THRESHOLD=90 REVIEW_MAX_LOOPS=10 /ralpr --phase review --pr 123
```

## Multi-Language Support

Quality gates auto-detect the project's language and run appropriate tools:

| Language | Tests | Lint | Typecheck |
|----------|-------|------|-----------|
| JavaScript / TypeScript | `npm test` | `npm run lint` | `npx tsc --noEmit` |
| Rust | `cargo test` | `cargo clippy -- -D warnings` | `cargo check` |
| Solidity (Foundry) | `forge test` | `forge fmt --check` | — |
| Python | `pytest` | `ruff check .` | `mypy .` |
| Makefile-based | `make test` | `make lint` | — |

Detection is automatic based on project files (`package.json`, `Cargo.toml`, `foundry.toml`, `pyproject.toml`, `Makefile`).

## Advanced: Orchestrator

The orchestrator (`scripts/ralpr-orchestrator.sh`) automates multi-iteration loops by spawning fresh Claude sessions for each iteration. The `/ralpr` skill runs a **single iteration** — the orchestrator chains them.

```bash
# Run review loop until 90% confidence or 7 iterations
ralpr-orchestrator.sh review --pr 123

# Run refactor loop with custom thresholds
ralpr-orchestrator.sh refactor --pr 456 --threshold 90

# Custom max iterations
ralpr-orchestrator.sh review --pr 123 --max-loops 10 --threshold 85
```

**Usage:**

```
ralpr-orchestrator.sh <phase> [options]

Phases:
  review      Run review iterations with parallel reviewers
  refactor    Run refactor iterations with code simplification

Options:
  --pr N              PR number (required)
  --max-loops N       Maximum iterations (default: 7 review, 5 refactor)
  --threshold N       Confidence target (default: 85)
  --working-dir DIR   Working directory (default: current)
  --dry-run           Preview without making changes
```

Each iteration runs in a fresh Claude session with no accumulated context, using PR comments as the sole state carrier between iterations.

## Project Structure

```
ralpr/
├── README.md
├── LICENSE
├── commands/
│   └── ralpr.md                         # Skill entry point
├── skills/
│   └── ralpr/
│       └── SKILL.md                     # Phase orchestration docs
├── agents/
│   ├── explore-agent.md                 # Codebase mapper (Haiku)
│   ├── understand-agent.md              # Requirement extractor (Opus)
│   ├── implement-agent.md               # TDD implementer (Opus)
│   ├── qa-reviewer.md                   # QA reviewer (Opus)
│   ├── domain-expert.md                 # Domain reviewer (Opus)
│   └── codex-reviewer.md               # Codex MCP reviewer (Opus)
├── scripts/
│   ├── ralpr                            # Main CLI
│   ├── ralpr-orchestrator.sh            # Multi-iteration session manager
│   ├── ralpr-implementation.sh          # Phase 1 workflow
│   ├── ralpr-review.sh                  # Phase 2 workflow
│   ├── ralpr-refactor.sh               # Phase 3 workflow
│   ├── lib/
│   │   ├── common.sh                    # Shared utilities
│   │   ├── quality-gates.sh             # Auto-detect test/lint/typecheck
│   │   ├── github-labels.sh             # Label management
│   │   ├── confidence.sh                # Confidence calculations
│   │   └── ci-watcher.sh               # CI status polling
│   ├── queries/
│   │   ├── issue-closing-prs.graphql
│   │   ├── pr-review-thread-details.graphql
│   │   └── pr-unresolved-threads.graphql
│   └── templates/
│       ├── review-iteration-prompt.md
│       └── refactor-iteration-prompt.md
├── config/
│   └── ralpr.config.sh                  # Default configuration
├── schemas/
│   ├── confidence.json
│   ├── explore-output.json
│   ├── understand-output.json
│   ├── implement-output.json
│   ├── reviewer-input.json
│   ├── reviewer-output.json
│   ├── review-fix-output.json
│   ├── codex-review-request.json
│   └── codex-review-response.json
├── docs/
│   ├── phase-implementation.md          # Phase 1 detailed docs
│   ├── phase-review.md                  # Phase 2 detailed docs
│   ├── phase-refactor.md               # Phase 3 detailed docs
│   ├── confidence-formulas.md           # Scoring model docs
│   ├── comment-formats.md              # Label & comment templates
│   └── iteration-state.md             # State management docs
└── hooks/
    ├── hooks.json                       # Hook configuration
    ├── session-start.sh                 # Loads skill on session start
    └── iteration-complete.sh            # Post-iteration hook
```

## State Management

Ralpr uses a stateless-per-session architecture. Each Claude session starts fresh with no accumulated context.

**State carriers:**
- **PR labels**: `ralpr:impl:done`, `ralpr:review:XX`, `ralpr:refactor:XX` — track phase completion and confidence
- **PR comments**: Hidden HTML markers (`<!-- RALPR_REVIEW_STATE {...} -->`, `<!-- RALPR_REFACTOR_STATE {...} -->`) carry iteration state between sessions
- **Local state files**: `.ralpr/pr-<N>/confidence-state.json` — cumulative confidence tracking within a session

**Label lifecycle:**
- `ralpr:impl:done` — set once, never removed
- `ralpr:review:XX` — updated each iteration with current confidence (old label removed, new one added)
- `ralpr:refactor:XX` — same pattern as review

**State comment pattern:** delete-then-create. Each iteration deletes the previous state comment and writes a new one, ensuring exactly one state comment exists per phase.

## Troubleshooting

### `gh auth status` fails

Ralpr requires an authenticated GitHub CLI. Run:

```bash
gh auth login
```

### "No ready tickets" on `/ralpr`

Auto-selection looks for open issues not already assigned and without an existing implementation PR. Verify your repo has open issues, or specify one directly with `--issue <N>`.

### Review confidence stuck below threshold

The cumulative model has diminishing returns. Later iterations earn fewer points. Check:
- Are tests passing? (+4 points per iteration)
- Are high-severity issues being resolved? (+3 points)
- Are reviewers reaching consensus? (+3 points)

If stuck, review the state comment on the PR for a detailed breakdown.

### Codex reviewer fails

The codex-reviewer requires:
1. Codex CLI installed and configured as an MCP server
2. `OPENAI_API_KEY` environment variable set
3. The `mcp__codex__codex` tool available in the Claude session

If Codex is unavailable, the review phase continues with 2 reviewers (QA + Domain Expert).

### Quality gates fail for my language

Quality gates auto-detect based on project files. Ensure your project has:
- **JS/TS**: `package.json` with `test` and `lint` scripts
- **Rust**: `Cargo.toml`
- **Solidity**: `foundry.toml`
- **Python**: `pyproject.toml` with pytest/ruff/mypy config
- **Other**: A `Makefile` with `test` and/or `lint` targets

### Worktree conflicts

Ralpr uses git worktrees for isolation. If you see worktree errors:

```bash
git worktree list    # See active worktrees
git worktree prune   # Clean up stale entries
```

### CI timeout

By default, Ralpr waits for CI to complete. If your CI is slow, the ci-watcher may time out. Check CI status manually:

```bash
gh pr checks <PR_NUMBER>
```

## Contributing

### Setup

```bash
git clone https://github.com/Archethect/ralpr.git
cd ralpr

# Run Claude Code with the local plugin
claude --plugin-dir .
```

### Testing

```bash
# Dry run to verify plugin loads
/ralpr --dry-run

# Test a specific phase against a real issue/PR
/ralpr --phase impl --issue <N>
/ralpr --phase review --pr <N>
/ralpr --phase refactor --pr <N>
```

### PR guidelines

- All scripts are pure Bash — no npm/node dependencies
- Follow the existing code style in `scripts/lib/`
- Agent definitions go in `agents/` as Markdown files
- Configuration variables belong in `config/ralpr.config.sh` with defaults
- Document new phases or agents in the `docs/` directory

## License

[MIT](LICENSE)

## Credits

Built by [Archethect](https://github.com/Archethect).
