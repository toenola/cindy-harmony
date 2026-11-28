import { describe, expect, it } from '@ohos/hypium';
import { isRemoteBusyError, isRemoteBusyMessage } from '../main/ets/core/device-link/RemoteInvokePresentation';
import { ConnectionAttemptState } from '../main/ets/core/device-link/ConnectionAttemptState';
import { resolveInvokeTimeoutMs } from '../main/ets/core/device-link/InvokePolicy';
import { NewSessionCreationStore, NewSessionCreationParams } from '../main/ets/core/tasks/NewSessionCreationStore';
import {
  InvokeScheduler, isBackgroundInvoke, bypassInvokeScheduling, invokePhysicalPeerId,
} from '../main/ets/core/device-link/InvokeScheduler';
import {
  DlClient, DlClientOptions, DlInvokeOptions, DlError, ScopedPeerPort, assertInvokeSucceeded,
} from '../main/ets/core/device-link/DlClient';
import {
  Envelope, EnvelopeKind, PresenceSnapshot, PROTOCOL_VERSION, encodeEnvelope, decodeEnvelope,
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
  receive(kind: string, payload: Object, requestId: string = '', source: string = '', destination: string = ''): void {
    const envelope = new Envelope();
    envelope.kind = kind;
    envelope.payload = payload;
    envelope.id = requestId;
    envelope.src = source;
    envelope.dst = destination;
    this.callbacks.onMessage(new TestWsMessage(encodeEnvelope(envelope)));
  }
  hello(userId: string = 'account-a', deviceId: string = 'controller'): void {
    this.callbacks.onOpen();
    const payload: Record<string, Object> = {};
    payload['serverProtocolVersion'] = PROTOCOL_VERSION;
    payload['deviceId'] = deviceId;
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

class SharedScopeTestPort implements ScopedPeerPort {
  authorized: boolean = true;
  version: string = 'membership-1';
  calls: number = 0;
  closed: number = 0;
  result: Promise<Object | undefined> = Promise.resolve('scoped result');
  current(): boolean { return this.authorized; }
  identity(): string { return this.version; }
  status(): string { return 'online'; }
  supportsHistoryView(): boolean { return false; }
  async invoke(_channel: string, _args: Object[], _timeout: number): Promise<Object | undefined> { this.calls++; return this.result; }
  async subscribe(_topics: string[]): Promise<void> {}
  async unsubscribe(_topics: string[]): Promise<void> {}
  close(): void { this.closed++; this.authorized = false; }
}

function clientSlots(client: DlClient, peerId: string): Promise<DlError>[] {
  const pending: Promise<DlError>[] = [];
  for (let index = 0; index < 12; index += 1) pending.push(failure(client.invoke(peerId, invokeOptions())));
  return pending;
}

export default function v132LinkTests(): void {
  describe('v132LinkAlignment', () => {
    /**
     * 生产入口：DlClient 注册式共享路由；官方 sharedTaskPeer 的本地键不能成为owner地址。
     * 缺口：既有断链测试只覆盖同账号peer。最小输入：未注册的canonical长peer与撤权中迟到返回。
     * tier=unit，注入业务端口，不连接外网、不调用真实模型。
     */
    it('routes_only_registered_shared_peers_without_an_owner_connection', 0, async () => {
      const client = new DlClient(new DlClientOptions());
      const peer = '["shared-1","host",null,"host-a"]'.padEnd(129, '~');
      expect((await failure(client.invoke(peer, invokeOptions()))).code).assertEqual('ACCESS_REVOKED');
      const port = new SharedScopeTestPort(); client.registerScopedPeer(peer, port);
      const result = await client.invoke(peer, invokeOptions());
      expect((result.payload as Record<string, Object>)['result']).assertEqual('scoped result');
      expect(port.calls).assertEqual(1);
      expect(client.getStatus(peer)).assertEqual('online');
      expect(client.getStatus()).assertEqual('stopped');
      client.clearScopedPeers();
      expect(port.closed).assertEqual(1);
      expect(client.getStatus(peer)).assertEqual('stopped');
      expect((await failure(client.invoke(peer, invokeOptions()))).code).assertEqual('ACCESS_REVOKED');
    });
    /**
     * Production raw-socket ingress and shared invoke scheduler, unit tier. Existing outbound
     * registry tests cannot detect owner-relay spoofed local keys or owner disconnect clearing
     * the independent transport queue. Minimum: one forged frame, or 12 held jobs + one waiter.
     * Uses native socket ports/held Promises only; no network, model, long waits or source reads.
     */
    it('raw_owner_frames_cannot_spoof_canonical_shared_sources_destinations_or_presence', 0, async () => {
      const harness = new LinkHarness(), pushes: string[] = [], presences: string[] = [], closed: string[] = [];
      harness.options.events.onPush = (peer: string): void => { pushes.push(peer); };
      harness.options.events.onPresence = (presence: PresenceSnapshot): void => { presences.push(presence.deviceId); };
      harness.options.events.onLinkClosed = (peer: string): void => { closed.push(peer); };
      const socket = await harness.online(), peer = '["shared-1","host",null,"host-a"]'.padEnd(129, '~');
      const port = new SharedScopeTestPort(); harness.client.registerScopedPeer(peer, port);
      const push = JSON.parse('{"channel":"maker:event","payload":{"sessionId":"task"}}') as Record<string, Object>;
      const close = JSON.parse('{"reason":"revoked"}') as Record<string, Object>;
      for (const forged of [peer, 'x'.repeat(129)]) {
        socket.receive(EnvelopeKind.PUSH, push, '', forged);
        socket.receive(EnvelopeKind.LINK_CLOSE, close, '', forged);
        const presence: Record<string, Object> = {}; presence['deviceId'] = forged; presence['online'] = false;
        socket.receive(EnvelopeKind.PRESENCE_CHANGED, presence);
      }
      socket.receive(EnvelopeKind.PUSH, push, '', 'host-a', peer);
      socket.receive(EnvelopeKind.LINK_CLOSE, close, '', 'host-a', peer);
      expect(pushes.length).assertEqual(0); expect(presences.length).assertEqual(0); expect(closed.length).assertEqual(0);
      expect(harness.client.hasScopedPeer(peer)).assertTrue(); expect(port.closed).assertEqual(0);
      const physical = 'p'.repeat(128), presence: Record<string, Object> = {}; presence['deviceId'] = physical; presence['online'] = true;
      socket.receive(EnvelopeKind.PUSH, push, '', physical, 'controller');
      socket.receive(EnvelopeKind.PRESENCE_CHANGED, presence);
      socket.receive(EnvelopeKind.LINK_CLOSE, close, '', physical, 'controller');
      expect(pushes[0]).assertEqual(physical); expect(presences[0]).assertEqual(physical); expect(closed[0]).assertEqual(physical);
      const result = await harness.client.invoke(peer, invokeOptions());
      expect((result.payload as Record<string, Object>)['result']).assertEqual('scoped result');
      expect(socket.invocations().length).assertEqual(0); harness.client.clearScopedPeers(); harness.client.stop();
    });
    it('canonical_hello_device_claim_never_becomes_an_online_physical_identity', 0, async () => {
      const harness = new LinkHarness(); harness.client.start(); await flushPromises();
      const peer = '["shared-1","host",null,"host-a"]'.padEnd(129, '~');
      harness.sockets[0].hello('account-a', peer);
      expect(harness.client.getStatus() === 'online').assertFalse(); expect(harness.client.getDeviceId() === peer).assertFalse();
      expect(harness.sockets[0].terminated).assertEqual(1); harness.client.stop();
    });
    it('owner_socket_loss_and_stop_cancel_owner_jobs_but_preserve_twelve_plus_one_guest_jobs', 0, async () => {
      const harness = new LinkHarness(), socket = await harness.online();
      const peer = '["shared-1","host",null,"a"]'.padEnd(129, '~'), port = new SharedScopeTestPort(), held = new Deferred<Object | undefined>();
      port.result = held.promise; harness.client.registerScopedPeer(peer, port);
      const guestActive = clientSlots(harness.client, peer), guestQueued = failure(harness.client.invoke(peer, invokeOptions()));
      const samePhysicalOwnerQueued = failure(harness.client.invoke('a', invokeOptions()));
      const ownerActive = clientSlots(harness.client, 'b'), ownerQueued = failure(harness.client.invoke('b', invokeOptions()));
      expect(port.calls).assertEqual(12); expect(socket.invocations().length).assertEqual(12);
      socket.close(1006, 'owner link lost'); harness.client.stop();
      expect((await samePhysicalOwnerQueued).code).assertEqual('NOT_CONNECTED'); expect((await ownerQueued).inFlight).assertFalse();
      expect((await Promise.all(ownerActive)).every((error: DlError) => error.inFlight)).assertTrue();
      expect(harness.client.getStatus(peer)).assertEqual('online'); expect(port.closed).assertEqual(0);
      held.resolve('guest data');
      expect((await Promise.all(guestActive)).every((error: DlError) => error.code === 'NONE')).assertTrue();
      expect((await guestQueued).code).assertEqual('NONE'); expect(port.calls).assertEqual(13);
      expect(socket.invocations().length).assertEqual(12); harness.client.clearScopedPeers();
    });
    it('removing_one_scope_cancels_its_waiter_without_cancelling_another_scope_on_same_host', 0, async () => {
      const harness = new LinkHarness(), socket = await harness.online(), held = new Deferred<Object | undefined>();
      const peerA = '["shared-a","host",null,"a"]'.padEnd(129, '~'), peerB = '["shared-b","host",null,"a"]'.padEnd(129, '~');
      const portA = new SharedScopeTestPort(), portB = new SharedScopeTestPort(); portA.result = held.promise;
      harness.client.registerScopedPeer(peerA, portA); harness.client.registerScopedPeer(peerB, portB);
      const activeA = clientSlots(harness.client, peerA), queuedA = failure(harness.client.invoke(peerA, invokeOptions()));
      const queuedB = failure(harness.client.invoke(peerB, invokeOptions()));
      expect(portA.calls).assertEqual(12); expect(portB.calls).assertEqual(0);
      harness.client.removeScopedPeer(peerA); expect((await queuedA).code).assertEqual('LINK_NOT_OPEN');
      held.resolve('late retired data');
      expect((await Promise.all(activeA)).every((error: DlError) => error.code === 'ACCESS_REVOKED')).assertTrue();
      expect((await queuedB).code).assertEqual('NONE'); expect(portB.calls).assertEqual(1); expect(portB.closed).assertEqual(0);
      expect(socket.invocations().length).assertEqual(0); harness.client.clearScopedPeers(); harness.client.stop();
    });
    it('discards_in_flight_shared_results_after_membership_changes', 0, async () => {
      const client = new DlClient(new DlClientOptions());
      const peer = '["shared-1","host",null,"host-a"]'.padEnd(129, '~');
      const port = new SharedScopeTestPort(); const pending = new Deferred<Object | undefined>();
      port.result = pending.promise; client.registerScopedPeer(peer, port);
      const request = failure(client.invoke(peer, invokeOptions()));
      await flushPromises();
      port.authorized = false; pending.resolve('must not surface');
      expect((await request).code).assertEqual('ACCESS_REVOKED');
      client.clearScopedPeers();
    });
    /**
     * 生产入口：创建 Store 的精确输入回执，绑定路由 commit 的唯一触发点。
     * 缺口：既有测试没有首条输入与后续输入/异设备回执的区分。
     * 最小失败输入：正确 session、错误 clientId；tier=unit，无网络或计时等待。
     */
    it('commits_only_the_exact_first_input_once_even_when_route_commit_fails', 0, () => {
      const store = new NewSessionCreationStore();
      const params = new NewSessionCreationParams();
      params.deviceId = 'host-a'; params.session.id = 'new-task'; params.firstMessageClientId = 'first';
      let commits = 0;
      params.onFirstInputAccepted = async (): Promise<void> => {
        commits++;
        throw new Error('simulated routing receipt failure');
      };
      store.start(params);
      store.noteInputAccepted('host-b', 'new-task', 'first');
      store.noteInputAccepted('host-a', 'new-task', 'follow-up');
      expect(commits).assertEqual(0);
      store.noteInputAccepted('host-a', 'new-task', 'first');
      store.noteInputAccepted('host-a', 'new-task', 'first');
      expect(commits).assertEqual(1);
      store.clearAll(false);
      store.noteInputAccepted('host-a', 'new-task', 'first');
      expect(commits).assertEqual(1);
    });
    /**
     * 生产入口：DlClient.invoke 使用的预算解析；慢创建不应被默认 30 秒截断。
     * 依据：官方 allowlist.ts@91179cedad 的跨端调用预算；现有测试只覆盖排队/断链。
     * 最小输入：create-session 无显式预算；tier=unit，无外网或长时间真实等待。
     * 这里断言跨端执行预算契约，不扫描源码，不测试内部实现副本。
     */
    it('uses_host_slow_operation_budgets_without_extending_other_invokes', 0, () => {
      expect(resolveInvokeTimeoutMs('maker:create-session', undefined)).assertEqual(120_000);
      expect(resolveInvokeTimeoutMs('maker:compact-session', undefined)).assertEqual(660_000);
      expect(resolveInvokeTimeoutMs('maker:predict-prompt', undefined)).assertEqual(45_000);
      expect(resolveInvokeTimeoutMs('maker:send', undefined)).assertEqual(30_000);
      expect(resolveInvokeTimeoutMs('unknown:new-channel', undefined)).assertEqual(30_000);
    });
    it('honors_finite_caller_budgets_and_rejects_invalid_timer_values', 0, () => {
      expect(resolveInvokeTimeoutMs('maker:create-session', 8000)).assertEqual(8000);
      expect(resolveInvokeTimeoutMs('maker:create-session', 0)).assertEqual(120_000);
      expect(resolveInvokeTimeoutMs('maker:send', Number.NaN)).assertEqual(30_000);
      expect(resolveInvokeTimeoutMs('maker:send', Number.POSITIVE_INFINITY)).assertEqual(30_000);
    });
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
