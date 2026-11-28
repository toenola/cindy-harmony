import { ChatPending, ChatOutboxStorage } from './ChatModels';
import { SecureStore } from '../storage/SecureStore';

/** Existing initialized app-private store; cleared by AuthStore logout with other account data. */
export class ChatOutbox implements ChatOutboxStorage {
  private store: SecureStore;
  constructor(store: SecureStore) { this.store = store;}
  async read(owner: string): Promise<ChatPending[]> {
    const raw = await this.store.get(this.key(owner), '[]');
    const rows = JSON.parse(raw) as ChatPending[];
    if (!Array.isArray(rows) || rows.length > 100) throw new Error('INVALID_CHAT_OUTBOX');
    return rows.filter((r: ChatPending): boolean => r.owner === owner);
  }
  async write(owner: string, rows: ChatPending[]): Promise<void> {
    if (rows.length > 100 || rows.some((r: ChatPending): boolean => r.owner !== owner)) throw new Error('INVALID_CHAT_OUTBOX');
    const raw = JSON.stringify(rows);
    if (raw.length > 1024 * 1024) throw new Error('CHAT_OUTBOX_FULL');
    if (rows.length === 0) await this.store.remove(this.key(owner)); else await this.store.set(this.key(owner), raw);
  }
  private key(owner: string): string {
    if (!owner) throw new Error('UNAUTHENTICATED'); return `chat.outbox.v1:${encodeURIComponent(owner)}`;
  }
}
