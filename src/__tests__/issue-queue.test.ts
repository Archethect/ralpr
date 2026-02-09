import { describe, it, expect, vi, beforeEach } from 'vitest';

const mockExec = vi.fn();
vi.mock('../exec.js', () => ({
  exec: (...args: unknown[]) => mockExec(...args),
}));

import { pollIssueQueue, claimIssue, releaseIssue, addLabel, removeLabel } from '../issue-queue.js';

describe('pollIssueQueue', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('returns empty array on CLI failure', async () => {
    mockExec.mockResolvedValue({ stdout: '', stderr: 'error', exitCode: 1 });
    const issues = await pollIssueQueue('main');
    expect(issues).toEqual([]);
  });

  it('parses issues and sorts by priority', async () => {
    const rawIssues = [
      { number: 1, title: 'Low', labels: [{ name: 'priority:low' }], body: '', assignees: [] },
      { number: 2, title: 'High', labels: [{ name: 'priority:high' }], body: '', assignees: [] },
      { number: 3, title: 'Critical', labels: [{ name: 'priority:critical' }], body: '', assignees: [] },
    ];
    mockExec.mockResolvedValue({ stdout: JSON.stringify(rawIssues), stderr: '', exitCode: 0 });

    const issues = await pollIssueQueue('main');
    expect(issues).toHaveLength(3);
    expect(issues[0].number).toBe(3);
    expect(issues[1].number).toBe(2);
    expect(issues[2].number).toBe(1);
  });

  it('filters out assigned issues', async () => {
    const rawIssues = [
      { number: 1, title: 'Free', labels: [], body: '', assignees: [] },
      { number: 2, title: 'Taken', labels: [], body: '', assignees: [{ login: 'alice' }] },
    ];
    mockExec.mockResolvedValue({ stdout: JSON.stringify(rawIssues), stderr: '', exitCode: 0 });

    const issues = await pollIssueQueue('main');
    expect(issues).toHaveLength(1);
    expect(issues[0].number).toBe(1);
  });

  it('puts issues without priority labels last', async () => {
    const rawIssues = [
      { number: 1, title: 'No prio', labels: [], body: '', assignees: [] },
      { number: 2, title: 'Medium', labels: [{ name: 'priority:medium' }], body: '', assignees: [] },
    ];
    mockExec.mockResolvedValue({ stdout: JSON.stringify(rawIssues), stderr: '', exitCode: 0 });

    const issues = await pollIssueQueue('main');
    expect(issues[0].number).toBe(2);
    expect(issues[1].number).toBe(1);
  });
});

describe('claimIssue', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('returns false when assign fails', async () => {
    mockExec.mockResolvedValue({ stdout: '', stderr: 'error', exitCode: 1 });
    const result = await claimIssue(1);
    expect(result).toBe(false);
  });

  it('returns true when assignment is verified', async () => {
    mockExec
      .mockResolvedValueOnce({ stdout: '', stderr: '', exitCode: 0 })
      .mockResolvedValueOnce({
        stdout: JSON.stringify({ assignees: [{ login: 'me' }] }),
        stderr: '', exitCode: 0,
      })
      .mockResolvedValueOnce({ stdout: 'me', stderr: '', exitCode: 0 });

    const result = await claimIssue(1);
    expect(result).toBe(true);
  });

  it('returns false when not in assignees after claim', async () => {
    mockExec
      .mockResolvedValueOnce({ stdout: '', stderr: '', exitCode: 0 })
      .mockResolvedValueOnce({
        stdout: JSON.stringify({ assignees: [{ login: 'someone-else' }] }),
        stderr: '', exitCode: 0,
      })
      .mockResolvedValueOnce({ stdout: 'me', stderr: '', exitCode: 0 });

    const result = await claimIssue(1);
    expect(result).toBe(false);
  });
});

describe('releaseIssue', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('calls gh issue edit with remove-assignee', async () => {
    mockExec.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });
    await releaseIssue(5);
    expect(mockExec).toHaveBeenCalledWith('gh', [
      'issue', 'edit', '5', '--remove-assignee', '@me',
    ]);
  });
});

describe('addLabel', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('calls gh issue edit to add label', async () => {
    mockExec.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });
    await addLabel(42, 'bug');

    expect(mockExec).toHaveBeenCalledWith('gh', [
      'issue', 'edit', '42', '--add-label', 'bug',
    ]);
  });
});

describe('removeLabel', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('calls gh issue edit to remove label', async () => {
    mockExec.mockResolvedValue({ stdout: '', stderr: '', exitCode: 0 });
    await removeLabel(42, 'bug');

    expect(mockExec).toHaveBeenCalledWith('gh', [
      'issue', 'edit', '42', '--remove-label', 'bug',
    ]);
  });
});
