import { Want } from '@kit.AbilityKit';

export class TaskCompletedPushData {
  version: number = 1;
  type: string = 'task_completed';
  sessionId: string = '';
}

function parseObject(value: Object): TaskCompletedPushData | null {
  const record = value as Record<string, Object>;
  if (record['version'] !== 1 || record['type'] !== 'task_completed') return null;
  const sessionId = record['sessionId'];
  if (typeof sessionId !== 'string') return null;
  const normalized = sessionId.trim();
  if (normalized.length === 0) return null;
  const data = new TaskCompletedPushData();
  data.sessionId = normalized;
  return data;
}

export function parseTaskCompletedPushData(raw: Object | string | undefined): TaskCompletedPushData | null {
  if (raw === undefined) return null;
  if (typeof raw === 'string') {
    const text = raw.trim();
    if (text.length === 0) return null;
    try {
      const parsed = JSON.parse(text) as Object;
      return parseObject(parsed);
    } catch (_) {
      return null;
    }
  }
  return parseObject(raw);
}

/**
 * Push Kit notification click data can arrive either flattened into Want parameters or
 * nested as a JSON string/object. Accept the documented contract without trusting other fields.
 */
export function taskCompletedPushDataFromWant(want: Want): TaskCompletedPushData | null {
  const parameters = want.parameters;
  if (parameters === undefined) return null;
  const direct = parseTaskCompletedPushData(parameters as Object);
  if (direct !== null) return direct;
  const candidates: string[] = ['data', 'pushData', 'payload'];
  const record = parameters as Record<string, Object>;
  for (let i = 0; i < candidates.length; i++) {
    const value = record[candidates[i]];
    const parsed = parseTaskCompletedPushData(value);
    if (parsed !== null) return parsed;
  }
  return null;
}

export function taskSessionDeepLink(data: TaskCompletedPushData): string {
  return `cindy://session/${encodeURIComponent(data.sessionId)}`;
}
