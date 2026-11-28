import { recordOrEmpty, readStr } from '../tasks/TaskModels';
import { ResourceInvoke, ResourceClient, ResourceRequest, ResourceRawLink, ResourceRef, ResourceItem, ResourceCollection, ResourceAction, ResourceLink,
  resourceKey, resourceAllowed, resourceText, resourceError, parseResourceItem, parseResourceActions, parseResourceLinks } from './ResourceModels';

export const RESOURCE_CHANGED = 'maker:remote-resources:changed';
export class ResourceStore {
  collections: ResourceCollection[] = [];
  items: ResourceItem[] = [];
  detail: ResourceItem | null = null;
  collectionId: string = '';
  query: string = '';
  nextCursor: string = '';
  issue: string = '';
  busy: boolean = false;
  actionBusy: boolean = false;
  verified: boolean = false;
  notice: string = '';
  navigation: ResourceLink | null = null;
  private generation: number = 0;
  private actionGeneration: number = 0;
  private permissionGeneration: number = 0;
  private visible: boolean = false;
  private online: boolean = false;
  private scope: string = '';
  private deviceId: string = '';
  private locale: string = '';
  private selected: ResourceRef | null = null;
  private pending: boolean = false;
  private readGeneration: number = -1;
  private timer: number = -1;
  private operation: Promise<void> | null = null;
  private listeners: Array<() => void> = [];
  private invoke: ResourceInvoke;
  constructor(invoke: ResourceInvoke) { this.invoke = invoke; }
  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => { this.listeners = this.listeners.filter((entry: () => void): boolean => entry !== listener); };
  }
  private emit(): void { this.listeners.forEach((listener: () => void): void => listener()); }
  configure(scope: string, deviceId: string, locale: string, online: boolean): void {
    const changed = scope !== this.scope || deviceId !== this.deviceId || locale !== this.locale;
    if (changed) { this.generation++; this.permissionGeneration++; this.collections = []; this.items = []; this.detail = null; this.selected = null;
      this.nextCursor = ''; this.collectionId = ''; this.query = ''; this.issue = ''; this.navigation = null; this.notice = '';
      this.scope = scope; this.deviceId = deviceId; this.locale = locale; this.actionBusy = false; this.actionGeneration++; this.verified = false; }
    const restored = online && !this.online;
    this.online = online;
    if (!online) { this.generation++; this.permissionGeneration++; this.verified = false; this.issue = 'offline'; }
    if ((changed || restored) && this.visible && online) void this.refresh();
    this.emit();
  }
  setVisible(value: boolean): void {
    if (value === this.visible) return;
    this.visible = value; this.generation++; this.verified = false;
    if (!value) { if (this.timer >= 0) clearTimeout(this.timer); this.timer = -1; }
    else void this.refresh();
  }
  showCollections(): void {
    this.generation++; this.collectionId = ''; this.selected = null; this.detail = null; this.items = []; this.nextCursor = '';
    this.verified = false; void this.refresh();
  }
  selectCollection(id: string, query: string = ''): void {
    if (!resourceAllowed(id)) return;
    this.generation++; this.collectionId = id; this.query = query.slice(0, 1000);
    this.items = []; this.detail = null; this.selected = null; this.nextCursor = ''; this.verified = false;
    void this.refresh();
  }
  selectResource(ref: ResourceRef | null): void {
    if (ref && ref.collectionId !== this.collectionId) return;
    this.generation++; this.selected = ref; this.detail = null; this.verified = false;
    void this.refresh();
  }
  private client(): ResourceClient { return { protocolVersion: 1, primitives: ['status', 'session-link'], locale: this.locale }; }
  private valid(generation: number): boolean { return this.generation === generation && this.visible && this.online && !!this.scope && !!this.deviceId; }
  refresh(): Promise<void> {
    if (!this.visible || !this.online || !this.scope || !this.deviceId) return Promise.resolve();
    if (this.operation) { if (this.generation !== this.readGeneration) this.pending = true; return this.operation; }
    const generation = this.generation; this.readGeneration = generation;
    this.busy = true; this.issue = ''; this.emit();
    const operation = this.read(generation, '').finally((): void => {
      if (this.operation !== operation) return;
      this.operation = null; this.busy = false; this.emit();
      if (this.pending) { this.pending = false; if (this.visible && this.online) void this.refresh(); }
    });
    this.operation = operation;
    return operation;
  }
  async loadMore(): Promise<void> {
    if (this.busy || !this.nextCursor || !this.valid(this.generation)) return;
    const generation = this.generation; this.busy = true; this.emit();
    const operation = this.read(generation, this.nextCursor).finally((): void => {
      if (this.operation !== operation) return;
      this.operation = null; this.busy = false; this.emit();
      if (this.pending) { this.pending = false; void this.refresh(); }
    });
    this.operation = operation;
    await operation;
  }
  private async read(generation: number, cursor: string): Promise<void> {
    try {
      if (!this.collectionId) {
        const request: ResourceRequest = { client: this.client() };
        const raw = recordOrEmpty(await this.invoke(this.deviceId, 'maker:remote-resources:manifest', [request]));
        if (!this.valid(generation)) return;
        if (!Array.isArray(raw['collections'])) throw new Error('Invalid manifest');
        const result: ResourceCollection[] = [];
        for (const entry of (raw['collections'] as Object[]).slice(0, 128)) {
          const row = recordOrEmpty(entry), id = readStr(row, 'id'), resourceKind = readStr(row, 'resourceKind');
          const title = resourceText(row['title'], this.locale);
          if (resourceAllowed(id) && resourceKind && title) result.push({ id, resourceKind, title,
            placement: readStr(row, 'placement'), actions: parseResourceActions(row['actions'], this.locale) });
        }
        this.collections = result;
      } else if (this.selected) {
        const ref = this.selected;
        const request: ResourceRequest = { client: this.client(), ref };
        const raw = await this.invoke(this.deviceId, 'maker:remote-resources:get', [request]);
        if (!this.valid(generation)) return;
        const item = parseResourceItem(raw, ref.collectionId, this.locale);
        if (!item || resourceKey(item.ref) !== resourceKey(ref)) throw new Error('Invalid resource');
        this.detail = item;
      } else {
        const request: ResourceRequest = { client: this.client(), collectionId: this.collectionId, limit: 200 };
        if (cursor) request.cursor = cursor;
        if (this.query) request.query = this.query;
        const row = recordOrEmpty(await this.invoke(this.deviceId, 'maker:remote-resources:list', [request]));
        if (!this.valid(generation)) return;
        if (readStr(row, 'collectionId') !== this.collectionId || !Array.isArray(row['items']) || !readStr(row, 'revision')) throw new Error('Invalid list');
        const items = cursor ? this.items.slice() : [];
        for (const value of (row['items'] as Object[]).slice(0, 200)) {
          const item = parseResourceItem(value, this.collectionId, this.locale);
          if (!item) continue;
          const index = items.findIndex((candidate: ResourceItem): boolean => resourceKey(candidate.ref) === resourceKey(item.ref));
          if (index < 0) items.push(item); else items[index] = item;
        }
        this.items = items;
        const next = readStr(row, 'nextCursor');
        this.nextCursor = next.length <= 1024 && next !== cursor ? next : '';
      }
      this.verified = true;
    } catch (error) {
      if (!this.valid(generation)) return;
      this.issue = resourceError(error as Object); this.verified = false;
      if (this.issue === 'unavailable' || this.issue === 'unsupported') { this.items = []; this.detail = null; this.collections = []; this.nextCursor = ''; }
    }
  }
  handlePush(deviceId: string, channel: string, raw: Object): void {
    const row = recordOrEmpty(raw);
    if (deviceId !== this.deviceId || channel !== RESOURCE_CHANGED || (this.collectionId && readStr(row, 'collectionId') !== this.collectionId)) return;
    this.generation++; this.verified = false;
    if (!this.visible) return;
    if (this.timer >= 0) return;
    this.timer = setTimeout((): void => { this.timer = -1; void this.refresh(); }, 300);
    this.emit();
  }
  async runAction(id: string, confirmed: boolean = false): Promise<void> {
    const actions = this.detail?.actions ?? this.collections.find((row: ResourceCollection): boolean => row.id === this.collectionId)?.actions ?? [];
    const action = actions.find((entry: ResourceAction): boolean => entry.id === id);
    if (!action || !action.supported || action.disabled || this.actionBusy || !this.verified || !this.valid(this.generation)) return;
    if (action.confirmation && !confirmed) { this.issue = 'confirmation'; this.emit(); return; }
    const permissionGeneration = this.permissionGeneration;
    const scope = this.scope, deviceId = this.deviceId, collectionId = this.collectionId;
    const selectedKey = this.selected ? resourceKey(this.selected) : '';
    const writeCurrent = (): boolean => this.permissionGeneration === permissionGeneration && this.scope === scope && this.deviceId === deviceId && this.collectionId === collectionId
      && (this.selected ? resourceKey(this.selected) : '') === selectedKey && this.visible && this.online;
    const request: ResourceRequest = { client: this.client(), collectionId: this.collectionId, actionId: id };
    if (this.selected) request.resourceRef = this.selected;
    const actionGeneration = ++this.actionGeneration;
    this.actionBusy = true; this.issue = ''; this.emit();
    try {
      const response = recordOrEmpty(await this.invoke(this.deviceId, 'maker:remote-resources:invoke', [request]));
      if (!writeCurrent()) return;
      if (!Array.isArray(response['effects'])) throw new Error('Invalid action response');
      for (const value of (response['effects'] as Object[]).slice(0, 32)) {
        const effect = recordOrEmpty(value), kind = readStr(effect, 'kind');
        if (kind === 'toast') this.notice = resourceText(effect['message'], this.locale);
        if (kind === 'navigate') {
          const rawLink: ResourceRawLink = { rel: 'navigate', target: effect['target'] };
          const links = parseResourceLinks([rawLink], this.locale);
          this.navigation = links.length > 0 ? links[0] : null;
        }
      }
      this.verified = false;
      await this.refresh();
    } catch (error) {
      if (writeCurrent()) { this.issue = resourceError(error as Object); this.verified = false;
        if (this.issue === 'unavailable') { this.detail = null; this.items = []; } }
    } finally { if (this.actionGeneration === actionGeneration) { this.actionBusy = false; this.emit(); } }
  }
  // Call only after the linked task has synchronized and the visible reply was actually read.
  // Opening a details sheet alone never marks a conversation read.
  async markReadThrough(at: number): Promise<void> {
    const detail = this.detail;
    if (!detail || detail.ref.kind !== 'bot' || !detail.readSupported || !Number.isFinite(at)
      || at <= detail.lastReadAt || !this.verified || !this.valid(this.generation)) return;
    const generation = this.generation;
    try {
      const request: ResourceRequest = { client: this.client(),
        collectionId: this.collectionId, actionId: 'read', resourceRef: detail.ref, input: { at: Math.floor(at) } };
      await this.invoke(this.deviceId, 'maker:remote-resources:invoke', [request]);
      if (this.valid(generation) && this.detail === detail) { detail.lastReadAt = Math.max(detail.lastReadAt, at); this.emit(); }
    } catch (error) {
      if (this.valid(generation) && resourceError(error as Object) === 'unavailable') this.revoke();
    }
  }
  revoke(): void { this.generation++; this.permissionGeneration++; this.online = false; this.collections = []; this.items = []; this.detail = null;
    this.verified = false; this.issue = 'unavailable'; this.emit(); }
  dispose(): void { this.revoke(); this.visible = false; if (this.timer >= 0) clearTimeout(this.timer); this.timer = -1; this.listeners = []; }
}
