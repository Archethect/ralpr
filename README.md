# Ralpr v2.0

**Ralph Autonomous Loop for Pull-request Readiness**

Three-phase architecture for autonomous GitHub ticket processing with fresh context per loop iteration.

## Key Changes from v1.0

1. **Three Independent Phases**: Implementation → Review → Refactor
2. **No Nested Subagents**: Only main agent spawns subagents (no nesting)
3. **Fresh Context Per Loop**: Each review/refactor iteration runs in a fresh Claude session
4. **GitHub Labels Track State**: Phases communicate via PR labels, not context
5. **Quality Gates in ALL Phases**: Tests, lint, typecheck, CI must pass
6. **Claude Sessions Set Labels**: Labels are set directly by Claude sessions, not bash orchestrator

## Architecture

```
Phase 1: Implementation    Phase 2: Review         Phase 3: Refactor
(No loops)                 (Loops + 90% target)    (Loops + 95% target)

Select → Understand →      LOOP:                   LOOP:
Implement → PR → CI        Fresh session →         Fresh session →
                          3 reviewers parallel →   Refactor skill →
Label: ralpr:impl:done     Fix → Quality gates     Quality gates
                          Set label directly       Set label directly

                          Label: ralpr:review:XX  Label: ralpr:refactor:XX
```

## Usage

```bash
# Full pipeline
/ralpr --issue 123

# Specific phases
/ralpr --phase impl --issue 123
/ralpr --phase review --pr 456
/ralpr --phase refactor --pr 456

# Auto-select
/ralpr                    # Auto-select issue/PR
/ralpr --phase review     # Auto-select review-ready PR
```

## File Structure

```
~/.claude/plugins/cache/local/atw/2.0.0/
├── scripts/
│   ├── ralpr                    # Main CLI
│   ├── ralpr-orchestrator.sh    # Session manager
│   ├── ralpr-implementation.sh  # Phase 1
│   ├── ralpr-review.sh          # Phase 2
│   ├── ralpr-refactor.sh        # Phase 3
│   └── lib/
│       ├── common.sh
│       ├── quality-gates.sh
│       ├── github-labels.sh
│       ├── confidence.sh
│       └── ci-watcher.sh
├── agents/
│   ├── explore-agent.md
│   ├── understand-agent.md
│   ├── implement-agent.md
│   ├── qa-reviewer.md
│   ├── domain-expert.md
│   └── codex-reviewer.md
├── config/
│   └── ralpr.config.sh
├── schemas/
│   └── confidence.json
├── skills/
│   └── ralpr/
│       └── SKILL.md
├── docs/
│   └── confidence-formulas.md
└── hooks/
    ├── hooks.json
    └── session-start.sh
```

## Configuration

Override via environment variables:

```bash
# Review phase
REVIEW_THRESHOLD=90
REVIEW_MAX_LOOPS=7

# Refactor phase
REFACTOR_THRESHOLD=95
REFACTOR_MAX_LOOPS=5
```

## Confidence Formulas

### Review Phase
```
confidence = (verdict × 0.40) + (critical_resolved × 0.30) +
             (important_resolved × 0.20) + (iteration_score × 0.10)
```

### Refactor Phase
```
confidence = (skill_confidence × 0.70) + (test_stability × 0.30)
```

## Label Setting

Labels are set directly by Claude sessions using:

```bash
# Review phase
gh pr edit $PR_NUMBER --add-label "ralpr:review:$CONFIDENCE"

# Refactor phase
gh pr edit $PR_NUMBER --add-label "ralpr:refactor:$CONFIDENCE"
```

See `docs/confidence-formulas.md` for detailed documentation.
