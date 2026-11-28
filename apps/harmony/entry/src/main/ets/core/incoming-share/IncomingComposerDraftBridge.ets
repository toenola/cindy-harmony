import { ComposerDocument, ComposerNode, composerDocumentProjectedText, composerDocumentToStorage,
  parseStoredComposerDocument, normalizeComposerDocument, textNode } from '../messages/ComposerDocument';
import { recordOrEmpty } from '../tasks/TaskModels';
import { IncomingShareDestination, IncomingShareDraftPort, IncomingShareFile } from './IncomingShareStore';

export interface IncomingComposerStorage { read(): string; write(json: string): void; }
export interface IncomingComposerFiles {
  allocate(name: string): string;
  copy(source: string, owned: string, size: number): Promise<void>;
  remove(owned: string): Promise<void>;
}
/** Page adapter only reads/applies the current document and awaits existing save/flush.
 * compareAndSave must reject changed UI revisions/owners, apply the document synchronously,
 * and never enqueue input or create a task. Attachment queue adoption happens after consume. */
export interface IncomingComposerDocuments {
  read(destination: IncomingShareDestination): Promise<ComposerDocument>;
  compareAndSave(destination: IncomingShareDestination, expectedStorage: string, document: ComposerDocument): Promise<boolean>;
}
export class IncomingComposerFile extends IncomingShareFile {
  id: string = ''; sourceUri: string = ''; copied: boolean = false; removed: boolean = false;
}
export class IncomingComposerBatch {
  batchId: string = ''; target: IncomingShareDestination = new IncomingShareDestination();
  text: string = ''; sourceFingerprint: string = ''; files: IncomingComposerFile[] = [];
  phase: string = 'copying'; textApplied: boolean = false;
  commandKind: string = '';
  mergedDocument: string = ''; inputClientId: string = ''; inputSessionId: string = '';
}
export class IncomingComposerReceipt {
  batchId: string = ''; targetKey: string = '';
  inputClientId: string = ''; inputSessionId: string = ''; commandRunId: string = ''; documentStorage: string = '';
}
export class IncomingComposerLedger {
  version: number = 1; owner: string = '';
  batches: IncomingComposerBatch[] = []; completed: IncomingComposerReceipt[] = []; garbage: string[] = [];
}
/** A stable, recoverable projection, not a send instruction. Re-enqueue the same owned URIs:
 * existing image/file queues deduplicate those URIs within the live composer. */
export class IncomingComposerPendingInput { clientId: string = ''; sessionId: string = ''; batchIds: string[] = []; documentStorage: string = ''; }
export class IncomingComposerDelivery {
  target: IncomingShareDestination = new IncomingShareDestination();
  batchIds: string[] = []; document: ComposerDocument = new ComposerDocument();
  files: IncomingComposerFile[] = [];
}
// Compatible before/after the Lead adds this optional field to the common document model.
class IncomingReceiptDocument extends ComposerDocument { incomingShareBatchIds: string[] = []; }
function cloneDestination(destination: IncomingShareDestination): IncomingShareDestination {
  return JSON.parse(JSON.stringify(destination)) as IncomingShareDestination;
}
export function incomingComposerTargetKey(destination: IncomingShareDestination): string {
  return JSON.stringify([destination.ownerKey, destination.deviceId, destination.sessionId]);
}
export function incomingComposerReceipts(document: ComposerDocument): string[] {
  const raw = recordOrEmpty(JSON.parse(JSON.stringify(document)) as Object), value = raw['incomingShareBatchIds'];
  if (!Array.isArray(value)) return [];
  return (value as Object[]).filter((item: Object): boolean => typeof item === 'string').slice(-256) as string[];
}
export function withIncomingComposerReceipts(document: ComposerDocument, receipts: string[]): ComposerDocument {
  const next = new IncomingReceiptDocument(); next.nodes = JSON.parse(JSON.stringify(document.nodes)) as ComposerNode[];
  next.incomingShareBatchIds = receipts.slice(-256); return next;
}
function appendBatch(document: ComposerDocument, batch: IncomingComposerBatch): ComposerDocument {
  const next = new IncomingReceiptDocument();
  next.nodes = (JSON.parse(JSON.stringify(document.nodes)) as ComposerNode[]);
  next.incomingShareBatchIds = incomingComposerReceipts(document);
  if (next.incomingShareBatchIds.includes(batch.batchId)) return document;
  if (batch.text) {
    const prefix = composerDocumentProjectedText(document).length > 0 ? '\n\n' : '';
    next.nodes.push(textNode(prefix + batch.text));
  }
  next.incomingShareBatchIds = next.incomingShareBatchIds.concat([batch.batchId]).slice(-256);
  // Refuse before touching the UI if the common serializer cannot yet persist the receipt.
  // Persist the same canonical node shape the common parser restores. In particular,
  // adjacent text nodes must not change a document's CAS representation after a restart.
  const normalized = normalizeComposerDocument(next);
  const roundTrip = parseStoredComposerDocument(composerDocumentToStorage(normalized));
  if (!roundTrip || !incomingComposerReceipts(roundTrip).includes(batch.batchId)) throw new Error('INCOMING_COMPOSER_RECEIPTS_UNSUPPORTED');
  return normalized;
}
export class IncomingComposerDraftBridge implements IncomingShareDraftPort {
  private storage: IncomingComposerStorage;
  private files: IncomingComposerFiles;
  private ledger: IncomingComposerLedger;
  private owner: string = '';
  private generation: number = 0;
  private epoch: number = 0;
  private tail: Promise<void> = Promise.resolve();
  private pendingOperations: number = 0;
  private cleanupFailed: boolean = false;
  private listeners: Set<() => void> = new Set();
  constructor(storage: IncomingComposerStorage, files: IncomingComposerFiles) {
    this.storage = storage; this.files = files;
    const json = storage.read(); this.ledger = json ? JSON.parse(json) as IncomingComposerLedger : new IncomingComposerLedger();
    if (this.ledger.version !== 1 || !Array.isArray(this.ledger.batches) || this.ledger.batches.length > 64
      || !Array.isArray(this.ledger.completed) || !Array.isArray(this.ledger.garbage)) throw new Error('INCOMING_COMPOSER_INVALID_LEDGER');
  }
  onChanged(listener: () => void): () => void { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; }
  private emit(): void {
    this.listeners.forEach((listener: () => void): void => { try { listener(); } catch { } });
  }
  private clone(): IncomingComposerLedger { return JSON.parse(JSON.stringify(this.ledger)) as IncomingComposerLedger; }
  private commit(next: IncomingComposerLedger): void {
    const json = JSON.stringify(next);
    if (json.length > 4 * 1024 * 1024) throw new Error('INCOMING_COMPOSER_STORAGE_LIMIT');
    this.storage.write(json); this.ledger = next;
  }
  private serial(work: () => Promise<void>): Promise<void> {
    this.pendingOperations++;
    const run: Promise<void> = this.tail.then(work).finally(() => { this.pendingOperations--; });
    this.tail = run.catch(() => {}); return run;
  }
  isBusy(): boolean { return this.pendingOperations > 0; }
  private assertIdle(): void { if (this.isBusy()) throw new Error('INCOMING_COMPOSER_BUSY'); }
  private assertCurrent(owner: string, epoch: number): void {
    if (!owner || owner !== this.owner || this.ledger.owner !== owner || epoch !== this.epoch) throw new Error('INCOMING_COMPOSER_STALE');
  }
  private assertTarget(target: IncomingShareDestination): void {
    if (!target.deviceId || target.ownerKey !== this.owner) throw new Error('INCOMING_COMPOSER_TARGET_INVALID');
    this.assertCurrent(target.ownerKey, this.epoch);
  }
  setOwner(owner: string, generation: number): Promise<void> {
    if (owner !== this.owner || generation !== this.generation) this.epoch++;
    this.owner = owner; this.generation = generation;
    if (this.ledger.owner !== owner || !owner) {
      const next = this.clone();
      for (const batch of next.batches) for (const file of batch.files) next.garbage.push(file.uri);
      next.owner = owner; next.batches = []; next.completed = []; this.commit(next); this.emit();
    }
    return this.scheduleCleanup();
  }
  previewFiles(target: IncomingShareDestination): IncomingComposerFile[] {
    this.assertTarget(target); const key = incomingComposerTargetKey(target), files: IncomingComposerFile[] = [];
    for (const batch of this.ledger.batches) if (incomingComposerTargetKey(batch.target) === key
      && batch.phase !== 'queued' && batch.phase !== 'command-pending') {
      for (const file of batch.files) if (!file.removed) files.push(JSON.parse(JSON.stringify(file)) as IncomingComposerFile);
    }
    return files;
  }
  pendingTargets(): IncomingShareDestination[] {
    if (!this.owner || this.ledger.owner !== this.owner) return [];
    const seen: Set<string> = new Set(), targets: IncomingShareDestination[] = [];
    for (const batch of this.ledger.batches) {
      const key = incomingComposerTargetKey(batch.target);
      if (!seen.has(key)) { seen.add(key); targets.push(cloneDestination(batch.target)); }
    }
    return targets;
  }
  /** Durable adopt is independent of page lifetime. The inbox may release originals only after true. */
  async adopt(batchId: string, target: IncomingShareDestination, text: string, sources: IncomingShareFile[]): Promise<boolean> {
    this.assertTarget(target); const owner = this.owner, epoch = this.epoch;
    await this.serial(async (): Promise<void> => {
      this.assertCurrent(owner, epoch);
      if (!batchId || batchId.length > 128 || text.length > 200000 || sources.length > 20) throw new Error('INCOMING_COMPOSER_LIMIT');
      const targetKey = incomingComposerTargetKey(target);
      const fingerprint = JSON.stringify([targetKey, text, JSON.stringify(sources)]);
      const completed = this.ledger.completed.find((receipt: IncomingComposerReceipt): boolean => receipt.batchId === batchId);
      if (completed) {
        if (completed.targetKey !== targetKey) throw new Error('INCOMING_COMPOSER_TARGET_MISMATCH');
        return;
      }
      let batch = this.ledger.batches.find((batch: IncomingComposerBatch): boolean => batch.batchId === batchId);
      if (batch && batch.sourceFingerprint !== fingerprint) throw new Error('INCOMING_COMPOSER_BATCH_MISMATCH');
      if (batch && batch.phase !== 'copying') return;
      if (!batch) {
        if (this.ledger.batches.length >= 64) throw new Error('INCOMING_COMPOSER_FULL');
        batch = new IncomingComposerBatch(); batch.batchId = batchId; batch.target = cloneDestination(target);
        batch.text = text; batch.sourceFingerprint = fingerprint;
        for (let i = 0; i < sources.length; i++) {
          const source = sources[i], file = new IncomingComposerFile(); file.id = batchId + ':' + i;
          file.sourceUri = source.uri; file.uri = this.files.allocate(source.name); file.name = source.name; file.mime = source.mime; file.size = source.size;
          batch.files.push(file);
        }
        const prepared = this.clone(); prepared.batches.push(batch); this.commit(prepared);
      }
      for (let i = 0; i < batch.files.length; i++) {
        const file = batch.files[i];
        if (file.copied || file.removed) continue;
        await this.files.copy(file.sourceUri, file.uri, file.size); this.assertCurrent(owner, epoch);
        const next = this.clone(), current = next.batches.find((item: IncomingComposerBatch): boolean => item.batchId === batchId);
        if (!current) throw new Error('INCOMING_COMPOSER_STALE');
        current.files[i].copied = true; this.commit(next);
      }
      this.assertCurrent(owner, epoch);
      const ready = this.clone(), current = ready.batches.find((item: IncomingComposerBatch): boolean => item.batchId === batchId);
      if (!current) throw new Error('INCOMING_COMPOSER_STALE');
      current.phase = current.textApplied ? 'applied' : 'ready'; this.commit(ready); this.emit();
    });
    return true;
  }
  /** Caller first restores its normal draft, then consumes only on the selected target while active.
   * All merge/CAS/WAL work is here; a retry after any crash cannot append an applied batch twice. */
  async consume(target: IncomingShareDestination, documents: IncomingComposerDocuments): Promise<IncomingComposerDelivery> {
    this.assertTarget(target); const owner = this.owner, epoch = this.epoch;
    const delivery = new IncomingComposerDelivery(); delivery.target = cloneDestination(target);
    await this.serial(async (): Promise<void> => {
      this.assertCurrent(owner, epoch); const key = incomingComposerTargetKey(target);
      const batchIds = this.ledger.batches.filter((batch: IncomingComposerBatch): boolean => incomingComposerTargetKey(batch.target) === key
        && batch.phase !== 'copying' && batch.phase !== 'queued' && batch.phase !== 'command-pending').map((batch: IncomingComposerBatch): string => batch.batchId);
      for (const batchId of batchIds) {
        let applied = false;
        for (let attempt = 0; attempt < 3 && !applied; attempt++) {
          const batch = this.ledger.batches.find((batch: IncomingComposerBatch): boolean => batch.batchId === batchId);
          if (!batch) throw new Error('INCOMING_COMPOSER_STALE');
          const document = await documents.read(target); this.assertCurrent(owner, epoch);
          const already = batch.textApplied || incomingComposerReceipts(document).includes(batchId);
          const nextDocument = already ? document : appendBatch(document, batch);
          const journal = this.clone(), entry = journal.batches.find((batch: IncomingComposerBatch): boolean => batch.batchId === batchId);
          if (!entry) throw new Error('INCOMING_COMPOSER_STALE');
          entry.mergedDocument = composerDocumentToStorage(nextDocument); this.commit(journal);
          // A receipt visible only in memory after a failed flush is not durable proof.
          if (!batch.textApplied && !await documents.compareAndSave(target, composerDocumentToStorage(document), nextDocument)) continue;
          this.assertCurrent(owner, epoch);
          const saved = this.clone(), current = saved.batches.find((batch: IncomingComposerBatch): boolean => batch.batchId === batchId);
          if (!current) throw new Error('INCOMING_COMPOSER_STALE');
          current.textApplied = true; current.phase = 'applied'; this.commit(saved); applied = true;
        }
        if (!applied) throw new Error('INCOMING_COMPOSER_CHANGED');
      }
      delivery.document = await documents.read(target); this.assertCurrent(owner, epoch);
      delivery.batchIds = batchIds;
      for (const batchId of batchIds) {
        const batch = this.ledger.batches.find((batch: IncomingComposerBatch): boolean => batch.batchId === batchId);
        if (batch) delivery.files = delivery.files.concat(batch.files.filter((file: IncomingComposerFile): boolean => !file.removed));
      }
    });
    return delivery;
  }
  /** enqueue is synchronous. Ack only after both actual queues contain every delivery URI.
   * Ack retains durable files for cold restart; it never means 'message sent'. */
  ack(delivery: IncomingComposerDelivery, queuedUris: string[]): void {
    this.assertIdle(); this.assertTarget(delivery.target);
    if (delivery.files.some((file: IncomingComposerFile): boolean => !queuedUris.includes(file.uri))) throw new Error('INCOMING_COMPOSER_QUEUE_INCOMPLETE');
    const next = this.clone();
    for (const id of delivery.batchIds) {
      const batch = next.batches.find((batch: IncomingComposerBatch): boolean => batch.batchId === id);
      if (!batch || !batch.textApplied || incomingComposerTargetKey(batch.target) !== incomingComposerTargetKey(delivery.target)) throw new Error('INCOMING_COMPOSER_STALE');
      batch.phase = 'acknowledged';
    }
    this.commit(next);
  }
  /** Explicit local attachment removal is durable so it cannot reappear after a restart. */
  removeFile(target: IncomingShareDestination, fileId: string): Promise<void> {
    this.assertIdle(); this.assertTarget(target); const key = incomingComposerTargetKey(target), next = this.clone();
    for (const batch of next.batches) {
      if (incomingComposerTargetKey(batch.target) !== key) continue;
      const file = batch.files.find((file: IncomingComposerFile): boolean => file.id === fileId);
      if (file && !file.removed) { file.removed = true; next.garbage.push(file.uri); }
    }
    this.commit(next); return this.scheduleCleanup();
  }
  /** Before existing input enqueue, persist that exact clientId as an ownership-transfer intent.
   * No send occurs here. Unknown receipt remains queued and is never restored as a new input. */
  prepareInput(delivery: IncomingComposerDelivery, clientId: string, sessionId: string = ''): void {
    this.assertIdle(); this.assertTarget(delivery.target); if (!clientId) throw new Error('INCOMING_COMPOSER_INPUT_ID_REQUIRED');
    const next = this.clone();
    for (const id of delivery.batchIds) {
      const batch = next.batches.find((batch: IncomingComposerBatch): boolean => batch.batchId === id);
      if (!batch || incomingComposerTargetKey(batch.target) !== incomingComposerTargetKey(delivery.target)) throw new Error('INCOMING_COMPOSER_STALE');
      if (!batch.textApplied || batch.phase === 'copying' || batch.phase === 'command-pending') throw new Error('INCOMING_COMPOSER_NOT_APPLIED');
      if (batch.inputClientId && batch.inputClientId !== clientId) throw new Error('INCOMING_COMPOSER_INPUT_MISMATCH');
      batch.mergedDocument = composerDocumentToStorage(delivery.document);
      batch.inputClientId = clientId; batch.inputSessionId = sessionId || delivery.target.sessionId; batch.phase = 'queued';
    }
    this.commit(next);
  }
  /** learn:start has no host idempotency key. This intent is deliberately not an input outbox. */
  prepareCommand(delivery: IncomingComposerDelivery, actionId: string): void {
    this.assertIdle(); this.assertTarget(delivery.target);
    if (!actionId || delivery.batchIds.length === 0) throw new Error('INCOMING_COMPOSER_COMMAND_INVALID');
    const next = this.clone();
    for (const id of delivery.batchIds) {
      const batch = next.batches.find((batch: IncomingComposerBatch): boolean => batch.batchId === id);
      if (!batch || !batch.textApplied || incomingComposerTargetKey(batch.target) !== incomingComposerTargetKey(delivery.target)
        || batch.phase === 'queued' || batch.phase === 'command-pending') throw new Error('INCOMING_COMPOSER_COMMAND_UNRESOLVED');
      batch.mergedDocument = composerDocumentToStorage(delivery.document);
      batch.phase = 'command-pending'; batch.commandKind = 'learn'; batch.inputClientId = actionId;
      batch.inputSessionId = delivery.target.sessionId;
    }
    this.commit(next);
  }
  pendingCommands(target: IncomingShareDestination): string[] {
    this.assertTarget(target); const key = incomingComposerTargetKey(target), ids: string[] = [];
    for (const batch of this.ledger.batches) if (batch.phase === 'command-pending' && incomingComposerTargetKey(batch.target) === key
      && !ids.includes(batch.inputClientId)) ids.push(batch.inputClientId);
    return ids;
  }
  completeCommand(target: IncomingShareDestination, actionId: string, runId: string): Promise<void> {
    this.assertIdle(); this.assertTarget(target);
    if (!runId || runId.length > 256) throw new Error('INCOMING_COMPOSER_COMMAND_UNCONFIRMED');
    const next = this.clone(), key = incomingComposerTargetKey(target);
    const matches = next.batches.filter((batch: IncomingComposerBatch): boolean => batch.phase === 'command-pending'
      && batch.inputClientId === actionId && incomingComposerTargetKey(batch.target) === key);
    if (matches.length === 0) throw new Error('INCOMING_COMPOSER_COMMAND_STALE');
    for (const batch of matches) {
      const receipt = new IncomingComposerReceipt(); receipt.batchId = batch.batchId; receipt.targetKey = key;
      receipt.inputClientId = actionId; receipt.inputSessionId = target.sessionId; receipt.commandRunId = runId; receipt.documentStorage = batch.mergedDocument;
      next.completed.push(receipt); for (const file of batch.files) next.garbage.push(file.uri);
    }
    next.batches = next.batches.filter((batch: IncomingComposerBatch): boolean => !matches.includes(batch));
    next.completed = next.completed.slice(-256); this.commit(next); this.emit(); return this.scheduleCleanup();
  }
  pendingInputs(target: IncomingShareDestination): IncomingComposerPendingInput[] {
    this.assertTarget(target); const key = incomingComposerTargetKey(target), result: IncomingComposerPendingInput[] = [];
    for (const batch of this.ledger.batches) {
      if (incomingComposerTargetKey(batch.target) !== key || batch.phase !== 'queued') continue;
      let item = result.find((item: IncomingComposerPendingInput): boolean => item.clientId === batch.inputClientId);
      if (!item) {
        item = new IncomingComposerPendingInput(); item.clientId = batch.inputClientId; item.sessionId = batch.inputSessionId || target.sessionId; result.push(item);
      }
      item.batchIds.push(batch.batchId);
    }
    return result;
  }
  pendingInputIds(target: IncomingShareDestination): string[] {
    this.assertTarget(target); const key = incomingComposerTargetKey(target), ids: string[] = [];
    for (const batch of this.ledger.batches) if (incomingComposerTargetKey(batch.target) === key && batch.phase === 'queued' && !ids.includes(batch.inputClientId)) ids.push(batch.inputClientId);
    return ids;
  }
  /** A crash after owned commit but before clearing the composer must not create another input.
   * Only receipts still in that actual document expose their original outbox identity. */
  committedInputs(target: IncomingShareDestination, receipts: string[]): IncomingComposerPendingInput[] {
    if (!target.ownerKey || target.ownerKey !== this.owner || this.ledger.owner !== this.owner || !target.deviceId) return [];
    this.assertTarget(target); const key = incomingComposerTargetKey(target), result: IncomingComposerPendingInput[] = [];
    for (const receipt of this.ledger.completed) {
      if (receipt.targetKey !== key || !receipts.includes(receipt.batchId) || !receipt.inputClientId) continue;
      let item = result.find((item: IncomingComposerPendingInput): boolean => item.clientId === receipt.inputClientId);
      if (!item) {
        item = new IncomingComposerPendingInput(); item.clientId = receipt.inputClientId;
        item.sessionId = receipt.inputSessionId || target.sessionId; item.documentStorage = receipt.documentStorage || ''; result.push(item);
      }
      item.batchIds.push(receipt.batchId);
    }
    return result;
  }
  hasCommittedInput(target: IncomingShareDestination): boolean {
    if (!target.ownerKey || target.ownerKey !== this.owner || this.ledger.owner !== this.owner || !target.deviceId) return false;
    this.assertTarget(target); const key = incomingComposerTargetKey(target);
    return this.ledger.completed.some((receipt: IncomingComposerReceipt): boolean => receipt.targetKey === key && !!receipt.inputClientId);
  }
  /** Existing durable outbox is authority: known queued/accepted input owns attachments;
   * definitely absent restores the same draft, unknown does nothing and cannot auto-resend. */
  reconcileInput(target: IncomingShareDestination, clientId: string, outcome: string): Promise<void> {
    this.assertIdle(); this.assertTarget(target);
    if (outcome === 'unknown') return Promise.resolve();
    if (['owned', 'absent'].indexOf(outcome) < 0) throw new Error('INCOMING_COMPOSER_INPUT_OUTCOME_INVALID');
    const next = this.clone(), key = incomingComposerTargetKey(target);
    const matching = next.batches.filter((batch: IncomingComposerBatch): boolean => incomingComposerTargetKey(batch.target) === key && batch.inputClientId === clientId);
    for (const batch of matching) {
      if (batch.phase === 'command-pending') throw new Error('INCOMING_COMPOSER_COMMAND_UNRESOLVED');
      if (outcome === 'absent') { batch.phase = 'acknowledged'; batch.inputClientId = ''; batch.inputSessionId = ''; }
      else {
        const receipt = new IncomingComposerReceipt(); receipt.batchId = batch.batchId; receipt.targetKey = key;
        receipt.inputClientId = batch.inputClientId; receipt.inputSessionId = batch.inputSessionId || target.sessionId; receipt.documentStorage = batch.mergedDocument; next.completed.push(receipt);
        for (const file of batch.files) next.garbage.push(file.uri);
      }
    }
    if (outcome === 'owned') next.batches = next.batches.filter((batch: IncomingComposerBatch): boolean => !matching.includes(batch));
    next.completed = next.completed.slice(-256); this.commit(next); this.emit();
    return this.scheduleCleanup();
  }
  /** User explicitly discards this imported draft; ordinary page exit must not call this. */
  discard(target: IncomingShareDestination): Promise<void> {
    this.assertIdle(); this.assertTarget(target); const next = this.clone(), key = incomingComposerTargetKey(target);
    const matching = next.batches.filter((batch: IncomingComposerBatch): boolean => incomingComposerTargetKey(batch.target) === key);
    if (matching.some((batch: IncomingComposerBatch): boolean => (batch.phase === 'queued' || batch.phase === 'command-pending'))) throw new Error('INCOMING_COMPOSER_INPUT_UNRESOLVED');
    for (const batch of matching) {
      const receipt = new IncomingComposerReceipt(); receipt.batchId = batch.batchId; receipt.targetKey = key; next.completed.push(receipt);
      for (const file of batch.files) next.garbage.push(file.uri);
    }
    next.batches = next.batches.filter((batch: IncomingComposerBatch): boolean => !matching.includes(batch));
    next.completed = next.completed.slice(-256); this.commit(next); this.emit();
    return this.scheduleCleanup();
  }
  cleanupPending(): boolean { return this.cleanupFailed || this.ledger.garbage.length > 0; }
  retryCleanup(): Promise<void> { return this.scheduleCleanup(); }
  private scheduleCleanup(): Promise<void> {
    // The ledger transition already committed synchronously. An asynchronous garbage failure
    // cannot turn owned input back into an unsent draft or authorize discarding its real outbox.
    return this.serial((): Promise<void> => this.cleanup()).then((): void => { this.cleanupFailed = false; })
      .catch((): void => { this.cleanupFailed = true; });
  }
  private async cleanup(): Promise<void> {
    for (const uri of this.ledger.garbage.slice()) {
      await this.files.remove(uri);
      const next = this.clone(); next.garbage = next.garbage.filter((item: string): boolean => item !== uri); this.commit(next);
    }
  }
  dispose(): void { this.epoch++; this.owner = ''; this.listeners.clear(); }
}
