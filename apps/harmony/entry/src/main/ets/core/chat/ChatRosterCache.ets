import { SecureStore } from '../storage/SecureStore';
import { ChatActor, ChatMe, ChatRoom } from './ChatModels';
export interface ChatCachedRoster { rooms: ChatRoom[]; actors: ChatActor[]; me: ChatMe }
export interface ChatRosterStorage { read(owner: string): Promise<ChatCachedRoster | null>; write(owner: string, value: ChatCachedRoster): Promise<void> }
export class ChatRosterPreferences implements ChatRosterStorage {
  private store: SecureStore;
  constructor(store: SecureStore) { this.store = store; }
  async read(owner: string): Promise<ChatCachedRoster | null> {
    const text = await this.store.get(`chat.roster.v1:${encodeURIComponent(owner)}`, ''); if (!text) return null;
    const value = JSON.parse(text) as ChatCachedRoster;
    return Array.isArray(value.rooms) && Array.isArray(value.actors) && value.me?.actor?.kind === 'human' ? value : null;
  }
  async write(owner: string, value: ChatCachedRoster): Promise<void> {
    const text = JSON.stringify(value); if (text.length > 1024 * 1024) throw new Error('CHAT_HISTORY_CACHE_FULL');
    await this.store.set(`chat.roster.v1:${encodeURIComponent(owner)}`, text);
  }
}
