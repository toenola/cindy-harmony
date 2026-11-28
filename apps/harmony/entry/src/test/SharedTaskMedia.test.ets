import { HttpMethod, HttpResponseData } from '../main/ets/network/HarmonyHttp';
import { requiresScopedMediaCleanup } from '../main/ets/core/shared-tasks/SharedTaskMediaKey';
import { describe, expect, it } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { AuthStore } from '../main/ets/core/auth/AuthStore';
import { Envelope } from '../main/ets/core/device-link/DlProtocol';
import { ScopedPeerPort } from '../main/ets/core/device-link/DlClient';
import { AttachmentOssRef } from '../main/ets/core/attachments/AttachmentOssRef';
import { recordOrEmpty } from '../main/ets/core/tasks/TaskModels';
import { SharedTaskSessionTarget, sharedTaskHostPeerKey } from '../main/ets/core/shared-tasks/SharedTaskModels';
import { SharedTaskReadyTransport, SharedTaskRoutingPort, SharedTaskAgentNetMedia } from '../main/ets/core/shared-tasks/SharedTaskGuestClient';
import { createSharedTaskMediaPorts, SharedTaskMedia, SharedTaskAttachmentCodec, SharedTaskMediaHttpPort } from '../main/ets/core/shared-tasks/SharedTaskMedia';

// Unit tier: actual media factory/fetch entry, replacing only its live authorized guest/Auth ports.
// Each minimum input is one reference or one delayed response. Covers cross-task and transport
// confusion missed by guest codec tests. No token access, HTTP, file IO, sleeps or source assertions.
// System OSS codec boundary fake. No Base64/SDK result or real upload success is fabricated:
// only already-decoded invalid-key fixtures reach the production authorization checks below.
class MediaAttachmentCodecFixture implements SharedTaskAttachmentCodec {
  encode(reference: AttachmentOssRef): string {
    const row: Record<string, string> = { 'ossKey': reference.ossKey }; return 'unit-attachment:' + JSON.stringify(row);
  }
  decode(reference: string): AttachmentOssRef | null {
    if (!reference.startsWith('unit-attachment:')) return null;
    const row = recordOrEmpty(JSON.parse(reference.slice('unit-attachment:'.length)) as Object);
    if (typeof row['ossKey'] !== 'string') return null;
    const value = new AttachmentOssRef(); value.ossKey = row['ossKey'] as string; return value;
  }
}
class MediaAuth extends AuthStore { get isLoggedIn(): boolean { return true; } async getAccessToken(): Promise<string> { return 'unit-fixture-token'; } }
class MediaGate {
  release: () => void = (): void => {};
  promise: Promise<void> = new Promise<void>((resolve) => { this.release = resolve; });
}
interface MediaHttpReceipt { address: string; method: string; body: string; timeoutMs: number; privateEndpoint: boolean; authenticated: boolean; }
class MediaHttpFixture implements SharedTaskMediaHttpPort {
  receipts: MediaHttpReceipt[] = [];
  delay: MediaGate | null = null;
  started: MediaGate = new MediaGate();
  async requestJson(address: string, method: HttpMethod, headers: Record<string, string>, body?: string,
    timeoutMs?: number, privateEndpoint?: boolean): Promise<HttpResponseData> {
    const receipt: MediaHttpReceipt = { address, method, body: body ?? '', timeoutMs: timeoutMs ?? 0,
      privateEndpoint: privateEndpoint ?? false, authenticated: headers['Authorization'] === 'Bearer unit-fixture-token' };
    this.receipts.push(receipt); this.started.release(); if (this.delay) await this.delay.promise;
    const response: HttpResponseData = { statusCode: 200, body: '{"deleted":true}' }; return response;
  }
}
class MediaScopedPortFixture implements ScopedPeerPort {
  private guest: MediaGuest;
  constructor(guest: MediaGuest) { this.guest = guest; }
  current(): boolean { return this.guest.live; }
  identity(): string { return 'identity'; }
  status(): string { return 'online'; }
  async invoke(channel: string, args: Object[], _timeout: number, preSend?: () => void): Promise<Object | undefined> { preSend?.(); return this.guest.invoke(channel, args); }
  async subscribe(_topics: string[]): Promise<void> {}
  async unsubscribe(_topics: string[]): Promise<void> {}
  close(): void { this.guest.close(); }
  supportsHistoryView(): boolean { return false; }
}
function nativeMedia(deleted: string[]): SharedTaskAgentNetMedia {
  const backend: SharedTaskAgentNetMedia = {
    upload: async (): Promise<string> => { throw new Error('upload must not run'); },
    download: async (): Promise<string> => { throw new Error('download must not run'); },
    delete: async (key: string): Promise<void> => { deleted.push(key); },
  }; return backend;
}
function mediaTarget(): SharedTaskSessionTarget {
  return { sharedTaskId: 'share', sessionId: 'task', ownerAccountId: 'owner', hostDeviceId: 'host', title: 'Task',
    peer: sharedTaskHostPeerKey('share', 'host'), guest: true, transport: 'official-scoped' };
}
class MediaGuest implements SharedTaskReadyTransport, SharedTaskRoutingPort {
  target: SharedTaskSessionTarget = mediaTarget();
  session: Object = new Object();
  routing: SharedTaskRoutingPort = this;
  agentNetMedia: SharedTaskAgentNetMedia | undefined = undefined;
  live: boolean = true;
  calls: number = 0;
  channel: string = '';
  args: Object[] = [];
  delay: MediaGate | null = null;
  started: MediaGate = new MediaGate();
  private closures: Array<() => void> = [];
  scopedPort(): ScopedPeerPort { return new MediaScopedPortFixture(this); }
  async invoke(channel: string, args: Object[]): Promise<Object> {
    this.calls++; this.channel = channel; this.args = args; this.started.release(); if (this.delay) await this.delay.promise;
    return JSON.parse('{"inlineBase64":"aGk=","mimeType":"text/plain","size":2}') as Object;
  }
  subscribe(_listener: (channel: string, payload: Object) => void): () => void { return (): void => {}; }
  async upload(_uri: string, _name: string, _mime: string): Promise<string> { throw new Error('upload must not run'); }
  async fetch(_reference: string): Promise<Object | undefined> { throw new Error('recursive fetch must not run'); }
  onRevoked(_listener: () => void): () => void { return (): void => {}; }
  onClosed(listener: () => void): () => void { this.closures.push(listener); return (): void => {}; }
  close(): void { this.live = false; this.closures.forEach((listener: () => void): void => listener()); this.closures = []; }
  async invokeEnvelope(_channel: string, _args: Object[], _timeout?: number): Promise<Envelope> { throw new Error('envelope must not run'); }
  async subscribeTopics(_topics: string[]): Promise<Envelope> { throw new Error('subscribe must not run'); }
  async unsubscribeTopics(_topics: string[]): Promise<Envelope> { throw new Error('unsubscribe must not run'); }
  getStatus(): string { return 'online'; }
  connectionIdentity(): string { return 'identity'; }
  onStatus(_listener: (status: string) => void): () => void { return (): void => {}; }
}
function media(guest: MediaGuest | null, http?: MediaHttpFixture): SharedTaskMedia {
  const context = JSON.parse('{"cacheDir":""}') as common.UIAbilityContext;
  return createSharedTaskMediaPorts({ auth: new MediaAuth(), officialApiBase: 'https://official.invalid',
    scope: (): string => 'account:1', readyGuest: (): SharedTaskReadyTransport | null => guest, context, attachmentCodec: new MediaAttachmentCodecFixture(), http });
}
function nativeTaskKey(task: string = 'share'): string {
  const raw = 'agent-net-v3/00000000-0000-0000-0000-000000000001/private%3Anetwork/00000000-0000-0000-0000-000000000002/00000000-0000-0000-0000-000000000003/' + 'a'.repeat(64) + '/image%2Fpng';
  let hex = ''; for (let index = 0; index < raw.length; index++) hex += raw.charCodeAt(index).toString(16).padStart(2, '0');
  return 'cindy/device-link/shared-task/' + task + '/member/an3-' + hex;
}
function attachment(key: string): string { const ref = new AttachmentOssRef(); ref.ossKey = key; return new MediaAttachmentCodecFixture().encode(ref); }
export default function sharedTaskMediaTests(): void {
  describe('SharedTaskMedia', () => {
    it('cleanup_routes_delegated_receipts_away_from_owner_but_keeps_normal_owner_agent_net_keys', 0, () => {
      const slot = '00000000-0000-0000-0000-000000000001', object = '00000000-0000-0000-0000-000000000002';
      const grant = '00000000-0000-0000-0000-000000000003';
      const prefix = 'agent-net-v3/' + slot + '/private%3Anetwork/', suffix = '/' + object + '/' + 'a'.repeat(64) + '/image%2Fpng';
      expect(requiresScopedMediaCleanup(prefix + '-' + suffix)).assertFalse();
      expect(requiresScopedMediaCleanup(prefix + grant + suffix)).assertTrue();
      expect(requiresScopedMediaCleanup('cindy/device-link/shared-task/share/member/an3-6167656e742d6e65742d7633')).assertTrue();
      expect(requiresScopedMediaCleanup('cindy/device-link/shared-task/share/member/object.png')).assertTrue();
      expect(requiresScopedMediaCleanup('cindy/device-link/owner/object.png')).assertFalse();
    });
    it('official_task_delete_uses_fixed_authenticated_api_without_owner_host_rpc', 0, async () => {
      const guest = new MediaGuest(), http = new MediaHttpFixture(), factory = media(guest, http), key = 'cindy/device-link/shared-task/share/member/object.png';
      await factory.delete(mediaTarget(), key);
      expect(http.receipts.length).assertEqual(1); const receipt = http.receipts[0];
      expect(receipt.address).assertEqual('https://official.invalid/api/device-link/media'); expect(receipt.method).assertEqual('DELETE');
      expect(receipt.timeoutMs).assertEqual(12000); expect(receipt.privateEndpoint).assertTrue(); expect(receipt.authenticated).assertTrue();
      expect(recordOrEmpty(JSON.parse(receipt.body) as Object)['key']).assertEqual(key); expect(guest.calls).assertEqual(0); factory.dispose();
    });
    it('cross_task_and_native_keys_are_rejected_before_official_delete', 0, async () => {
      const guest = new MediaGuest(), http = new MediaHttpFixture(), factory = media(guest, http);
      const invalid: string[] = ['cindy/device-link/shared-task/other/member/object.png', nativeTaskKey(), 'agent-net-v3/invalid'];
      for (const key of invalid) { let rejected = false; try { await factory.delete(mediaTarget(), key); } catch { rejected = true; } expect(rejected).assertTrue(); }
      expect(http.receipts.length).assertEqual(0); expect(guest.calls).assertEqual(0); factory.dispose();
    });
    it('native_task_delete_uses_current_guest_backend_and_never_official_http', 0, async () => {
      const guest = new MediaGuest(); guest.target.transport = 'agent-net'; const deleted: string[] = []; guest.agentNetMedia = nativeMedia(deleted);
      const target = mediaTarget(); target.transport = 'agent-net'; const http = new MediaHttpFixture(), factory = media(guest, http);
      const key = nativeTaskKey();
      // Full receipt/root/network/slot authorization belongs to the actual backend tested separately.
      await factory.delete(target, key); expect(deleted[0]).assertEqual(key); expect(http.receipts.length).assertEqual(0);
      let rejected = false; try { await factory.delete(target, key.replace('/share/', '/other/')); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(deleted.length).assertEqual(1); factory.dispose();
    });
    it('revocation_during_official_delete_never_publishes_late_success_or_retries', 0, async () => {
      const guest = new MediaGuest(), http = new MediaHttpFixture(), factory = media(guest, http); http.delay = new MediaGate(); let rejected = false;
      const pending = factory.delete(mediaTarget(), 'cindy/device-link/shared-task/share/member/object.png').catch((): void => { rejected = true; });
      await http.started.promise; guest.close(); http.delay.release(); await pending;
      expect(rejected).assertTrue(); expect(http.receipts.length).assertEqual(1); factory.dispose();
    });
    it('native_backend_without_delete_fails_closed_instead_of_using_official_or_owner', 0, async () => {
      const guest = new MediaGuest(); guest.target.transport = 'agent-net'; const target = mediaTarget(); target.transport = 'agent-net';
      const http = new MediaHttpFixture(), factory = media(guest, http); let rejected = false;
      try { await factory.delete(target, nativeTaskKey()); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(http.receipts.length).assertEqual(0); expect(guest.calls).assertEqual(0); factory.dispose();
    });
    it('local_reference_is_authorized_via_exact_scoped_host_rpc_before_inline_result', 0, async () => {
      const guest = new MediaGuest(), factory = media(guest);
      const value = recordOrEmpty(await factory.fetch(mediaTarget(), 'xdt-file://local?path=%2Fproject%2Fa.txt'));
      expect(guest.channel).assertEqual('device-link:media:fetch'); expect(guest.args.length).assertEqual(1);
      const request = recordOrEmpty(guest.args[0]); expect(request['prepareOnly']).assertEqual(false);
      expect(request['sessionId'] === undefined).assertTrue(); expect(value['getUrl']).assertEqual('data:text/plain;base64,aGk='); factory.dispose();
    });
    it('plain_web_reference_remains_a_web_url_without_owner_media_rpc', 0, async () => {
      const guest = new MediaGuest(), factory = media(guest), value = recordOrEmpty(await factory.fetch(mediaTarget(), 'https://example.invalid/image.png'));
      expect(value['getUrl']).assertEqual('https://example.invalid/image.png'); expect(guest.calls).assertEqual(0); factory.dispose();
    });
    it('revoked_guest_cannot_publish_delayed_inline_bytes', 0, async () => {
      const guest = new MediaGuest(), factory = media(guest); guest.delay = new MediaGate(); let rejected = false;
      const pending = factory.fetch(mediaTarget(), 'xdt-image://task/image.png').catch((): void => { rejected = true; });
      await guest.started.promise; guest.close(); guest.delay.release(); await pending;
      expect(rejected).assertTrue(); factory.dispose();
    });
    it('same_peer_with_wrong_task_claim_fails_before_host_or_network_access', 0, async () => {
      const guest = new MediaGuest(), factory = media(guest), target = mediaTarget(); target.sharedTaskId = 'other'; let rejected = false;
      try { await factory.fetch(target, 'xdt-image://task/image.png'); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(guest.calls).assertEqual(0); factory.dispose();
    });
    it('forged_transport_claim_cannot_move_private_guest_media_to_official_route', 0, async () => {
      const guest = new MediaGuest(); guest.target.transport = 'agent-net'; const factory = media(guest); let rejected = false;
      try { await factory.fetch(mediaTarget(), 'https://example.invalid/private.png'); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(guest.calls).assertEqual(0); factory.dispose();
    });
    it('unregistered_guest_and_disposed_factory_fail_closed', 0, async () => {
      const absent = media(null); let missing = false; try { await absent.fetch(mediaTarget(), 'https://example.invalid/a'); } catch { missing = true; }
      expect(missing).assertTrue(); absent.dispose();
      const guest = new MediaGuest(), factory = media(guest); factory.dispose(); let rejected = false;
      try { await factory.fetch(mediaTarget(), 'xdt-image://task/image.png'); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(guest.calls).assertEqual(0);
    });
    it('uploaded_reference_for_other_task_never_reaches_host_local_fetch_or_presign', 0, async () => {
      const guest = new MediaGuest(), factory = media(guest); let rejected = false;
      try { await factory.fetch(mediaTarget(), attachment('cindy/device-link/shared-task/other/member/a.png')); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(guest.calls).assertEqual(0); factory.dispose();
    });
    it('agent_net_receipt_cannot_fall_back_to_official_media_transport', 0, async () => {
      const guest = new MediaGuest(), factory = media(guest); let rejected = false;
      try { await factory.fetch(mediaTarget(), attachment('cindy/device-link/shared-task/share/member/an3-receipt')); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(guest.calls).assertEqual(0); factory.dispose();
    });
  });
}
