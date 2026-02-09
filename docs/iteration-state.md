# Iteration State Management

## Canonical State Source

PR comments (hidden HTML markers) are the **authoritative** state source. Local `.ralpr/pr-N/` files are script-level caches and may be stale. If there is a conflict between a PR comment state and a local file, the PR comment wins.

## State Markers

State persists as hidden PR comments with **phase-specific markers**:

- Review: `<!-- RALPR_REVIEW_STATE {...} -->`
- Refactor: `<!-- RALPR_REFACTOR_STATE {...} -->`

## State Schema

Review state includes user directive tracking:

```json
{
  "iteration": 2,
  "cumulative_score": 25.7,
  "confidence": 65,
  "status": "active",
  "user_directives": [
    {"id": "UD-1", "status": "resolved", "resolved_by": "commit abc123"},
    {"id": "UD-2", "status": "pending_approval"}
  ]
}
```

**Directive Status Values:**
- `pending` — Not yet addressed, needs fix or user response
- `resolved` — Addressed by a fix (include `resolved_by` reference)
- `skipped_with_approval` — User explicitly approved skipping
- `pending_approval` — Waiting for user response (blocks progress)

**Blocked State:**
When waiting for user response:
```json
{
  "iteration": 2,
  "status": "blocked",
  "reason": "awaiting_user_response",
  "directive_id": "UD-2",
  "blocked_at": "2024-01-15T10:30:00Z"
}
```

**Confidence Cap Rule:** A PR cannot reach 90% confidence if ANY user directive has status `pending_approval`. Maximum achievable is 70% until all directives are resolved or explicitly approved for skip.

## Read State

**Review Phase:**
```bash
REVIEW_STATE=$(gh pr view <N> --json comments --jq '
  [.comments[] | select(.body | contains("RALPR_REVIEW_STATE")) | .body] | first // empty
' | grep -oE '\{"iteration":[^}]+\}')
[ -z "$REVIEW_STATE" ] && REVIEW_STATE='{"iteration":0,"cumulative_score":0,"confidence":40}'
```

**Refactor Phase:**
```bash
REFACTOR_STATE=$(gh pr view <N> --json comments --jq '
  [.comments[] | select(.body | contains("RALPR_REFACTOR_STATE")) | .body] | first // empty
' | grep -oE '\{"iteration":[^}]+\}')
[ -z "$REFACTOR_STATE" ] && REFACTOR_STATE='{"iteration":0,"confidence":0}'
```

## Write State (Delete-then-Create)

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

## End State

PR should have exactly:
- One final review comment (with `RALPR_REVIEW_STATE`)
- One final refactor comment (with `RALPR_REFACTOR_STATE`)
