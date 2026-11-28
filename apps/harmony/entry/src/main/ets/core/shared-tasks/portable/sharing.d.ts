// Pure TypeScript declarations at the JS boundary; never import ArkTS modules here.
export interface SharingWireCallbacks {
  open(): void;
  message(data: string, binary: boolean): void;
  close(code: number): void;
  error(): void;
}
export interface SharingWireSocket {
  send(data: string, binary: boolean): void;
  close(): void;
}
export interface SharingNativeHost {
  check(): void;
  command(engine: string, input: string): string;
  sha256(base64url: string): string;
  identityCard(nonce: string): Promise<string>;
  memberAuthorization(method: string, path: string, body: string): Promise<string>;
  request(address: string, method: string, headers: string, body: string, binary: boolean): Promise<string>;
  socket(address: string, headers: string, callbacks: SharingWireCallbacks): SharingWireSocket;
  message(text: string): void;
  close(code: number): void;
  error(): void;
  destroyEngine(engine: string): void;
  destroy(): void;
}
export interface AgentNetSharingConnection {
  request(path: string, method: string, body: string, timeoutMs?: number): Promise<string>;
  subject(): string;
  connect(): Promise<void>;
  deleteMedia?(key: string): Promise<void>;
  send(text: string): void;
  close(): void;
  upload(size: number, contentType: string, read: (offset: number, length: number) => Promise<string>): Promise<string>;
  download(key: string, write: (base64url: string, offset: number) => Promise<void>): Promise<string>;
}
export function parseSharingInvitation(input: string): string;
export function buildSharingInvitation(receipt: string, server: string, app: string): string;
export function createAgentNetSharing(config: string, host: SharingNativeHost): Promise<AgentNetSharingConnection>;
export function installSharingWebApis(parseUrl: (input: string) => string, queryPairs: (input: string) => string): void;

export function deleteScopedAgentNetMedia(key: string, scope: string, assertCurrent: () => void, remove: (objectId: string) => Promise<void>): Promise<void>;
