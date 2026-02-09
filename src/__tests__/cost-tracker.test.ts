import { describe, it, expect, beforeEach } from 'vitest';
import {
  parseCostLine, addCost, getTotalCost, checkThresholds,
  clearCosts, resetAllCosts, getGlobalTotalCost,
} from '../cost-tracker.js';
import type { RalprConfig } from '../config.js';
import { loadConfig } from '../config.js';

function makeConfig(overrides: Partial<RalprConfig> = {}): RalprConfig {
  return { ...loadConfig(), ...overrides };
}

describe('parseCostLine', () => {
  it('parses RALPR_COST line with dollar sign', () => {
    expect(parseCostLine('RALPR_COST: $1.50')).toBe(1.5);
  });

  it('parses RALPR_COST line without dollar sign', () => {
    expect(parseCostLine('RALPR_COST: 2.75')).toBe(2.75);
  });

  it('returns null for non-cost line', () => {
    expect(parseCostLine('some random log output')).toBeNull();
  });

  it('returns null for empty string', () => {
    expect(parseCostLine('')).toBeNull();
  });

  it('parses zero cost', () => {
    expect(parseCostLine('RALPR_COST: $0.00')).toBe(0);
  });

  it('parses cost with extra whitespace', () => {
    expect(parseCostLine('RALPR_COST:   $3.14')).toBe(3.14);
  });
});

describe('cost aggregation', () => {
  beforeEach(() => {
    resetAllCosts();
  });

  it('starts at zero for unknown issue', () => {
    expect(getTotalCost(999)).toBe(0);
  });

  it('accumulates costs for an issue', () => {
    addCost(1, 'implement', 1.5);
    addCost(1, 'test', 0.75);
    expect(getTotalCost(1)).toBe(2.25);
  });

  it('tracks costs per issue independently', () => {
    addCost(1, 'implement', 1.0);
    addCost(2, 'implement', 2.0);
    expect(getTotalCost(1)).toBe(1.0);
    expect(getTotalCost(2)).toBe(2.0);
  });

  it('clears costs for a single issue', () => {
    addCost(1, 'implement', 1.0);
    addCost(2, 'implement', 2.0);
    clearCosts(1);
    expect(getTotalCost(1)).toBe(0);
    expect(getTotalCost(2)).toBe(2.0);
  });

  it('computes global total across all issues', () => {
    addCost(1, 'implement', 1.0);
    addCost(2, 'test', 2.0);
    addCost(3, 'review+codex', 3.0);
    expect(getGlobalTotalCost()).toBe(6.0);
  });
});

describe('checkThresholds', () => {
  beforeEach(() => {
    resetAllCosts();
  });

  it('returns ok when under warning', () => {
    addCost(1, 'implement', 10);
    const config = makeConfig({ costWarning: 25, costHardLimit: 100 });
    expect(checkThresholds(1, config)).toBe('ok');
  });

  it('returns warning at warning threshold', () => {
    addCost(1, 'implement', 25);
    const config = makeConfig({ costWarning: 25, costHardLimit: 100 });
    expect(checkThresholds(1, config)).toBe('warning');
  });

  it('returns hard-limit at hard limit', () => {
    addCost(1, 'implement', 100);
    const config = makeConfig({ costWarning: 25, costHardLimit: 100 });
    expect(checkThresholds(1, config)).toBe('hard-limit');
  });

  it('returns hard-limit when over hard limit', () => {
    addCost(1, 'implement', 150);
    const config = makeConfig({ costWarning: 25, costHardLimit: 100 });
    expect(checkThresholds(1, config)).toBe('hard-limit');
  });
});
