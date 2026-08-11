/** 任务列表 anti-entropy：push 是主路径，前台低频权威对账只负责最终收敛。 */

export const TASK_LIST_RECONCILE_INTERVAL_MS: number = 10_000;
const TASK_LIST_RECONCILE_MAX_BACKOFF_MS: number = 120_000;

class TaskListReconcileState {
  failures: number = 0;
  nextEligibleAt: number = 0;
}

/**
 * 按设备记录失败退避，避免固定 10 秒轮询在弱网下叠加成长时间超时风暴。
 * 成功立即复位；不同设备互不连坐。
 */
export class TaskListReconcileBackoff {
  private states: Map<string, TaskListReconcileState> = new Map();

  shouldAttempt(deviceId: string, now: number = Date.now()): boolean {
    const state = this.states.get(deviceId);
    return state === undefined || now >= state.nextEligibleAt;
  }

  report(deviceId: string, success: boolean, now: number = Date.now(), random: number = Math.random()): void {
    if (success) {
      this.states.delete(deviceId);
      return;
    }
    const previous = this.states.get(deviceId);
    const state = previous ?? new TaskListReconcileState();
    state.failures += 1;
    const baseDelay = Math.min(
      TASK_LIST_RECONCILE_INTERVAL_MS * Math.pow(2, Math.max(0, state.failures - 1)),
      TASK_LIST_RECONCILE_MAX_BACKOFF_MS,
    );
    // ±15% 抖动打散多电脑齐步请求；封顶仍严格保持 2 分钟。
    const normalizedRandom = Math.min(1, Math.max(0, random));
    const jittered = Math.round(baseDelay * (0.85 + normalizedRandom * 0.3));
    state.nextEligibleAt = now + Math.min(jittered, TASK_LIST_RECONCILE_MAX_BACKOFF_MS);
    this.states.set(deviceId, state);
  }

  retainOnly(deviceIds: Set<string>): void {
    const stale: string[] = [];
    this.states.forEach((_state: TaskListReconcileState, deviceId: string) => {
      if (!deviceIds.has(deviceId)) stale.push(deviceId);
    });
    for (let i = 0; i < stale.length; i++) this.states.delete(stale[i]);
  }

  clear(): void {
    this.states.clear();
  }
}
