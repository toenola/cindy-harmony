/** Chat Server wire subset, pinned to upstream 91179cedad. Never substitute a device identity. */
export interface ChatActor {
  id: string; kind: string; externalId: string; name: string; avatar?: string | null;
  homeDeviceId?: string | null; disabled?: boolean;
}
export interface ChatMember {
  id: string; kind: string; name: string; state: string; ownerActorId: string;
  role: string; assistant?: boolean; avatar?: string | null; nickname?: string | null; guestAccess?: string; accessRevision?: number;
}
export interface ChatRoom {
  id: string; name: string; kind: string; head?: string; archived: boolean; revision: number;
  created_at: string; updated_at: string; dissolved_at?: string | null;
  allow_member_mention_all?: boolean; allow_member_invites?: boolean;
}
export interface ChatBlock {
  type: string; text?: string; fallback?: string; mediaId?: string; caption?: string;
  namespace?: string; schemaRevision?: number; data?: Record<string, Object | null>;
}
export interface ChatAuthor { kind: string; name: string }
export interface ChatReaction { emoji: string; count: number; me: boolean }
export interface ChatMessage {
  id: string; seq: string; authorId: string; author: ChatAuthor; createdAt: string;
  deleted: boolean; threadRootId: string | null; content: ChatBlock[]; replyCount?: number;
  reactions?: ChatReaction[]; revision?: number; origin?: string; mentions?: string[];
}
export interface ChatRead { thread_key: string; read_seq: string; muted?: boolean; following?: boolean; notification_scope?: string | null }
export interface ChatSnapshot {
  room: ChatRoom; members: ChatMember[]; messages: ChatMessage[]; cursor: string; reads?: ChatRead[];
}
export interface ChatMe { actor: ChatActor; capabilities?: Record<string, Object> }
export interface ChatSendBody {
  operationId: string; content: ChatBlock[]; mentions: string[];
  threadRootId?: string; mentionAudience?: string; independentReplies?: boolean;
}
export interface ChatPending {
  owner: string; roomId: string; body: ChatSendBody; state: string; error: string;
}
/** Stable owner contains account, realm and endpoint; auth epoch is fenced by the request closure. */
export interface ChatOutboxStorage {
  read(owner: string): Promise<ChatPending[]>;
  write(owner: string, rows: ChatPending[]): Promise<void>;
}
export type ChatRequest = (path: string, method: string, body?: Object, actorId?: string) => Promise<Object>;
export interface ChatTarget { kind: string; roomId: string; deviceId: string }
export interface ChatMedia { name: string; type: string; size: number | string; url: string }
export interface ChatRoomPage { snapshot: ChatSnapshot; messages: ChatMessage[]; before: string | null; threadRootId: string; verified?: boolean; historyGeneration?: string }
export function chatId(id: string): string {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new Error('INVALID_CHAT_ID');
  return id;
}
export function chatCursor(seq: string): string {
  if (!/^\d{1,30}$/.test(seq)) throw new Error('INVALID_CHAT_CURSOR');
  return seq.replace(/^0+(?=\d)/, '');
}
/** Decimal comparison retains precision beyond Number.MAX_SAFE_INTEGER. */
export function compareChatSequence(a: string, b: string): number {
  const x = chatCursor(a), y = chatCursor(b);
  return x.length !== y.length ? x.length - y.length : x === y ? 0 : x > y ? 1 : -1;
}
export function chatManager(snapshot: ChatSnapshot, self: string): ChatMember | undefined {
  const rows = snapshot.members.filter((m: ChatMember): boolean => m.state === 'joined'
    && (m.id === self || m.ownerActorId === self) && (m.role === 'owner' || m.role === 'admin'));
  return rows.find((m: ChatMember): boolean => m.role === 'owner')
    ?? rows.find((m: ChatMember): boolean => m.id === self) ?? rows[0];
}
export function chatMessageText(message: ChatMessage): string {
  if (message.deleted) return '';
  return message.content.map((b: ChatBlock): string => b.text ?? b.fallback ?? b.caption ?? '').join('\n');
}
export function mergeChatMessages(old: ChatMessage[], incoming: ChatMessage[]): ChatMessage[] {
  const rows = new Map<string, ChatMessage>();
  old.forEach((m: ChatMessage): void => { rows.set(m.id, m); });
  incoming.forEach((m: ChatMessage): void => {
    const prior = rows.get(m.id);
    if (!prior || (m.revision ?? 0) >= (prior.revision ?? 0)) rows.set(m.id, m);
  });
  return Array.from(rows.values()).sort((a: ChatMessage, b: ChatMessage): number => compareChatSequence(a.seq, b.seq));
}
export function chatError(error: Object): string {
  return error instanceof Error ? error.message : 'CHAT_UNAVAILABLE';
}

export class ChatHttpError extends Error {
  readonly code: string;
  readonly status: number;
  readonly retryAt: number;
  constructor(status: number, retryAt: number = 0, code: string = '') { super(`HTTP_${status}`); this.status = status; this.retryAt = retryAt; this.code = code; }
}

export function validateChatMessage(message: ChatMessage): ChatMessage {
  if (!message || !message.author || typeof message.author.name !== 'string' || typeof message.authorId !== 'string'
    || !Array.isArray(message.content) || typeof message.deleted !== 'boolean') throw new Error('INVALID_CHAT_MESSAGE');
  chatId(message.id); chatCursor(message.seq);
  if (message.threadRootId) chatId(message.threadRootId);
  message.content.forEach((block: ChatBlock): void => {
    if (!block || typeof block.type !== 'string'
      || (block.text !== undefined && typeof block.text !== 'string')
      || (block.fallback !== undefined && typeof block.fallback !== 'string')
      || (block.caption !== undefined && typeof block.caption !== 'string')) throw new Error('INVALID_CHAT_CONTENT');
  }); return message;
}

export interface ChatDeltaData { conversationId?: string; hidden?: boolean; revision?: number; message?: ChatMessage; threadRootId?: string | null }
export interface ChatDelta { type: string; entityId?: string; data?: ChatDeltaData }
export interface ChatDeltaBatch { cursor: string; changes: ChatDelta[]; hasMore?: boolean }

export interface ChatMentionsPage { messages: ChatMessage[]; hasMore: boolean }

export interface ChatListState { conversationId: string; hidden: boolean; revision: number }
