/**
 * Ralpr v4 main orchestrator.
 * Polls issue queue, spawns Agent Teams, monitors heartbeats, handles shutdown.
 */
import { loadConfig, type RalprConfig } from './config.js';
import { pollIssueQueue, claimIssue, releaseIssue } from './issue-queue.js';
import { spawnTeam, createTmuxPane, stopTeam, isContainerRunning, createWorktree, removeWorktree } from './team-spawner.js';
import { pollPrComments, routeToContainer, getPrNumberForBranch } from './pr-monitor.js';
import { checkAndRebase } from './auto-rebase.js';
import { notifyMacOs, getGlobalTotalCost } from './cost-tracker.js';
import { clearAndRender } from './dashboard.js';
import { retryBlocked } from './codex-circuit-breaker.js';
import type { ContainerInfo, DashboardState } from './types.js';

const activeTeams: Map<number, ContainerInfo> = new Map();
const prSeenComments: Map<number, Set<string>> = new Map();
let isShuttingDown = false;
const resumeAttempts: Map<number, number> = new Map();

function log(msg: string): void {
  console.error(`[${new Date().toISOString()}] ${msg}`);
}

function sleep(seconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, seconds * 1000));
}

async function cleanupTeam(issueNumber: number, repoRoot: string): Promise<void> {
  const team = activeTeams.get(issueNumber);
  if (!team) return;
  await stopTeam(team.name);
  await removeWorktree(repoRoot, team.worktreePath);
  await releaseIssue(issueNumber);
  activeTeams.delete(issueNumber);
  resumeAttempts.delete(issueNumber);
  log(`Cleaned up team for #${issueNumber}`);
}

async function handleIssue(issueNumber: number, config: RalprConfig, repoRoot: string): Promise<void> {
  const claimed = await claimIssue(issueNumber);
  if (!claimed) { log(`Failed to claim #${issueNumber}`); return; }
  log(`Claimed issue #${issueNumber}`);

  const noVncPort = config.noVncBasePort + activeTeams.size;
  const { worktreePath, exitCode: wtExit } = await createWorktree(repoRoot, issueNumber, config.baseBranch);
  if (wtExit !== 0) { log(`Worktree failed for #${issueNumber}`); await releaseIssue(issueNumber); return; }

  const { containerName: ctrName, exitCode } = await spawnTeam(issueNumber, worktreePath, config, noVncPort);
  if (exitCode !== 0) {
    log(`Spawn failed for #${issueNumber}`);
    await releaseIssue(issueNumber); await removeWorktree(repoRoot, worktreePath); return;
  }

  const paneId = await createTmuxPane(ctrName, config);
  const now = new Date().toISOString();
  activeTeams.set(issueNumber, {
    name: ctrName, issueNumber, tmuxPane: paneId, worktreePath,
    noVncPort, startedAt: now, lastHeartbeat: now, costSoFar: 0,
    currentStage: null, tier: null,
  });
  log(`Team spawned for #${issueNumber} -> ${ctrName}`);
}

async function checkHeartbeats(config: RalprConfig, repoRoot: string): Promise<void> {
  const now = Date.now();
  const timeoutMs = config.containerHeartbeatTimeout * 1000;

  for (const [issueNumber, team] of activeTeams) {
    const running = await isContainerRunning(team.name);
    if (!running) {
      const attempts = resumeAttempts.get(issueNumber) ?? 0;
      if (attempts < config.maxResumeAttempts) {
        log(`Container ${team.name} died, resume ${attempts + 1}/${config.maxResumeAttempts}`);
        resumeAttempts.set(issueNumber, attempts + 1);
        const { exitCode } = await spawnTeam(issueNumber, team.worktreePath, config, team.noVncPort);
        if (exitCode === 0) { team.lastHeartbeat = new Date().toISOString(); continue; }
      }
      log(`Giving up on #${issueNumber} after ${attempts + 1} attempts`);
      await cleanupTeam(issueNumber, repoRoot);
      continue;
    }
    const lastBeat = new Date(team.lastHeartbeat).getTime();
    if (now - lastBeat > timeoutMs) {
      log(`Heartbeat timeout for #${issueNumber}`);
      await cleanupTeam(issueNumber, repoRoot);
    }
  }
}

async function pollComments(): Promise<void> {
  for (const [issueNumber, team] of activeTeams) {
    const prNumber = await getPrNumberForBranch(`ralpr/issue-${issueNumber}`);
    if (!prNumber) continue;
    const seenIds = prSeenComments.get(prNumber) ?? new Set();
    const { comments, newSeenIds } = await pollPrComments(prNumber, seenIds);
    prSeenComments.set(prNumber, newSeenIds);
    for (const comment of comments) {
      log(`Routing comment from ${comment.author} to ${team.name}`);
      await routeToContainer(team.name, comment);
    }
  }
}

async function handleAutoRebase(config: RalprConfig): Promise<void> {
  if (!config.autoRebase) return;
  for (const [issueNumber, team] of activeTeams) {
    const result = await checkAndRebase(team.worktreePath, config.baseBranch);
    if (!result.success && result.hadConflicts) {
      log(`Rebase conflict for #${issueNumber}: ${result.error}`);
      if (config.notifyMacOs) await notifyMacOs(`Rebase conflict on issue #${issueNumber}`);
    }
  }
}

function buildDashboardState(): DashboardState {
  return {
    queueDepth: 0, activeTeams: [...activeTeams.values()],
    totalCost: getGlobalTotalCost(), completionRate: 0,
    costPerMergedPr: 0, issuesCompleted: 0,
    avgTimePerTier: { S: 0, M: 0, L: 0 },
  };
}

async function mainLoop(config: RalprConfig, repoRoot: string): Promise<void> {
  log('Ralpr v4 orchestrator starting');
  while (!isShuttingDown) {
    const issues = await pollIssueQueue(config.baseBranch);
    const available = issues.filter((i) => !activeTeams.has(i.number));
    const slots = config.maxParallelTeams - activeTeams.size;
    for (let i = 0; i < Math.min(available.length, slots); i++) {
      await handleIssue(available[i].number, config, repoRoot);
    }
    await checkHeartbeats(config, repoRoot);
    await pollComments();
    await handleAutoRebase(config);
    await retryBlocked();
    clearAndRender(buildDashboardState());
    await sleep(config.issuePollInterval);
  }
}

async function gracefulShutdown(repoRoot: string): Promise<void> {
  log('Graceful shutdown initiated');
  isShuttingDown = true;
  for (const issueNumber of activeTeams.keys()) {
    await cleanupTeam(issueNumber, repoRoot);
  }
  log('All teams stopped. Exiting.');
  process.exit(0);
}

export async function start(): Promise<void> {
  const config = loadConfig();
  const repoRoot = process.cwd();
  process.on('SIGTERM', () => gracefulShutdown(repoRoot));
  process.on('SIGINT', () => gracefulShutdown(repoRoot));
  await mainLoop(config, repoRoot);
}

if (process.argv[1]?.endsWith('orchestrator.ts') || process.argv[1]?.endsWith('orchestrator.js')) {
  start().catch((err) => { console.error('Fatal error:', err); process.exit(1); });
}
