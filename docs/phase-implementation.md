# Phase 1: Implementation

**No confidence scoring. Just implement and ship.**

## Workflow

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

## Cleanup (ALWAYS)
```bash
RALPR_SCRIPTS/ralpr release issue <N>
git worktree remove <path> --force  # if worktree
```
