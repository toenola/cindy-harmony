import { util } from '@kit.ArkTS';
import { AppConfig } from '../AppConfig';
import { AuthStore } from './auth/AuthStore';
import { SecureStore } from './storage/SecureStore';
import { createChatAuthenticatedRequest } from './chat/ChatAuthenticatedRequest';
import { ChatServerApi } from './chat/ChatServerApi';
import { ChatStore } from './chat/ChatStore';
import { ChatOutbox } from './chat/ChatOutbox';
import { ChatHistory, ChatHistoryPreferences } from './chat/ChatHistory';
import { ChatRosterPreferences } from './chat/ChatRosterCache';
import { ChatSubscription } from './chat/ChatSubscription';

/** Official account chat is independent of the selected Device Link relay. */
export class CloudChatRuntime {
  store: ChatStore | null = null;
  api: ChatServerApi | null = null;
  private auth: AuthStore;
  private storage: SecureStore;
  private generation: number = 0;
  private epoch: number = -1;
  private owner: string = '';
  private visible: boolean = false;
  private listVisible: boolean = true;
  private foreground: boolean = true;
  private socket: ChatSubscription | null = null;
  private socketScope: string = '';
  private off: (() => void) | null = null;
  private pending: Promise<ChatStore> | null = null;
  private closeTail: Promise<void> = Promise.resolve();
  private listeners: Set<() => void> = new Set();
  constructor(auth: AuthStore, storage: SecureStore) { this.auth = auth; this.storage = storage; }
  onChanged(listener: () => void): () => void {
    this.listeners.add(listener);
    return (): void => { this.listeners.delete(listener); };
  }
  private emit(): void { this.listeners.forEach((listener: () => void): void => listener()); }
  private ownerKey(): string {
    return this.auth.isLoggedIn && this.auth.cacheAccountId
      ? JSON.stringify([AppConfig.region, this.auth.cacheAccountId, AppConfig.chatApiBaseUrl]) : '';
  }
  /** Called on auth transitions; token refresh alone does not destroy retained history. */
  syncIdentity(): void {
    if (this.owner !== this.ownerKey() || this.epoch !== this.auth.sessionEpoch) this.invalidate();
  }
  private invalidate(): void {
    this.generation++;
    this.socket?.stop(); this.socket = null; this.socketScope = '';
    this.off?.(); this.off = null;
    const old = this.store;
    this.store = null; this.api = null; this.pending = null;
    this.owner = ''; this.epoch = -1;
    if (old !== null) {
      old.dispose();
      this.closeTail = this.closeTail.then((): Promise<void> => old.shutdown()).catch((): void => {});
    }
    this.emit();
  }
  async shutdown(): Promise<void> { this.invalidate(); await this.closeTail; }
  prepare(): Promise<ChatStore> {
    this.syncIdentity();
    const owner = this.ownerKey();
    if (!owner) return Promise.reject(new Error('UNAUTHENTICATED'));
    if (this.store !== null) return Promise.resolve(this.store);
    if (this.pending !== null) return this.pending;
    this.owner = owner; this.epoch = this.auth.sessionEpoch;
    const generation = this.generation;
    const epoch = this.epoch;
    const current = (): boolean => generation === this.generation
      && owner === this.ownerKey() && epoch === this.auth.sessionEpoch;
    const run = this.create(owner, current).finally((): void => { if (this.pending === run) this.pending = null; });
    this.pending = run;
    return run;
  }
  private async create(owner: string, current: () => boolean): Promise<ChatStore> {
    await this.closeTail;
    if (!current()) throw new Error('OWNER_CHANGED');
    const api = new ChatServerApi(createChatAuthenticatedRequest(this.auth, AppConfig.chatApiBaseUrl, current));
    const store = new ChatStore(owner, api, new ChatOutbox(this.storage));
    store.attachRoster(new ChatRosterPreferences(this.storage));
    store.attachHistory(new ChatHistory(owner, api, new ChatHistoryPreferences(this.storage), current,
      (): string => util.generateRandomUUID()));
    try {
      await store.restore();
      if (!current()) throw new Error('OWNER_CHANGED');
      this.store = store; this.api = api;
      this.off = store.onChanged((): void => { this.syncSocket(current); this.emit(); });
      this.syncSocket(current); this.emit();
      return store;
    } catch (failure) {
      await store.shutdown();
      throw failure instanceof Error ? failure : new Error('CHAT_UNAVAILABLE');
    }
  }
  setVisible(visible: boolean, listVisible?: boolean): void {
    this.visible = visible;
    if (listVisible !== undefined) this.listVisible = listVisible;
    const generation = this.generation;
    const owner = this.owner;
    const epoch = this.epoch;
    this.syncSocket((): boolean => generation === this.generation && owner === this.ownerKey()
      && epoch === this.auth.sessionEpoch);
  }
  setForeground(foreground: boolean): void { this.foreground = foreground; this.setVisible(this.visible); }
  private syncSocket(current: () => boolean): void {
    const store = this.store;
    const page = store?.page;
    const scope = this.visible && this.foreground && current() && store !== null && store.me !== null
      ? JSON.stringify([page?.snapshot.room.id ?? 'list', page?.threadRootId ?? '', this.listVisible]) : '';
    if (scope === this.socketScope) return;
    this.socket?.stop(); this.socket = null; this.socketScope = scope;
    if (!scope || store === null) return;
    this.socket = new ChatSubscription(store, AppConfig.chatApiBaseUrl,
      (): Promise<string | null> => this.auth.getAccessToken(), current);
    this.socket.setListVisible(this.listVisible);
    this.socket.start();
  }
}
