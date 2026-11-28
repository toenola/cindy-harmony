import { ChatServerApi } from './ChatServerApi';
import { ChatHttpError, chatId, chatError } from './ChatModels';

export interface ChatInvitationPreview {
  groupId: string; name: string; inviterName: string; joined: boolean;
  expiresAt?: string | null; reusable?: boolean; avatar?: string | null; memberCount?: number;
}
export interface ChatInviteReference { token: string; shareId: string }
export interface ChatInviteShares {
  resolve(shareId: string): Promise<string>;
  create(groupId: string, token: string, actorId: string): Promise<string>;
  revoked?(shareId: string): Promise<void>;
}
/** Port of device-link/chatInvitation.ts. An input hostname NEVER becomes an HTTP target. */
export function parseChatInviteReference(input: string): ChatInviteReference {
  if (input.length > 8192) throw new Error('INVALID_INVITATION_LINK');
  const text = input.trim();
  if (/^[A-Za-z0-9_-]{43}$/.test(text)) return { token: text, shareId: '' };
  const native = /^(?:cindy|cindycn|cindydev):\/\/chat-invite\/([A-Za-z0-9_-]{43})$/.exec(text);
  if (native) return { token: native[1], shareId: '' };
  // Only parse the canonical invitation URL grammar; never ask a platform URL shim
  // to normalize an input hostname into a network destination.
  const matches = text.match(/https?:\/\/(?:\[[0-9A-Fa-f:.]+\])?[^\s<>"'，。！？、（）「」“”‘’[\])]+/g) ?? [];
  const candidates: ChatInviteUrl[] = [];
  matches.forEach((value: string): void => {
    const parsed = canonicalInviteUrl(value.replace(/[.,;!]+$/, ''));
    if (parsed && parsed.path.startsWith('/chat-invite/')) candidates.push(parsed);
  });
  if (candidates.length !== 1) throw new Error('INVALID_INVITATION_LINK');
  const parsed = candidates[0];
  if (parsed.scheme !== 'https' && !(parsed.scheme === 'http' && ['localhost', '127.0.0.1', '[::1]'].includes(parsed.host))) throw new Error('INVALID_INVITATION_LINK');
  const share = /^\/chat-invite\/([A-Za-z0-9_-]{32})$/.exec(parsed.path);
  if (!share) throw new Error('INVALID_INVITATION_LINK');
  return { token: '', shareId: share[1] };
}
interface ChatInviteUrl { scheme: string; host: string; path: string }
function canonicalInviteUrl(value: string): ChatInviteUrl | null {
  // Username/password, query/hash, escaped authority and invalid ports are rejected.
  const parts=/^(https?):\/\/(\[[0-9A-Fa-f:.]+\]|[^\/:@?#\\\s%\[\]]+)(?::([0-9]{1,5}))?(\/[^?#]*)$/.exec(value);
  if(!parts || (parts[3] && Number(parts[3])>65535))return null;
  const host=parts[2].toLowerCase();
  if(host.startsWith('[')) {
    const address=host.slice(1,-1),compress=address.indexOf('::');
    if(compress!==address.lastIndexOf('::') || address.includes('.'))return null;
    const groups=address.split(':').filter((part:string):boolean=>part.length>0);
    if(groups.some((part:string):boolean=>!/^[0-9a-f]{1,4}$/.test(part)) || (compress>=0?groups.length>=8:groups.length!==8))return null;
  }
  return {scheme:parts[1],host,path:parts[4]};
}
/** Preview is always read-only. Accept is a separate explicit action with stable operation ID. */
export class ChatInvitationStore {
  phase: string = 'input';
  preview: ChatInvitationPreview | null = null;
  error: string = '';
  joinedRoom: string = '';
  private token: string = '';
  private operationId: string = '';
  private epoch: number = 0;
  private disposed: boolean = false;
  private listeners: Array<() => void> = [];
  readonly owner: string;
  private api: ChatServerApi;
  private shares: ChatInviteShares;
  private newId: () => string;
  private current: () => boolean;
  private now: () => number;
  constructor(owner: string, api: ChatServerApi, shares: ChatInviteShares, newId: () => string, current: () => boolean, now: () => number = (): number => Date.now()) { this.owner = owner; this.api = api; this.shares = shares; this.newId = newId; this.current = current; this.now = now;}
  onChanged(fn: () => void): () => void {
    this.listeners.push(fn); return (): void => { this.listeners = this.listeners.filter((l: () => void): boolean => l !== fn); };
  }
  private notify(): void { this.listeners.forEach((fn: () => void): void => fn()); }
  private live(epoch: number): boolean { return !this.disposed && this.current() && epoch === this.epoch; }
  async read(link: string): Promise<void> {
    if (this.phase === 'joining') return;
    const epoch = ++this.epoch;
    this.preview = null; this.token = ''; this.operationId = ''; this.joinedRoom = ''; this.phase = 'reading'; this.error = ''; this.notify();
    try {
      const ref = parseChatInviteReference(link);
      const token = ref.token || await this.shares.resolve(ref.shareId);
      if (!this.live(epoch)) return;
      if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error('INVALID_INVITATION_LINK');
      const preview = await this.api.previewInvite(token) as ChatInvitationPreview;
      if (!this.live(epoch)) return;
      if (!preview || typeof preview.name !== 'string' || typeof preview.inviterName !== 'string'
        || typeof preview.joined !== 'boolean' || (preview.expiresAt === null && preview.reusable !== true)
        || (preview.expiresAt !== undefined && preview.expiresAt !== null && !Number.isFinite(Date.parse(preview.expiresAt)))) throw new Error('INVALID_CHAT_RESPONSE');
      chatId(preview.groupId); this.token = token; this.preview = preview;
      if (!preview.joined && this.expired()) throw new Error('INVITATION_EXPIRED');
      this.phase = 'preview';
    } catch (e) { if (this.live(epoch)) { this.phase = 'error'; this.error = chatError(e); } }
    finally { if (this.live(epoch)) this.notify(); }
  }
  expired(): boolean { return !!this.preview?.expiresAt && Date.parse(this.preview.expiresAt) <= this.now(); }
  async accept(): Promise<void> {
    if (!this.preview || !this.token || this.phase === 'joining' || this.disposed || !this.current()) return;
    const uncertain = this.phase === 'uncertain';
    if (!uncertain && this.expired() && !this.preview.joined) { this.phase = 'error'; this.error = 'INVITATION_EXPIRED'; this.notify(); return; }
    const epoch = this.epoch;
    if (this.preview.joined) { this.joinedRoom = this.preview.groupId; this.phase = 'joined'; this.notify(); return; }
    this.operationId = this.operationId || this.newId(); this.phase = 'joining'; this.error = ''; this.notify();
    try {
      const room = await this.api.join(this.token, this.operationId);
      if (!this.live(epoch)) return;
      this.joinedRoom = room; this.phase = 'joined';
    } catch (e) {
      if (!this.live(epoch)) return;
      this.error = chatError(e);
      this.phase = e instanceof ChatHttpError && e.status >= 400 && e.status < 500 && e.status !== 408 ? 'error' : 'uncertain';
    } finally { if (this.live(epoch)) this.notify(); }
  }
  dispose(): void {
    this.epoch++; this.disposed = true; this.preview = null; this.token = ''; this.operationId = ''; this.joinedRoom = ''; this.phase = 'input'; this.notify(); this.listeners = [];
  }
}
