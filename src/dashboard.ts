/**
 * TUI dashboard renderer.
 * Shows queue depth, active teams, costs, completion metrics.
 */

import type { DashboardState, ContainerInfo, Tier } from './types.js';

const DIVIDER = '─'.repeat(60);
const HEADER = ' RALPR v4 Dashboard ';

function pad(str: string, len: number): string {
  return str.length >= len ? str.slice(0, len) : str + ' '.repeat(len - str.length);
}

function formatCost(amount: number): string {
  return `$${amount.toFixed(2)}`;
}

function formatDuration(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`;
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`;
  return `${(seconds / 3600).toFixed(1)}h`;
}

function renderTeamRow(team: ContainerInfo): string {
  const issue = `#${team.issueNumber}`;
  const stage = team.currentStage ?? 'unknown';
  const tier = team.tier ?? '?';
  const cost = formatCost(team.costSoFar);
  return `  ${pad(issue, 8)} ${pad(`[${tier}]`, 5)} ${pad(stage, 20)} ${cost}`;
}

function renderTierAvg(avgTimePerTier: Record<Tier, number>): string {
  const tiers: Tier[] = ['S', 'M', 'L'];
  return tiers
    .map((t) => `${t}: ${formatDuration(avgTimePerTier[t] ?? 0)}`)
    .join('  |  ');
}

export function renderDashboard(state: DashboardState): string {
  const lines: string[] = [];

  lines.push('');
  lines.push(`${DIVIDER}`);
  lines.push(`${HEADER}`);
  lines.push(`${DIVIDER}`);
  lines.push('');

  lines.push(`  Queue depth:     ${state.queueDepth}`);
  lines.push(`  Active teams:    ${state.activeTeams.length}`);
  lines.push(`  Total cost:      ${formatCost(state.totalCost)}`);
  lines.push(`  Completed:       ${state.issuesCompleted}`);
  lines.push(`  Completion rate: ${(state.completionRate * 100).toFixed(0)}%`);
  lines.push(`  Cost/merged PR:  ${formatCost(state.costPerMergedPr)}`);
  lines.push('');

  lines.push(`  Avg time per tier:  ${renderTierAvg(state.avgTimePerTier)}`);
  lines.push('');

  if (state.activeTeams.length > 0) {
    lines.push(`  ${pad('Issue', 8)} ${pad('Tier', 5)} ${pad('Stage', 20)} Cost`);
    lines.push(`  ${'-'.repeat(45)}`);
    for (const team of state.activeTeams) {
      lines.push(renderTeamRow(team));
    }
  } else {
    lines.push('  No active teams. Waiting for issues...');
  }

  lines.push('');
  lines.push(`${DIVIDER}`);
  lines.push(`  Last updated: ${new Date().toLocaleTimeString()}`);
  lines.push('');

  return lines.join('\n');
}

export function clearAndRender(state: DashboardState): void {
  process.stdout.write('\x1B[2J\x1B[H');
  process.stdout.write(renderDashboard(state));
}
