import { readStr, recordOrEmpty } from '../tasks/TaskModels';
import { OwnedHostMedia } from '../attachments/OwnedHostMedia';
import { WorkdirRequest } from './WorkdirFiles';

export function workdirPreviewKind(path: string): string {
  if (/\.(drawio(?:\.svg)?|dio)$/i.test(path)) return 'drawio';
  if (/\.html?$/i.test(path)) return 'html';
  if (/\.(glb|gltf)$/i.test(path)) return 'model';
  if (/\.(png|jpe?g|gif|webp|bmp|heic|svg|avif)$/i.test(path)) return 'image';
  if (/\.(mp4|mov|m4v|webm)$/i.test(path)) return 'video';
  if (/\.(mp3|m4a|wav|aac|ogg|flac)$/i.test(path)) return 'audio';
  if (/\.(md|markdown|mdx)$/i.test(path)) return 'markdown';
  if (/\.(mmd|mermaid)$/i.test(path)) return 'mermaid';
  if (/\.pdf$/i.test(path)) return 'pdf';
  if (/\.(zip|rar|7z|exe|bin|docx?|xlsx?|pptx?)$/i.test(path)) return 'unsupported';
  return 'text';
}

export class WorkdirPreviewMedia {
  private media: OwnedHostMedia;
  private device: string;
  private root: string;
  private call: (request: WorkdirRequest, current: () => boolean) => Promise<Object | undefined>;
  private capabilityCache: Record<string, Object> | undefined;
  private capabilityRequest: Promise<Record<string, Object>> | undefined;
  private keys: Map<string, string> = new Map();

  constructor(media: OwnedHostMedia, device: string, root: string,
    call: (request: WorkdirRequest, current: () => boolean) => Promise<Object | undefined>) {
    this.media = media;
    this.device = device;
    this.root = root;
    this.call = call;
  }

  async url(path: string, modified: number, current: () => boolean, maxBytes?: number): Promise<string> {
    if (!current()) throw new Error('OWNER_CHANGED');
    const key = JSON.stringify([path, modified]);
    let reference = maxBytes === undefined ? (this.keys.get(key) ?? '') : '';
    if (!reference) {
      const result = recordOrEmpty(await this.call(new WorkdirRequest('fileUrl', this.root, path), current));
      if (maxBytes !== undefined && (typeof result['size'] !== 'number' ||
        Number(result['size']) > maxBytes)) throw new Error('FILE_PREVIEW_TOO_LARGE');
      reference = readStr(result, 'url');
      if (result['ok'] !== true || !/^xdt-file:\/\//i.test(reference)) throw new Error('FILE_REFERENCE_UNAVAILABLE');
      this.keys.set(key, reference);
      if (this.keys.size > 24) this.keys.delete(this.keys.keys().next().value as string);
    }
    if (!current()) throw new Error('OWNER_CHANGED');
    const url = await this.media.resolve(this.device, reference, false);
    if (!current()) throw new Error('OWNER_CHANGED');
    return url;
  }

  async capabilities(current: () => boolean): Promise<Record<string, Object>> {
    if (!current()) throw new Error('OWNER_CHANGED');
    if (this.capabilityCache !== undefined) return this.capabilityCache;
    const pending = this.capabilityRequest;
    if (pending !== undefined) return await pending;
    const run = this.call(new WorkdirRequest('caps', this.root), current)
      .then((value: Object | undefined): Record<string, Object> => recordOrEmpty(value))
      .catch((error: Error): Record<string, Object> => {
        if (!/unknown op|CHANNEL_NOT_ALLOWED/i.test(String(error))) throw error;
        return recordOrEmpty(undefined);
      });
    this.capabilityRequest = run;
    try {
      const caps = await run;
      if (!current()) throw new Error('OWNER_CHANGED');
      this.capabilityCache = caps;
      return caps;
    } finally {
      if (this.capabilityRequest === run) this.capabilityRequest = undefined;
    }
  }

  // Only explicit export can start an old host upload. No background polling
  // for preview thumbnails or for folders, and no retry of exportFileStart.
  async exportUrl(path: string, modified: number, current: () => boolean,
    resolve: (key: string) => Promise<string>, release: (key: string) => void): Promise<string> {
    if (!current()) throw new Error('OWNER_CHANGED');
    const caps = await this.capabilities(current);
    if (caps['fileRead'] === true) return this.url(path, modified, current);
    const start = recordOrEmpty(await this.call(new WorkdirRequest('exportFileStart', this.root, path), current));
    const transferId = readStr(start, 'transferId');
    if (start['ok'] !== true || !transferId) throw new Error('FILE_EXPORT_FAILED');
    const deadline = Date.now() + 120000;
    while (current() && Date.now() < deadline) {
      const request = new WorkdirRequest('exportFileStatus', this.root);
      request.transferId = transferId;
      const status = recordOrEmpty(await this.call(request, current));
      const state = readStr(status, 'state');
      const key = readStr(status, 'key');
      if (state === 'done' && key) {
        if (!current()) { release(key); throw new Error('OWNER_CHANGED'); }
        return await resolve(key);
      }
      if (status['ok'] !== true || state === 'error') throw new Error('FILE_EXPORT_FAILED');
      await new Promise<void>((done: () => void): void => { setTimeout(done, 1000); });
    }
    throw new Error('FILE_EXPORT_STOPPED');
  }

  dispose(): void {
    this.keys.clear();
    this.media.dispose();
  }
}
