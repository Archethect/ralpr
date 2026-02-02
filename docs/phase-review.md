# Phase 2: Review

**Target: 90% confidence. Cumulative model: each iteration adds 5-15 points (with diminishing returns).**

Do NOT fetch PR files via GitHub API - agents read local files.

## Workflow

1. **Setup**: `RALPR_SCRIPTS/ralpr setup` → get `default_branch`, `worktree_base`

2. **Select**: `RALPR_SCRIPTS/ralpr select --phase review` (or use provided `--pr N`)

3. **Claim PR**: `RALPR_SCRIPTS/ralpr claim pr <N>`

4. **Setup Worktree**: `RALPR_SCRIPTS/ralpr review --pr <N>`
   → returns `{"status":"ready","phase":"review","pr_number":N,"branch":"...","worktree_path":"...","working_dir":"..."}`
   → **cd to `working_dir` before continuing**

5. **Explore** (in worktree):
   ```
   Task(subagent_type="ralpr:explore-agent",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "full", "working_dir": "<working_dir>"}')
   ```
   → store `map_path`

6. **Read State** → store as `state` (see @iteration-state.md)

7. **Understand** (blocking):
   ```
   Task(subagent_type="ralpr:understand-agent",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "pr", "pr_number": <N>, "repo": "<owner>/<repo>", "map_path": "<path>"}')
   ```
   → store as `understand_output`

8. **Review** (3 agents IN PARALLEL):
   ```
   Task(subagent_type="ralpr:qa-reviewer",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": <N>, "branch": "...", "base_branch": "...", "working_dir": "...", "map_path": "...", "context": <understand_output>, "focus_areas": <understand_output.focus_areas.qa>}')

   Task(subagent_type="ralpr:domain-expert",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": <N>, "branch": "...", "base_branch": "...", "working_dir": "...", "map_path": "...", "context": <understand_output>, "focus_areas": <understand_output.focus_areas.domain>}')

   Task(subagent_type="ralpr:codex-reviewer",
        prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": <N>, "branch": "...", "base_branch": "...", "repo": "<owner>/<repo>", "context": <understand_output>, "focus_areas": <understand_output.focus_areas.codex>}')
   ```
    - QA/Domain read LOCAL files; Codex uses `gh pr diff`

9. **Aggregate**: Dedupe by file:line → `issues_this_iteration`, `current_severity = {high: N, medium: N, low: N}`

10. **Discuss**: Have a discussion with ALL reviewers (including yourself) and ask if the issue needs to be fixed.

11. **Decide (Fix-by-Default)**:

    The default action for every issue is **FIX**. Skipping requires structured justification.

    **Severity rules:**
    - **CRITICAL/HIGH**: MUST fix. No skip without explicit user approval.
    - **MEDIUM with >= 2 reviewers agreeing**: MUST fix unless there is a concrete technical reason (not a deferral).
    - **MEDIUM with 1 reviewer**: Fix unless it would break an explicit acceptance criterion.
    - **LOW**: Fix at your discretion, but log reasoning for skips.

    **Prohibited skip reasons** (using any of these is grounds for re-evaluation):
    - "Design decision for a future ticket"
    - "Acceptable for a skeleton/initial PR"
    - "Beyond the scope of this ticket"
    - Any deferral variant that does not cite a specific acceptance criterion conflict

    **Scope-relevance check:** If the issue falls within the CATEGORY of work the PR is doing, it is in scope. A fix is only out of scope if it requires changes to a system or component the PR does not touch.

    **Overrule as obligation:** You are the FINAL reviewer. When you see a concrete improvement to code quality, correctness, or safety — implement it. Not doing so requires justification equivalent to a SKIP.

    If a required fix seems impossible (e.g., missing test infrastructure, out-of-scope dependency), **STOP and ask the user**. Do NOT skip or rationalize. If the user approves skipping, document the skip reason in the review comment.

    **Step 11b — Decision Log** (REQUIRED before proceeding to Fix step):

    Produce a structured table for ALL issues:

    ```
    | ID | Severity | Reviewers | Action | Justification | AC Conflict? |
    |----|----------|-----------|--------|---------------|--------------|
    | 1  | HIGH     | QA, Domain | FIX   | —             | —            |
    | 2  | MEDIUM   | QA, Codex  | FIX   | —             | —            |
    | 3  | LOW      | Domain     | SKIP  | Cosmetic only, no behavioral impact | No |
    ```

    - FIX needs no justification (it is the default).
    - SKIP requires a reason that is NOT on the prohibited list above.
    - **Circuit breaker:** If > 50% of MEDIUM+ issues are marked SKIP, STOP and re-evaluate. You are likely being lazy.

12. **Fix**: Implement fixes → track `issues_fixed_this_iteration`

13. **Quality Gates**: Run tests, lint, and typecheck (use project's package manager)

14. **Push + CI**: Commit, push, `RALPR_SCRIPTS/ralpr ci wait`

15. **Calculate Confidence** (Cumulative Additive Model):
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

16. **Set Label**: See @comment-formats.md

17. **Write State**:
    ```python
    new_state = {
        "phase": "review",
        "iteration": state.iteration + 1,
        "cumulative_score": new_cumulative,
        "confidence": confidence
    }
    ```

18. **Write Comment**: See @comment-formats.md

## Output
```json
{"iteration": 2, "points_earned": 11.7, "cumulative_score": 25.7, "confidence": 65, "label_set": "ralpr:review:65"}
```

## Cleanup (ALWAYS)
```bash
RALPR_SCRIPTS/ralpr release pr <N>
git worktree remove <path> --force  # if worktree
```
