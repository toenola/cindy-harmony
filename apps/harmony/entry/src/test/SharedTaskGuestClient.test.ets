import { withoutSharedTaskField } from '../main/ets/core/shared-tasks/SharedTaskScope';
import { describe, expect, it } from '@ohos/hypium';
import { WsAdapter, WsCallbacks, WsMessage } from '../main/ets/network/WsAdapter';
import { HelloPayload } from '../main/ets/core/device-link/DlProtocol';
import { SharedTaskGuestClientPorts, SharedTaskMediaPorts, createSharedTaskGuestClient } from '../main/ets/core/shared-tasks/SharedTaskGuestClient';
import { SharedTaskDetail, SharedTaskSessionTarget, parseSharedTaskDetail } from '../main/ets/core/shared-tasks/SharedTaskModels';
import { recordOrEmpty, readStr } from '../main/ets/core/tasks/TaskModels';

// Unit tier: the actual independent DlClient -> socket wrapper -> scope codec open path.
// Codec-only tests missed the global fail-closed canonical-peer guard. No real socket or waits;
// a synchronous fake relay must observe hello/link-open/server topic ACK/session-read in order.
class TextFrame implements WsMessage {
  private text: string;
  constructor(text: string) { this.text = text; }
  toString(): string { return this.text; }
}
class SharedFrameSignal {
  release: () => void = (): void => {};
  promise: Promise<void> = new Promise<void>((resolve) => { this.release = resolve; });
}
class SharedRelay implements WsAdapter {
  callbacks: WsCallbacks = new WsCallbacks();
  sent: Record<string, Object>[] = [];
  supported: boolean = true;
  spoof: boolean = false;
  terminated: boolean = false;
  held: Record<string, Object>[] = [];
  full: SharedFrameSignal = new SharedFrameSignal();
  setCallbacks(callbacks: WsCallbacks): void { this.callbacks = callbacks; }
  connect(_address: string, _headers: Record<string, string>): void { this.callbacks.onOpen(); }
  send(text: string): boolean {
    const row = recordOrEmpty(JSON.parse(text) as Object); this.sent.push(row);
    if (row['kind'] === 'hello') {
      const ack = JSON.parse('{"v":1,"kind":"hello-ack","payload":{"serverProtocolVersion":1,"deviceId":"phone","userId":"guest","capabilities":["shared-task-v2"]}}') as Record<string, Object>;
      if (!this.supported) { const caps: string[] = []; recordOrEmpty(ack['payload'])['capabilities'] = caps; }
      this.callbacks.onMessage(new TextFrame(JSON.stringify(ack))); return true;
    }
    if (row['kind'] !== 'link-open' && row['kind'] !== 'invoke') return true;
    const reply = JSON.parse('{"v":1,"kind":"invoke-result","id":"","src":"host","dst":"phone","sharedTask":{"sharedTaskId":"share","source":{"role":"host"},"target":{"role":"guest","memberId":"member"}},"payload":{"ok":true,"result":{}}}') as Record<string, Object>;
    reply['id'] = row['id'];
    if (row['kind'] === 'link-open') {
      reply['kind'] = 'link-accept'; reply['payload'] = JSON.parse('{"capabilities":["shared-task-v2","history-view-v1"]}') as Object;
    } else if (readStr(recordOrEmpty(row['payload']), 'channel') === 'local-db:sessions:get') {
      if (this.spoof) {
        const forged = withoutSharedTaskField(reply, 'sharedTask');
        recordOrEmpty(forged['payload'])['result'] = JSON.parse('{"id":"another-task"}') as Object;
        this.callbacks.onMessage(new TextFrame(JSON.stringify(forged)));
      }
      recordOrEmpty(reply['payload'])['result'] = JSON.parse('{"id":"task","title":"Shared"}') as Object;
    }
    if (readStr(recordOrEmpty(row['payload']), 'channel') === 'test:hold') { this.held.push(reply); if (this.held.length === 12) this.full.release(); return true; }
    this.callbacks.onMessage(new TextFrame(JSON.stringify(reply))); return true;
  }
  releaseHeld(): void {
    const replies = this.held.slice(); this.held = [];
    for (const reply of replies) this.callbacks.onMessage(new TextFrame(JSON.stringify(reply)));
  }
  close(_code?: number, _reason?: string): void { this.terminated = true; }
  terminate(): void { this.terminated = true; }
}
function target(): SharedTaskDetail {
  return parseSharedTaskDetail(JSON.parse('{"sharedTaskId":"share","sessionId":"task","ownerAccountId":"owner","hostDeviceId":"host","title":"Shared task","revision":1,"status":"active","guests":[{"memberId":"member","accountId":"guest","version":1,"deviceIds":["phone"],"displayName":"Guest","joinedAt":1}]}') as Object, 'share');
}
function ports(relay: SharedRelay): SharedTaskGuestClientPorts {
  const media: SharedTaskMediaPorts = {
    upload: async (): Promise<string> => 'scoped-ref', fetch: async (): Promise<Object> => JSON.parse('{"scoped":true}') as Object };
  return { accountId: 'guest', wsUrl: 'wss://official.invalid/ws', getToken: async (): Promise<string> => 'fixture-token',
    getHello: (): HelloPayload => new HelloPayload(), createWs: (): WsAdapter => relay, current: (): boolean => true,
    refreshAuth: (): void => {}, media, transport: 'official-scoped' };
}
export default function sharedTaskGuestClientTests(): void {
  describe('SharedTaskGuestClient', () => {
    it('factory_returns_only_after_real_scoped_link_topic_ack_and_matching_session_read', 0, async () => {
      const relay = new SharedRelay(), guest = await createSharedTaskGuestClient(target(), 'member', ports(relay));
      expect(guest.routing.getStatus()).assertEqual('online'); expect(readStr(recordOrEmpty(guest.session), 'id')).assertEqual('task');
      const routed = relay.sent.filter((row: Record<string, Object>): boolean => row['kind'] === 'invoke' || row['kind'] === 'link-open');
      expect(routed.length).assertEqual(3);
      for (const row of routed) { expect(row['dst']).assertEqual('host'); expect(readStr(recordOrEmpty(row['sharedTask']), 'sharedTaskId')).assertEqual('share'); }
      const subscribe = recordOrEmpty(routed[1]['payload']); expect(subscribe['channel']).assertEqual('device-link:subscribe');
      expect(guest.scopedPort().supportsHistoryView()).assertTrue(); guest.close(); expect(relay.terminated).assertTrue();
    });
    it('unscoped_result_with_matching_request_id_cannot_supply_session_data', 0, async () => {
      const relay = new SharedRelay(); relay.spoof = true;
      const guest = await createSharedTaskGuestClient(target(), 'member', ports(relay));
      expect(readStr(recordOrEmpty(guest.session), 'id')).assertEqual('task'); guest.close();
    });
    it('old_relay_without_shared_scope_support_fails_without_sending_a_control_frame', 0, async () => {
      const relay = new SharedRelay(); relay.supported = false; let rejected = false;
      try { await createSharedTaskGuestClient(target(), 'member', ports(relay)); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(relay.sent.length).assertEqual(1); expect(relay.terminated).assertTrue();
    });
    it('guest_media_delete_keeps_its_canonical_target_and_rejects_late_completion_after_close', 0, async () => {
      const relay = new SharedRelay(), config = ports(relay), started = new SharedFrameSignal(), finish = new SharedFrameSignal(), targets: string[] = [];
      config.media.delete = async (destination: SharedTaskSessionTarget, key: string): Promise<void> => { targets.push(destination.peer); targets.push(key); started.release(); await finish.promise; };
      const guest = await createSharedTaskGuestClient(target(), 'member', config); if (!guest.delete) throw new Error('delete implementation missing');
      let rejected = false; const pending = guest.delete('owned-task-key').catch((): void => { rejected = true; });
      await started.promise; guest.close(); finish.release(); await pending;
      expect(rejected).assertTrue(); expect(targets[0]).assertEqual(guest.target.peer); expect(targets[1]).assertEqual('owned-task-key');
      expect(relay.sent.filter((row: Record<string, Object>): boolean => row['kind'] === 'invoke').length).assertEqual(2);
    });
    it('queued_scoped_call_rechecks_user_pre_send_at_actual_private_client_dispatch', 0, async () => {
      const relay = new SharedRelay(), guest = await createSharedTaskGuestClient(target(), 'member', ports(relay));
      const running: Array<Promise<Object | undefined>> = [];
      for (let index = 0; index < 12; index++) running.push(guest.scopedPort().invoke('test:hold', [], 5000));
      await relay.full.promise; expect(relay.held.length).assertEqual(12);
      let allowed = true, rejected = false;
      const waiting = guest.scopedPort().invoke('test:stale', [], 5000, (): void => { if (!allowed) throw new Error('user scope changed'); })
        .catch((): void => { rejected = true; });
      allowed = false; relay.releaseHeld(); await Promise.all(running); await waiting;
      const stale = relay.sent.filter((row: Record<string, Object>): boolean => readStr(recordOrEmpty(row['payload']), 'channel') === 'test:stale');
      expect(rejected).assertTrue(); expect(stale.length).assertEqual(0); guest.close();
    });
    it('scoped_port_invokes_real_subscription_and_does_not_synthesize_server_ack', 0, async () => {
      const relay = new SharedRelay(), guest = await createSharedTaskGuestClient(target(), 'member', ports(relay));
      const before = relay.sent.length;
      await guest.scopedPort().subscribe(['session:task']);
      expect(relay.sent.length).assertEqual(before + 1);
      let rejected = false;
      try { await guest.scopedPort().subscribe(['sessions']); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(relay.sent.length).assertEqual(before + 1); guest.close();
    });
  });
}
