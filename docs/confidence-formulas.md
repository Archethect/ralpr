# Confidence Formulas for Ralpr

This document describes how confidence scores are calculated for the review and refactor phases.

## Review Phase Confidence (Cumulative Additive Model)

### Key Principle

**Confidence only goes UP, never down.** Each iteration earns points based on quality factors. This eliminates issues with duplicate detection and ensures steady progress toward the threshold.

### Formula

```
iteration_points = 5                           # base: completed iteration
                 + (4 if tests_pass)           # tests passing
                 + (3 if high_sev == 0         # no high severity
                    else 1 if high_sev <= 1)   # or just 1 high severity
                 + (3 if all_approved          # all reviewers approve
                    else 1 if approved >= 2)   # or majority approve

multiplier = max(0.5, 1.0 - iteration * 0.1)   # diminishing returns
points_earned = iteration_points * multiplier

confidence = min(100, 40 + cumulative_score)
```

### Components

| Factor | Points | Description |
|--------|--------|-------------|
| Base | +5 | Completed iteration (always earned) |
| Tests pass | +4 | All tests passing |
| No high severity | +3 | Zero critical/important issues |
| Low high severity | +1 | Only 1 critical/important issue |
| All approve | +3 | All 3 reviewers APPROVED |
| Majority approve | +1 | At least 2 reviewers APPROVED |

**Range per iteration: 5-15 points**

### Diminishing Returns

Later iterations earn fewer points to encourage fixing issues early:

| Iteration | Multiplier | Max Points |
|-----------|------------|------------|
| 1 | 1.0 | 15 |
| 2 | 0.9 | 13.5 |
| 3 | 0.8 | 12 |
| 4 | 0.7 | 10.5 |
| 5 | 0.6 | 9 |
| 6+ | 0.5 | 7.5 |

### Progression Examples

**Perfect iterations (15 points each):**
```
Iter 1: 40 + 15.0 = 55%
Iter 2: 40 + 28.5 = 68%
Iter 3: 40 + 40.5 = 80%
Iter 4: 40 + 51.0 = 91%  <- threshold met
```

**Average iterations (10 points each):**
```
Iter 1: 40 + 10.0 = 50%
Iter 2: 40 + 19.0 = 59%
Iter 3: 40 + 27.0 = 67%
Iter 4: 40 + 34.0 = 74%
Iter 5: 40 + 40.0 = 80%
Iter 6: 40 + 45.0 = 85%
Iter 7: 40 + 50.0 = 90%  <- threshold met
```

**Poor iterations (5 points each):**
```
Iter 1: 40 + 5.0 = 45%
Iter 2: 40 + 9.5 = 49%
Iter 3: 40 + 13.5 = 53%
... (many more iterations needed)
```

---

## State Management

State persists across iterations in `.ralpr/pr-<NUMBER>/confidence-state.json`.

### State File Structure

```json
{
  "pr_number": 123,
  "phase": "review",
  "iteration": 2,
  "cumulative_score": 25.5,
  "confidence": 65,
  "iterations": [
    {
      "iteration": 1,
      "cumulative_score": 14,
      "confidence": 54,
      "breakdown": {
        "base_points": 14,
        "multiplier": 1.0,
        "points_earned": 14,
        "tests_passed": true,
        "high_severity_count": 1,
        "approved_count": 2,
        "total_reviewers": 3
      }
    },
    {
      "iteration": 2,
      "cumulative_score": 25.5,
      "confidence": 65,
      "breakdown": {
        "base_points": 13,
        "multiplier": 0.9,
        "points_earned": 11.7,
        "tests_passed": true,
        "high_severity_count": 0,
        "approved_count": 3,
        "total_reviewers": 3
      }
    }
  ]
}
```

### PR Comment State

State is also persisted as a hidden PR comment for cross-session continuity:

```html
<!-- RALPR_STATE {"phase":"review","iteration":2,"cumulative_score":25.5,"confidence":65} -->
```

---

## Setting the Label

After calculating confidence, set the PR label:

```bash
# Remove existing ralpr review labels
gh pr view $PR_NUMBER --json labels --jq '.labels[].name' | grep "^ralpr:review:" | while read label; do
  gh pr edit $PR_NUMBER --remove-label "$label"
done

# Set new confidence label
gh pr edit $PR_NUMBER --add-label "ralpr:review:$CONFIDENCE"
```

### Threshold

Default threshold: **90%**

If confidence >= 90%, the review phase passes.

---

## Refactor Phase Confidence

The refactor phase uses a different formula (unchanged from previous version).

### Formula

```
confidence = (skill_confidence * 0.70) + (test_stability * 0.30)
```

### Components

| Component | Weight | Description |
|-----------|--------|-------------|
| `skill_confidence` | 70% | Confidence reported by refactor skill (0-100) |
| `test_stability` | 30% | 1.0 if all tests pass, 0.0 if any fail |

### Threshold

Default threshold: **95%**

---

## Configuration

Override settings via environment variables:

```bash
# Review phase base confidence
REVIEW_BASE_CONFIDENCE=40

# Refactor phase weights
REFACTOR_WEIGHTS_SKILL=0.70
REFACTOR_WEIGHTS_STABILITY=0.30

# Thresholds
REVIEW_THRESHOLD=85
REFACTOR_THRESHOLD=85
```

---

## Label Colors

Labels are created with colors based on confidence level:

| Confidence | Color | Hex |
|------------|-------|-----|
| >= 85% | Green | #238636 |
| 65-84% | Orange | #d29922 |
| < 65% | Red | #d73a4a |

---

## Why Cumulative Additive?

The previous formula had a critical flaw:

**Problem:** Using `resolution = total_fixed / total_found` with cumulative totals meant reviewers re-finding the same issues (duplicates) caused confidence to DROP over iterations.

**Solution:** The additive model:
1. **No issue tracking needed** - reviewers can flag same issues forever
2. **Monotonically increasing** - confidence never drops
3. **Simple state** - just iteration count and cumulative score
4. **Predictable** - 4 good iterations gets you to 90%+
5. **Rewards quality** - better iterations earn more points faster
