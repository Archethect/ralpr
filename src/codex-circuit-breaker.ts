/**
 * Codex circuit breaker.
 * Checks Codex MCP availability, manages blocked state.
 */

import { exec } from './exec.js';
import { addLabel, removeLabel } from './issue-queue.js';

const BLOCKED_LABEL = 'blocked:codex';
const SKIPPED_LABEL = 'codex-skipped';

const blockedIssues: Set<number> = new Set();

export async function checkCodexAvailability(): Promise<boolean> {
  const result = await exec('claude', [
    '--print', '-p', 'echo test',
    '--model', 'codex',
  ]);

  return result.exitCode === 0 && result.stdout.includes('test');
}

export async function queueAsBlocked(issueNumber: number): Promise<void> {
  blockedIssues.add(issueNumber);
  await addLabel(issueNumber, BLOCKED_LABEL);
}

export async function allowOverride(issueNumber: number): Promise<boolean> {
  blockedIssues.delete(issueNumber);
  await removeLabel(issueNumber, BLOCKED_LABEL);
  await addLabel(issueNumber, SKIPPED_LABEL);
  return true;
}

export function isBlocked(issueNumber: number): boolean {
  return blockedIssues.has(issueNumber);
}

export function getBlockedIssues(): number[] {
  return [...blockedIssues];
}

export async function retryBlocked(): Promise<number[]> {
  const available = await checkCodexAvailability();
  if (!available) return [];

  const unblocked: number[] = [];
  for (const issueNumber of blockedIssues) {
    blockedIssues.delete(issueNumber);
    await removeLabel(issueNumber, BLOCKED_LABEL);
    unblocked.push(issueNumber);
  }

  return unblocked;
}

export function resetBlockedState(): void {
  blockedIssues.clear();
}
