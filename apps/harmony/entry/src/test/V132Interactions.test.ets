import { describe, expect, it } from '@ohos/hypium';
import { DlClient, DlClientOptions, DlInvokeOptions } from '../main/ets/core/device-link/DlClient';
import { Envelope } from '../main/ets/core/device-link/DlProtocol';
import {
  AskUserDraft, InteractionStore, PlanReviewDraft, INTERACTION_DECISION_NOT_ACCEPTED,
} from '../main/ets/core/interactions/InteractionStore';
import {
  AskOptionPresentation, askOptionPresentations, isFreeTextAskOptionLabel,
  permissionAutoReviewUnavailableNotice, permissionDescription, permissionSourceDescription, visibleAskOptions,
} from '../main/ets/core/interactions/InteractionPresentation';

class DeferredValue<Value> {
  promise: Promise<Value>;
  resolve: (value: Value) => void = (_value: Value): void => {};

  constructor() {
    this.promise = new Promise<Value>((resolve) => { this.resolve = resolve; });
  }
}

function success(result: Object | undefined = undefined): Envelope {
  const payload: Record<string, Object> = {};
  payload['ok'] = true;
  if (result !== undefined) payload['result'] = result;
  const envelope = new Envelope();
  envelope.payload = payload;
  return envelope;
}

function recordFixture(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

function rawFixture(json: string): Object {
  return JSON.parse(json) as Object;
}

class MockDlClient extends DlClient {
  resolveResult: Object | undefined = recordFixture('{"accepted":true}');
  resolveError: string = '';
  transientFailures: number = 0;
  pendingResult: Object = [];
  pendingError: string = '';
  resolveCalls: number = 0;
  pendingCalls: number = 0;
  devices: string[] = [];
  epoch: number = 1;
  deferredResolves: Map<string, DeferredValue<Envelope>> = new Map();
  deferredPending: DeferredValue<Envelope> | undefined = undefined;
  resolveStarted: DeferredValue<boolean> = new DeferredValue<boolean>();
  pendingStarted: DeferredValue<boolean> = new DeferredValue<boolean>();

  constructor() {
    super(new DlClientOptions());
  }

  connectionIdentity(deviceId: string): string {
    return deviceId + ':' + String(this.epoch);
  }

  invoke(deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    this.devices.push(deviceId);
    if (options.channel === 'maker:resolve-interaction') {
      this.resolveCalls += 1;
      this.resolveStarted.resolve(true);
      const deferred = this.deferredResolves.get(deviceId);
      if (deferred !== undefined) return deferred.promise;
      if (this.resolveCalls <= this.transientFailures) return Promise.reject(new Error('NOT_CONNECTED'));
      if (this.resolveError.length > 0) return Promise.reject(new Error(this.resolveError));
      return Promise.resolve(success(this.resolveResult));
    }
    if (options.channel === 'maker:get-pending-interactions') {
      this.pendingCalls += 1;
      this.pendingStarted.resolve(true);
      if (this.deferredPending !== undefined) return this.deferredPending.promise;
      if (this.pendingError.length > 0) return Promise.reject(new Error(this.pendingError));
      return Promise.resolve(success(this.pendingResult));
    }
    return Promise.reject(new Error('UNEXPECTED_CHANNEL'));
  }
}

function addInteraction(
  store: InteractionStore,
  deviceId: string = 'device',
  sessionId: string = 'session',
  requestId: string = 'request',
  kind: string = 'ask_user_question',
): void {
  const request: Record<string, Object> = {};
  request['requestId'] = requestId;
  request['kind'] = kind;
  const payload: Record<string, Object> = {};
  payload['sessionId'] = sessionId;
  payload['request'] = request;
  store.handleInteractionRequest(payload, deviceId);
}

function attachStore(client: MockDlClient): InteractionStore {
  const store = new InteractionStore();
  store.attach(client);
  addInteraction(store);
  return store;
}

function saveDrafts(store: InteractionStore, deviceId: string = 'device', text: string = 'keep draft'): void {
  const ask = new AskUserDraft();
  ask.customInput = text;
  ask.showCustomInput = true;
  ask.answers.set('Question', text);
  ask.selectedLabels = ['Choice'];
  store.saveAskDraft('request', ask, deviceId, 'session');
  const plan = new PlanReviewDraft();
  plan.planText = text;
  plan.feedback = 'keep feedback';
  store.savePlanDraft('request', plan, deviceId, 'session');
}

async function rejectedMessage(operation: Promise<void>): Promise<string> {
  try {
    await operation;
    return '';
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

export default function v132InteractionTests(): void {
  describe('V132Interactions', () => {
    it('rejects_explicit_refusals_for_every_resolvable_kind_without_pending_reconciliation', 0, async () => {
      for (const kind of ['permission', 'ask_user_question', 'plan_review']) {
        const client = new MockDlClient();
        client.resolveResult = recordFixture('{"accepted":false}');
        const store = new InteractionStore();
        store.attach(client);
        addInteraction(store, 'device', 'session', 'request', kind);
        saveDrafts(store);
        const decision: Record<string, Object> = {};
        decision['kind'] = kind;
        const message = await rejectedMessage(store.resolve('device', 'session', 'request', decision));
        expect(message).assertEqual(INTERACTION_DECISION_NOT_ACCEPTED);
        expect(client.resolveCalls).assertEqual(1);
        expect(client.pendingCalls).assertEqual(0);
        expect(store.getPending('session', 'device').length).assertEqual(1);
        expect(store.readAskDraft('request', 'device', 'session')?.customInput).assertEqual('keep draft');
        expect(store.readPlanDraft('request', 'device', 'session')?.feedback).assertEqual('keep feedback');
        expect(store.resolveError('request', 'device', 'session')).assertEqual(INTERACTION_DECISION_NOT_ACCEPTED);
        expect(store.isResolving('request', 'device', 'session')).assertFalse();
      }
    });

    it('does_not_reconcile_a_refusal_after_a_transient_retry', 0, async () => {
      const client = new MockDlClient();
      client.transientFailures = 1;
      client.resolveResult = recordFixture('{"accepted":false}');
      const store = attachStore(client);
      saveDrafts(store);
      expect(await rejectedMessage(store.resolve('device', 'session', 'request', {})))
        .assertEqual(INTERACTION_DECISION_NOT_ACCEPTED);
      expect(client.resolveCalls).assertEqual(2);
      expect(client.pendingCalls).assertEqual(0);
      expect(store.readAskDraft('request', 'device', 'session')?.customInput).assertEqual('keep draft');
    });

    it('accepts_legacy_void_receipts_without_querying_pending', 0, async () => {
      const client = new MockDlClient();
      client.resolveResult = undefined;
      const store = attachStore(client);
      saveDrafts(store);
      await store.resolve('device', 'session', 'request', {});
      expect(client.pendingCalls).assertEqual(0);
      expect(store.getPending('session', 'device').length).assertEqual(0);
      expect(store.readAskDraft('request', 'device', 'session')).assertEqual(null);
      expect(store.readPlanDraft('request', 'device', 'session')).assertEqual(null);
    });

    it('accepts_positive_receipts_and_only_the_literal_false_is_a_refusal', 0, async () => {
      const receipts = JSON.parse('[{"accepted":true},{"accepted":0},{}]') as Record<string, Object>[];
      for (const receipt of receipts) {
        const client = new MockDlClient();
        client.resolveResult = receipt;
        const store = attachStore(client);
        await store.resolve('device', 'session', 'request', {});
        expect(client.pendingCalls).assertEqual(0);
        expect(store.getPending('session', 'device').length).assertEqual(0);
      }
    });

    it('uses_authoritative_pending_absence_only_after_a_transport_failure', 0, async () => {
      const client = new MockDlClient();
      client.resolveError = 'INVOKE_TIMEOUT';
      client.pendingResult = rawFixture('[{"request":{"requestId":"other","kind":"permission"}}]');
      const store = attachStore(client);
      saveDrafts(store);
      await store.resolve('device', 'session', 'request', {});
      expect(client.resolveCalls).assertEqual(1);
      expect(client.pendingCalls).assertEqual(1);
      expect(client.devices.join(',')).assertEqual('device,device');
      expect(store.getPending('session', 'device').length).assertEqual(0);
      expect(store.readAskDraft('request', 'device', 'session')).assertEqual(null);
    });

    it('keeps_drafts_and_original_transport_error_when_the_request_remains_pending', 0, async () => {
      const client = new MockDlClient();
      client.resolveError = 'INVOKE_TIMEOUT';
      client.pendingResult = rawFixture('[{"request":{"requestId":"request","kind":"ask_user_question"}}]');
      const store = attachStore(client);
      saveDrafts(store);
      expect(await rejectedMessage(store.resolve('device', 'session', 'request', {}))).assertEqual('INVOKE_TIMEOUT');
      expect(client.pendingCalls).assertEqual(1);
      expect(store.getPending('session', 'device').length).assertEqual(1);
      expect(store.readAskDraft('request', 'device', 'session')?.answers.get('Question')).assertEqual('keep draft');
      expect(store.readPlanDraft('request', 'device', 'session')?.planText).assertEqual('keep draft');
    });

    it('keeps_the_card_when_an_old_host_disallows_pending_reconciliation', 0, async () => {
      const client = new MockDlClient();
      client.resolveError = 'INVOKE_TIMEOUT';
      client.pendingError = 'CHANNEL_NOT_ALLOWED';
      const store = attachStore(client);
      saveDrafts(store);
      expect(await rejectedMessage(store.resolve('device', 'session', 'request', {}))).assertEqual('INVOKE_TIMEOUT');
      expect(client.pendingCalls).assertEqual(1);
      expect(store.getPending('session', 'device').length).assertEqual(1);
      expect(store.readAskDraft('request', 'device', 'session')?.customInput).assertEqual('keep draft');
    });

    it('does_not_treat_a_malformed_pending_reply_as_proof_of_success', 0, async () => {
      const client = new MockDlClient();
      client.resolveError = 'INVOKE_TIMEOUT';
      client.pendingResult = recordFixture('{}');
      const store = attachStore(client);
      expect(await rejectedMessage(store.resolve('device', 'session', 'request', {}))).assertEqual('INVOKE_TIMEOUT');
      expect(store.getPending('session', 'device').length).assertEqual(1);
    });

    it('does_not_let_a_late_pending_snapshot_remove_a_new_push_or_draft', 0, async () => {
      const client = new MockDlClient();
      client.resolveError = 'INVOKE_TIMEOUT';
      client.deferredPending = new DeferredValue<Envelope>();
      const store = attachStore(client);
      const operation = rejectedMessage(store.resolve('device', 'session', 'request', {}));
      await client.pendingStarted.promise;
      addInteraction(store);
      saveDrafts(store, 'device', 'new draft');
      client.deferredPending.resolve(success([]));
      expect(await operation).assertEqual('INVOKE_TIMEOUT');
      expect(store.getPending('session', 'device').length).assertEqual(1);
      expect(store.readAskDraft('request', 'device', 'session')?.customInput).assertEqual('new draft');
    });

    it('does_not_use_a_snapshot_from_a_different_connection_for_reconciliation', 0, async () => {
      const client = new MockDlClient();
      client.resolveError = 'INVOKE_TIMEOUT';
      client.deferredPending = new DeferredValue<Envelope>();
      const store = attachStore(client);
      const operation = rejectedMessage(store.resolve('device', 'session', 'request', {}));
      await client.pendingStarted.promise;
      client.epoch += 1;
      client.deferredPending.resolve(success([]));
      expect(await operation).assertEqual('INVOKE_TIMEOUT');
      expect(store.getPending('session', 'device').length).assertEqual(1);
    });

    it('rejects_late_refusals_after_clear_all_without_touching_the_new_generation', 0, async () => {
      const client = new MockDlClient();
      const previous = new DeferredValue<Envelope>();
      client.deferredResolves.set('device', previous);
      const store = attachStore(client);
      const oldOperation = rejectedMessage(store.resolve('device', 'session', 'request', {}));
      store.clearAll();
      addInteraction(store);
      saveDrafts(store, 'device', 'new generation');
      const current = new DeferredValue<Envelope>();
      client.deferredResolves.set('device', current);
      const newOperation = store.resolve('device', 'session', 'request', {});
      previous.resolve(success(recordFixture('{"accepted":false}')));
      expect(await oldOperation).assertEqual(INTERACTION_DECISION_NOT_ACCEPTED);
      expect(client.pendingCalls).assertEqual(0);
      expect(store.isResolving('request', 'device', 'session')).assertTrue();
      expect(store.resolveError('request', 'device', 'session')).assertEqual('');
      expect(store.readAskDraft('request', 'device', 'session')?.customInput).assertEqual('new generation');
      current.resolve(success());
      await newOperation;
    });

    it('isolates_same_request_ids_on_different_devices_during_concurrent_resolves', 0, async () => {
      const client = new MockDlClient();
      const first = new DeferredValue<Envelope>();
      client.deferredResolves.set('device', first);
      const store = attachStore(client);
      addInteraction(store, 'other-device');
      saveDrafts(store, 'device', 'first draft');
      saveDrafts(store, 'other-device', 'second draft');
      const firstOperation = rejectedMessage(store.resolve('device', 'session', 'request', {}));
      await store.resolve('other-device', 'session', 'request', {});
      expect(client.resolveCalls).assertEqual(2);
      expect(store.isResolving('request', 'device', 'session')).assertTrue();
      expect(store.getPending('session', 'other-device').length).assertEqual(0);
      expect(store.readAskDraft('request', 'device', 'session')?.customInput).assertEqual('first draft');
      first.resolve(success(recordFixture('{"accepted":false}')));
      expect(await firstOperation).assertEqual(INTERACTION_DECISION_NOT_ACCEPTED);
      expect(store.resolveError('request', 'other-device', 'session')).assertEqual('');
      expect(store.getPending('session', 'device').length).assertEqual(1);
    });

    it('dismisses_only_the_origin_device_without_cancelling_another_device_resolve', 0, async () => {
      const client = new MockDlClient();
      const deferred = new DeferredValue<Envelope>();
      client.deferredResolves.set('other-device', deferred);
      const store = attachStore(client);
      addInteraction(store, 'other-device');
      saveDrafts(store, 'other-device', 'other draft');
      const operation = store.resolve('other-device', 'session', 'request', {});
      store.handleInteractionDismissed(recordFixture('{"sessionId":"session","requestId":"request"}'), 'device');
      expect(store.isResolving('request', 'other-device', 'session')).assertTrue();
      expect(store.getPending('session', 'other-device').length).assertEqual(1);
      expect(store.readAskDraft('request', 'other-device', 'session')?.customInput).assertEqual('other draft');
      deferred.resolve(success());
      await operation;
    });

    it('does_not_publish_an_old_refusal_into_a_replacement_request_in_the_same_generation', 0, async () => {
      const client = new MockDlClient();
      const previous = new DeferredValue<Envelope>();
      client.deferredResolves.set('device', previous);
      const store = attachStore(client);
      const oldOperation = rejectedMessage(store.resolve('device', 'session', 'request', {}));
      store.handleInteractionDismissed(recordFixture('{"sessionId":"session","requestId":"request"}'), 'device');
      addInteraction(store);
      saveDrafts(store, 'device', 'replacement');
      const current = new DeferredValue<Envelope>();
      client.deferredResolves.set('device', current);
      const newOperation = store.resolve('device', 'session', 'request', {});
      previous.resolve(success(recordFixture('{"accepted":false}')));
      expect(await oldOperation).assertEqual(INTERACTION_DECISION_NOT_ACCEPTED);
      expect(store.isResolving('request', 'device', 'session')).assertTrue();
      expect(store.resolveError('request', 'device', 'session')).assertEqual('');
      expect(store.readAskDraft('request', 'device', 'session')?.customInput).assertEqual('replacement');
      current.resolve(success());
      await newOperation;
    });

    it('isolates_same_request_ids_in_different_sessions_on_the_same_device', 0, async () => {
      const client = new MockDlClient();
      client.resolveResult = recordFixture('{"accepted":false}');
      const store = attachStore(client);
      addInteraction(store, 'device', 'other-session');
      saveDrafts(store);
      const otherDraft = new AskUserDraft();
      otherDraft.customInput = 'other session';
      store.saveAskDraft('request', otherDraft, 'device', 'other-session');
      await rejectedMessage(store.resolve('device', 'session', 'request', {}));
      expect(store.resolveError('request', 'device', 'other-session')).assertEqual('');
      expect(store.readAskDraft('request', 'device', 'other-session')?.customInput).assertEqual('other session');
      client.resolveResult = recordFixture('{"accepted":true}');
      await store.resolve('device', 'other-session', 'request', {});
      expect(store.getPending('session', 'device').length).assertEqual(1);
      expect(store.readAskDraft('request', 'device', 'session')?.customInput).assertEqual('keep draft');
      expect(store.resolveError('request', 'device', 'session')).assertEqual(INTERACTION_DECISION_NOT_ACCEPTED);
    });

    it('allows_a_user_retry_after_refusal_and_clears_only_the_successful_request_state', 0, async () => {
      const client = new MockDlClient();
      client.resolveResult = recordFixture('{"accepted":false}');
      const store = attachStore(client);
      saveDrafts(store);
      await rejectedMessage(store.resolve('device', 'session', 'request', {}));
      client.resolveResult = undefined;
      await store.resolve('device', 'session', 'request', {});
      expect(client.resolveCalls).assertEqual(2);
      expect(client.pendingCalls).assertEqual(0);
      expect(store.resolveError('request', 'device', 'session')).assertEqual('');
      expect(store.readAskDraft('request', 'device', 'session')).assertEqual(null);
      expect(store.getPending('session', 'device').length).assertEqual(0);
    });

    it('retains_request_only_access_for_unambiguous_existing_callers', 0, async () => {
      const client = new MockDlClient();
      client.resolveResult = recordFixture('{"accepted":false}');
      const store = attachStore(client);
      const draft = new AskUserDraft();
      draft.customInput = 'legacy caller';
      store.saveAskDraft('request', draft);
      expect(store.readAskDraft('request')?.customInput).assertEqual('legacy caller');
      await rejectedMessage(store.resolve('device', 'session', 'request', {}));
      expect(store.resolveError('request')).assertEqual(INTERACTION_DECISION_NOT_ACCEPTED);
      expect(store.isResolving('request')).assertFalse();
    });

    it('uses_shared_escape_hatch_boundaries_for_all_five_ui_languages', 0, () => {
      const labels = ['其他（回复说明）', '其他（請說明）', 'Other (please specify)', 'その他（説明）', '기타 (설명)'];
      for (const label of labels) expect(isFreeTextAskOptionLabel(label)).assertTrue();
      for (const label of ['其它', '其他答案', '其他选项：说明', 'Others', 'Something else…']) {
        expect(isFreeTextAskOptionLabel(label)).assertTrue();
      }
    });

    it('preserves_substantive_other_tasks_and_embedded_explanations', 0, () => {
      const labels = ['其他任务', '其他供應商', 'Other tasks', 'その他の質問', '기타 작업', 'sensor_height 要改（回复说明数值）'];
      for (const label of labels) expect(isFreeTextAskOptionLabel(label)).assertFalse();
      expect(isFreeTextAskOptionLabel('')).assertFalse();
      expect(isFreeTextAskOptionLabel('other choice')).assertFalse();
    });

    it('filters_question_projection_without_mutating_the_original_options_or_descriptions', 0, () => {
      const question = recordFixture('{"options":['
        + '{"label":"其他（说明）","description":"model placeholder"},'
        + '{"label":"其他任务","description":"keep meaning"},'
        + '{"label":"Conservative","description":"keep detail"}]}');
      const original = JSON.stringify(question);
      const rows = askOptionPresentations(question);
      expect(rows.length).assertEqual(2);
      expect(rows[0].label).assertEqual('其他任务');
      expect(rows[0].description).assertEqual('keep meaning');
      expect(rows[1].description).assertEqual('keep detail');
      expect(JSON.stringify(question)).assertEqual(original);
    });

    it('supports_empty_visible_options_and_ignores_malformed_wire_rows', 0, () => {
      const escape = new AskOptionPresentation();
      escape.label = 'Other';
      expect(visibleAskOptions([escape]).length).assertEqual(0);
      expect(visibleAskOptions(undefined).length).assertEqual(0);
      expect(askOptionPresentations(recordFixture('{"options":[null,42,[],{"label":7},{"label":"其他"}]}')).length).assertEqual(0);
      expect(askOptionPresentations(recordFixture('{}')).length).assertEqual(0);
    });

    it('reads_permission_source_only_from_valid_optional_metadata', 0, () => {
      expect(permissionSourceDescription(recordFixture('{"metadata":{"imSourceDescription":"来源：Telegram · 开发群"}}')))
        .assertEqual('来源：Telegram · 开发群');
      expect(permissionSourceDescription(recordFixture('{"metadata":{"imSourceDescription":7}}'))).assertEqual('');
      expect(permissionSourceDescription(recordFixture('{"metadata":[]}'))).assertEqual('');
      expect(permissionSourceDescription(recordFixture('{"metadata":null}'))).assertEqual('');
      expect(permissionSourceDescription(recordFixture('{}'))).assertEqual('');
    });

    it('strips_only_the_shared_exact_source_prefix_in_a_pure_projection', 0, () => {
      const source = '来源：Telegram · 开发群';
      const metadata: Record<string, Object> = {};
      metadata['imSourceDescription'] = source;
      const request: Record<string, Object> = {};
      request['kind'] = 'permission';
      request['description'] = source + '\n\nRead the requested file';
      request['metadata'] = metadata;
      const original = JSON.stringify(request);
      expect(permissionSourceDescription(request)).assertEqual(source);
      expect(permissionDescription(request)).assertEqual('Read the requested file');
      expect(JSON.stringify(request)).assertEqual(original);
      request['description'] = source;
      expect(permissionDescription(request)).assertEqual('');
      request['description'] = source + '\nRead the requested file';
      expect(permissionDescription(request)).assertEqual(source + '\nRead the requested file');
      request['description'] = 'Read the requested file\n\n' + source;
      expect(permissionDescription(request)).assertEqual('Read the requested file\n\n' + source);
    });

    it('keeps_legacy_permission_descriptions_when_source_is_missing', 0, () => {
      expect(permissionDescription(recordFixture('{"description":"Read the requested file"}'))).assertEqual('Read the requested file');
      expect(permissionDescription(recordFixture('{"description":"Other source","metadata":{"imSourceDescription":"Known source"}}')))
        .assertEqual('Other source');
      expect(permissionDescription(recordFixture('{"description":7}'))).assertEqual('');
      expect(permissionDescription(recordFixture('{}'))).assertEqual('');
    });

    it('projects_auto_review_failure_separately_without_overwriting_the_im_source', 0, () => {
      const source = '来源：Telegram · 开发群';
      const sourceMetadata: Record<string, Object> = {};
      sourceMetadata['autoReviewUnavailable'] = true;
      sourceMetadata['imSourceDescription'] = source;
      const request: Record<string, Object> = {};
      request['kind'] = 'permission';
      request['description'] = source + '\n\nRead the requested file';
      request['metadata'] = sourceMetadata;
      const original = JSON.stringify(request);
      expect(permissionAutoReviewUnavailableNotice(request)).assertEqual('自动审批没完成，请确认要不要允许这次操作。');
      expect(permissionSourceDescription(request)).assertEqual(source);
      expect(permissionDescription(request)).assertEqual('Read the requested file');
      expect(JSON.stringify(request)).assertEqual(original);
      const ordinary: Record<string, Object> = {};
      ordinary['kind'] = 'permission';
      const metadata: Record<string, Object> = {};
      metadata['imSourceDescription'] = source;
      ordinary['metadata'] = metadata;
      expect(permissionAutoReviewUnavailableNotice(ordinary)).assertEqual('');
      expect(permissionSourceDescription(ordinary)).assertEqual(source);
    });
  });
}
