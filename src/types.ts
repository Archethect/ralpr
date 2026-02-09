/**
 * Ralpr v4 shared types.
 * Used by all orchestrator modules — no runtime dependencies.
 */

export type Tier = 'S' | 'M' | 'L';

export type StageS =
  | 'setup'
  | 'research'
  | 'implement'
  | 'simplify'
  | 'review+codex'
  | 'test'
  | 'pr'
  | 'code-review+codex'
  | 'complete';

export type StageM =
  | 'setup'
  | 'research'
  | 'evaluate'
  | 'plan'
  | 'implement'
  | 'simplify'
  | 'review+codex'
  | 'test'
  | 'pr'
  | 'code-review+codex'
  | 'complete';

export type StageL =
  | 'setup'
  | 'research'
  | 'evaluate'
  | 'plan'
  | 'implement'
  | 'task-review'
  | 'fix'
  | 'simplify'
  | 'review+codex'
  | 'test'
  | 'docs'
  | 'pr'
  | 'spec-review'
  | 'code-review+codex'
  | 'complete';

export type Stage = StageS | StageM | StageL;

export const STAGE_ORDER_S: readonly StageS[] = [
  'setup', 'research', 'implement', 'simplify', 'review+codex',
  'test', 'pr', 'code-review+codex', 'complete',
] as const;

export const STAGE_ORDER_M: readonly StageM[] = [
  'setup', 'research', 'evaluate', 'plan', 'implement', 'simplify',
  'review+codex', 'test', 'pr', 'code-review+codex', 'complete',
] as const;

export const STAGE_ORDER_L: readonly StageL[] = [
  'setup', 'research', 'evaluate', 'plan', 'implement', 'task-review',
  'fix', 'simplify', 'review+codex', 'test', 'docs', 'pr',
  'spec-review', 'code-review+codex', 'complete',
] as const;

export interface TaskPlan {
  id: string;
  title: string;
  status: 'pending' | 'in_progress' | 'done';
}

export interface QualityIterations {
  task_quality: number;
  pr_quality: number;
}

export interface Checkpoint {
  current_stage: Stage;
  tier: Tier;
  completed_tasks: string[];
  committed_shas: string[];
  last_completed_stage: Stage;
  review_verdicts: Record<string, 'pass' | 'fail'>;
  cost_so_far: number;
  plan: TaskPlan[];
  quality_iterations: Record<string, QualityIterations>;
  compact_prompt: string;
  timestamp: string;
}

export interface IssueInfo {
  number: number;
  title: string;
  labels: string[];
  body: string;
  assignees: string[];
}

export interface ContainerInfo {
  name: string;
  issueNumber: number;
  tmuxPane: string;
  worktreePath: string;
  noVncPort: number;
  startedAt: string;
  lastHeartbeat: string;
  costSoFar: number;
  currentStage: Stage | null;
  tier: Tier | null;
}

export type Severity = 'CRITICAL' | 'HIGH' | 'MEDIUM' | 'LOW';

export interface Finding {
  id: string;
  severity: Severity;
  description: string;
  file: string;
  line: number;
  suggestion?: string;
}

export interface StageVerdict {
  stage: Stage;
  task?: string;
  verdict: 'pass' | 'fail';
  iteration: number;
  findings: Finding[];
}

export interface CostEntry {
  issueNumber: number;
  stage: Stage;
  amount: number;
  timestamp: string;
}

export interface DashboardState {
  queueDepth: number;
  activeTeams: ContainerInfo[];
  totalCost: number;
  completionRate: number;
  costPerMergedPr: number;
  issuesCompleted: number;
  avgTimePerTier: Record<Tier, number>;
}
