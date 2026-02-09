/**
 * Cost tracking and threshold alerts.
 * Parses cost lines from container stdout, aggregates per issue.
 */

import { exec } from './exec.js';
import type { RalprConfig } from './config.js';
import type { CostEntry, Stage } from './types.js';

export type ThresholdStatus = 'ok' | 'warning' | 'hard-limit';

const costStore: Map<number, CostEntry[]> = new Map();

const COST_PATTERN = /RALPR_COST:\s*\$?([\d.]+)/;

export function parseCostLine(line: string): number | null {
  const match = COST_PATTERN.exec(line);
  if (!match) return null;
  const amount = parseFloat(match[1]);
  return Number.isNaN(amount) ? null : amount;
}

export function addCost(issueNumber: number, stage: Stage, amount: number): void {
  const entries = costStore.get(issueNumber) ?? [];
  entries.push({
    issueNumber,
    stage,
    amount,
    timestamp: new Date().toISOString(),
  });
  costStore.set(issueNumber, entries);
}

export function getTotalCost(issueNumber: number): number {
  const entries = costStore.get(issueNumber) ?? [];
  return entries.reduce((sum, e) => sum + e.amount, 0);
}

export function getAllCosts(): Map<number, CostEntry[]> {
  return new Map(costStore);
}

export function getGlobalTotalCost(): number {
  let total = 0;
  for (const entries of costStore.values()) {
    total += entries.reduce((sum, e) => sum + e.amount, 0);
  }
  return total;
}

export function checkThresholds(
  issueNumber: number,
  config: RalprConfig,
): ThresholdStatus {
  const total = getTotalCost(issueNumber);

  if (total >= config.costHardLimit) return 'hard-limit';
  if (total >= config.costWarning) return 'warning';
  return 'ok';
}

export async function notifyMacOs(message: string): Promise<void> {
  await exec('osascript', [
    '-e', `display notification "${message}" with title "Ralpr"`,
  ]);
}

export function clearCosts(issueNumber: number): void {
  costStore.delete(issueNumber);
}

export function resetAllCosts(): void {
  costStore.clear();
}
