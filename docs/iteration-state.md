# Iteration State Management

State persists as hidden PR comments with **phase-specific markers**:

- Review: `<!-- RALPR_REVIEW_STATE {...} -->`
- Refactor: `<!-- RALPR_REFACTOR_STATE {...} -->`

## Read State

**Review Phase:**
```bash
REVIEW_STATE=$(gh pr view <N> --json comments --jq '
  .comments[] | select(.body | contains("RALPR_REVIEW_STATE")) | .body
' | head -1 | grep -oP '(?<=<!-- RALPR_REVIEW_STATE )\{[^}]+\}(?= -->)')
[ -z "$REVIEW_STATE" ] && REVIEW_STATE='{"iteration":0,"cumulative_score":0,"confidence":40}'
```

**Refactor Phase:**
```bash
REFACTOR_STATE=$(gh pr view <N> --json comments --jq '
  .comments[] | select(.body | contains("RALPR_REFACTOR_STATE")) | .body
' | head -1 | grep -oP '(?<=<!-- RALPR_REFACTOR_STATE )\{[^}]+\}(?= -->)')
[ -z "$REFACTOR_STATE" ] && REFACTOR_STATE='{"iteration":0,"confidence":0}'
```

## Write State (Delete-then-Create)

**Review Phase:**
```bash
# Delete existing review comment
COMMENT_ID=$(gh pr view <N> --json comments --jq '
  .comments[] | select(.body | contains("RALPR_REVIEW_STATE")) | .id
' | head -1)
[ -n "$COMMENT_ID" ] && gh api repos/{owner}/{repo}/issues/comments/$COMMENT_ID -X DELETE

# Create new
gh pr comment <N> --body "$REVIEW_BODY"
```

**Refactor Phase (preserves review comment):**
```bash
# Delete existing REFACTOR comment only
COMMENT_ID=$(gh pr view <N> --json comments --jq '
  .comments[] | select(.body | contains("RALPR_REFACTOR_STATE")) | .id
' | head -1)
[ -n "$COMMENT_ID" ] && gh api repos/{owner}/{repo}/issues/comments/$COMMENT_ID -X DELETE

# Create new
gh pr comment <N> --body "$REFACTOR_BODY"
```

**Semantics:** Read `iteration: N` → N iterations completed. After completing, write `iteration: N+1`.

## End State

PR should have exactly:
- One final review comment (with `RALPR_REVIEW_STATE`)
- One final refactor comment (with `RALPR_REFACTOR_STATE`)
