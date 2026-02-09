/**
 * Ralpr v4 configuration loader.
 * Loads all env vars from spec Section 19 with defaults.
 * Deterministic — no AI calls.
 */

export interface RalprConfig {
  maxParallelTeams: number;
  issuePollInterval: number;
  prPollInterval: number;
  autoRebase: boolean;
  noVncBasePort: number;
  teammateMode: string;
  tmuxSession: string;
  model: string;
  taskQualityMaxIterations: number;
  prQualityMaxIterations: number;
  baseBranch: string;
  notifyMacOs: boolean;
  forceTier: 'S' | 'M' | 'L' | null;
  containerHeartbeatTimeout: number;
  maxResumeAttempts: number;
  learningEnabled: boolean;
  patternMaxAgeDays: number;
  codexModel: string;
  costWarning: number;
  costHardLimit: number;
  stageMaxTurns: number;
  debug: boolean;
  outputDir: string;
}

function envInt(key: string, fallback: number): number {
  const val = process.env[key];
  if (val === undefined) return fallback;
  const parsed = parseInt(val, 10);
  return Number.isNaN(parsed) ? fallback : parsed;
}

function envBool(key: string, fallback: boolean): boolean {
  const val = process.env[key];
  if (val === undefined) return fallback;
  return val === '1' || val === 'true';
}

function envString(key: string, fallback: string): string {
  return process.env[key] ?? fallback;
}

export function loadConfig(): RalprConfig {
  const forceTierRaw = process.env['RALPR_FORCE_TIER'];
  let forceTier: 'S' | 'M' | 'L' | null = null;
  if (forceTierRaw === 'S' || forceTierRaw === 'M' || forceTierRaw === 'L') {
    forceTier = forceTierRaw;
  }

  return {
    maxParallelTeams: envInt('RALPR_MAX_PARALLEL_TEAMS', 3),
    issuePollInterval: envInt('RALPR_ISSUE_POLL_INTERVAL', 60),
    prPollInterval: envInt('RALPR_PR_POLL_INTERVAL', 30),
    autoRebase: envBool('RALPR_AUTO_REBASE', true),
    noVncBasePort: envInt('RALPR_NOVNC_BASE_PORT', 6080),
    teammateMode: envString('RALPR_TEAMMATE_MODE', 'in-process'),
    tmuxSession: envString('RALPR_TMUX_SESSION', 'ralpr'),
    model: envString('RALPR_MODEL', 'opus'),
    taskQualityMaxIterations: envInt('RALPR_TASK_QUALITY_MAX_ITERATIONS', 3),
    prQualityMaxIterations: envInt('RALPR_PR_QUALITY_MAX_ITERATIONS', 3),
    baseBranch: envString('RALPR_BASE_BRANCH', 'main'),
    notifyMacOs: envBool('RALPR_NOTIFY_MACOS', true),
    forceTier,
    containerHeartbeatTimeout: envInt('RALPR_CONTAINER_HEARTBEAT_TIMEOUT', 300),
    maxResumeAttempts: envInt('RALPR_MAX_RESUME_ATTEMPTS', 2),
    learningEnabled: envBool('RALPR_LEARNING_ENABLED', true),
    patternMaxAgeDays: envInt('RALPR_PATTERN_MAX_AGE_DAYS', 90),
    codexModel: envString('RALPR_CODEX_MODEL', 'gpt-5.2-codex'),
    costWarning: envInt('RALPR_COST_WARNING', 25),
    costHardLimit: envInt('RALPR_COST_HARD_LIMIT', 100),
    stageMaxTurns: envInt('RALPR_STAGE_MAX_TURNS', 50),
    debug: envBool('RALPR_DEBUG', false),
    outputDir: envString('RALPR_OUTPUT_DIR', '.ralpr'),
  };
}
