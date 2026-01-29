Ralpr Review Phase - Iteration {{ITERATION}} for PR #{{PR_NUMBER}}

You are running Ralpr Review Phase iteration {{ITERATION}}.

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
     description="Analyze PR changes"
   )
   ```

2. **Run 3 reviewers IN PARALLEL**:
   ```
   Task(subagent_type="ralpr:qa-reviewer", prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": {{PR_NUMBER}}, "branch": "{{BRANCH}}", "base_branch": "{{BASE_BRANCH}}", "working_dir": "{{WORKING_DIR}}", "map_path": "docs/.codebase-map.json"}', description="QA review")
   Task(subagent_type="ralpr:domain-expert", prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": {{PR_NUMBER}}, "branch": "{{BRANCH}}", "base_branch": "{{BASE_BRANCH}}", "working_dir": "{{WORKING_DIR}}", "map_path": "docs/.codebase-map.json"}', description="Domain review")
   Task(subagent_type="ralpr:codex-reviewer", prompt='Follow your agent instructions to complete the task described by the following input data:\n\n{"pr_number": {{PR_NUMBER}}, "branch": "{{BRANCH}}", "base_branch": "{{BASE_BRANCH}}", "working_dir": "{{WORKING_DIR}}"}', description="Codex review")
   ```

3. **Aggregate issues** - Dedupe by file:line, prioritize by severity

4. **Apply fixes** - For high-confidence suggestions (>0.8), apply the fix

5. **Run quality gates**:
   - npm test
   - npm run lint
   - npm run typecheck (if TypeScript)

6. **Commit and push** if any fixes applied:
   ```bash
   git add -A
   git commit -m "fix: address review feedback - iteration {{ITERATION}}

   Co-Authored-By: Claude <noreply@anthropic.com>"
   git push
   ```

7. **Calculate confidence** using the formula:
   ```
   confidence = (convergence × 0.30) + (resolution × 0.25) + (consensus × 0.20) + (test_quality × 0.15) + (severity_trend × 0.10)
   ```
   Note: First iteration caps at ~57% to ensure convergence proof.

8. **Set PR label** with confidence score:
   ```bash
   gh pr edit {{PR_NUMBER}} --add-label "ralpr:review:$CONFIDENCE"
   ```

## Output Format

After completing all tasks, output EXACTLY this JSON (no other text):

```json
{
  "iteration": {{ITERATION}},
  "reviewers": {
    "qa": <qa_reviewer_output>,
    "domain": <domain_expert_output>,
    "codex": <codex_reviewer_output>
  },
  "issues_found": <total_count>,
  "issues_fixed": <fixed_count>,
  "quality_gates": {
    "tests": "passed|failed|skipped",
    "lint": "passed|failed|skipped",
    "typecheck": "passed|failed|skipped"
  },
  "commits": [<list of commit SHAs if any>],
  "confidence": <calculated_confidence_0_100>,
  "label_set": "ralpr:review:<confidence>"
}
```
