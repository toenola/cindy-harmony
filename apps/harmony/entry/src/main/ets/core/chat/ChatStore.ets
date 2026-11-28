import { ChatRosterStorage, ChatCachedRoster } from './ChatRosterCache';
import { ChatConversationSummary, chatConversationSummary } from './ChatConversationSummary';
import { ChatInviteShares, parseChatInviteReference } from './ChatInvitationStore';
import { ChatHistory } from './ChatHistory';
import { chatQuoteBlock } from './ChatQuote';
import { ChatActor, ChatListState, ChatHttpError, ChatDelta, ChatDeltaBatch, ChatMember, ChatRead, ChatMe, ChatRoom, ChatSnapshot, ChatMessage, ChatPending, ChatOutboxStorage, ChatSendBody, ChatRoomPage,
  chatId, chatManager, chatError, compareChatSequence, mergeChatMessages } from './ChatModels';
import { ChatServerApi } from './ChatServerApi';

interface ChatPreparedManagement { room: string; suffix: string; method: string; body: Record<string, Object | null>; actor?: string; settled?: boolean }
interface ChatPreparedInvitation { token: string; actor: string }
/** Account-owned state, not a page-owned network connection. No polling and no blind write replay. */
export class ChatStore {
  rooms: ChatRoom[] = [];
  actors: ChatActor[] = [];
  me: ChatMe | null = null;
  page: ChatRoomPage | null = null;
  pending: ChatPending[] = [];
  error: string = '';
  loading: boolean = false;
  private directoryVerified:boolean=false;
  ensureConversations():Promise<void>{return this.directoryVerified?Promise.resolve():this.loadConversations();}
  topicRoots: ChatMessage[] = [];
  topicBefore: string = '';
  mentionMessages: ChatMessage[] = [];
  private management: Map<string, ChatPreparedManagement> = new Map();
  private invitations: Map<string, ChatPreparedInvitation> = new Map();
  summaries: ChatConversationSummary[] = [];
  private summaryRequested: Set<string> = new Set();
  private summaryTask: Promise<void> | null = null;
  private listStates: Map<string, ChatListState> = new Map();
  private listSynced: boolean = false;
  private roster: ChatRosterStorage | null = null;
  private rosterWrites: Promise<void> = Promise.resolve();
  attachRoster(roster: ChatRosterStorage): void { this.roster = roster; }
  private history: ChatHistory | null = null;
  attachHistory(history: ChatHistory): void { this.history = history; }
  private generation: number = 0;
  private navigation: number = 0;
  private listeners: Array<() => void> = [];
  private reads: Map<string, Promise<void>> = new Map();
  private sends: Set<string> = new Set();
  private enqueuing: Set<string> = new Set();
  private writeTail: Promise<void> = Promise.resolve();
  private ownedDrains:Set<()=>Promise<void>>=new Set();
  registerOwnedDrain(drain:()=>Promise<void>):()=>void{if(this.disposed)throw new Error('OWNER_CHANGED');this.ownedDrains.add(drain);return():void=>{this.ownedDrains.delete(drain);};}
  private shutdownTask: Promise<void> | null = null;
  private disposed: boolean = false;
  readonly owner: string;
  private api: ChatServerApi;
  private storage: ChatOutboxStorage;
  constructor(owner: string, api: ChatServerApi, storage: ChatOutboxStorage) { this.owner = owner; this.api = api; this.storage = storage;}
  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => { this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener); };
  }
  private notify(): void { if (!this.disposed) this.listeners.forEach((l: () => void): void => l()); }
  private current(generation: number): boolean { return !this.disposed && generation === this.generation; }
  /** Composition root must dispose on logout/realm change, before publishing the next identity. */
  dispose(): void {
    if (this.disposed) return;
    this.generation++; this.navigation++;
    this.directoryVerified=false;this.rooms = []; this.actors = []; this.summaries = []; this.topicRoots = []; this.mentionMessages = []; this.page = null; this.pending = []; this.me = null;
    this.reads.clear(); this.summaryRequested.clear(); this.listStates.clear(); this.management.clear(); this.invitations.clear(); this.notify(); this.disposed = true; this.listeners = [];
  }
  /** Await before AuthStore clears credentials so no older durable write survives logout. */
  shutdown(): Promise<void> {
    if (this.shutdownTask) return this.shutdownTask;
    // Publish the task BEFORE dispose notifies listeners; even a reentrant shutdown
    // receives this same promise. Every durable tail settles before any error escapes.
    const task = Promise.resolve().then(async (): Promise<void> => {
      const failures: Error[] = [];
      const drain = (pending: Promise<void>): Promise<void> => pending.catch((e: Object): void => { failures.push(e instanceof Error ? e : new Error('CHAT_SHUTDOWN_FAILED')); });
      const history = this.history;
      const historyDrain = Promise.resolve().then(async (): Promise<void> => { await history?.shutdown(); });
      const children=Array.from(this.ownedDrains).map((child:()=>Promise<void>):Promise<void>=>drain(Promise.resolve().then(child)));
      await Promise.all([drain(historyDrain), drain(this.rosterWrites), drain(this.writeTail), ...children]); this.ownedDrains.clear();
      if (failures.length) throw failures[0];
    });
    this.shutdownTask = task; this.dispose(); return task;
  }
  async restore(): Promise<void> {
    const g = this.generation;
    if (this.roster) {
      const cached = await this.roster.read(this.owner);
      if (!this.current(g)) return;
      if (cached) { this.rooms = cached.rooms; this.actors = cached.actors; this.me = cached.me; this.notify(); }
    }
    const rows = await this.storage.read(this.owner);
    if (!this.current(g)) return;
    this.pending = rows.filter((r: ChatPending): boolean => r.owner === this.owner).map((r: ChatPending): ChatPending => {
      if (r.state === 'sending') r.state = 'unknown'; return r;
    }); this.notify();
  }
  private acceptSummary(snapshot: ChatSnapshot): void {
    if (!this.me) return; const summary = chatConversationSummary(snapshot, this.me.actor.id);
    const listed = this.rooms.find((r: ChatRoom): boolean => r.id === snapshot.room.id);
    summary.head = listed?.head ?? String(listed?.revision ?? snapshot.room.revision);
    this.summaries = this.summaries.filter((r: ChatConversationSummary): boolean => r.roomId !== summary.roomId).concat([summary]);
  }
  loadSummaries(ids: string[]): Promise<void> {
    ids.forEach((id: string): void => { this.summaryRequested.add(id); });
    if (this.summaryTask) return this.summaryTask;
    const g = this.generation;
    const run = async (): Promise<void> => {
      while (this.summaryRequested.size && this.current(g)) {
        const batch = Array.from(this.summaryRequested).slice(0, 4); batch.forEach((id: string): void => { this.summaryRequested.delete(id); });
        await Promise.all(batch.map(async (id: string): Promise<void> => {
          const room = this.rooms.find((r: ChatRoom): boolean => r.id === id);
          const prior = this.summaries.find((r: ChatConversationSummary): boolean => r.roomId === id);
          if (prior && prior.head === (room?.head ?? String(room?.revision))) return;
          try { const snapshot = await this.api.snapshot(id); if (this.current(g)) this.acceptSummary(snapshot); } catch (_) {}
        }));
        if (this.current(g)) this.notify();
      }
    };
    const task = run().finally((): void => { if (this.summaryTask === task) this.summaryTask = null; });
    this.summaryTask = task; return task;
  }
  async openCompanion(actor: ChatActor): Promise<void> {
    if (this.me?.capabilities?.['companionHome'] !== true || !this.actors.some((a: ChatActor): boolean => a.id === actor.id)) throw new Error('UNSUPPORTED_OPERATION');
    const g = this.generation; const room = await this.api.companionRoom(actor.id, actor.name);
    if (this.current(g)) await this.open(room);
  }
  private mergeListState(row: ChatListState): void {
    chatId(row.conversationId); if (typeof row.hidden !== 'boolean' || !Number.isSafeInteger(row.revision) || row.revision < 1) throw new Error('INVALID_CHAT_LIST_STATE');
    if ((this.listStates.get(row.conversationId)?.revision ?? 0) >= row.revision) return;
    this.listStates.set(row.conversationId,row);
    if (row.hidden) { this.rooms=this.rooms.filter((r: ChatRoom): boolean => r.id!==row.conversationId); if (this.page?.snapshot.room.id===row.conversationId) { this.page=null; this.navigation++; } }
  }
  async syncListState(force: boolean = false): Promise<void> {
    if (!this.capability('conversationListStateVersion') || (this.listSynced && !force)) return;
    const g=this.generation; let after='';
    do {
      const rows=await this.api.listStates(after); if (!this.current(g)) return;
      if (!Array.isArray(rows)) throw new Error('INVALID_CHAT_LIST_STATE'); rows.forEach((r: ChatListState): void => this.mergeListState(r));
      const next=rows.length===100 ? rows[rows.length-1].conversationId : '';
      if (next && after && next<=after) throw new Error('INVALID_CHAT_PAGE'); after=next;
    } while(after);
    this.listSynced=true;
  }
  async resetActorScope(): Promise<void> { await this.syncListState(true); await this.loadConversations(false); }
  async setHidden(room: string, hidden: boolean, operationId: string): Promise<void> {
    if (!this.capability('conversationListStateVersion')) throw new Error('UNSUPPORTED_OPERATION'); await this.syncListState(true);
    const g=this.generation; const result=await this.api.hide(room,hidden,this.listStates.get(room)?.revision ?? 0,operationId);
    if (!this.current(g)) return; this.mergeListState(result); this.notify();
  }
  async actorHead(actor: string): Promise<string> { return this.api.actorHead(actor); }
  async actorChanged(changes: ChatDeltaBatch, listVisible: boolean): Promise<void> {
    const room = this.page?.snapshot.room.id;
    const invalid = new Set(changes.changes.filter((c: ChatDelta): boolean => c.type === 'read.changed' || c.type === 'membership.changed').map((c: ChatDelta): string => c.entityId ?? ''));
    if (invalid.size) this.summaries = this.summaries.filter((s: ChatConversationSummary): boolean => !invalid.has(s.roomId));
    changes.changes.forEach((c: ChatDelta): void => {
      if (c.type==='conversation.list.changed' && c.data?.conversationId && typeof c.data.hidden==='boolean' && c.data.revision!==undefined) {
        const row: ChatListState={conversationId:c.data.conversationId,hidden:c.data.hidden,revision:c.data.revision}; this.mergeListState(row);
      }
    });
    if (listVisible) await this.loadConversations(changes.changes.some((c: ChatDelta): boolean => c.type.startsWith('actor.')));
    if (room && invalid.has(room)) await this.refresh();
  }
  async loadConversations(refreshIdentity: boolean = true): Promise<void> {
    return this.coalesce('list', async (): Promise<void> => {
      const g = this.generation;
      const me = refreshIdentity || !this.me ? await this.api.me() : this.me;
      if (!this.current(g)) return;
      const actors = refreshIdentity ? await this.api.actors() : this.actors;
      if (!this.current(g)) return;
      const rows: ChatRoom[] = []; let after = '';
      // One page per explicit call; loadMoreConversations advances only on user request.
      const first = await this.api.list(after);
      if (!this.current(g)) return;
      this.me=me; await this.syncListState(); if (!this.current(g)) return;
      rows.push(...first.filter((r: ChatRoom): boolean => this.listStates.get(r.id)?.hidden!==true)); this.me = me; this.actors = actors; this.rooms = rows; this.directoryVerified=true;this.notify();
      if (!this.current(g)) return;
      if (this.roster) {
        const value = this.roster; const snapshot: ChatCachedRoster = { rooms: this.rooms, actors: this.actors, me };
        this.rosterWrites = value.write(this.owner, snapshot); await this.rosterWrites;
      }
      await this.loadSummaries(this.rooms.slice(0, 20).map((r: ChatRoom): string => r.id));
    });
  }
  async loadMoreConversations(): Promise<void> {
    if (this.rooms.length === 0 || this.rooms.length % 100 !== 0) return;
    const after = this.rooms[this.rooms.length - 1].id;
    return this.coalesce(`list:${after}`, async (): Promise<void> => {
      const g = this.generation, rows = await this.api.list(after);
      if (!this.current(g)) return;
      const known = new Set(this.rooms.map((r: ChatRoom): string => r.id));
      this.rooms = this.rooms.concat(rows.filter((r: ChatRoom): boolean => !known.has(r.id))); this.notify();
    });
  }
  closePage():void{this.navigation++;this.page=null;this.loading=false;this.notify();}
  async open(room: string, thread: string = ''): Promise<void> {
    chatId(room); if (thread) chatId(thread);
    const nav = ++this.navigation, g = this.generation;
    this.page = null; this.loading = true; this.error = ''; this.notify();
    try {
      if (this.history) {
        const cached = await this.history.page(room, thread, '', true);
        if (!this.current(g) || nav !== this.navigation) return; this.page = cached; this.acceptSummary(cached.snapshot); return;
      }
      const snapshot = await this.api.snapshot(room);
      if (!this.current(g) || nav !== this.navigation) return;
      const messages = await this.api.messages(room, thread);
      if (!this.current(g) || nav !== this.navigation) return;
      this.page = { snapshot, messages: mergeChatMessages([], messages), threadRootId: thread,
        before: messages.length === 100 ? messages[messages.length - 1].seq : null };
    } catch (e) {
      if (this.current(g) && nav === this.navigation) {
        this.error = chatError(e);
        if (this.history && !(e instanceof ChatHttpError && e.status >= 400 && e.status < 500)) {
          const offline = await this.history.offline(room, thread);
          if (this.current(g) && nav === this.navigation) this.page = offline;
        }
      }
    }
    finally { if (this.current(g) && nav === this.navigation) { this.loading = false; this.notify(); } }
  }
  /** Push handlers must filter the authorized room, then call this; no timer fallback. */
  async refresh(): Promise<void> {
    const page = this.page; if (!page) return;
    return this.coalesce(`refresh:${page.snapshot.room.id}:${page.threadRootId}`, async (): Promise<void> => {
      const g = this.generation, nav = this.navigation, room = page.snapshot.room.id;
      try {
        if (this.history) {
          const next = await this.history.page(room, page.threadRootId, '', true);
          if (!this.current(g) || nav !== this.navigation) return;
          if (next.historyGeneration === page.historyGeneration) { const length = next.messages.length; next.messages = mergeChatMessages(page.messages, this.history.messages(room).filter((m: ChatMessage): boolean => (m.threadRootId ?? '') === page.threadRootId)); if (page.messages.length > length) next.before = page.before; }
          this.page = next; this.acceptSummary(next.snapshot); this.error = ''; this.notify(); return;
        }
        const snapshot = await this.api.snapshot(room);
        if (!this.current(g) || nav !== this.navigation) return;
        const messages = await this.api.messages(room, page.threadRootId);
        if (!this.current(g) || nav !== this.navigation) return;
        page.snapshot = snapshot; page.messages = mergeChatMessages(page.messages, messages); this.error = ''; this.notify();
      } catch (e) {
        if (!this.current(g) || nav !== this.navigation) return;
        this.error = chatError(e);
        if (this.error === 'HTTP_403' || this.error === 'HTTP_404') { this.page = null; this.navigation++; }
        this.notify(); throw e instanceof Error ? e : new Error(chatError(e));
      }
    });
  }
  async loadOlder(): Promise<void> {
    const page = this.page; if (!page?.before) return;
    const before = page.before, nav = this.navigation, g = this.generation;
    return this.coalesce(`older:${page.snapshot.room.id}:${page.threadRootId}:${before}`, async (): Promise<void> => {
      const loaded = this.history ? await this.history.page(page.snapshot.room.id, page.threadRootId, before) : null;
      const rows = loaded?.messages ?? await this.api.messages(page.snapshot.room.id, page.threadRootId, before);
      if (!this.current(g) || nav !== this.navigation) return;
      page.messages = mergeChatMessages(page.messages, rows);
      page.before = loaded ? loaded.before : rows.length === 100 ? rows[rows.length - 1].seq : null; this.notify();
    });
  }
  /** Persist EXACT bytes before sending. onEnqueued transfers the immutable draft
   * snapshot once, before RPC; later unknown-state write failure never undoes it.
   * Retry uses this body even when membership/quote changed. */
  async send(body: ChatSendBody, quoteId: string = '', onEnqueued: (() => void) | null = null): Promise<void> {
    const page = this.page; if (!page || !this.me) throw new Error('CHAT_NOT_READY');
    if (!body.operationId || (!body.content.length) || this.pending.length >= 100) throw new Error('INVALID_CHAT_SEND');
    if ((body.threadRootId ?? '') !== page.threadRootId) throw new Error('CHAT_TARGET_CHANGED');
    if (this.pending.some((p: ChatPending): boolean => p.body.operationId === body.operationId)) throw new Error('CHAT_OPERATION_EXISTS');
    const g = this.generation, room = page.snapshot.room.id;
    const snapshot = await this.api.snapshot(room);
    if (!this.current(g) || page !== this.page) throw new Error('OWNER_CHANGED');
    this.assertSend(snapshot);
    if (body.mentionAudience && (!this.capability('groupMentionAudiences') || snapshot.room.kind === 'direct')) throw new Error('UNSUPPORTED_OPERATION');
    if (body.mentionAudience && !chatManager(snapshot, this.me.actor.id) && snapshot.room.allow_member_mention_all !== true) throw new Error('ROLE_REQUIRED');
    body.mentions.forEach((id: string): void => {
      if (!snapshot.members.some((m: ChatMember): boolean => m.id === chatId(id) && m.state === 'joined')) throw new Error('MEMBER_UNAVAILABLE');
    });
    const exact = JSON.parse(JSON.stringify(body)) as ChatSendBody;
    if (quoteId) {
      const source = await this.api.message(room, chatId(quoteId));
      if (!this.current(g) || page !== this.page) throw new Error('OWNER_CHANGED');
      if (source.threadRootId && source.threadRootId !== page.threadRootId) throw new Error('QUOTE_UNAVAILABLE');
      exact.content.unshift(chatQuoteBlock(source));
      const author = snapshot.members.find((m: ChatMember): boolean => m.id === source.authorId);
      if (!exact.mentionAudience && author?.kind === 'bot' && author.state === 'joined' && !exact.mentions.includes(author.id)) exact.mentions.push(author.id);
    }
    if (this.capability('independentReplies') && snapshot.room.kind !== 'direct') exact.independentReplies = true;
    const pending: ChatPending = { owner: this.owner, roomId: room, body: exact, state: 'queued', error: '' };
    this.enqueuing.add(body.operationId); this.pending.push(pending); this.notify();
    try { await this.persist(); }
    catch (e) { this.pending = this.pending.filter((p: ChatPending): boolean => p !== pending); this.notify(); throw e instanceof Error ? e : new Error(chatError(e)); }
    finally { this.enqueuing.delete(body.operationId); }
    if (this.current(g)) { onEnqueued?.(); await this.deliver(pending); }
  }
  async retry(operationId: string): Promise<void> {
    const item = this.pending.find((p: ChatPending): boolean => p.body.operationId === operationId);
    if (!item || item.owner !== this.owner) throw new Error('OUTBOX_NOT_FOUND');
    if (this.enqueuing.has(operationId)) throw new Error('CHAT_SEND_IN_PROGRESS');
    await this.persist(); await this.deliver(item);
  }
  private async deliver(item: ChatPending): Promise<void> {
    if (this.sends.has(item.body.operationId) || this.disposed) return;
    const g = this.generation;
    let accepted = false;
    this.sends.add(item.body.operationId); item.state = 'sending'; this.notify();
    try {
      const message = await this.api.send(item.roomId, item.body);
      if (!this.current(g)) return;
      accepted = true;
      if (this.page?.snapshot.room.id === item.roomId && this.page.threadRootId === (item.body.threadRootId ?? '')) {
        this.page.messages = mergeChatMessages(this.page.messages, [message]);
      }
      this.pending = this.pending.filter((p: ChatPending): boolean => p !== item);
      await this.persist();
    } catch (e) {
      if (!this.current(g)) return;
      if (accepted) { this.error = 'OUTBOX_NOT_SAVED'; throw e instanceof Error ? e : new Error(chatError(e)); }
      // Transport failure is unknown; never auto retry on reconnect or rebuild operationId.
      item.error = chatError(e); item.state = /^HTTP_4(?!08)/.test(item.error) ? 'failed' : 'unknown';
      await this.persist();
    } finally { this.sends.delete(item.body.operationId); if (this.current(g)) this.notify(); }
  }
  async markRead(visibleIds: string[], atEnd: boolean, foreground: boolean): Promise<void> {
    const page = this.page; if (!page || !foreground || !atEnd || !page.snapshot.reads) return;
    const key = page.threadRootId || 'main';
    const prior = page.snapshot.reads.find((r: ChatRead): boolean => r.thread_key === key);
    let seq = prior?.read_seq ?? '0';
    page.messages.forEach((m: ChatMessage): void => {
      if (visibleIds.includes(m.id) && (m.threadRootId ?? '') === page.threadRootId && compareChatSequence(m.seq, seq) > 0) seq = m.seq;
    });
    if (compareChatSequence(seq, prior?.read_seq ?? '0') <= 0) return;
    const g = this.generation, nav = this.navigation;
    const result = await this.api.read(page.snapshot.room.id, seq, page.threadRootId) as Record<string, Object>;
    if (!this.current(g) || nav !== this.navigation) return;
    const accepted = result['readSeq'] as string;
    if (compareChatSequence(accepted, prior?.read_seq ?? '0') > 0) {
      if (prior) prior.read_seq = accepted; else page.snapshot.reads.push({ thread_key: key, read_seq: accepted });
      this.acceptSummary(page.snapshot); this.notify();
    }
  }
  async react(message: string, emoji: string, present: boolean, operationId: string): Promise<void> {
    const page = this.page; if (!page) return;
    const g = this.generation, nav = this.navigation;
    await this.api.react(page.snapshot.room.id, message, emoji, present, operationId);
    if (!this.current(g) || nav !== this.navigation) return;
    const saved = await this.api.message(page.snapshot.room.id, message);
    if (!this.current(g) || nav !== this.navigation) return;
    page.messages = mergeChatMessages(page.messages, [saved]); this.notify();
  }
  /** Managers are reselected from a NEW authorized snapshot before each write. */
  async manage(type: string, input: Record<string, Object | null>, operationId: string): Promise<Object> {
    const page = this.page, me = this.me; if (!page || !me || !operationId) throw new Error('CHAT_NOT_READY');
    const g = this.generation, nav = this.navigation, room = page.snapshot.room.id;
    const snapshot = await this.api.snapshot(room);
    if (!this.current(g) || nav !== this.navigation) throw new Error('OWNER_CHANGED');
    const manager = chatManager(snapshot, me.actor.id);
    const self = snapshot.members.find((m: ChatMember): boolean => m.id === me.actor.id && m.state === 'joined');
    let suffix = '', method = 'POST', actor: string | undefined = undefined;
    const body: Record<string, Object | null> = {}; body['operationId'] = operationId;
    if (snapshot.room.dissolved_at || (snapshot.room.archived && type !== 'restore')) throw new Error('GROUP_CLOSED');
    const targetMember = snapshot.members.find((m: ChatMember): boolean => m.id === input['actorId']);
    const ownedBot = targetMember?.kind === 'bot' && targetMember.ownerActorId === me.actor.id && !targetMember.assistant;
    if (type === 'invite') {
      if (!self || (!manager && !(this.capability('groupMemberInvites') && snapshot.room.allow_member_invites))) throw new Error('ROLE_REQUIRED');
      suffix = '/invite-links'; actor = manager?.id ?? self.id;
    } else if (type === 'member' && ((input['action'] === 'invite' && this.actors.some((a: ChatActor): boolean => a.id === input['actorId'])) || (input['action'] === 'remove' && ownedBot))) {
      if (!self) throw new Error('ROLE_REQUIRED'); suffix = '/members'; body['actorId'] = chatId(input['actorId'] as string);
      if (input['action'] === 'remove') { body['action'] = 'leave'; actor = targetMember?.id; } else body['action'] = 'invite';
    } else if (type === 'botAccess') {
      if (!self || !ownedBot || !Number.isSafeInteger(input['expectedRevision'])) throw new Error('ROLE_REQUIRED');
      suffix = '/bot-access'; body['actorId'] = chatId(input['actorId'] as string); body['access'] = input['access']; body['expectedRevision'] = input['expectedRevision'];
    } else if (type === 'nickname' || type === 'avatar') {
      if (!self || snapshot.room.archived || snapshot.room.dissolved_at) throw new Error('ROLE_REQUIRED');
      if (type === 'avatar' && !this.capability('groupMemberAvatar')) throw new Error('UNSUPPORTED_OPERATION');
      suffix = '/nickname'; body['actorId'] = self.id; body[type] = input[type];
    } else if (type === 'notifications') {
      if (!self || !this.capability('groupNotificationSettings')) throw new Error('UNSUPPORTED_OPERATION');
      suffix = '/read'; body['readSeq'] = '0'; body['notificationMode'] = input['mode'];
    } else if (type === 'leave') {
      if (!self) throw new Error('ROLE_REQUIRED');
      suffix = '/members'; body['actorId'] = self.id; body['action'] = 'leave';
    } else {
      if (!manager || snapshot.room.dissolved_at || (snapshot.room.archived && type !== 'restore')) throw new Error('ROLE_REQUIRED');
      actor = manager.id;
      if (type === 'update' || type === 'archive' || type === 'restore') {
        method = 'PATCH'; body['expectedRevision'] = snapshot.room.revision;
        if (type !== 'update') body['archived'] = type === 'archive';
        else {
          ['name', 'topic', 'description'].forEach((key: string): void => { if (input[key] !== undefined) body[key] = input[key]; });
          if (input['allowMemberInvites'] !== undefined && this.capability('groupMemberInvites')) body['allowMemberInvites'] = input['allowMemberInvites'];
          if (input['allowMemberMentionAll'] !== undefined && this.capability('groupMemberMentionAll')) body['allowMemberMentionAll'] = input['allowMemberMentionAll'];
        }
      } else if (type === 'member') {
        suffix = '/members'; body['actorId'] = chatId(input['actorId'] as string); body['action'] = input['action'];
        if (input['role'] !== undefined) body['role'] = input['role'];
      } else if (type === 'transfer') { suffix = '/transfer'; body['actorId'] = chatId(input['actorId'] as string); }
      else if (type === 'botAccess') {
        suffix = '/bot-access'; body['actorId'] = chatId(input['actorId'] as string);
        body['access'] = input['access']; body['expectedRevision'] = input['expectedRevision'];
      } else if (type === 'dissolve') {
        if (!this.capability('groupLifecycleVersion') || manager.role !== 'owner') throw new Error('UNSUPPORTED_OPERATION');
        suffix = '/dissolve'; body['expectedRevision'] = snapshot.room.revision;
      } else if (type === 'invite') { suffix = '/invite-links'; }
      else throw new Error('UNSUPPORTED_OPERATION');
    }
    let prepared = this.management.get(operationId);
    if (!prepared) {
      prepared = { room, suffix, method, body: JSON.parse(JSON.stringify(body)) as Record<string, Object | null>, actor };
      if (this.management.size >= 100) {
        const evict = Array.from(this.management.keys()).find((id: string): boolean => this.management.get(id)?.settled === true);
        if (evict) this.management.delete(evict); else throw new Error('CHAT_OPERATION_LIMIT');
      } this.management.set(operationId, prepared);
    }
    if (prepared.room !== room || prepared.suffix !== suffix || prepared.actor !== actor) throw new Error('CHAT_OPERATION_CHANGED');
    const result = await this.api.manage(room, prepared.suffix, prepared.method, prepared.body, prepared.actor);
    prepared.settled = true;
    if (!this.current(g) || nav !== this.navigation) throw new Error('OWNER_CHANGED');
    if (type === 'leave') { this.page = null; this.navigation++; this.notify(); }
    else await this.refresh().catch((): void => {});
    return result;
  }
  async revokeInvite(shares: ChatInviteShares, link: string, operationId: string): Promise<void> {
    const page=this.page,me=this.me; if(!page||!me) throw new Error('CHAT_NOT_READY');
    const g=this.generation,nav=this.navigation,room=page.snapshot.room.id,ref=parseChatInviteReference(link);
    const token=ref.token || await shares.resolve(ref.shareId);
    if(!this.current(g)||nav!==this.navigation) throw new Error('OWNER_CHANGED');
    const snapshot=await this.api.snapshot(room);
    if(!this.current(g)||nav!==this.navigation) throw new Error('OWNER_CHANGED');
    const manager=chatManager(snapshot,me.actor.id), self=snapshot.members.find((m:ChatMember):boolean=>m.id===me.actor.id&&m.state==='joined');
    if((!manager&&!self)||snapshot.room.archived||snapshot.room.dissolved_at) throw new Error('ROLE_REQUIRED');
    await this.api.revokeInvite(room,token,manager?.id??self?.id??'',operationId);
    if(!this.current(g)||nav!==this.navigation) throw new Error('OWNER_CHANGED');
    // Chat Server revocation is authoritative. Public share-page cleanup cannot undo it.
    if(ref.shareId&&shares.revoked) await shares.revoked(ref.shareId).catch(():void=>{});
    if(!this.current(g)||nav!==this.navigation) throw new Error('OWNER_CHANGED');
    this.invitations.forEach((value:ChatPreparedInvitation,id:string):void=>{if(value.token===token)this.invitations.delete(id);});
  }
  async inviteLink(shares: ChatInviteShares, operationId: string): Promise<string> {
    const page = this.page; if (!page) throw new Error('CHAT_NOT_READY');
    const g = this.generation, room = page.snapshot.room.id;
    let invitation = this.invitations.get(operationId);
    if (!invitation) {
      const input: Record<string, Object> = {};
      const result = await this.manage('invite', input, operationId) as Record<string, Object>;
      if (!this.current(g)) throw new Error('OWNER_CHANGED');
      const token = result['token']; if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error('INVALID_CHAT_RESPONSE');
      const actor = this.management.get(operationId)?.actor; if (!actor) throw new Error('INVALID_CHAT_IDENTITY');
      invitation = { token, actor }; this.invitations.set(operationId, invitation);
    }
    const link = await shares.create(room, invitation.token, invitation.actor);
    if (!this.current(g)) throw new Error('OWNER_CHANGED'); return link;
  }
  async receive(batch: ChatDeltaBatch, subscribedAfter: string): Promise<void> {
    const page = this.page, history = this.history; if (!page) return;
    if (!history) { await this.refresh(); return; }
    const g = this.generation, nav = this.navigation, room = page.snapshot.room.id;
    await history.receive(room, batch, subscribedAfter);
    const next = await history.page(room, page.threadRootId);
    if (!this.current(g) || nav !== this.navigation) return;
    if (next.historyGeneration === page.historyGeneration) { const length = next.messages.length; next.messages = mergeChatMessages(page.messages, history.messages(room).filter((m: ChatMessage): boolean => (m.threadRootId ?? '') === page.threadRootId)); if (page.messages.length > length) next.before = page.before; }
    this.page = next; this.acceptSummary(next.snapshot); this.notify();
  }
  async loadTopics(more: boolean = false): Promise<void> {
    const page = this.page; if (!page || page.snapshot.room.kind !== 'group') return;
    const g = this.generation, nav = this.navigation, room = page.snapshot.room.id;
    const rows = await this.api.allMessages(room, more ? this.topicBefore : '');
    if (!this.current(g) || nav !== this.navigation) return;
    const known = mergeChatMessages(more ? this.topicRoots : [], this.cachedMessages().concat(rows));
    const rootIds = new Set<string>(); known.forEach((m: ChatMessage): void => { if (m.threadRootId) rootIds.add(m.threadRootId); if (m.replyCount) rootIds.add(m.id); });
    const roots = known.filter((m: ChatMessage): boolean => rootIds.has(m.id) && !m.threadRootId && !m.deleted);
    const missing = Array.from(rootIds).filter((id: string): boolean => !roots.some((m: ChatMessage): boolean => m.id === id)).slice(0, 40);
    for (let i = 0; i < missing.length; i += 4) {
      const found = await Promise.all(missing.slice(i, i + 4).map(async (id: string): Promise<ChatMessage | null> => {
        try { return await this.api.message(room, id); } catch (_) { return null; }
      }));
      if (!this.current(g) || nav !== this.navigation) return;
      found.forEach((m: ChatMessage | null): void => { if (m && !m.deleted && !m.threadRootId) roots.push(m); });
    }
    this.topicRoots = mergeChatMessages([], roots).reverse(); this.topicBefore = rows.length === 100 ? rows[rows.length - 1].seq : ''; this.notify();
  }
  async loadMentions(before: string = ''): Promise<void> {
    const page = this.page; if (!page) return;
    if (!this.capability('personalMentionHistory') || !this.capability('personalMask')) throw new Error('UNSUPPORTED_OPERATION');
    const g = this.generation, nav = this.navigation;
    const result = await this.api.mentions(page.snapshot.room.id, before, true);
    if (!this.current(g) || nav !== this.navigation) return;
    this.mentionMessages = mergeChatMessages(before ? this.mentionMessages : [], result.messages).reverse(); this.notify();
  }
  async locate(message: ChatMessage): Promise<void> {
    const room = this.page?.snapshot.room.id; if (!room) return;
    const g = this.generation; await this.open(room, message.threadRootId ?? '');
    if (!this.current(g) || !this.page) return;
    const fresh = await this.api.message(room, message.id);
    if (!this.current(g) || this.page?.snapshot.room.id !== room || this.page.threadRootId !== (fresh.threadRootId ?? '')) return;
    if (fresh.deleted) throw new Error('MESSAGE_UNAVAILABLE');
    this.page.messages = mergeChatMessages(this.page.messages, [fresh]); this.notify();
  }
  cachedMessages(): ChatMessage[] { return this.page && this.history ? this.history.messages(this.page.snapshot.room.id) : this.page?.snapshot.messages ?? []; }
  capability(key: string): boolean { return this.me?.capabilities?.[key] === 1; }
  private assertSend(snapshot: ChatSnapshot): void {
    if (snapshot.room.kind === 'direct') throw new Error('COMPANION_READ_ONLY');
    if (snapshot.room.archived || snapshot.room.dissolved_at) throw new Error('GROUP_CLOSED');
    if (!snapshot.members.some((m: ChatMember): boolean => m.id === this.me?.actor.id && m.state === 'joined')) throw new Error('ROLE_REQUIRED');
  }
  private persist(): Promise<void> {
    const snapshot = JSON.parse(JSON.stringify(this.pending)) as ChatPending[];
    const next = this.writeTail.catch((): void => {}).then((): Promise<void> => this.storage.write(this.owner, snapshot));
    this.writeTail = next; return next;
  }
  private coalesce(key: string, run: () => Promise<void>): Promise<void> {
    const old = this.reads.get(key); if (old) return old;
    const task = run().finally((): void => { if (this.reads.get(key) === task) this.reads.delete(key); });
    this.reads.set(key, task); return task;
  }
}
