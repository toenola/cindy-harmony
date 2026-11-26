export interface WireCallbacks {
  open(): void;
  message(data: string, binary: boolean): void;
  close(code: number): void;
  error(): void;
}
export interface WireSocket {
  send(data: string, binary: boolean): void;
  close(): void;
}
export interface PortableHost {
  parseUrl(value: string): string;
  check(): void;
  command(input: string): string;
  destroy(): void;
  sha256(base64: string): string;
  binaryRequest(url: string, method: string, headers: string, body: string, binary: boolean): Promise<string>;
  request(url: string, method: string, headers: string, body: string): Promise<string>;
  socket(url: string, headers: string, callbacks: WireCallbacks): WireSocket;
  message(text: string): void;
  close(code: number): void;
  error(): void;
}
export interface Connection {
  send(text: string): void;
  close(): void;
  directory(): Promise<string>;
  upload(deviceId: string, encoded: string, contentType: string): Promise<string>;
  download(key: string): Promise<string>;
  deleteMedia(key: string): Promise<void>;
  request(method: string, resource: string, body: string): Promise<string>;
}
export const connect: (config: string, host: PortableHost) => Promise<Connection>;
export function accountOffers(value: string): string;
export function accountBoard(value: string, now: number): string;
export function editAccountBoard(value: string, now: number, deviceId: string, requestId: string, request: string): string;
export function installUrlParser(parse: (value: string) => string, query: (value: string) => string): void;
