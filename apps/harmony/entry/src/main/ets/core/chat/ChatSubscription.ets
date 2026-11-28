import { WsAdapter, WsCallbacks, WsMessage } from '../../network/WsAdapter';
import { HarmonyWsAdapter } from '../../network/HarmonyWsAdapter';
import { ChatStore } from './ChatStore';
import { chatId, chatCursor, ChatDeltaBatch, ChatDelta } from './ChatModels';
interface ChatSocketCommand { type: string; token?: string; scope?: string; cursor?: string; after?: string }
interface ChatFrameError { code: string; details?: Record<string, Object> }
interface ChatFrame { type: string; actorId?: string; scope?: string; cursor?: string; changes?: ChatDelta[]; error?: ChatFrameError }
export interface ChatSubscriptionClock {
  once(run: () => void, ms: number): number;
  repeat(run: () => void, ms: number): number;
  cancelOnce(id: number): void;
  cancelRepeat(id: number): void;
}
export class ChatSystemSubscriptionClock implements ChatSubscriptionClock {
  once(run: () => void, ms: number): number { return setTimeout(run,ms); }
  repeat(run: () => void, ms: number): number { return setInterval(run,ms); }
  cancelOnce(id: number): void { clearTimeout(id); }
  cancelRepeat(id: number): void { clearInterval(id); }
}
/** One foreground chat surface owns one socket: actor scope plus at most one visible room. */
export class ChatSubscription {
  private clock: ChatSubscriptionClock;
  private store: ChatStore;
  private endpoint: string;
  private token: () => Promise<string | null>;
  private current: () => boolean;
  private createSocket: () => WsAdapter;
  private socket: WsAdapter | null = null;
  private generation: number = 0;
  private stopped: boolean = true;
  private retry: number = -1;
  private deadline: number = -1;
  private poll: number = -1;
  private listFlag: boolean | null = null;
  private delay: number = 1000;
  private queued: number = 0;
  private scopes: Map<string, string> = new Map();
  private tail: Promise<void> = Promise.resolve();
  constructor(store: ChatStore, endpoint: string, token: () => Promise<string | null>, current: () => boolean,
    createSocket: () => WsAdapter = (): WsAdapter => new HarmonyWsAdapter(), clock: ChatSubscriptionClock = new ChatSystemSubscriptionClock()) {
    this.store=store; this.endpoint=endpoint; this.token=token; this.current=current; this.createSocket=createSocket; this.clock=clock;
  }
  /** Folded detail: false; visible chat list (including expanded split view): true. */
  setListVisible(visible: boolean): void { this.listFlag = visible; if (!this.stopped) this.syncPoll(); }
  private listVisible(): boolean { return this.listFlag ?? this.store.page === null; }
  start(): void { this.stop(); this.stopped = false; this.syncPoll(); this.connect(); }
  stop(): void {
    this.stopped = true; this.generation++; this.clock.cancelOnce(this.retry); this.clock.cancelOnce(this.deadline); this.clock.cancelRepeat(this.poll);
    this.socket?.close(); this.socket = null; this.scopes.clear(); this.tail = Promise.resolve();
  }
  /** Official Mobile list reads room heads every 30s; actor events alone omit other rooms' messages. */
  private syncPoll(): void {
    this.clock.cancelRepeat(this.poll); if (!this.listVisible()) return;
    this.poll = this.clock.repeat((): void => {
      if (!this.stopped && this.current() && this.listVisible()) this.store.loadConversations(false).catch((): void => {});
    }, 30000);
  }
  private async connect(): Promise<void> {
    const g = ++this.generation;
    const live = (): boolean => !this.stopped && this.current() && g === this.generation;
    try {
      const token = await this.token(); if (!live()) return;
      if (!token) throw new Error('UNAUTHENTICATED');
      if (!/^https:\/\/[A-Za-z0-9.-]+(?::\d+)?(?:\/[^?#]*)?$/.test(this.endpoint)) throw new Error('CHAT_ENDPOINT_UNAVAILABLE');
      const socket = this.createSocket(); this.socket = socket; this.scopes.clear();
      const callbacks = new WsCallbacks();
      callbacks.onOpen = (): void => { if (live()) this.send(socket, { type: 'auth', token }); };
      callbacks.onMessage = (data: WsMessage): void => {
        if (!live()) return;
        if (this.queued >= 100) { this.schedule(g); return; } this.queued++;
        this.tail = this.tail.then(async (): Promise<void> => {
          if (!live()) return; const frame = JSON.parse(data.toString()) as ChatFrame;
          if (frame.type === 'ready') {
            const actor = chatId(frame.actorId ?? ''); this.clock.cancelOnce(this.deadline);
            // Capture the head BEFORE the initial directory read so a join during it is not missed.
            const head = await this.store.actorHead(actor); if (!live()) return;
            if (this.listVisible() || !this.store.me) await this.store.loadConversations();
            if (this.store.page) await this.store.refresh();
            if (!live()) return;
            if (this.store.me?.actor.id !== actor) throw new Error('OWNER_CHANGED');
            this.subscribe(socket, `actor:${actor}`, head);
            const page = this.store.page;
            if (page) this.subscribe(socket, `conversation:${page.snapshot.room.id}`, page.snapshot.cursor);
            this.clock.cancelOnce(this.deadline); this.delay = 1000;
          } else if (frame.type === 'changes' && frame.scope && this.scopes.has(frame.scope)) {
            const batch: ChatDeltaBatch = { cursor: chatCursor(frame.cursor ?? ''), changes: frame.changes ?? [] };
            const workOnly=batch.changes.length>0&&batch.changes.every((c:ChatDelta):boolean=>c.type==='work.available');
            if(workOnly) { /* Computers own work hints; the phone only acknowledges. */ }
            else if (frame.scope.startsWith('actor:')) await this.store.actorChanged(batch, this.listVisible());
            else if (this.store.page && frame.scope === `conversation:${this.store.page.snapshot.room.id}`) await this.store.receive(batch, this.scopes.get(frame.scope) ?? '0');
            else return;
            if (!live()) return;
            this.scopes.set(frame.scope, batch.cursor); this.send(socket, { type: 'ack', scope: frame.scope, cursor: batch.cursor });
          } else if (frame.type === 'scope_error' && frame.scope && this.scopes.has(frame.scope)) {
            if (frame.scope.startsWith('actor:')) await this.store.resetActorScope();
            else { try { await this.store.refresh(); } catch (_) { this.scopes.delete(frame.scope); return; } }
            if (!live()) return;
            const head = frame.error?.details?.['head'];
            if (frame.error?.code === 'RESET_REQUIRED' && typeof head === 'string') this.subscribe(socket, frame.scope, head);
            else this.scopes.delete(frame.scope);
          } else if (frame.type === 'error') this.schedule(g);
        }).catch((): void => { if (live()) this.schedule(g); }).finally((): void => { this.queued = Math.max(0, this.queued - 1); });
      };
      callbacks.onClose = (_code: number, _reason: string): void => { if (live()) this.schedule(g); };
      callbacks.onError = (_error: Error): void => { if (live()) this.schedule(g); };
      socket.setCallbacks(callbacks);
      this.deadline = this.clock.once((): void => { if (live()) this.schedule(g); }, 15000);
      socket.connect(`${this.endpoint.replace(/^https:/, 'wss:').replace(/\/$/, '')}/v1/ws`, {});
    } catch (_) { if (live()) this.schedule(g); }
  }
  private subscribe(socket: WsAdapter, scope: string, after: string): void {
    const cursor = chatCursor(after); this.scopes.set(scope, cursor); this.send(socket, { type: 'subscribe', scope, after: cursor });
  }
  private send(socket: WsAdapter, command: ChatSocketCommand): void { socket.send(JSON.stringify(command)); }
  private schedule(g: number): void {
    if (this.stopped || !this.current() || g !== this.generation) return;
    this.generation++; this.clock.cancelOnce(this.deadline); this.clock.cancelOnce(this.retry); this.socket?.close(); this.socket=null;
    this.retry=this.clock.once((): void => { if (!this.stopped && this.current()) this.connect(); }, Math.max(this.delay,5000)); this.delay=Math.min(this.delay*2,15000);
  }
}
