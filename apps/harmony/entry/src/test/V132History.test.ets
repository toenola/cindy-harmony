import { describe, expect, it } from '@ohos/hypium';
import { DlClient, DlClientOptions, DlInvokeOptions } from '../main/ets/core/device-link/DlClient';
import { Envelope } from '../main/ets/core/device-link/DlProtocol';
import { HistoryViewAdapter, parseHistoryProjection } from '../main/ets/core/messages/HistoryViewAdapter';
import {
  canApplyHistoryWorkPatch, hasHistoryWorkReference, historyDetailWindow, historyWorkReferenceIdentity,
  projectHistoryWorkPresentation,
} from '../main/ets/core/messages/HistoryWorkPresentation';
import { MessageStore } from '../main/ets/core/messages/MessageStore';
import { formatHistoryWorkLine } from '../main/ets/core/messages/HistoryLinePresentation';
import { canFollowLatest } from '../main/ets/pages/TaskScrollState';
import { parseMessage, readBool, readStr, RemoteMessage } from '../main/ets/core/tasks/TaskModels';

class HistoryDeferred {
  promise: Promise<Envelope>;
  resolve: (value: Envelope) => void = (_value: Envelope): void => {};
  constructor() {
    this.promise = new Promise<Envelope>((resolve) => { this.resolve = resolve; });
  }
}

function historySuccess(value: Object): Envelope {
  const payload: Record<string, Object> = {};
  payload['ok'] = true;
  payload['result'] = value;
  const envelope = new Envelope();
  envelope.payload = payload;
  return envelope;
}

function historyUnavailable(): Envelope {
  const error: Record<string, Object> = {};
  error['code'] = 'CHANNEL_NOT_ALLOWED';
  error['message'] = 'old host';
  const payload: Record<string, Object> = {};
  payload['ok'] = false;
  payload['error'] = error;
  const envelope = new Envelope();
  envelope.payload = payload;
  return envelope;
}

function historySummary(revision: string = '1', first: string = 'a', last: string = 'z'): Record<string, Object> {
  const summary = JSON.parse('{"key":"work","startedAtMs":1000,"endedAtMs":2000,"isStreaming":true,'
    + '"messageCount":2,"toolCount":1,"model":"actual-child-model",'
    + '"lines":[{"kind":"thinking","key":"thought","text":"working"},'
    + '{"kind":"tool","key":"tool","toolName":"Bash","status":"running",'
    + '"descriptor":{"kind":"command","intent":"search","command":"rg foo"}}],'
    + '"artifacts":[{"path":"/work/output.txt","source":"tool","createdAt":"1970-01-01T00:00:02Z","ready":true}]}') as Record<string, Object>;
  summary['revision'] = revision;
  summary['firstMessageId'] = first;
  summary['lastMessageId'] = last;
  return summary;
}

function historyItem(summary: Record<string, Object>): Record<string, Object> {
  const item: Record<string, Object> = {};
  item['type'] = 'work';
  item['key'] = readStr(summary, 'key');
  item['summary'] = summary;
  return item;
}

function historyPage(summary: Record<string, Object>): Object {
  const page: Record<string, Object> = {};
  const items: Object[] = [historyItem(summary)];
  page['version'] = 1;
  page['items'] = items;
  page['hasMore'] = false;
  return page;
}

function historyPatch(summary: Record<string, Object>, baseRevision: string = '1'): Object {
  const patch: Record<string, Object> = {};
  patch['version'] = 1;
  patch['sessionId'] = 'session';
  patch['baseRevision'] = baseRevision;
  patch['item'] = historyItem(summary);
  return patch;
}

function historyPageWithMessages(summary: Record<string, Object>, messages: RemoteMessage[]): Object {
  const page = historyPage(summary) as Record<string, Object>;
  const source: Record<string, Object> = {};
  source['type'] = 'messages';
  source['key'] = 'visible';
  source['messages'] = messages;
  const items: Object[] = [source, historyItem(summary)];
  page['items'] = items;
  return page;
}

function historyRow(id: string, text: string = 'detail'): RemoteMessage {
  const raw: Record<string, Object> = {};
  raw['id'] = id;
  raw['clientId'] = id;
  raw['sessionId'] = 'session';
  raw['role'] = 'thinking';
  raw['createdAt'] = '1970-01-01T00:00:01Z';
  raw['content'] = text;
  return parseMessage(raw);
}

function historyDetails(rows: RemoteMessage[], cursor: string = ''): Object {
  const page: Record<string, Object> = {};
  page['version'] = 1;
  page['messages'] = rows;
  page['hasMore'] = cursor.length > 0;
  if (cursor) page['nextCursor'] = cursor;
  return page;
}

class HistoryMockDlClient extends DlClient {
  epoch: number = 1;
  supported: boolean = true;
  page: Object = historyPage(historySummary());
  calls: DlInvokeOptions[] = [];
  pageReplies: Promise<Envelope>[] = [];
  detailReplies: Promise<Envelope>[] = [];
  rejectView: boolean = false;
  rejectIntent: boolean = false;
  rejectDetails: boolean = false;
  subscriptionCount: number = 0;
  constructor() { super(new DlClientOptions()); }
  connectionIdentity(_deviceId: string): string { return String(this.epoch); }
  supportsHistoryView(_deviceId: string): boolean { return this.supported; }
  async subscribe(_deviceId: string, _topics: string[], _timeout: number = 0): Promise<Envelope> {
    this.subscriptionCount += 1;
    return historySuccess(true);
  }
  async unsubscribe(_deviceId: string, _topics: string[], _timeout: number = 0): Promise<Envelope> {
    return historySuccess(true);
  }
  invoke(_deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    this.calls.push(options);
    if (options.channel === 'local-db:messages:view') {
      return this.pageReplies.shift() ?? Promise.resolve(this.rejectView ? historyUnavailable() : historySuccess(this.page));
    }
    if (options.channel === 'local-db:messages:view-intent') {
      return Promise.resolve(this.rejectIntent ? historyUnavailable() : historySuccess(true));
    }
    if (options.channel === 'local-db:messages:work-details') {
      return this.detailReplies.shift() ?? Promise.resolve(this.rejectDetails ? historyUnavailable()
        : historySuccess(historyDetails([historyRow('a'), historyRow('z')])));
    }
    return Promise.resolve(historySuccess(options.channel === 'local-db:messages:list' ? [historyRow('legacy')] : false));
  }
}

async function historyWaitForCalls(client: HistoryMockDlClient, channel: string, count: number): Promise<void> {
  for (let attempt = 0; attempt < 80; attempt++) {
    if (client.calls.filter((call: DlInvokeOptions) => call.channel === channel).length >= count) return;
    await Promise.resolve();
  }
  expect(client.calls.filter((call: DlInvokeOptions) => call.channel === channel).length >= count).assertTrue();
}

async function historySettle(): Promise<void> {
  for (let attempt = 0; attempt < 40; attempt++) await Promise.resolve();
}

export default function v132HistoryTests(): void {
  describe('v132History', () => {
    it('does_not_follow_latest_after_touch_release_while_reading_older_history', 0, () => {
      expect(canFollowLatest(false, false, false, true)).assertFalse();
    });
    it('does_not_follow_latest_while_touching_or_loading_older_history', 0, () => {
      expect(canFollowLatest(true, true, false, true)).assertFalse();
      expect(canFollowLatest(true, false, true, true)).assertFalse();
      expect(canFollowLatest(true, true, true, true)).assertFalse();
    });
    it('follows_latest_only_when_pinned_idle_and_content_is_present', 0, () => {
      expect(canFollowLatest(true, false, false, true)).assertTrue();
      expect(canFollowLatest(true, false, false, false)).assertFalse();
    });
    it('resolves_deferred_real_anchors_from_subagent_keys_and_tool_use_ids', 0, async () => {
      const client = new HistoryMockDlClient();
      client.page = JSON.parse('{"version":1,"items":[{"type":"messages","key":"client-header",'
        + '"messages":[{"id":"db-header","clientId":"client-header","role":"tool_use","toolUseId":"agent-tool",'
        + '"content":{"toolName":"Agent","toolUseId":"agent-tool","input":{"description":"child"}},'
        + '"createdAt":"1970-01-01T00:00:01Z"}],'
        + '"deferred":{"key":"subagent-work","revision":"1","anchorClientId":"client-header","parentToolUseId":"agent-tool",'
        + '"firstMessageId":"a","lastMessageId":"z","startedAtMs":1000,"endedAtMs":2000,"model":"actual-model"}}],"hasMore":false}') as Object;
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const keys: string[] = ['db-header', 'client-header', 'subagent-agent-tool', 'agent-tool'];
      for (const key of keys) {
        const work = store.historyWorkPresentation('device', 'session', key);
        expect(work?.messageId).assertEqual('db-header');
        expect(work?.anchorClientId).assertEqual('client-header');
        expect(work?.parentToolUseId).assertEqual('agent-tool');
      }
      const work = store.historyWorkPresentation('device', 'session', 'subagent-agent-tool');
      await store.loadHistoryDetails('device', 'session', work?.messageId ?? '');
      expect(store.historyWorkPresentation('device', 'session', 'subagent-agent-tool')?.complete).assertTrue();
      expect(store.historyWorkPresentation('device', 'session', 'unrelated')).assertEqual(undefined);
      await store.closeSession('session', 'device');
    });
    it('refreshes_only_the_current_task_without_clearing_messages_or_resubscribing', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      await store.loadHistoryDetails('device', 'session', 'history-work:work');
      await historySettle();
      const subscriptions = client.subscriptionCount;
      const started = client.calls.length;
      const pending = new HistoryDeferred();
      client.pageReplies.push(pending.promise);
      const refresh = store.refreshHistoryView('device', 'session', store.historyReadLease('device', 'session'));
      await historyWaitForCalls(client, 'local-db:messages:view', 2);
      expect(store.getMessages('session', 'device').some((row: RemoteMessage) => row.id === 'a')).assertTrue();
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.complete).assertTrue();
      pending.resolve(historySuccess(client.page));
      expect(await refresh).assertTrue();
      expect(client.subscriptionCount).assertEqual(subscriptions);
      expect(client.calls.slice(started).every((call: DlInvokeOptions) => call.channel === 'local-db:messages:view')).assertTrue();
      expect(store.getMessages('session', 'device').some((row: RemoteMessage) => row.id === 'a')).assertTrue();
      await store.closeSession('session', 'device');
    });
    it('coalesces_history_invalidations_and_waits_for_one_fresh_trailing_read', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const initial = new HistoryDeferred();
      const tail = new HistoryDeferred();
      client.pageReplies.push(initial.promise, tail.promise);
      const lease = store.historyReadLease('device', 'session');
      const first = store.refreshHistoryView('device', 'session', lease);
      const sameTurn = store.refreshHistoryView('device', 'session', lease);
      expect(first === sameTurn).assertTrue();
      await historyWaitForCalls(client, 'local-db:messages:view', 2);
      const invalidated = store.refreshHistoryView('device', 'session', lease);
      const latest = store.refreshHistoryView('device', 'session', lease);
      expect(first === invalidated && first === latest).assertTrue();
      initial.resolve(historySuccess(historyPage(historySummary('stale'))));
      await historyWaitForCalls(client, 'local-db:messages:view', 3);
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.revision).assertEqual('1');
      tail.resolve(historySuccess(historyPage(historySummary('fresh'))));
      expect(await first).assertTrue();
      expect(await invalidated).assertTrue();
      expect(client.calls.filter((call: DlInvokeOptions) => call.channel === 'local-db:messages:view').length).assertEqual(3);
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.revision).assertEqual('fresh');
      await store.closeSession('session', 'device');
    });
    it('follows_a_new_message_push_without_publishing_the_stale_history_page', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const initial = new HistoryDeferred();
      const tail = new HistoryDeferred();
      client.pageReplies.push(initial.promise, tail.promise);
      const refresh = store.refreshHistoryView('device', 'session', store.historyReadLease('device', 'session'));
      await historyWaitForCalls(client, 'local-db:messages:view', 2);
      const created: Record<string, Object> = {};
      created['sessionId'] = 'session';
      created['message'] = historyRow('pushed', 'new push');
      store.handleSessionPush('device', 'local-db:messages:created', created);
      initial.resolve(historySuccess(historyPageWithMessages(historySummary('stale'), [historyRow('pushed', 'stale body')])));
      await historyWaitForCalls(client, 'local-db:messages:view', 3);
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.revision).assertEqual('1');
      expect(store.getMessages('session', 'device').find((row: RemoteMessage) => row.id === 'pushed')?.content).assertEqual('new push');
      tail.resolve(historySuccess(historyPageWithMessages(historySummary('fresh'), [historyRow('pushed', 'new push')])));
      expect(await refresh).assertTrue();
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.revision).assertEqual('fresh');
      expect(store.getMessages('session', 'device').find((row: RemoteMessage) => row.id === 'pushed')?.content).assertEqual('new push');
      await store.closeSession('session', 'device');
    });
    it('refreshes_after_an_inherited_projection_read_instead_of_treating_it_as_fresh', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const inherited = new HistoryDeferred();
      const tail = new HistoryDeferred();
      client.pageReplies.push(inherited.promise, tail.promise);
      const healing = store.resubscribeAndHeal('device', 'session');
      await historyWaitForCalls(client, 'local-db:messages:view', 2);
      const refresh = store.refreshHistoryView('device', 'session', store.historyReadLease('device', 'session'));
      await historySettle();
      expect(client.calls.filter((call: DlInvokeOptions) => call.channel === 'local-db:messages:view').length).assertEqual(2);
      inherited.resolve(historySuccess(historyPage(historySummary('inherited'))));
      await historyWaitForCalls(client, 'local-db:messages:view', 3);
      tail.resolve(historySuccess(historyPage(historySummary('fresh'))));
      await healing;
      expect(await refresh).assertTrue();
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.revision).assertEqual('fresh');
      await store.closeSession('session', 'device');
    });
    it('rejects_retired_refresh_leases_without_requests_and_drops_inflight_results', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      await historySettle();
      const lease = store.historyReadLease('device', 'session');
      const started = client.calls.length;
      expect(await store.refreshHistoryView('other-device', 'session', lease)).assertFalse();
      expect(await store.refreshHistoryView('device', 'session', '')).assertFalse();
      expect(client.calls.length).assertEqual(started);
      const pending = new HistoryDeferred();
      client.pageReplies.push(pending.promise);
      const refresh = store.refreshHistoryView('device', 'session', lease);
      await historyWaitForCalls(client, 'local-db:messages:view', 2);
      client.epoch += 1;
      pending.resolve(historySuccess(historyPage(historySummary('retired'))));
      expect(await refresh).assertFalse();
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.revision).assertEqual('1');
      const after = client.calls.length;
      expect(await store.refreshHistoryView('device', 'session', lease)).assertFalse();
      expect(client.calls.length).assertEqual(after);
      await store.closeSession('session', 'device');
    });
    it('keeps_history_on_refresh_failure_and_allows_the_next_request_to_retry', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const lease = store.historyReadLease('device', 'session');
      client.pageReplies.push(Promise.resolve(historySuccess(JSON.parse('{"version":2,"items":[]}') as Object)));
      expect(await store.refreshHistoryView('device', 'session', lease)).assertFalse();
      expect(store.getMessages('session', 'device')[0].id).assertEqual('history-work:work');
      client.page = historyPage(historySummary('retry'));
      expect(await store.refreshHistoryView('device', 'session', lease)).assertTrue();
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.revision).assertEqual('retry');
      await store.closeSession('session', 'device');
    });
    it('formats_host_activity_lines_without_reinterpreting_truncated_inputs', 0, () => {
      const text = (key: string, args: string[]): string => key + ':' + args.join('|');
      const thinking = JSON.parse('{"kind":"thinking","text":"host thought"}') as Record<string, Object>;
      expect(formatHistoryWorkLine(thinking, text)).assertEqual('host thought');
      const command = JSON.parse('{"kind":"tool","toolName":"Bash","input":{"command":"cat harmless"},'
        + '"descriptor":{"kind":"command","command":"git push origin main","intent":{"action":"gitPush","target":"origin"}}}') as Record<string, Object>;
      expect(formatHistoryWorkLine(command, text)).assertEqual('v132_history_action_run_command:');
      const description = JSON.parse('{"kind":"tool","toolName":"Bash","descriptor":{"kind":"command",'
        + '"description":"host description","command":"cat ignored","intent":{"action":"read","target":"ignored"}}}') as Record<string, Object>;
      expect(formatHistoryWorkLine(description, text)).assertEqual('host description');
      const intent = JSON.parse('{"kind":"tool","toolName":"exec","descriptor":{"kind":"command",'
        + '"command":"truncated…","intent":{"action":"search","target":"actual host target"}}}') as Record<string, Object>;
      expect(formatHistoryWorkLine(intent, text)).assertEqual('v132_history_action_search:actual host target');
    });
    it('formats_descriptor_file_operations_and_preserves_shell_entry_counts', 0, () => {
      const text = (key: string, args: string[]): string => key + ':' + args.join('|');
      const file = JSON.parse('{"kind":"tool","toolName":"Read","descriptor":{"kind":"file","action":"read",'
        + '"filePath":"/private/path","fileName":"host-name.ets"}}') as Record<string, Object>;
      expect(formatHistoryWorkLine(file, text)).assertEqual('v132_history_action_read:host-name.ets');
      const rename = JSON.parse('{"kind":"tool","toolName":"file_change","descriptor":{"kind":"fileChange",'
        + '"changes":[{"action":"move","fileName":"old.ets","moveFileName":"new.ets"}]}}') as Record<string, Object>;
      expect(formatHistoryWorkLine(rename, text)).assertEqual('v132_history_action_rename:old.ets → new.ets');
      const multiple = JSON.parse('{"kind":"tool","toolName":"file_change","descriptor":{"kind":"fileChange",'
        + '"changes":[{"action":"update","fileName":"one.ets"},{},{}]}}') as Record<string, Object>;
      expect(formatHistoryWorkLine(multiple, text)).assertEqual('v132_history_updated_files:3');
    });
    it('formats_web_search_and_service_labels_from_projected_fields', 0, () => {
      const text = (key: string, args: string[]): string => key + ':' + args.join('|');
      const descriptors: Record<string, Object>[] = [
        JSON.parse('{"kind":"web","mode":"fetch","target":"https://example.test"}') as Record<string, Object>,
        JSON.parse('{"kind":"search","mode":"grep","pattern":"host pattern"}') as Record<string, Object>,
        JSON.parse('{"kind":"todo"}') as Record<string, Object>,
        JSON.parse('{"kind":"task","description":"host subagent description"}') as Record<string, Object>,
        JSON.parse('{"kind":"mcp","serverLabel":"Host Server","toolLabel":"Host Tool"}') as Record<string, Object>,
        JSON.parse('{"kind":"dynamic","namespace":"Host Namespace","toolLabel":"Host Tool"}') as Record<string, Object>,
        JSON.parse('{"kind":"collab","toolLabel":"Host Collaborator"}') as Record<string, Object>,
        JSON.parse('{"kind":"generic","toolName":"Host Generic"}') as Record<string, Object>,
      ];
      const expected: string[] = ['v132_history_action_fetch:https://example.test', 'v132_history_action_search:host pattern',
        'v132_history_action_update_todos:', 'host subagent description', 'v132_history_action_use:Host Server · Host Tool',
        'v132_history_action_use:Host Namespace · Host Tool', 'v132_history_action_use:Host Collaborator', 'v132_history_action_use:Host Generic'];
      for (let index = 0; index < descriptors.length; index++) {
        const line: Record<string, Object> = {};
        line['kind'] = 'tool';
        line['toolName'] = 'fallback';
        line['descriptor'] = descriptors[index];
        expect(formatHistoryWorkLine(line, text)).assertEqual(expected[index]);
      }
    });
    it('falls_back_for_missing_descriptors_and_missing_translations', 0, () => {
      const text = (_key: string, _args: string[]): string => '';
      const missing = JSON.parse('{"kind":"tool","toolName":"legacy tool"}') as Record<string, Object>;
      expect(formatHistoryWorkLine(missing, text)).assertEqual('legacy tool');
      const file = JSON.parse('{"kind":"tool","toolName":"Read","descriptor":{"kind":"file","action":"read","fileName":"host.ets"}}') as Record<string, Object>;
      expect(formatHistoryWorkLine(file, text)).assertEqual('Read');
      const malformed = JSON.parse('{"kind":"tool","toolName":"file_change","descriptor":{"kind":"fileChange","changes":[]}}') as Record<string, Object>;
      expect(formatHistoryWorkLine(malformed, text)).assertEqual('file_change');
    });
    it('requests_lazy_details_and_work_lines_without_increasing_budgets', 0, async () => {
      const client = new HistoryMockDlClient();
      const adapter = new HistoryViewAdapter();
      adapter.available(client, 'device', 'session');
      await adapter.page(client, 'device', 'session', false, 'lease', () => true);
      const options = client.calls[0].args[1] as Record<string, Object>;
      expect(options['lazyDetails']).assertTrue();
      expect(options['workLines']).assertTrue();
      expect(Object.keys(options).length).assertEqual(2);
      expect(client.calls.some((call: DlInvokeOptions) => call.channel === 'local-db:messages:work-details')).assertFalse();
    });
    it('accepts_missing_optional_fields_from_old_hosts', 0, () => {
      const summary = JSON.parse('{"key":"work","revision":"1","firstMessageId":"a","lastMessageId":"z",'
        + '"startedAtMs":1000,"endedAtMs":2000}') as Record<string, Object>;
      const message = parseHistoryProjection(historyPage(summary), 'session').messages[0];
      const presentation = projectHistoryWorkPresentation(message, 'idle', false, []);
      expect(presentation.lines.length).assertEqual(0);
      expect(presentation.artifacts.length).assertEqual(0);
      expect(presentation.model).assertEqual('');
      expect(presentation.awaitingDetails).assertTrue();
    });
    it('displays_legacy_summaries_without_detail_range_endpoints', 0, () => {
      const summary = JSON.parse('{"key":"work","revision":"1"}') as Record<string, Object>;
      const message = parseHistoryProjection(historyPage(summary), 'session').messages[0];
      const presentation = projectHistoryWorkPresentation(message, 'idle', false, []);
      expect(message.id).assertEqual('history-work:work');
      expect(message.role).assertEqual('thinking');
      expect(presentation.key).assertEqual('work');
      expect(presentation.revision).assertEqual('1');
      expect(readStr(presentation.summary, 'firstMessageId')).assertEqual('');
      expect(readStr(presentation.summary, 'lastMessageId')).assertEqual('');
      expect(hasHistoryWorkReference(summary)).assertFalse();
      expect(historyDetailWindow(summary, [historyRow('a')]).length).assertEqual(0);
    });
    it('reads_legacy_nested_wrappers_and_deferred_outlines_without_full_references', 0, () => {
      const raw = JSON.parse('{"version":1,"items":[{"type":"work","children":['
        + '{"type":"messages","key":"header","messages":[{"id":"header","clientId":"header",'
        + '"role":"assistant","content":"visible prose","createdAt":"1970-01-01T00:00:01Z"}],'
        + '"deferred":{"key":"subagent","revision":"1","anchorClientId":"header","model":"actual-model"}},'
        + '{"type":"work","summary":{"key":"work","revision":"1"}}]}],"hasMore":false}') as Object;
      const page = parseHistoryProjection(raw, 'session');
      expect(page.messages.length).assertEqual(2);
      expect(page.messages[0].content).assertEqual('visible prose');
      expect(page.messages[1].id).assertEqual('history-work:work');
      expect(readBool(page.messages[0].agentMeta, 'historyWorkDeferred', false)).assertTrue();
      const deferred = projectHistoryWorkPresentation(page.messages[0], 'idle', false, []);
      expect(deferred.key).assertEqual('subagent');
      expect(deferred.model).assertEqual('actual-model');
      expect(hasHistoryWorkReference(deferred.summary)).assertFalse();
    });
    it('requires_complete_current_and_incoming_references_for_work_patches', 0, () => {
      const summary = JSON.parse('{"key":"work","revision":"1"}') as Record<string, Object>;
      const legacy = parseHistoryProjection(historyPage(summary), 'session').messages[0];
      const complete = parseHistoryProjection(historyPage(historySummary()), 'session').messages[0];
      const incomplete = JSON.parse('{"key":"work","revision":"2","firstMessageId":"a"}') as Record<string, Object>;
      expect(canApplyHistoryWorkPatch(legacy, historyPatch(historySummary('2')))).assertFalse();
      expect(canApplyHistoryWorkPatch(complete, historyPatch(incomplete))).assertFalse();
      expect(canApplyHistoryWorkPatch(complete, historyPatch(historySummary('2')))).assertTrue();
    });
    it('rejects_incomplete_detail_and_intent_references_before_any_remote_request', 0, async () => {
      const client = new HistoryMockDlClient();
      const adapter = new HistoryViewAdapter();
      const incomplete: Record<string, Object>[] = [
        JSON.parse('{"key":"work","revision":"1"}') as Record<string, Object>,
        JSON.parse('{"key":"work","revision":"1","firstMessageId":"a"}') as Record<string, Object>,
        JSON.parse('{"key":"work","revision":"1","lastMessageId":"z"}') as Record<string, Object>,
      ];
      for (const summary of incomplete) {
        let detailRejected = false;
        let intentRejected = false;
        try {
          await adapter.details(client, 'device', 'session', summary, () => true, (_rows: RemoteMessage[]): void => {});
        } catch (error) { detailRejected = error instanceof Error; }
        try { await adapter.retain(client, 'device', 'session', summary, () => true); }
        catch (error) { intentRejected = error instanceof Error; }
        expect(detailRejected).assertTrue();
        expect(intentRejected).assertTrue();
      }
      expect(client.calls.length).assertEqual(0);
      const completeLegacy = JSON.parse('{"key":"work","firstMessageId":"a","lastMessageId":"z"}') as Record<string, Object>;
      expect(hasHistoryWorkReference(completeLegacy)).assertTrue();
      let received = 0;
      await adapter.details(client, 'device', 'session', completeLegacy, () => true,
        (rows: RemoteMessage[]): void => { received += rows.length; });
      expect(received).assertEqual(2);
    });
    it('falls_back_to_raw_history_for_unadvertised_and_rejected_views', 0, async () => {
      for (const advertised of [false, true]) {
        const client = new HistoryMockDlClient();
        client.supported = advertised;
        client.rejectView = advertised;
        const store = new MessageStore();
        store.attach(client);
        expect(await store.openSession('device', 'session')).assertTrue();
        expect(store.getMessages('session', 'device')[0].id).assertEqual('legacy');
        expect(store.handleHistoryWorkPatch('device', historyPatch(historySummary('2')), store.historyReadLease('device', 'session'))).assertFalse();
        await store.closeSession('session', 'device');
      }
    });
    it('reads_details_when_an_old_host_rejects_advisory_intent', 0, async () => {
      const client = new HistoryMockDlClient();
      client.rejectIntent = true;
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      await store.loadHistoryDetails('device', 'session', 'history-work:work');
      expect(store.historyDetailState('device', 'session', 'history-work:work')).assertEqual('complete');
      expect(store.getMessages('session', 'device').some((row: RemoteMessage) => row.id === 'a')).assertTrue();
      await store.closeSession('session', 'device');
    });
    it('retains_lines_and_artifacts_when_old_host_details_are_unavailable', 0, async () => {
      const client = new HistoryMockDlClient();
      client.rejectDetails = true;
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      await store.loadHistoryDetails('device', 'session', 'history-work:work');
      const presentation = store.historyWorkPresentation('device', 'session', 'history-work:work');
      expect(presentation?.failed).assertTrue();
      expect(presentation?.lines.length).assertEqual(2);
      expect(presentation?.artifacts.length).assertEqual(1);
      await store.closeSession('session', 'device');
    });
    it('keeps_activity_lines_visible_while_expanded_details_are_pending', 0, async () => {
      const client = new HistoryMockDlClient();
      const pending = new HistoryDeferred();
      client.detailReplies.push(pending.promise);
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const loading = store.loadHistoryDetails('device', 'session', 'history-work:work');
      await historyWaitForCalls(client, 'local-db:messages:work-details', 1);
      const presentation = store.historyWorkPresentation('device', 'session', 'history-work:work');
      expect(presentation?.loading).assertTrue();
      expect(presentation?.expanded).assertTrue();
      expect(presentation?.awaitingDetails).assertTrue();
      expect(presentation?.lines.length).assertEqual(2);
      pending.resolve(historySuccess(historyDetails([historyRow('a'), historyRow('z')])));
      await loading;
      const completed = store.historyWorkPresentation('device', 'session', 'history-work:work');
      expect(completed?.awaitingDetails).assertFalse();
      expect(completed?.artifacts.length).assertEqual(1);
      expect(completed?.model).assertEqual('actual-child-model');
      await store.closeSession('session', 'device');
    });
    it('applies_only_matching_base_revisions_and_preserves_terminal_projection', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const lease = store.historyReadLease('device', 'session');
      const terminal = historySummary('2');
      terminal['isStreaming'] = false;
      terminal['lines'] = [];
      expect(store.handleHistoryWorkPatch('device', historyPatch(terminal), lease)).assertTrue();
      expect(store.handleHistoryWorkPatch('device', historyPatch(historySummary('3')), lease)).assertFalse();
      const presentation = store.historyWorkPresentation('device', 'session', 'history-work:work');
      expect(presentation?.revision).assertEqual('2');
      expect(readBool(presentation?.summary ?? {}, 'isStreaming', true)).assertFalse();
      expect(presentation?.artifacts.length).assertEqual(1);
      await store.closeSession('session', 'device');
    });
    it('rejects_range_start_and_parent_scope_changes_even_with_matching_revision', 0, () => {
      const message = parseHistoryProjection(historyPage(historySummary()), 'session').messages[0];
      expect(canApplyHistoryWorkPatch(message, historyPatch(historySummary('2', 'changed')))).assertFalse();
      const nested = historySummary('2');
      nested['parentToolUseId'] = 'other-parent';
      expect(canApplyHistoryWorkPatch(message, historyPatch(nested))).assertFalse();
      expect(canApplyHistoryWorkPatch(message, historyPatch(historySummary('2', 'a', 'new-tail')))).assertTrue();
    });
    it('retains_nested_summaries_and_deferred_subagent_ownership', 0, () => {
      const leaf = historyItem(historySummary());
      const nested = historySummary();
      nested['key'] = 'subagent';
      nested['parentToolUseId'] = 'agent-tool';
      nested['anchorClientId'] = 'agent-header';
      const header = historyRow('agent-header');
      header.role = 'tool_use';
      const source: Record<string, Object> = {};
      const headers: RemoteMessage[] = [header];
      source['type'] = 'messages';
      source['key'] = 'agent-header';
      source['messages'] = headers;
      source['deferred'] = nested;
      const outer = historyItem(historySummary());
      const children: Object[] = [leaf, source];
      outer['children'] = children;
      const root: Record<string, Object> = {};
      const items: Object[] = [outer];
      root['version'] = 1;
      root['items'] = items;
      const messages = parseHistoryProjection(root, 'session').messages;
      expect(messages.length).assertEqual(2);
      expect(Array.isArray(messages[0].agentMeta['historyWorkParents'])).assertTrue();
      expect(canApplyHistoryWorkPatch(messages[0], historyPatch(historySummary('2')))).assertFalse();
      expect(readBool(messages[1].agentMeta, 'historyWorkDeferred', false)).assertTrue();
      const presentation = projectHistoryWorkPresentation(messages[1], 'loading', true, []);
      expect(presentation.parentToolUseId).assertEqual('agent-tool');
      expect(presentation.model).assertEqual('actual-child-model');
      expect(presentation.artifacts.length).assertEqual(1);
    });
    it('reads_deferred_subagent_details_by_the_real_anchor_row', 0, async () => {
      const client = new HistoryMockDlClient();
      client.page = JSON.parse('{"version":1,"items":[{"type":"messages","key":"agent-header",'
        + '"messages":[{"id":"agent-header","clientId":"agent-header","role":"tool_use","content":"Agent","createdAt":"1970-01-01T00:00:01Z"}],'
        + '"deferred":{"key":"subagent","revision":"1","anchorClientId":"agent-header","parentToolUseId":"agent-tool",'
        + '"firstMessageId":"a","lastMessageId":"z","startedAtMs":1000,"endedAtMs":2000,"model":"actual-model"}}],"hasMore":false}') as Object;
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      await store.loadHistoryDetails('device', 'session', 'agent-header');
      const call = client.calls.find((candidate: DlInvokeOptions) => candidate.channel === 'local-db:messages:work-details');
      expect(readStr(call?.args[1] as Record<string, Object>, 'parentToolUseId')).assertEqual('agent-tool');
      expect(store.historyWorkPresentation('device', 'session', 'agent-header')?.complete).assertTrue();
      store.hideHistoryDetails('device', 'session', 'agent-header');
      await store.closeSession('session', 'device');
    });
    it('invalidates_reference_identity_for_same_revision_range_replacement', 0, () => {
      const previous = historySummary();
      const replacement = historySummary('1', 'a', 'new-tail');
      expect(historyWorkReferenceIdentity(previous) === historyWorkReferenceIdentity(replacement)).assertFalse();
      const body = [historyRow('a'), historyRow('middle'), historyRow('z')];
      expect(historyDetailWindow(historySummary('2', 'middle', 'z'), body).length).assertEqual(2);
      expect(historyDetailWindow(historySummary('2', 'absent', 'z'), body).length).assertEqual(0);
    });
    it('rejects_old_detail_reads_after_work_revision_changes', 0, async () => {
      const client = new HistoryMockDlClient();
      const oldRead = new HistoryDeferred();
      const freshRead = new HistoryDeferred();
      client.detailReplies.push(oldRead.promise, freshRead.promise);
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const loading = store.loadHistoryDetails('device', 'session', 'history-work:work');
      await historyWaitForCalls(client, 'local-db:messages:work-details', 1);
      expect(store.handleHistoryWorkPatch('device', historyPatch(historySummary('2')), store.historyReadLease('device', 'session'))).assertTrue();
      await historyWaitForCalls(client, 'local-db:messages:work-details', 2);
      freshRead.resolve(historySuccess(historyDetails([historyRow('a', 'fresh'), historyRow('z', 'fresh')])));
      await historySettle();
      oldRead.resolve(historySuccess(historyDetails([historyRow('a', 'stale'), historyRow('z', 'stale')])));
      await loading;
      expect(store.getMessages('session', 'device').find((row: RemoteMessage) => row.id === 'a')?.content).assertEqual('fresh');
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.revision).assertEqual('2');
      await store.closeSession('session', 'device');
    });
    it('rejects_old_detail_reads_after_same_revision_range_replacement', 0, async () => {
      const client = new HistoryMockDlClient();
      const oldRead = new HistoryDeferred();
      client.detailReplies.push(oldRead.promise);
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const loading = store.loadHistoryDetails('device', 'session', 'history-work:work');
      await historyWaitForCalls(client, 'local-db:messages:work-details', 1);
      client.page = historyPage(historySummary('1', 'new-first', 'new-last'));
      client.detailReplies.push(Promise.resolve(historySuccess(historyDetails([historyRow('new-first'), historyRow('new-last')]))));
      await store.resubscribeAndHeal('device', 'session');
      await historySettle();
      oldRead.resolve(historySuccess(historyDetails([historyRow('a', 'stale'), historyRow('z', 'stale')])));
      await loading;
      expect(store.getMessages('session', 'device').some((row: RemoteMessage) => row.id === 'a')).assertFalse();
      expect(store.getMessages('session', 'device').some((row: RemoteMessage) => row.id === 'new-first')).assertTrue();
      await store.closeSession('session', 'device');
    });
    it('preserves_completed_details_and_new_artifacts_at_the_same_revision', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      await store.loadHistoryDetails('device', 'session', 'history-work:work');
      const summary = historySummary();
      summary['artifacts'] = JSON.parse('[{"path":"/work/new-output.txt","source":"command","createdAt":"1970-01-01T00:00:02Z","exclude":"command"}]') as Object[];
      client.page = historyPage(summary);
      await store.resubscribeAndHeal('device', 'session');
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.complete).assertTrue();
      const artifacts = store.historyWorkPresentation('device', 'session', 'history-work:work')?.artifacts ?? [];
      expect(readStr(artifacts[0], 'path')).assertEqual('/work/new-output.txt');
      expect(readStr(artifacts[0], 'exclude')).assertEqual('command');
      expect(store.getMessages('session', 'device').some((row: RemoteMessage) => row.id === 'a')).assertTrue();
      await store.closeSession('session', 'device');
    });
    it('keeps_the_previous_detail_window_until_all_replacement_pages_settle', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      await store.loadHistoryDetails('device', 'session', 'history-work:work');
      const tail = new HistoryDeferred();
      client.detailReplies.push(Promise.resolve(historySuccess(historyDetails([historyRow('a', 'new')], 'cursor'))), tail.promise);
      const terminal = historySummary('2');
      terminal['isStreaming'] = false;
      expect(store.handleHistoryWorkPatch('device', historyPatch(terminal), store.historyReadLease('device', 'session'))).assertTrue();
      await historyWaitForCalls(client, 'local-db:messages:work-details', 3);
      expect(store.getMessages('session', 'device').find((row: RemoteMessage) => row.id === 'a')?.content).assertEqual('detail');
      expect(store.getMessages('session', 'device').some((row: RemoteMessage) => row.id === 'z')).assertTrue();
      tail.resolve(historySuccess(historyDetails([historyRow('z', 'new')])));
      await historySettle();
      expect(store.getMessages('session', 'device').find((row: RemoteMessage) => row.id === 'a')?.content).assertEqual('new');
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.artifacts.length).assertEqual(1);
      await store.closeSession('session', 'device');
    });
    it('rejects_patches_while_a_page_read_is_in_flight', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const pending = new HistoryDeferred();
      client.pageReplies.push(pending.promise);
      const healing = store.resubscribeAndHeal('device', 'session');
      await historyWaitForCalls(client, 'local-db:messages:view', 2);
      expect(store.handleHistoryWorkPatch('device', historyPatch(historySummary('2')), store.historyReadLease('device', 'session'))).assertFalse();
      pending.resolve(historySuccess(client.page));
      await healing;
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.revision).assertEqual('1');
      await store.closeSession('session', 'device');
    });
    it('drops_late_pages_after_the_session_lease_is_replaced', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const pending = new HistoryDeferred();
      client.pageReplies.push(pending.promise);
      const healing = store.resubscribeAndHeal('device', 'session');
      await historyWaitForCalls(client, 'local-db:messages:view', 2);
      await store.closeSession('session', 'device');
      client.page = historyPage(historySummary('fresh'));
      await store.openSession('device', 'session');
      pending.resolve(historySuccess(historyPage(historySummary('stale'))));
      await healing;
      expect(store.historyWorkPresentation('device', 'session', 'history-work:work')?.revision).assertEqual('fresh');
      await store.closeSession('session', 'device');
    });
    it('keeps_new_created_content_when_a_detail_read_finishes_late', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const pending = new HistoryDeferred();
      client.detailReplies.push(pending.promise);
      const loading = store.loadHistoryDetails('device', 'session', 'history-work:work');
      await historyWaitForCalls(client, 'local-db:messages:work-details', 1);
      const created: Record<string, Object> = {};
      created['sessionId'] = 'session';
      created['message'] = historyRow('a', 'pushed');
      store.handleSessionPush('device', 'local-db:messages:created', created);
      pending.resolve(historySuccess(historyDetails([historyRow('a', 'stale'), historyRow('z')])));
      await loading;
      expect(store.getMessages('session', 'device').find((row: RemoteMessage) => row.id === 'a')?.content).assertEqual('pushed');
      await store.closeSession('session', 'device');
    });
    it('rejects_retired_connection_account_device_and_session_leases', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      store.setCacheAccountScope('account-a');
      await store.openSession('device', 'session');
      const originalLease = store.historyReadLease('device', 'session');
      client.epoch += 1;
      expect(store.handleHistoryWorkPatch('device', historyPatch(historySummary('2')), originalLease)).assertFalse();
      await store.resubscribeAndHeal('device', 'session');
      const connectedLease = store.historyReadLease('device', 'session');
      store.setCacheAccountScope('account-b');
      expect(store.handleHistoryWorkPatch('device', historyPatch(historySummary('2')), connectedLease)).assertFalse();
      await store.resubscribeAndHeal('device', 'session');
      const accountLease = store.historyReadLease('device', 'session');
      expect(store.handleHistoryWorkPatch('other-device', historyPatch(historySummary('2')), accountLease)).assertFalse();
      await store.closeSession('session', 'device');
      expect(store.handleHistoryWorkPatch('device', historyPatch(historySummary('2')), accountLease)).assertFalse();
      await store.openSession('device', 'session');
      expect(store.handleHistoryWorkPatch('device', historyPatch(historySummary('2')), accountLease)).assertFalse();
      await store.closeSession('session', 'device');
    });
    it('drops_pending_details_after_connection_and_account_changes', 0, async () => {
      for (const changeAccount of [false, true]) {
        const client = new HistoryMockDlClient();
        const store = new MessageStore();
        store.attach(client);
        store.setCacheAccountScope('account-a');
        await store.openSession('device', 'session');
        const pending = new HistoryDeferred();
        client.detailReplies.push(pending.promise);
        const loading = store.loadHistoryDetails('device', 'session', 'history-work:work');
        await historyWaitForCalls(client, 'local-db:messages:work-details', 1);
        if (changeAccount) store.setCacheAccountScope('account-b');
        else client.epoch += 1;
        pending.resolve(historySuccess(historyDetails([historyRow('stale')])));
        await loading;
        expect(store.getMessages('session', 'device').some((row: RemoteMessage) => row.id === 'stale')).assertFalse();
        await store.closeSession('session', 'device');
      }
    });
    it('does_not_resurrect_a_cancelled_detail_read_after_reexpansion', 0, async () => {
      const client = new HistoryMockDlClient();
      const store = new MessageStore();
      store.attach(client);
      await store.openSession('device', 'session');
      const retired = new HistoryDeferred();
      const current = new HistoryDeferred();
      client.detailReplies.push(retired.promise, current.promise);
      const firstRead = store.loadHistoryDetails('device', 'session', 'history-work:work');
      await historyWaitForCalls(client, 'local-db:messages:work-details', 1);
      store.hideHistoryDetails('device', 'session', 'history-work:work');
      const secondRead = store.loadHistoryDetails('device', 'session', 'history-work:work');
      await historyWaitForCalls(client, 'local-db:messages:work-details', 2);
      retired.resolve(historySuccess(historyDetails([historyRow('retired')])));
      await firstRead;
      expect(store.historyDetailState('device', 'session', 'history-work:work')).assertEqual('loading');
      current.resolve(historySuccess(historyDetails([historyRow('a', 'current'), historyRow('z')])));
      await secondRead;
      expect(store.getMessages('session', 'device').some((row: RemoteMessage) => row.id === 'retired')).assertFalse();
      expect(store.historyDetailState('device', 'session', 'history-work:work')).assertEqual('complete');
      await store.closeSession('session', 'device');
    });
  });
}
