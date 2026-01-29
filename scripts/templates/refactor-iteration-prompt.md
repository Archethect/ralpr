Ralpr Refactor Phase - Iteration {{ITERATION}} for PR #{{PR_NUMBER}}

You are running Ralpr Refactor Phase iteration {{ITERATION}}.

## Context
- PR: {{PR_NUMBER}}
- Repository: {{OWNER_REPO}}
- Base branch: {{BASE_BRANCH}}
- Working directory: {{WORKING_DIR}}
- This is a FRESH session - previous context is not available

## Your Tasks

1. **Understand the PR** - Spawn understand-agent:
   ```
   Task(
     subagent_type="ralpr:understand-agent",
     prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"mode": "pr", "pr_number": {{PR_NUMBER}}, "repo": "{{OWNER_REPO}}", "map_path": "docs/.codebase-map.json"}',
     description="Analyze PR for refactoring"
   )
   ```

2. **Invoke the refactor skill**:
   ```
   Skill(skill="superpowers:refactor")
   ```

3. **Get skill confidence** - The refactor skill should report its confidence level (0-100)

4. **Run quality gates**:
   - npm test
   - npm run lint
   - npm run typecheck (if TypeScript)

5. **Commit and push** if any refactoring applied:
   ```bash
   git add -A
   git commit -m "refactor: improve code quality - iteration {{ITERATION}}

   Co-Authored-By: Claude <noreply@anthropic.com>"
   git push
   ```

6. **Calculate confidence** using the formula:
   ```
   confidence = (skill_confidence × 0.70) + (test_stability × 0.30)
   ```

7. **Set PR label** with confidence score:
   ```bash
   gh pr edit {{PR_NUMBER}} --add-label "ralpr:refactor:$CONFIDENCE"
   ```

## Output Format

After completing all tasks, output EXACTLY this JSON (no other text):

```json
{
  "iteration": {{ITERATION}},
  "skill_confidence": <0-100>,
  "refactorings_applied": <count>,
  "quality_gates": {
    "tests": "passed|failed|skipped",
    "lint": "passed|failed|skipped",
    "typecheck": "passed|failed|skipped"
  },
  "commits": [<list of commit SHAs if any>],
  "confidence": <calculated_confidence_0_100>,
  "label_set": "ralpr:refactor:<confidence>"
}
```
