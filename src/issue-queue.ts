/**
 * GitHub issue queue management.
 * Polls for available issues, claims/releases via `gh` CLI.
 */

import { exec } from './exec.js';
import type { IssueInfo } from './types.js';

const PRIORITY_LABELS = ['priority:critical', 'priority:high', 'priority:medium', 'priority:low'];

function priorityRank(labels: string[]): number {
  for (let i = 0; i < PRIORITY_LABELS.length; i++) {
    if (labels.includes(PRIORITY_LABELS[i])) return i;
  }
  return PRIORITY_LABELS.length;
}

export async function pollIssueQueue(baseBranch: string): Promise<IssueInfo[]> {
  const result = await exec('gh', [
    'issue', 'list',
    '--state', 'open',
    '--assignee', '',
    '--json', 'number,title,labels,body,assignees',
    '--limit', '50',
  ]);

  if (result.exitCode !== 0 || !result.stdout) return [];

  const raw = JSON.parse(result.stdout) as Array<{
    number: number;
    title: string;
    labels: Array<{ name: string }>;
    body: string;
    assignees: Array<{ login: string }>;
  }>;

  const unassigned = raw.filter((issue) => issue.assignees.length === 0);

  const issues: IssueInfo[] = unassigned.map((issue) => ({
    number: issue.number,
    title: issue.title,
    labels: issue.labels.map((l) => l.name),
    body: issue.body ?? '',
    assignees: issue.assignees.map((a) => a.login),
  }));

  issues.sort((a, b) => priorityRank(a.labels) - priorityRank(b.labels));

  return issues;
}

export async function claimIssue(issueNumber: number): Promise<boolean> {
  const assignResult = await exec('gh', [
    'issue', 'edit', String(issueNumber),
    '--add-assignee', '@me',
  ]);

  if (assignResult.exitCode !== 0) return false;

  const verifyResult = await exec('gh', [
    'issue', 'view', String(issueNumber),
    '--json', 'assignees',
  ]);

  if (verifyResult.exitCode !== 0) return false;

  const data = JSON.parse(verifyResult.stdout) as {
    assignees: Array<{ login: string }>;
  };

  const meResult = await exec('gh', ['api', 'user', '--jq', '.login']);
  if (meResult.exitCode !== 0) return false;

  const myLogin = meResult.stdout;
  return data.assignees.some((a) => a.login === myLogin);
}

export async function releaseIssue(issueNumber: number): Promise<void> {
  await exec('gh', [
    'issue', 'edit', String(issueNumber),
    '--remove-assignee', '@me',
  ]);
}

export async function addLabel(issueNumber: number, label: string): Promise<void> {
  await exec('gh', [
    'issue', 'edit', String(issueNumber),
    '--add-label', label,
  ]);
}

export async function removeLabel(issueNumber: number, label: string): Promise<void> {
  await exec('gh', [
    'issue', 'edit', String(issueNumber),
    '--remove-label', label,
  ]);
}
