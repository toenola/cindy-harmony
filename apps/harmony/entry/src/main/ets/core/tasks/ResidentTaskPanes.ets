export class ResidentTaskPane {
  key: string = '';
  deviceId: string = '';
  sessionId: string = '';
  messageClientId: string = '';
}

export class TaskAccountTransition {
  private activeEpoch: number = -1;

  get active(): boolean {
    return this.activeEpoch >= 0;
  }

  begin(epoch: number): void {
    this.activeEpoch = epoch;
  }

  complete(epoch: number): boolean {
    if (this.activeEpoch !== epoch) return false;
    this.activeEpoch = -1;
    return true;
  }
}

export function initialTaskPaneMessage(embedded: boolean, paneMessage: string, routeMessage: string): string {
  return embedded ? paneMessage : routeMessage;
}

export function residentTaskPaneKey(accountEpoch: number, deviceId: string, sessionId: string): string {
  return JSON.stringify([accountEpoch, deviceId, sessionId]);
}

export function residentPaneAllowsPositioning(active: boolean, recovering: boolean): boolean {
  return active && !recovering;
}

export function rememberResidentTaskPane(
  panes: ResidentTaskPane[],
  accountEpoch: number,
  deviceId: string,
  sessionId: string,
  messageClientId: string,
): ResidentTaskPane[] {
  if (deviceId.length === 0 || sessionId.length === 0) return panes;
  const key = residentTaskPaneKey(accountEpoch, deviceId, sessionId);
  const next = panes.filter((pane: ResidentTaskPane): boolean => pane.key !== key);
  const pane = new ResidentTaskPane();
  pane.key = key;
  pane.deviceId = deviceId;
  pane.sessionId = sessionId;
  pane.messageClientId = messageClientId;
  next.push(pane);
  return next.slice(-3);
}

/**
 * 常驻任务是否继续保留。TaskStore 会直接移除已删除的任务，所以找不到任务只在曾经见过、
 * 且该电脑列表仍有数据时才视为已删除；列表为空可能只是尚未加载或断线。当前选中的任务
 * 不在这里释放，否则右栏会在选择切换前变成空白。刚被归档的任务释放，本来就在归档里的保留。
 * `currentStatus` 为 undefined 表示列表里找不到该任务。
 */
export function residentPaneSurvives(
  previousStatus: string | undefined,
  currentStatus: string | undefined,
  deviceSessionCount: number,
  selected: boolean,
): boolean {
  if (currentStatus === undefined) {
    return previousStatus === undefined || deviceSessionCount === 0 || selected;
  }
  return currentStatus !== 'deleted'
    && (currentStatus !== 'archived' || previousStatus === undefined || previousStatus === 'archived');
}

/**
 * 会话 Composer 输入框的组件 ID。双栏会同时挂载多个常驻任务，固定 ID 会让 requestFocus
 * 命中隐藏任务的输入框，所以必须按账号代次、设备与任务区分。
 */
export function taskComposerInputId(accountEpoch: number, deviceId: string, sessionId: string): string {
  return 'task-composer-input:' + encodeURIComponent(JSON.stringify([accountEpoch, deviceId, sessionId]));
}
