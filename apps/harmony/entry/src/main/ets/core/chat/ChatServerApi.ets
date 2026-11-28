import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { ChatActor, ChatHttpError, ChatMe, ChatRoom, ChatSnapshot, ChatMessage, ChatRequest, ChatSendBody, ChatMedia, chatId, chatCursor, validateChatMessage, chatError, ChatDeltaBatch, ChatMentionsPage, ChatListState } from './ChatModels';

/** Authenticated request is injected: endpoint discovery/token refresh remain with AuthStore. */
export class ChatServerApi {
  private request: ChatRequest;
  constructor(request: ChatRequest) { this.request = request;}
  async listStates(after: string = ''): Promise<ChatListState[]> {
    return await this.request(`/v1/conversation-list-state?limit=100${after ? `&after=${chatId(after)}` : ''}`, 'GET') as ChatListState[];
  }
  async hide(room: string, hidden: boolean, expectedRevision: number, operationId: string): Promise<ChatListState> {
    const body: Record<string, Object> = {}; body['operationId']=operationId; body['hidden']=hidden; body['expectedRevision']=expectedRevision;
    return await this.request(`${this.room(room)}/list-state`, 'POST', body) as ChatListState;
  }
  async actorHead(actor: string): Promise<string> {
    try { const response = await this.request(`/v1/changes?scope=actor:${chatId(actor)}&after=0&limit=1`, 'GET') as Record<string, Object>; return chatCursor(response['head'] as string); }
    catch (e) { if (e instanceof ChatHttpError && e.code === 'RESET_REQUIRED') return '0'; throw e instanceof Error ? e : new Error('CHAT_UNAVAILABLE'); }
  }
  async allMessages(room: string, before: string = ''): Promise<ChatMessage[]> {
    const rows = await this.request(`${this.room(room)}/messages?all=true&limit=100${before ? `&before=${chatCursor(before)}` : ''}`, 'GET') as ChatMessage[];
    if (!Array.isArray(rows)) throw new Error('INVALID_CHAT_PAGE'); rows.forEach((m: ChatMessage): void => { validateChatMessage(m); }); return rows;
  }
  async mentions(room: string, before: string = '', history: boolean = false): Promise<ChatMentionsPage> {
    return await this.request(`${this.room(room)}/mentions?limit=100&scope=${history ? 'personal-history' : 'personal-unread'}${before ? `&before=${chatCursor(before)}` : ''}`, 'GET') as ChatMentionsPage;
  }
  async changes(room: string, after: string): Promise<ChatDeltaBatch> {
    return await this.request(`/v1/changes?scope=conversation:${chatId(room)}&after=${chatCursor(after)}&limit=100`, 'GET') as ChatDeltaBatch;
  }
  async me(): Promise<ChatMe> {
    const me = await this.request('/v1/me', 'GET') as ChatMe;
    if (!me.actor || me.actor.kind !== 'human') throw new Error('INVALID_CHAT_IDENTITY');
    chatId(me.actor.id); return me;
  }
  async companionRoom(actorId: string, name: string): Promise<string> {
    const body: Record<string, Object> = {}; body['kind'] = 'direct'; body['name'] = name.trim().slice(0, 160) || '伙伴';
    body['participants'] = [chatId(actorId)]; body['sourceId'] = actorId; body['operationId'] = `companion-room:${actorId}`;
    let room: Record<string, Object>;
    try { room = await this.request('/v1/conversations', 'POST', body) as Record<string, Object>; }
    catch (e) {
      if (!(e instanceof ChatHttpError) || e.status !== 409 || e.code !== 'OPERATION_CONFLICT') throw e instanceof Error ? e : new Error(chatError(e));
      const digest = cryptoFramework.createMd('SHA256');
      await digest.update({ data: new util.TextEncoder().encodeInto(body['name'] as string) });
      const bytes = (await digest.digest()).data;
      const hex = Array.from(bytes).map((b: number): string => b.toString(16).padStart(2, '0')).join('');
      body['operationId'] = `companion-room:${actorId}:${hex.slice(0, 12)}`;
      room = await this.request('/v1/conversations', 'POST', body) as Record<string, Object>;
    }
    return chatId(room['id'] as string);
  }
  async actors(): Promise<ChatActor[]> {
    const rows = await this.request('/v1/actors', 'GET') as ChatActor[];
    if (!Array.isArray(rows)) throw new Error('INVALID_CHAT_ACTORS');
    return rows.filter((r: ChatActor): boolean => !r.disabled && r.kind === 'bot');
  }
  async list(after: string = ''): Promise<ChatRoom[]> {
    const rows = await this.request(`/v1/conversations?limit=100${after ? `&after=${chatId(after)}` : ''}`, 'GET') as ChatRoom[];
    if (!Array.isArray(rows)) throw new Error('INVALID_CHAT_PAGE'); return rows;
  }
  async snapshot(room: string): Promise<ChatSnapshot> {
    const value = await this.request(`${this.room(room)}/snapshot`, 'GET') as ChatSnapshot;
    if (!value.room || value.room.id !== room || !Array.isArray(value.members) || !Array.isArray(value.messages)) throw new Error('INVALID_CHAT_SNAPSHOT');
    chatCursor(value.cursor); return value;
  }
  async messages(room: string, thread: string = '', before: string = ''): Promise<ChatMessage[]> {
    const rows = await this.request(`${this.room(room)}/messages?limit=100${thread ? `&threadRootId=${chatId(thread)}` : ''}${before ? `&before=${chatCursor(before)}` : ''}`, 'GET') as ChatMessage[];
    if (!Array.isArray(rows)) throw new Error('INVALID_CHAT_PAGE');
    rows.forEach((m: ChatMessage): void => { validateChatMessage(m); }); return rows;
  }
  async message(room: string, id: string): Promise<ChatMessage> {
    return validateChatMessage(await this.request(`${this.room(room)}/messages/${chatId(id)}`, 'GET') as ChatMessage);
  }
  async send(room: string, body: ChatSendBody): Promise<ChatMessage> {
    return validateChatMessage(await this.request(`${this.room(room)}/messages`, 'POST', body) as ChatMessage);
  }
  async read(room: string, seq: string, thread: string): Promise<Object> {
    const body: Record<string, Object> = {}; body['operationId'] = `read-${thread || 'main'}:${chatCursor(seq)}`; body['readSeq'] = chatCursor(seq);
    if (thread) body['threadRootId'] = chatId(thread);
    return this.request(`${this.room(room)}/read`, 'POST', body);
  }
  async react(room: string, message: string, emoji: string, present: boolean, operationId: string): Promise<void> {
    const body: Record<string, Object> = {}; body['operationId'] = operationId; body['emoji'] = emoji; body['present'] = present;
    await this.request(`${this.room(room)}/messages/${chatId(message)}/reactions`, 'POST', body);
  }
  async manage(room: string, suffix: string, method: string, body: Object, actor?: string): Promise<Object> {
    return this.request(`${this.room(room)}${suffix}`, method, body, actor ? chatId(actor) : undefined);
  }
  async previewInvite(token: string): Promise<Object> {
    this.checkToken(token); const body: Record<string, Object> = {}; body['token'] = token; return this.request('/v1/invite-links/preview', 'POST', body);
  }
  async revokeInvite(room: string, token: string, actor: string, operationId: string): Promise<void> {
    this.checkToken(token); const body:Record<string,Object>={}; body['token']=token;body['operationId']=operationId;
    const result=await this.request(`${this.room(room)}/invite-links/revoke`,'POST',body,chatId(actor)) as Record<string,Object>;
    if(result['revoked']!==true) throw new Error('INVALID_CHAT_RESPONSE');
  }
  async join(token: string, operationId: string): Promise<string> {
    this.checkToken(token);
    const body: Record<string, Object> = {}; body['token'] = token; body['operationId'] = operationId;
    const result = await this.request('/v1/invite-links/accept', 'POST', body) as Record<string, Object>;
    return chatId(result['groupId'] as string);
  }
  async media(room: string, id: string): Promise<ChatMedia> {
    const value = await this.request(`${this.room(room)}/media/${chatId(id)}`, 'GET') as ChatMedia;
    if (!/^https:\/\//i.test(value.url) || /^https:\/\/[^/]*@/.test(value.url)
      || !Number.isSafeInteger(Number(value.size)) || Number(value.size) < 0) throw new Error('INVALID_CHAT_MEDIA');
    return value;
  }
  private checkToken(token: string): void { if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error('INVALID_INVITATION_LINK'); }
  private room(id: string): string { return `/v1/conversations/${chatId(id)}`; }
}
