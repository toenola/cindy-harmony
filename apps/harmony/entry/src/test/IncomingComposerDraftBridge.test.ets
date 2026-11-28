import { IncomingComposerIdleGate } from '../main/ets/core/incoming-share/IncomingComposerIdleGate';
import { restoreIncomingNewSessionDraft } from '../main/ets/core/incoming-share/IncomingNewSessionDrafts';
import { ComposerDraftStore, composerDraftStorageKey } from '../main/ets/core/messages/ComposerDraftStore';
import { SecureStore } from '../main/ets/core/storage/SecureStore';
import { InputQueueStore } from '../main/ets/core/messages/InputQueueStore';
import { SerializedComposerDocument } from '../main/ets/core/messages/ComposerDocument';
import { mergeMessageEditDraft } from '../main/ets/core/messages/MessageEdit';
import { RemoteSession } from '../main/ets/core/tasks/TaskModels';
import { describe, expect, it } from '@ohos/hypium';
import { ComposerDocument, composerDocumentProjectedText, composerDocumentToStorage,
  parseStoredComposerDocument, reconcileComposerProjectedText, textComposerDocument, textNode, quoteNode } from '../main/ets/core/messages/ComposerDocument';
import { IncomingShareDestination, IncomingShareFile } from '../main/ets/core/incoming-share/IncomingShareStore';
import { IncomingComposerDraftBridge, IncomingComposerFile, IncomingComposerDocuments, IncomingComposerFiles, IncomingComposerStorage,
  incomingComposerReceipts } from '../main/ets/core/incoming-share/IncomingComposerDraftBridge';
// Production entry and observable outcome: durable bridge adopt/consume/ack and restart retain the
// exact draft once, private attachment ownership and original outbox clientId. Rule: v1.3.9 F1 /
// credentials-and-local-storage and ComposerDocument semantic invariants. Prior IncomingShare tests
// stop at the draft port and cannot cover its two-ledger crash windows. Minimal failures are one
// copied file before a failed journal write, or doc flush before a failed bridge ack. Unit tier,
// real common document serializer/parser with in-memory disk/files ports, no sleeps/network.
// Runtime is pending Lead's serial Hvigor. Requires the declared common receipt metadata patch.
class MemoryDraftStorage extends SecureStore {
  values: Map<string, string> = new Map();
  beforeSet: () => void = (): void => {};
  async get(key: string, fallback: string): Promise<string> { return this.values.get(key) ?? fallback; }
  async set(key: string, value: string): Promise<void> {
    const before = this.beforeSet; this.beforeSet = (): void => {}; before(); this.values.set(key, value);
  }
  async remove(key: string): Promise<void> { this.values.delete(key); }
}
class BridgeStorage implements IncomingComposerStorage {
  json: string = ''; writes: number = 0; failAt: number = -1;
  read(): string { return this.json; }
  write(json: string): void { this.writes++; if (this.writes === this.failAt) throw new Error('SIMULATED_CRASH'); this.json = json; }
}
class BridgeFiles implements IncomingComposerFiles {
  contents: Map<string, string> = new Map(); removed: string[] = []; sequence: number = 0;
  blockCopy: boolean = false; release: () => void = (): void => {};
  failRemove: boolean = false;
  allocate(name: string): string { return 'draft-owned-' + (++this.sequence) + '/' + name; }
  async copy(source: string, owned: string, _size: number): Promise<void> {
    if (this.blockCopy) await new Promise<void>((resolve) => { this.release = resolve; });
    if (!this.contents.has(owned)) this.contents.set(owned, source);
  }
  async remove(owned: string): Promise<void> {
    if (this.failRemove) throw new Error('GC_UNAVAILABLE');
    this.contents.delete(owned); this.removed.push(owned);
  }
}
class BridgeDocuments implements IncomingComposerDocuments {
  stored: string = composerDocumentToStorage(textComposerDocument('Existing'));
  crashAfterSave: boolean = false; refuse: number = 0; memory: string = ''; failFlush: boolean = false;
  async read(_target: IncomingShareDestination): Promise<ComposerDocument> {
    const document = parseStoredComposerDocument(this.memory || this.stored); if (!document) throw new Error('INVALID_TEST_DOCUMENT'); return document;
  }
  async compareAndSave(_target: IncomingShareDestination, expected: string, document: ComposerDocument): Promise<boolean> {
    // The production page compares its live document, not the bytes loaded from disk.
    // Parsing normalizes adjacent text nodes; CAS must use that same observable revision.
    const current = await this.read(_target);
    if (this.refuse-- > 0 || composerDocumentToStorage(current) !== expected) return false;
    this.memory = composerDocumentToStorage(document);
    if (this.failFlush) throw new Error('DRAFT_FLUSH_FAILED');
    this.stored = this.memory;
    if (this.crashAfterSave) { this.crashAfterSave = false; throw new Error('CRASH_AFTER_DOCUMENT_FLUSH'); }
    return true;
  }
}
function target(device: string = 'computer'): IncomingShareDestination {
  const target = new IncomingShareDestination(); target.ownerKey = 'owner'; target.deviceId = device; target.sessionId = 'session'; return target;
}
function source(name: string = 'report.txt'): IncomingShareFile {
  const file = new IncomingShareFile(); file.uri = 'inbox-owned/' + name; file.name = name; file.mime = 'text/plain'; file.size = 3; return file;
}
async function failure(promise: Promise<Object | void>): Promise<string> {
  try { await promise; return ''; } catch (error) { return String(error); }
}
export default function incomingComposerDraftBridgeTests(): void {
  describe('IncomingComposerDraftBridge', () => {
    // Actual migration/Store and scheduler boundaries: no legacy claiming, no native storage,
    // no clock waits. Minimal failures are one foreign global edit or two same-turn idle events.
    it('idle_notifications_coalesce_and_old_lifecycle_does_not_import', 0, async () => {
      const gate = new IncomingComposerIdleGate(); let generation = 1, imports = 0;
      const request = (): void => {
        const captured = generation;
        gate.request(captured, (): boolean => generation === captured, (): void => { imports++; });
      };
      request(); request(); await Promise.resolve(); expect(imports).assertEqual(1);
      request(); generation = 2; request(); request(); await Promise.resolve(); expect(imports).assertEqual(2);
      request(); generation = 3; await Promise.resolve(); expect(imports).assertEqual(2);
    });
    it('scoped_only_reads_and_cleanup_never_claim_or_remove_the_global_draft', 0, async () => {
      const disk = new MemoryDraftStorage(), store = new ComposerDraftStore(disk);
      const global = textComposerDocument('Global new draft'), scoped = textComposerDocument('Scoped old draft');
      disk.values.set(composerDraftStorageKey('new'), composerDocumentToStorage(global));
      expect((await store.readScopedOnly('new', 'computer')) === null).assertTrue();
      expect(disk.values.get(composerDraftStorageKey('new'))).assertEqual(composerDocumentToStorage(global));
      disk.values.set(composerDraftStorageKey('new', 'computer'), composerDocumentToStorage(scoped));
      expect(await store.clearScopedOnly('new', 'computer', composerDocumentToStorage(scoped))).assertTrue();
      expect(disk.values.has(composerDraftStorageKey('new', 'computer'))).assertFalse();
      expect(disk.values.get(composerDraftStorageKey('new'))).assertEqual(composerDocumentToStorage(global));
    });
    it('ordinary_scoped_recovery_moves_to_empty_global_and_future_devices_share_it', 0, async () => {
      const disk = new MemoryDraftStorage(), store = new ComposerDraftStore(disk), old = textComposerDocument('Ordinary');
      disk.values.set(composerDraftStorageKey('new', 'A'), composerDocumentToStorage(old));
      const restored = await restoreIncomingNewSessionDraft(store, 'new', 'A', false, (): boolean => true);
      expect(restored.deviceId).assertEqual(''); expect(composerDocumentProjectedText(restored.document as ComposerDocument)).assertEqual('Ordinary');
      expect(disk.values.has(composerDraftStorageKey('new', 'A'))).assertFalse();
      const other = await restoreIncomingNewSessionDraft(store, 'new', 'B', false, (): boolean => true);
      expect(composerDocumentProjectedText(other.document as ComposerDocument)).assertEqual('Ordinary');
    });
    it('migration_preserves_existing_global_and_retains_scoped_source_on_a_concurrent_new_edit', 0, async () => {
      const disk = new MemoryDraftStorage(), store = new ComposerDraftStore(disk), old = textComposerDocument('Old source');
      disk.values.set(composerDraftStorageKey('new', 'A'), composerDocumentToStorage(old));
      disk.beforeSet = (): void => { store.save('new', textComposerDocument('Concurrent new global')); };
      const restored = await restoreIncomingNewSessionDraft(store, 'new', 'A', false, (): boolean => true);
      expect(restored.deviceId).assertEqual('');
      expect(composerDocumentProjectedText(restored.document as ComposerDocument)).assertEqual('Concurrent new global');
      expect(disk.values.get(composerDraftStorageKey('new'))).assertEqual(composerDocumentToStorage(textComposerDocument('Concurrent new global')));
      expect(disk.values.has(composerDraftStorageKey('new', 'A'))).assertTrue();
      const again = await restoreIncomingNewSessionDraft(store, 'new', 'A', false, (): boolean => true);
      expect(composerDocumentProjectedText(again.document as ComposerDocument)).assertEqual('Concurrent new global');
    });
    it('only_pending_import_or_actual_receipt_restores_a_device_scoped_composer', 0, async () => {
      const disk = new MemoryDraftStorage(), store = new ComposerDraftStore(disk), incoming = textComposerDocument('Shared');
      incoming.incomingShareBatchIds = ['receipt']; disk.values.set(composerDraftStorageKey('new', 'A'), composerDocumentToStorage(incoming));
      const receipt = await restoreIncomingNewSessionDraft(store, 'new', 'A', false, (): boolean => true);
      expect(receipt.deviceId).assertEqual('A'); expect(receipt.document?.incomingShareBatchIds[0]).assertEqual('receipt');
      const pending = await restoreIncomingNewSessionDraft(store, 'other', 'B', true, (): boolean => true);
      expect(pending.deviceId).assertEqual('B');
    });

    // New-task production prepare/owned/restart entry: the editable composer may differ
    // from its initial imported delivery. Recovery must retain the actual sent snapshot.
    it('new_task_owned_receipt_keeps_the_live_edited_snapshot_and_original_identity', 0, async () => {
      const storage = new BridgeStorage(), files = new BridgeFiles(), documents = new BridgeDocuments();
      let bridge = new IncomingComposerDraftBridge(storage, files); const newTask = target(); newTask.sessionId = '';
      await bridge.setOwner('owner', 1); await bridge.adopt('batch', newTask, 'Shared', []);
      const delivery = await bridge.consume(newTask, documents);
      const live = reconcileComposerProjectedText(delivery.document, 'Edited before send');
      delivery.document = live; bridge.prepareInput(delivery, 'original-client', 'original-session');
      await bridge.reconcileInput(newTask, 'original-client', 'owned');
      bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 2);
      const recovered = bridge.committedInputs(newTask, incomingComposerReceipts(live))[0];
      expect(recovered.clientId).assertEqual('original-client'); expect(recovered.sessionId).assertEqual('original-session');
      expect(recovered.documentStorage).assertEqual(composerDocumentToStorage(live));
      const newer = reconcileComposerProjectedText(live, 'New draft after ownership');
      expect(recovered.documentStorage === composerDocumentToStorage(newer)).assertFalse();
      expect(composerDocumentProjectedText(parseStoredComposerDocument(recovered.documentStorage) as ComposerDocument)).assertEqual('Edited before send');
    });

    // Production boundaries: command intent vs normal input, exact local rollback, and
    // semantic stash merge. One batch/file or two deferred IDs is the minimal failure.
    // Unit tier, in-memory ports; no real RPC, timers, native account or source scanning.
    it('learn_unknown_intent_survives_restart_and_cannot_be_retried_as_an_input', 0, async () => {
      const storage = new BridgeStorage(), files = new BridgeFiles(), documents = new BridgeDocuments();
      let bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 1);
      await bridge.adopt('learn', target(), '/learn explain', []); const delivery = await bridge.consume(target(), documents);
      bridge.ack(delivery, []); bridge.prepareCommand(delivery, 'action');
      bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 2);
      expect(bridge.pendingCommands(target())[0]).assertEqual('action'); expect(bridge.pendingInputs(target()).length).assertEqual(0);
      let retryBlocked = false; try { bridge.prepareCommand(delivery, 'second-action'); } catch { retryBlocked = true; }
      expect(retryBlocked).assertTrue();
      let absenceBlocked = false; try { await bridge.reconcileInput(target(), 'action', 'absent'); } catch { absenceBlocked = true; }
      expect(absenceBlocked).assertTrue();
      expect((await bridge.consume(target(), documents)).batchIds.length).assertEqual(0);
      await bridge.completeCommand(target(), 'action', 'actual-host-run');
      bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 3);
      expect(bridge.pendingCommands(target()).length).assertEqual(0);
      expect(bridge.committedInputs(target(), ['learn'])[0].clientId).assertEqual('action');
      expect(storage.json.includes('actual-host-run')).assertTrue();
    });
    it('deferred_reservation_rollback_removes_the_original_memory_input_before_another_tap', 0, async () => {
      const queue = new InputQueueStore(), session = new RemoteSession(); session.id = 'session'; session.agentKind = 'codex';
      session.agentDeviceId = 'source-computer'; session.providerId = 'provider';
      const document = new SerializedComposerDocument(); document.text = 'Shared';
      const storage = new BridgeStorage(), bridge = new IncomingComposerDraftBridge(storage, new BridgeFiles());
      await bridge.setOwner('owner', 1); await bridge.adopt('batch', target(), 'Shared', []);
      const delivery = await bridge.consume(target(), new BridgeDocuments()); bridge.prepareInput(delivery, 'original');
      queue.deferDocument('computer', session, document, [], [], 'original');
      storage.failAt = storage.writes + 1;
      let failed = false; try { await bridge.reconcileInput(target(), 'original', 'owned'); } catch { failed = true; }
      expect(failed).assertTrue();
      queue.discardReserved('computer', 'session', 'original');
      expect(queue.getBubbles('session', 'computer').length).assertEqual(0);
      storage.failAt = -1; await bridge.reconcileInput(target(), 'original', 'absent'); bridge.prepareInput(delivery, 'second');
      queue.deferDocument('computer', session, document, [], [], 'second');
      const remaining = queue.takeDeferred('session'); expect(remaining.length).assertEqual(1);
      expect(remaining[0].clientId).assertEqual('second');
      const options = remaining[0].raw['createOpts'] as Record<string, Object>;
      expect(options['agentDeviceId']).assertEqual('source-computer');
      session.agentDeviceId = ''; queue.deferDocument('computer', session, document, [], [], 'local');
      const local = queue.takeDeferred('session')[0].raw['createOpts'] as Record<string, Object>;
      expect(local['agentDeviceId'] === undefined).assertTrue();
    });
    it('editing_an_old_message_preserves_text_and_receipt_only_stashed_imports', 0, () => {
      const stash = textComposerDocument('Shared'); stash.incomingShareBatchIds = ['body'];
      const receiptsOnly = new ComposerDocument(); receiptsOnly.incomingShareBatchIds = ['attachment', 'body'];
      const merged = mergeMessageEditDraft(receiptsOnly, stash, null);
      expect(composerDocumentProjectedText(merged)).assertEqual('Shared');
      expect(merged.incomingShareBatchIds.length).assertEqual(2);
      expect(merged.incomingShareBatchIds.includes('attachment')).assertTrue();
      const restored = parseStoredComposerDocument(composerDocumentToStorage(merged));
      expect(restored?.incomingShareBatchIds.length).assertEqual(2);
      const replacement = textComposerDocument('Replacement');
      mergeMessageEditDraft(null, stash, replacement);
      expect(composerDocumentProjectedText(replacement)).assertEqual('Replacement');
      expect(composerDocumentProjectedText(stash)).assertEqual('Shared');
    });
    it('attachment_only_import_restarts_with_its_empty_document_receipt_and_same_owned_file', 0, async () => {
      const storage = new BridgeStorage(), files = new BridgeFiles(), documents = new BridgeDocuments();
      documents.stored = composerDocumentToStorage(new ComposerDocument());
      let bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 1);
      await bridge.adopt('attachment', target(), '', [source()]);
      const first = await bridge.consume(target(), documents); bridge.ack(first, first.files.map((file: IncomingComposerFile): string => file.uri));
      bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 2); documents.memory = '';
      const restored = await bridge.consume(target(), documents);
      expect(restored.document.nodes.length).assertEqual(0); expect(restored.document.incomingShareBatchIds[0]).assertEqual('attachment');
      expect(restored.files[0].uri).assertEqual(first.files[0].uri);
    });

    it('durable_adopt_owns_distinct_files_and_repeat_batch_cannot_append_or_retarget', 0, async () => {
      const files = new BridgeFiles(), bridge = new IncomingComposerDraftBridge(new BridgeStorage(), files), documents = new BridgeDocuments();
      await bridge.setOwner('owner', 1); await bridge.adopt('batch', target(), 'Shared', [source()]);
      await bridge.adopt('batch', target(), 'Shared', [source()]); expect(files.contents.size).assertEqual(1);
      expect((await failure(bridge.adopt('batch', target('different'), 'Shared', [source()]))).includes('BATCH_MISMATCH')).assertTrue();
      const delivery = await bridge.consume(target(), documents); bridge.ack(delivery, delivery.files.map((file: IncomingComposerFile): string => file.uri));
      expect(composerDocumentProjectedText(delivery.document)).assertEqual('Existing\n\nShared');
      expect(incomingComposerReceipts(delivery.document)[0]).assertEqual('batch');
      const again = await bridge.consume(target(), documents); expect(composerDocumentProjectedText(again.document)).assertEqual('Existing\n\nShared');
      expect(again.files[0].uri === source().uri).assertFalse();
    });
    it('copy_completed_before_journal_failure_resumes_the_same_owned_destination', 0, async () => {
      const storage = new BridgeStorage(), files = new BridgeFiles(); let bridge = new IncomingComposerDraftBridge(storage, files);
      await bridge.setOwner('owner', 1); storage.failAt = storage.writes + 2;
      expect((await failure(bridge.adopt('batch', target(), 'Shared', [source()]))).includes('SIMULATED_CRASH')).assertTrue();
      const owned = Array.from(files.contents.keys())[0]; bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 2);
      await bridge.adopt('batch', target(), 'Shared', [source()]);
      const delivery = await bridge.consume(target(), new BridgeDocuments()); expect(delivery.files[0].uri).assertEqual(owned); expect(files.contents.size).assertEqual(1);
    });
    it('document_flush_before_bridge_ack_recovers_by_persisted_receipt_without_duplicate_text', 0, async () => {
      const storage = new BridgeStorage(), files = new BridgeFiles(), documents = new BridgeDocuments();
      const original = textComposerDocument('Existing'); original.nodes.unshift(quoteNode('Quoted semantics', 'file.ts', 1, 2));
      documents.stored = composerDocumentToStorage(original);
      let bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 1); await bridge.adopt('batch', target(), 'Shared', [source()]);
      documents.crashAfterSave = true; expect((await failure(bridge.consume(target(), documents))).includes('CRASH_AFTER_DOCUMENT_FLUSH')).assertTrue();
      bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 2);
      const recovered = await bridge.consume(target(), documents);
      expect(composerDocumentProjectedText(recovered.document)).assertEqual('Existing\n\nShared'); expect(recovered.document.nodes[0].type).assertEqual('quote');
      expect(recovered.files.length).assertEqual(1); expect(incomingComposerReceipts(recovered.document).length).assertEqual(1);
    });
    it('receipt_visible_in_memory_after_failed_flush_is_flushed_again_before_ack', 0, async () => {
      const storage = new BridgeStorage(), files = new BridgeFiles(), documents = new BridgeDocuments();
      const bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 1);
      await bridge.adopt('batch', target(), 'Shared', []); documents.failFlush = true;
      expect((await failure(bridge.consume(target(), documents))).includes('DRAFT_FLUSH_FAILED')).assertTrue();
      expect(documents.stored.includes('Shared')).assertFalse(); documents.failFlush = false;
      await bridge.consume(target(), documents); documents.memory = '';
      const restarted = new IncomingComposerDraftBridge(storage, files); await restarted.setOwner('owner', 2);
      const recovered = await restarted.consume(target(), documents);
      expect(composerDocumentProjectedText(recovered.document)).assertEqual('Existing\n\nShared');
      expect(incomingComposerReceipts(recovered.document).length).assertEqual(1);
    });
    it('partial_queue_acceptance_never_acks_and_removed_attachment_does_not_return_on_restart', 0, async () => {
      const storage = new BridgeStorage(), files = new BridgeFiles(); let bridge = new IncomingComposerDraftBridge(storage, files);
      const documents = new BridgeDocuments(); await bridge.setOwner('owner', 1); await bridge.adopt('batch', target(), 'Shared', [source('a.txt'), source('b.txt')]);
      const delivery = await bridge.consume(target(), documents); let rejected = false;
      try { bridge.ack(delivery, [delivery.files[0].uri]); } catch { rejected = true; }
      expect(rejected).assertTrue(); await bridge.removeFile(target(), delivery.files[1].id);
      bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 2);
      const restored = await bridge.consume(target(), documents); expect(restored.files.length).assertEqual(1); expect(restored.files[0].name).assertEqual('a.txt');
    });
    it('old_account_copy_cannot_commit_and_only_its_owned_copy_is_cleaned', 0, async () => {
      const files = new BridgeFiles(), bridge = new IncomingComposerDraftBridge(new BridgeStorage(), files); await bridge.setOwner('owner', 1);
      files.blockCopy = true; const adopting = failure(bridge.adopt('batch', target(), 'Private', [source()]));
      await Promise.resolve(); const changed = bridge.setOwner('other', 2); files.release(); await changed;
      expect((await adopting).includes('STALE')).assertTrue(); expect(files.contents.size).assertEqual(0);
      const other = target(); other.ownerKey = 'other'; const restored = await bridge.consume(other, new BridgeDocuments()); expect(restored.files.length).assertEqual(0);
    });
    it('unknown_input_receipt_never_becomes_a_new_draft_send_and_absence_uses_same_content_once', 0, async () => {
      const files = new BridgeFiles(), bridge = new IncomingComposerDraftBridge(new BridgeStorage(), files), documents = new BridgeDocuments();
      await bridge.setOwner('owner', 1); await bridge.adopt('batch', target(), 'Shared', [source()]);
      const delivery = await bridge.consume(target(), documents); bridge.prepareInput(delivery, 'original-client-id');
      await bridge.reconcileInput(target(), 'original-client-id', 'unknown');
      expect(bridge.pendingInputIds(target())[0]).assertEqual('original-client-id'); expect((await bridge.consume(target(), documents)).files.length).assertEqual(0);
      await bridge.reconcileInput(target(), 'original-client-id', 'absent'); expect((await bridge.consume(target(), documents)).files.length).assertEqual(1);
      expect(composerDocumentProjectedText(await documents.read(target()))).assertEqual('Existing\n\nShared');
      bridge.prepareInput(delivery, 'original-client-id'); await bridge.reconcileInput(target(), 'original-client-id', 'owned');
      expect(files.contents.size).assertEqual(0); await bridge.adopt('batch', target(), 'Shared', [source()]); expect(files.contents.size).assertEqual(0);
    });
    it('changed_document_CAS_is_retried_boundedly_and_share_is_merged_once', 0, async () => {
      const bridge = new IncomingComposerDraftBridge(new BridgeStorage(), new BridgeFiles()), documents = new BridgeDocuments();
      await bridge.setOwner('owner', 1); await bridge.adopt('batch', target(), 'Shared', []); documents.refuse = 2;
      const delivery = await bridge.consume(target(), documents); expect(composerDocumentProjectedText(delivery.document)).assertEqual('Existing\n\nShared');
      expect(incomingComposerReceipts(delivery.document).length).assertEqual(1);
    });
    it('stored_adjacent_text_is_normalized_before_comparing_the_live_document_revision', 0, async () => {
      const bridge = new IncomingComposerDraftBridge(new BridgeStorage(), new BridgeFiles()), documents = new BridgeDocuments();
      const original = textComposerDocument('Existing'); original.nodes.push(textNode(' tail'));
      documents.stored = composerDocumentToStorage(original);
      await bridge.setOwner('owner', 1); await bridge.adopt('batch', target(), 'Shared', []);
      const delivery = await bridge.consume(target(), documents);
      expect(composerDocumentProjectedText(delivery.document)).assertEqual('Existing tail\n\nShared');
      expect(delivery.document.nodes.length).assertEqual(1);
      documents.memory = ''; expect(composerDocumentProjectedText(await documents.read(target()))).assertEqual('Existing tail\n\nShared');
    });
    it('owned_commit_survives_cleanup_failure_and_recovers_original_new_task_identity', 0, async () => {
      const storage = new BridgeStorage(), files = new BridgeFiles(), documents = new BridgeDocuments();
      let bridge = new IncomingComposerDraftBridge(storage, files); const newTask = target(); newTask.sessionId = '';
      await bridge.setOwner('owner', 1); await bridge.adopt('batch', newTask, 'Shared', [source()]);
      const delivery = await bridge.consume(newTask, documents); bridge.prepareInput(delivery, 'original-id', 'original-session');
      expect(bridge.pendingInputs(newTask)[0].sessionId).assertEqual('original-session');
      files.failRemove = true; await bridge.reconcileInput(newTask, 'original-id', 'owned');
      expect(bridge.cleanupPending()).assertTrue(); expect(bridge.pendingInputs(newTask).length).assertEqual(0);
      bridge = new IncomingComposerDraftBridge(storage, files); await bridge.setOwner('owner', 2);
      const committed = bridge.committedInputs(newTask, incomingComposerReceipts(await documents.read(newTask)));
      expect(committed.length).assertEqual(1); expect(committed[0].clientId).assertEqual('original-id');
      expect(committed[0].sessionId).assertEqual('original-session'); expect(bridge.hasCommittedInput(newTask)).assertTrue();
      expect(bridge.committedInputs(newTask, []).length).assertEqual(0);
      files.failRemove = false; await bridge.retryCleanup(); expect(files.contents.size).assertEqual(0);
    });
  });
}
