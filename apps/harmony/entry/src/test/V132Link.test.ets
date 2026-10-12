import { describe, expect, it } from '@ohos/hypium';
import { isRemoteBusyError, isRemoteBusyMessage } from '../main/ets/core/device-link/RemoteInvokePresentation';
import { ConnectionAttemptState } from '../main/ets/core/device-link/ConnectionAttemptState';
import {
  InvokeScheduler, isBackgroundInvoke, bypassInvokeScheduling, invokePhysicalPeerId,
} from '../main/ets/core/device-link/InvokeScheduler';
import {
  DlClient, DlClientOptions, DlInvokeOptions, DlError, assertInvokeSucceeded,
} from '../main/ets/core/device-link/DlClient';
import {
  Envelope, EnvelopeKind, PROTOCOL_VERSION, encodeEnvelope, decodeEnvelope,
} from '../main/ets/core/device-link/DlProtocol';
import { WsAdapter, WsCallbacks, WsMessage } from '../main/ets/network/WsAdapter';

class Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void = (_value: T): void => {};

  constructor() {
    this.promise = new Promise<T>((resolve) => { this.resolve = resolve; });
  }
}

async function flushPromises(): Promise<void> {
  for (let turn = 0; turn < 12; turn += 1) await Promise.resolve();
}

async function failure<T>(promise: Promise<T>): Promise<DlError> {
  try {
    await promise;
    return new DlError('NONE', 'resolved');
  } catch (error) {
    return error instanceof DlError ? error : new DlError('OTHER', 'unexpected error');
  }
}

function holdSlots(scheduler: InvokeScheduler, peerId: string, count: number,
  active: Deferred<number>, background: boolean = false): Promise<DlError>[] {
  const pending: Promise<DlError>[] = [];
  for (let index = 0; index < count; index += 1) {
    pending.push(failure(scheduler.run<number>(peerId, background, 30_000, () => active.promise)));
  }
  return pending;
}

class TestWsMessage implements WsMessage {
  private text: string;

  constructor(text: string) { this.text = text; }
  toString(): string { return this.text; }
}

class TestSocket implements WsAdapter {
  callbacks: WsCallbacks = new WsCallbacks();
  sent: Envelope[] = [];
  terminated: number = 0;

  connect(_url: string, _headers: Record<string, string>): void {}
  send(text: string): boolean {
    const envelope = decodeEnvelope(text);
    if (envelope !== null) this.sent.push(envelope);
    return true;
  }
  close(code: number = 1000, reason: string = ''): void { this.callbacks.onClose(code, reason); }
  terminate(): void {
    this.terminated += 1;
    this.callbacks.onClose(1000, 'terminated');
  }
  setCallbacks(callbacks: WsCallbacks): void { this.callbacks = callbacks; }
  receive(kind: string, payload: Object, requestId: string = '', source: string = ''): void {
    const envelope = new Envelope();
    envelope.kind = kind;
    envelope.payload = payload;
    envelope.id = requestId;
    envelope.src = source;
    this.callbacks.onMessage(new TestWsMessage(encodeEnvelope(envelope)));
  }
  hello(userId: string = 'account-a'): void {
    this.callbacks.onOpen();
    const payload: Record<string, Object> = {};
    payload['serverProtocolVersion'] = PROTOCOL_VERSION;
    payload['deviceId'] = 'controller';
    payload['userId'] = userId;
    this.receive(EnvelopeKind.HELLO_ACK, payload);
  }
  invocations(): Envelope[] { return this.sent.filter((envelope: Envelope) => envelope.kind === EnvelopeKind.INVOKE); }
  succeed(request: Envelope): void {
    const payload: Record<string, Object> = {};
    payload['ok'] = true;
    this.receive(EnvelopeKind.INVOKE_RESULT, payload, request.id, request.dst);
  }
}

class LinkHarness {
  sockets: TestSocket[] = [];
  client: DlClient;
  options: DlClientOptions = new DlClientOptions();

  constructor() {
    this.options.getToken = async () => 'token';
    this.options.getWsUrl = () => 'wss://test.invalid';
    this.options.createWs = (): WsAdapter => {
      const socket = new TestSocket();
      this.sockets.push(socket);
      return socket;
    };
    this.client = new DlClient(this.options);
  }
  async online(): Promise<TestSocket> {
    this.client.start();
    await flushPromises();
    const socket = this.sockets[0];
    socket.hello();
    return socket;
  }
}

function invokeOptions(channel: string = 'maker:send'): DlInvokeOptions {
  const options = new DlInvokeOptions();
  options.channel = channel;
  return options;
}

function clientSlots(client: DlClient, peerId: string): Promise<DlError>[] {
  const pending: Promise<DlError>[] = [];
  for (let index = 0; index < 12; index += 1) pending.push(failure(client.invoke(peerId, invokeOptions())));
  return pending;
}

export default function v132LinkTests(): void {
  describe('v132LinkAlignment', () => {
    it('recognizes_busy_admission_without_relabeling_arbitrary_failures', 0, () => {
      expect(isRemoteBusyError(new DlError('BACKPRESSURE', 'queue full'))).assertTrue();
      expect(isRemoteBusyMessage('local remote invoke queue is full')).assertTrue();
      expect(isRemoteBusyMessage('remote invoke expired before dispatch')).assertTrue();
      expect(isRemoteBusyMessage('authentication failed')).assertFalse();
    });
    it('keeps_only_a_live_connecting_watchdog_without_backoff', 0, () => {
      const attempt = new ConnectionAttemptState();
      expect(attempt.shouldKeep('connecting', false, 1000)).assertFalse();
      attempt.arm(1000, 15_000);
      expect(attempt.shouldKeep('connecting', false, 15_999)).assertTrue();
      expect(attempt.shouldKeep('connecting', false, 16_000)).assertFalse();
      expect(attempt.shouldKeep('connecting', true, 2000)).assertFalse();
      expect(attempt.shouldKeep('stopped', false, 2000)).assertFalse();
      expect(attempt.shouldKeep('online', false, 2000)).assertFalse();
    });

    it('uses_the_restarted_watchdog_deadline_after_websocket_open', 0, () => {
      const attempt = new ConnectionAttemptState();
      attempt.arm(1000, 15_000);
      attempt.arm(6000, 15_000);
      expect(attempt.shouldKeep('connecting', false, 16_001)).assertTrue();
      expect(attempt.shouldKeep('connecting', false, 21_000)).assertFalse();
      attempt.clear();
      expect(attempt.shouldKeep('connecting', false, 7000)).assertFalse();
    });

    it('foreground_flicker_keeps_handshake_but_network_change_restarts', 0, async () => {
      const harness = new LinkHarness();
      harness.client.start();
      await flushPromises();
      const first = harness.sockets[0];
      first.callbacks.onOpen();
      harness.client.connectNow('foreground', true, true);
      await flushPromises();
      expect(harness.sockets.length).assertEqual(1);
      expect(first.terminated).assertEqual(0);
      harness.client.connectNow('network-change', true, true);
      await flushPromises();
      expect(harness.sockets.length).assertEqual(2);
      expect(first.terminated).assertEqual(1);
      harness.client.stop();
    });

    it('does_not_keep_a_backoff_timer_as_a_live_handshake', 0, async () => {
      const harness = new LinkHarness();
      harness.client.start();
      await flushPromises();
      harness.sockets[0].close(1013, 'busy');
      harness.client.connectNow('foreground', true, true);
      await flushPromises();
      expect(harness.sockets.length).assertEqual(2);
      harness.client.stop();
    });

    it('discards_token_results_from_superseded_connect_attempts', 0, async () => {
      const harness = new LinkHarness();
      const oldToken = new Deferred<string | null>();
      let tokenReads = 0;
      harness.options.getToken = (): Promise<string | null> => {
        tokenReads += 1;
        return tokenReads === 1 ? oldToken.promise : Promise.resolve('fresh-token');
      };
      harness.client.start();
      harness.client.connectNow('network-change');
      await flushPromises();
      expect(harness.sockets.length).assertEqual(1);
      oldToken.resolve('old-token');
      await flushPromises();
      expect(harness.sockets.length).assertEqual(1);
      harness.client.stop();
    });

    it('limits_background_to_four_within_the_twelve_total_slots', 0, async () => {
      const scheduler = new InvokeScheduler();
      const active = new Deferred<number>();
      let backgroundStarted = 0;
      let foregroundStarted = 0;
      const pending: Promise<DlError>[] = [];
      for (let index = 0; index < 6; index += 1) {
        pending.push(failure(scheduler.run<number>('a', true, 30_000, () => {
          backgroundStarted += 1;
          return active.promise;
        })));
      }
      for (let index = 0; index < 10; index += 1) {
        pending.push(failure(scheduler.run<number>('a', false, 30_000, () => {
          foregroundStarted += 1;
          return active.promise;
        })));
      }
      expect(backgroundStarted).assertEqual(4);
      expect(foregroundStarted).assertEqual(8);
      active.resolve(1);
      await Promise.all(pending);
      expect(backgroundStarted).assertEqual(6);
      expect(foregroundStarted).assertEqual(10);
    });

    it('prioritizes_queued_user_actions_over_background_refreshes', 0, async () => {
      const scheduler = new InvokeScheduler();
      const background = new Deferred<number>();
      const foreground = new Deferred<number>();
      const pending = holdSlots(scheduler, 'a', 4, background, true);
      pending.push(...holdSlots(scheduler, 'a', 8, foreground));
      const order: string[] = [];
      const nextBackground = scheduler.run<number>('a', true, 30_000, async () => {
        order.push('background');
        return 1;
      });
      const nextForeground = scheduler.run<number>('a', false, 30_000, async () => {
        order.push('foreground');
        return 1;
      });
      background.resolve(1);
      await flushPromises();
      expect(order[0]).assertEqual('foreground');
      foreground.resolve(1);
      await Promise.all(pending);
      await nextForeground;
      await nextBackground;
    });

    it('bounds_waiting_to_128_and_reserves_32_positions_for_user_actions', 0, async () => {
      const scheduler = new InvokeScheduler();
      const active = new Deferred<number>();
      const pending = holdSlots(scheduler, 'a', 100, active, true);
      const backgroundOverflow = await failure(scheduler.run<number>('a', true, 30_000, async () => 1));
      expect(backgroundOverflow.code).assertEqual('BACKPRESSURE');
      expect(backgroundOverflow.inFlight).assertFalse();
      pending.push(...holdSlots(scheduler, 'a', 40, active));
      const foregroundOverflow = await failure(scheduler.run<number>('a', false, 30_000, async () => 1));
      expect(foregroundOverflow.code).assertEqual('BACKPRESSURE');
      scheduler.clear(new DlError('NOT_CONNECTED', 'stop', true));
      active.resolve(1);
      const results = await Promise.all(pending);
      expect(results.filter((error: DlError) => error.code === 'NOT_CONNECTED').length).assertEqual(128);
      expect(results.every((error: DlError) => !error.inFlight)).assertTrue();
    });

    it('rechecks_wallclock_before_dequeue_even_if_timers_have_not_fired', 0, async () => {
      let nowMs = 1000;
      const scheduler = new InvokeScheduler(() => nowMs);
      const active = new Deferred<number>();
      const pending = holdSlots(scheduler, 'a', 12, active);
      let sent = 0;
      const expired = failure(scheduler.run<number>('a', false, 1000, async () => { sent += 1; return 1; }));
      nowMs = 2000;
      active.resolve(1);
      await Promise.all(pending);
      const result = await expired;
      expect(result.code).assertEqual('BACKPRESSURE');
      expect(result.inFlight).assertFalse();
      expect(sent).assertEqual(0);
    });

    it('expires_waiting_jobs_without_waiting_for_active_work_to_settle', 0, async () => {
      const scheduler = new InvokeScheduler();
      const active = new Deferred<number>();
      const pending = holdSlots(scheduler, 'a', 12, active);
      let sent = 0;
      const result = await failure(scheduler.run<number>('a', false, 1, async () => { sent += 1; return 1; }));
      expect(result.code).assertEqual('BACKPRESSURE');
      expect(sent).assertEqual(0);
      active.resolve(1);
      await Promise.all(pending);
    });

    it('cancels_only_one_peer_and_keeps_active_slots_until_settlement', 0, async () => {
      const scheduler = new InvokeScheduler();
      const active = new Deferred<number>();
      const pending = holdSlots(scheduler, 'a', 12, active);
      let sent = 0;
      const cancelled = failure(scheduler.run<number>('a', false, 30_000, async () => { sent += 1; return 1; }));
      scheduler.cancel('a', new DlError('NOT_CONNECTED', 'peer closed', true));
      expect((await cancelled).inFlight).assertFalse();
      const fresh = scheduler.run<number>('a', false, 30_000, async () => { sent += 1; return 1; });
      expect(sent).assertEqual(0);
      expect(await scheduler.run<number>('b', false, 30_000, async () => 42)).assertEqual(42);
      active.resolve(1);
      await Promise.all(pending);
      await fresh;
      expect(sent).assertEqual(1);
    });

    it('retains_active_capacity_when_cleared_for_a_reconnect', 0, async () => {
      const scheduler = new InvokeScheduler();
      const active = new Deferred<number>();
      const pending = holdSlots(scheduler, 'a', 12, active);
      scheduler.clear(new DlError('NOT_CONNECTED', 'reconnect'));
      let sent = 0;
      const next = scheduler.run<number>('a', false, 30_000, async () => { sent += 1; return 1; });
      expect(sent).assertEqual(0);
      active.resolve(1);
      await Promise.all(pending);
      await next;
      expect(sent).assertEqual(1);
    });

    it('shares_physical_capacity_but_cancels_only_the_exact_scoped_peer', 0, async () => {
      const scheduler = new InvokeScheduler();
      const active = new Deferred<number>();
      const scoped = '[["unused"]]';
      const hostPeer = '["task-a","host",null,"a"]'.padEnd(129, '~');
      const guestPeer = '["task-b","guest","member","a"]'.padEnd(129, '~');
      expect(invokePhysicalPeerId(hostPeer)).assertEqual('a');
      expect(invokePhysicalPeerId(guestPeer)).assertEqual('a');
      expect(invokePhysicalPeerId(scoped)).assertEqual(scoped);
      const pending = holdSlots(scheduler, 'a', 12, active);
      let sent = 0;
      const host = failure(scheduler.run<number>(hostPeer, false, 30_000, async () => { sent += 1; return 1; }));
      const guest = scheduler.run<number>(guestPeer, false, 30_000, async () => { sent += 1; return 1; });
      scheduler.cancel(hostPeer, new DlError('NOT_CONNECTED', 'scope closed'));
      expect((await host).code).assertEqual('NOT_CONNECTED');
      expect(sent).assertEqual(0);
      active.resolve(1);
      await Promise.all(pending);
      await guest;
      expect(sent).assertEqual(1);
    });

    it('releases_slots_after_sync_and_async_failures_without_retry', 0, async () => {
      const scheduler = new InvokeScheduler();
      let attempts = 0;
      await failure(scheduler.run<number>('a', true, 1000, () => {
        attempts += 1;
        throw new DlError('CANCELLED', 'cancelled before send');
      }));
      await failure(scheduler.run<number>('a', true, 1000, async () => {
        attempts += 1;
        throw new DlError('SEND_FAILED', 'already sent', true);
      }));
      expect(await scheduler.run<number>('a', true, 1000, async () => 42)).assertEqual(42);
      expect(attempts).assertEqual(2);
    });

    it('shares_active_and_waiting_quotas_between_physical_and_scoped_aliases', 0, async () => {
      const peers: string[] = ['a', '["task-a","host",null,"a"]'.padEnd(129, '~'),
        '["task-b","guest","member","a"]'.padEnd(129, '~')];
      for (const background of [false, true]) {
        const scheduler = new InvokeScheduler();
        const active = new Deferred<number>();
        const activeLimit = background ? 4 : 12;
        const waitingLimit = background ? 96 : 128;
        let started = 0;
        const pending: Promise<DlError>[] = [];
        for (let index = 0; index < activeLimit + waitingLimit; index += 1) {
          pending.push(failure(scheduler.run<number>(peers[index % peers.length], background, 30_000, () => {
            started += 1;
            return active.promise;
          })));
        }
        expect(started).assertEqual(activeLimit);
        for (const peer of peers) {
          const overflow = await failure(scheduler.run<number>(peer, background, 30_000, async () => 1));
          expect(overflow.code).assertEqual('BACKPRESSURE');
        }
        expect(await scheduler.run<number>('other', background, 30_000, async () => 42)).assertEqual(42);
        scheduler.clear(new DlError('NOT_CONNECTED', 'stop'));
        active.resolve(1);
        await Promise.all(pending);
        expect(started).assertEqual(activeLimit);
      }
    });

    it('uses_the_exact_upstream_background_list_and_control_exemptions', 0, () => {
      const channels: string[] = ['git-context:pr-refs:list', 'git-context:pr-status',
        'maker:schedule:list-sidebar-index-runs', 'maker:usage:device-rows',
        'maker:session-background-activity', 'maker:session-background-tasks:list'];
      expect(channels.every((channel: string) => isBackgroundInvoke(channel))).assertTrue();
      expect(isBackgroundInvoke('local-db:sessions:list')).assertFalse();
      expect(isBackgroundInvoke('maker:send')).assertFalse();
      expect(bypassInvokeScheduling('device-link:subscribe', [])).assertTrue();
      expect(bypassInvokeScheduling('device-link:unsubscribe', [])).assertTrue();
      const heartbeat: Record<string, Object> = {};
      heartbeat['op'] = 'heartbeat';
      expect(bypassInvokeScheduling('device-link:remote-desktop:v1', [heartbeat])).assertTrue();
      expect(bypassInvokeScheduling('maker:send', [heartbeat])).assertFalse();
    });

    it('client_control_traffic_bypasses_a_full_business_inflight_window', 0, async () => {
      const harness = new LinkHarness();
      const socket = await harness.online();
      const pending = clientSlots(harness.client, 'a');
      const queued = failure(harness.client.invoke('a', invokeOptions()));
      const subscription = harness.client.subscribe('a', ['sessions']);
      const unsubscription = harness.client.unsubscribe('a', ['sessions']);
      expect(socket.invocations().length).assertEqual(14);
      socket.succeed(socket.invocations()[12]);
      socket.succeed(socket.invocations()[13]);
      await subscription;
      await unsubscription;
      expect(socket.invocations().length).assertEqual(14);
      harness.client.stop();
      expect((await queued).inFlight).assertFalse();
      const results = await Promise.all(pending);
      expect(results.every((error: DlError) => error.inFlight)).assertTrue();
    });

    it('checks_caller_cancellation_synchronously_before_dispatch', 0, async () => {
      const harness = new LinkHarness();
      const socket = await harness.online();
      const pending = clientSlots(harness.client, 'a');
      let cancelled = false;
      const options = invokeOptions();
      options.preSend = (): void => {
        if (cancelled) throw new DlError('CANCELLED', 'caller cancelled');
      };
      const queued = failure(harness.client.invoke('a', options));
      cancelled = true;
      socket.succeed(socket.invocations()[0]);
      await flushPromises();
      expect((await queued).code).assertEqual('CANCELLED');
      expect(socket.invocations().length).assertEqual(12);
      harness.client.stop();
      await Promise.all(pending);
    });

    it('peer_close_cancels_its_writes_without_disrupting_other_peers', 0, async () => {
      const harness = new LinkHarness();
      const socket = await harness.online();
      const pending = clientSlots(harness.client, 'a');
      const queued = failure(harness.client.invoke('a', invokeOptions()));
      const other = harness.client.invoke('b', invokeOptions());
      const payload: Record<string, Object> = {};
      payload['reason'] = 'peer closed';
      socket.receive(EnvelopeKind.LINK_CLOSE, payload, '', 'a');
      expect((await queued).inFlight).assertFalse();
      const results = await Promise.all(pending);
      expect(results.every((error: DlError) => error.inFlight)).assertTrue();
      expect(harness.client.getStatus()).assertEqual('online');
      expect(socket.terminated).assertEqual(0);
      socket.succeed(socket.invocations()[12]);
      await other;
      expect(socket.invocations().length).assertEqual(13);
      harness.client.stop();
    });

    it('account_switch_discards_queued_writes_and_never_replays_sent_writes', 0, async () => {
      const harness = new LinkHarness();
      const first = await harness.online();
      const pending = clientSlots(harness.client, 'a');
      const queued = failure(harness.client.invoke('a', invokeOptions()));
      harness.client.stop();
      harness.client.start();
      await flushPromises();
      const second = harness.sockets[1];
      second.hello('account-b');
      expect((await queued).inFlight).assertFalse();
      const results = await Promise.all(pending);
      expect(results.every((error: DlError) => error.inFlight)).assertTrue();
      expect(first.invocations().length).assertEqual(12);
      expect(second.invocations().length).assertEqual(0);
      harness.client.stop();
    });

    it('rechecks_peer_ownership_after_dequeue_and_before_the_websocket_send', 0, async () => {
      const harness = new LinkHarness();
      const socket = await harness.online();
      const pending = clientSlots(harness.client, 'a');
      const before = harness.client.connectionIdentity('a');
      const queued = failure(harness.client.invoke('a', invokeOptions()));
      harness.client.closeLink('a', 'replaced');
      expect(harness.client.connectionIdentity('a') === before).assertFalse();
      expect((await queued).code).assertEqual('LINK_NOT_OPEN');
      expect(socket.invocations().length).assertEqual(12);
      await Promise.all(pending);
      harness.client.stop();
    });

    it('connection_replacement_cancels_unsent_work_without_replaying_inflight_writes', 0, async () => {
      const harness = new LinkHarness();
      const first = await harness.online();
      const pending = clientSlots(harness.client, 'a');
      const queued = failure(harness.client.invoke('a', invokeOptions()));
      first.close(1006, 'lost connection');
      harness.client.connectNow('network-change');
      await flushPromises();
      const second = harness.sockets[1];
      second.hello();
      const cancelled = await queued;
      expect(cancelled.code).assertEqual('NOT_CONNECTED');
      expect(cancelled.inFlight).assertFalse();
      const results = await Promise.all(pending);
      expect(results.every((error: DlError) => error.inFlight)).assertTrue();
      expect(second.invocations().length).assertEqual(0);
      expect(harness.client.getStatus()).assertEqual('online');
      harness.client.stop();
    });

    it('rejects_old_lifecycle_requests_waiting_online_after_an_account_switch', 0, async () => {
      const harness = new LinkHarness();
      const oldToken = new Deferred<string | null>();
      let reads = 0;
      harness.options.getToken = (): Promise<string | null> => {
        reads += 1;
        return reads === 1 ? oldToken.promise : Promise.resolve('fresh-token');
      };
      harness.client.start();
      const options = invokeOptions();
      options.timeoutMs = 400;
      const oldRequest = failure(harness.client.invoke('a', options));
      harness.client.stop();
      harness.client.start();
      await flushPromises();
      const socket = harness.sockets[0];
      socket.hello('account-b');
      oldToken.resolve('old-token');
      const result = await oldRequest;
      expect(result.code).assertEqual('NOT_CONNECTED');
      expect(result.inFlight).assertFalse();
      expect(socket.invocations().length).assertEqual(0);
      harness.client.stop();
    });

    it('keeps_legacy_host_results_and_channel_rejections_unchanged', 0, async () => {
      const harness = new LinkHarness();
      const socket = await harness.online();
      const request = harness.client.invoke('a', invokeOptions('unknown:new-channel'));
      const payload: Record<string, Object> = {};
      payload['ok'] = false;
      payload['errorCode'] = 'CHANNEL_NOT_ALLOWED';
      const sent = socket.invocations()[0];
      socket.receive(EnvelopeKind.INVOKE_RESULT, payload, sent.id, 'a');
      const result = await request;
      let errorCode = '';
      try {
        assertInvokeSucceeded(result);
      } catch (error) {
        if (error instanceof DlError) errorCode = error.code;
      }
      expect(errorCode).assertEqual('CHANNEL_NOT_ALLOWED');
      expect(harness.client.supportsHistoryView('a')).assertFalse();
      expect(socket.invocations().length).assertEqual(1);
      harness.client.stop();
    });
  });
}
