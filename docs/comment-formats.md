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
