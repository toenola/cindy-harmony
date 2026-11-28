import { ChatBlock, ChatMessage, chatMessageText } from './ChatModels';
/** Existing cindy.quote revision 1 only. Card fields are display data, never authorization. */
export function chatQuoteBlock(message: ChatMessage): ChatBlock {
  if (message.deleted || message.origin === 'system') throw new Error('QUOTE_UNAVAILABLE');
  const excerpt = Array.from(chatMessageText(message).replace(/\s+/g, ' ').trim()).slice(0, 280).join('');
  const attachments = message.content.filter((b: ChatBlock): boolean => b.type === 'media');
  const authorName = message.author.name.slice(0, 200), attachmentName = attachments[0]?.caption ?? '';
  const seq = Number(message.seq);
  const data: Record<string, Object | null> = {};
  data['messageId'] = message.id; data['authorName'] = authorName; data['authorKind'] = message.author.kind === 'human' ? 'user' : 'bot';
  data['excerpt'] = excerpt; data['attachmentCount'] = attachments.length; data['attachmentName'] = attachmentName || null;
  data['seq'] = Number.isSafeInteger(seq) ? String(seq) : null;
  return { type: 'card', namespace: 'cindy.quote', schemaRevision: 1,
    fallback: `> ${authorName}: ${excerpt}${attachmentName ? ` 📎 ${attachmentName}` : ''}`, data };
}
export function chatQuotePreview(block: ChatBlock, loaded: ChatMessage[], deletedLabel: string): string {
  if (block.namespace !== 'cindy.quote' || block.schemaRevision !== 1 || !block.data) return block.fallback ?? '';
  const id = block.data['messageId'];
  const current = loaded.find((m: ChatMessage): boolean => m.id === id);
  if (current) return current.deleted ? deletedLabel : `> ${current.author.name}: ${chatMessageText(current)}`;
  return block.fallback ?? '';
}
