# Ralpr v3.0 Specification: Super Loop

> Continuous autonomous development with parallel loop orchestration and tmux monitoring.

---

## 1. Overview

Ralpr v3.0 adds a **Super Loop** system that continuously runs the full `impl -> review -> refactor` pipeline for GitHub issues. Multiple loops can run in parallel, each in its own tmux pane with full Claude output visibility. Every phase runs in a fresh Docker-isolated Claude session to prevent context drift and hallucination.

### Core Principles

- **Single issue end-to-end**: Each loop cycle takes one issue through all 3 phases before picking the next.
- **Hard context reset**: Every phase spawns a fresh `claude-docker` session. No accumulated context across phases.
- **Full output fidelity**: Each tmux pane shows the full interactive Claude session output — spinners, colors, agent progress, everything.
- **GitHub as source of truth**: Phase transitions are detected via GitHub labels and PR metadata, not by parsing Claude output.
- **Docker always**: Every Claude session runs inside a Docker container via `claude-docker`.

---

## 2. Architecture

```
Host Terminal
    |
    v
ralpr loop start [--issue N] [--max-cycles M]
    |
    v
tmux session: "ralpr-loops"
    |
    +-- Pane 1: loop-1 orchestrator (bash)
    |     |
    |     +-- Cycle 1:
    |     |     +-- claude-docker: /ralpr --phase impl --issue 42
    |     |     +-- claude-docker: /ralpr --phase review --pr 87
    |     |     +-- claude-docker: /ralpr --phase review --pr 87   (iteration 2)
    |     |     +-- claude-docker: /ralpr --phase refactor --pr 87
    |     |
    |     +-- Cycle 2:
    |           +-- claude-docker: /ralpr --phase impl (auto-select)
    |           +-- ...
    |
    +-- Pane 2: loop-2 orchestrator (bash)
    |     +-- ...
    |
    +-- Pane 3: loop-3 orchestrator (bash)
          +-- ...
```

### Components

| Component | Location | Runs On | Purpose |
|-----------|----------|---------|---------|
| `ralpr loop` subcommand | Plugin script (symlinked to PATH) | Host | CLI for loop management |
| `ralpr-superloop.sh` | `scripts/ralpr-superloop.sh` | Host (in tmux pane) | Per-loop orchestrator |
| `claude-docker` | `~/.claude-host/docker/claude-docker` | Host | Spawns isolated Claude sessions |
| `ralpr` skill (existing) | Plugin cache (inside Docker) | Docker container | Single-phase execution |
| tmux session | System | Host | Pane layout and monitoring |

---

## 3. Command Interface

All commands are subcommands of the existing `ralpr` CLI. They are host-side only (not callable from within a Claude session).

### 3.1 `ralpr loop start`

Start a new loop in a tmux pane.

```
ralpr loop start [--issue <N>] [--max-cycles <N>]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--issue <N>` | Auto-select | Specific issue to start with. Subsequent cycles auto-select. |
| `--max-cycles <N>` | 0 (infinite) | Max impl->review->refactor cycles. 0 = run until stopped. |

**Behavior:**
1. Check tmux is installed; error if not.
2. Create or reuse tmux session named `ralpr-loops`.
3. Assign loop ID: auto-increment (loop-1, loop-2, ...). Tracked in `.ralpr/loops/registry.json`.
4. Create a new tmux pane in the `ralpr-loops` window.
5. Rebalance layout using `tmux select-layout tiled`.
6. Start `ralpr-superloop.sh` in the new pane with appropriate arguments.
7. Print: `Loop loop-<N> started. Use 'ralpr loop attach' to monitor.`

### 3.2 `ralpr loop stop`

Gracefully or forcefully stop a loop.

```
ralpr loop stop <loop-id> [--force]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--force` | false | Immediately kill the Docker container and orchestrator. |

**Graceful (default):** Write a stop signal file (`.ralpr/loops/loop-<id>/stop`). The orchestrator checks for this between phases and exits cleanly after the current phase completes. Release any assignments.

**Force (`--force`):** Kill the Docker container (`docker kill`), kill the orchestrator process, release assignments, clean up worktree.

### 3.3 `ralpr loop status`

Show status of all loops.

```
ralpr loop status
```

**Output:** Minimal table format.

```
ID      | Issue/PR  | Phase      | Cycle | Status
--------|-----------|------------|-------|--------
loop-1  | #42/PR#87 | review:3   | 1/5   | running
loop-2  | #15/PR#90 | refactor:1 | 2/0   | running
loop-3  | —         | —          | 3/3   | done
loop-4  | #28       | impl       | 1/0   | failed
```

**Data source:** Each orchestrator writes state to `.ralpr/loops/loop-<id>/state.json`:
```json
{
  "id": "loop-1",
  "pid": 12345,
  "issue": 42,
  "pr": 87,
  "phase": "review",
  "phase_iteration": 3,
  "cycle": 1,
  "max_cycles": 5,
  "status": "running",
  "started_at": "2026-02-03T10:15:00Z",
  "last_activity": "2026-02-03T10:45:00Z"
}
```

### 3.4 `ralpr loop attach`

Attach to the tmux monitoring session.

```
ralpr loop attach
```

**Behavior:**
- If already inside tmux: `tmux switch-client -t ralpr-loops`.
- If not in tmux: `tmux attach-session -t ralpr-loops`.
- Detach with standard `Ctrl-B D`.

### 3.5 `ralpr loop logs`

View or tail logs for a specific loop.

```
ralpr loop logs <loop-id> [--follow]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--follow` | false | Tail the log file (like `tail -f`). |

**Log location:** `.ralpr/logs/loop-<id>/cycle-<N>/<phase>.log`

Without `--follow`: cat the most recent log file.
With `--follow`: tail -f the active log file for the running loop.

### 3.6 `ralpr loop list`

Alias for `ralpr loop status`.

---

## 4. Super Loop Orchestrator (`ralpr-superloop.sh`)

The per-loop bash script that runs inside each tmux pane.

### 4.1 Lifecycle

```
START
  |
  v
[Check prerequisites: docker, gh auth, git clean]
  |
  v
[Initialize state file: .ralpr/loops/loop-<id>/state.json]
  |
  v
+---> [Check stop signal: .ralpr/loops/loop-<id>/stop]
|       |
|       +-- If exists: cleanup & EXIT
|       |
|       v
|     [Check max_cycles: if cycle > max_cycles and max_cycles > 0: EXIT]
|       |
|       v
|     === PHASE 1: IMPLEMENTATION ===
|     [Clean stale worktrees for this loop]
|     [Select issue (--issue N or auto-select with claim-verify)]
|     [Update state.json: phase=impl, issue=N]
|     [Spawn: claude-docker -p '/ralpr --phase impl --issue N']
|     [Wait for container exit]
|     [Poll GitHub: find PR with ralpr:impl:done for issue N (60s, every 10s)]
|     [If not found: retry phase once, then FAIL]
|     [Update state.json: pr=M]
|       |
|       v
|     [Check stop signal]
|       |
|       v
|     === PHASE 2: REVIEW (iterative) ===
|     [Update state.json: phase=review, phase_iteration=1]
|     [Spawn: claude-docker -p '/ralpr --phase review --pr M']
|     [Wait for container exit]
|     [Check GitHub label: ralpr:review:XX]
|     [If XX >= REVIEW_THRESHOLD: proceed to refactor]
|     [If XX < REVIEW_THRESHOLD: increment iteration, respawn]
|     [If max review iterations reached: FAIL]
|       |
|       v
|     [Check stop signal]
|       |
|       v
|     === PHASE 3: REFACTOR (iterative) ===
|     [Update state.json: phase=refactor, phase_iteration=1]
|     [Spawn: claude-docker -p '/ralpr --phase refactor --pr M']
|     [Wait for container exit]
|     [Check GitHub label: ralpr:refactor:XX]
|     [If XX >= REFACTOR_THRESHOLD: cycle complete]
|     [If XX < REFACTOR_THRESHOLD: increment iteration, respawn]
|     [If max refactor iterations reached: FAIL]
|       |
|       v
|     [Cycle complete. Increment cycle counter.]
|     [Print cycle summary.]
+-----[Loop back to top]
  |
  v
[All cycles done OR stopped]
[Print completion summary]
[Keep shell alive: exec bash]
```

### 4.2 Issue Selection with Race Condition Prevention

When auto-selecting issues (no `--issue` flag), use GitHub assignment as a distributed lock:

```bash
# 1. Find candidate issue (unassigned, open, matching criteria)
ISSUE=$(gh issue list --state open --assignee "" --label "status:backlog" --limit 1 --json number -q '.[0].number')

# 2. Attempt to claim (assign to self)
gh issue edit "$ISSUE" --add-assignee "@me"

# 3. Verify claim succeeded (re-check assignee)
ASSIGNEE=$(gh issue view "$ISSUE" --json assignees -q '.assignees[0].login')
MY_LOGIN=$(gh api user -q '.login')

if [[ "$ASSIGNEE" != "$MY_LOGIN" ]]; then
  # Race lost - someone else claimed it between step 1 and 2
  # Release our assignment attempt and try next issue
  gh issue edit "$ISSUE" --remove-assignee "@me"
  # Retry with next candidate
fi
```

This pattern uses GitHub's own assignment state as the distributed lock, working across machines.

### 4.3 Phase Handoff via GitHub Labels

After each phase's Docker container exits, the orchestrator checks GitHub for completion signals:

| After Phase | Check | Query |
|-------------|-------|-------|
| Implementation | PR exists with `ralpr:impl:done` label closing the issue | `issue-closing-prs.graphql` + label check |
| Review | PR has `ralpr:review:XX` label where XX >= REVIEW_THRESHOLD | `gh pr view --json labels` |
| Refactor | PR has `ralpr:refactor:XX` label where XX >= REFACTOR_THRESHOLD | `gh pr view --json labels` |

**Polling:** Every 10s for up to 60s. If the expected label is not found after 60s, the phase is considered failed.

### 4.4 Failure Handling

| Failure | Action |
|---------|--------|
| Phase fails (container exits non-zero, label not found) | Retry the phase ONCE with a fresh Claude session. If retry fails, mark loop as `failed`. |
| Docker container crash | Detect via exit code. Clean stale worktree. Retry once. |
| Stale worktrees | Auto-cleanup before each phase: `git worktree list` → remove any matching this loop's pattern. |
| Stop signal received | Finish current phase, then exit cleanly. Release all assignments. |
| GitHub API errors | Retry with exponential backoff (3 attempts). If persistent, mark loop as `failed`. |

On any failure that halts the loop:
- Release issue/PR assignment.
- Update state.json: `status: "failed"`.
- Print error summary.
- Keep shell alive (`exec bash`) so the pane stays open for inspection.

### 4.5 Logging

All output (stdout + stderr) from each Claude session is tee'd to log files:

```
.ralpr/
  logs/
    loop-1/
      cycle-1/
        impl.log
        review-iter-1.log
        review-iter-2.log
        refactor-iter-1.log
      cycle-2/
        impl.log
        ...
    loop-2/
      ...
```

The tmux pane shows the live output. Logs are written simultaneously for post-mortem access.

Add `.ralpr/logs/` to `.gitignore`.

### 4.6 Completion Summary

When a loop finishes (all cycles done or stopped), print:

```
╔══════════════════════════════════════════╗
║          LOOP loop-1 COMPLETE            ║
╠══════════════════════════════════════════╣
║ Cycles completed: 3/3                    ║
║                                          ║
║ Cycle 1: Issue #42 → PR #87 (merged)    ║
║   impl: done | review: 92% | refactor: 96%
║                                          ║
║ Cycle 2: Issue #15 → PR #90 (merged)    ║
║   impl: done | review: 88% | refactor: 95%
║                                          ║
║ Cycle 3: Issue #28 → PR #95 (merged)    ║
║   impl: done | review: 91% | refactor: 97%
║                                          ║
║ Logs: .ralpr/logs/loop-1/               ║
╚══════════════════════════════════════════╝
```

---

## 5. tmux Session Management

### 5.1 Session Structure

- **Session name:** `ralpr-loops`
- **Single window** with grid panes (all loops visible simultaneously).
- **Layout:** `tiled` (auto-arranged grid). Rebalances when panes are added.
- **Pane titles:** `loop-<id>: <status>` (e.g., `loop-1: impl #42`)

### 5.2 Pane Lifecycle

1. **Created** by `ralpr loop start` → `tmux split-window` + `tmux select-layout tiled`.
2. **Active** while orchestrator runs. Pane title updated by orchestrator via `tmux select-pane -T "..."`.
3. **Completed/Failed** → orchestrator prints summary, then `exec bash` keeps pane alive.
4. **Closed** manually by user (`Ctrl-B X` or `exit` in the pane shell).

### 5.3 First Loop Bootstrap

When `ralpr loop start` is called and no `ralpr-loops` session exists:

1. Create new tmux session: `tmux new-session -d -s ralpr-loops -n loops`.
2. Start the orchestrator in the initial pane.
3. Print attach instructions.

Subsequent loops use `tmux split-window -t ralpr-loops:loops`.

---

## 6. Docker Integration

### 6.1 Claude Session Spawning

Each phase spawns a Claude session via:

```bash
claude-docker --no-tty -p "/ralpr --phase <phase> --<issue|pr> <N>"
```

**Key flags:**
- `--no-tty`: Required because the tmux pane already provides the PTY. Prevents double-TTY issues.
- `-p`: Initial prompt flag (passed through to `claude` CLI as the first user message).

**Note:** The `claude-docker` script passes `--dangerously-skip-permissions --model opus` by default. The orchestrator does NOT add these — they're handled by `claude-docker`.

### 6.2 Plugin Availability

The ralpr plugin is available inside Docker containers because:
- `claude-docker` mounts `~/.claude` as `/home/claude/.claude-host`.
- The Docker entrypoint (or Claude's startup) copies/links plugins from `.claude-host`.
- The session-start hook injects the ralpr skill into the Claude session.
- No additional mounts or configuration needed.

### 6.3 Container Naming

Each Docker container gets a unique name to prevent conflicts:

```bash
# In claude-docker, the existing pattern is: claude-session-$$
# For super-loop, the orchestrator will set a container name via env var:
CLAUDE_DOCKER_NAME="ralpr-loop-${LOOP_ID}-${PHASE}-${ITERATION}"
```

The orchestrator can use `docker kill <name>` for force-stop.

**Note:** This requires a small modification to `claude-docker` to accept `CLAUDE_DOCKER_NAME` env var for container naming. Currently it uses `claude-session-$$`.

---

## 7. State Management

### 7.1 Local State Files

```
.ralpr/
  loops/
    registry.json          # Loop registry (IDs, PIDs, creation times)
    loop-1/
      state.json           # Current loop state (updated by orchestrator)
      stop                 # Stop signal file (created by 'ralpr loop stop')
    loop-2/
      state.json
      ...
```

**registry.json:**
```json
{
  "next_id": 4,
  "loops": {
    "loop-1": {"pid": 12345, "tmux_pane": "%3", "created_at": "..."},
    "loop-2": {"pid": 12346, "tmux_pane": "%4", "created_at": "..."},
    "loop-3": {"pid": 12347, "tmux_pane": "%5", "created_at": "..."}
  }
}
```

### 7.2 GitHub State (Unchanged from v2.1)

PR comments with `RALPR_REVIEW_STATE` and `RALPR_REFACTOR_STATE` markers remain the canonical state for phase confidence and iteration tracking. The super-loop reads these labels but does NOT write to them — that's the Claude session's job.

---

## 8. Installation & Setup

### 8.1 Prerequisites

- `tmux` installed and in PATH.
- `docker` installed and running.
- `claude-docker` image built (`claude-docker --rebuild`).
- `gh` CLI authenticated.
- Ralpr plugin v3.0 installed.

### 8.2 PATH Setup

The `ralpr` CLI needs to be callable from any terminal. Add to shell profile:

```bash
# Add to ~/.bashrc or ~/.zshrc:
export PATH="$HOME/.claude/plugins/cache/local/ralpr/3.0.0/scripts:$PATH"
```

Or create a symlink:

```bash
ln -sf "$HOME/.claude/plugins/cache/local/ralpr/3.0.0/scripts/ralpr" "$HOME/.local/bin/ralpr"
```

The plugin's README will document both approaches with copy-paste commands.

### 8.3 Quick Start

```bash
# 1. Install/update the plugin (via Claude Code plugin manager)
# 2. Add ralpr to PATH (see above)
# 3. Verify setup
ralpr loop start --issue 42 --max-cycles 1

# 4. Monitor
ralpr loop attach

# 5. Check status (from another terminal)
ralpr loop status

# 6. Start more loops
ralpr loop start --issue 15
ralpr loop start                    # auto-selects issue

# 7. View logs
ralpr loop logs loop-1

# 8. Stop a loop
ralpr loop stop loop-2
ralpr loop stop loop-3 --force      # immediate kill
```

---

## 9. Configuration

New environment variables (added to `config/ralpr.config.sh`):

| Variable | Default | Description |
|----------|---------|-------------|
| `RALPR_TMUX_SESSION` | `ralpr-loops` | tmux session name |
| `RALPR_LOOP_MAX_CYCLES` | `0` | Default max cycles (0 = infinite) |
| `RALPR_LOOP_LOG_DIR` | `.ralpr/logs` | Log directory |
| `RALPR_LOOP_STATE_DIR` | `.ralpr/loops` | Loop state directory |
| `RALPR_DOCKER_CMD` | `claude-docker` | Docker wrapper command |
| `RALPR_LABEL_POLL_INTERVAL` | `10` | Seconds between GitHub label polls |
| `RALPR_LABEL_POLL_TIMEOUT` | `60` | Max seconds to poll for labels |

Existing variables unchanged:
- `REVIEW_THRESHOLD`, `REVIEW_MAX_LOOPS`, `REFACTOR_THRESHOLD`, `REFACTOR_MAX_LOOPS`
- `RALPR_BASE_BRANCH`, `RALPR_DEBUG`

---

## 10. Backwards Compatibility

| Feature | v2.1 | v3.0 |
|---------|------|------|
| `/ralpr --phase impl` (single phase) | Supported | Unchanged |
| `/ralpr --phase review --pr N` | Supported | Unchanged |
| `/ralpr --phase refactor --pr N` | Supported | Unchanged |
| `ralpr-orchestrator.sh` | Supported | Deprecated (superseded by super-loop) |
| `ralpr loop start` | N/A | New |
| `ralpr loop stop/status/attach/logs` | N/A | New |

The single-phase `/ralpr` skill inside Claude sessions remains identical. The super-loop is a host-side orchestration layer on top.

---

## 11. Files to Create/Modify

### New Files

| File | Purpose |
|------|---------|
| `scripts/ralpr-superloop.sh` | Per-loop orchestrator (runs in tmux pane) |
| `scripts/lib/tmux.sh` | tmux session/pane management helpers |
| `scripts/lib/loop-state.sh` | Loop registry and state file helpers |
| `docs/spec-v3-super-loop.md` | This spec |
| `docs/loop-usage.md` | User-facing loop documentation |

### Modified Files

| File | Change |
|------|--------|
| `scripts/ralpr` | Add `loop` subcommand routing (start/stop/status/attach/logs/list) |
| `config/ralpr.config.sh` | Add new env vars for loop configuration |
| `.claude-plugin/plugin.json` | Bump version to 3.0.0 |
| `README.md` | Add super-loop section with installation & usage docs |

### Unchanged Files

All existing phase scripts, agent definitions, library scripts, hooks, schemas, and templates remain untouched. The super-loop operates as a layer above the existing system.

---

## 12. Non-Goals (Explicitly Out of Scope)

- Web dashboard or GUI monitoring.
- Automatic merging of completed PRs.
- Cross-repository loop orchestration.
- Notification system (Slack, email, etc.).
- Log rotation or compression.
- Cost tracking or token usage reporting.
- Model selection per phase (always uses claude-docker's default: opus).
