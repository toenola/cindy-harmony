import { ChatCloudAuthSource, ChatCloudHttpSource, createAuthenticatedCloudRequest } from './ChatAuthenticatedRequest';
import { HarmonyHttp } from '../../network/HarmonyHttp';
import { ChatInviteShares } from './ChatInvitationStore';
import { ChatRequest, chatId } from './ChatModels';

/** shareRequest is AUTHENTICATED against discovered Share Server, not Chat Server or incoming URL. */
export class ChatInviteShareClient implements ChatInviteShares {
  private base: string;
  private region: string;
  private realm: string;
  private shareRequest: ChatRequest;
  private http: ChatCloudHttpSource;
  private current: () => boolean;
  constructor(base: string, region: string, realm: string, shareRequest: ChatRequest, current: () => boolean, http: ChatCloudHttpSource = new HarmonyHttp()) { this.base = base; this.region = region; this.realm = realm; this.shareRequest = shareRequest; this.current = current; this.http = http;
    if (!/^https:\/\/[A-Za-z0-9.-]+(?::\d+)?\/?$/.test(base) || !['cn', 'global'].includes(region) || !['cn', 'global'].includes(realm)) throw new Error('CHAT_ENDPOINT_UNAVAILABLE');
    this.base = base.replace(/\/$/, '');
  }
  async resolve(shareId: string): Promise<string> {
    this.check(); if (!/^[A-Za-z0-9_-]{32}$/.test(shareId)) throw new Error('INVALID_INVITATION_LINK');
    // Public opaque reference resolution receives no account token and never follows redirects.
    const response = await this.http.requestJson(`${this.base}/api/chat-invites/${shareId}/token`, 'POST', {}, undefined, 20000, true);
    this.check();
    if (response.statusCode === 404) throw new Error('INVITATION_NOT_FOUND');
    if (response.statusCode !== 200) throw new Error('CHAT_ENDPOINT_UNAVAILABLE');
    if (response.body.length > 8192) throw new Error('INVALID_CHAT_RESPONSE');
    const value = JSON.parse(response.body) as Record<string, Object>;
    if (typeof value['token'] !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(value['token'] as string)) throw new Error('INVALID_CHAT_RESPONSE');
    return value['token'] as string;
  }
  async create(groupId: string, token: string, actorId: string): Promise<string> {
    this.check(); if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error('INVALID_INVITATION_LINK');
    const body: Record<string, Object> = {}; body['kind'] = 'chat-invite'; body['reference'] = chatId(groupId); body['token'] = token;
    body['actorId'] = chatId(actorId); body['authRealm'] = this.realm; body['region'] = this.region;
    body['lang'] = this.region === 'cn' ? 'zh-CN' : 'en'; body['includeAttribution'] = true;
    const value = await this.shareRequest('/api/shares', 'POST', body) as Record<string, Object>;
    this.check();
    const id = value['shareId'];
    if (value['schemaVersion'] !== 1 || value['kind'] !== 'chat-invite' || value['includeAttribution'] !== true
      || typeof id !== 'string' || !/^[A-Za-z0-9_-]{32}$/.test(id) || value['url'] !== `${this.base}/chat-invite/${id}`) throw new Error('INVALID_CHAT_RESPONSE');
    return value['url'] as string;
  }
  async revoked(shareId: string): Promise<void> {
    if (!/^[A-Za-z0-9_-]{32}$/.test(shareId)) throw new Error('INVALID_INVITATION_LINK');
    for (let i=0;i<2;i++) {
      this.check();
      try { const body: Record<string,Object>={}; body['authRealm']=this.realm;
        const value=await this.shareRequest(`/api/chat-invites/${shareId}/revoked`,'POST',body) as Record<string,Object>;
        this.check(); if(value['revoked']===true) return;
      } catch (_) { if(!this.current()) return; }
    }
  }
  private check(): void { if (!this.current()) throw new Error('OWNER_CHANGED'); }
}

/** Build and account realm are deliberately distinct, matching Mobile's BUILD_AUTH_REGION rule. */
export interface ChatInviteServiceScope {
  region: string;
  realm: string;
  current: () => boolean;
  /** Optional discovered trusted Cindy Share Server origin. Never use the incoming invite host. */
  shareBaseUrl?: string;
}
/** Concrete official service factory: pass the existing AuthStore directly as auth. */
export function createOfficialChatInviteShares(auth: ChatCloudAuthSource, scope: ChatInviteServiceScope,
  http: ChatCloudHttpSource = new HarmonyHttp()): ChatInviteShareClient {
  if(!['cn','global'].includes(scope.region) || !['cn','global'].includes(scope.realm)) throw new Error('INVALID_AUTH_REALM');
  // Pinned config/endpoint.json and endpoint.global.json at 91179cedad.
  const base=scope.shareBaseUrl ?? (scope.region==='cn' ? 'https://share.cindy.com.cn' : 'https://share.cindy.app');
  const request=createAuthenticatedCloudRequest(auth,base,'/api/',scope.current,http,20000);
  return new ChatInviteShareClient(base,scope.region,scope.realm,request,scope.current,http);
}
