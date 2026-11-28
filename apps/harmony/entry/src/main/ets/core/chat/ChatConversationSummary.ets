import { ChatSnapshot, ChatMessage, ChatMember, ChatRead, chatMessageText, compareChatSequence } from './ChatModels';
export interface ChatConversationSummary { roomId: string; text: string; unread: number; mentioned: boolean; timestamp: number; avatars: string[]; head: string }
export function chatConversationSummary(snapshot: ChatSnapshot, self: string): ChatConversationSummary {
  const main = snapshot.reads?.find((r: ChatRead): boolean => r.thread_key === 'main');
  const incoming = snapshot.messages.filter((m: ChatMessage): boolean => {
    if (m.deleted || m.authorId === self || m.origin === 'system' || m.origin === 'import') return false;
    const read = m.threadRootId ? snapshot.reads?.find((r: ChatRead): boolean => r.thread_key === m.threadRootId) : main;
    return !read?.muted && compareChatSequence(m.seq, read?.read_seq ?? '0') > 0 && (!m.threadRootId || read?.following || !!m.mentions?.includes(self));
  });
  const latest = snapshot.messages.filter((m: ChatMessage): boolean => !m.deleted)
    .sort((a: ChatMessage, b: ChatMessage): number => compareChatSequence(b.seq, a.seq))[0];
  const muted = main?.muted || snapshot.room.archived || !!snapshot.room.dissolved_at;
  return { roomId: snapshot.room.id, text: latest ? `${latest.author.name}: ${chatMessageText(latest)}`.slice(0, 160) : '',
    unread: muted ? 0 : incoming.length, mentioned: !muted && incoming.some((m: ChatMessage): boolean => !!m.mentions?.includes(self)),
    timestamp: Math.max(Date.parse(snapshot.room.created_at) || 0, latest ? Date.parse(latest.createdAt) || 0 : 0),
    avatars: snapshot.members.filter((m: ChatMember): boolean => m.state === 'joined' && !!m.avatar).slice(0, 4).map((m: ChatMember): string => m.avatar ?? ''), head: snapshot.room.head ?? String(snapshot.room.revision) };
}
