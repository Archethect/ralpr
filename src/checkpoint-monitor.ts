/**
 * Checkpoint validation.
 * Ensures stage transitions follow the correct order for the tier.
 */

import type { Checkpoint, Tier, Stage } from './types.js';

import {
  STAGE_ORDER_S as ORDER_S,
  STAGE_ORDER_M as ORDER_M,
  STAGE_ORDER_L as ORDER_L,
} from './types.js';

export interface ValidationResult {
  valid: boolean;
  violation?: string;
}

function getStageOrder(tier: Tier): readonly Stage[] {
  switch (tier) {
    case 'S': return ORDER_S as readonly Stage[];
    case 'M': return ORDER_M as readonly Stage[];
    case 'L': return ORDER_L as readonly Stage[];
  }
}

function stageIndex(stage: Stage, order: readonly Stage[]): number {
  return order.indexOf(stage);
}

export function validateCheckpoint(checkpoint: Checkpoint, tier: Tier): ValidationResult {
  const order = getStageOrder(tier);

  if (checkpoint.tier !== tier) {
    return {
      valid: false,
      violation: `checkpoint tier '${checkpoint.tier}' does not match expected '${tier}'`,
    };
  }

  const currentIdx = stageIndex(checkpoint.current_stage, order);
  if (currentIdx === -1) {
    return {
      valid: false,
      violation: `stage '${checkpoint.current_stage}' is not valid for tier ${tier}`,
    };
  }

  const lastIdx = stageIndex(checkpoint.last_completed_stage, order);
  if (lastIdx === -1) {
    return {
      valid: false,
      violation: `last completed stage '${checkpoint.last_completed_stage}' is not valid for tier ${tier}`,
    };
  }

  if (currentIdx < lastIdx) {
    return {
      valid: false,
      violation: `current stage '${checkpoint.current_stage}' (${currentIdx}) is before last completed '${checkpoint.last_completed_stage}' (${lastIdx})`,
    };
  }

  if (currentIdx > lastIdx + 1) {
    const skipped = order.slice(lastIdx + 1, currentIdx);
    return {
      valid: false,
      violation: `stages skipped: ${skipped.join(', ')}`,
    };
  }

  for (const [taskId, iterations] of Object.entries(checkpoint.quality_iterations)) {
    if (iterations.task_quality < 0 || iterations.pr_quality < 0) {
      return {
        valid: false,
        violation: `negative iteration count for task ${taskId}`,
      };
    }
  }

  return { valid: true };
}

export function isTerminalStage(stage: Stage, tier: Tier): boolean {
  const order = getStageOrder(tier);
  return stage === order[order.length - 1];
}

export function nextStage(currentStage: Stage, tier: Tier): Stage | null {
  const order = getStageOrder(tier);
  const idx = stageIndex(currentStage, order);
  if (idx === -1 || idx >= order.length - 1) return null;
  return order[idx + 1];
}
