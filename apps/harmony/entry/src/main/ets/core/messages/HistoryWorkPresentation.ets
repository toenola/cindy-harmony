import { RemoteMessage, readBool, readObj, readStr, recordOrEmpty } from '../tasks/TaskModels';

export class HistoryWorkPresentation {
  key: string = '';
  messageId: string = '';
  anchorClientId: string = '';
  revision: string = '';
  summary: Record<string, Object> = {};
  lines: Record<string, Object>[] = [];
  artifacts: Record<string, Object>[] = [];
  model: string = '';
  parentToolUseId: string = '';
  expanded: boolean = false;
  loading: boolean = false;
  failed: boolean = false;
  complete: boolean = false;
  awaitingDetails: boolean = true;
}

export function historyWorkSummary(message: RemoteMessage): Record<string, Object> {
  return readObj(message.agentMeta, 'historyWork');
}

export function hasHistoryWorkReference(summary: Record<string, Object>): boolean {
  return readStr(summary, 'key').length > 0 && readStr(summary, 'firstMessageId').length > 0
    && readStr(summary, 'lastMessageId').length > 0;
}

export function historyWorkReferenceIdentity(summary: Record<string, Object>): string {
  return JSON.stringify([readStr(summary, 'key'), readStr(summary, 'revision'),
    readStr(summary, 'firstMessageId'), readStr(summary, 'lastMessageId'),
    readStr(summary, 'firstStoredMessageId'), readStr(summary, 'lastStoredMessageId'),
    readStr(summary, 'parentToolUseId'), summary['liveMessageIds'] ?? []]);
}

export function historyWorkRecords(value: Object | undefined): Record<string, Object>[] {
  if (!Array.isArray(value)) return [];
  return (value as Object[]).map((entry: Object): Record<string, Object> => recordOrEmpty(entry));
}

export function projectHistoryWorkPresentation(message: RemoteMessage, state: string,
  expanded: boolean, body: RemoteMessage[]): HistoryWorkPresentation {
  const presentation = new HistoryWorkPresentation();
  const summary = historyWorkSummary(message);
  presentation.summary = summary;
  presentation.key = readStr(summary, 'key');
  presentation.messageId = message.id;
  presentation.anchorClientId = readStr(summary, 'anchorClientId') || message.clientId;
  presentation.revision = readStr(summary, 'revision');
  presentation.lines = historyWorkRecords(summary['lines']);
  presentation.artifacts = historyWorkRecords(summary['artifacts']);
  presentation.model = readStr(summary, 'model');
  presentation.parentToolUseId = readStr(summary, 'parentToolUseId');
  presentation.expanded = expanded;
  presentation.loading = state === 'loading';
  presentation.failed = state === 'failed';
  presentation.complete = state === 'complete';
  presentation.awaitingDetails = !presentation.complete && body.length === 0;
  return presentation;
}

export function historyDetailWindow(summary: Record<string, Object>, body: RemoteMessage[]): RemoteMessage[] {
  if (!hasHistoryWorkReference(summary)) return [];
  const matches = (row: RemoteMessage, id: string): boolean => row.id === id
    || (id.startsWith('history-live:') && row.clientId === id.slice('history-live:'.length));
  const first = body.findIndex((row: RemoteMessage) => matches(row, readStr(summary, 'firstMessageId')));
  const last = body.findIndex((row: RemoteMessage) => matches(row, readStr(summary, 'lastMessageId')));
  if (first < 0) return [];
  return body.slice(first, last < first ? undefined : last + 1);
}

export function canApplyHistoryWorkPatch(message: RemoteMessage, value: Object): boolean {
  const patch = recordOrEmpty(value);
  const item = readObj(patch, 'item');
  const summary = readObj(item, 'summary');
  const current = historyWorkSummary(message);
  return patch['version'] === 1 && item['type'] === 'work' && !Array.isArray(item['children'])
    && hasHistoryWorkReference(current) && hasHistoryWorkReference(summary)
    && readBool(message.agentMeta, 'historyWorkPatchable', false)
    && readStr(patch, 'baseRevision').length > 0
    && readStr(current, 'revision') === readStr(patch, 'baseRevision')
    && readStr(item, 'key') === readStr(current, 'key')
    && readStr(summary, 'key') === readStr(current, 'key')
    && readStr(summary, 'revision').length > 0
    && readStr(summary, 'firstMessageId') === readStr(current, 'firstMessageId')
    && readStr(summary, 'lastMessageId').length > 0
    && readStr(summary, 'parentToolUseId') === readStr(current, 'parentToolUseId');
}
