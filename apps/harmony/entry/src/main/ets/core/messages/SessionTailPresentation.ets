import { RemoteMessage, RemoteSession } from '../tasks/TaskModels';

export const CONTINUE_AFTER_APP_EXIT_PROMPT =
  '[UI_ACTION_TRIGGER] The previous turn was interrupted because the app exited mid-run.'
  + ' Review the conversation above to determine how far the task progressed,'
  + ' then continue from where it left off.'
  + ' Do not repeat steps that already completed and had external effects'
  + ' (messages or comments already sent, commits already pushed, files already written).';

export const CONTINUE_AFTER_ERROR_PROMPT =
  '[UI_ACTION_TRIGGER] The previous turn errored partway through.'
  + ' Review the conversation above to determine how far the task progressed,'
  + ' then continue from where it left off.'
  + ' Do not repeat steps that already completed and had external effects'
  + ' (messages or comments already sent, commits already pushed, files already written).';

export class SessionTailPresentation {
  kind: string = '';
  clientId: string = '';
  text: string = '';
  interrupted: boolean = false;
  retryable: boolean = true;
}

export function isContinuationText(text: string): boolean {
  return text === CONTINUE_AFTER_APP_EXIT_PROMPT || text === CONTINUE_AFTER_ERROR_PROMPT;
}

export function findErrorTailClientId(messages: RemoteMessage[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    if (message.localOnly) continue;
    if (message.role !== 'error') return '';
    const content = errorContent(message.content);
    if (content.dismissed) return '';
    return message.clientId.length > 0 ? message.clientId : message.id;
  }
  return '';
}

export function deriveSessionTailPresentation(
  messages: RemoteMessage[],
  session: RemoteSession | undefined,
  projectionError: string,
  credentialSwitchWaiting: boolean,
  streaming: boolean,
  continuationInFlight: boolean,
  interruptAcked: boolean,
  hiddenErrorClientIds: string[],
): SessionTailPresentation | null {
  if (projectionError.length > 0 || credentialSwitchWaiting
    || streaming || continuationInFlight) return null;
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    if (message.localOnly) continue;
    if (message.role !== 'error') break;
    const content = errorContent(message.content);
    const clientId = message.clientId.length > 0 ? message.clientId : message.id;
    if (content.dismissed || hiddenErrorClientIds.includes(clientId)) return null;
    const out = new SessionTailPresentation();
    out.kind = 'error-tail';
    out.clientId = clientId;
    out.text = content.text;
    out.interrupted = content.reason === 'app-exit-interrupted';
    out.retryable = !isNonRetryableError(content.text);
    if (!out.retryable) out.text = nonRetryableGuidance(content.text);
    return out;
  }
  if (interruptAcked || session === undefined || session.activeTurnStartedAt <= 0) return null;
  const clearedAt = session.clearedAt.length > 0 ? Date.parse(session.clearedAt) : 0;
  if (session.activeTurnStartedAt > session.lastTurnEndedAt
    && session.activeTurnStartedAt > (Number.isFinite(clearedAt) ? clearedAt : 0)) {
    const out = new SessionTailPresentation();
    out.kind = 'interrupted';
    out.interrupted = true;
    out.text = '上一次执行可能在应用退出时中断。';
    return out;
  }
  return null;
}

class ErrorTailContent {
  text: string = '';
  reason: string = '';
  dismissed: boolean = false;
}

function errorContent(value: Object | undefined): ErrorTailContent {
  const out = new ErrorTailContent();
  let record: Record<string, Object> | null = null;
  if (typeof value === 'string') {
    out.text = value;
    try {
      const parsed = JSON.parse(value) as Object;
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        record = parsed as Record<string, Object>;
      }
    } catch (e) {
      return out;
    }
  } else if (value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value)) {
    record = value as Record<string, Object>;
  }
  if (record === null) return out;
  if (typeof record['message'] === 'string') out.text = record['message'] as string;
  else if (typeof record['text'] === 'string') out.text = record['text'] as string;
  if (typeof record['reason'] === 'string') out.reason = record['reason'] as string;
  out.dismissed = record['dismissed'] === true;
  return out;
}

function isNonRetryableError(text: string): boolean {
  return /thread not found|invalid_encrypted_content|not authenticated|unauthorized|please login/i.test(text);
}

function nonRetryableGuidance(text: string): string {
  if (/thread not found/i.test(text)) return '原有 Codex 线程已失效，请回到电脑端新建任务继续。';
  if (/invalid_encrypted_content/i.test(text)) return '当前加密内容无法由新供应商继续，请回到电脑端处理。';
  return '电脑端 Agent 尚未完成登录，请先在电脑上完成授权。';
}
