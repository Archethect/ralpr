/**
 * Docker container + tmux pane management.
 * Spawns Agent Teams inside containers, manages lifecycle.
 */

import { exec } from './exec.js';
import type { RalprConfig } from './config.js';

const CONTAINER_PREFIX = 'ralpr-issue-';

export function containerName(issueNumber: number): string {
  return `${CONTAINER_PREFIX}${issueNumber}`;
}

export async function spawnTeam(
  issueNumber: number,
  worktreePath: string,
  config: RalprConfig,
  noVncPort: number,
): Promise<{ containerName: string; exitCode: number }> {
  const name = containerName(issueNumber);

  const args = [
    'run', '-d',
    '--name', name,
    '-v', `${worktreePath}:/workspace`,
    '-e', 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1',
    '-e', `RALPR_TEAMMATE_MODE=${config.teammateMode}`,
    '-e', `RALPR_MODEL=${config.model}`,
    '-e', `RALPR_STAGE_MAX_TURNS=${config.stageMaxTurns}`,
    '-e', `RALPR_TASK_QUALITY_MAX_ITERATIONS=${config.taskQualityMaxIterations}`,
    '-e', `RALPR_PR_QUALITY_MAX_ITERATIONS=${config.prQualityMaxIterations}`,
    '-e', `RALPR_BASE_BRANCH=${config.baseBranch}`,
    '-e', `RALPR_DEBUG=${config.debug ? '1' : '0'}`,
    '-p', `${noVncPort}:6080`,
    '--workdir', '/workspace',
    'ralpr:latest',
  ];

  const result = await exec('docker', args);

  return { containerName: name, exitCode: result.exitCode };
}

export async function createTmuxPane(
  ctrName: string,
  config: RalprConfig,
): Promise<string> {
  const paneId = `${config.tmuxSession}:${ctrName}`;

  await exec('tmux', [
    'new-window', '-t', config.tmuxSession,
    '-n', ctrName,
    'docker', 'logs', '-f', ctrName,
  ]);

  return paneId;
}

export async function stopTeam(ctrName: string): Promise<void> {
  await exec('docker', ['stop', ctrName]);
  await exec('docker', ['rm', '-f', ctrName]);
}

export async function isContainerRunning(ctrName: string): Promise<boolean> {
  const result = await exec('docker', [
    'inspect', '-f', '{{.State.Running}}', ctrName,
  ]);
  return result.exitCode === 0 && result.stdout === 'true';
}

export async function getContainerLogs(
  ctrName: string,
  tail: number = 50,
): Promise<string> {
  const result = await exec('docker', [
    'logs', '--tail', String(tail), ctrName,
  ]);
  return result.stdout;
}

export async function createWorktree(
  repoRoot: string,
  issueNumber: number,
  baseBranch: string,
): Promise<{ worktreePath: string; exitCode: number }> {
  const branchName = `ralpr/issue-${issueNumber}`;
  const worktreePath = `${repoRoot}/.worktrees/issue-${issueNumber}`;

  const result = await exec('git', [
    'worktree', 'add', '-b', branchName, worktreePath, baseBranch,
  ], repoRoot);

  return { worktreePath, exitCode: result.exitCode };
}

export async function removeWorktree(
  repoRoot: string,
  worktreePath: string,
): Promise<void> {
  await exec('git', ['worktree', 'remove', '--force', worktreePath], repoRoot);
}
