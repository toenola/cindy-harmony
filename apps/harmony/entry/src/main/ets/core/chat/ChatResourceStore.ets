import { RemoteSerializedAttachment } from '../attachments/AttachmentModels';
import { parseAttachmentOssRef } from '../attachments/AttachmentOssRef';
import { ChatResourceAdapter, ChatResource, ChatResourceBlock } from './ChatResourceAdapter';
import { SecureStore } from '../storage/SecureStore';
import { chatError } from './ChatModels';
import { ChatHostAttachment, chatHostAttachments } from './ChatHostMedia';

export interface ChatHostMessage {
  id: string; sequence: number; serverSequence?: string; authorName: string; authorBotId: string;
  authorKind: string; content: string; deleted: boolean; createdAt: number; threadRootId: string;
  attachments: ChatHostAttachment[];
}
export interface ChatHostPending {
  owner: string; deviceId: string; groupId: string; clientId: string;
  input: Record<string, Object>; state: string; error: string;
}
export interface ChatHostPersistence {
  read(owner: string, device: string, group: string): Promise<ChatHostPending[]>;
  write(owner: string, device: string, group: string, rows: ChatHostPending[]): Promise<void>;
}
export class ChatHostOutbox implements ChatHostPersistence {
  private store: SecureStore;
  constructor(store: SecureStore) { this.store = store;}
  async read(owner: string, device: string, group: string): Promise<ChatHostPending[]> {
    const rows = JSON.parse(await this.store.get(this.key(owner, device, group), '[]')) as ChatHostPending[];
    if (!Array.isArray(rows) || rows.length > 100) throw new Error('INVALID_CHAT_OUTBOX');
    return rows.filter((r: ChatHostPending): boolean => r.owner === owner && r.deviceId === device && r.groupId === group);
  }
  async write(owner: string, device: string, group: string, rows: ChatHostPending[]): Promise<void> {
    const value = JSON.stringify(rows);
    if (rows.length > 100 || value.length > 1024 * 1024) throw new Error('CHAT_OUTBOX_FULL');
    if (!rows.length) await this.store.remove(this.key(owner, device, group)); else await this.store.set(this.key(owner, device, group), value);
  }
  private key(owner: string, device: string, group: string): string { return `chat.host-outbox.v1:${encodeURIComponent(JSON.stringify([owner, device, group]))}`; }
}
/** Resource identity remains (owner,device,group). Its sequence is NOT a cloud-room cursor. */
export function chatHostMessages(resource: ChatResource): ChatHostMessage[] {
  const data = resource.blocks.find((b: ChatResourceBlock): boolean => b.primitive === 'bot-group-chat')?.data;
  const rows = data?.['messages']; if (!Array.isArray(rows)) throw new Error('INVALID_GROUP_RESOURCE');
  const result: ChatHostMessage[] = [];
  (rows as Object[]).forEach((raw: Object): void => {
    if (!raw || typeof raw !== 'object') return;
    const r = raw as Record<string, Object>;
    if (typeof r['id'] !== 'string' || typeof r['content'] !== 'string' || typeof r['sequence'] !== 'number'
      || !Number.isFinite(r['sequence'] as number) || typeof r['createdAt'] !== 'number'
      || !['message', 'round-end', 'notice', 'plan', 'plan-end'].includes(r['kind'] as string)
      || !['user', 'bot', 'system'].includes(r['authorKind'] as string)) return;
    result.push({ id: (r['id'] as string).slice(0, 256), sequence: r['sequence'] as number,
      serverSequence: typeof r['serverSequence'] === 'string' ? r['serverSequence'] as string : undefined,
      authorName: typeof r['authorName'] === 'string' ? (r['authorName'] as string).slice(0, 512) : '',
      authorBotId: typeof r['authorBotId'] === 'string' ? r['authorBotId'] as string : '', authorKind: r['authorKind'] as string,
      content: (r['content'] as string).slice(0, 200000), deleted: r['deleted'] === true, createdAt: r['createdAt'] as number,
      threadRootId: typeof r['threadRootId'] === 'string' ? r['threadRootId'] as string : '',
      attachments: r['deleted'] === true ? [] : chatHostAttachments(r['attachments']) });
  }); return result;
}
export class ChatResourceStore {
  resource: ChatResource | null = null;
  messages: ChatHostMessage[] = [];
  pending: ChatHostPending[] = [];
  error: string = '';
  loading: boolean = false;
  private lastRead: string = '';
  private shutdownTask:Promise<void>|null=null;
  private disposed: boolean = false;
  private listeners: Array<() => void> = [];
  private loadingTask: Promise<void> | null = null;
  private sending: Set<string> = new Set();
  private enqueuing: Set<string> = new Set();
  private writeTail: Promise<void> = Promise.resolve();
  readonly owner: string;
  readonly groupId: string;
  readonly adapter: ChatResourceAdapter;
  private disk: ChatHostPersistence;
  constructor(owner: string, groupId: string, adapter: ChatResourceAdapter, disk: ChatHostPersistence) { this.owner = owner; this.groupId = groupId; this.adapter = adapter; this.disk = disk;}
  onChanged(fn: () => void): () => void {
    this.listeners.push(fn); return (): void => { this.listeners = this.listeners.filter((l: () => void): boolean => l !== fn); };
  }
  isActive(): boolean { return !this.disposed; }
  private notify(): void { if (!this.disposed) this.listeners.forEach((fn: () => void): void => fn()); }
  async restore(): Promise<void> {
    const rows = await this.disk.read(this.owner, this.adapter.deviceId, this.groupId); if (this.disposed) return;
    this.pending = rows.map((r: ChatHostPending): ChatHostPending => { if (r.state === 'sending') r.state = 'unknown'; return r; }); this.notify();
  }
  refresh(): Promise<void> {
    if (this.loadingTask) return this.loadingTask;
    const task = this.load().finally((): void => { if (this.loadingTask === task) this.loadingTask = null; });
    this.loadingTask = task; return task;
  }
  private async load(): Promise<void> {
    if (this.disposed) return;
    this.loading = true; this.notify();
    try {
      const resource = await this.adapter.get(this.groupId); if (this.disposed) return;
      const messages = chatHostMessages(resource); this.resource = resource; this.messages = messages; this.error = '';
    } catch (e) { if (!this.disposed) { this.error = chatError(e); this.resource = null; this.messages = []; } }
    finally { if (!this.disposed) { this.loading = false; this.notify(); } }
  }
  /** Exact original Mobile resource send body, persisted with its clientId before
   * invoking. onEnqueued transfers only that snapshot, independently of RPC result. */
  async send(text: string, botIds: string[], clientId: string, attachments: RemoteSerializedAttachment[] = [], onEnqueued: (() => void) | null = null): Promise<void> {
    if (!this.resource || !clientId || (!text.trim() && !attachments.length) || this.pending.length >= 100 || this.disposed) throw new Error('CHAT_NOT_READY');
    if (this.pending.some((p: ChatHostPending): boolean => p.clientId === clientId)) throw new Error('CHAT_OPERATION_EXISTS');
    if (attachments.length) {
      const data = this.resource.blocks.find((b: ChatResourceBlock): boolean => b.primitive === 'bot-group-chat')?.data;
      if (data?.['supportsAttachments'] !== true) throw new Error('UNSUPPORTED_OPERATION');
      if (attachments.length > 20 || attachments.some((a: RemoteSerializedAttachment): boolean => !parseAttachmentOssRef(a.path))) throw new Error('INVALID_ATTACHMENT');
    }
    const mentions: Record<string, Object> = {}; mentions['all'] = false; mentions['botIds'] = botIds.slice();
    const input: Record<string, Object> = {}; input['text'] = text; input['clientId'] = clientId; input['mentions'] = mentions; if (attachments.length) input['attachments'] = attachments;
    const row: ChatHostPending = { owner: this.owner, deviceId: this.adapter.deviceId, groupId: this.groupId, clientId,
      input: JSON.parse(JSON.stringify(input)) as Record<string, Object>, state: 'queued', error: '' };
    this.enqueuing.add(clientId); this.pending.push(row);
    try { await this.persist(); }
    catch (e) { this.pending = this.pending.filter((p: ChatHostPending): boolean => p !== row); this.notify(); throw e instanceof Error ? e : new Error(chatError(e)); }
    finally { this.enqueuing.delete(clientId); }
    if (!this.disposed) { onEnqueued?.(); await this.deliver(row); }
  }
  async retry(clientId: string): Promise<void> {
    const row = this.pending.find((p: ChatHostPending): boolean => p.clientId === clientId);
    if (!row || this.disposed) throw new Error('OUTBOX_NOT_FOUND');
    if (this.enqueuing.has(clientId)) throw new Error('CHAT_SEND_IN_PROGRESS');
    await this.persist(); await this.deliver(row);
  }
  private async deliver(row: ChatHostPending): Promise<void> {
    if (this.sending.has(row.clientId) || this.disposed || !this.resource) return;
    let accepted = false;
    this.sending.add(row.clientId); row.state = 'sending'; this.notify();
    try {
      await this.adapter.act(this.resource, 'send', row.input); if (this.disposed) return;
      accepted = true;
      this.pending = this.pending.filter((p: ChatHostPending): boolean => p !== row); await this.persist(); await this.refresh();
    } catch (e) {
      if (accepted && !this.disposed) { this.error = 'OUTBOX_NOT_SAVED'; throw e instanceof Error ? e : new Error(chatError(e)); }
      if (!this.disposed) { row.state = 'unknown'; row.error = chatError(e); await this.persist(); }
    } finally { this.sending.delete(row.clientId); this.notify(); }
  }
  async perform(action:string,input:Record<string,Object>):Promise<void>{
    const resource=this.resource;if(!resource||this.disposed)throw new Error('CHAT_NOT_READY');
    await this.adapter.act(resource,action,input);if(!this.disposed)await this.refresh();
  }
  async markRead(visible: string[], atEnd: boolean, foreground: boolean): Promise<void> {
    const resource = this.resource; if (!resource || !foreground || !atEnd || this.disposed) return;
    const data = resource.blocks.find((b: ChatResourceBlock): boolean => b.primitive === 'bot-group-chat')?.data;
    const shown = this.messages.filter((m: ChatHostMessage): boolean => !m.threadRootId && visible.includes(m.id));
    const last = shown.sort((a: ChatHostMessage, b: ChatHostMessage): number => b.sequence - a.sequence)[0]; if (!last) return;
    if (this.lastRead===last.id) return; this.lastRead=last.id;
    const input: Record<string, Object> = {};
    try { if (data?.['supportsReadReceipts'] === true) { input['messageId'] = last.id; await this.adapter.act(resource, 'read', input); }
    else if (data?.['supportsLocalReadSync'] === true) { input['at'] = Math.max(...shown.map((m: ChatHostMessage): number => m.createdAt)); await this.adapter.act(resource, 'read', input); } } catch (e) { this.lastRead=''; throw e instanceof Error ? e : new Error('CHAT_READ_FAILED'); }
  }
  shutdown(): Promise<void> {
    if(this.shutdownTask)return this.shutdownTask;
    const task=Promise.resolve().then(async():Promise<void>=>{await this.writeTail.catch(():void=>{});});this.shutdownTask=task;
    this.adapter.dispose();this.resource=null;this.messages=[];this.pending=[];this.notify();this.disposed=true;this.listeners=[];return task;
  }
  private persist(): Promise<void> {
    const rows = JSON.parse(JSON.stringify(this.pending)) as ChatHostPending[];
    const task = this.writeTail.catch((): void => {}).then((): Promise<void> => this.disk.write(this.owner, this.adapter.deviceId, this.groupId, rows));
    this.writeTail = task; return task;
  }
}
