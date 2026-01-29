# Phase 2: Review

**Target: 90% confidence. Cumulative model: each iteration adds 5-15 points (with diminishing returns).**

Do NOT fetch PR files via GitHub API - agents read local files.

## Workflow

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

5. **Read State** → store as `state` (see @iteration-state.md)

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

14. **Set Label**: See @comment-formats.md

15. **Write State**:
    ```python
    new_state = {
        "phase": "review",
        "iteration": state.iteration + 1,
        "cumulative_score": new_cumulative,
        "confidence": confidence
    }
    ```

16. **Write Comment**: See @comment-formats.md

## Output
```json
{"iteration": 2, "points_earned": 11.7, "cumulative_score": 25.7, "confidence": 65, "label_set": "ralpr:review:65"}
```

## Cleanup (ALWAYS)
```bash
RALPR_SCRIPTS/ralpr release pr <N>
git worktree remove <path> --force  # if worktree
```
