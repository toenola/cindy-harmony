import { ChatServerApi } from './ChatServerApi';
import { SecureStore } from '../storage/SecureStore';
import { ChatSnapshot, ChatMessage, ChatRoomPage, ChatHttpError, chatId, chatCursor, compareChatSequence, mergeChatMessages, validateChatMessage, ChatDelta, ChatDeltaBatch } from './ChatModels';

export interface ChatCachedPage { thread: string; before: string; ids: string[] }
export interface ChatHistoryState {
  version: number; generation: string; snapshot: ChatSnapshot; cursor: string;
  messages: ChatMessage[]; pages: ChatCachedPage[]; metadataDirty: boolean;
}
export interface ChatHistoryStorage {
  read(owner: string, room: string): Promise<ChatHistoryState | null>;
  write(owner: string, room: string, state: ChatHistoryState | null): Promise<void>;
}
/** Private derived history only. Never writes a partially updated cursor/page pair. */
export class ChatHistoryPreferences implements ChatHistoryStorage {
  private store: SecureStore;
  constructor(store: SecureStore) { this.store = store; }
  async read(owner: string, room: string): Promise<ChatHistoryState | null> {
    const text = await this.store.get(this.key(owner, room), ''); if (!text) return null;
    const value = JSON.parse(text) as ChatHistoryState;
    if (value.version !== 1 || value.snapshot?.room?.id !== room || !Array.isArray(value.pages) || !Array.isArray(value.messages)) return null;
    chatCursor(value.cursor); value.messages.forEach((m: ChatMessage): void => { validateChatMessage(m); }); return value;
  }
  private writes: Promise<void> = Promise.resolve();
  write(owner: string, room: string, value: ChatHistoryState | null): Promise<void> {
    const text = value ? JSON.stringify(value) : '';
    const task = this.writes.catch((): void => {}).then(async (): Promise<void> => {
      if (!value) { await this.store.remove(this.key(owner, room)); return; }
      if (text.length > 4 * 1024 * 1024) throw new Error('CHAT_HISTORY_CACHE_FULL');
      const indexKey=`chat.history-index.v1:${encodeURIComponent(owner)}`;
      const ids=JSON.parse(await this.store.get(indexKey,'[]')) as string[];
      if (!Array.isArray(ids) || ids.some((id: string): boolean => typeof id!=='string')) throw new Error('INVALID_CHAT_CACHE');
      await this.store.set(this.key(owner,room),text);
      if (!ids.includes(room)) {
        ids.push(room); while(ids.length>8) { const old=ids.shift(); if(old) await this.store.remove(this.key(owner,old)); }
        await this.store.set(indexKey,JSON.stringify(ids));
      }
    }); this.writes=task; return task;
  }
  private key(owner: string, room: string): string { return `chat.history.v1:${encodeURIComponent(owner)}:${chatId(room)}`; }
}
/** Port of maker-shared/chatHistory's durable cursor, bounded catch-up and reset semantics. */
export class ChatHistory {
  private owner: string;
  private api: ChatServerApi;
  private disk: ChatHistoryStorage;
  private current: () => boolean;
  private newId: () => string;
  private states: Map<string, ChatHistoryState> = new Map();
  private chains: Map<string, Promise<void>> = new Map();
  private closed: boolean = false;
  constructor(owner: string, api: ChatServerApi, disk: ChatHistoryStorage, current: () => boolean, newId: () => string) {
    this.owner = owner; this.api = api; this.disk = disk; this.current = current; this.newId = newId;
  }
  private check(): void { if (this.closed || !this.current()) throw new Error('OWNER_CHANGED'); }
  private async restore(room: string): Promise<ChatHistoryState | null> {
    const state = this.states.get(room) ?? await this.disk.read(this.owner, room); this.check(); return state ?? null;
  }
  private async save(room: string, state: ChatHistoryState): Promise<void> {
    this.check();
    // Retain exactly the loaded pages and the 100-message metadata window; evict derived oldest pages.
    if (state.pages.length > 40) state.pages = state.pages.slice(-40);
    const ids = new Set(state.snapshot.messages.map((m: ChatMessage): string => m.id));
    state.pages.forEach((p: ChatCachedPage): void => { p.ids.forEach((id: string): void => { ids.add(id); }); });
    state.messages = state.messages.filter((m: ChatMessage): boolean => ids.has(m.id));
    state.snapshot.cursor = state.cursor;
    await this.disk.write(this.owner, room, state); this.check(); this.states.delete(room); this.states.set(room, state);
    let held = 0; this.states.forEach((s: ChatHistoryState): void => { held += s.messages.length; });
    for (const entry of this.states.entries()) {
      if (held <= 4000) break;
      if (entry[0] !== room && !this.chains.has(entry[0])) { held -= entry[1].messages.length; this.states.delete(entry[0]); }
    }
  }
  private async bootstrap(room: string): Promise<ChatHistoryState> {
    const snapshot = await this.api.snapshot(room); this.check();
    const state: ChatHistoryState = { version: 1, generation: this.newId(), snapshot, cursor: snapshot.cursor,
      messages: snapshot.messages.slice(), pages: [], metadataDirty: false };
    await this.save(room, state); return state;
  }
  private async ensure(room: string): Promise<ChatHistoryState> {
    let state = await this.restore(room); if (!state) return this.bootstrap(room);
    // Stage a clone: a failed durable commit must not publish a cursor never written to disk.
    state = JSON.parse(JSON.stringify(state)) as ChatHistoryState;
    try {
      for (let n = 0; n < 20; n++) {
        const batch = await this.api.changes(room, state.cursor); this.check();
        if (batch.hasMore && batch.cursor === state.cursor) throw new Error('CHAT_SYNC_STALLED');
        if (!await this.apply(room, state, batch)) return this.bootstrap(room);
        if (!batch.hasMore) {
          // Actor read preferences can change outside the room stream; verify them on foreground sync.
          const snapshot = await this.api.snapshot(room); this.check();
          state.messages = mergeChatMessages(state.messages, snapshot.messages);
          snapshot.cursor = state.cursor; state.snapshot = snapshot; state.metadataDirty = false;
          await this.save(room, state); return state;
        }
      }
      return this.bootstrap(room);
    } catch (e) {
      if (e instanceof ChatHttpError && ['RESET_REQUIRED', 'CURSOR_AHEAD'].includes(e.code)) return this.bootstrap(room);
      if (e instanceof ChatHttpError && (e.status === 403 || e.status === 404)) await this.clear(room);
      throw e instanceof Error ? e : new Error('CHAT_SYNC_FAILED');
    }
  }
  /** Metadata/membership changes require an authoritative snapshot, never infer grants from a card. */
  private async apply(room: string, state: ChatHistoryState, batch: ChatDeltaBatch): Promise<boolean> {
    chatCursor(batch.cursor); if (!Array.isArray(batch.changes)) throw new Error('INVALID_CHAT_DELTA');
    if (compareChatSequence(batch.cursor, state.cursor) <= 0) return true;
    if (batch.changes.some((c: ChatDelta): boolean => c.type === 'membership.changed')) return false;
    for (let i = 0; i < batch.changes.length; i++) {
      const change = batch.changes[i];
      if (/^(message\.|reaction\.|pin\.)/.test(change.type)) {
        const delta = change.data?.message; if (!delta) return false;
        let message: ChatMessage;
        if (change.type === 'reaction.changed') message = await this.api.message(room, delta.id);
        else {
          const previous = state.messages.find((m: ChatMessage): boolean => m.id === delta.id);
          if (previous) {
            const merged = JSON.parse(JSON.stringify(previous)) as ChatMessage;
            if ((delta.revision ?? 0) < (previous.revision ?? 0)) continue;
            merged.revision = delta.revision ?? previous.revision; merged.seq = delta.seq ?? previous.seq;
            if (delta.deleted !== undefined) merged.deleted = delta.deleted;
            if (delta.content !== undefined) merged.content = delta.content;
            if (delta.reactions !== undefined) merged.reactions = delta.reactions;
            if (delta.replyCount !== undefined) merged.replyCount = delta.replyCount;
            message = validateChatMessage(merged);
          } else {
            try { message = validateChatMessage(delta); }
            catch (_) { message = await this.api.message(room, delta.id); }
          }
        }
        this.check(); state.messages = mergeChatMessages(state.messages, [message]);
        state.snapshot.messages = mergeChatMessages(state.snapshot.messages, [message]).slice(-100);
        if (message.threadRootId && (change.type === 'message.created' || change.type === 'message.deleted')) {
          const root = state.messages.find((m: ChatMessage): boolean => m.id === message.threadRootId);
          if (root) { const fresh = await this.api.message(room, root.id); this.check(); state.messages = mergeChatMessages(state.messages, [fresh]); }
        }
        if (change.type === 'message.created') state.pages.slice().forEach((p: ChatCachedPage): void => {
          if (p.thread !== (message.threadRootId ?? '')) return;
          if (p.before && compareChatSequence(message.seq, p.before) >= 0) return;
          if (!p.ids.includes(message.id)) {
            if (p.before) return;
            const previous = p.ids.slice();
            const latest = state.messages.filter((m: ChatMessage): boolean => previous.includes(m.id) || m.id === message.id)
              .sort((a: ChatMessage, b: ChatMessage): number => compareChatSequence(b.seq, a.seq));
            if (previous.length && latest.length > 100) {
              const top = state.messages.filter((m: ChatMessage): boolean => previous.includes(m.id))
                .sort((a: ChatMessage, b: ChatMessage): number => compareChatSequence(b.seq, a.seq))[0];
              state.pages.push({ thread: p.thread, before: incrementSequence(top.seq), ids: previous });
            }
            p.ids = latest.slice(0, 100).map((m: ChatMessage): string => m.id);
          }
        });
      } else if (!['execution.changed', 'plan.changed', 'work.available'].includes(change.type)) state.metadataDirty = true;
    }
    state.cursor = batch.cursor; return true;
  }
  async page(room: string, thread: string, before: string = '', sync: boolean = false): Promise<ChatRoomPage> {
    let result: ChatRoomPage | null = null;
    await this.serial(room, async (): Promise<void> => {
      let state = sync ? await this.ensure(room) : await this.restore(room) ?? await this.bootstrap(room);
      const cached = state.pages.find((p: ChatCachedPage): boolean => p.thread === thread && p.before === before);
      let ids = cached?.ids;
      if (!ids) {
        const rows = await this.api.messages(room, thread, before); this.check();
        state = JSON.parse(JSON.stringify(state)) as ChatHistoryState;
        state.messages = mergeChatMessages(state.messages, rows); ids = rows.map((m: ChatMessage): string => m.id);
        state.pages.push({ thread, before, ids }); await this.save(room, state);
      }
      const messages = state.messages.filter((m: ChatMessage): boolean => ids?.includes(m.id) === true);
      const sorted = mergeChatMessages([], messages);
      result = { snapshot: state.snapshot, messages: sorted, threadRootId: thread,
        before: ids.length >= 100 && sorted.length ? sorted[0].seq : null, verified: true, historyGeneration: state.generation };
    });
    if (!result) throw new Error('CHAT_NOT_READY'); return result as ChatRoomPage;
  }
  async receive(room: string, batch: ChatDeltaBatch, subscribedAfter: string): Promise<void> {
    await this.serial(room, async (): Promise<void> => {
      let state = await this.restore(room);
      if (!state || compareChatSequence(subscribedAfter, state.cursor) > 0) { await this.ensure(room); return; }
      state = JSON.parse(JSON.stringify(state)) as ChatHistoryState;
      if (!await this.apply(room, state, batch)) { await this.bootstrap(room); return; }
      if (state.metadataDirty) {
        const snapshot = await this.api.snapshot(room); this.check();
        state.messages = mergeChatMessages(state.messages, snapshot.messages); state.snapshot = snapshot; state.metadataDirty = false;
      }
      await this.save(room, state);
    });
  }
  /** Caller may display SAME-OWNER cached history as unverified only after a transport error. */
  async offline(room: string, thread: string): Promise<ChatRoomPage | null> {
    const state = await this.restore(room); if (!state) return null;
    const pages = state.pages.filter((p: ChatCachedPage): boolean => p.thread === thread);
    const ids = new Set<string>(); pages.forEach((p: ChatCachedPage): void => { p.ids.forEach((id: string): void => { ids.add(id); }); });
    return { snapshot: state.snapshot, messages: mergeChatMessages([], state.messages.filter((m: ChatMessage): boolean => ids.has(m.id))),
      threadRootId: thread, before: null, verified: false, historyGeneration: state.generation };
  }
  messages(room: string): ChatMessage[] { return this.states.get(room)?.messages.slice() ?? []; }
  cursor(room: string): string { return this.states.get(room)?.cursor ?? '0'; }
  async clear(room: string): Promise<void> { this.states.delete(room); await this.disk.write(this.owner, room, null); this.check(); }
  async shutdown(): Promise<void> { this.closed = true; await Promise.all(Array.from(this.chains.values()).map((p: Promise<void>): Promise<void> => p.catch((): void => {}))); this.states.clear(); }
  private serial(room: string, run: () => Promise<void>): Promise<void> {
    const task = (this.chains.get(room) ?? Promise.resolve()).catch((): void => {}).then(async (): Promise<void> => { this.check(); await run(); });
    this.chains.set(room, task);
    task.finally((): void => { if (this.chains.get(room) === task) this.chains.delete(room); }).catch((): void => {}); return task;
  }
}

function incrementSequence(value: string): string {
  const digits = chatCursor(value).split(''); let carry = 1;
  for (let i = digits.length - 1; i >= 0 && carry; i--) { const n = Number(digits[i]) + carry; digits[i] = String(n % 10); carry = n > 9 ? 1 : 0; }
  return carry ? `1${digits.join('')}` : digits.join('');
}
