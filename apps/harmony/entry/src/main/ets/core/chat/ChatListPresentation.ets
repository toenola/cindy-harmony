import { ChatActor, ChatRoom } from './ChatModels';
import { ChatConversationSummary } from './ChatConversationSummary';
import { TeammateRosterEntry } from '../tasks/TeammateRoster';
export interface ChatListRow { key: string; kind: string; id: string; deviceId: string; title: string; avatar: string; summary: string; unread: number; hasUnread: boolean; timestamp: number }
/** Match the canonical home by externalId, never by name or avatar. Local main chat wins. */
export function chatListRows(actors: ChatActor[], rooms: ChatRoom[], summaries: ChatConversationSummary[], query: string,
  local: TeammateRosterEntry[] = []): ChatListRow[] {
  const rows: ChatListRow[] = [];
  const homes = new Map<string, ChatActor>(); actors.forEach((a: ChatActor): void => { if (a.externalId && a.homeDeviceId) homes.set(a.externalId, a); });
  local.forEach((entry: TeammateRosterEntry): void => {
    const actor = homes.get(entry.id); if (actor && actor.homeDeviceId !== entry.deviceId) return;
    rows.push({ key: JSON.stringify(['local',entry.deviceId,entry.id]), kind: 'local', id: entry.id, deviceId: entry.deviceId,
      title: entry.name, avatar: entry.avatarValue, summary: entry.preview, unread: 0,
      hasUnread: entry.readAt >= 0 && entry.replyAt > entry.readAt, timestamp: entry.timestamp });
  });
  actors.forEach((a: ChatActor): void => {
    if (a.disabled || !a.homeDeviceId || rows.some((r: ChatListRow): boolean => r.kind === 'local' && r.id === a.externalId && r.deviceId === a.homeDeviceId)) return;
    rows.push({ key: `actor:${a.id}`, kind: 'companion', id: a.id, deviceId: a.homeDeviceId, title: a.name, avatar: a.avatar ?? '', summary: '', unread: 0, hasUnread: false, timestamp: 0 });
  });
  rooms.forEach((r: ChatRoom): void => {
    if (r.kind !== 'group') return;
    const summary = summaries.find((s: ChatConversationSummary): boolean => s.roomId === r.id);
    rows.push({ key: `room:${r.id}`, kind: 'group', id: r.id, deviceId: '', title: r.name, avatar: summary?.avatars[0] ?? '', summary: summary?.text ?? '',
      unread: summary?.unread ?? 0, hasUnread: (summary?.unread ?? 0) > 0, timestamp: summary?.timestamp ?? (Date.parse(r.created_at) || 0) });
  });
  const needle = query.normalize('NFKC').trim().toLowerCase();
  return rows.filter((r: ChatListRow): boolean => !needle || `${r.title}\n${r.summary}`.normalize('NFKC').toLowerCase().includes(needle))
    .sort((a: ChatListRow, b: ChatListRow): number => b.timestamp - a.timestamp || a.key.localeCompare(b.key));
}
