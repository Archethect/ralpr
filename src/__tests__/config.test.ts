import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { loadConfig } from '../config.js';

describe('loadConfig', () => {
  const originalEnv = { ...process.env };

  afterEach(() => {
    process.env = { ...originalEnv };
  });

  it('returns defaults when no env vars set', () => {
    const config = loadConfig();
    expect(config.maxParallelTeams).toBe(3);
    expect(config.issuePollInterval).toBe(60);
    expect(config.prPollInterval).toBe(30);
    expect(config.autoRebase).toBe(true);
    expect(config.noVncBasePort).toBe(6080);
    expect(config.teammateMode).toBe('in-process');
    expect(config.tmuxSession).toBe('ralpr');
    expect(config.model).toBe('opus');
    expect(config.baseBranch).toBe('main');
    expect(config.notifyMacOs).toBe(true);
    expect(config.forceTier).toBeNull();
    expect(config.containerHeartbeatTimeout).toBe(300);
    expect(config.maxResumeAttempts).toBe(2);
    expect(config.costWarning).toBe(25);
    expect(config.costHardLimit).toBe(100);
    expect(config.debug).toBe(false);
  });

  it('reads integer env vars', () => {
    process.env['RALPR_MAX_PARALLEL_TEAMS'] = '5';
    process.env['RALPR_ISSUE_POLL_INTERVAL'] = '120';
    const config = loadConfig();
    expect(config.maxParallelTeams).toBe(5);
    expect(config.issuePollInterval).toBe(120);
  });

  it('falls back on invalid integer', () => {
    process.env['RALPR_MAX_PARALLEL_TEAMS'] = 'abc';
    const config = loadConfig();
    expect(config.maxParallelTeams).toBe(3);
  });

  it('reads boolean env vars', () => {
    process.env['RALPR_AUTO_REBASE'] = '0';
    process.env['RALPR_DEBUG'] = '1';
    const config = loadConfig();
    expect(config.autoRebase).toBe(false);
    expect(config.debug).toBe(true);
  });

  it('reads boolean "true" string', () => {
    process.env['RALPR_DEBUG'] = 'true';
    const config = loadConfig();
    expect(config.debug).toBe(true);
  });

  it('reads string env vars', () => {
    process.env['RALPR_BASE_BRANCH'] = 'develop';
    process.env['RALPR_MODEL'] = 'sonnet';
    const config = loadConfig();
    expect(config.baseBranch).toBe('develop');
    expect(config.model).toBe('sonnet');
  });

  it('parses valid force tier S/M/L', () => {
    process.env['RALPR_FORCE_TIER'] = 'M';
    const config = loadConfig();
    expect(config.forceTier).toBe('M');
  });

  it('ignores invalid force tier', () => {
    process.env['RALPR_FORCE_TIER'] = 'XL';
    const config = loadConfig();
    expect(config.forceTier).toBeNull();
  });
});
