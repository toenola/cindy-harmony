import { ChatBlock, ChatMember, ChatMessage, ChatActor, ChatSnapshot } from './ChatModels';
export interface ChatCardView { key: string; kind: string; title: string; state: string; summary: string }
export interface ChatOwnedTaskTarget { deviceId: string; sessionId: string; clientId: string; executionId: string; kind: string }
function text(record: Record<string, Object | null>, key: string, max: number): string { return typeof record[key] === 'string' ? (record[key] as string).slice(0, max) : ''; }
/** Cards are display snapshots; no state or permission is inferred from their prose. */
export function chatCards(message: ChatMessage): ChatCardView[] {
  if (message.deleted) return [];
  const cards: ChatCardView[] = [];
  message.content.forEach((block: ChatBlock, i: number): void => {
    if (block.type !== 'card' || !block.data) return;
    if (block.namespace === 'cindy.task' && (block.schemaRevision === 1 || block.schemaRevision === 2)) {
      const state = text(block.data, 'state', 30);
      if (!['started','waiting','completed','failed','cancelled','timed-out','running','pending','done','stopped'].includes(state)) return;
      cards.push({ key: `${message.id}:${i}`, kind: 'task', title: text(block.data, 'title', 120), state, summary: text(block.data, 'summary', 400) });
    } else if (block.namespace === 'cindy.plan' && block.schemaRevision === 1) {
      cards.push({ key: `${message.id}:${i}`, kind: 'plan', title: block.fallback ?? '', state: '', summary: '' });
    } else if (block.namespace === 'cindy.work-record' && block.schemaRevision === 1) {
      cards.push({ key: `${message.id}:${i}`, kind: 'process', title: block.fallback ?? '', state: '', summary: '' });
    }
  }); return cards;
}
/** Only an account-owned BOT may offer a task locator, never an arbitrary user's card. */
export function ownedChatTask(message: ChatMessage, block: ChatBlock, snapshot: ChatSnapshot, actors: ChatActor[],
  self: string, canControl: (deviceId: string) => boolean): ChatOwnedTaskTarget | null {
  const member = snapshot.members.find((m: ChatMember): boolean => m.id === message.authorId && m.kind === 'bot' && m.ownerActorId === self);
  const actor = actors.find((a: ChatActor): boolean => a.id === member?.id);
  if (message.deleted || !member || !actor || !block.data) return null;
  const data = block.data;
  let target: ChatOwnedTaskTarget | null = null;
  if (block.namespace === 'cindy.work-record' && block.schemaRevision === 1 && data['groupId'] === snapshot.room.id) {
    target = { deviceId: text(data, 'deviceId', 500) || actor.homeDeviceId || '', sessionId: text(data, 'sessionId', 500),
      clientId: text(data, 'clientId', 500), executionId: text(data, 'executionId', 500), kind: 'process' };
  } else if (block.namespace === 'cindy.task' && block.schemaRevision === 2) {
    target = { deviceId: text(data, 'deviceId', 500) || actor.homeDeviceId || '', sessionId: text(data, 'taskId', 500), clientId: '', executionId: '', kind: 'task' };
  }
  if (!target?.deviceId || !target.sessionId || !canControl(target.deviceId)) return null;
  if (target.kind === 'process' && (!target.clientId || !target.executionId)) return null;
  return target;
}
