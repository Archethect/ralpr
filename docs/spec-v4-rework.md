# Ralpr v4.0 Specification: Agent Teams Architecture

> Complete rework of the Ralpr autonomous development framework. Two-layer architecture: TypeScript outer loop for deterministic orchestration + Claude Code Agent Teams inner loop for intelligent multi-agent coordination per issue. Adaptive team sizing (S/M/L), checkpoint-resume on crash, feedback learning across PRs.

---

## 1. Executive Summary

Ralpr v4 replaces the bash super-loop with a two-layer architecture designed for multi-developer, multi-issue autonomous development. A TypeScript orchestrator manages the issue queue, Docker containers, and host tmux layout, while Agent Teams inside each container coordinate specialized teammates through shared task lists and direct messaging.

### Design Principles

1. **Two-layer architecture**: TypeScript outer loop (deterministic, no AI) + Agent Teams inner loop (intelligent coordination).
2. **Framework-agnostic**: Works across any project type without assumptions.
3. **GitHub for work items. Worktree files for transient pipeline state.** Issues, PRs, labels, and assignments live in GitHub. Checkpoint state for crash recovery lives in `.ralpr/checkpoint.json` inside the worktree.
4. **Docker containers per issue**: Mandatory clean sandbox per team with git worktrees for filesystem isolation.
5. **Codex review is required, with circuit breaker.** Reviews require agreement between Claude and Codex before passing. If Codex MCP is unavailable, the issue is queued as `blocked:codex` with human notification — pipeline does NOT deadlock. Human can override to proceed with single-model review (PR gets `codex-skipped` label). Human decides on merge.
6. **Human-in-the-loop**: Host tmux panes for live intervention + PR comment-driven feedback loop.
7. **Full verification pipeline**: Unit, integration, E2E (headed Chromium via Xvfb), visual regression, security scans.
8. **Auto-scaling**: Scale up when issues arrive, scale to zero when idle. User-configurable max parallel.
9. **Cost transparency with guardrails**: Track and report per-issue, per-phase costs. Soft warning at `RALPR_COST_WARNING` (default $25/issue) triggers macOS notification. Hard pause at `RALPR_COST_HARD_LIMIT` (default $100/issue) pauses pipeline and requires manual resume.
10. **Configurable parallelism**: User defines max concurrent agent teams.
11. **Adaptive team sizing**: Issues sized as S/M/L get appropriately scaled teams (5/5/8 teammates).
12. **Checkpoint-resume**: Pipeline state checkpointed to worktree file; outer loop resumes from last checkpoint on crash.
13. **Feedback learning**: Confirmed review findings accumulated in `.ralpr/patterns.md` and read by agents on future issues.
14. **Goal-oriented verification**: Every tier verifies implementation against original issue goals before PR creation. Lead checks "does this PR actually solve the issue?" in all tiers. Tier L gets additional dedicated Spec Reviewer verification.

---

## 2. Technology Stack

### Outer Loop (Host)

```
TypeScript (Node.js) — deterministic process management, no AI reasoning
├── child_process.spawn() → `claude` CLI with Agent Teams env
├── gh CLI → GitHub API for issues, PRs, comments
├── tmux commands → host pane management
└── docker CLI → container lifecycle (MANDATORY)
```

### Inner Loop (per Docker container)

```
Claude Code CLI with CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
├── Team lead in delegate mode (coordinates only, never implements — ALL tiers)
└── Teammates spawned by lead (count depends on tier):
    Tier S (5): Implementer, Code Simplifier, Code Reviewer, Codex Reviewer, Test Runner
    Tier M (5): Implementer, Code Simplifier, Code Reviewer, Codex Reviewer, Test Runner
    Tier L (8): Explorer, Implementer, Spec Reviewer, Code Simplifier, Code Reviewer,
                Codex Reviewer, Test Runner, Doc Writer
```

Codex Reviewer is REQUIRED in all tiers. It runs via `mcp__codex__codex` MCP tool. If the Codex MCP bridge is unavailable, a circuit breaker activates: the issue is queued as `blocked:codex`, human is notified via macOS notification, and the pipeline pauses. Human can override to proceed with single-model review (PR receives `codex-skipped` warning label).

### Docker Image

```
Base: node:20-slim
├── Chromium (headed via Xvfb)
├── Playwright
├── gh CLI
├── git
├── Xvfb virtual display (DISPLAY=:99)
└── noVNC web viewer (optional, port 6080+N)

Mounts: repo worktree directory → /workspace
Env: ANTHROPIC_API_KEY, GH_TOKEN, CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

Docker is mandatory for filesystem safety. There is no non-Docker mode.

### Host

```
tmux session "ralpr"
├── Pane per issue: docker exec -it ralpr-issue-N (attach to container)
└── Dashboard pane: TypeScript TUI (queue, costs, status)

Node.js orchestrator: background process
```

---

## 3. Pain Points Addressed

| Current Problem | v4 Solution |
|----------------|-------------|
| Bash orchestration is fragile | TypeScript outer loop for deterministic work, Agent Teams for reasoning |
| Agents lose context between phases | Teammates persist within a session; shared task list + mailbox |
| Agents work in silos | Agent Teams: shared tasks, direct messaging, challenge protocol |
| Review quality inconsistent | Multi-model consensus (Claude + Codex) with evidence-based verdicts |
| Can't verify frontend/UI | Headed Chromium via Xvfb + Playwright E2E + Claude vision |
| Can't see what agents do in the browser | noVNC virtual display at `http://localhost:608X` |
| Can't interact with agents | Host tmux panes → `docker exec` into any container, Shift+Up/Down between teammates |
| Confidence scores inaccurate | Replace with pass/fail per stage — no numeric scores |
| Label/comment detection unreliable | Structured GitHub state with `gh` CLI queries |
| No cost visibility | Per-issue, per-phase cost tracking and dashboard |
| No auto-scaling | Outer loop polls issue queue, spawns/terminates containers dynamically |
| Single developer only | GitHub assignment as distributed lock; any dev's orchestrator can claim work |
| Every issue gets same treatment | Adaptive tier sizing (S/M/L) based on issue complexity |
| No crash recovery | Checkpoint-resume from worktree state file |
| No cross-PR learning | Patterns file accumulates confirmed review insights |

---

## 4. Agent Team

### Team Lead (delegate mode)

The team lead coordinates only — it never writes code or runs tests directly, in ALL tiers (no exceptions).

Responsibilities:
- Reads issue context, drives stage transitions through the pipeline
- **Decides the tier** (S/M/L) based on issue complexity during research (Tier S) or evaluate (Tier M/L)
- Creates Agent Teams tasks for teammates at each stage
- Routes review findings to implementer via mailbox
- Makes pass/fail decisions based on teammate reports
- Handles human feedback (PR comments → new tasks for implementer)
- Resolves reviewer disagreements (or escalates to human)
- **Deduplicates overlapping findings** from Code Reviewer and Codex by `(file, line_range, category)`. Higher severity wins. Both reviewer IDs kept. Prevents double-counting for "2+ reviewers agree" threshold.
- **Verifies implementation against original issue goals** before PR creation (all tiers)
- **Writes checkpoint** to `.ralpr/checkpoint.json` after each stage transition

### Tier-Based Team Sizing

The lead decides the tier — no labels, no external configuration (unless `RALPR_FORCE_TIER` is set).

| Tier | Teammates | When to Use | Lead Role |
|------|-----------|-------------|-----------|
| **S (Small)** | 5 | Simple fixes, config changes, small features | Lead delegates to Implementer |
| **M (Minimal)** | 5 | Standard features, moderate complexity | Lead delegates to Implementer |
| **L (Full)** | 8 | Large features, cross-cutting changes, complex refactors | Lead delegates, full review chain |

#### Teammate Roster by Tier

| Teammate | Tier S | Tier M | Tier L | Model |
|----------|--------|--------|--------|-------|
| Explorer | — | — | yes | opus |
| Implementer | yes | yes | yes | opus |
| Spec Reviewer | — | — | yes | opus |
| Code Simplifier | yes | yes | yes | opus |
| Code Reviewer | yes | yes | yes | opus |
| Codex Reviewer | yes | yes | yes | codex |
| Test Runner | yes | yes | yes | haiku |
| Doc Writer | — | — | yes | haiku |

Implementer, Code Simplifier, Code Reviewer, Codex Reviewer, and Test Runner are present in ALL tiers. The lead is always coordinator-only — it never implements directly.

#### Tier Upgrade Rule

If Tier M hits 3+ fix iterations on a single task, the lead MAY upgrade to Tier L by spawning additional teammates (Explorer, Spec Reviewer, Doc Writer) mid-session.

### Teammates (detailed roles)

| # | Teammate | Role | Active Stages | Key Behaviors |
|---|----------|------|---------------|---------------|
| 1 | **Explorer** | Codebase mapper + context builder | research | Maps directory structure, reads AGENTS.md/CLAUDE.md conventions, extracts requirements from issue. Reads `.ralpr/patterns.md` for accumulated insights. Outputs codebase map + structured requirements. |
| 2 | **Implementer** | TDD code + tests + targeted fixes | implement, fix | Red-green-refactor cycle. Claims tasks from plan, commits per-AC. Reads review findings from mailbox, applies targeted fixes. Reads `.ralpr/patterns.md` for known patterns. |
| 3 | **Spec Reviewer** | Goal/acceptance-criteria verification | task-review, spec-review | Verifies implementation meets stated goals. Per-task: checks task AC. Per-PR: holistic issue goal verification. Pass/fail verdict. |
| 4 | **Code Simplifier** | Refactor for clarity, no behavior change | simplify | Removes dead code, improves naming, extracts helpers if warranted. Never changes behavior. Commits separately. Runs in ALL tiers. |
| 5 | **Code Reviewer** | Quality: bugs, architecture, conventions, security, performance | review, code-review | Reviews against project conventions, OWASP Top 10, performance patterns. Challenges other reviewers on disagreements. |
| 6 | **Codex Reviewer** | Third-party review (MCP) | review, code-review | Runs via `mcp__codex__codex` MCP tool. Independent second opinion for multi-model consensus. REQUIRED — circuit breaker activates if unavailable (see Section 5). |
| 7 | **Test Runner** | Test execution, coverage, quality gates | test | Runs full test suite, checks coverage thresholds, runs linter + type checker. Pass/fail verdict. |
| 8 | **Doc Writer** | Docstrings, API docs, README | docs | Adds/updates docstrings for new/changed public APIs. Updates README if API surface changed. No docs for internal helpers unless complex. |

### Coordination Model (Agent Teams Primitives)

**Shared task list**: Lead creates tasks per stage, teammates claim from the list.

**Mailbox messaging**: Direct communication between any teammates.
- Reviewers → Implementer: specific findings to fix
- Reviewers ↔ Reviewers: challenge protocol for disagreements
- Lead → Any: stage transition instructions

**Challenge protocol**: When reviewers disagree:
1. Disagreeing reviewers message each other directly
2. They attempt to reach consensus with evidence
3. If unresolved, lead makes the call
4. If lead is uncertain, issue flagged for human

**Teammate lifecycle**: Teammates are spawned once by the lead and persist for the entire issue session. They are NOT respawned fresh per stage — this enables accumulated context across all stages.

---

## 5. Two-Layer Architecture

### Outer Loop: TypeScript Orchestrator (`src/orchestrator.ts`)

Long-lived Node.js process running on the host. Handles all deterministic work — no AI reasoning needed.

**Responsibilities:**
- Polls GitHub every `RALPR_ISSUE_POLL_INTERVAL` (60s) for issues matching criteria
- Claims issues via GitHub assignment (distributed lock)
- **Creates git worktree per issue** (sole owner of worktree lifecycle — inner loop verifies but does not create)
- Spawns Docker container per issue with Agent Teams env
- Creates tmux pane per container (via `docker exec`)
- Monitors PR comments every `RALPR_PR_POLL_INTERVAL` (30s), routes to correct container
- Auto-rebases assigned PRs when merge conflicts detected
- Aggregates cost data from container outputs
- Scales up/down based on queue depth vs `RALPR_MAX_PARALLEL_TEAMS`
- Renders dashboard TUI in a dedicated tmux pane
- **Heartbeat monitoring**: Detects unresponsive containers (`RALPR_CONTAINER_HEARTBEAT_TIMEOUT`, default 300s)
- **Crash detection + checkpoint-resume**: On container crash, reads `.ralpr/checkpoint.json` from worktree, respawns container with enriched prompt including checkpoint data (max `RALPR_MAX_RESUME_ATTEMPTS` resumes, then escalate to human)
- **Checkpoint monitoring**: After each checkpoint write, validates correct stage order, within iteration limits, no skips. Intervenes on violations (kill container + resume from last valid checkpoint).
- **Cost monitoring**: Triggers macOS notification at `RALPR_COST_WARNING` threshold (default $25/issue). Pauses pipeline at `RALPR_COST_HARD_LIMIT` threshold (default $100/issue) and escalates to human for manual resume.
- **Codex circuit breaker**: If Codex MCP unavailable, queues issue as `blocked:codex`, notifies human via macOS notification, allows human override to proceed with single-model review (PR gets `codex-skipped` warning label). Pipeline does NOT deadlock on Codex downtime.

**What it does NOT do:**
- No AI reasoning or model calls
- No stage transition decisions (that's the team lead's job) — but monitors stage ordering and intervenes on violations
- No code review or implementation logic

### Inner Loop: Agent Teams per Issue (inside Docker)

Each Docker container runs one Claude Code session with Agent Teams enabled. The inner loop follows a tier-specific pipeline with two quality loops — one per-task and one per-PR.

**Checkpoint writes**: The team lead writes `.ralpr/checkpoint.json` after every stage transition. Because the worktree is mounted from the host filesystem, this file survives container crashes. Checkpoint also serves as a **context anchor** — the lead re-reads `checkpoint.json` after Claude Code's auto-compaction to recover pipeline state.

**Lifecycle:**
1. Outer loop starts container with `-p "Work on issue #N..."` prompt (enriched with checkpoint data on resume)
2. Team lead reads issue, assesses complexity, decides tier (S/M/L), spawns teammates
3. Executes tier-specific pipeline (see Section 7)
4. **complete**: Lead sets labels, container signals outer loop and exits

**On resume after crash:**
1. Outer loop detects container exit/unresponsive (heartbeat timeout)
2. Reads `.ralpr/checkpoint.json` from worktree
3. Respawns container with enriched prompt: original issue context + checkpoint state + "resume from stage X"
4. New team lead reads checkpoint, skips completed stages, continues from last completed stage
5. Max `RALPR_MAX_RESUME_ATTEMPTS` (default 2) resumes. After that, escalate to human.

**Communication with outer loop:**
- Container stdout for cost/status parsing
- GitHub labels for stage completion signals
- Container exit code for success/failure

---

## 6. Docker Architecture

```
Host filesystem:
  /path/to/repo/                           # Main repo (untouched)
  /path/to/repo/.worktrees/
    ralpr-issue-42/                        # Worktree for issue 42
      .ralpr/checkpoint.json               # Pipeline checkpoint (survives crashes)
    ralpr-issue-15/                        # Worktree for issue 15
      .ralpr/checkpoint.json

Docker containers:
  ralpr-issue-42:
    Mounts: .worktrees/ralpr-issue-42 → /workspace
    Runs: Xvfb :99 (virtual display)
    Runs: noVNC on port 6080
    Runs: claude -p "Work on issue #42..." (Agent Teams enabled)

  ralpr-issue-15:
    Mounts: .worktrees/ralpr-issue-15 → /workspace
    Runs: noVNC on port 6081
    Runs: claude -p "Work on issue #15..." (Agent Teams enabled)
```

### Host tmux Layout

```
tmux session "ralpr":
  ┌─────────────────┬─────────────────┐
  │ docker exec     │ docker exec     │
  │ ralpr-issue-42  │ ralpr-issue-15  │
  │                 │                 │
  │ [Agent Teams    │ [Agent Teams    │
  │  in-process]    │  in-process]    │
  ├─────────────────┴─────────────────┤
  │ Dashboard (TypeScript TUI)        │
  │ Queue: 5 | Active: 2 | $12.40    │
  └───────────────────────────────────┘
```

### Browser Viewing (Optional)

```
http://localhost:6080 → ralpr-issue-42 Chromium display
http://localhost:6081 → ralpr-issue-15 Chromium display
```

noVNC provides a web-based VNC viewer so developers can watch what agents see in the browser — no VNC client needed.

### Container Naming

```
ralpr-issue-{number}
# Example: ralpr-issue-42, ralpr-issue-15
```

### Worktree Lifecycle

1. **Create** when issue claimed: `git worktree add .worktrees/ralpr-issue-42 -b feat/issue-42`
2. **Mount** into Docker container as `/workspace`
3. **Cleanup** when container exits (success or failure)
4. **Stale detection**: Remove worktrees with no associated running container (24h threshold)

---

## 7. Stage Pipeline

All stages flow within a single Agent Teams session. The team lead drives transitions — teammates persist across all stages. The pipeline varies by tier.

### Tier S Pipeline (9 stages)

Lead delegates to Implementer. No evaluate/plan — lead assesses during research.

| # | Stage | Agent(s) | Purpose | Loop? |
|---|-------|----------|---------|-------|
| 1 | **setup** | lead | Verify worktree, fetch issue, set labels | — |
| 2 | **research** | lead | Map codebase, understand context, assess complexity, decide tier | — |
| 3 | **implement** | implementer | Implement changes (TDD) | per-task |
| 4 | **simplify** | code-simplifier | Clean up code without changing behavior | Task Quality |
| 5 | **review+codex** | code-reviewer + codex | Internal code review (parallel: Claude + Codex) | Task Quality |
| 6 | **test** | test-runner | Run tests + quality audit | Task Quality |
| 7 | **pr** | lead | Goal verification + create or update PR | — |
| 8 | **code-review+codex** | code-reviewer + codex | Final quality check (parallel: Claude + Codex) | PR Quality |
| 9 | **complete** | lead | Set labels, cleanup | — |

**Task quality loop**: implement → simplify → review+codex → test (max 3 iterations)
**PR quality loop**: code-review+codex (max 3 iterations)

### Tier M Pipeline (11 stages)

Lead delegates to Implementer.

| # | Stage | Agent(s) | Purpose | Loop? |
|---|-------|----------|---------|-------|
| 1 | **setup** | lead | Verify worktree, fetch issue, set labels | — |
| 2 | **research** | lead | Map codebase, understand context | — |
| 3 | **evaluate** | lead | Assess approach options, decide tier | — |
| 4 | **plan** | lead | Create implementation plan as task list | — |
| 5 | **implement** | implementer | Execute each task from the plan (TDD) | per-task |
| 6 | **simplify** | code-simplifier | Clean up code without changing behavior | Task Quality |
| 7 | **review+codex** | code-reviewer + codex | Internal code review (parallel: Claude + Codex) | Task Quality |
| 8 | **test** | test-runner | Run tests + quality audit | Task Quality |
| 9 | **pr** | lead | Goal verification + create or update PR | — |
| 10 | **code-review+codex** | code-reviewer + codex | Final quality check (parallel: Claude + Codex) | PR Quality |
| 11 | **complete** | lead | Set labels, cleanup | — |

**Task quality loop**: implement → simplify → review+codex → test (max 3 iterations)
**PR quality loop**: code-review+codex (max 3 iterations)

### Tier L Pipeline (15 stages)

Full team with Spec Reviewer and Doc Writer.

| # | Stage | Agent(s) | Purpose | Loop? |
|---|-------|----------|---------|-------|
| 1 | **setup** | lead | Verify worktree, fetch issue, set labels | — |
| 2 | **research** | explorer | Map codebase structure, understand context, extract requirements | — |
| 3 | **evaluate** | lead | Assess approach options, trade-offs, constraints, decide tier | — |
| 4 | **plan** | lead | Create implementation plan as task list | — |
| 5 | **implement** | implementer | Execute each task from the plan (TDD) | per-task |
| 6 | **task-review** | spec-reviewer | Verify task achieved its stated goal | Task Quality |
| 7 | **fix** | implementer | Address task-review findings | Task Quality |
| 8 | **simplify** | code-simplifier | Clean up code without changing behavior | Task Quality |
| 9 | **review+codex** | code-reviewer + codex | Internal code review (parallel: Claude + Codex) | Task Quality |
| 10 | **test** | test-runner | Run tests + quality audit | Task Quality |
| 11 | **docs** | doc-writer | Add docstrings, update README if API changed (conditional) | — |
| 12 | **pr** | lead | Goal verification + create or update PR | — |
| 13 | **spec-review** | spec-reviewer | Verify PR achieves issue goals holistically | PR Quality |
| 14 | **code-review+codex** | code-reviewer + codex | Final quality check (parallel: Claude + Codex) | PR Quality |
| 15 | **complete** | lead | Set labels, cleanup, append to patterns file | — |

**Task quality loop**: implement → task-review → fix → simplify → review+codex → test (max 3 iterations)
**PR quality loop**: spec-review → code-review+codex (max 3 iterations)
**Docs stage**: Conditional — only runs when public API surface has changed.

### Quality Loops

#### Task Quality Loop (per task from the plan)

**Tier S/M** (no task-review or fix stages):
```
implement(task-N)
    → simplify: clean up the code
    → review + codex (parallel): quality check
        → PASS: continue to test
        → FAIL: fix → simplify → review (max 3 iterations)
    → test: run tests + coverage check
        → PASS: task complete, move to next task
        → FAIL: fix → test (max 3 iterations)
```

**Tier L** (full review chain):
```
implement(task-N)
    → task-review: does it meet the task's goal?
        → PASS: continue to simplify
        → FAIL: fix → task-review (max 3 iterations)
    → simplify: clean up the code
    → review + codex (parallel): quality check
        → PASS: continue to test
        → FAIL: fix → review (max 3 iterations)
    → test: run tests + coverage check
        → PASS: task complete, move to next task
        → FAIL: fix → test (max 3 iterations)
```

A task must pass ALL checks before moving to the next task.

#### PR Quality Loop (after PR creation)

**Tier S/M**:
```
pr
    → code-review + codex (parallel): final holistic quality check
        → PASS: complete
        → FAIL: fix → code-review (max 3 iterations)
```

**Tier L**:
```
pr
    → spec-review: does the PR achieve the issue's goals?
        → PASS: continue to code-review
        → FAIL: fix → spec-review (max 3 iterations)
    → code-review + codex (parallel): final holistic quality check
        → PASS: complete
        → FAIL: fix → code-review (max 3 iterations)
```

**Exit conditions**: All checks pass, or max iterations reached (escalate to human).

### Stage Details

#### Stage: setup (lead — all tiers)
- Verify worktree exists (created by outer loop before Docker start)
- Fetch issue details via GitHub API
- Set `ralpr:in-progress` label
- Assign issue to bot
- Write initial checkpoint

#### Stage: research (explorer in Tier L, lead in Tier S/M)
- Map codebase structure (directory tree, config detection)
- Read AGENTS.md/CLAUDE.md for project conventions
- Read `.ralpr/patterns.md` for accumulated insights from past PRs
- Identify relevant files, patterns, dependencies
- Extract acceptance criteria from issue
- Identify user directives (binding requirements)
- Output: codebase map + structured requirements
- In Tier S: lead also assesses complexity and decides tier here

#### Stage: evaluate (lead — Tier M/L only)
- Review research findings
- Assess multiple approach options with trade-offs
- Consider constraints (performance, backwards compat, scope)
- Select approach (or ask human if genuinely ambiguous)
- Decide tier if not already decided

#### Stage: plan (lead — Tier M/L only)
- Break selected approach into discrete tasks
- Each task has: title, description, acceptance criteria, estimated files to modify
- Create Agent Teams task list
- Assign implementation order (respect dependencies)

#### Stage: implement (implementer — all tiers, per-task)
- Claim next task from task list
- Read `.ralpr/patterns.md` for known patterns to follow/avoid
- Red-green-refactor cycle (TDD)
- Commit after each passing AC: `feat(<scope>): <description>`
- Follow codebase conventions from research output

#### Stage: task-review (spec-reviewer — Tier L only)
- Read the task's stated goal and acceptance criteria
- Read the implementer's changes (diff)
- Verdict: PASS (goal met) or FAIL (with specific findings)

#### Stage: fix (implementer — Tier L only)
- Address specific findings from task-review or code review
- Targeted fixes only (no scope creep)
- Commit fixes separately: `fix(<scope>): address review - <finding>`

#### Stage: simplify (code-simplifier — all tiers)
- Review implementation for unnecessary complexity
- Simplify without changing behavior
- Remove dead code, extract helpers if warranted, improve naming
- Commit: `refactor(<scope>): simplify <description>`
- Runs ALWAYS — never skipped, regardless of tier

#### Stage: review+codex (code-reviewer + codex, parallel — all tiers)
- **Code Reviewer** checks: bugs, architecture, conventions, security (OWASP), performance
- **Codex Reviewer** runs independently via MCP for multi-model consensus
- Reviewers should reference original acceptance criteria, not just code quality
- Aggregate: both PASS → proceed. Any FAIL → fix loop. Lead deduplicates overlapping findings by `(file, line_range, category)`.
- If reviewers disagree, lead resolves.
- Both reviewers are REQUIRED. If Codex unavailable, circuit breaker activates (see Section 5).

#### Stage: test (test-runner — all tiers)
- Run full test suite
- Check coverage meets thresholds
- Run linter + type checker
- Verdict: PASS (all green) or FAIL (with specific failures)

#### Stage: docs (doc-writer — Tier L only, conditional)
- Only runs when public API surface has changed
- Add/update docstrings for new/changed public APIs
- Update README if API surface changed
- No docs for internal helpers unless complex

#### Stage: pr (lead — all tiers)
- **Goal verification**: Lead checks implementation against original issue acceptance criteria — "does this PR actually solve the issue?" This runs in ALL tiers. For Tier L, the dedicated Spec Reviewer does a deeper check in the subsequent spec-review stage.
- Create PR (or update existing) with structured description
- Include: summary, task list, test results
- Wait for CI to pass

#### Stage: spec-review (spec-reviewer — Tier L only)
- Holistic check: does the entire PR achieve the issue's goals?
- Verify ALL acceptance criteria are addressed
- Check user directives are satisfied
- Verdict: PASS or FAIL (with specific gaps)

#### Stage: code-review+codex (code-reviewer + codex, parallel — all tiers)
- Final quality gate across entire PR diff
- Focus on cross-task interactions, integration concerns
- Reviewers should reference original acceptance criteria, not just code quality
- Security audit across full change set
- Lead deduplicates overlapping findings by `(file, line_range, category)` before routing to fix loop
- Verdict: PASS or FAIL
- Both Code Reviewer and Codex REQUIRED. If Codex unavailable, circuit breaker activates (see Section 5).

#### Stage: complete (lead — all tiers)
- Set `ralpr:ready-for-review` label
- Report costs
- Clean up (unassign issue if configured)
- GitHub: `needs-human` label + @mention
- tmux: pane title updated
- macOS: desktop notification
- **Append confirmed CRITICAL/HIGH findings to `.ralpr/patterns.md`** (Tier L only)

---

## 8. Human Interaction Model

### Intervention via tmux

```
Host tmux:
  Ctrl-B + arrow keys  → switch between issue panes
  Type                  → interact with Agent Teams CLI

Inside container (Agent Teams):
  Shift+Up/Down         → switch between teammates
  Type                  → direct input to selected teammate
```

Each tmux pane runs `docker exec -it ralpr-issue-N` which attaches to the Agent Teams session inside the container. The user gets full Claude Code CLI interaction — they can steer any agent, override decisions, or provide context.

### PR Comment Feedback

The outer loop polls for new PR comments every `RALPR_PR_POLL_INTERVAL` (30s):

1. Outer loop detects unresolved comment on PR
2. Routes comment content to the correct container (via stdin or signal)
3. Team lead reads comment, creates task for Implementer
4. Implementer makes targeted fix
5. Pushes commit referencing the comment
6. Resolves the comment thread

Comments from PR author, maintainers, or CODEOWNERS are treated as **CRITICAL** directives — they cannot be skipped without explicit approval from the same user.

### Browser Viewing via noVNC

For frontend work, developers can open `http://localhost:608X` in their browser to watch what agents see in real-time. No VNC client needed — noVNC provides a web-based viewer.

### Status Display

Status is internal only — zero bot comments on GitHub PRs. Only humans comment on PRs.

| Channel | Information |
|---------|-------------|
| **tmux pane titles** | Current stage, tier, iteration count |
| **Dashboard TUI** | Queue depth, active teams, costs, stage per team |
| **Container stdout** | Detailed stage transitions, verdicts, costs |
| **macOS notifications** | PR ready, agent blocked/failed |

### Notification System

| Event | tmux | GitHub | macOS |
|-------|------|--------|-------|
| Phase complete | Pane title update | Label added | - |
| PR ready for review | Pane highlight | @mention + `needs-human` label | Desktop notification |
| Agent blocked/failed | Pane turns red | — | Desktop notification |
| Bug auto-filed | - | New issue created | - |

macOS notifications via:
```bash
osascript -e 'display notification "PR #87 ready for review" with title "Ralpr"'
```

---

## 9. Frontend/UI Verification

Three-layer verification for any PR touching frontend code. Xvfb enables headed Chromium (not just headless), and noVNC allows live viewing.

### Layer 1: Playwright E2E (Functional)

- Run inside Docker container with headed Chromium via `Xvfb :99`
- Execute existing E2E test suite
- Agents write NEW E2E tests for new features
- Test user flows, form submissions, navigation

### Layer 2: Screenshot Comparison (Visual Regression)

- Capture screenshots at key breakpoints (mobile, tablet, desktop)
- Compare against golden images if available
- If design spec (Figma link) provided, compare against exported design
- Store screenshots in worktree for human review

### Layer 3: Claude Vision (Design Quality)

- Feed screenshots to Claude's multimodal capabilities
- Assess: layout correctness, spacing consistency, color adherence, accessibility
- Check against: Figma reference, verbal description in ticket, component library patterns
- Report findings as structured review output

---

## 10. Bug Lifecycle

### Agent-Filed Bugs

During review or refactor, if an agent discovers a pre-existing bug NOT related to the current PR:

1. Agent creates a new GitHub issue with:
   - Clear reproduction steps
   - Severity assessment
   - Relevant code references
   - Labels: `bug`, `filed-by-agent`
2. If the agent is confident in the fix (simple, low-risk):
   - Also labels: `auto-fixable`
   - Can be auto-assigned in the next available cycle
3. If complex or risky:
   - Labels: `needs-triage`
   - Waits for human or lead assessment

### Smart Failure Analysis

When tests fail, agents don't blindly retry. Instead:

1. **Analyze failure output**: Parse error messages, stack traces, test names
2. **Classify failure type**:
   - **Real failure**: Code bug → fix the code
   - **Flaky test**: Timing, network, race condition → retry once, if still flaky, file bug for the test
   - **Environment issue**: Missing dependency, Docker config → fix environment
   - **Merge conflict**: Upstream changed → outer loop auto-rebases
3. **Take appropriate action** based on classification
4. **After 3 failed attempts** at fixing: flag for human with full analysis

---

## 11. State Management

GitHub for work items (issues, PRs, labels, assignments). Worktree files for transient pipeline state. tmux/logs for status display. Zero bot comments on GitHub PRs.

### State Mechanisms

| Mechanism | Purpose |
|-----------|---------|
| **Issue labels** | Ticket status (`status:backlog`, `status:in-progress`, `status:done`) |
| **Issue assignment** | Distributed lock for claiming (race condition prevention across developers) |
| **PR labels** | Stage signals (`ralpr:in-progress`, `ralpr:ready-for-review`, `needs-human`) |
| **PR review status** | Human approval state |
| **`.ralpr/checkpoint.json`** | Pipeline state for crash recovery (in worktree, survives container death) |

### Checkpoint File (`.ralpr/checkpoint.json`)

Written by the team lead after every stage transition. Lives in the worktree directory (mounted from host), so it survives container crashes. Serves dual purpose: **crash recovery** (outer loop reads on container death) AND **context recovery** (lead re-reads after Claude Code auto-compaction to recover pipeline state).

```json
{
  "current_stage": "review",
  "tier": "M",
  "completed_tasks": ["task-1", "task-2"],
  "committed_shas": ["abc123", "def456"],
  "last_completed_stage": "implement",
  "review_verdicts": {
    "task-1": "pass",
    "task-2": "fail"
  },
  "cost_so_far": 8.40,
  "plan": [
    {"id": "task-1", "title": "Add login endpoint", "status": "done"},
    {"id": "task-2", "title": "Add session middleware", "status": "in_progress"},
    {"id": "task-3", "title": "Add logout endpoint", "status": "pending"}
  ],
  "quality_iterations": {
    "task-2": {"task_quality": 1, "pr_quality": 0}
  },
  "compact_prompt": "You are the team lead for issue #42. Tier M. Currently at review stage for task-2. task-1 is done (pass). task-2 implementation complete, pending review. Plan has 3 tasks total.",
  "timestamp": "2026-02-09T12:34:56Z"
}
```

### Resume Strategy by Stage Range

| Last Completed Stage | Resume Action |
|---------------------|---------------|
| setup | Re-run research from scratch |
| research, evaluate, plan | Resume from next stage, reuse plan if present |
| implement (mid-task) | Resume from current task (check committed SHAs to skip completed tasks) |
| simplify, review, test | Re-run from implement of current task (code may be partially committed) |
| docs, pr | Resume from pr (re-create/update if needed) |
| spec-review, code-review | Resume from the failing review stage |
| complete | No resume needed — already done |

### What Does NOT Live in GitHub

- Pipeline checkpoint state (lives in `.ralpr/checkpoint.json` in worktree)
- Stage verdicts and cost breakdowns (live in container stdout / dashboard)
- Rolling status (lives in tmux pane titles / dashboard TUI)

---

## 12. Pass/Fail Quality Model

No numeric confidence scores. Each quality check produces a binary pass/fail verdict. A stage either passes or fails. The PR is ready when all stages pass.

### Stage Verdict Format

Each quality stage (task-review, review, test, spec-review, code-review) records:
```json
{
  "stage": "review",
  "task": "task-3",
  "verdict": "pass | fail",
  "iteration": 1,
  "findings": [
    {
      "id": "CR-C001",
      "severity": "CRITICAL | HIGH | MEDIUM | LOW",
      "description": "SQL injection in login query",
      "file": "src/auth.ts",
      "line": 42,
      "suggestion": "Use parameterized query"
    }
  ]
}
```

### Pass/Fail Rules

| Condition | Result |
|-----------|--------|
| No findings | PASS |
| Only LOW findings | PASS (findings logged but non-blocking) |
| Any MEDIUM+ finding | FAIL → fix loop |
| Both code-reviewer AND codex pass | Stage passes |
| Either code-reviewer or codex fails | FAIL → fix loop |
| Codex MCP unavailable | BLOCK — issue queued as `blocked:codex`, human notified via macOS notification. Human can override to proceed with single-model review (PR gets `codex-skipped` label). Pipeline does NOT deadlock. |
| Both reviewers find same issue | Lead deduplicates by `(file, line_range, category)`. Higher severity wins. Both reviewer IDs kept. |
| Reviewers disagree on severity | Challenge protocol → lead resolves |
| Max iterations (3) reached without pass | Escalate to human |

Both Claude (Code Reviewer) and Codex (Codex Reviewer) participate in every review under normal conditions. When Codex is unavailable, the circuit breaker (see Section 5) activates — pipeline pauses rather than deadlocking, and human can override to proceed with single-model review.

### Fix-by-Default (unchanged)

The default action for every finding is **FIX**. Skipping requires structured justification:
- **CRITICAL/HIGH**: MUST fix. No skip without explicit user approval.
- **MEDIUM with 2+ reviewers agreeing**: MUST fix.
- **LOW**: Fix at discretion, log reasoning for skips.

Prohibited skip reasons: "future ticket", "out of scope", "acceptable for initial PR".

### Human Role

Agents only recommend — human decides on final merge. The `needs-human` label signals readiness for human review. Agents never auto-merge.

---

## 13. Cost Tracking

### Collection

- Per-container: parse Claude CLI output for token counts and cost
- Per-issue: aggregate across container lifecycle
- Per-phase: tag costs to pipeline stages
- **Checkpoint continuity**: Cost recorded in `.ralpr/checkpoint.json` so resumed sessions continue the running total

### Reporting

- **Dashboard pane**: Running total, cost-per-issue, daily summary
- **Container stdout**: Cost summary printed before exit

No cost information is posted as bot comments on GitHub PRs. Status is internal only.

### Limits

| Threshold | Default | Behavior |
|-----------|---------|----------|
| `RALPR_COST_WARNING` | `$25/issue` | macOS notification + dashboard highlight. Pipeline continues. |
| `RALPR_COST_HARD_LIMIT` | `$100/issue` | Pipeline pauses. macOS notification. Requires manual resume via `ralpr resume <issue>`. |

Per-stage indirect cost control: `RALPR_STAGE_MAX_TURNS` (default 50) limits the number of API turns per teammate per stage. Prevents runaway loops.

All thresholds configurable via environment variables (see Section 19).

### Dashboard Metrics

The dashboard TUI tracks and displays:

- **Completion rate**: Issues completed / issues claimed
- **Cost per merged PR**: Total cost / PRs merged
- **Issues completed**: Total and per-tier breakdown
- **Average time per tier**: Wall-clock time from claim to PR-ready

---

## 14. Auto-Scaling

| Parameter | Default | Description |
|-----------|---------|-------------|
| `RALPR_ISSUE_POLL_INTERVAL` | `60` | Seconds between GitHub issue queue polls |
| `RALPR_MAX_PARALLEL_TEAMS` | `3` | Maximum concurrent Docker containers |

### Scaling Rules

- **Scale up**: Spawn new container when unassigned issues exist AND active containers < `RALPR_MAX_PARALLEL_TEAMS`
- **Scale down**: Don't spawn when queue is empty
- **Scale to zero**: All containers terminate when no issues remain and all PRs are merged or waiting for human review

### Priority Selection

The lead evaluates the issue queue and selects the highest-impact work. There is no strict FIFO — the lead uses judgment based on issue labels, severity, and dependencies.

**Rule: Never abandon in-progress work.** Finish the current task before picking the next highest priority. A new high-priority issue does not preempt active work.

### Claiming Protocol

Same as v3 — GitHub assignment as distributed lock:
1. Find candidate issue (unassigned, open, matching label criteria)
2. Assign to self via `gh issue edit --add-assignee @me`
3. Verify claim (re-check assignee matches)
4. If race lost: release and retry with next candidate

---

## 15. Feedback Learning

### Patterns File (`.ralpr/patterns.md`)

A committed file in the repository root that accumulates confirmed review insights across PRs. This enables agents to learn from past mistakes and successes.

### Write (Lead, at complete stage)

After a PR passes all reviews, the lead appends confirmed CRITICAL/HIGH findings to `.ralpr/patterns.md`:
- Only findings that were actually fixed and confirmed by reviewers
- Each pattern includes: source PR, rule description, date

### Read (Explorer + Implementer)

- **Explorer** reads during research stage to surface known patterns for the relevant code area
- **Implementer** reads during implement stage to follow/avoid known patterns

### Format

```markdown
## Patterns

### 2026-02-09 — PR #87
- **CRITICAL**: Always use parameterized queries for database access (found raw SQL in `src/auth.ts`)
- **HIGH**: Validate JWT expiry before trusting claims (missing check in `src/middleware/auth.ts`)

### 2026-02-05 — PR #82
- **HIGH**: Run `npm audit` after adding dependencies (vulnerable transitive dep via `lodash`)
```

### Pruning

- Patterns older than `RALPR_PATTERN_MAX_AGE_DAYS` (default 90) are marked stale and can be removed
- Maximum 200 lines — oldest patterns pruned first when limit exceeded
- Pruning happens at the start of the complete stage before appending new patterns

---

## 16. Claude Code Integration

Leverage Claude Code's built-in capabilities to improve agent effectiveness.

### Context7 (Library Documentation)

The Implementer uses Context7 MCP (`mcp__plugin_context7_context7`) for library documentation lookups during implementation. When working with unfamiliar APIs or dependencies, the Implementer resolves the library ID and queries up-to-date docs rather than relying on training data. This is a prompt-level instruction in the Implementer agent prompt — no infrastructure changes needed.

### Project Readiness Check

During the **research** stage, the lead (or Explorer in Tier L) validates that the target project has:
- `CLAUDE.md` (project-level instructions)
- `AGENTS.md` (agent conventions)

If either is missing, create sensible defaults based on the project's detected framework, language, and structure. This ensures all agents have consistent project context.

### Plan Mode (Tier M/L)

The lead uses **Plan Mode** for the evaluate and plan stages in Tier M/L. Plan Mode provides structured exploration before committing to an approach. Approval is autonomous — the lead decides (optionally checks with teammates for Tier L). Plan Mode is NOT escalated to human; it's a tool for the lead's own planning workflow.

### Custom Skills

**`/ralpr-quality-gate`**: A framework-agnostic quality gate skill that auto-detects project type and runs appropriate test + lint + typecheck commands. Used by the Test Runner teammate. Eliminates hardcoded assumptions about project tooling.

Detection strategy:
- `package.json` → npm/yarn/pnpm test + eslint/biome + tsc
- `Cargo.toml` → cargo test + cargo clippy
- `pyproject.toml` / `setup.py` → pytest + ruff/flake8 + mypy
- `go.mod` → go test + golangci-lint
- Fallback: run any test command found in project config

---

## 17. Multi-Developer Ownership

### Model

- Each developer runs their own orchestrator locally
- Issue assignment via GitHub = distributed lock
- Any orchestrator CAN pick up unassigned issues and PRs (even those created by other devs)
- Once assigned, only that orchestrator works on it (assignment = lock)
- Creator of a PR owns it until merged

### Conflict Prevention

- Git worktrees prevent filesystem collisions
- Docker containers prevent process collisions
- GitHub assignment prevents issue claiming races
- Auto-rebase: orchestrator rebases its assigned PRs when merge conflicts detected

### What's NOT Shared

- No shared database or state files
- No IPC between orchestrators
- No coordination beyond GitHub's own APIs
- Each developer's orchestrator is fully independent

---

## 18. Monorepo Scope Inference

For monorepo projects, agents infer affected packages automatically:

1. **Explorer** analyzes issue description for package/workspace keywords
2. **Explorer** maps monorepo structure (package.json workspaces, directories, build configs)
3. **Cross-reference**: keywords from issue → matching package names
4. **Test scoping**:
   - During development: run tests only for affected packages (faster iteration)
   - Before PR ready: run full test suite (catch cross-package regressions)
5. **Scope annotation**: PR description includes "Affected packages: ..." for human reviewers

---

## 19. Configuration

Environment variables (in `config/ralpr.config.sh` or `.env`):

| Variable | Default | Description |
|----------|---------|-------------|
| `RALPR_MAX_PARALLEL_TEAMS` | `3` | Max concurrent Docker containers |
| `RALPR_ISSUE_POLL_INTERVAL` | `60` | Seconds between issue queue polls |
| `RALPR_PR_POLL_INTERVAL` | `30` | Seconds between PR comment polls |
| `RALPR_AUTO_REBASE` | `true` | Auto-rebase PRs on merge conflicts |
| `RALPR_NOVNC_BASE_PORT` | `6080` | Base port for noVNC viewers (6080, 6081, ...) |
| `RALPR_TEAMMATE_MODE` | `in-process` | Agent Teams mode (in-process avoids tmux nesting) |
| `RALPR_TMUX_SESSION` | `ralpr` | Host tmux session name |
| `RALPR_MODEL` | `opus` | Claude model for all agents |
| `RALPR_TASK_QUALITY_MAX_ITERATIONS` | `3` | Max per-task quality loop iterations before escalation |
| `RALPR_PR_QUALITY_MAX_ITERATIONS` | `3` | Max PR quality loop iterations before escalation |
| `RALPR_BASE_BRANCH` | `main` | Default base branch |
| `RALPR_NOTIFY_MACOS` | `1` | Enable macOS desktop notifications |
| `RALPR_FORCE_TIER` | *(unset)* | Force tier (S/M/L). Unset = lead auto-detects. |
| `RALPR_CONTAINER_HEARTBEAT_TIMEOUT` | `300` | Seconds before container considered unresponsive |
| `RALPR_MAX_RESUME_ATTEMPTS` | `2` | Max crash resumes before escalating to human |
| `RALPR_LEARNING_ENABLED` | `true` | Enable patterns file feedback learning |
| `RALPR_PATTERN_MAX_AGE_DAYS` | `90` | Prune patterns older than this (days) |
| `RALPR_CODEX_MODEL` | `gpt-5.2-codex` | Codex model name for MCP bridge. Circuit breaker activates if unavailable (see Section 5). |
| `RALPR_COST_WARNING` | `25` | Per-issue cost threshold ($) for warning notification |
| `RALPR_COST_HARD_LIMIT` | `100` | Per-issue cost threshold ($) for pipeline pause + human escalation |
| `RALPR_STAGE_MAX_TURNS` | `50` | Default max API turns per teammate per stage (indirect cost control) |

Removed from v3 (now always-on):
- ~~`RALPR_CODEX_ENABLED`~~ → Codex is always required
- ~~`RALPR_DOCKER_MODE`~~ → Docker is always mandatory
- ~~`RALPR_AGENT_TEAMS`~~ → Agent Teams is always enabled
- ~~`RALPR_NOTIFY_GITHUB`~~ → No bot comments on GitHub (removed)

---

## 20. Command Interface

```bash
# Start orchestrator
ralpr start [--max-teams <N>]

# Stop
ralpr stop                         # Graceful: finish current phases, then exit
ralpr stop --force                 # Immediate: kill all containers

# Monitor
ralpr status                       # Show all active teams + queue
ralpr attach                       # Attach to tmux session
ralpr logs <issue-number> [--follow]

# Bug management
ralpr bugs                         # List agent-filed bugs
ralpr bugs triage                  # Show bugs needing human triage

# Maintenance
ralpr cleanup                      # Remove stale worktrees, exited containers
ralpr rebuild                      # Rebuild Docker image
```

---

## 21. Files to Create

### TypeScript Orchestrator (`src/`)

| File | Purpose |
|------|---------|
| `src/orchestrator.ts` | Main entry point, lifecycle management, heartbeat monitoring, crash resume |
| `src/issue-queue.ts` | GitHub issue polling, claiming, assignment, priority selection |
| `src/pr-monitor.ts` | PR comment detection, routing to containers |
| `src/team-spawner.ts` | Docker container + tmux pane creation |
| `src/cost-tracker.ts` | Token/cost aggregation from container output, warning/hard-limit enforcement |
| `src/auto-rebase.ts` | Merge conflict detection and rebase |
| `src/dashboard.ts` | TUI dashboard for tmux pane (includes metrics: completion rate, cost/PR, issues completed, avg time) |
| `src/config.ts` | Configuration loading and validation |
| `src/checkpoint-monitor.ts` | Validates checkpoint stage order, iteration limits, detects skips/violations |
| `src/codex-circuit-breaker.ts` | Codex MCP availability detection, `blocked:codex` queue management, human override flow |
| `src/__tests__/` | Unit tests for orchestrator modules (checkpoint-monitor, codex-circuit-breaker, cost-tracker, issue-queue, config) |
| `package.json` | Node.js project config |
| `tsconfig.json` | TypeScript config |

### Agent Prompts (`agents/`)

New:

| File | Purpose |
|------|---------|
| `agents/team-lead.md` | Team lead (delegate mode coordinator, tier selection, checkpoint writes) |
| `agents/spec-reviewer.md` | Goal verification agent (task-review + spec-review stages) |
| `agents/code-simplifier.md` | Code cleanup agent (simplify stage) |
| `agents/test-runner.md` | Test execution + quality audit agent (test stage) |
| `agents/doc-writer.md` | Documentation agent (docs stage) |

Updated (existing):

| File | Change |
|------|--------|
| `agents/explore-agent.md` | Add requirement extraction (merge understand-agent scope), patterns file reading |
| `agents/implement-agent.md` | Adapt for per-task model + task quality loop (fix stage), patterns file reading |
| `agents/domain-expert.md` → `agents/code-reviewer.md` | Rename, broaden scope (add security, frontend concerns) |
| `agents/codex-reviewer.md` | Update stage references, keep MCP bridge unchanged |

Removed:

| File | Reason |
|------|--------|
| `agents/understand-agent.md` | Merged into explorer (research stage handles both) |
| `agents/qa-reviewer.md` | Replaced by spec-reviewer + code-reviewer split |

### Docker

| File | Change |
|------|--------|
| `Dockerfile` | Add Xvfb, noVNC, Playwright deps, tmux |

### Other

| File | Purpose |
|------|---------|
| `scripts/ralpr` | Simplified CLI (thin wrapper to start/stop orchestrator) |
| `config/ralpr.config.sh` | Updated with new env vars |
| `skills/ralpr-quality-gate/` | Custom skill: framework-agnostic quality gate (auto-detects project type, runs test+lint+typecheck) |

### Files to Delete

| File | Reason |
|------|--------|
| `scripts/ralpr-superloop.sh` | Replaced by TypeScript orchestrator |
| `scripts/ralpr-orchestrator.sh` | Replaced by TypeScript orchestrator |
| `scripts/ralpr-implementation.sh` | Logic moved to team lead + teammates |
| `scripts/ralpr-review.sh` | Logic moved to team lead + teammates |
| `scripts/ralpr-refactor.sh` | Logic moved to team lead + teammates |
| `scripts/lib/confidence.sh` | Replaced by pass/fail model |
| `scripts/lib/ci-watcher.sh` | Replaced by Test Runner teammate |
| `scripts/lib/loop-state.sh` | State moved to GitHub + checkpoint file |

---

## 22. Agent Teams Limitations

Known experimental limitations (as of Claude Code Agent Teams preview):

| # | Limitation | Impact | Mitigation |
|---|-----------|--------|------------|
| 1 | No session resumption | If container crashes, team must restart from scratch | Checkpoint-resume: outer loop reads `.ralpr/checkpoint.json`, respawns with enriched prompt. Max `RALPR_MAX_RESUME_ATTEMPTS` (2) resumes. |
| 2 | Task status lag | Teammates sometimes don't mark tasks complete promptly | Lead monitors via periodic task list checks |
| 3 | Slow shutdown | Teammates finish current API request before stopping | Budget extra time for graceful container shutdown |
| 4 | One team per session | Can't run multiple teams in one container | One container per issue = fine |
| 5 | No nested teams | Teammates can't spawn sub-teams | Flat team structure by design |
| 6 | Fixed lead | Can't transfer lead role mid-session | Lead is always the coordinator; teammates do the work |
| 7 | All teammates inherit permissions | Teammates get lead's `--dangerously-skip-permissions` | Acceptable for Docker-isolated containers. Docker container hardened: no `--privileged`, drop unnecessary Linux capabilities, read-only root FS except `/workspace`. |
| 8 | No split-pane mode inside Docker | Agent Teams split-pane requires host tmux | Use in-process mode (`RALPR_TEAMMATE_MODE=in-process`) |
| 9 | Codex MCP dependency | Pipeline pauses if Codex bridge unavailable | Circuit breaker: issue queued as `blocked:codex`, human notified, can override to single-model review with `codex-skipped` label. Pipeline does NOT deadlock. |
| 10 | Agent Teams experimental | No fallback to non-Agent-Teams mode | Accept the risk — Agent Teams is the path forward. Architecture kept modular for future inner-loop swap. |

---

## 23. Migration Path

Since this is a clean rewrite in the same repo:

### Branch

`feature/v4-agent-teams`

v3 stays on its branch (`feature/v3-super-loop`), v4 on `feature/v4-agent-teams`. They coexist independently.

### Implementation Phases

| Phase | Scope | Deliverables |
|-------|-------|-------------|
| 1 | TypeScript outer loop | `src/orchestrator.ts`, `src/issue-queue.ts`, `src/team-spawner.ts`, `src/checkpoint-monitor.ts`, `src/codex-circuit-breaker.ts`, tmux management, heartbeat + checkpoint-resume |
| 1.5 | Orchestrator tests | Unit tests for orchestrator modules (`src/__tests__/`): checkpoint validation, stage order monitoring, cost tracking, issue queue, Codex circuit breaker. Mock `gh` CLI for integration tests. |
| 2 | Docker image | Updated Dockerfile with Xvfb, noVNC, Playwright, Agent Teams env. Hardened: no `--privileged`, drop capabilities, read-only root FS except `/workspace`. |
| 3 | Agent prompts | `agents/team-lead.md` + teammate prompts (5 new, 4 updated), tier-specific pipeline logic |
| 4 | PR monitor + auto-rebase | `src/pr-monitor.ts`, `src/auto-rebase.ts`, comment routing |
| 5 | Cost tracking + dashboard | `src/cost-tracker.ts`, `src/dashboard.ts`, TUI pane, dashboard metrics |
| 6 | Integration test + dry-run | Full cycle against real repo with 3-5 issues, verify all tiers. Add `ralpr start --dry-run` mode for full pipeline simulation without GitHub side effects. |
| 6+ | Chaos/failure tests (stretch) | Container crash recovery, GitHub API rate limit handling, Codex outage simulation, stale lock detection |

---

## 24. Success Criteria

The rework is complete when:

- [ ] TypeScript orchestrator manages issue queue, containers, and tmux layout
- [ ] Adaptive team sizing works: Tier S (5 teammates), Tier M (5), Tier L (8)
- [ ] Agent Teams team lead coordinates teammates through tier-specific pipeline
- [ ] Multi-model consensus (Claude + Codex) produces reliable review verdicts
- [ ] Codex review runs for every issue in every tier
- [ ] Pipeline does not deadlock on Codex MCP unavailability (circuit breaker queues as `blocked:codex`)
- [ ] Reviewers can challenge each other via direct messaging
- [ ] Frontend changes verified via headed Chromium + Playwright + Claude vision
- [ ] noVNC provides live browser viewing from host
- [ ] Human can type into tmux pane to steer any agent
- [ ] PR comments detected by outer loop and routed to correct container
- [ ] Auto-rebase resolves merge conflicts without human intervention
- [ ] Agents can file bugs for pre-existing issues
- [ ] Smart failure analysis (not blind retries)
- [ ] Cost tracked per-issue, per-stage, displayed in dashboard
- [ ] Auto-scaling: containers spawn/terminate based on queue depth
- [ ] Scale to zero when idle
- [ ] Multiple developers can run independent orchestrators simultaneously
- [ ] Checkpoint-resume recovers from container crash (up to 2 resumes)
- [ ] Patterns file (`.ralpr/patterns.md`) accumulates insights and is read by agents
- [ ] Zero bot comments on PRs — only human comments appear
- [ ] 3+ parallel teams running simultaneously without conflicts
- [ ] Full cycle completes autonomously on a real project
- [ ] macOS + tmux notifications working
- [ ] Cost warning triggers at configurable threshold (`RALPR_COST_WARNING`)
- [ ] Cost hard limit pauses pipeline at configurable threshold (`RALPR_COST_HARD_LIMIT`)
- [ ] Outer loop detects and intervenes on stage order violations (checkpoint monitor)
- [ ] Lead is coordinator-only in ALL tiers (no Tier S exception)
- [ ] Orchestrator has unit test coverage for critical modules (`src/__tests__/`)
- [ ] Target projects validated for CLAUDE.md/AGENTS.md at research stage
- [ ] `ralpr start --dry-run` mode runs full pipeline simulation
