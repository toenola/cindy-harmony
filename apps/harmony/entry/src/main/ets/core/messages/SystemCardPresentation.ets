/** 系统卡只消费结构化 metadata，禁止把内部 JSON 当普通消息正文展示。 */

export class SystemCardRow {
  label: string = '';
  value: string = '';
}

export class SystemCardPresentation {
  title: string = '';
  subtitle: string = '';
  body: string = '';
  rows: SystemCardRow[] = [];
  danger: boolean = false;
}

export function deriveSystemCardPresentation(
  type: string,
  data: Record<string, Object>,
): SystemCardPresentation {
  const out = new SystemCardPresentation();
  if (type === 'goal-complete') {
    out.title = '目标已完成';
    out.body = firstString(data, ['reason', 'message', 'summary']);
    pushNumberRow(out, '执行轮次', data['turnsUsed']);
    pushDurationRow(out, data['elapsedMs']);
  } else if (type === 'goal-resumed') {
    out.title = readString(data, 'kind') === 'capacity-resumed' ? '目标已恢复推进' : '目标继续执行';
    out.body = firstString(data, ['message', 'reason', 'detail']);
  } else if (type === 'agent-switch') {
    out.title = 'Agent 已切换';
    const from = firstString(data, ['fromAgentKind', 'from']);
    const to = firstString(data, ['toAgentKind', 'to']);
    if (from.length > 0) pushRow(out, '原 Agent', agentLabel(from));
    if (to.length > 0) pushRow(out, '当前 Agent', agentLabel(to));
    const model = firstString(data, ['toModel', 'model']);
    if (model.length > 0) pushRow(out, '模型', model);
    out.subtitle = data['resumed'] === true ? '已接续原任务上下文' : '';
  } else if (type === 'learn') {
    const runId = readString(data, 'runId');
    const error = readString(data, 'error');
    out.danger = error.length > 0;
    out.title = runId.length > 0 ? '技能学习已启动'
      : error === 'learn-busy' ? '已有技能学习正在进行' : '技能学习未启动';
    out.body = firstString(data, ['detail', 'message', 'input']);
    if (runId.length > 0) pushRow(out, '运行编号', runId.slice(0, 8));
  } else if (type === 'compact') {
    out.title = '已自动压缩早期上下文';
  } else if (type === 'help') {
    out.title = '命令帮助';
    out.body = firstString(data, ['text', 'message', 'detail']);
  } else if (type === 'context') {
    out.title = '上下文状态';
    out.body = firstString(data, ['text', 'message', 'detail']);
  } else if (type === 'cost') {
    out.title = '本轮用量';
    out.body = firstString(data, ['text', 'message', 'detail']);
  } else if (type === 'pwd') {
    out.title = '当前工作目录';
    out.body = firstString(data, ['path', 'workingDir', 'text']);
  } else if (type === 'status') {
    out.title = '任务状态';
    out.body = firstString(data, ['text', 'message', 'status']);
  } else if (type === 'cmd') {
    out.title = '命令结果';
    out.body = firstString(data, ['text', 'message', 'detail']);
  } else {
    out.title = type.length > 0 ? type : '系统消息';
    out.body = firstString(data, ['text', 'message', 'detail', 'reason']);
    if (out.body.length === 0 && Object.keys(data).length > 0) {
      out.body = JSON.stringify(data).slice(0, 320);
    }
  }
  return out;
}

function readString(data: Record<string, Object>, key: string): string {
  const value = data[key];
  return typeof value === 'string' ? value as string : '';
}

function firstString(data: Record<string, Object>, keys: string[]): string {
  for (let i = 0; i < keys.length; i++) {
    const value = readString(data, keys[i]);
    if (value.length > 0) return value.slice(0, 4000);
  }
  return '';
}

function pushRow(out: SystemCardPresentation, label: string, value: string): void {
  if (value.length === 0) return;
  const row = new SystemCardRow();
  row.label = label;
  row.value = value;
  out.rows.push(row);
}

function pushNumberRow(out: SystemCardPresentation, label: string, value: Object | undefined): void {
  if (typeof value === 'number' && Number.isFinite(value)) pushRow(out, label, `${Math.floor(value)}`);
}

function pushDurationRow(out: SystemCardPresentation, value: Object | undefined): void {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return;
  const seconds = Math.max(1, Math.round(value / 1000));
  pushRow(out, '耗时', seconds < 60 ? `${seconds} 秒` : `${Math.floor(seconds / 60)} 分 ${seconds % 60} 秒`);
}

function agentLabel(value: string): string {
  if (value === 'cc' || value === 'claude-code') return 'Claude Code';
  if (value === 'codex') return 'Codex';
  if (value === 'pi') return 'Pi';
  return value;
}
