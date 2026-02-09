/**
 * Automatic rebase on merge conflicts.
 * Fetches upstream, checks for conflicts, auto-rebases.
 */

import { exec } from './exec.js';

export interface RebaseResult {
  success: boolean;
  hadConflicts: boolean;
  error?: string;
}

export async function checkAndRebase(
  worktreePath: string,
  baseBranch: string,
): Promise<RebaseResult> {
  const fetchResult = await exec('git', ['fetch', 'origin', baseBranch], worktreePath);
  if (fetchResult.exitCode !== 0) {
    return { success: false, hadConflicts: false, error: `fetch failed: ${fetchResult.stderr}` };
  }

  const mergeBaseResult = await exec(
    'git', ['merge-base', 'HEAD', `origin/${baseBranch}`],
    worktreePath,
  );
  if (mergeBaseResult.exitCode !== 0) {
    return { success: false, hadConflicts: false, error: 'cannot find merge base' };
  }

  const diffResult = await exec(
    'git', ['diff', '--name-only', `origin/${baseBranch}...HEAD`],
    worktreePath,
  );

  const checkResult = await exec(
    'git', ['diff', '--name-only', `${mergeBaseResult.stdout}..origin/${baseBranch}`],
    worktreePath,
  );

  const ourFiles = new Set(diffResult.stdout.split('\n').filter(Boolean));
  const theirFiles = new Set(checkResult.stdout.split('\n').filter(Boolean));
  const overlapping = [...ourFiles].filter((f) => theirFiles.has(f));

  if (overlapping.length === 0) {
    const rebaseResult = await exec(
      'git', ['rebase', `origin/${baseBranch}`],
      worktreePath,
    );

    if (rebaseResult.exitCode !== 0) {
      await exec('git', ['rebase', '--abort'], worktreePath);
      return { success: false, hadConflicts: true, error: rebaseResult.stderr };
    }

    return { success: true, hadConflicts: false };
  }

  const rebaseResult = await exec(
    'git', ['rebase', `origin/${baseBranch}`],
    worktreePath,
  );

  if (rebaseResult.exitCode !== 0) {
    await exec('git', ['rebase', '--abort'], worktreePath);
    return {
      success: false,
      hadConflicts: true,
      error: `conflicts in: ${overlapping.join(', ')}`,
    };
  }

  return { success: true, hadConflicts: true };
}

export async function hasUncommittedChanges(worktreePath: string): Promise<boolean> {
  const result = await exec('git', ['status', '--porcelain'], worktreePath);
  return result.stdout.length > 0;
}
