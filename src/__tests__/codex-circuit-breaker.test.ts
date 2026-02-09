import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { ExecResult } from '../exec.js';

vi.mock('../exec.js', () => ({
  exec: vi.fn(),
}));

vi.mock('../issue-queue.js', () => ({
  addLabel: vi.fn(),
  removeLabel: vi.fn(),
}));

import { exec } from '../exec.js';
import { addLabel, removeLabel } from '../issue-queue.js';
import {
  checkCodexAvailability,
  queueAsBlocked,
  allowOverride,
  isBlocked,
  getBlockedIssues,
  retryBlocked,
  resetBlockedState,
} from '../codex-circuit-breaker.js';

const mockExec = vi.mocked(exec);
const mockAddLabel = vi.mocked(addLabel);
const mockRemoveLabel = vi.mocked(removeLabel);

function ok(stdout = ''): ExecResult {
  return { stdout, stderr: '', exitCode: 0 };
}

function fail(stderr = ''): ExecResult {
  return { stdout: '', stderr, exitCode: 1 };
}

describe('codex-circuit-breaker', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    resetBlockedState();
  });

  describe('checkCodexAvailability', () => {
    it('returns true when codex responds successfully', async () => {
      mockExec.mockResolvedValue(ok('test'));
      const result = await checkCodexAvailability();
      expect(result).toBe(true);
      expect(mockExec).toHaveBeenCalledWith('claude', [
        '--print', '-p', 'echo test',
        '--model', 'codex',
      ]);
    });

    it('returns false when codex exits non-zero', async () => {
      mockExec.mockResolvedValue(fail());
      expect(await checkCodexAvailability()).toBe(false);
    });

    it('returns false when stdout lacks expected output', async () => {
      mockExec.mockResolvedValue(ok('error: model not available'));
      expect(await checkCodexAvailability()).toBe(false);
    });

    it('returns false when both conditions fail', async () => {
      mockExec.mockResolvedValue({ stdout: '', stderr: 'timeout', exitCode: 127 });
      expect(await checkCodexAvailability()).toBe(false);
    });
  });

  describe('queueAsBlocked', () => {
    it('marks issue as blocked and adds gh label', async () => {
      mockAddLabel.mockResolvedValue(undefined);
      await queueAsBlocked(42);

      expect(isBlocked(42)).toBe(true);
      expect(mockAddLabel).toHaveBeenCalledWith(42, 'blocked:codex');
    });

    it('tracks multiple blocked issues', async () => {
      mockAddLabel.mockResolvedValue(undefined);
      await queueAsBlocked(1);
      await queueAsBlocked(2);
      await queueAsBlocked(3);

      expect(getBlockedIssues()).toHaveLength(3);
      expect(getBlockedIssues()).toEqual(expect.arrayContaining([1, 2, 3]));
    });

    it('is idempotent for same issue', async () => {
      mockAddLabel.mockResolvedValue(undefined);
      await queueAsBlocked(42);
      await queueAsBlocked(42);

      expect(getBlockedIssues()).toHaveLength(1);
    });
  });

  describe('allowOverride', () => {
    it('removes blocked label and adds codex-skipped label', async () => {
      mockAddLabel.mockResolvedValue(undefined);
      mockRemoveLabel.mockResolvedValue(undefined);

      await queueAsBlocked(42);
      const result = await allowOverride(42);

      expect(result).toBe(true);
      expect(isBlocked(42)).toBe(false);
      expect(mockRemoveLabel).toHaveBeenCalledWith(42, 'blocked:codex');
      expect(mockAddLabel).toHaveBeenCalledWith(42, 'codex-skipped');
    });
  });

  describe('state tracking', () => {
    it('starts with no blocked issues', () => {
      expect(getBlockedIssues()).toEqual([]);
    });

    it('reports unblocked for unknown issue', () => {
      expect(isBlocked(999)).toBe(false);
    });

    it('resetBlockedState clears all blocked issues', async () => {
      mockAddLabel.mockResolvedValue(undefined);
      await queueAsBlocked(1);
      await queueAsBlocked(2);

      resetBlockedState();

      expect(getBlockedIssues()).toEqual([]);
      expect(isBlocked(1)).toBe(false);
      expect(isBlocked(2)).toBe(false);
    });
  });

  describe('retryBlocked', () => {
    it('unblocks all issues when codex becomes available', async () => {
      mockAddLabel.mockResolvedValue(undefined);
      mockRemoveLabel.mockResolvedValue(undefined);

      await queueAsBlocked(10);
      await queueAsBlocked(20);

      mockExec.mockResolvedValue(ok('test'));
      const unblocked = await retryBlocked();

      expect(unblocked).toEqual(expect.arrayContaining([10, 20]));
      expect(getBlockedIssues()).toEqual([]);
      expect(mockRemoveLabel).toHaveBeenCalledWith(10, 'blocked:codex');
      expect(mockRemoveLabel).toHaveBeenCalledWith(20, 'blocked:codex');
    });

    it('returns empty array when codex is still unavailable', async () => {
      mockAddLabel.mockResolvedValue(undefined);
      await queueAsBlocked(10);

      mockExec.mockResolvedValue(fail());
      const unblocked = await retryBlocked();

      expect(unblocked).toEqual([]);
      expect(isBlocked(10)).toBe(true);
    });

    it('returns empty array when no issues are blocked', async () => {
      mockExec.mockResolvedValue(ok('test'));
      const unblocked = await retryBlocked();
      expect(unblocked).toEqual([]);
    });
  });
});
