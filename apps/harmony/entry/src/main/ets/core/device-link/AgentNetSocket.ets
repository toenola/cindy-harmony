import { webSocket, http } from '@kit.NetworkKit';
import { util, url } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { connect, Connection, PortableHost, WireCallbacks, WireSocket } from './portable/index';
import { WsAdapter, WsCallbacks, WsMessage } from '../../network/WsAdapter';
import { HarmonyHttp, HttpMethod } from '../../network/HarmonyHttp';
import { AgentNetEngine, AgentNetEngineOptions } from './AgentNetEngine';
import { base64Url } from './AgentNetPairing';

export class AgentNetSocketConfig {
  baseUrl: string = '';
  name: string = '';
  accountId: string = '';
  rootPublicKey: string = '';
  certificate: Record<string, Object> = {};
  seed: string = '';
  relayId: string = '';
  deviceId: string = '';
}
class AgentNetMessage implements WsMessage {
  private text: string;
  constructor(text: string) { this.text = text; }
  toString(): string { return this.text; }
}
class AgentNetWire implements WireSocket {
  private socket: webSocket.WebSocket = webSocket.createWebSocket();
  private active: boolean = true;
  constructor(address: string, headers: string, callbacks: WireCallbacks) {
    this.socket.on('open', (error: BusinessError) => {
      if (this.active) { if (error) callbacks.error(); else callbacks.open(); }
    });
    this.socket.on('message', (_error: BusinessError, data: string | ArrayBuffer) => {
      if (!this.active) return;
      if (_error) { callbacks.error(); return; }
      callbacks.message(typeof data === 'string' ? data : base64Url(new Uint8Array(data)), typeof data !== 'string');
    });
    this.socket.on('error', () => { if (this.active) callbacks.error(); });
    this.socket.on('close', (_error: BusinessError, result: webSocket.CloseResult) => {
      if (this.active) callbacks.close(result.code);
    });
    const options: webSocket.WebSocketRequestOptions = {
      header: JSON.parse(headers) as Record<string, string>,
    };
    void this.socket.connect(address, options).catch(() => { if (this.active) callbacks.error(); });
  }
  send(data: string, binary: boolean): void {
    const decoded = binary ? new util.Base64Helper().decodeSync(
      data.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - data.length % 4) % 4)) : undefined;
    void this.socket.send(decoded ? decoded.buffer as ArrayBuffer : data).catch(() => {});
  }
  close(): void {
    this.active = false;
    void this.socket.close().catch(() => {});
  }
}

export class AgentNetSocket implements WsAdapter, PortableHost {
  private config: AgentNetSocketConfig;
  private guard: () => void;
  private callbacks: WsCallbacks = new WsCallbacks();
  private connection: Connection | undefined;
  private engine: AgentNetEngine | undefined;
  private active: boolean = true;

  constructor(config: AgentNetSocketConfig, guard: () => void) {
    this.config = config;
    this.guard = guard;
  }
  setCallbacks(callbacks: WsCallbacks): void { this.callbacks = callbacks; }
  connect(_url: string, _headers: Record<string, string>): void {
    void this.open().catch(() => {
      if (this.active) {
        this.destroy();
        this.callbacks.onError(new Error('AGENT_NET_CONNECTION_FAILED'));
      }
    });
  }
  private async open(): Promise<void> {
    this.check();
    const options = new AgentNetEngineOptions();
    options.seed = this.config.seed;
    options.context = this.config.relayId;
    options.deviceId = this.config.deviceId;
    this.engine = await AgentNetEngine.create(options, () => this.check());
    const connection = await connect(JSON.stringify(this.config), this);
    try {
      this.check();
      this.connection = connection;
      this.callbacks.onOpen();
    } catch (_error) {
      connection.close();
    }
  }
  check(): void {
    this.guard();
    if (!this.active) throw new Error('AGENT_NET_CONNECTION_CLOSED');
  }
  command(input: string): string {
    this.check();
    if (!this.engine) throw new Error('AGENT_NET_ENGINE_REQUIRED');
    return this.engine.command(input);
  }
  destroy(): void { this.engine?.close(); this.engine = undefined; }
  parseUrl(value: string): string {
    const parsed = url.URL.parseURL(value);
    const properties: Record<string, string> = {
      'protocol': parsed.protocol, 'hostname': parsed.hostname, 'host': parsed.host,
      'username': parsed.username, 'password': parsed.password, 'search': parsed.search,
      'hash': parsed.hash, 'pathname': parsed.pathname, 'href': parsed.href,
    };
    return JSON.stringify(properties);
  }
  sha256(encoded: string): string {
    this.check();
    const md = cryptoFramework.createMd('SHA256');
    const bytes = new util.Base64Helper().decodeSync(encoded.replace(/-/g, '+').replace(/_/g, '/')
      + '='.repeat((4 - encoded.length % 4) % 4));
    md.updateSync({ data: bytes });
    return base64Url(md.digestSync().data);
  }
  binaryRequest(address: string, method: string, headers: string, body: string, binary: boolean): Promise<string> {
    this.check();
    if (!address.startsWith(this.config.baseUrl + '/api/agent-net/')
      || !['GET', 'POST', 'PUT', 'DELETE', 'PATCH'].includes(method)) {
      return Promise.reject(new Error('AGENT_NET_ORIGIN_MISMATCH'));
    }
    return new Promise<string>((resolve, reject) => {
      const request = http.createHttp();
      const options: http.HttpRequestOptions = {
        method: method as http.RequestMethod,
        header: JSON.parse(headers) as Record<string, string>,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxRedirects: 0, connectTimeout: 15000, readTimeout: 60000,
        maxLimit: 32 * 1024 * 1024,
      };
      if (body) options.extraData = binary ? this.decode(body).buffer as ArrayBuffer : body;
      request.request(address, options, (error: BusinessError, result: http.HttpResponse) => {
        request.destroy();
        try {
          this.check();
          if (error) { reject(new Error('AGENT_NET_NETWORK_ERROR')); return; }
          const responseHeaders: Record<string, string> = {};
          const original = result.header as Record<string, Object>;
          Object.keys(original).forEach((key: string) => { responseHeaders[key] = String(original[key]); });
          const bytes = result.result instanceof ArrayBuffer
            ? new Uint8Array(result.result) : new util.TextEncoder().encodeInto(String(result.result));
          const reply: Record<string, Object> = {
            'status': result.responseCode, 'headers': responseHeaders, 'body': base64Url(bytes),
          };
          resolve(JSON.stringify(reply));
        } catch (_error) { reject(new Error('AGENT_NET_ROUTE_CHANGED')); }
      });
    });
  }
  private decode(value: string): Uint8Array {
    return new util.Base64Helper().decodeSync(value.replace(/-/g, '+').replace(/_/g, '/')
      + '='.repeat((4 - value.length % 4) % 4));
  }
  async upload(deviceId: string, bytes: ArrayBuffer, mimeType: string): Promise<string> {
    this.check();
    if (!this.connection) throw new Error('AGENT_NET_NOT_CONNECTED');
    return this.connection.upload(deviceId, base64Url(new Uint8Array(bytes)), mimeType);
  }
  async download(key: string): Promise<string> {
    this.check();
    if (!this.connection) throw new Error('AGENT_NET_NOT_CONNECTED');
    return this.connection.download(key);
  }
  async deleteMedia(key: string): Promise<void> {
    this.check();
    if (!this.connection) throw new Error('AGENT_NET_NOT_CONNECTED');
    await this.connection.deleteMedia(key);
  }
  async request(address: string, method: string, headers: string, body: string): Promise<string> {
    this.check();
    if (!address.startsWith(this.config.baseUrl + '/api/agent-net/')) throw new Error('AGENT_NET_ORIGIN_MISMATCH');
    if (!['GET', 'POST', 'PUT', 'DELETE', 'PATCH'].includes(method)) throw new Error('AGENT_NET_INVALID_METHOD');
    const response = await new HarmonyHttp().requestJson(address, method as HttpMethod,
      JSON.parse(headers) as Record<string, string>, body || undefined, 12000, true);
    this.check();
    const result: Record<string, Object> = { 'status': response.statusCode, 'body': response.body };
    return JSON.stringify(result);
  }
  socket(address: string, headers: string, callbacks: WireCallbacks): WireSocket {
    this.check();
    if (!address.startsWith(this.config.baseUrl.replace(/^http/, 'ws') + '/api/agent-net/')) {
      throw new Error('AGENT_NET_ORIGIN_MISMATCH');
    }
    return new AgentNetWire(address, headers, callbacks);
  }
  message(text: string): void {
    this.check();
    this.callbacks.onMessage(new AgentNetMessage(text));
  }
  error(): void {
    if (this.active) this.callbacks.onError(new Error('AGENT_NET_NETWORK_ERROR'));
  }
  close(code: number = 1000): void {
    const active = this.active;
    this.active = false;
    this.connection?.close();
    this.connection = undefined;
    this.destroy();
    if (active) this.callbacks.onClose(code, 'Agent-Net closed');
  }
  terminate(): void { this.close(1000); }
  send(text: string): boolean {
    try {
      this.check();
      if (!this.connection) return false;
      this.connection.send(text);
      return true;
    } catch (_error) { return false; }
  }
  async apiRequest(method: string, path: string, body: string = ''): Promise<string> {
    this.check();
    if (!this.connection) throw new Error('AGENT_NET_NOT_CONNECTED');
    return this.connection.request(method, path, body);
  }
  async directory(): Promise<string> {
    this.check();
    if (!this.connection) throw new Error('AGENT_NET_NOT_CONNECTED');
    return this.connection.directory();
  }
}
