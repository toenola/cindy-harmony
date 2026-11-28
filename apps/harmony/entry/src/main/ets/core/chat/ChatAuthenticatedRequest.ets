import { AuthStore } from '../auth/AuthStore';
import { HarmonyHttp, HttpMethod, HttpResponseData } from '../../network/HarmonyHttp';
import { ChatRequest, ChatHttpError } from './ChatModels';

/** Named test ports plus explicit production source unions avoid ArkTS structural conversion. */
export interface ChatCloudAuth { getAccessToken(): Promise<string | null>; forceRefreshToken(): Promise<string | null> }
export interface ChatCloudHttp {
  requestJson(url: string, method: HttpMethod, headers: Record<string, string>, body?: string, timeoutMs?: number, privateEndpoint?: boolean): Promise<HttpResponseData>;
}
export type ChatCloudAuthSource = AuthStore | ChatCloudAuth;
export type ChatCloudHttpSource = HarmonyHttp | ChatCloudHttp;
/** Endpoint comes from account/realm discovery, NEVER the selected relay or a guessed hostname. */
export function createChatAuthenticatedRequest(auth: AuthStore, endpoint: string, isCurrent: () => boolean): ChatRequest {
  return createAuthenticatedCloudRequest(auth, endpoint, '/v1/', isCurrent);
}
/** Composition root supplies a discovered Cindy Share/OSS origin; never an incoming link hostname. */
export function createAuthenticatedCloudRequest(auth: ChatCloudAuthSource, endpoint: string, prefix: string, isCurrent: () => boolean, transport: ChatCloudHttpSource = new HarmonyHttp(), timeoutMs: number = 15000): ChatRequest {
  if (prefix !== '/v1/' && prefix !== '/api/') throw new Error('INVALID_CLOUD_SERVICE');
  if (!/^https:\/\/[A-Za-z0-9.-]+(?::\d+)?(?:\/[^?#]*)?$/.test(endpoint)) throw new Error('CHAT_ENDPOINT_UNAVAILABLE');
  const base = endpoint.replace(/\/$/, ''), http = transport;
  let retryAt = 0;
  return async (path: string, method: string, body?: Object, actor?: string): Promise<Object> => {
    const check = (): void => { if (!isCurrent()) throw new Error('OWNER_CHANGED'); };
    check();
    if (!path.startsWith(prefix) || path.includes('..') || path.includes('\\')) throw new Error('INVALID_CHAT_PATH');
    if (Date.now() < retryAt) throw new ChatHttpError(429, retryAt);
    let token = await auth.getAccessToken(); check();
    if (!token) throw new Error('UNAUTHENTICATED');
    const headers: Record<string, string> = {};
    headers['Authorization'] = `Bearer ${token}`;
    if (actor) headers['X-Chat-Actor'] = actor;
    let response = await http.requestJson(`${base}${path}`, method as HttpMethod, headers,
      body === undefined ? undefined : JSON.stringify(body), timeoutMs, true);
    check();
    if (response.statusCode === 401) {
      token = await auth.forceRefreshToken(); check();
      if (!token) throw new Error('UNAUTHENTICATED');
      headers['Authorization'] = `Bearer ${token}`;
      response = await http.requestJson(`${base}${path}`, method as HttpMethod, headers,
        body === undefined ? undefined : JSON.stringify(body), timeoutMs, true); check();
    }
    if (response.statusCode === 429) retryAt = Date.now() + 5000;
    if (response.statusCode >= 300) {
      let code = '';
      try { const failure = JSON.parse(response.body) as Record<string, Object>; const detail = failure['error'] as Record<string, Object>;
        const value = detail ? detail['code'] : failure['code']; if (typeof value === 'string') code = value;
      } catch (_) {}
      throw new ChatHttpError(response.statusCode, retryAt, code);
    }
    const empty: Record<string, Object> = {};
    return response.body ? JSON.parse(response.body) as Object : empty;
  };
}
