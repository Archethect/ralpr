# Phase 3: Refactor

**Target: 95% confidence.**

Do NOT fetch PR files via GitHub API - agents read local files.

## Workflow

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

5. **Read State** → store as `state` (see @iteration-state.md)

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

12. **Set Label**: See @comment-formats.md

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

14. **Write Comment**: See @comment-formats.md

## Output
```json
{"iteration": 1, "skill_confidence": 95, "confidence": 96, "label_set": "ralpr:refactor:96"}
```

## Cleanup (ALWAYS)
```bash
RALPR_SCRIPTS/ralpr release pr <N>
git worktree remove <path> --force  # if worktree
```
