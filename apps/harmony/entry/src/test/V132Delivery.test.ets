import { describe, expect, it } from '@ohos/hypium';
import { DlClient, DlClientOptions, DlError, DlInvokeOptions } from '../main/ets/core/device-link/DlClient';
import { Envelope } from '../main/ets/core/device-link/DlProtocol';
import { RemoteSession } from '../main/ets/core/tasks/TaskModels';
import { SerializedComposerDocument } from '../main/ets/core/messages/ComposerDocument';
import { InputQueueStore, PendingQueueBubble, parseInputProjection, pendingQueueBubbleRenderKey } from '../main/ets/core/messages/InputQueueStore';
import {
  InputDeliveryState, boundedDeliveryClientIds, inputDeliveryResendAllowed, parseInputDeliveryProjection,
} from '../main/ets/core/messages/InputDeliveryProjection';

class DeliveryDeferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void = (_value: T): void => {};

  constructor() {
    this.promise = new Promise<T>((resolve) => { this.resolve = resolve; });
  }
}

function deliveryEnvelope(result: Object): Envelope {
  const payload: Record<string, Object> = {};
  payload['ok'] = true;
  payload['result'] = result;
  const envelope = new Envelope();
  envelope.payload = payload;
  return envelope;
}

function deliveryProjection(clientId: string = '', state: string = 'unknown', version: number = 1): Record<string, Object> {
  const raw: Record<string, Object> = {};
  raw['sessionId'] = 'session';
  raw['pendingQueue'] = [];
  if (version === 1) raw['inputDeliveryVersion'] = 1;
  if (clientId.length > 0) {
    const receipt: Record<string, Object> = {};
    receipt['clientId'] = clientId;
    receipt['state'] = state;
    raw['deliveryReceipts'] = [receipt];
  }
  return raw;
}

function deliverySession(sessionId: string = 'session'): RemoteSession {
  const session = new RemoteSession();
  session.id = sessionId;
  session.agentKind = 'codex';
  session.model = 'model';
  return session;
}

class DeliveryCall {
  deviceId: string = '';
  channel: string = '';
  args: Object[] = [];
}

class DeliveryClient extends DlClient {
  online: boolean = true;
  epoch: number = 1;
  calls: DeliveryCall[] = [];
  projection: Object = deliveryProjection();
  enqueueResult: Object = deliveryProjection();
  removeResult: Object = deliveryProjection();
  enqueueFailure: DlError | undefined = undefined;
  removeFailure: DlError | undefined = undefined;
  projectionFailure: DlError | undefined = undefined;
  delayedProjection: DeliveryDeferred<Envelope> | undefined = undefined;
  delayedEnqueue: DeliveryDeferred<Envelope> | undefined = undefined;
  readStarted: DeliveryDeferred<boolean> = new DeliveryDeferred<boolean>();
  sendStarted: DeliveryDeferred<boolean> = new DeliveryDeferred<boolean>();

  constructor() {
    super(new DlClientOptions());
  }

  getStatus(): string {
    return this.online ? 'online' : 'connecting';
  }

  connectionIdentity(_deviceId: string): string {
    return String(this.epoch);
  }

  invoke(deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    if (options.preSend !== undefined) options.preSend();
    const call = new DeliveryCall();
    call.deviceId = deviceId;
    call.channel = options.channel;
    call.args = options.args;
    this.calls.push(call);
    if (options.channel === 'maker:input:get-projection') {
      this.readStarted.resolve(true);
      if (this.projectionFailure !== undefined) return Promise.reject(this.projectionFailure);
      return this.delayedProjection?.promise ?? Promise.resolve(deliveryEnvelope(this.projection));
    }
    if (options.channel === 'maker:input:enqueue') {
      this.sendStarted.resolve(true);
      if (this.enqueueFailure !== undefined) return Promise.reject(this.enqueueFailure);
      return this.delayedEnqueue?.promise ?? Promise.resolve(deliveryEnvelope(this.enqueueResult));
    }
    if (options.channel === 'maker:input:remove') {
      if (this.removeFailure !== undefined) return Promise.reject(this.removeFailure);
      return Promise.resolve(deliveryEnvelope(this.removeResult));
    }
    if (options.channel === 'maker:input:cancel-usage-limit-wait') return Promise.resolve(deliveryEnvelope(true));
    return Promise.reject(new Error('UNEXPECTED_DELIVERY_CHANNEL'));
  }

  writes(): number {
    return this.calls.filter((call: DeliveryCall) => call.channel === 'maker:input:enqueue').length;
  }
}

function ownedDeliveryStore(client: DeliveryClient, clientId: string = 'own'): InputQueueStore {
  const store = new InputQueueStore();
  store.attach(client);
  store.seedOptimisticText('device', deliverySession(), 'original', [], clientId);
  return store;
}

function requestedDeliveryIds(call: DeliveryCall): string[] {
  if (call.args.length < 2) return [];
  return (call.args[1] as Record<string, Object>)['deliveryClientIds'] as string[];
}

async function failedDelivery(store: InputQueueStore): Promise<void> {
  try {
    await store.retry('device', 'session', 'own');
  } catch (_error) {
  }
}

export default function v132DeliveryTests(): void {
  describe('v132InputDelivery', () => {
    it('refreshes_queue_action_nodes_when_delivery_state_or_retry_proof_changes', 0, () => {
      const bubble = new PendingQueueBubble();
      bubble.clientId = 'own';
      bubble.phase = 'failed';
      bubble.text = 'same text';
      const safeKey = pendingQueueBubbleRenderKey(bubble);
      bubble.deliveryRetryAllowed = false;
      const uncertainKey = pendingQueueBubbleRenderKey(bubble);
      expect(safeKey === uncertainKey).assertFalse();
      bubble.deliveryState = 'pending';
      expect(pendingQueueBubbleRenderKey(bubble) === uncertainKey).assertFalse();
      expect(bubble.clientId).assertEqual('own');
      expect(bubble.text).assertEqual('same text');
    });
    it('requires_exact_version_one_and_reads_the_four_states', 0, () => {
      for (const state of ['pending', 'accepted', 'removed', 'unknown']) {
        const projection = parseInputProjection(deliveryProjection('own', state), 'session');
        expect(projection.inputDeliveryVersion).assertEqual(1);
        expect(projection.deliveryReceipts[0].state).assertEqual(state);
      }
      for (const raw of [undefined, JSON.parse('null') as Object, [],
        deliveryProjection('own', 'accepted', 0), JSON.parse('{"inputDeliveryVersion":"1"}') as Object,
        JSON.parse('{"inputDeliveryVersion":2,"deliveryReceipts":[]}') as Object]) {
        const projection = parseInputDeliveryProjection(raw);
        expect(projection.inputDeliveryVersion).assertEqual(undefined);
        expect(projection.deliveryReceipts.length).assertEqual(0);
      }
    });

    it('bounds_receipt_count_and_id_length_and_ignores_malformed_rows', 0, () => {
      const raw = deliveryProjection();
      const invalid: Object[] = [JSON.parse('null') as Object, [], 'receipt',
        JSON.parse('{"clientId":"","state":"accepted"}') as Object,
        JSON.parse('{"clientId":3,"state":"accepted"}') as Object,
        JSON.parse('{"clientId":"bad","state":"queued"}') as Object];
      const longest: Record<string, Object> = {};
      longest['clientId'] = 'x'.repeat(256);
      longest['state'] = 'pending';
      const tooLong: Record<string, Object> = {};
      tooLong['clientId'] = 'x'.repeat(257);
      tooLong['state'] = 'accepted';
      raw['deliveryReceipts'] = invalid.concat([longest, tooLong]);
      const parsed = parseInputDeliveryProjection(raw);
      expect(parsed.deliveryReceipts.length).assertEqual(1);
      expect(parsed.deliveryReceipts[0].clientId.length).assertEqual(256);
      const rows: Object[] = [];
      for (let index = 0; index < 65; index += 1) {
        const row: Record<string, Object> = {};
        row['clientId'] = String(index);
        row['state'] = 'unknown';
        rows.push(row);
      }
      raw['deliveryReceipts'] = rows;
      expect(parseInputDeliveryProjection(raw).deliveryReceipts.length).assertEqual(64);
    });

    it('does_not_downgrade_conflicting_duplicate_receipts', 0, () => {
      const raw = JSON.parse('{"inputDeliveryVersion":1,"deliveryReceipts":[{"clientId":"own","state":"accepted"},{"clientId":"own","state":"unknown"},{"clientId":"own","state":"removed"},{"clientId":"own","state":"pending"}]}') as Object;
      const projection = parseInputDeliveryProjection(raw);
      expect(projection.deliveryReceipts.length).assertEqual(1);
      expect(projection.deliveryReceipts[0].state).assertEqual('removed');
      expect(parseInputDeliveryProjection(deliveryProjection()).deliveryReceipts.length).assertEqual(0);
    });

    it('bounds_and_deduplicates_query_ids_without_using_absence_as_unsent_proof', 0, () => {
      const ids: string[] = ['', 'own', 'own', 'x'.repeat(257), 'x'.repeat(256)];
      for (let index = 0; index < 70; index += 1) ids.push('id-' + String(index));
      const bounded = boundedDeliveryClientIds(ids);
      expect(bounded.length).assertEqual(64);
      expect(bounded[0]).assertEqual('own');
      expect(bounded[1].length).assertEqual(256);
      for (const state of ['pending', 'accepted', 'removed'] as InputDeliveryState[]) {
        expect(inputDeliveryResendAllowed(state, true)).assertFalse();
        expect(inputDeliveryResendAllowed(state, false)).assertFalse();
      }
      expect(inputDeliveryResendAllowed('unknown', false)).assertFalse();
      expect(inputDeliveryResendAllowed('unknown', true)).assertTrue();
    });

    it('refresh_queries_only_ids_owned_by_this_account_device_and_session', 0, async () => {
      const client = new DeliveryClient();
      const store = ownedDeliveryStore(client);
      store.seedOptimisticText('other-device', deliverySession('other-session'), 'other', [], 'other-id');
      const remote = deliveryProjection('foreign', 'accepted');
      remote['pendingQueue'] = JSON.parse('[{"clientId":"foreign","text":"foreign","persistedContent":"foreign","model":"model","workingDir":"","createOpts":{},"chatMessage":{"role":"user"}}]') as Object;
      store.handleProjectionPush(remote, 'device');
      expect(await store.refresh('device', 'session')).assertTrue();
      const ids = requestedDeliveryIds(client.calls[0]);
      expect(ids.length).assertEqual(1);
      expect(ids[0]).assertEqual('own');
      expect(client.calls[0].deviceId).assertEqual('device');
      expect(client.calls[0].args[0]).assertEqual('session');
      expect(store.getInputDeliveryState('session', 'foreign', 'device')).assertEqual('unknown');
      store.clearAll();
    });

    it('real_store_queries_at_most_64_valid_ids_and_keeps_empty_legacy_call_shape', 0, async () => {
      const client = new DeliveryClient();
      const store = new InputQueueStore();
      store.attach(client);
      await store.refresh('device', 'session');
      expect(client.calls[0].args.length).assertEqual(1);
      for (let index = 0; index < 66; index += 1) {
        store.seedOptimisticText('device', deliverySession(), 'message', [], 'id-' + String(index));
      }
      store.seedOptimisticText('device', deliverySession(), 'long', [], 'x'.repeat(257));
      await store.refresh('device', 'session');
      const ids = requestedDeliveryIds(client.calls[1]);
      expect(ids.length).assertEqual(64);
      expect(ids.every((clientId: string) => clientId.length > 0 && clientId.length <= 256)).assertTrue();
      store.clearAll();
    });

    it('does_not_retry_accepted_pending_or_removed_even_if_later_push_omits_receipts', 0, async () => {
      for (const state of ['accepted', 'pending', 'removed']) {
        const client = new DeliveryClient();
        client.projection = deliveryProjection('own', state);
        const store = ownedDeliveryStore(client);
        await store.refresh('device', 'session');
        expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual(state);
        expect(store.canRetryInputDelivery('session', 'own', 'device')).assertFalse();
        store.handleProjectionPush(deliveryProjection(), 'device');
        await store.enqueueText('device', deliverySession(), 'original', [], 'own');
        await store.retry('device', 'session', 'own');
        expect(client.writes()).assertEqual(0);
        expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual(state);
        store.clearAll();
      }
    });

    it('never_replays_unknown_or_missing_receipt_after_an_inflight_failure', 0, async () => {
      for (const clientId of ['own', '']) {
        const client = new DeliveryClient();
        client.projection = deliveryProjection(clientId, 'unknown');
        client.enqueueFailure = new DlError('TIMEOUT', 'uncertain delivery', true);
        const store = ownedDeliveryStore(client);
        await failedDelivery(store);
        expect(client.writes()).assertEqual(1);
        expect(requestedDeliveryIds(client.calls[1])[0]).assertEqual('own');
        expect(store.canRetryInputDelivery('session', 'own', 'device')).assertFalse();
        const bubble = store.getBubbles('session', 'device').find((item: PendingQueueBubble) => item.clientId === 'own');
        expect(bubble !== undefined).assertTrue();
        expect(bubble?.deliveryState).assertEqual('unknown');
        expect(bubble?.deliveryRetryAllowed).assertFalse();
        client.enqueueFailure = undefined;
        await store.retry('device', 'session', 'own');
        await store.enqueueText('device', deliverySession(), 'original', [], 'own');
        store.activateSession('device', 'session');
        await store.resyncDevice('device');
        expect(client.writes()).assertEqual(1);
        expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual('unknown');
        store.clearAll();
      }
    });

    it('positive_receipt_after_lost_enqueue_ack_does_not_become_a_retryable_failure', 0, async () => {
      for (const state of ['accepted', 'pending', 'removed']) {
        const client = new DeliveryClient();
        client.projection = deliveryProjection('own', state);
        client.enqueueFailure = new DlError('TIMEOUT', 'lost ack', true);
        const store = ownedDeliveryStore(client);
        await failedDelivery(store);
        expect(store.isLocallyFailed('own')).assertFalse();
        client.enqueueFailure = undefined;
        await store.enqueueText('device', deliverySession(), 'original', [], 'own');
        expect(client.writes()).assertEqual(1);
        store.clearAll();
      }
    });

    it('does_not_auto_send_parked_input_when_host_reports_a_positive_receipt', 0, async () => {
      for (const state of ['accepted', 'pending', 'removed']) {
        const client = new DeliveryClient();
        client.online = false;
        client.projection = deliveryProjection('own', state);
        const store = new InputQueueStore();
        store.attach(client);
        await store.enqueueText('device', deliverySession(), 'original', [], 'own');
        store.activateSession('device', 'session');
        client.online = true;
        await store.resyncDevice('device');
        expect(client.writes()).assertEqual(0);
        expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual(state);
        store.clearAll();
      }
    });

    it('unknown_only_permits_auto_send_with_independent_local_unsent_proof', 0, async () => {
      for (const version of [0, 1]) {
        const client = new DeliveryClient();
        client.online = false;
        client.projection = deliveryProjection('own', 'unknown', version);
        client.enqueueResult = deliveryProjection('own', 'accepted', version);
        const store = new InputQueueStore();
        store.attach(client);
        await store.enqueueText('device', deliverySession(), 'original', [], 'own');
        store.activateSession('device', 'session');
        client.online = true;
        await store.resyncDevice('device');
        expect(client.writes()).assertEqual(1);
        await store.resyncDevice('device');
        expect(client.writes()).assertEqual(1);
        store.clearAll();
      }
    });

    it('safe_unsent_transport_error_preserves_retry_proof_on_legacy_and_new_hosts', 0, async () => {
      for (const version of [0, 1]) {
        const client = new DeliveryClient();
        client.projection = deliveryProjection('own', 'unknown', version);
        client.enqueueFailure = new DlError('BACKPRESSURE', 'not sent', false);
        client.enqueueResult = deliveryProjection('', 'unknown', version);
        const store = new InputQueueStore();
        store.attach(client);
        await store.enqueueText('device', deliverySession(), 'original', [], 'own');
        expect(client.writes()).assertEqual(1);
        client.enqueueFailure = undefined;
        store.activateSession('device', 'session');
        await store.resyncDevice('device');
        expect(client.writes()).assertEqual(2);
        store.clearAll();
      }
    });

    it('legacy_host_keeps_existing_manual_retry_but_not_automatic_uncertain_replay', 0, async () => {
      const client = new DeliveryClient();
      client.projection = deliveryProjection('', 'unknown', 0);
      client.enqueueResult = deliveryProjection('', 'unknown', 0);
      client.enqueueFailure = new DlError('TIMEOUT', 'lost ack', true);
      const store = ownedDeliveryStore(client);
      await failedDelivery(store);
      expect(store.isLocallyFailed('own')).assertTrue();
      expect(store.canRetryInputDelivery('session', 'own', 'device')).assertTrue();
      client.enqueueFailure = undefined;
      await store.retry('device', 'session', 'own');
      expect(client.writes()).assertEqual(2);
      store.activateSession('device', 'session');
      await store.resyncDevice('device');
      expect(client.writes()).assertEqual(2);
      store.clearAll();
    });

    it('channel_not_allowed_readback_never_becomes_unsent_evidence_or_auto_replay', 0, async () => {
      for (const version of [0, 1]) {
        const client = new DeliveryClient();
        client.enqueueFailure = new DlError('TIMEOUT', 'uncertain send', true);
        client.projectionFailure = new DlError('CHANNEL_NOT_ALLOWED', 'old host read denied', false);
        const store = ownedDeliveryStore(client);
        if (version === 1) store.handleProjectionPush(deliveryProjection('own'), 'device');
        await failedDelivery(store);
        expect(client.writes()).assertEqual(1);
        expect(store.isLocallyFailed('own')).assertTrue();
        store.activateSession('device', 'session');
        await store.resyncDevice('device');
        expect(client.writes()).assertEqual(1);
        expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual('unknown');
        store.clearAll();
      }
    });

    it('cancellation_receipt_wins_over_late_enqueue_ack_without_resurrection', 0, async () => {
      for (const state of ['removed', 'accepted']) {
        const client = new DeliveryClient();
        const delayed = new DeliveryDeferred<Envelope>();
        client.delayedEnqueue = delayed;
        client.removeResult = deliveryProjection('own', state);
        const store = ownedDeliveryStore(client);
        const sending = store.enqueueText('device', deliverySession(), 'original', [], 'own');
        await client.sendStarted.promise;
        await store.remove('device', 'session', 'own');
        delayed.resolve(deliveryEnvelope(deliveryProjection('own', 'accepted')));
        await sending;
        expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual(state);
        expect(store.getProjection('session', 'device').pendingQueue.length).assertEqual(0);
        expect(store.isLocallyFailed('own')).assertFalse();
        await store.enqueueText('device', deliverySession(), 'original', [], 'own');
        expect(client.writes()).assertEqual(1);
        store.clearAll();
      }
    });

    it('lost_remove_ack_is_reconciled_by_queried_removed_receipt', 0, async () => {
      const client = new DeliveryClient();
      client.removeFailure = new DlError('TIMEOUT', 'lost remove ack', true);
      client.projection = deliveryProjection('own', 'removed');
      const store = ownedDeliveryStore(client);
      await store.remove('device', 'session', 'own');
      const read = client.calls.find((call: DeliveryCall) => call.channel === 'maker:input:get-projection');
      expect(read !== undefined).assertTrue();
      if (read !== undefined) expect(requestedDeliveryIds(read)[0]).assertEqual('own');
      expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual('removed');
      expect(store.getBubbles('session', 'device').length).assertEqual(0);
      store.clearAll();
    });

    it('cancel_during_parked_input_dispatch_calls_host_remove_and_fences_the_send_ack', 0, async () => {
      const client = new DeliveryClient();
      const delayed = new DeliveryDeferred<Envelope>();
      client.online = false;
      client.delayedEnqueue = delayed;
      client.projection = deliveryProjection('own', 'unknown');
      client.removeResult = deliveryProjection('own', 'removed');
      const store = new InputQueueStore();
      store.attach(client);
      await store.enqueueText('device', deliverySession(), 'original', [], 'own');
      store.activateSession('device', 'session');
      client.online = true;
      const resyncing = store.resyncDevice('device');
      await client.sendStarted.promise;
      await store.remove('device', 'session', 'own');
      expect(client.calls.some((call: DeliveryCall) => call.channel === 'maker:input:remove')).assertTrue();
      delayed.resolve(deliveryEnvelope(deliveryProjection('own', 'accepted')));
      await resyncing;
      expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual('removed');
      expect(store.getBubbles('session', 'device').length).assertEqual(0);
      expect(client.writes()).assertEqual(1);
      store.clearAll();
    });

    it('cancel_before_link_open_finishes_prevents_the_enqueue_from_being_sent', 0, async () => {
      const client = new DeliveryClient();
      const opened = new DeliveryDeferred<boolean>();
      client.removeResult = deliveryProjection('own', 'removed');
      const store = ownedDeliveryStore(client);
      store.setLinkOpener(async (_deviceId: string): Promise<void> => { await opened.promise; });
      const sending = store.enqueueText('device', deliverySession(), 'original', [], 'own');
      const cancelling = store.remove('device', 'session', 'own');
      opened.resolve(true);
      await sending;
      await cancelling;
      expect(client.writes()).assertEqual(0);
      expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual('removed');
      store.clearAll();
    });

    it('b1_cancel_readback_includes_current_owned_delivery_ids', 0, async () => {
      const client = new DeliveryClient();
      const waiting = deliveryProjection('own');
      waiting['error'] = 'usage limited';
      waiting['usageLimitWait'] = JSON.parse('{"resumeAt":1000}') as Object;
      const store = ownedDeliveryStore(client);
      store.handleProjectionPush(waiting, 'device');
      await store.cancelUsageLimitWait('device', 'session');
      const read = client.calls.find((call: DeliveryCall) => call.channel === 'maker:input:get-projection');
      if (read === undefined) throw new Error('EXPECTED_CANCEL_READBACK');
      expect(requestedDeliveryIds(read)[0]).assertEqual('own');
      expect(store.getProjection('session', 'device').usageLimitWait).assertEqual(undefined);
      store.clearAll();
    });

    it('late_receipt_cannot_override_a_newer_projection', 0, async () => {
      const client = new DeliveryClient();
      const delayed = new DeliveryDeferred<Envelope>();
      client.delayedProjection = delayed;
      const store = ownedDeliveryStore(client);
      const refreshing = store.refresh('device', 'session');
      await client.readStarted.promise;
      const latest = deliveryProjection('own', 'pending');
      latest['error'] = 'new error';
      store.handleProjectionPush(latest, 'device');
      delayed.resolve(deliveryEnvelope(deliveryProjection('own', 'accepted')));
      expect(await refreshing).assertFalse();
      expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual('pending');
      expect(store.getProjection('session', 'device').error).assertEqual('new error');
      store.clearAll();
    });

    it('wrong_session_projection_cannot_grant_delivery_ownership', 0, async () => {
      const client = new DeliveryClient();
      const raw = deliveryProjection('own', 'accepted');
      raw['sessionId'] = 'wrong-session';
      client.projection = raw;
      const store = ownedDeliveryStore(client);
      expect(await store.refresh('device', 'session')).assertFalse();
      expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual('unknown');
      expect(store.getProjection('session', 'device').pendingQueue[0].text).assertEqual('original');
      store.clearAll();
    });

    it('account_client_connection_and_device_boundaries_discard_late_receipts', 0, async () => {
      for (const boundary of ['account', 'client', 'connection', 'device']) {
        const client = new DeliveryClient();
        const delayed = new DeliveryDeferred<Envelope>();
        client.delayedProjection = delayed;
        const store = ownedDeliveryStore(client);
        const refreshing = store.refresh('device', 'session');
        await client.readStarted.promise;
        let deviceId = 'device';
        if (boundary === 'account') store.clearAll();
        else if (boundary === 'client') store.attach(new DeliveryClient());
        else if (boundary === 'connection') client.epoch += 1;
        else {
          deviceId = 'other-device';
          store.activateSession(deviceId, 'session');
        }
        store.seedOptimisticText(deviceId, deliverySession(), 'new account input', [], 'new-own');
        delayed.resolve(deliveryEnvelope(deliveryProjection('own', 'accepted')));
        expect(await refreshing).assertFalse();
        expect(store.getInputDeliveryState('session', 'own', deviceId)).assertEqual('unknown');
        expect(store.getInputDeliveryState('session', 'new-own', deviceId)).assertEqual('unknown');
        expect(store.getInputDeliveryClientIds('session', deviceId).includes('new-own')).assertTrue();
        if (boundary !== 'connection') {
          expect(store.getInputDeliveryClientIds('session', deviceId).includes('own')).assertFalse();
        }
        store.clearAll();
      }
    });

    it('late_enqueue_ack_cannot_take_ownership_of_new_account_input_with_same_ids', 0, async () => {
      const client = new DeliveryClient();
      const delayed = new DeliveryDeferred<Envelope>();
      client.delayedEnqueue = delayed;
      const store = ownedDeliveryStore(client);
      const sending = store.enqueueText('device', deliverySession(), 'original', [], 'own');
      await client.sendStarted.promise;
      store.clearAll();
      store.seedOptimisticText('device', deliverySession(), 'new account text', [], 'own');
      delayed.resolve(deliveryEnvelope(deliveryProjection('own', 'accepted')));
      await sending;
      expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual('unknown');
      expect(store.getProjection('session', 'device').pendingQueue[0].text).assertEqual('new account text');
      expect(store.isLocallyFailed('own')).assertFalse();
      store.clearAll();
    });

    it('new_deferred_input_survives_an_older_input_receipt_and_its_document_is_untouched', 0, async () => {
      const client = new DeliveryClient();
      const delayed = new DeliveryDeferred<Envelope>();
      client.delayedProjection = delayed;
      const store = ownedDeliveryStore(client);
      const refreshing = store.refresh('device', 'session');
      await client.readStarted.promise;
      const draft = new SerializedComposerDocument();
      draft.text = 'new draft';
      const newClientId = store.deferDocument('device', deliverySession(), draft, [], []);
      delayed.resolve(deliveryEnvelope(deliveryProjection('own', 'accepted')));
      expect(await refreshing).assertTrue();
      expect(draft.text).assertEqual('new draft');
      const bubbles = store.getBubbles('session', 'device');
      expect(bubbles.some((bubble) => bubble.clientId === newClientId && bubble.text === 'new draft')).assertTrue();
      expect(store.getInputDeliveryState('session', newClientId, 'device')).assertEqual('unknown');
      store.clearAll();
    });

    it('unsolicited_foreign_receipt_never_changes_local_ownership_or_retry_proof', 0, async () => {
      const client = new DeliveryClient();
      const store = ownedDeliveryStore(client);
      store.handleProjectionPush(deliveryProjection('foreign', 'removed'), 'device');
      expect(store.getInputDeliveryState('session', 'foreign', 'device')).assertEqual('unknown');
      expect(store.getInputDeliveryClientIds('session', 'device').includes('foreign')).assertFalse();
      await store.enqueueText('device', deliverySession(), 'original', [], 'own');
      expect(client.writes()).assertEqual(1);
      store.clearAll();
    });

    it('prunes_completed_history_beyond_the_evidence_budget_without_reopening_recent_delivery', 0, async () => {
      const client = new DeliveryClient();
      const store = new InputQueueStore();
      store.attach(client);
      for (let index = 0; index < 320; index += 1) {
        const clientId = 'completed-' + String(index);
        store.seedOptimisticText('device', deliverySession(), 'completed', [], clientId);
        store.resolveAppliedDelivery('session', clientId, 'device');
        expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(0);
      }
      expect(store.getInputDeliveryClientIds('session', 'device').length).assertEqual(0);
      expect(store.getInputDeliveryState('session', 'completed-319', 'device')).assertEqual('accepted');
      expect(store.canRetryInputDelivery('session', 'completed-319', 'device')).assertFalse();
      store.seedOptimisticText('device', deliverySession(), 'duplicate', [], 'completed-319');
      await store.enqueueText('device', deliverySession(), 'duplicate', [], 'completed-319');
      expect(client.writes()).assertEqual(0);
      expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(0);
      store.clearAll();
    });

    it('page_close_keeps_uncertain_receipts_and_accepted_inputs_without_history_confirmation', 0, async () => {
      for (const state of ['unknown', 'accepted', 'pending', 'removed']) {
        const client = new DeliveryClient();
        client.projection = deliveryProjection('own', state);
        const store = ownedDeliveryStore(client);
        store.activateSession('device', 'session');
        await store.refresh('device', 'session');
        store.deactivateSession('device', 'session');
        expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(1);
        expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual(state);
        store.clearSession('session', 'device');
        expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(0);
        store.clearAll();
      }
    });

    it('history_confirmation_retains_inflight_ownership_until_the_enqueue_finishes', 0, async () => {
      const client = new DeliveryClient();
      const delayed = new DeliveryDeferred<Envelope>();
      client.delayedEnqueue = delayed;
      const store = ownedDeliveryStore(client);
      store.activateSession('device', 'session');
      const sending = store.enqueueText('device', deliverySession(), 'original', [], 'own');
      await client.sendStarted.promise;
      store.resolveAppliedDelivery('session', 'own', 'device');
      expect(store.getProjection('session', 'device').pendingQueue.length).assertEqual(0);
      expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(1);
      store.deactivateSession('device', 'session');
      expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(1);
      delayed.resolve(deliveryEnvelope(deliveryProjection('own', 'accepted')));
      await sending;
      expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(0);
      expect(store.getInputDeliveryState('session', 'own', 'device')).assertEqual('accepted');
      expect(store.canRetryInputDelivery('session', 'own', 'device')).assertFalse();
      await store.enqueueText('device', deliverySession(), 'duplicate', [], 'own');
      expect(client.writes()).assertEqual(1);
      store.clearAll();
    });

    it('late_history_can_retire_an_input_after_its_local_projection_has_been_discarded', 0, () => {
      const client = new DeliveryClient();
      const store = ownedDeliveryStore(client);
      store.discardProjection('session', 'device');
      expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(1);
      store.setDeliveredClientIds('session', new Set<string>(['own']), 'device');
      expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(0);
      expect(store.canRetryInputDelivery('session', 'own', 'device')).assertFalse();
      store.clearAll();
    });

    it('history_confirmed_input_is_retained_while_queue_locks_still_reference_it', 0, () => {
      const client = new DeliveryClient();
      const store = ownedDeliveryStore(client);
      const locked = deliveryProjection('own', 'pending');
      locked['pendingQueue'] = [store.getProjection('session', 'device').pendingQueue[0].raw];
      locked['queueEditLocks'] = ['own'];
      store.handleProjectionPush(locked, 'device');
      store.setDeliveredClientIds('session', new Set<string>(['own']), 'device');
      expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(1);
      store.handleProjectionPush(deliveryProjection(), 'device');
      expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(0);
      expect(store.canRetryInputDelivery('session', 'own', 'device')).assertFalse();
      store.clearAll();
    });

    it('retired_history_evidence_does_not_block_same_ids_after_client_scope_replacement', 0, () => {
      const client = new DeliveryClient();
      const store = ownedDeliveryStore(client);
      store.resolveAppliedDelivery('session', 'own', 'device');
      expect(store.getInputDeliveryTrackingCount('session', 'device')).assertEqual(0);
      expect(store.canRetryInputDelivery('session', 'own', 'device')).assertFalse();
      store.attach(new DeliveryClient());
      store.seedOptimisticText('device', deliverySession(), 'new scope', [], 'own');
      expect(store.getProjection('session', 'device').pendingQueue[0].text).assertEqual('new scope');
      expect(store.canRetryInputDelivery('session', 'own', 'device')).assertTrue();
      store.clearAll();
    });
  });
}
