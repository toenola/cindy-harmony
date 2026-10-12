import { describe, expect, it } from '@ohos/hypium';
import { DlClient, DlClientOptions, DlError, DlInvokeOptions } from '../main/ets/core/device-link/DlClient';
import { Envelope } from '../main/ets/core/device-link/DlProtocol';
import { InputQueueStore, parseInputProjection } from '../main/ets/core/messages/InputQueueStore';
import {
  readUsageLimitWait, shouldShowUsageLimitWait, usageLimitWaitCancelUnsupported,
} from '../main/ets/core/messages/UsageLimitWait';

class QueueDeferredValue<T> {
  promise: Promise<T>;
  resolve: (value: T) => void = (_value: T): void => {};

  constructor() {
    this.promise = new Promise<T>((resolve) => { this.resolve = resolve; });
  }
}

class QueueInvokeCall {
  deviceId: string = '';
  channel: string = '';
  args: Object[] = [];
}

function queueProjection(sessionId: string, resumeAt: number = 0, error: string = 'usage limited'): Object {
  const raw: Record<string, Object> = {};
  raw['sessionId'] = sessionId;
  raw['pendingQueue'] = [];
  raw['error'] = error;
  raw['errorRetryText'] = 'retry original message';
  if (resumeAt !== 0) {
    const wait: Record<string, Object> = {};
    wait['resumeAt'] = resumeAt;
    raw['usageLimitWait'] = wait;
  }
  return raw;
}

function queueResponse(result: Object | undefined): Envelope {
  const payload: Record<string, Object> = {};
  payload['ok'] = true;
  if (result !== undefined) payload['result'] = result;
  const envelope = new Envelope();
  envelope.payload = payload;
  return envelope;
}

function queueFailure(code: string, message: string): Envelope {
  const failure: Record<string, Object> = {};
  failure['code'] = code;
  failure['message'] = message;
  const payload: Record<string, Object> = {};
  payload['ok'] = false;
  payload['error'] = failure;
  const envelope = new Envelope();
  envelope.payload = payload;
  return envelope;
}

class UsageWaitQueueClient extends DlClient {
  calls: QueueInvokeCall[] = [];
  epochs: Map<string, number> = new Map();
  cancelResponse: Envelope = queueResponse(true);
  projectionResponse: Envelope = queueResponse(queueProjection('session'));
  cancelFailure: DlError | undefined = undefined;
  delayedCancel: QueueDeferredValue<Envelope> | undefined = undefined;
  delayedProjection: QueueDeferredValue<Envelope> | undefined = undefined;
  projectionRequested: QueueDeferredValue<boolean> = new QueueDeferredValue<boolean>();

  constructor() {
    super(new DlClientOptions());
  }

  connectionIdentity(deviceId: string): string {
    return String(this.epochs.get(deviceId) ?? 1);
  }

  invoke(deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    if (options.preSend !== undefined) options.preSend();
    const call = new QueueInvokeCall();
    call.deviceId = deviceId;
    call.channel = options.channel;
    call.args = options.args;
    this.calls.push(call);
    if (options.channel === 'maker:input:cancel-usage-limit-wait') {
      if (this.cancelFailure !== undefined) return Promise.reject(this.cancelFailure);
      return this.delayedCancel?.promise ?? Promise.resolve(this.cancelResponse);
    }
    if (options.channel === 'maker:input:get-projection') {
      this.projectionRequested.resolve(true);
      return this.delayedProjection?.promise ?? Promise.resolve(this.projectionResponse);
    }
    return Promise.reject(new Error('UNEXPECTED_QUEUE_CHANNEL'));
  }
}

function waitingQueue(client: UsageWaitQueueClient): InputQueueStore {
  const store = new InputQueueStore();
  store.attach(client);
  store.handleProjectionPush(queueProjection('session', 1000), 'device');
  return store;
}

async function cancellationError(store: InputQueueStore): Promise<string> {
  try {
    await store.cancelUsageLimitWait('device', 'session');
    return '';
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

export default function v132QueueTests(): void {
  describe('v132UsageLimitQueue', () => {
    it('rejects_missing_and_malformed_wait_records', 0, () => {
      expect(readUsageLimitWait(undefined)).assertEqual(undefined);
      const invalid: Object[] = [JSON.parse('null') as Object, [], 'wait', 1000, true,
        JSON.parse('{}') as Object, JSON.parse('{"resumeAt":"1000"}') as Object,
        JSON.parse('{"resumeAt":null}') as Object];
      for (const value of invalid) expect(readUsageLimitWait(value)).assertEqual(undefined);
      expect(parseInputProjection(undefined, 'session').usageLimitWait).assertEqual(undefined);
      expect(parseInputProjection(queueProjection('session'), 'session').usageLimitWait).assertEqual(undefined);
    });

    it('accepts_only_finite_positive_milliseconds_without_local_deadline_filtering', 0, () => {
      const invalid: number[] = [0, -1, NaN, Infinity, -Infinity];
      for (const resumeAt of invalid) {
        const wait: Record<string, Object> = {};
        wait['resumeAt'] = resumeAt;
        expect(readUsageLimitWait(wait)).assertEqual(undefined);
      }
      for (const resumeAt of [1, 0.5, 1791800000000]) {
        const projection = parseInputProjection(queueProjection('session', resumeAt), 'session');
        expect(projection.usageLimitWait?.resumeAt).assertEqual(resumeAt);
      }
    });

    it('shows_wait_with_error_even_when_pending_queue_is_empty_and_never_resumes_locally', 0, () => {
      const client = new UsageWaitQueueClient();
      const store = waitingQueue(client);
      const projection = store.getProjection('session', 'device');
      expect(projection.pendingQueue.length).assertEqual(0);
      expect(shouldShowUsageLimitWait(projection.error, projection.usageLimitWait)).assertTrue();
      const state = store.getUsageLimitWaitState('session', 'device');
      expect(state.visible).assertTrue();
      expect(state.resumeAt).assertEqual(1000);
      expect(state.canCancel).assertTrue();
      expect(client.calls.length).assertEqual(0);
      store.clearAll();
    });

    it('hides_wait_without_error_and_avoids_calls_for_missing_wait_or_wrong_device', 0, async () => {
      const client = new UsageWaitQueueClient();
      const store = waitingQueue(client);
      await store.cancelUsageLimitWait('other-device', 'session');
      expect(store.getProjection('session', 'device').usageLimitWait?.resumeAt).assertEqual(1000);
      store.handleProjectionPush(queueProjection('session', 1000, ''), 'device');
      expect(store.getUsageLimitWaitState('session', 'device').visible).assertFalse();
      await store.cancelUsageLimitWait('device', 'session');
      store.handleProjectionPush(queueProjection('session'), 'device');
      expect(store.getUsageLimitWaitState('session', 'device').canCancel).assertFalse();
      await store.cancelUsageLimitWait('device', 'session');
      expect(client.calls.length).assertEqual(0);
      store.clearAll();
    });

    it('reads_projection_after_success_and_preserves_host_error_and_retry_text', 0, async () => {
      const client = new UsageWaitQueueClient();
      const store = waitingQueue(client);
      let changed = 0;
      const unsubscribe = store.onChanged(() => { changed += 1; });
      await store.cancelUsageLimitWait('device', 'session');
      expect(client.calls.length).assertEqual(2);
      expect(client.calls[0].channel).assertEqual('maker:input:cancel-usage-limit-wait');
      expect(client.calls[0].deviceId).assertEqual('device');
      expect(client.calls[0].args.length).assertEqual(1);
      expect(client.calls[0].args[0]).assertEqual('session');
      expect(client.calls[1].channel).assertEqual('maker:input:get-projection');
      expect(client.calls[1].args.length).assertEqual(1);
      expect(client.calls[1].args[0]).assertEqual('session');
      expect(store.getProjection('session', 'device').usageLimitWait).assertEqual(undefined);
      expect(store.getProjection('session', 'device').error).assertEqual('usage limited');
      expect(store.getProjection('session', 'device').errorRetryText).assertEqual('retry original message');
      expect(store.getUsageLimitWaitState('session', 'device').cancelling).assertFalse();
      expect(changed >= 2).assertTrue();
      unsubscribe();
      store.clearAll();
    });

    it('accepts_void_cancellation_reply_but_does_not_clear_wait_optimistically', 0, async () => {
      const client = new UsageWaitQueueClient();
      client.cancelResponse = queueResponse(undefined);
      client.projectionResponse = queueResponse(queueProjection('session', 2000));
      const store = waitingQueue(client);
      await store.cancelUsageLimitWait('device', 'session');
      expect(store.getProjection('session', 'device').usageLimitWait?.resumeAt).assertEqual(2000);
      expect(store.getUsageLimitWaitState('session', 'device').visible).assertTrue();
      store.clearAll();
    });

    it('coalesces_duplicate_clicks_and_keeps_wait_visible_until_readback', 0, async () => {
      const client = new UsageWaitQueueClient();
      const delayed = new QueueDeferredValue<Envelope>();
      client.delayedCancel = delayed;
      const store = waitingQueue(client);
      const cancelling = store.cancelUsageLimitWait('device', 'session');
      expect(store.getUsageLimitWaitState('session', 'device').cancelling).assertTrue();
      expect(store.getUsageLimitWaitState('session', 'device').canCancel).assertFalse();
      await store.cancelUsageLimitWait('device', 'session');
      expect(client.calls.length).assertEqual(1);
      expect(store.getProjection('session', 'device').usageLimitWait?.resumeAt).assertEqual(1000);
      delayed.resolve(queueResponse(true));
      await cancelling;
      expect(client.calls.length).assertEqual(2);
      store.clearAll();
    });

    it('preserves_wait_on_explicit_false_and_accepted_false', 0, async () => {
      const replies: Object[] = [false, JSON.parse('{"accepted":false}') as Object];
      for (const reply of replies) {
        const client = new UsageWaitQueueClient();
        client.cancelResponse = queueResponse(reply);
        const store = waitingQueue(client);
        expect(await cancellationError(store)).assertEqual('USAGE_LIMIT_CANCEL_REJECTED');
        const state = store.getUsageLimitWaitState('session', 'device');
        expect(state.cancelError).assertEqual('USAGE_LIMIT_CANCEL_REJECTED');
        expect(state.visible).assertTrue();
        expect(state.canCancel).assertTrue();
        expect(client.calls.length).assertEqual(1);
        expect(store.getProjection('session', 'device').error).assertEqual('usage limited');
        store.clearAll();
      }
    });

    it('keeps_wait_and_exposes_transport_and_permission_failures_then_allows_retry', 0, async () => {
      const client = new UsageWaitQueueClient();
      client.cancelResponse = queueFailure('FORBIDDEN', 'permission denied');
      const store = waitingQueue(client);
      expect((await cancellationError(store)).indexOf('FORBIDDEN') >= 0).assertTrue();
      expect(store.getUsageLimitWaitState('session', 'device').cancelError.indexOf('permission denied') >= 0)
        .assertTrue();
      expect(store.getUsageLimitWaitState('session', 'device').cancelSupported).assertTrue();
      client.cancelFailure = new DlError('TIMEOUT', 'cancel timed out', true);
      expect(await cancellationError(store)).assertEqual('cancel timed out');
      expect(store.getUsageLimitWaitState('session', 'device').cancelError).assertEqual('cancel timed out');
      expect(store.getProjection('session', 'device').usageLimitWait?.resumeAt).assertEqual(1000);
      client.cancelFailure = undefined;
      client.cancelResponse = queueResponse(true);
      await store.cancelUsageLimitWait('device', 'session');
      expect(store.getUsageLimitWaitState('session', 'device').cancelError).assertEqual('');
      expect(store.getProjection('session', 'device').usageLimitWait).assertEqual(undefined);
      store.clearAll();
    });

    it('hides_unsupported_cancel_for_only_the_current_device_connection', 0, async () => {
      const client = new UsageWaitQueueClient();
      client.cancelFailure = new DlError('CHANNEL_NOT_ALLOWED', 'not allowed', false);
      const store = waitingQueue(client);
      await store.cancelUsageLimitWait('device', 'session');
      const state = store.getUsageLimitWaitState('session', 'device');
      expect(state.visible).assertTrue();
      expect(state.cancelSupported).assertFalse();
      expect(state.canCancel).assertFalse();
      expect(state.cancelError).assertEqual('');
      await store.cancelUsageLimitWait('device', 'session');
      expect(client.calls.length).assertEqual(1);
      store.handleProjectionPush(queueProjection('other-session', 1000), 'other-device');
      expect(store.getUsageLimitWaitState('other-session', 'other-device').canCancel).assertTrue();
      store.handleProjectionPush(queueProjection('same-device-session', 1000), 'device');
      expect(store.getUsageLimitWaitState('same-device-session', 'device').canCancel).assertFalse();
      client.epochs.set('device', 2);
      expect(store.getUsageLimitWaitState('session', 'device').canCancel).assertTrue();
      store.clearAll();
    });

    it('recognizes_old_host_envelope_and_no_handler_without_hiding_permission_failures', 0, async () => {
      expect(usageLimitWaitCancelUnsupported('No handler registered for maker:input:cancel-usage-limit-wait'))
        .assertTrue();
      expect(usageLimitWaitCancelUnsupported('permission denied')).assertFalse();
      expect(usageLimitWaitCancelUnsupported('[FORBIDDEN] unsupported selection')).assertFalse();
      expect(usageLimitWaitCancelUnsupported('No handler registered for unrelated-channel')).assertFalse();
      const client = new UsageWaitQueueClient();
      client.cancelResponse = queueFailure('CHANNEL_NOT_ALLOWED', 'old host');
      const store = waitingQueue(client);
      await store.cancelUsageLimitWait('device', 'session');
      expect(store.getUsageLimitWaitState('session', 'device').cancelSupported).assertFalse();
      expect(store.getProjection('session', 'device').usageLimitWait?.resumeAt).assertEqual(1000);
      store.clearAll();
    });

    it('does_not_reuse_unsupported_state_after_account_clear_or_client_replacement', 0, async () => {
      const client = new UsageWaitQueueClient();
      client.cancelResponse = queueFailure('CHANNEL_NOT_ALLOWED', 'old host');
      const store = waitingQueue(client);
      await store.cancelUsageLimitWait('device', 'session');
      store.clearAll();
      store.handleProjectionPush(queueProjection('session', 2000), 'device');
      expect(store.getUsageLimitWaitState('session', 'device').canCancel).assertTrue();
      await store.cancelUsageLimitWait('device', 'session');
      expect(store.getUsageLimitWaitState('session', 'device').canCancel).assertFalse();
      store.attach(new UsageWaitQueueClient());
      expect(store.getUsageLimitWaitState('session', 'device').canCancel).assertTrue();
      store.clearAll();
    });

    it('retains_wait_and_visible_error_if_readback_fails_or_has_wrong_shape', 0, async () => {
      const replies: Envelope[] = [queueFailure('TIMEOUT', 'read timed out'), queueResponse(undefined),
        queueResponse(JSON.parse('{}') as Object), queueResponse(queueProjection('wrong-session'))];
      for (const reply of replies) {
        const client = new UsageWaitQueueClient();
        client.projectionResponse = reply;
        const store = waitingQueue(client);
        expect((await cancellationError(store)).length > 0).assertTrue();
        const state = store.getUsageLimitWaitState('session', 'device');
        expect(state.visible).assertTrue();
        expect(state.cancelError.length > 0).assertTrue();
        expect(state.canCancel).assertTrue();
        expect(store.getProjection('session', 'device').usageLimitWait?.resumeAt).assertEqual(1000);
        expect(store.getProjection('session', 'device').error).assertEqual('usage limited');
        store.clearAll();
      }
    });

    it('does_not_mark_cancel_unsupported_when_only_the_readback_channel_is_rejected', 0, async () => {
      const client = new UsageWaitQueueClient();
      client.projectionResponse = queueFailure('CHANNEL_NOT_ALLOWED', 'projection unavailable');
      const store = waitingQueue(client);
      expect((await cancellationError(store)).indexOf('CHANNEL_NOT_ALLOWED') >= 0).assertTrue();
      expect(store.getUsageLimitWaitState('session', 'device').cancelSupported).assertTrue();
      expect(store.getProjection('session', 'device').usageLimitWait?.resumeAt).assertEqual(1000);
      store.clearAll();
    });

    it('discards_readback_that_arrives_after_a_new_authoritative_push', 0, async () => {
      const client = new UsageWaitQueueClient();
      const delayed = new QueueDeferredValue<Envelope>();
      client.delayedProjection = delayed;
      const store = waitingQueue(client);
      const cancelling = store.cancelUsageLimitWait('device', 'session');
      await client.projectionRequested.promise;
      store.handleProjectionPush(queueProjection('session', 3000, 'new limit'), 'device');
      delayed.resolve(queueResponse(queueProjection('session')));
      await cancelling;
      expect(store.getProjection('session', 'device').usageLimitWait?.resumeAt).assertEqual(3000);
      expect(store.getProjection('session', 'device').error).assertEqual('new limit');
      expect(store.getUsageLimitWaitState('session', 'device').cancelError).assertEqual('');
      store.clearAll();
    });

    it('discards_late_cancel_failure_after_the_wait_has_been_replaced', 0, async () => {
      const client = new UsageWaitQueueClient();
      const delayed = new QueueDeferredValue<Envelope>();
      client.delayedCancel = delayed;
      const store = waitingQueue(client);
      const cancelling = store.cancelUsageLimitWait('device', 'session');
      store.handleProjectionPush(queueProjection('session', 3000, 'new limit'), 'device');
      expect(store.getUsageLimitWaitState('session', 'device').canCancel).assertFalse();
      await store.cancelUsageLimitWait('device', 'session');
      expect(client.calls.length).assertEqual(1);
      delayed.resolve(queueFailure('FORBIDDEN', 'old failure'));
      await cancelling;
      expect(store.getUsageLimitWaitState('session', 'device').cancelError).assertEqual('');
      expect(store.getProjection('session', 'device').usageLimitWait?.resumeAt).assertEqual(3000);
      store.clearAll();
    });

    it('discards_late_cancel_unsupported_after_account_switch_without_poisoning_new_scope', 0, async () => {
      const client = new UsageWaitQueueClient();
      const delayed = new QueueDeferredValue<Envelope>();
      client.delayedCancel = delayed;
      const store = waitingQueue(client);
      const cancelling = store.cancelUsageLimitWait('device', 'session');
      store.clearAll();
      store.handleProjectionPush(queueProjection('session', 3000), 'device');
      delayed.resolve(queueFailure('CHANNEL_NOT_ALLOWED', 'old account'));
      await cancelling;
      expect(store.getUsageLimitWaitState('session', 'device').canCancel).assertTrue();
      expect(store.getProjection('session', 'device').usageLimitWait?.resumeAt).assertEqual(3000);
      expect(client.calls.length).assertEqual(1);
      store.clearAll();
    });

    it('does_not_send_old_account_cancellation_after_a_delayed_link_open', 0, async () => {
      const client = new UsageWaitQueueClient();
      const opened = new QueueDeferredValue<boolean>();
      const store = waitingQueue(client);
      store.setLinkOpener(async (_deviceId: string): Promise<void> => {
        await opened.promise;
      });
      const cancelling = store.cancelUsageLimitWait('device', 'session');
      store.clearAll();
      store.handleProjectionPush(queueProjection('session', 3000), 'device');
      opened.resolve(true);
      await cancelling;
      expect(client.calls.length).assertEqual(0);
      expect(store.getProjection('session', 'device').usageLimitWait?.resumeAt).assertEqual(3000);
      expect(store.getUsageLimitWaitState('session', 'device').canCancel).assertTrue();
      store.clearAll();
    });

    it('discards_readback_after_device_connection_change_session_clear_or_device_invalidation', 0, async () => {
      for (const boundary of ['connection', 'clear', 'invalidate', 'device-switch']) {
        const client = new UsageWaitQueueClient();
        const delayed = new QueueDeferredValue<Envelope>();
        client.delayedProjection = delayed;
        const store = waitingQueue(client);
        const cancelling = store.cancelUsageLimitWait('device', 'session');
        await client.projectionRequested.promise;
        if (boundary === 'connection') {
          client.epochs.set('device', 2);
          store.handleProjectionPush(queueProjection('session', 3000), 'device');
        } else if (boundary === 'clear') {
          store.clearSession('session', 'device');
          store.handleProjectionPush(queueProjection('session', 3000), 'device');
        } else if (boundary === 'invalidate') {
          store.invalidateDevice('device');
        } else {
          store.activateSession('other-device', 'session');
          store.handleProjectionPush(queueProjection('session', 3000), 'other-device');
        }
        delayed.resolve(queueResponse(queueProjection('session')));
        await cancelling;
        if (boundary === 'invalidate') {
          expect(store.getProjection('session', 'device').usageLimitWait).assertEqual(undefined);
        } else {
          const deviceId = boundary === 'device-switch' ? 'other-device' : 'device';
          expect(store.getProjection('session', deviceId).usageLimitWait?.resumeAt).assertEqual(3000);
          expect(store.getUsageLimitWaitState('session', deviceId).canCancel).assertTrue();
        }
        store.clearAll();
      }
    });
  });
}
