import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { ExecResult } from '../exec.js';

const mockExec = vi.fn();
vi.mock('../exec.js', () => ({
  exec: (...args: unknown[]) => mockExec(...args),
}));

import {
  containerName,
  spawnTeam,
  createTmuxPane,
  stopTeam,
  isContainerRunning,
  getContainerLogs,
  createWorktree,
  removeWorktree,
} from '../team-spawner.js';
import type { RalprConfig } from '../config.js';
import { loadConfig } from '../config.js';

function ok(stdout = ''): ExecResult {
  return { stdout, stderr: '', exitCode: 0 };
}

function makeConfig(overrides: Partial<RalprConfig> = {}): RalprConfig {
  return { ...loadConfig(), ...overrides };
}

describe('containerName', () => {
  it('generates name with prefix and issue number', () => {
    expect(containerName(42)).toBe('ralpr-issue-42');
  });

  it('handles single digit issue', () => {
    expect(containerName(1)).toBe('ralpr-issue-1');
  });

  it('handles large issue number', () => {
    expect(containerName(9999)).toBe('ralpr-issue-9999');
  });
});

describe('spawnTeam', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('constructs docker run command with all env vars', async () => {
    mockExec.mockResolvedValue(ok());
    const config = makeConfig();

    await spawnTeam(42, '/repo/.worktrees/issue-42', config, 6080);

    expect(mockExec).toHaveBeenCalledWith('docker', [
      'run', '-d',
      '--name', 'ralpr-issue-42',
      '-v', '/repo/.worktrees/issue-42:/workspace',
      '-e', 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1',
      '-e', 'RALPR_TEAMMATE_MODE=in-process',
      '-e', 'RALPR_MODEL=opus',
      '-e', 'RALPR_STAGE_MAX_TURNS=50',
      '-e', 'RALPR_TASK_QUALITY_MAX_ITERATIONS=3',
      '-e', 'RALPR_PR_QUALITY_MAX_ITERATIONS=3',
      '-e', 'RALPR_BASE_BRANCH=main',
      '-e', 'RALPR_DEBUG=0',
      '-p', '6080:6080',
      '--workdir', '/workspace',
      'ralpr:latest',
    ]);
  });

  it('maps noVNC port correctly', async () => {
    mockExec.mockResolvedValue(ok());
    await spawnTeam(10, '/worktree', makeConfig(), 6085);

    const args = mockExec.mock.calls[0][1] as string[];
    const portIdx = args.indexOf('-p');
    expect(args[portIdx + 1]).toBe('6085:6080');
  });

  it('returns containerName and exitCode on success', async () => {
    mockExec.mockResolvedValue(ok());
    const result = await spawnTeam(42, '/worktree', makeConfig(), 6080);

    expect(result.containerName).toBe('ralpr-issue-42');
    expect(result.exitCode).toBe(0);
  });

  it('returns non-zero exit code on failure', async () => {
    mockExec.mockResolvedValue({ stdout: '', stderr: 'error', exitCode: 125 });
    const result = await spawnTeam(42, '/worktree', makeConfig(), 6080);
    expect(result.exitCode).toBe(125);
  });

  it('passes debug=1 when debug is enabled', async () => {
    mockExec.mockResolvedValue(ok());
    await spawnTeam(42, '/worktree', makeConfig({ debug: true }), 6080);

    const args = mockExec.mock.calls[0][1] as string[];
    expect(args).toContain('RALPR_DEBUG=1');
  });

  it('passes debug=0 when debug is disabled', async () => {
    mockExec.mockResolvedValue(ok());
    await spawnTeam(42, '/worktree', makeConfig({ debug: false }), 6080);

    const args = mockExec.mock.calls[0][1] as string[];
    expect(args).toContain('RALPR_DEBUG=0');
  });

  it('mounts worktree path to /workspace', async () => {
    mockExec.mockResolvedValue(ok());
    await spawnTeam(5, '/home/user/repo/.worktrees/issue-5', makeConfig(), 6080);

    const args = mockExec.mock.calls[0][1] as string[];
    const vIdx = args.indexOf('-v');
    expect(args[vIdx + 1]).toBe('/home/user/repo/.worktrees/issue-5:/workspace');
  });
});

describe('createTmuxPane', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('creates tmux window tailing docker logs', async () => {
    mockExec.mockResolvedValue(ok());
    const config = makeConfig({ tmuxSession: 'ralpr' });

    const paneId = await createTmuxPane('ralpr-issue-42', config);

    expect(paneId).toBe('ralpr:ralpr-issue-42');
    expect(mockExec).toHaveBeenCalledWith('tmux', [
      'new-window', '-t', 'ralpr',
      '-n', 'ralpr-issue-42',
      'docker', 'logs', '-f', 'ralpr-issue-42',
    ]);
  });

  it('uses custom tmux session name', async () => {
    mockExec.mockResolvedValue(ok());
    const config = makeConfig({ tmuxSession: 'myproject' });

    const paneId = await createTmuxPane('ralpr-issue-1', config);
    expect(paneId).toBe('myproject:ralpr-issue-1');
  });
});

describe('stopTeam', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('stops and force-removes the container', async () => {
    mockExec.mockResolvedValue(ok());
    await stopTeam('ralpr-issue-42');

    expect(mockExec).toHaveBeenCalledTimes(2);
    expect(mockExec).toHaveBeenCalledWith('docker', ['stop', 'ralpr-issue-42']);
    expect(mockExec).toHaveBeenCalledWith('docker', ['rm', '-f', 'ralpr-issue-42']);
  });
});

describe('isContainerRunning', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('returns true when container reports running', async () => {
    mockExec.mockResolvedValue(ok('true'));
    expect(await isContainerRunning('ralpr-issue-42')).toBe(true);
  });

  it('returns false when container reports not running', async () => {
    mockExec.mockResolvedValue(ok('false'));
    expect(await isContainerRunning('ralpr-issue-42')).toBe(false);
  });

  it('returns false when docker inspect fails', async () => {
    mockExec.mockResolvedValue({ stdout: '', stderr: 'not found', exitCode: 1 });
    expect(await isContainerRunning('ralpr-issue-42')).toBe(false);
  });
});

describe('getContainerLogs', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('fetches logs with default tail count', async () => {
    mockExec.mockResolvedValue(ok('log line 1\nlog line 2'));
    const logs = await getContainerLogs('ralpr-issue-42');

    expect(logs).toBe('log line 1\nlog line 2');
    expect(mockExec).toHaveBeenCalledWith('docker', [
      'logs', '--tail', '50', 'ralpr-issue-42',
    ]);
  });

  it('fetches logs with custom tail count', async () => {
    mockExec.mockResolvedValue(ok('last line'));
    await getContainerLogs('ralpr-issue-42', 10);

    expect(mockExec).toHaveBeenCalledWith('docker', [
      'logs', '--tail', '10', 'ralpr-issue-42',
    ]);
  });
});

describe('createWorktree', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('creates worktree with correct branch and path', async () => {
    mockExec.mockResolvedValue(ok());
    const result = await createWorktree('/repo', 42, 'main');

    expect(result.worktreePath).toBe('/repo/.worktrees/issue-42');
    expect(result.exitCode).toBe(0);
    expect(mockExec).toHaveBeenCalledWith(
      'git',
      ['worktree', 'add', '-b', 'ralpr/issue-42', '/repo/.worktrees/issue-42', 'main'],
      '/repo',
    );
  });

  it('returns non-zero exit code on failure', async () => {
    mockExec.mockResolvedValue({ stdout: '', stderr: 'fatal', exitCode: 128 });
    const result = await createWorktree('/repo', 10, 'develop');
    expect(result.exitCode).toBe(128);
  });

  it('uses provided base branch', async () => {
    mockExec.mockResolvedValue(ok());
    await createWorktree('/repo', 5, 'develop');

    const args = mockExec.mock.calls[0][1] as string[];
    expect(args[args.length - 1]).toBe('develop');
  });
});

describe('removeWorktree', () => {
  beforeEach(() => {
    mockExec.mockReset();
  });

  it('force-removes the worktree', async () => {
    mockExec.mockResolvedValue(ok());
    await removeWorktree('/repo', '/repo/.worktrees/issue-42');

    expect(mockExec).toHaveBeenCalledWith(
      'git',
      ['worktree', 'remove', '--force', '/repo/.worktrees/issue-42'],
      '/repo',
    );
  });
});
