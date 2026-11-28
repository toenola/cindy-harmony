import { describe, expect, it } from '@ohos/hypium';
import { registerScopedAttachments, rememberScopedUpload } from '../main/ets/core/attachments/ScopedAttachmentRoutes';
import { uploadImage, uploadDocument, deleteUpload } from '../main/ets/core/attachments/AttachmentUpload';
import { ImageAttachmentCandidate } from '../main/ets/core/attachments/AttachmentModels';
import { sharedTaskHostPeerKey } from '../main/ets/core/shared-tasks/SharedTaskModels';
import { InputQueueStore } from '../main/ets/core/messages/InputQueueStore';
import { SerializedComposerDocument } from '../main/ets/core/messages/ComposerDocument';
import { RemoteSession } from '../main/ets/core/tasks/TaskModels';
import { OwnedHostMedia, OwnedHostMediaPort } from '../main/ets/core/attachments/OwnedHostMedia';
import { RemoteMediaFetchResult } from '../main/ets/core/attachments/AttachmentModels';
import { MessageStore } from '../main/ets/core/messages/MessageStore';
import { InteractionStore, AskUserDraft } from '../main/ets/core/interactions/InteractionStore';
import { DlClient, DlClientOptions, DlInvokeOptions } from '../main/ets/core/device-link/DlClient';
import { Envelope } from '../main/ets/core/device-link/DlProtocol';
import { NewSessionCreationStore, NewSessionCreationParams } from '../main/ets/core/tasks/NewSessionCreationStore';
import { TaskStore } from '../main/ets/core/tasks/TaskStore';

class CreationDispatchClient extends DlClient {
  started: boolean = false; wireCalls: number = 0;
  release: () => void = (): void => {};
  constructor() { super(new DlClientOptions()); }
  subscribe(_device: string, _topics: string[], _timeout: number = 0): Promise<Envelope> {
    const value = new Envelope(); value.payload = fixture('{"ok":true,"result":true}'); return Promise.resolve(value);
  }
  unsubscribe(device: string, topics: string[], timeout: number = 0): Promise<Envelope> { return this.subscribe(device, topics, timeout); }
  invoke(_device: string, options: DlInvokeOptions): Promise<Envelope> {
    this.started = true;
    return new Promise<Envelope>((resolve, reject) => {
      this.release = (): void => {
        try { options.preSend?.(); this.wireCalls++;
          const value = new Envelope(); value.payload = fixture('{"ok":true,"result":{"id":"creating"}}'); resolve(value);
        } catch (error) { reject(error); }
      };
    });
  }
}

class PendingSnapshotClient extends DlClient {
  release: (value: Envelope) => void = (_value: Envelope): void => {};
  started: boolean = false;
  constructor() { super(new DlClientOptions()); }
  invoke(_device: string, _options: DlInvokeOptions): Promise<Envelope> {
    this.started = true; return new Promise<Envelope>((resolve) => { this.release = resolve; });
  }
}
function fixture(json: string): Record<string, Object> { return JSON.parse(json) as Record<string, Object>; }
function inlineMedia(): RemoteMediaFetchResult {
  const value = new RemoteMediaFetchResult(); value.mimeType = 'image/png'; value.inlineBase64 = 'eA=='; return value;
}

// Unit tier. Actual public upload/queue entry points, with only the external
// authenticated media service replaced. No disk, socket, timers or source scans.
// Missing coverage: root attachment routing and owner-directory reconciliation
// can regress independently of the sharing module's own transport tests.
export default function v139IntegrationTests(): void {
  describe('V139Integration', () => {
    // Unit tier: real creation producer + deferred final transport dispatch. A
    // relay replacement must revoke an old creation before its queue slot opens.
    it('cancelled_owner_creation_cannot_dispatch_after_the_owner_route_is_replaced', 0, async () => {
      const client = new CreationDispatchClient(), queue = new InputQueueStore(), messages = new MessageStore();
      const store = new NewSessionCreationStore();
      store.attach(client, new TaskStore(), queue, messages, async (): Promise<void> => {});
      const params = new NewSessionCreationParams(); params.deviceId = 'host'; params.session.id = 'creating';
      params.firstMessageClientId = 'original-input'; params.firstMessageText = 'one intent';
      store.start(params);
      for (let turn = 0; turn < 12; turn++) await Promise.resolve();
      expect(client.started).assertTrue(); store.clearAll(false); client.release();
      for (let turn = 0; turn < 12; turn++) await Promise.resolve();
      expect(client.wireCalls).assertEqual(0); expect(store.getTask('creating')).assertNull(); queue.clearAll();
    });
    it('reopening_a_cleaned_host_picture_bypasses_the_computers_stale_upload_key', 0, async () => {
      let key = '', serial = 0; const removed: Set<string> = new Set();
      const port: OwnedHostMediaPort = { current: (): boolean => true,
        fetch: async (_device, _reference, _thumbnail, guard, skipCache): Promise<RemoteMediaFetchResult> => {
          guard(); if (!key || skipCache) key = 'temporary-' + (++serial);
          const result = new RemoteMediaFetchResult(); result.ossKey = key; return result;
        }, presign: async (value: string): Promise<string> => {
          if (removed.has(value)) throw new Error('MEDIA_GONE'); return 'https://media.example/' + value;
        }, remove: async (value: string): Promise<void> => { removed.add(value); }, decode: () => null };
      const first = new OwnedHostMedia(port);
      expect(await first.resolve('host', 'cindy-media://blobs/image.png', false)).assertEqual('https://media.example/temporary-1');
      first.dispose(); expect(removed.has('temporary-1')).assertTrue();
      const reopened = new OwnedHostMedia(port);
      expect(await reopened.resolve('host', 'cindy-media://blobs/image.png', false)).assertEqual('https://media.example/temporary-2');
      reopened.dispose();
    });
    // Unit tier: real cleanup entry, no owner network/storage. A key alone is not
    // permission to delete; only its still-current upload lease authorizes it.
    it('shared_cleanup_uses_the_original_upload_lease_and_revocation_cannot_fall_back', 0, async () => {
      const peer = sharedTaskHostPeerKey('share', 'host'), key = 'cindy/device-link/shared-task/share/device/object';
      const deleted: string[] = [];
      const off = registerScopedAttachments(peer, { current: (): boolean => true,
        upload: async (): Promise<string> => '', fetch: async (): Promise<Object | undefined> => undefined,
        delete: async (value: string): Promise<void> => { deleted.push(value); } });
      rememberScopedUpload(peer, key); await deleteUpload(key, 'must-not-be-used');
      expect(deleted.join(',')).assertEqual(key);
      rememberScopedUpload(peer, key); off(); let code = '';
      try { await deleteUpload(key, 'must-not-be-used'); } catch (error) { code = error instanceof Error ? error.message : ''; }
      expect(code).assertEqual('ACCESS_REVOKED'); expect(deleted.length).assertEqual(1);
    });
    // Unit tier: production status/pending entry points. One main-transport failure
    // must not erase an independent guest, and a revoked scope rejects late cards.
    it('main_disconnect_preserves_guest_metrics_and_guest_failure_is_exact', 0, () => {
      const messages = new MessageStore(), peer = sharedTaskHostPeerKey('share', 'host');
      const status = fixture('{"type":"status","data":{"isRunning":true,"outputTokens":40,"generationDurationMs":1000,"generationActive":true}}');
      messages.handleMakerEvent('owner-session', status, '', 'physical-host');
      messages.handleMakerEvent('guest-session', status, '', peer);
      expect(messages.getGenerationStatus('guest-session', peer).outputTokens).assertEqual(40);
      messages.invalidateOwnerLiveTailTrust();
      expect(messages.getGenerationStatus('owner-session', 'physical-host').outputTokens).assertEqual(0);
      expect(messages.getGenerationStatus('guest-session', peer).outputTokens).assertEqual(40);
      messages.invalidatePeerLiveTailTrust(peer);
      expect(messages.getGenerationStatus('guest-session', peer).outputTokens).assertEqual(0);
      messages.setCacheAccountScope('next-account');
    });
    it('scope_revocation_clears_only_its_draft_and_rejects_a_late_pending_snapshot', 0, async () => {
      const interactions = new InteractionStore(), client = new PendingSnapshotClient(); interactions.attach(client);
      const a = sharedTaskHostPeerKey('a', 'host'), b = sharedTaskHostPeerKey('b', 'host');
      const payload = fixture('{"sessionId":"session","request":{"requestId":"question","kind":"ask_user_question"}}');
      interactions.handleInteractionRequest(payload, a); interactions.handleInteractionRequest(payload, b);
      const draft = new AskUserDraft(); draft.customInput = 'keep B';
      interactions.saveAskDraft('question', draft, a, 'session'); interactions.saveAskDraft('question', draft, b, 'session');
      const pending = interactions.refreshPending(a, 'session'); expect(client.started).assertTrue();
      interactions.invalidateSession(a, 'session');
      const response = new Envelope(); response.payload = fixture('{"ok":true,"result":[{"requestId":"late","kind":"ask_user_question"}]}');
      client.release(response); await pending;
      expect(interactions.getPending('session', a).length).assertEqual(0);
      expect(interactions.readAskDraft('question', a, 'session')).assertNull();
      expect(interactions.getPending('session', b).length).assertEqual(1);
      expect(interactions.readAskDraft('question', b, 'session')?.customInput).assertEqual('keep B');
      interactions.clearAll();
    });
    // Unit tier: actual media lease with only RPC/presign service ports replaced.
    // Regression: old-account inline results and generated temporary objects must
    // not outlive the visible group, while original uploads must remain intact.
    it('owned_host_media_fences_account_change_and_cleans_only_temporary_objects', 0, async () => {
      let current = true; const removed: string[] = [];
      let release: (value: RemoteMediaFetchResult) => void = (_value: RemoteMediaFetchResult): void => {};
      let deferred = false;
      const port: OwnedHostMediaPort = { current: (): boolean => current,
        fetch: async (): Promise<RemoteMediaFetchResult> => {
          if (deferred) return new Promise<RemoteMediaFetchResult>((resolve) => { release = resolve; });
          const value = new RemoteMediaFetchResult(); value.ossKey = 'temporary'; return value;
        }, presign: async (): Promise<string> => 'https://media.example/image',
        remove: async (key: string): Promise<void> => { removed.push(key); }, decode: () => null };
      const resolver = new OwnedHostMedia(port);
      expect(await resolver.resolve('host', 'cindy-media://blobs/image.png', false)).assertEqual('https://media.example/image');
      resolver.dispose(); expect(removed.join(',')).assertEqual('temporary');
      const fresh = new OwnedHostMedia(port); deferred = true;
      const request = fresh.resolve('host', 'cindy-media://blobs/late.png', true); current = false; release(inlineMedia());
      let error = ''; try { await request; } catch (failure) { error = failure instanceof Error ? failure.message : ''; }
      expect(error).assertEqual('OWNER_CHANGED'); fresh.dispose();
      expect(removed.length).assertEqual(1);
    });
    it('canonical_guest_cannot_borrow_owned_host_media_even_when_a_port_accepts_it', 0, async () => {
      let calls = 0;
      const port: OwnedHostMediaPort = { current: (): boolean => true,
        fetch: async (): Promise<RemoteMediaFetchResult> => { calls++; return inlineMedia(); },
        presign: async (): Promise<string> => '', remove: async (): Promise<void> => {} };
      const resolver = new OwnedHostMedia(port); let error = '';
      try { await resolver.resolve(sharedTaskHostPeerKey('share', 'host'), 'cindy-media://blobs/image.png', true); }
      catch (failure) { error = failure instanceof Error ? failure.message : ''; }
      expect(error).assertEqual('OWNER_CHANGED'); expect(calls).assertEqual(0); resolver.dispose();
    });
    it('unregistered_shared_upload_fails_before_owner_storage_or_local_file_read', 0, async () => {
      const candidate = new ImageAttachmentCandidate(); candidate.uri = 'unreadable://photo';
      let message = '';
      try { await uploadImage(candidate, 'must-not-be-used', sharedTaskHostPeerKey('share', 'host')); }
      catch (error) { message = error instanceof Error ? error.message : ''; }
      expect(message).assertEqual('ACCESS_REVOKED');
    });

    it('invalid_shared_upload_reference_never_falls_back_to_owner_storage', 0, async () => {
      const peer = sharedTaskHostPeerKey('share', 'host'), calls: string[] = [];
      const sealed = 'invalid-authorized-service-reference';
      const off = registerScopedAttachments(peer, { current: (): boolean => true,
        upload: async (uri: string, name: string, mime: string): Promise<string> => { calls.push(JSON.stringify([uri, name, mime])); return sealed; },
        fetch: async (_ref: string): Promise<Object | undefined> => undefined });
      try {
        const candidate = new ImageAttachmentCandidate(); candidate.uri = 'private://photo';
        candidate.name = 'photo.png'; candidate.mimeType = 'image/png';
        let imageError = '', fileError = '';
        try { await uploadImage(candidate, 'unused', peer); } catch (error) { imageError = error instanceof Error ? error.message : ''; }
        try { await uploadDocument('private://file', 'report.txt', 'unused', peer); } catch (error) { fileError = error instanceof Error ? error.message : ''; }
        expect(imageError).assertEqual('SHARED_TASK_MEDIA_INVALID'); expect(fileError).assertEqual('SHARED_TASK_MEDIA_INVALID');
        expect(calls.length).assertEqual(2);
        expect(calls[0]).assertEqual(JSON.stringify(['private://photo', 'photo.png', 'image/png']));
      } finally { off(); }
    });

    it('revocation_discards_late_shared_upload_and_never_falls_back_to_owner', 0, async () => {
      const peer = sharedTaskHostPeerKey('share', 'host'); let current = true;
      let release: (value: string) => void = (_value: string): void => {};
      const waiting = new Promise<string>((resolve) => { release = resolve; });
      const off = registerScopedAttachments(peer, { current: (): boolean => current,
        upload: async (): Promise<string> => waiting, fetch: async (): Promise<Object | undefined> => undefined });
      const candidate = new ImageAttachmentCandidate(); candidate.uri = 'private://photo';
      const pending = uploadImage(candidate, 'unused', peer); current = false; release('late');
      let message = ''; try { await pending; } catch (error) { message = error instanceof Error ? error.message : ''; } finally { off(); }
      expect(message).assertEqual('ACCESS_REVOKED');
    });

    it('owner_device_snapshot_cannot_revoke_an_independent_shared_input', 0, () => {
      const queue = new InputQueueStore(), session = new RemoteSession(), document = new SerializedComposerDocument();
      session.id = 'session'; session.agentKind = 'codex'; document.text = 'one intent';
      const peer = sharedTaskHostPeerKey('share', 'host');
      queue.deferDocument(peer, session, document, [], [], 'same-client');
      queue.reconcileDeviceSnapshot(new Set<string>(), new Set<string>());
      expect(queue.isLocallyOwnedInput(peer, session.id, 'same-client')).assertTrue();
      expect(queue.getBubbles(session.id, peer).length).assertEqual(1);
      queue.clearAll();
    });
    it('replacing_the_owner_route_discards_only_owner_deferred_inputs_before_reuse', 0, () => {
      const queue = new InputQueueStore(), owner = new RemoteSession(), guest = new RemoteSession(), document = new SerializedComposerDocument();
      owner.id = 'owner'; owner.agentKind = 'codex'; guest.id = 'guest'; guest.agentKind = 'codex'; document.text = 'one intent';
      const peer = sharedTaskHostPeerKey('share', 'host');
      queue.deferDocument('host', owner, document, [], [], 'owner-input');
      queue.deferDocument(peer, guest, document, [], [], 'guest-input');
      queue.invalidateOwnerDevices();
      expect(queue.getBubbles(owner.id, 'host').length).assertEqual(0);
      expect(queue.getBubbles(guest.id, peer).length).assertEqual(1);
      expect(queue.isLocallyOwnedInput(peer, guest.id, 'guest-input')).assertTrue(); queue.clearAll();
    });
  });
}
