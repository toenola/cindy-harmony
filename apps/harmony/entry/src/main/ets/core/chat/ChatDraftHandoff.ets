import { ChatBlock } from './ChatModels';

export interface ChatDraftText { text: string; revision: number }
export interface ChatDraftContent extends ChatDraftText {
  attachments: ChatBlock[]; mentions: string[]; mentionAll: boolean;
  mentionRevision: number; quoteId: string; quoteRevision: number;
}
export function consumeChatDraftText(current: ChatDraftText, sent: ChatDraftText): ChatDraftText {
  return { text: current.revision === sent.revision && current.text === sent.text ? '' : current.text, revision: current.revision };
}
export function emptyChatDraft(): ChatDraftContent {
  return { text: '', revision: 0, attachments: [], mentions: [], mentionAll: false, mentionRevision: 0, quoteId: '', quoteRevision: 0 };
}
function cloneDraft(value: ChatDraftContent): ChatDraftContent { return JSON.parse(JSON.stringify(value)) as ChatDraftContent; }
/** Durable outbox ownership consumes only its exact snapshot. New text revisions,
 * attachment blocks and explicitly reselected mentions/quotes remain a new draft. */
export function consumeChatDraft(current: ChatDraftContent, sent: ChatDraftContent): ChatDraftContent {
  const next = cloneDraft(current), text = consumeChatDraftText(current, sent);
  next.text = text.text;
  const blocks = new Set(sent.attachments.map((block: ChatBlock): string => JSON.stringify(block)));
  next.attachments = current.attachments.filter((block: ChatBlock): boolean => !blocks.has(JSON.stringify(block)));
  if (current.mentionRevision === sent.mentionRevision) { next.mentions = []; next.mentionAll = false; }
  if (current.quoteRevision === sent.quoteRevision && current.quoteId === sent.quoteId) next.quoteId = '';
  return next;
}
/** Owner/room/thread-keyed drafts also receive handoff while their page is away. */
export class ChatDraftBook {
  private values: Map<string, ChatDraftContent> = new Map();
  read(key: string): ChatDraftContent { return cloneDraft(this.values.get(key) ?? emptyChatDraft()); }
  write(key: string, value: ChatDraftContent): void { if (key) this.values.set(key, cloneDraft(value)); }
  consume(key: string, sent: ChatDraftContent): ChatDraftContent {
    const next = consumeChatDraft(this.read(key), sent); this.write(key, next); return next;
  }
  clear(): void { this.values.clear(); }
}
