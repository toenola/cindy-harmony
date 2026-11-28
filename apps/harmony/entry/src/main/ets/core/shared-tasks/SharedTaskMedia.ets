import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AuthStore } from '../auth/AuthStore';
import { HarmonyHttp, HttpMethod, HttpResponseData } from '../../network/HarmonyHttp';
import { AttachmentOssRef, buildAttachmentOssRef, parseAttachmentOssRef } from '../attachments/AttachmentOssRef';
import { readFileBytes } from '../attachments/ImagePreprocess';
import { sha256Hex, uploadExtForName } from '../attachments/AttachmentUpload';
import { MAX_ATTACHMENT_BYTES } from '../attachments/AttachmentModels';
import { recordOrEmpty, readStr, readNum } from '../tasks/TaskModels';
import { sharedTaskError, SharedTaskSessionTarget, SharedTaskFault } from './SharedTaskModels';
import { SharedTaskMediaPorts, SharedTaskReadyTransport } from './SharedTaskGuestClient';
import { sharedTaskInvitationServer, parseSharedTaskWebAddress } from './SharedTaskInvitation';
import { base64Url } from '../device-link/AgentNetPairing';

/** Existing system-backed OSS reference codec. Tests may replace this boundary, never the authorization route. */
export interface SharedTaskAttachmentCodec {
  encode(reference: AttachmentOssRef): string;
  decode(reference: string): AttachmentOssRef | null;
}
class NativeSharedTaskAttachmentCodec implements SharedTaskAttachmentCodec {
  encode(reference: AttachmentOssRef): string { return buildAttachmentOssRef(reference); }
  decode(reference: string): AttachmentOssRef | null { return parseAttachmentOssRef(reference); }
}
export interface SharedTaskMediaHttpPort {
  requestJson(address: string, method: HttpMethod, headers: Record<string, string>, body?: string,
    timeoutMs?: number, privateEndpoint?: boolean): Promise<HttpResponseData>;
}
export interface SharedTaskMediaOptions {
  auth: AuthStore; officialApiBase: string; scope: () => string;
  readyGuest: (peer: string) => SharedTaskReadyTransport | null;
  context: common.UIAbilityContext;
  attachmentCodec?: SharedTaskAttachmentCodec;
  http?: SharedTaskMediaHttpPort;
}
interface SharedMediaFetchRequest { url: string; prepareOnly: boolean; }
export class SharedTaskMedia implements SharedTaskMediaPorts {
  private options: SharedTaskMediaOptions;
  private base: string;
  private attachmentCodec: SharedTaskAttachmentCodec;
  private http: SharedTaskMediaHttpPort;
  private observed: Set<SharedTaskReadyTransport> = new Set();
  private paths: Map<string, string[]> = new Map();
  private active: number = 0;
  private disposed: boolean = false;
  constructor(options: SharedTaskMediaOptions) {
    const base = sharedTaskInvitationServer(options.officialApiBase); if (!base) throw new SharedTaskFault('invalid');
    this.options = options; this.base = base; this.attachmentCodec = options.attachmentCodec ?? new NativeSharedTaskAttachmentCodec();
    this.http = options.http ?? new HarmonyHttp();
  }
  private guest(target: SharedTaskSessionTarget, scope: string): SharedTaskReadyTransport {
    const guest = this.options.readyGuest(target.peer);
    if (this.disposed || !this.options.auth.isLoggedIn || scope !== this.options.scope() || !guest || !guest.scopedPort().current()
      || !target.guest || !guest.target.guest || guest.target.peer !== target.peer || guest.target.transport !== target.transport
      || guest.target.ownerAccountId !== target.ownerAccountId || guest.target.sharedTaskId !== target.sharedTaskId
      || guest.target.sessionId !== target.sessionId || guest.target.hostDeviceId !== target.hostDeviceId) throw new SharedTaskFault('ACCESS_REVOKED');
    if (!this.observed.has(guest)) {
      this.observed.add(guest);
      guest.onClosed((): void => { this.cleanup(target.peer); this.observed.delete(guest); });
    }
    return guest;
  }
  private async api(path: string, body: Object, scope: string, method: 'POST' | 'DELETE' = 'POST', current?: () => void): Promise<Record<string, Object>> {
    current?.(); const token = await this.options.auth.getAccessToken();
    if (!token || scope !== this.options.scope()) throw new SharedTaskFault('ACCESS_REVOKED'); current?.();
    const headers: Record<string, string> = {}; headers['Authorization'] = 'Bearer ' + token;
    const response = await this.http.requestJson(this.base + path, method, headers, JSON.stringify(body), 12000, true);
    if (scope !== this.options.scope()) throw new SharedTaskFault('ACCESS_REVOKED'); current?.();
    if (response.statusCode < 200 || response.statusCode >= 300) throw new SharedTaskFault('SHARED_TASK_MEDIA_REQUEST_FAILED');
    if (!response.body) { const empty: Record<string, Object> = {}; return empty; }
    return recordOrEmpty(JSON.parse(response.body) as Object);
  }
  async upload(target: SharedTaskSessionTarget, localUri: string, name: string, mime: string): Promise<string> {
    const scope = this.options.scope(); let guest = this.guest(target, scope);
    if (this.active >= 2) throw new SharedTaskFault('BACKPRESSURE'); this.active++;
    try {
      const stat = fileIo.statSync(localUri); if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_ATTACHMENT_BYTES) throw new SharedTaskFault('SHARED_TASK_ATTACHMENT_TOO_LARGE');
      const data = await readFileBytes(localUri); guest = this.guest(target, scope);
      if (data.byteLength !== stat.size) throw new SharedTaskFault('SHARED_TASK_ATTACHMENT_CHANGED');
      const sha = await sha256Hex(data); this.guest(target, scope);
      const type = mime || 'application/octet-stream'; let key = '';
      if (target.transport === 'agent-net') {
        const backend = guest.agentNetMedia; if (!backend) throw new SharedTaskFault('unsupported');
        const uploaded = recordOrEmpty(JSON.parse(await backend.upload(data.byteLength, type,
          async (offset: number, length: number): Promise<string> => { this.guest(target, scope); return base64Url(new Uint8Array(data, offset, length)); })) as Object);
        this.guest(target, scope); key = readStr(uploaded, 'key');
        if (readStr(uploaded, 'sha256') !== sha || readNum(uploaded, 'size', -1) !== data.byteLength) throw new SharedTaskFault('SHARED_TASK_ATTACHMENT_CHANGED');
      } else {
        const request: Record<string, Object> = {}; request['size'] = data.byteLength; request['contentType'] = type;
        request['ext'] = uploadExtForName(name); request['sharedTaskId'] = target.sharedTaskId;
        const presigned = await this.api('/api/device-link/media/presign-put', request, scope); this.guest(target, scope);
        key = readStr(presigned, 'key'); this.officialKey(key, target.sharedTaskId);
        const putUrl = readStr(presigned, 'putUrl'); this.https(putUrl);
        try { await this.put(putUrl, data, type, (): void => { this.guest(target, scope); }); this.guest(target, scope); }
        catch (error) {
          try { this.guest(target, scope); const cleanup: Record<string, string> = { 'key': key }; await this.api('/api/device-link/media', cleanup, scope, 'DELETE'); } catch {}
          throw sharedTaskError(error);
        }
      }
      if (!key) throw new SharedTaskFault('invalid');
      const ref = new AttachmentOssRef(); ref.ossKey = key; ref.originalName = name; ref.mimeType = type;
      ref.size = data.byteLength; ref.sha256 = sha; ref.hasIntegrity = true; return this.attachmentCodec.encode(ref);
    } finally { this.active--; }
  }
  private officialKey(key: string, task: string): void {
    const parts = key.split('/');
    if (parts.length !== 6 || parts[0] !== 'cindy' || parts[1] !== 'device-link' || parts[2] !== 'shared-task'
      || parts[3] !== task || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(parts[4])
      || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(parts[5]) || parts[5].startsWith('an3-')) throw new SharedTaskFault('SHARED_TASK_MEDIA_SCOPE_MISMATCH');
  }
  private https(address: string): void {
    const parsed = parseSharedTaskWebAddress(address);
    if (!parsed || parsed.scheme !== 'https' || parsed.hash) throw new SharedTaskFault('SHARED_TASK_MEDIA_SCOPE_MISMATCH');
  }
  private put(address: string, data: ArrayBuffer, mime: string, current: () => void): Promise<void> {
    current();
    return new Promise<void>((resolve, reject) => {
      const request = http.createHttp(); const headers: Record<string, string> = { 'Content-Type': mime, 'x-oss-object-acl': 'private' };
      const options: http.HttpRequestOptions = { method: http.RequestMethod.PUT, header: headers, extraData: data,
        maxRedirects: 0, usingCache: false, connectTimeout: 15000, readTimeout: 120000 };
      request.request(address, options, (error: BusinessError, response: http.HttpResponse): void => {
        request.destroy();
        try { current(); if (error || response.responseCode < 200 || response.responseCode >= 300) throw new SharedTaskFault('SHARED_TASK_UPLOAD_FAILED'); resolve(); }
        catch (failure) { reject(failure); }
      });
    });
  }
  async fetch(target: SharedTaskSessionTarget, reference: string): Promise<Object | undefined> {
    const scope = this.options.scope(), guest = this.guest(target, scope);
    if (this.active >= 2) throw new SharedTaskFault('BACKPRESSURE'); this.active++;
    try {
      if (/^https?:\/\//.test(reference)) {
        const parsed = parseSharedTaskWebAddress(reference);
        if (!parsed) throw new SharedTaskFault('invalid');
        const direct: Record<string, string> = { 'getUrl': reference }; return direct;
      }
      const attachment = this.attachmentCodec.decode(reference);
      let result: Record<string, Object>;
      if (attachment) {
        // Existing uploads already have an authority-controlled key. The media:fetch RPC resolves
        // host-local paths only; membership is rechecked by scoped presign or the live AN lease.
        result = {}; result['ossKey'] = attachment.ossKey; result['mimeType'] = attachment.mimeType; result['size'] = attachment.size;
      } else {
        const request: SharedMediaFetchRequest = { url: reference, prepareOnly: false };
        // Host rechecks current task history/workdir membership for local-path references.
        result = recordOrEmpty(await guest.invoke('device-link:media:fetch', [request])); this.guest(target, scope);
      }
      const inline = readStr(result, 'inlineBase64'), mime = readStr(result, 'mimeType') || 'application/octet-stream';
      if (inline) {
        if (!/^[A-Za-z0-9+/=]+$/.test(inline) || inline.length > 2 * 1024 * 1024) throw new SharedTaskFault('invalid');
        result['getUrl'] = 'data:' + mime + ';base64,' + inline; return result;
      }
      const key = readStr(result, 'ossKey'); if (!key) throw new SharedTaskFault('invalid');
      if (target.transport === 'agent-net' && (key.startsWith('agent-net-v3/') || key.split('/')[5]?.startsWith('an3-'))) {
        const backend = guest.agentNetMedia; if (!backend) throw new SharedTaskFault('unsupported');
        const directory = this.options.context.cacheDir; if (!directory) throw new SharedTaskFault('unsupported');
        const path = directory + '/cindy-shared-' + base64Url(cryptoFramework.createRandom().generateRandomSync(18).data);
        const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
        const paths = this.paths.get(target.peer) ?? []; paths.push(path); this.paths.set(target.peer, paths);
        try {
          const meta = recordOrEmpty(JSON.parse(await backend.download(key, async (encoded: string, offset: number): Promise<void> => {
            this.guest(target, scope);
            const chunk = new util.Base64Helper().decodeSync(encoded.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - encoded.length % 4) % 4));
            fileIo.writeSync(file.fd, chunk.buffer as ArrayBuffer, { offset });
          })) as Object);
          this.guest(target, scope);
          if (readNum(meta, 'size', -1) !== fileIo.statSync(file.fd).size) throw new SharedTaskFault('SHARED_TASK_DOWNLOAD_FAILED');
          result['getUrl'] = fileUri.getUriFromPath(path); result['size'] = meta['size']; result['expiresAt'] = new Date(Date.now() + 300000).toISOString(); return result;
        } catch (error) { try { fileIo.unlinkSync(path); } catch {} throw sharedTaskError(error); }
        finally { fileIo.closeSync(file); }
      }
      this.officialKey(key, target.sharedTaskId);
      const body: Record<string, string> = { 'key': key };
      const presigned = await this.api('/api/device-link/media/presign-get', body, scope); this.guest(target, scope);
      const getUrl = readStr(presigned, 'getUrl'); this.https(getUrl);
      result['getUrl'] = getUrl; result['expiresAt'] = readStr(presigned, 'expiresAt'); return result;
    } finally { this.active--; }
  }
  async delete(target: SharedTaskSessionTarget, reference: string): Promise<void> {
    const scope = this.options.scope(), guest = this.guest(target, scope);
    const current = (): void => { if (this.guest(target, scope) !== guest) throw new SharedTaskFault('ACCESS_REVOKED'); };
    if (this.active >= 2) throw new SharedTaskFault('BACKPRESSURE'); this.active++;
    try {
      const key = this.attachmentCodec.decode(reference)?.ossKey ?? reference;
      if (!key || key.length > 4096) throw new SharedTaskFault('invalid');
      const parts = key.split('/'), native = key.startsWith('agent-net-v3/') || (parts.length === 6 && parts[5].startsWith('an3-'));
      if (native) {
        if (target.transport !== 'agent-net') throw new SharedTaskFault('SHARED_TASK_MEDIA_SCOPE_MISMATCH');
        if (key.startsWith('cindy/device-link/shared-task/') && parts[3] !== target.sharedTaskId) throw new SharedTaskFault('SHARED_TASK_MEDIA_SCOPE_MISMATCH');
        if (!guest.agentNetMedia?.delete) throw new SharedTaskFault('unsupported');
        await guest.agentNetMedia.delete(key); current(); return;
      }
      this.officialKey(key, target.sharedTaskId);
      const body: Record<string, string> = { 'key': key };
      await this.api('/api/device-link/media', body, scope, 'DELETE', current); current();
    } finally { this.active--; }
  }
  cleanup(peer: string): void {
    const paths = this.paths.get(peer) ?? []; this.paths.delete(peer);
    for (const path of paths) { try { fileIo.unlinkSync(path); } catch {} }
  }
  dispose(): void { this.disposed = true; const peers: string[] = []; this.paths.forEach((_paths: string[], peer: string): void => { peers.push(peer); }); for (const peer of peers) this.cleanup(peer); }
}
export function createSharedTaskMediaPorts(options: SharedTaskMediaOptions): SharedTaskMedia { return new SharedTaskMedia(options); }
