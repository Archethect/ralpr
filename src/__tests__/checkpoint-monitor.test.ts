import { describe, it, expect } from 'vitest';
import { validateCheckpoint, isTerminalStage, nextStage } from '../checkpoint-monitor.js';
import type { Checkpoint, Tier, Stage } from '../types.js';

function makeCheckpoint(overrides: Partial<Checkpoint> = {}): Checkpoint {
  return {
    current_stage: 'implement',
    tier: 'S',
    completed_tasks: [],
    committed_shas: [],
    last_completed_stage: 'research',
    review_verdicts: {},
    cost_so_far: 0,
    plan: [],
    quality_iterations: {},
    compact_prompt: '',
    timestamp: new Date().toISOString(),
    ...overrides,
  };
}

describe('validateCheckpoint', () => {
  it('accepts valid S-tier checkpoint with adjacent stages', () => {
    const cp = makeCheckpoint({ tier: 'S', current_stage: 'implement', last_completed_stage: 'research' });
    const result = validateCheckpoint(cp, 'S');
    expect(result.valid).toBe(true);
    expect(result.violation).toBeUndefined();
  });

  it('accepts checkpoint at same stage as last completed', () => {
    const cp = makeCheckpoint({ tier: 'S', current_stage: 'implement', last_completed_stage: 'implement' });
    const result = validateCheckpoint(cp, 'S');
    expect(result.valid).toBe(true);
  });

  it('rejects tier mismatch', () => {
    const cp = makeCheckpoint({ tier: 'S' });
    const result = validateCheckpoint(cp, 'M');
    expect(result.valid).toBe(false);
    expect(result.violation).toContain('does not match');
  });

  it('rejects invalid stage for tier', () => {
    const cp = makeCheckpoint({ tier: 'S', current_stage: 'docs' as Stage });
    const result = validateCheckpoint(cp, 'S');
    expect(result.valid).toBe(false);
    expect(result.violation).toContain('not valid for tier S');
  });

  it('rejects skipped stages', () => {
    const cp = makeCheckpoint({
      tier: 'S',
      current_stage: 'test',
      last_completed_stage: 'implement',
    });
    const result = validateCheckpoint(cp, 'S');
    expect(result.valid).toBe(false);
    expect(result.violation).toContain('skipped');
  });

  it('rejects backwards progression', () => {
    const cp = makeCheckpoint({
      tier: 'S',
      current_stage: 'research',
      last_completed_stage: 'implement',
    });
    const result = validateCheckpoint(cp, 'S');
    expect(result.valid).toBe(false);
    expect(result.violation).toContain('before last completed');
  });

  it('rejects negative iteration counts', () => {
    const cp = makeCheckpoint({
      tier: 'S',
      current_stage: 'implement',
      last_completed_stage: 'research',
      quality_iterations: { 'task-1': { task_quality: -1, pr_quality: 0 } },
    });
    const result = validateCheckpoint(cp, 'S');
    expect(result.valid).toBe(false);
    expect(result.violation).toContain('negative iteration');
  });

  it('validates M-tier stage sequence', () => {
    const cp = makeCheckpoint({
      tier: 'M',
      current_stage: 'plan',
      last_completed_stage: 'evaluate',
    });
    const result = validateCheckpoint(cp, 'M');
    expect(result.valid).toBe(true);
  });

  it('validates L-tier stage sequence', () => {
    const cp = makeCheckpoint({
      tier: 'L',
      current_stage: 'task-review',
      last_completed_stage: 'implement',
    });
    const result = validateCheckpoint(cp, 'L');
    expect(result.valid).toBe(true);
  });
});

describe('isTerminalStage', () => {
  it('returns true for complete stage', () => {
    expect(isTerminalStage('complete', 'S')).toBe(true);
    expect(isTerminalStage('complete', 'M')).toBe(true);
    expect(isTerminalStage('complete', 'L')).toBe(true);
  });

  it('returns false for non-terminal stages', () => {
    expect(isTerminalStage('implement', 'S')).toBe(false);
    expect(isTerminalStage('setup', 'L')).toBe(false);
  });
});

describe('nextStage', () => {
  it('returns next S-tier stage', () => {
    expect(nextStage('setup', 'S')).toBe('research');
    expect(nextStage('research', 'S')).toBe('implement');
    expect(nextStage('implement', 'S')).toBe('simplify');
  });

  it('returns null for terminal stage', () => {
    expect(nextStage('complete', 'S')).toBeNull();
    expect(nextStage('complete', 'M')).toBeNull();
  });

  it('returns null for invalid stage', () => {
    expect(nextStage('docs' as Stage, 'S')).toBeNull();
  });

  it('handles M-tier unique stages', () => {
    expect(nextStage('evaluate', 'M')).toBe('plan');
    expect(nextStage('plan', 'M')).toBe('implement');
  });

  it('handles L-tier unique stages', () => {
    expect(nextStage('implement', 'L')).toBe('task-review');
    expect(nextStage('task-review', 'L')).toBe('fix');
    expect(nextStage('docs', 'L')).toBe('pr');
  });
});
