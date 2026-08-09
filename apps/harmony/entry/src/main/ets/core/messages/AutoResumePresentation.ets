import { RemoteMessage, readStr } from '../tasks/TaskModels';

export class AutoResumePresentation {
  state: string = 'separator'; // separator | live | succeeded | failed | neutral
  error: string = '';
  summary: string = '';
  attempt: number = -1;
  maxAttempts: number = -1;
  sessionTotal: number = -1;
  canExpand: boolean = false;
}

function positiveNumber(data: Record<string, Object>, key: string): number {
  const value = data[key];
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : -1;
}

/** 自动续跑错误只在摘要行压成一句；展开后始终保留原始详情。 */
export function summarizeAutoResumeError(detail: string): string {
  if (detail.trim().length === 0) return '';
  const compact = detail.replace(/^\s*API Error:\s*/i, '').replace(/\s+/g, ' ').trim();
  if (compact.length === 0) return '';
  const sentence = compact.match(/^.*?[.。!?！？](?=\s|$)/);
  const first = sentence !== null && sentence.length > 0 ? sentence[0] : compact;
  return first.length > 72 ? `${first.slice(0, 71)}…` : first;
}

export function deriveAutoResumePresentation(
  data: Record<string, Object>,
  inFlight: boolean,
): AutoResumePresentation {
  const out = new AutoResumePresentation();
  const rawError = data['error'];
  out.error = typeof rawError === 'string' && rawError.trim().length > 0 ? rawError : '';
  out.summary = summarizeAutoResumeError(out.error);
  out.attempt = positiveNumber(data, 'attempt');
  out.maxAttempts = positiveNumber(data, 'maxAttempts');
  out.sessionTotal = positiveNumber(data, 'sessionTotal');
  const hasProgress = out.attempt > 0 && out.maxAttempts > 0;
  const outcome = readStr(data, 'outcome');
  const terminalOutcome = outcome === 'succeeded' || outcome === 'failed' ? outcome : '';
  const hasContext = data['live'] === true || out.error.length > 0 || hasProgress
    || out.sessionTotal > 0 || terminalOutcome.length > 0;
  if (!hasContext) {
    out.state = 'separator';
  } else if (terminalOutcome.length > 0) {
    out.state = terminalOutcome;
  } else if (data['live'] === true || inFlight) {
    out.state = 'live';
  } else {
    out.state = 'neutral';
  }
  out.canExpand = out.error.length > 0 || hasProgress || out.sessionTotal > 0;
  return out;
}

export function isAutoResumeRowInFlight(
  clientId: string,
  continuationTurnClientId: string,
  capability: string,
  makerTurnRunning: boolean,
  isLastUserInput: boolean,
): boolean {
  if (continuationTurnClientId.length > 0) return clientId === continuationTurnClientId;
  return capability === 'legacy' && makerTurnRunning && isLastUserInput;
}

/** 把 projection 的 pending 状态合成与持久消息同形的一行，统一走同一渲染管线。 */
export function appendAutoResumePendingMessage(
  messages: RemoteMessage[],
  pending: Record<string, Object> | undefined,
): RemoteMessage[] {
  if (pending === undefined) return messages;
  const stableId = 'harmony:auto-resume-pending';
  const next = messages.filter((message: RemoteMessage) =>
    message.id !== stableId && message.clientId !== stableId);
  let createdAt = '';
  if (next.length > 0) {
    const lastMs = Date.parse(next[next.length - 1].createdAt);
    if (!Number.isNaN(lastMs)) createdAt = new Date(lastMs + 1).toISOString();
  }
  const data: Record<string, Object> = {};
  const keys = Object.keys(pending);
  for (let i = 0; i < keys.length; i++) data[keys[i]] = pending[keys[i]];
  data['live'] = true;
  const message = new RemoteMessage();
  message.id = stableId;
  message.clientId = stableId;
  message.role = 'user';
  message.content = '';
  message.createdAt = createdAt;
  message.systemCardType = 'auto-resume';
  message.systemCardData = data;
  message.agentMeta['autoResume'] = true;
  message.agentMeta['autoResumeInfo'] = data;
  message.isSyntheticTrigger = true;
  next.push(message);
  return next;
}
