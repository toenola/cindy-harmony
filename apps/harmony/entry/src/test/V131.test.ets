import { LocalAttachmentPreviews } from '../main/ets/core/attachments/LocalAttachmentPreviews';
import { describe, it, expect } from '@ohos/hypium';
import { hasProviderCatalog, groupComposerModelOptions, modelWindowSwitchDecision, parseProviderModelOptions } from '../main/ets/core/ComposerCatalog';
import { parseNewSessionPreferences, NewSessionPreferenceStore, WorkspacePreferenceStorage } from '../main/ets/core/tasks/NewSessionPreferenceStore';
import { parseHistoryProjection, historyViewUnavailable, HistoryViewAdapter, projectedHistoryPrefix } from '../main/ets/core/messages/HistoryViewAdapter';
import { SnapshotReadPool } from '../main/ets/core/messages/SnapshotReadPool';
import { ProjectMachine, projectMachineLabel } from '../main/ets/core/tasks/ProjectMachineIdentity';
import { MessageStore } from '../main/ets/core/messages/MessageStore';
import { parseThinkingPresentation } from '../main/ets/core/messages/MessageRender';
import { DlClient, DlClientOptions, DlInvokeOptions } from '../main/ets/core/device-link/DlClient';
import { Envelope } from '../main/ets/core/device-link/DlProtocol';
import { RemoteMessage } from '../main/ets/core/tasks/TaskModels';
import { projectAccountUsage } from '../main/ets/core/messages/AccountUsage';

class DeferredValue<T> {
  promise: Promise<T>;
  resolve: (value: T) => void = (_value: T): void => {};
  constructor() { this.promise = new Promise<T>((resolve) => { this.resolve = resolve; }); }
}

class TestPreferenceStorage extends WorkspacePreferenceStorage {
  values: Map<string, string> = new Map();
  writes: string[] = [];
  delayedRead: DeferredValue<string> | undefined = undefined;
  async get(key: string, fallback: string): Promise<string> {
    return this.delayedRead?.promise ?? this.values.get(key) ?? fallback;
  }
  async set(key: string, value: string): Promise<void> { this.writes.push(key); this.values.set(key, value); }
}

function success(result: Object): Envelope {
  const payload: Record<string, Object> = {};
  payload['ok'] = true; payload['result'] = result;
  const envelope = new Envelope(); envelope.payload = payload; return envelope;
}

class ProjectionClient extends DlClient {
  calls: string[] = [];
  intents: Object[][] = [];
  epoch: number = 1;
  supported: boolean = true;
  page: Object = JSON.parse('{"version":1,"items":[{"type":"work","summary":{"key":"w","revision":"1","firstMessageId":"a","lastMessageId":"z","startedAtMs":1000,"endedAtMs":1000}}],"hasMore":false}') as Object;
  delayedPage: DeferredValue<Envelope> | undefined = undefined;
  constructor() { super(new DlClientOptions()); }
  connectionIdentity(_device: string): string { return String(this.epoch); }
  supportsHistoryView(_device: string): boolean { return this.supported; }
  async subscribe(_device: string, _topics: string[], _timeout: number = 0): Promise<Envelope> { return success(true); }
  async unsubscribe(_device: string, _topics: string[], _timeout: number = 0): Promise<Envelope> { return success(true); }
  invoke(_device: string, options: DlInvokeOptions): Promise<Envelope> {
    this.calls.push(options.channel);
    if (options.channel === 'local-db:messages:view') return this.delayedPage?.promise ?? Promise.resolve(success(this.page));
    if (options.channel === 'local-db:messages:view-intent') this.intents.push(options.args);
    if (options.channel === 'local-db:messages:work-details') return Promise.resolve(success(JSON.parse(
      '{"version":1,"messages":[{"id":"a","clientId":"a","role":"thinking","content":{"text":"detail"},"createdAt":"1970-01-01T00:00:01Z"}],"hasMore":false}') as Object));
    return Promise.resolve(success(options.channel === 'local-db:messages:list' ? [] : false));
  }
}

export default function v131Tests(): void {
  describe('v131Alignment', () => {
    it('keeps_local_attachment_previews_scoped_and_bounded_until_handoff', 0, () => {
      const previews = new LocalAttachmentPreviews();
      previews.remember('a', 'media', 'local-a');
      expect(previews.read('b', 'media')).assertEqual('');
      previews.remember('b', 'media', 'local-b');
      previews.release('a', 'media');
      expect(previews.read('b', 'media')).assertEqual('local-b');
      for (let i = 0; i < 129; i++) previews.remember('a', String(i), 'uri');
      expect(previews.read('a', '0')).assertEqual('');
      expect(previews.read('a', '128')).assertEqual('uri');
      previews.clear(); expect(previews.read('a', '128')).assertEqual('');
    });
    it('keeps_newer_live_text_with_the_history_timestamp_without_duplicates', 0, async () => {
      const client = new ProjectionClient(); const store = new MessageStore(); store.attach(client);
      await store.openSession('device', 'session');
      store.handleMakerEvent('session', JSON.parse('{"type":"text","data":{"text":"newer live text"}}') as Record<string, Object>, 'live', 'device');
      client.page = JSON.parse('{"version":1,"items":[{"type":"messages","messages":[{"id":"live","clientId":"live","role":"assistant","content":"old","isStreaming":true,"createdAt":"2026-09-10T00:00:00Z"}]}],"hasMore":false}') as Object;
      await store.resubscribeAndHeal('device', 'session');
      const live = store.getMessagesWithStreaming('session', 'device').filter((row: RemoteMessage) => row.id === 'live');
      expect(live.length).assertEqual(1);
      expect(live[0].content).assertEqual('newer live text');
      expect(live[0].createdAt).assertEqual('2026-09-10T00:00:00Z');
      await store.closeSession('session', 'device');
    });
    it('retains_finished_stream_blocks_until_their_authoritative_rows_arrive', 0, async () => {
      const client = new ProjectionClient();
      const store = new MessageStore(); store.attach(client);
      await store.openSession('device', 'session');
      const first = JSON.parse('{"type":"text","data":{"text":"first"}}') as Record<string, Object>;
      const second = JSON.parse('{"type":"text","data":{"text":"second"}}') as Record<string, Object>;
      store.handleMakerEvent('session', first, 'persist-1', 'device');
      store.handleMakerEvent('session', second, 'persist-2', 'device');
      store.handleMakerEvent('session', JSON.parse('{"type":"done","data":{}}') as Record<string, Object>, '', 'device');
      await store.resubscribeAndHeal('device', 'session');
      expect(store.getMessagesWithStreaming('session', 'device').some((row: RemoteMessage) => row.id === 'persist-1')).assertTrue();
      expect(store.getMessagesWithStreaming('session', 'device').some((row: RemoteMessage) => row.id === 'persist-2')).assertTrue();
      store.handleSessionPush('device', 'local-db:messages:created', JSON.parse('{"sessionId":"session","message":{"id":"persist-1","clientId":"persist-1","role":"assistant","content":"first saved","createdAt":"2026-09-10T00:00:00Z"}}') as Object);
      expect(store.getMessagesWithStreaming('session', 'device').filter((row: RemoteMessage) => row.id === 'persist-1').length).assertEqual(1);
      expect(store.getMessagesWithStreaming('session', 'device').some((row: RemoteMessage) => row.id === 'persist-2')).assertTrue();
      await store.closeSession('session', 'device');
    });
    it('does_not_overwrite_a_new_push_with_a_slow_history_snapshot', 0, async () => {
      const client = new ProjectionClient(); const store = new MessageStore(); store.attach(client);
      await store.openSession('device', 'session');
      client.delayedPage = new DeferredValue<Envelope>();
      const healing = store.resubscribeAndHeal('device', 'session');
      for (let i = 0; i < 10; i++) await Promise.resolve();
      store.handleSessionPush('device', 'local-db:messages:created', JSON.parse('{"sessionId":"session","message":{"id":"reply","clientId":"reply","role":"assistant","content":"new","createdAt":"2026-09-10T00:00:00Z"}}') as Object);
      client.delayedPage.resolve(success(JSON.parse('{"version":1,"items":[{"type":"messages","messages":[{"id":"reply","clientId":"reply","role":"assistant","content":"old","createdAt":"2026-09-10T00:00:00Z"}]}],"hasMore":false}') as Object));
      await healing;
      expect(store.getMessages('session', 'device').find((row: RemoteMessage) => row.id === 'reply')?.content).assertEqual('new');
      await store.closeSession('session', 'device');
    });
    it('isolates_accounts_and_serializes_explicit_workspace_choices', 0, async () => {
      const disk = new TestPreferenceStorage();
      const store = new NewSessionPreferenceStore(disk);
      await store.setAccountScope('account-a');
      store.save('device-a', 'project', ' /project a ');
      store.save('device-b', 'project', '/project-b');
      store.save('device-a', 'dialogue', '');
      await store.setAccountScope('account-b');
      expect(store.read().workspaceKind).assertEqual('');
      expect(Object.keys(store.read().workingDirByDevice).length).assertEqual(0);
      store.save('device-a', 'project', '/account-b');
      await store.setAccountScope('account-a');
      expect(store.read().workspaceKind).assertEqual('dialogue');
      expect(store.read().workingDirByDevice['device-a']).assertEqual(' /project a ');
      expect(store.read().workingDirByDevice['device-b']).assertEqual('/project-b');
      await store.setAccountScope('');
      expect(Object.keys(store.read().workingDirByDevice).length).assertEqual(0);
      expect(disk.writes.length).assertEqual(4);
    });
    it('does_not_replace_a_new_workspace_edit_with_slow_hydration', 0, async () => {
      const disk = new TestPreferenceStorage(); disk.delayedRead = new DeferredValue<string>();
      const store = new NewSessionPreferenceStore(disk);
      const loading = store.setAccountScope('account');
      await Promise.resolve();
      store.save('device', 'project', '/new');
      disk.delayedRead.resolve('{"workspaceKind":"project","workingDirByDevice":{"device":"/old"}}');
      await loading;
      expect(store.read().workingDirByDevice['device']).assertEqual('/new');
    });
    it('shares_only_identical_reads_and_retries_failure_independently', 0, async () => {
      const pool = new SnapshotReadPool<number>();
      const first = new DeferredValue<number>();
      let calls = 0;
      const invoke = (): Promise<number> => { calls += 1; return first.promise; };
      const a = pool.read('device/session/epoch/lease/window/authority', () => true, invoke);
      const b = pool.read('device/session/epoch/lease/window/authority', () => true, invoke);
      expect(calls).assertEqual(1);
      const independent = await pool.read('input-projection', () => true, async (): Promise<number> => 9);
      expect(independent).assertEqual(9);
      first.resolve(3);
      expect(await a).assertEqual(3); expect(await b).assertEqual(3);
      let failed = false;
      try { await pool.read('failed', () => true, async (): Promise<number> => { throw new Error('offline'); }); }
      catch (e) { failed = true; }
      expect(failed).assertTrue();
      expect(await pool.read('failed', () => true, async (): Promise<number> => 5)).assertEqual(5);
    });
    it('rejects_late_reads_after_the_connection_or_page_changes', 0, async () => {
      const pool = new SnapshotReadPool<number>();
      const delayed = new DeferredValue<number>();
      let current = true;
      const old = pool.read('old', () => current, () => delayed.promise).then(() => false, () => true);
      current = false;
      expect(await pool.read('new', () => true, async (): Promise<number> => 7)).assertEqual(7);
      delayed.resolve(1);
      expect(await old).assertTrue();
    });
    it('preserves_work_details_across_authoritative_refresh_and_keeps_zero_duration_stubs', 0, async () => {
      const client = new ProjectionClient();
      const store = new MessageStore(); store.attach(client);
      expect(await store.openSession('device', 'session')).assertTrue();
      const stub = store.getMessages('session', 'device')[0];
      expect(parseThinkingPresentation(stub) !== null).assertTrue();
      expect(client.calls.indexOf('local-db:messages:work-details')).assertEqual(-1);
      await store.loadHistoryDetails('device', 'session', stub.id);
      expect(store.historyDetailState('device', 'session', stub.id)).assertEqual('complete');
      await store.resubscribeAndHeal('device', 'session');
      expect(store.getMessages('session', 'device').some((row: RemoteMessage) => row.id === 'a')).assertTrue();
      expect(store.historyDetailState('device', 'session', stub.id)).assertEqual('complete');
      await store.closeSession('session', 'device');
    });
    it('uses_legacy_history_only_when_the_host_does_not_advertise_views', 0, async () => {
      const client = new ProjectionClient(); client.supported = false;
      const store = new MessageStore(); store.attach(client);
      expect(await store.openSession('device', 'session')).assertTrue();
      expect(client.calls.indexOf('local-db:messages:view')).assertEqual(-1);
      expect(client.calls.indexOf('local-db:messages:list') >= 0).assertTrue();
      await store.closeSession('session', 'device');
    });
    it('shares_view_requests_but_rejects_a_retired_connection', 0, async () => {
      const client = new ProjectionClient();
      const adapter = new HistoryViewAdapter();
      adapter.available(client, 'device', 'session');
      client.delayedPage = new DeferredValue<Envelope>();
      const a = adapter.page(client, 'device', 'session', false, '1', () => client.epoch === 1).then(() => false, () => true);
      const b = adapter.page(client, 'device', 'session', false, '1', () => client.epoch === 1).then(() => false, () => true);
      expect(client.calls.length).assertEqual(1);
      client.epoch = 2;
      adapter.available(client, 'device', 'session');
      client.delayedPage.resolve(success(client.page));
      expect(await a).assertTrue(); expect(await b).assertTrue();
    });
    it('retains_only_a_proven_history_prefix', 0, () => {
      const a = new RemoteMessage(); a.id = 'a';
      const b = new RemoteMessage(); b.id = 'b';
      const c = new RemoteMessage(); c.id = 'c';
      expect(projectedHistoryPrefix([a, b, c], [b, c], true).length).assertEqual(1);
      expect(projectedHistoryPrefix([a, c], [b, c], true).length).assertEqual(0);
      expect(projectedHistoryPrefix([a, b, c], [b, c], false).length).assertEqual(0);
    });
    it('disambiguates_only_visible_distinct_computers', 0, () => {
      const a = new ProjectMachine(); a.deviceId = 'a'; a.name = 'Mac'; a.online = true;
      const b = new ProjectMachine(); b.deviceId = 'b'; b.name = 'mac';
      expect(projectMachineLabel('a', '', [a, b], 'Offline')).assertEqual('Mac · a');
      expect(projectMachineLabel('b', '', [a, b], 'Offline')).assertEqual('mac · b · Offline');
      expect(projectMachineLabel('a', '', [a, a], 'Offline')).assertEqual('Mac');
      expect(projectMachineLabel('a', 'a', [a, b], 'Offline')).assertEqual('');
    });
    it('resolves_implicit_native_sources_and_preserves_legacy_visibility', 0, () => {
      const raw = JSON.parse('{"providers":[{"id":"other","connected":true,"agents":["codex"],"models":{"codex":[{"id":"m"}]}},{"id":"openai","connected":true,"suspended":true,"agents":["codex"],"models":{"codex":[{"id":"m","defaultEnabled":false}]}}]}') as Object;
      const actual = parseProviderModelOptions(raw, 'codex', new Map(), { model: 'm', providerId: '' }, true);
      expect(actual.find((row) => row.selectedRoute)?.providerId).assertEqual('openai');
      const fresh = parseProviderModelOptions(raw, 'codex', new Map(), { model: 'm', providerId: '' });
      expect(fresh.find((row) => row.selectedRoute)?.providerId).assertEqual('other');
      const missing = parseProviderModelOptions(raw, 'codex', new Map(), { model: 'm', providerId: 'missing' }, true);
      expect(missing.some((row) => row.selectedRoute)).assertFalse();
    });
    it('shows_public_account_identity_and_keeps_retired_models_out_of_new_routes', 0, () => {
      const raw = JSON.parse('{"providers":[{"id":"copy-a","name":"OpenAI","subscriptionAccount":{"identity":"account-a"},"connected":true,"agents":["codex"],"models":{"codex":[{"id":"retired","status":"retired"},{"id":"active"}]}},{"id":"copy-b","name":"OpenAI","subscriptionAccount":{"identity":"account-b"},"connected":true,"agents":["codex"],"models":{"codex":[{"id":"active"}]}}]}') as Object;
      const rows = parseProviderModelOptions(raw, 'codex', new Map(), undefined);
      expect(rows.length).assertEqual(2);
      const groups = groupComposerModelOptions(rows);
      expect(groups[0].name.indexOf('account-a') >= 0).assertTrue();
      expect(groups[1].name.indexOf('account-b') >= 0).assertTrue();
      const current = parseProviderModelOptions(raw, 'codex', new Map(), {model: 'retired', providerId: 'copy-a'}, true);
      expect(current.find((row) => row.id === 'retired')?.suspended).assertTrue();
    });
    it('keeps_suspended_actual_route_but_blocks_new_routes', 0, () => {
      const raw = JSON.parse('{"providers":[{"id":"account-2","name":"Second","connected":true,"suspended":true,"agents":["codex"],"models":{"codex":[{"id":"model-a","contextWindow":100000},{"id":"model-b"}]}}]}') as Object;
      const visibility = new Map<string, boolean>();
      expect(parseProviderModelOptions(raw, 'codex', visibility, { model: 'model-a', providerId: 'account-2' }).length).assertEqual(0);
      const actual = parseProviderModelOptions(raw, 'codex', visibility, { model: 'model-a', providerId: 'account-2' }, true);
      expect(actual.length).assertEqual(1);
      expect(actual[0].suspended).assertTrue();
      expect(actual[0].contextWindow).assertEqual(100000);
      expect(hasProviderCatalog(JSON.parse('{"providers":[]}') as Object)).assertTrue();
      expect(hasProviderCatalog(undefined)).assertFalse();
    });
    it('guards_local_and_ssh_window_boundaries_without_guessing', 0, () => {
      expect(modelWindowSwitchDecision(89999, 100000, 'ssh')).assertEqual('allow');
      expect(modelWindowSwitchDecision(90000, 100000, 'ssh')).assertEqual('blocked');
      expect(modelWindowSwitchDecision(99999, 100000, '')).assertEqual('allow');
      expect(modelWindowSwitchDecision(100000, 100000, '')).assertEqual('confirm');
      expect(modelWindowSwitchDecision(100000, NaN, '')).assertEqual('allow');
      expect(modelWindowSwitchDecision(Infinity, 100000, 'ssh')).assertEqual('allow');
    });
    it('preserves_explicit_directory_spaces_and_rejects_bad_preferences', 0, () => {
      const preferences = parseNewSessionPreferences('{"workspaceKind":"project","workingDirByDevice":{"a":" /work/project ","b":"  ","c":42}}');
      expect(preferences.workspaceKind).assertEqual('project');
      expect(preferences.workingDirByDevice['a']).assertEqual(' /work/project ');
      expect(Object.keys(preferences.workingDirByDevice).length).assertEqual(1);
      expect(parseNewSessionPreferences('bad').workspaceKind).assertEqual('');
    });
    it('reads_nested_history_prose_and_defers_work_bodies', 0, () => {
      const raw = JSON.parse('{"version":1,"items":[{"type":"work","children":[{"type":"messages","messages":[{"id":"u","clientId":"u","role":"user","content":"hello","createdAt":"2026-09-10T00:00:00Z"}]},{"type":"work","summary":{"key":"w","firstMessageId":"a","lastMessageId":"z","startedAtMs":1000,"endedAtMs":3000,"messageCount":500}}]}],"hasMore":true,"nextCursor":"older"}') as Object;
      const page = parseHistoryProjection(raw, 'session');
      expect(page.messages.length).assertEqual(2);
      expect(page.messages[0].content).assertEqual('hello');
      expect(page.messages[1].id).assertEqual('history-work:w');
      expect(page.messages[1].role).assertEqual('thinking');
      expect(page.nextCursor).assertEqual('older');
      expect(historyViewUnavailable('CHANNEL_NOT_ALLOWED')).assertTrue();
      expect(historyViewUnavailable('timeout')).assertFalse();
      let rejected = false;
      try { parseHistoryProjection(JSON.parse('{"version":1,"items":[],"hasMore":true}') as Object, 'session'); }
      catch (e) { rejected = true; }
      expect(rejected).assertTrue();
    });
    it('keeps_currency_and_missing_quota_distinct_from_zero', 0, () => {
      const valid = projectAccountUsage(JSON.parse('{"currency":"CNY","spend":0,"maxBudget":100,"todaySpend":0}') as Object, 'gateway', '');
      expect(valid.lines.length).assertEqual(2);
      expect(valid.lines[0].indexOf('CNY') >= 0).assertTrue();
      expect(projectAccountUsage(JSON.parse('{"spend":4,"maxBudget":100}') as Object, 'gateway', '').lines.length).assertEqual(0);
    });
    it('shows_generic_and_matching_model_buckets_without_foreign_quota', 0, () => {
      const raw = JSON.parse('{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25}},"spark":{"limitName":"Spark","primary":{"usedPercent":50}},"other":{"limitName":"Other","primary":{"usedPercent":99}}}}') as Object;
      const selected = projectAccountUsage(raw, 'chatgpt', 'gpt-spark', 1000);
      expect(selected.lines.length).assertEqual(2);
      expect(selected.lines[0].indexOf('75%') >= 0).assertTrue();
      expect(selected.lines[1].indexOf('50%') >= 0).assertTrue();
      const expired = projectAccountUsage(JSON.parse('{"primary":{"usedPercent":20,"resetsAt":1}}') as Object, 'chatgpt', '', 2000);
      expect(expired.lines.length).assertEqual(0);
    });
  });
}
