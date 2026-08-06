/**
 * 目标模式状态模型（对齐 Desktop goal-host / Mobile GoalStatusPayload）。
 */

import { readNum, readStr } from '../tasks/TaskModels';

export class GoalModeState {
  sessionId: string = '';
  objective: string = '';
  status: string = '';
  currentTurns: number = 0;
  cumulativeTokens: number = 0;
  /** -1 表示未设置上限。 */
  maxTurns: number = -1;
  /** -1 表示未设置上限。 */
  budgetTokens: number = -1;
  noProgressLimit: number = 3;
  lastReason: string = '';
  lastError: string = '';
}

function readOptionalLimit(raw: Record<string, Object>, key: string): number {
  const value = raw[key];
  return typeof value === 'number' ? value : -1;
}

/** null / undefined 表示当前任务没有目标。 */
export function parseGoalModeState(raw: Object | undefined): GoalModeState | null {
  if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    return null;
  }
  const record = raw as Record<string, Object>;
  const state = new GoalModeState();
  state.sessionId = readStr(record, 'sessionId');
  state.objective = readStr(record, 'objective');
  state.status = readStr(record, 'status');
  state.currentTurns = readNum(record, 'turnsUsed', 0);
  state.cumulativeTokens = readNum(record, 'tokensUsed', 0);
  state.maxTurns = readOptionalLimit(record, 'maxTurns');
  state.budgetTokens = readOptionalLimit(record, 'budgetTokens');
  state.noProgressLimit = readNum(record, 'noProgressLimit', 3);
  state.lastReason = readStr(record, 'lastReason');
  state.lastError = readStr(record, 'lastError');
  return state;
}
