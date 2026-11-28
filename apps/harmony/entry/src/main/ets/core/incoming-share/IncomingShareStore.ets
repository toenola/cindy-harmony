import { readNum, readStr, recordOrEmpty } from '../tasks/TaskModels';

export class IncomingShareFile {
  uri: string = ''; name: string = ''; mime: string = ''; size: number = 0;
}
export class IncomingShareItem {
  kind: string = ''; text: string = ''; uri: string = ''; name: string = ''; mime: string = '';
  file: IncomingShareFile | null = null;
}
export class IncomingShareDestination {
  ownerKey: string = ''; deviceId: string = ''; sessionId: string = ''; // empty session = new task
}
export class IncomingShareBatch {
  id: string = ''; receipt: string = ''; fingerprint: string = ''; owner: string = ''; receivedAt: number = 0;
  items: IncomingShareItem[] = [];
}
export class IncomingShareLedger {
  version: number = 1;
  batches: IncomingShareBatch[] = [];
  consumed: string[] = [];
}
export interface IncomingShareStorage {
  read(): Promise<string>; write(json: string): Promise<void>;
}
export interface IncomingShareStaging {
  stage(uri: string, name: string, mime: string): Promise<IncomingShareFile>;
  remove(ownedUri: string): Promise<void>;
}
/** Must atomically/idempotently adopt batchId into the existing draft/attachment owner.
 * The port copies files into its own draft directory and durably records batchId before true.
 * It must validate destination.ownerKey and never send a message. */
export interface IncomingShareDraftPort {
  adopt(batchId: string, destination: IncomingShareDestination, text: string, files: IncomingShareFile[]): Promise<boolean>;
}
function cloneBatch(batch: IncomingShareBatch): IncomingShareBatch {
  return JSON.parse(JSON.stringify(batch)) as IncomingShareBatch;
}
export function incomingShareText(batch: IncomingShareBatch): string {
  return batch.items.filter((item: IncomingShareItem): boolean => item.kind === 'text' || item.kind === 'url')
    .map((item: IncomingShareItem): string => item.text).join('\n\n');
}
export function incomingShareFiles(batch: IncomingShareBatch): IncomingShareFile[] {
  const files: IncomingShareFile[] = [];
  batch.items.forEach((item: IncomingShareItem): void => { if (item.file) files.push(item.file); }); return files;
}
/** Serial durable inbox. Account/receipt identity is not derived from file names or model/device names. */
export class IncomingShareStore {
  private storage: IncomingShareStorage;
  private staging: IncomingShareStaging;
  private ledger: IncomingShareLedger = new IncomingShareLedger();
  private tail: Promise<void> = Promise.resolve();
  private owner: string = '';
  private epoch: number = 0;
  private restored: boolean = false;
  private listeners: Set<() => void> = new Set();
  constructor(storage: IncomingShareStorage, staging: IncomingShareStaging) { this.storage = storage; this.staging = staging; }
  onChanged(listener: () => void): () => void { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; }
  private emit(): void { this.listeners.forEach((listener: () => void): void => listener()); }
  private serial(work: () => Promise<void>): Promise<void> {
    const run = this.tail.then(work); this.tail = run.catch(() => {}); return run;
  }
  private async restore(): Promise<void> {
    if (this.restored) return;
    const json = await this.storage.read();
    if (json) {
      const raw = recordOrEmpty(JSON.parse(json) as Object);
      if (raw['version'] !== 1 || !Array.isArray(raw['batches'])) throw new Error('INCOMING_SHARE_INVALID_INBOX');
      const parsed = new IncomingShareLedger();
      for (const item of (raw['batches'] as Object[]).slice(0, 8)) {
        const data = recordOrEmpty(item), batch = new IncomingShareBatch();
        batch.id = readStr(data, 'id'); batch.fingerprint = readStr(data, 'fingerprint'); batch.receipt = readStr(data, 'receipt'); batch.owner = readStr(data, 'owner');
        batch.receivedAt = readNum(data, 'receivedAt', 0);
        if (!batch.id || !batch.receipt || !Array.isArray(data['items'])) continue;
        for (const record of (data['items'] as Object[]).slice(0, 20)) {
          const value = recordOrEmpty(record), entry = new IncomingShareItem();
          entry.kind = readStr(value, 'kind'); entry.text = readStr(value, 'text');
          entry.name = readStr(value, 'name'); entry.mime = readStr(value, 'mime');
          const file = recordOrEmpty(value['file']);
          if (readStr(file, 'uri')) {
            const f = new IncomingShareFile(); f.uri = readStr(file, 'uri'); f.name = readStr(file, 'name');
            f.mime = readStr(file, 'mime'); f.size = readNum(file, 'size', 0); entry.file = f;
          }
          // External granted URIs are never persisted/reused after cold start.
          if ((entry.kind === 'text' || entry.kind === 'url') ? !!entry.text : entry.file !== null) batch.items.push(entry);
        }
        if (batch.items.length) parsed.batches.push(batch);
      }
      const consumed = raw['consumed'];
      if (Array.isArray(consumed)) parsed.consumed = (consumed as Object[]).filter((item: Object): boolean => typeof item === 'string').slice(-128) as string[];
      this.ledger = parsed;
    }
    this.restored = true;
  }
  private persist(): Promise<void> { return this.storage.write(JSON.stringify(this.ledger)); }
  private async deleteFiles(batch: IncomingShareBatch): Promise<void> {
    for (const file of incomingShareFiles(batch)) await this.staging.remove(file.uri);
  }
  /** Pre-login shares may be claimed by the first login. Shares owned by another account are removed. */
  setOwner(owner: string): Promise<void> {
    const previous = this.owner; this.owner = owner; if (previous !== owner) this.epoch++;
    return this.serial(async (): Promise<void> => {
      await this.restore();
      const discarded = this.ledger.batches.filter((batch: IncomingShareBatch): boolean =>
        !!batch.owner && batch.owner !== this.owner);
      for (const batch of discarded) await this.deleteFiles(batch);
      this.ledger.batches = this.ledger.batches.filter((batch: IncomingShareBatch): boolean => !discarded.includes(batch));
      if (this.owner) this.ledger.batches.forEach((batch: IncomingShareBatch): void => { if (!batch.owner) batch.owner = this.owner; });
      // Logout/account switch invalidates old native receipts too, without exposing their content.
      if (previous && previous !== this.owner) this.ledger.consumed = [];
      await this.persist(); this.emit();
    });
  }
  pending(): IncomingShareBatch | null {
    const batch = this.ledger.batches.find((batch: IncomingShareBatch): boolean => !!this.owner && batch.owner === this.owner);
    return batch ? cloneBatch(batch) : null;
  }
  receive(id: string, receipt: string, items: IncomingShareItem[], now: number = Date.now(), fingerprint: string = ''): Promise<void> {
    const epoch = this.epoch, owner = this.owner;
    return this.serial(async (): Promise<void> => {
      await this.restore();
      if (epoch !== this.epoch && !(owner === '' && this.owner !== '' && this.epoch === epoch + 1)) throw new Error('INCOMING_SHARE_STALE');
      if (!id || !receipt || receipt.length > 1000000 || !items.length || items.length > 20) throw new Error('INCOMING_SHARE_INVALID_BATCH');
      if (this.ledger.consumed.includes(receipt) || this.ledger.batches.some((batch: IncomingShareBatch): boolean => batch.receipt === receipt || (!!fingerprint && batch.fingerprint === fingerprint))) return;
      if (this.ledger.batches.length >= 8) throw new Error('INCOMING_SHARE_INBOX_FULL');
      const batch = new IncomingShareBatch(); batch.id = id; batch.receipt = receipt; batch.owner = owner || this.owner; batch.receivedAt = now; batch.fingerprint = fingerprint;
      try {
        for (const raw of items) {
          const item = new IncomingShareItem(); item.kind = raw.kind; item.text = raw.text; item.name = raw.name; item.mime = raw.mime;
          if (raw.kind === 'text' || raw.kind === 'url') {
            if (!raw.text || raw.text.length > 200000) throw new Error('INCOMING_SHARE_TEXT_TOO_LARGE');
          } else {
            item.file = await this.staging.stage(raw.uri, raw.name, raw.mime);
          }
          batch.items.push(item);
          if (epoch !== this.epoch && !(owner === '' && this.owner !== '' && this.epoch === epoch + 1)) throw new Error('INCOMING_SHARE_STALE');
        }
        this.ledger.batches.push(batch);
        try { await this.persist(); } catch (error) { this.ledger.batches.pop(); if (error instanceof Error) throw error; throw new Error('INCOMING_SHARE_FAILED'); }
        this.emit();
      } catch (error) { await this.deleteFiles(batch); if (error instanceof Error) throw error; throw new Error('INCOMING_SHARE_FAILED'); }
    });
  }
  /** Preview selection is separate from draft adoption. Caller supplies the user-selected target. */
  adopt(batchId: string, destination: IncomingShareDestination, draft: IncomingShareDraftPort): Promise<void> {
    const epoch = this.epoch, owner = this.owner;
    return this.serial(async (): Promise<void> => {
      await this.restore();
      const batch = this.ledger.batches.find((item: IncomingShareBatch): boolean => item.id === batchId);
      if (!batch || !owner || batch.owner !== owner || epoch !== this.epoch || !destination.deviceId) throw new Error('INCOMING_SHARE_STALE');
      // A failed/unknown adoption retains the inbox. The draft port deduplicates by batchId on retry.
      destination.ownerKey = owner;
      if (!await draft.adopt(batch.id, destination, incomingShareText(batch), incomingShareFiles(batch))) throw new Error('INCOMING_SHARE_NOT_ADOPTED');
      // Draft owns independent copies. Keep the original inbox recoverable if its tombstone cannot be saved.
      const previousBatches = this.ledger.batches, previousConsumed = this.ledger.consumed;
      this.ledger.batches = this.ledger.batches.filter((item: IncomingShareBatch): boolean => item.id !== batch.id);
      this.ledger.consumed = this.ledger.consumed.concat([batch.receipt]).slice(-128);
      try { await this.persist(); } catch (error) { this.ledger.batches = previousBatches; this.ledger.consumed = previousConsumed; if (error instanceof Error) throw error; throw new Error('INCOMING_SHARE_FAILED'); }
      await this.deleteFiles(batch); this.emit();
    });
  }
  /** The shared/group module validates the official invitation and owns its confirmation UI.
   * Only a sole text/link is eligible; mixed files never disappear into an invitation route. */
  openInvitation(batchId: string, open: (text: string, owner: string) => Promise<boolean>): Promise<void> {
    const epoch = this.epoch, owner = this.owner;
    return this.serial(async (): Promise<void> => {
      await this.restore();
      const batch = this.ledger.batches.find((item: IncomingShareBatch): boolean => item.id === batchId);
      if (!batch || !owner || batch.owner !== owner || epoch !== this.epoch || batch.items.length !== 1
        || incomingShareFiles(batch).length > 0) throw new Error('INCOMING_SHARE_INVITE_UNAVAILABLE');
      if (!await open(incomingShareText(batch), owner)) throw new Error('INCOMING_SHARE_INVITE_UNSUPPORTED');
      if (epoch !== this.epoch) throw new Error('INCOMING_SHARE_STALE');
      const previousBatches = this.ledger.batches, previousConsumed = this.ledger.consumed;
      this.ledger.batches = this.ledger.batches.filter((item: IncomingShareBatch): boolean => item.id !== batchId);
      this.ledger.consumed = this.ledger.consumed.concat([batch.receipt]).slice(-128);
      try { await this.persist(); } catch (error) { this.ledger.batches = previousBatches; this.ledger.consumed = previousConsumed; if (error instanceof Error) throw error; throw new Error('INCOMING_SHARE_FAILED'); }
      this.emit();
    });
  }
  cancel(batchId: string): Promise<void> {
    return this.serial(async (): Promise<void> => {
      await this.restore();
      const batch = this.ledger.batches.find((item: IncomingShareBatch): boolean => item.id === batchId && item.owner === this.owner);
      if (!batch) return;
      await this.deleteFiles(batch);
      this.ledger.batches = this.ledger.batches.filter((item: IncomingShareBatch): boolean => item.id !== batch.id);
      this.ledger.consumed = this.ledger.consumed.concat([batch.receipt]).slice(-128);
      await this.persist(); this.emit();
    });
  }
  /** Called on ingress/foreground; only still-unclaimed inbox files expire, never adopted drafts. */
  expire(now: number = Date.now()): Promise<void> {
    return this.serial(async (): Promise<void> => {
      await this.restore();
      const expired = this.ledger.batches.filter((batch: IncomingShareBatch): boolean => now - batch.receivedAt > 24 * 60 * 60 * 1000);
      for (const batch of expired) await this.deleteFiles(batch);
      this.ledger.batches = this.ledger.batches.filter((batch: IncomingShareBatch): boolean => !expired.includes(batch));
      await this.persist(); this.emit();
    });
  }
  dispose(): void { this.epoch++; this.owner = ''; this.listeners.clear(); }
}
