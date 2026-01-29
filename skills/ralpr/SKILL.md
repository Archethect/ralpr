---
name: ralpr
description: Ralpr - Ralph Autonomous Loop for Pull-request Readiness. Three phases - Implementation → Review → Refactor. Each invocation runs a single iteration.
args: "[--issue <number>] [--pr <number>] [--phase <impl|review|refactor>] [--human-review] [--dry-run]"
---

# Ralpr v2.0

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

## Iteration State

State persists as hidden PR comments with **phase-specific markers**:

- Review: `<!-- RALPR_REVIEW_STATE {...} -->`
- Refactor: `<!-- RALPR_REFACTOR_STATE {...} -->`

### Read State

**Review Phase:**
```bash
# Use grep -oE (extended regex, works on macOS and Linux)
REVIEW_STATE=$(gh pr view <N> --json comments --jq '
  [.comments[] | select(.body | contains("RALPR_REVIEW_STATE")) | .body] | first // empty
' | grep -oE '\{"iteration":[^}]+\}')
[ -z "$REVIEW_STATE" ] && REVIEW_STATE='{"iteration":0,"cumulative_score":0,"confidence":40}'
```

**Refactor Phase:**
```bash
# Use grep -oE (extended regex, works on macOS and Linux)
REFACTOR_STATE=$(gh pr view <N> --json comments --jq '
  [.comments[] | select(.body | contains("RALPR_REFACTOR_STATE")) | .body] | first // empty
' | grep -oE '\{"iteration":[^}]+\}')
[ -z "$REFACTOR_STATE" ] && REFACTOR_STATE='{"iteration":0,"confidence":0}'
```

### Write State (Delete-then-Create)

**Review Phase:**
```bash
# Delete existing review comment
# NOTE: Use REST API to get numeric IDs (gh pr view returns GraphQL node IDs which cause 404)
COMMENT_ID=$(gh api repos/{owner}/{repo}/issues/<N>/comments --jq '
  [.[] | select(.body | contains("RALPR_REVIEW_STATE"))] | first | .id // empty
')
[ -n "$COMMENT_ID" ] && gh api repos/{owner}/{repo}/issues/comments/$COMMENT_ID -X DELETE

# Create new
gh pr comment <N> --body "$REVIEW_BODY"
```

**Refactor Phase (preserves review comment):**
```bash
# Delete existing REFACTOR comment only
# NOTE: Use REST API to get numeric IDs (gh pr view returns GraphQL node IDs which cause 404)
COMMENT_ID=$(gh api repos/{owner}/{repo}/issues/<N>/comments --jq '
  [.[] | select(.body | contains("RALPR_REFACTOR_STATE"))] | first | .id // empty
')
[ -n "$COMMENT_ID" ] && gh api repos/{owner}/{repo}/issues/comments/$COMMENT_ID -X DELETE

# Create new
gh pr comment <N> --body "$REFACTOR_BODY"
```

**Semantics:** Read `iteration: N` → N iterations completed. After completing, write `iteration: N+1`.

### Labels

**Protected Labels:** `ralpr:impl:done` - NEVER remove

**Retention Rules:**
1. Review: Remove only old `ralpr:review:XX` before adding new
2. Refactor: Remove only old `ralpr:refactor:XX` (keep review label)
3. End state: `impl:done` + final `review:XX` + final `refactor:XX`

**Setting Review Confidence:**
```bash
gh pr view <N> --json labels --jq '.labels[].name' | grep "^ralpr:review:[0-9]\+$" | xargs -I{} gh pr edit <N> --remove-label {}
gh pr edit <N> --add-label "ralpr:review:<confidence>"
```

**Setting Refactor Confidence:**
```bash
gh pr view <N> --json labels --jq '.labels[].name' | grep "^ralpr:refactor:[0-9]\+$" | xargs -I{} gh pr edit <N> --remove-label {}
gh pr edit <N> --add-label "ralpr:refactor:<confidence>"
```

### Comment Formats

**Review:**
```markdown
🔄 **Ralpr Review** · 🏁 Iteration {N} · 🎯 {confidence}% · 📈 +{points}pts

| 🔴 High | 🟡 Med | 🟢 Low | ✅ Tests |
|:---:|:---:|:---:|:---:|
| {high} | {med} | {low} | {tests} |

<!-- RALPR_REVIEW_STATE {"iteration":N,"cumulative_score":X,"confidence":Y} -->
```

**Refactor:**
```markdown
✨ **Ralpr Refactor** · 🏁 Iteration {N} · 🎯 {confidence}%

| Skill | Tests | Final |
|:---:|:---:|:---:|
| {skill}% | {tests}% | {confidence}% |

<!-- RALPR_REFACTOR_STATE {"iteration":N,"confidence":Y,"refactor_confidence":Z} -->
```

### End State

PR should have exactly:
- One final review comment (with `RALPR_REVIEW_STATE`)
- One final refactor comment (with `RALPR_REFACTOR_STATE`)

**Icons:** 🔄 Review / ✨ Refactor · 🏁 Iteration · 🎯 Confidence · 📈 Points · 🔴🟡🟢 Severity · ✅ Tests

---

## Phase 1: Implementation

**No confidence scoring. Just implement and ship.**

### Workflow

1. **Setup**: `RALPR_SCRIPTS/ralpr setup` → get `default_branch`, `worktree_base`

2. **Select**: `RALPR_SCRIPTS/ralpr select [--issue <N>]`

3. **Claim**: `RALPR_SCRIPTS/ralpr claim issue <N>`

4. **Branch**: `RALPR_SCRIPTS/ralpr branch --issue <N>` → creates worktree, cd to it, install dependencies

5. **Explore** (in worktree):
   ```
   Task(subagent_type="ralpr:explore-agent",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "full", "working_dir": "<worktree>"}')
   ```
   → store `map_path`

6. **Understand**:
   ```
   Task(subagent_type="ralpr:understand-agent",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "issue", "issue_number": <N>, "repo": "<owner>/<repo>", "map_path": "<path>"}')
   ```
   → store requirements

7. **Implement**:
   ```
   Task(subagent_type="ralpr:implement-agent",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"issue_number": <N>, "branch": "<branch>", "requirements": <understand_output>, "map_path": "<path>", "working_dir": "<worktree>"}',
        max_turns=100)
   ```

8. **Quality Gates**: Run tests, lint, and typecheck (use project's package manager)

9. **Create PR**: `RALPR_SCRIPTS/ralpr pr create --issue <N> --title "..." --body "..."`

10. **CI Gate**: `RALPR_SCRIPTS/ralpr ci wait` (exit 0: ok, exit 1: fix & retry, exit 3: skip)

11. **Finalize**: `gh pr edit --add-label ralpr:impl:done`

### Cleanup (ALWAYS)
```bash
RALPR_SCRIPTS/ralpr release issue <N>
git worktree remove <path> --force  # if worktree
```

---

## Phase 2: Review

**Target: 85% confidence. Cumulative model: each iteration adds 5-15 points (with diminishing returns).**

Do NOT fetch PR files via GitHub API - agents read local files.

### Workflow

1. **Setup**: `RALPR_SCRIPTS/ralpr setup` → get `default_branch`, `worktree_base`

2. **Claim PR**: `RALPR_SCRIPTS/ralpr claim pr <N>`

3. **Setup Worktree**: `RALPR_SCRIPTS/ralpr review --pr <N>`
   → returns `{"status":"ready","phase":"review","pr_number":N,"branch":"...","worktree_path":"...","working_dir":"..."}`
   → **cd to `working_dir` before continuing**

4. **Explore** (in worktree):
   ```
   Task(subagent_type="ralpr:explore-agent",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "full", "working_dir": "<working_dir>"}')
   ```
   → store `map_path`

5. **Read State** → store as `state` (see [Iteration State](#iteration-state))

6. **Understand** (blocking):
   ```
   Task(subagent_type="ralpr:understand-agent",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "pr", "pr_number": <N>, "repo": "<owner>/<repo>", "map_path": "<path>"}')
   ```
   → store as `understand_output`

7. **Review** (3 agents IN PARALLEL):
   ```
   Task(subagent_type="ralpr:qa-reviewer",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": <N>, "branch": "...", "base_branch": "...", "working_dir": "...", "map_path": "...", "context": <understand_output>, "focus_areas": <understand_output.focus_areas.qa>}')

   Task(subagent_type="ralpr:domain-expert",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": <N>, "branch": "...", "base_branch": "...", "working_dir": "...", "map_path": "...", "context": <understand_output>, "focus_areas": <understand_output.focus_areas.domain>}')

   Task(subagent_type="ralpr:codex-reviewer",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": <N>, "branch": "...", "base_branch": "...", "repo": "<owner>/<repo>", "context": <understand_output>, "focus_areas": <understand_output.focus_areas.codex>}')
   ```
   - QA/Domain read LOCAL files; Codex uses `gh pr diff`

8. **Aggregate**: Dedupe by file:line → `issues_this_iteration`, `current_severity = {high: N, medium: N, low: N}`

9. **Analyze**: Decide yes/no on each suggestion

10. **Fix**: Implement fixes → track `issues_fixed_this_iteration`

11. **Quality Gates**: Run tests, lint, and typecheck (use project's package manager)

12. **Push + CI**: Commit, push, `RALPR_SCRIPTS/ralpr ci wait`

13. **Calculate Confidence** (Cumulative Additive Model):
    ```python
    # Each iteration earns 5-15 points based on quality
    iteration_points = 5  # base: completed iteration

    if tests_pass:
        iteration_points += 4

    if current_severity.high == 0:
        iteration_points += 3
    elif current_severity.high <= 1:
        iteration_points += 1

    if all_approved:
        iteration_points += 3
    elif approvals >= 2:
        iteration_points += 1

    # Diminishing returns: later iterations worth less
    multiplier = max(0.5, 1.0 - (state.iteration * 0.1))
    points_earned = iteration_points * multiplier

    # Confidence = base + cumulative points (monotonically increasing)
    new_cumulative = state.cumulative_score + points_earned
    confidence = min(100, int(40 + new_cumulative))
    ```

14. **Set Label**: See [Labels](#labels)

15. **Write State**:
    ```python
    new_state = {
        "phase": "review",
        "iteration": state.iteration + 1,
        "cumulative_score": new_cumulative,
        "confidence": confidence
    }
    ```

16. **Write Comment**: See [Comment Formats](#comment-formats)

### Output
```json
{"iteration": 2, "points_earned": 11.7, "cumulative_score": 25.7, "confidence": 65, "label_set": "ralpr:review:65"}
```

### Cleanup (ALWAYS)
```bash
RALPR_SCRIPTS/ralpr release pr <N>
git worktree remove <path> --force  # if worktree
```

---

## Phase 3: Refactor

**Target: 85% confidence.**

Do NOT fetch PR files via GitHub API - agents read local files.

### Workflow

1. **Setup**: `RALPR_SCRIPTS/ralpr setup` → get `default_branch`, `worktree_base`

2. **Claim PR**: `RALPR_SCRIPTS/ralpr claim pr <N>`

3. **Setup Worktree**: `RALPR_SCRIPTS/ralpr refactor --pr <N>`
   → returns `{"status":"ready","phase":"refactor","pr_number":N,"branch":"...","worktree_path":"...","working_dir":"..."}`
   → **cd to `working_dir` before continuing**

4. **Explore** (in worktree):
   ```
   Task(subagent_type="ralpr:explore-agent",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "full", "working_dir": "<working_dir>"}')
   ```
   → store `map_path`

5. **Read State** → store as `state` (see [Iteration State](#iteration-state))

6. **Understand**:
   ```
   Task(subagent_type="ralpr:understand-agent",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "pr", "pr_number": <N>, "repo": "<owner>/<repo>", "map_path": "<path>"}')
   ```

7. **Refactor**:
   ```
   Task(subagent_type="pr-review-toolkit:code-simplifier",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "pr", "pr_number": <N>, "repo": "<owner>/<repo>", "map_path": "<path>"}')
   ```

8. **Get Confidence**: Ask agent for score (0-100) → `skill_confidence`

9. **Quality Gates**: Run tests, lint, and typecheck (use project's package manager)

10. **Push + CI**: Commit, push, `RALPR_SCRIPTS/ralpr ci wait`

11. **Calculate Confidence**:
    ```python
    test_stability = 1.0 if tests_pass else 0.0
    confidence = int(100 * (skill_confidence/100 * 0.70 + test_stability * 0.30))
    ```

12. **Set Label**: See [Labels](#labels)

13. **Write State**:
    ```python
    is_first_refactor = (state.phase != "refactor")
    new_state = {
        "phase": "refactor",
        "iteration": 0 if is_first_refactor else state.iteration + 1,
        "cumulative_score": state.cumulative_score,
        "confidence": confidence,
        "refactor_confidence": skill_confidence
    }
    ```

14. **Write Comment**: See [Comment Formats](#comment-formats)

### Output
```json
{"iteration": 1, "skill_confidence": 95, "confidence": 96, "label_set": "ralpr:refactor:96"}
```

### Cleanup (ALWAYS)
```bash
RALPR_SCRIPTS/ralpr release pr <N>
git worktree remove <path> --force  # if worktree
```

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

---

## CLI Reference

```bash
# Phases
RALPR_SCRIPTS/ralpr implementation --issue 123
RALPR_SCRIPTS/ralpr review --pr 456
RALPR_SCRIPTS/ralpr refactor --pr 456

# Utilities
RALPR_SCRIPTS/ralpr setup
RALPR_SCRIPTS/ralpr select [--issue N]
RALPR_SCRIPTS/ralpr claim <issue|pr> <number>
RALPR_SCRIPTS/ralpr branch --issue N
RALPR_SCRIPTS/ralpr ci <wait|logs|status>
RALPR_SCRIPTS/ralpr pr <create|verify>
RALPR_SCRIPTS/ralpr release <issue|pr> <number>
```
