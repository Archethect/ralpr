# Comment Formats & Labels

## Labels

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

## Iteration Labels (Script-Managed)

Scripts automatically create iteration-tracking labels:
- `ralpr:review:iter:N` — set by `ralpr-review.sh` after each review iteration
- `ralpr:refactor:iter:N` — set by `ralpr-refactor.sh` after each refactor iteration

These are **read-only for agents**. Do not manually create, modify, or remove them. They are operational labels managed by scripts, separate from the confidence labels above.

## Comment Templates

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

## User Directive Pending

Use this template when a user directive cannot be addressed and requires user response:

```markdown
⚠️ **User Directive Pending**

@{author} requested: "{directive}"

Our review did not produce a fix for this. Options:
1. I can implement this now (reply 'proceed')
2. You can clarify the requirement (reply with details)
3. You can approve skipping (reply 'skip approved')

Waiting for your response before continuing.

<!-- RALPR_REVIEW_STATE {"iteration":N,"status":"blocked","reason":"awaiting_user_response","directive_id":"UD-X"} -->
```

**User Response Patterns:**
- Proceed: "proceed", "yes", "implement", "do it", "go ahead"
- Skip: "skip approved", "skip", "defer", "not needed", "ignore"
- Clarify: Any other response is treated as clarification

## Icons Reference

| Icon | Meaning |
|------|---------|
| 🔄 | Review phase |
| ✨ | Refactor phase |
| 🏁 | Iteration number |
| 🎯 | Confidence score |
| 📈 | Points earned |
| 🔴 | High severity |
| 🟡 | Medium severity |
| 🟢 | Low severity |
| ✅ | Tests status |
| ⚠️ | User directive pending |
