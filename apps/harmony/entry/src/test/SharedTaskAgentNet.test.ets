import { deleteScopedAgentNetMedia } from '../main/ets/core/shared-tasks/portable/sharing';
import { describe, expect, it } from '@ohos/hypium';
import { HelloPayload } from '../main/ets/core/device-link/DlProtocol';
import { WsCallbacks } from '../main/ets/network/WsAdapter';
import { recordOrEmpty } from '../main/ets/core/tasks/TaskModels';
import { SharedTaskMediaPorts } from '../main/ets/core/shared-tasks/SharedTaskGuestClient';
import { SharedTaskRequest, SharedTaskFault } from '../main/ets/core/shared-tasks/SharedTaskModels';
import { createSharedTaskAgentNetAdapter, AgentNetSharingSocket, SharedTaskAgentNetPorts, SharedAgentNetRoute,
  SharedAgentNetOrigin, SharedAgentNetConfig, AgentNetSharingBridge, AgentNetSharingConnection,
  SharingNativeHost, SharingWireCallbacks, SharingWireSocket } from '../main/ets/core/shared-tasks/SharedTaskAgentNet';

// Unit tier: production authority adapter and socket lifecycle. Bridge signing/network ports alone
// are replaced; these tests cover source pinning and native-resource lifetime, not cryptography.
// Minimal failures are one unavailable new origin, conflicting receipt, or delayed bridge creation.
// No disk/network, fake timers, sleeps or source-text assertions.
class Gate {
  release: () => void = (): void => {};
  promise: Promise<void> = new Promise<void>((resolve) => { this.release = resolve; });
}
class NativeFixture implements SharingNativeHost {
  destroyed: boolean = false;
  check(): void { if (this.destroyed) throw new Error('closed'); }
  command(_engine: string, _input: string): string { throw new Error('native crypto must not run'); }
  sha256(_input: string): string { throw new Error('native crypto must not run'); }
  async identityCard(_nonce: string): Promise<string> { throw new Error('identity card must not run'); }
  async memberAuthorization(_method: string, _path: string, _body: string): Promise<string> { throw new Error('signing must not run'); }
  async request(_url: string, _method: string, _headers: string, _body: string, _binary: boolean): Promise<string> { throw new Error('network must not run'); }
  socket(_url: string, _headers: string, _callbacks: SharingWireCallbacks): SharingWireSocket { throw new Error('network must not run'); }
  message(_text: string): void {}
  close(_code: number): void {}
  error(): void {}
  destroyEngine(_engine: string): void {}
  destroy(): void { this.destroyed = true; }
}
class ConnectionFixture implements AgentNetSharingConnection {
  failed: boolean = false;
  closed: boolean = false;
  closedSignal: Gate = new Gate();
  deleted: string[] = [];
  async request(_path: string, _method: string, _body: string, _timeout?: number): Promise<string> {
    if (this.failed) throw new Error('unavailable');
    return '{"status":"joined","created":false,"sharedTaskId":"task","memberId":"member"}';
  }
  async deleteMedia(key: string): Promise<void> { this.deleted.push(key); }
  subject(): string { return 'guest-subject'; }
  async connect(): Promise<void> {}
  send(_text: string): void {}
  close(): void { this.closed = true; this.closedSignal.release(); }
  async upload(_size: number, _mime: string, _read: (offset: number, length: number) => Promise<string>): Promise<string> { throw new Error('media must not run'); }
  async download(_key: string, _write: (text: string, offset: number) => Promise<void>): Promise<string> { throw new Error('media must not run'); }
}
class BridgeFixture implements AgentNetSharingBridge {
  connection: ConnectionFixture = new ConnectionFixture();
  calls: number = 0;
  failed: boolean = false;
  started: Gate = new Gate();
  delay: Gate | null = null;
  parseSharingInvitation(input: string): string { return input; }
  buildSharingInvitation(receipt: string, server: string, _app: string): string {
    const envelope: Record<string, Object> = {}; envelope['server'] = server; envelope['receipt'] = JSON.parse(receipt) as Object;
    return JSON.stringify(envelope);
  }
  async createAgentNetSharing(_config: string, _native: SharingNativeHost): Promise<AgentNetSharingConnection> {
    this.calls++; this.started.release(); if (this.delay) await this.delay.promise;
    if (this.failed) throw new Error('bridge unavailable'); return this.connection;
  }
}
function route(): SharedAgentNetRoute {
  return { v: 3, server: 'https://source.invalid', networkId: 'private:network', rootPublicKey: 'A'.repeat(43), hostDeviceId: 'host',
    resourceId: 'task', kind: 'shared-task', region: 'cn', memberId: 'member', retired: false, keyId: 'A'.repeat(24) };
}
class AgentFixture {
  scope: string = 'account:1';
  native: NativeFixture = new NativeFixture();
  bridge: BridgeFixture = new BridgeFixture();
  routes: SharedAgentNetRoute[] = [];
  origins: SharedAgentNetOrigin[] = [];
  saved: SharedAgentNetRoute[] = [];
  nativeStarted: Gate = new Gate();
  nativeDelay: Gate | null = null;
  ports(): SharedTaskAgentNetPorts {
    const media: SharedTaskMediaPorts = { upload: async (): Promise<string> => '', fetch: async (): Promise<Object | undefined> => undefined };
    return { bridge: this.bridge, scope: (): string => this.scope, accountId: (): string => 'account', deviceId: (): string => 'phone',
      region: (): string => 'cn', app: 'cindycn', getHello: (): HelloPayload => new HelloPayload(), media,
      createNative: async (_config: SharedAgentNetConfig, _current: () => boolean): Promise<SharingNativeHost> => {
        this.nativeStarted.release(); if (this.nativeDelay) await this.nativeDelay.promise; return this.native;
      },
      randomKeyId: (): string => 'B'.repeat(24), accountOrigins: (): SharedAgentNetOrigin[] => this.origins,
      loadRoutes: async (): Promise<SharedAgentNetRoute[]> => this.routes,
      saveRoutes: async (_scope: string, routes: SharedAgentNetRoute[]): Promise<void> => { this.saved = routes; } };
  }
}
function listRequest(): SharedTaskRequest { return { method: 'GET', isCurrent: (): boolean => true }; }
function nativeConfig(): SharedAgentNetConfig {
  const value = route(); return { v: value.v, server: value.server, networkId: value.networkId, rootPublicKey: value.rootPublicKey,
    hostDeviceId: value.hostDeviceId, resourceId: value.resourceId, kind: value.kind, region: value.region, memberId: value.memberId,
    retired: value.retired, keyId: value.keyId, accountId: 'account', deviceId: 'phone', localRegion: 'cn' };
}
function rawMediaKey(): string {
  return 'agent-net-v3/00000000-0000-0000-0000-000000000001/private%3Anetwork/00000000-0000-0000-0000-000000000002/00000000-0000-0000-0000-000000000003/' + 'a'.repeat(64) + '/image%2Fpng';
}
function scopedMediaKey(task: string, raw: string): string {
  let hex = ''; for (let index = 0; index < raw.length; index++) hex += raw.charCodeAt(index).toString(16).padStart(2, '0');
  return 'cindy/device-link/shared-task/' + task + '/member/an3-' + hex;
}
function mediaScope(): string {
  const scope: Record<string, string> = { 'slot': '00000000-0000-0000-0000-000000000001', 'networkId': 'private:network', 'sharedTaskId': 'task' };
  return JSON.stringify(scope);
}
export default function sharedTaskAgentNetTests(): void {
  describe('SharedTaskAgentNet', () => {
    it('portable_scoped_delete_parses_real_receipts_and_removes_only_the_verified_object_id', 0, async () => {
      const removed: string[] = [];
      for (const key of [rawMediaKey(), scopedMediaKey('task', rawMediaKey())]) {
        await deleteScopedAgentNetMedia(key, mediaScope(), (): void => {}, async (id: string): Promise<void> => { removed.push(id); });
      }
      expect(removed.length).assertEqual(2); expect(removed.every((id: string): boolean => id === '00000000-0000-0000-0000-000000000003')).assertTrue();
    });
    it('portable_scoped_delete_rejects_other_network_slot_task_and_invalid_key_before_request', 0, async () => {
      const removed: string[] = [], invalid: string[] = [
        rawMediaKey().replace('private%3Anetwork', 'private%3Aother'),
        rawMediaKey().replace('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004'),
        scopedMediaKey('other', rawMediaKey()), 'agent-net-v3/broken',
      ];
      for (const key of invalid) {
        let rejected = false; try { await deleteScopedAgentNetMedia(key, mediaScope(), (): void => {}, async (id: string): Promise<void> => { removed.push(id); }); } catch { rejected = true; }
        expect(rejected).assertTrue();
      }
      expect(removed.length).assertEqual(0);
    });
    it('portable_scoped_delete_never_reports_success_after_authorization_generation_changes', 0, async () => {
      let current = true, requests = 0, rejected = false;
      try { await deleteScopedAgentNetMedia(rawMediaKey(), mediaScope(), (): void => { if (!current) throw new Error('revoked'); },
        async (_id: string): Promise<void> => { requests++; current = false; }); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(requests).assertEqual(1);
    });
    it('socket_delete_delegates_only_to_its_ready_scoped_connection_and_stops_after_scope_change', 0, async () => {
      const state = new AgentFixture(), opened = new Gate(), callbacks = new WsCallbacks(); let current = true;
      const socket = new AgentNetSharingSocket(state.ports(), nativeConfig(), (): boolean => current);
      callbacks.onOpen = (): void => { opened.release(); }; socket.setCallbacks(callbacks); socket.connect('', {}); await opened.promise;
      await socket.deleteMedia(rawMediaKey()); expect(state.bridge.connection.deleted.length).assertEqual(1);
      current = false; let rejected = false; try { await socket.deleteMedia(rawMediaKey()); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(state.bridge.connection.deleted.length).assertEqual(1); socket.close();
    });
    it('unavailable_new_origin_marks_directory_incomplete_even_without_known_task_ids', 0, async () => {
      const state = new AgentFixture(), value = route(); state.bridge.connection.failed = true;
      state.origins = [{ v: value.v, server: value.server, networkId: value.networkId, rootPublicKey: value.rootPublicKey, region: value.region, privateMember: true, subject: 'account' }];
      const adapter = createSharedTaskAgentNetAdapter(state.ports());
      const result = recordOrEmpty(await adapter.request('/api/device-link/shared-tasks', listRequest()));
      expect(result['authorityIncomplete']).assertTrue(); expect((result['sharedTasks'] as Object[]).length).assertEqual(0); adapter.dispose();
    });
    it('conflicting_invitation_root_is_rejected_before_any_signed_business_call', 0, async () => {
      const state = new AgentFixture(); state.routes = [route()]; const adapter = createSharedTaskAgentNetAdapter(state.ports());
      const receipt: Record<string, Object> = JSON.parse(JSON.stringify(route())) as Record<string, Object>;
      receipt['invitation'] = 'A'.repeat(43); receipt['rootPublicKey'] = 'B'.repeat(43);
      const invitation = adapter.parseInvitation(state.bridge.buildSharingInvitation(JSON.stringify(receipt), 'https://source.invalid', 'cindycn'));
      if (!invitation) throw new Error('fixture invitation missing');
      let code = ''; try { await adapter.join(invitation, 'Guest', (): boolean => true); } catch (error) { if (error instanceof SharedTaskFault) code = error.code; }
      expect(code).assertEqual('AGENT_NET_SHARING_ROUTE_CONFLICT'); expect(state.bridge.calls).assertEqual(0); adapter.dispose();
    });
    it('business_bridge_creation_failure_destroys_native_and_keeps_route_metadata_unchanged', 0, async () => {
      const state = new AgentFixture(); state.routes = [route()]; state.bridge.failed = true;
      const adapter = createSharedTaskAgentNetAdapter(state.ports()); let rejected = false;
      try { await adapter.request('/api/device-link/shared-tasks/task', listRequest()); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(state.native.destroyed).assertTrue(); expect(state.saved.length).assertEqual(0); adapter.dispose();
    });
    it('native_created_after_account_switch_is_destroyed_before_bridge_can_observe_it', 0, async () => {
      const state = new AgentFixture(); state.routes = [route()]; state.nativeDelay = new Gate();
      const adapter = createSharedTaskAgentNetAdapter(state.ports()); let rejected = false;
      const pending = adapter.request('/api/device-link/shared-tasks/task', listRequest()).catch((): void => { rejected = true; });
      await state.nativeStarted.promise; state.scope = 'account:2'; state.nativeDelay.release(); await pending;
      expect(rejected).assertTrue(); expect(state.native.destroyed).assertTrue(); expect(state.bridge.calls).assertEqual(0); adapter.dispose();
    });
    it('rejoining_retired_member_rotates_seed_reference_before_persisting_live_membership', 0, async () => {
      const state = new AgentFixture(), old = route(); old.retired = true; state.routes = [old];
      const adapter = createSharedTaskAgentNetAdapter(state.ports()), receipt = JSON.parse(JSON.stringify(old)) as Record<string, Object>;
      receipt['invitation'] = 'A'.repeat(43);
      const invitation = adapter.parseInvitation(state.bridge.buildSharingInvitation(JSON.stringify(receipt), old.server, 'cindycn'));
      if (!invitation) throw new Error('fixture invitation missing');
      await adapter.join(invitation, 'Guest', (): boolean => true);
      expect(state.saved[0].retired).assertFalse(); expect(state.saved[0].keyId).assertEqual('B'.repeat(24)); adapter.dispose();
    });
    it('socket_bridge_failure_closes_native_before_reporting_failed_connection', 0, async () => {
      const state = new AgentFixture(); state.bridge.failed = true;
      const socket = new AgentNetSharingSocket(state.ports(), nativeConfig(), (): boolean => true), callbacks = new WsCallbacks(), ended = new Gate();
      callbacks.onClose = (): void => { ended.release(); }; socket.setCallbacks(callbacks); socket.connect('', {});
      await ended.promise; expect(state.native.destroyed).assertTrue(); socket.close();
    });
    it('closing_socket_during_bridge_creation_releases_native_and_rejects_late_ready', 0, async () => {
      const state = new AgentFixture(); state.bridge.delay = new Gate();
      const socket = new AgentNetSharingSocket(state.ports(), nativeConfig(), (): boolean => true), callbacks = new WsCallbacks(); let opened = false;
      callbacks.onOpen = (): void => { opened = true; }; socket.setCallbacks(callbacks); socket.connect('', {});
      await state.bridge.started.promise; socket.close(); expect(state.native.destroyed).assertTrue();
      state.bridge.delay.release(); await state.bridge.connection.closedSignal.promise;
      expect(opened).assertFalse(); expect(state.bridge.connection.closed).assertTrue();
    });
  });
}
