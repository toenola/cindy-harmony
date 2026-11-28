import { AttachmentOssRef, parseAttachmentOssRef } from './AttachmentOssRef';
import { RemoteMediaFetchResult } from './AttachmentModels';

export interface OwnedHostMediaPort {
  current: (device: string) => boolean;
  fetch: (device: string, reference: string, thumbnail: boolean, guard: () => void, skipCache: boolean) => Promise<RemoteMediaFetchResult>;
  presign: (key: string) => Promise<string>;
  remove: (key: string) => Promise<void>;
  decode?: (reference: string) => AttachmentOssRef | null;
}
/** Page-owned, bounded media lease. Original attachment objects are never deleted.
 * Only temporary objects produced by media:fetch belong to this page. */
export class OwnedHostMedia {
  private port: OwnedHostMediaPort;
  private closed: boolean = false;
  private active: number = 0;
  private temporary: Map<string, string> = new Map();
  constructor(port: OwnedHostMediaPort) { this.port = port; }
  private check(device: string): void {
    if (this.closed || !device || device.length > 128 || !this.port.current(device)) throw new Error('OWNER_CHANGED');
  }
  private release(key: string, device: string): void {
    if (this.port.current(device)) void this.port.remove(key).catch((): void => {});
  }
  async resolve(device: string, reference: string, thumbnail: boolean): Promise<string> {
    this.check(device);
    if (this.active >= 4) throw new Error('BACKPRESSURE');
    if (/^https?:\/\/[^\s\u0000-\u001f]+$/.test(reference)) return reference;
    this.active++;
    try {
      const attachment = (this.port.decode ?? parseAttachmentOssRef)(reference);
      let media: RemoteMediaFetchResult;
      if (attachment) {
        media = new RemoteMediaFetchResult(); media.ossKey = attachment.ossKey;
        media.mimeType = attachment.mimeType; media.size = attachment.size;
      } else {
        if (!/^(?:cindy-media|xdt-image|xdt-file):\/\//i.test(reference)) throw new Error('INVALID_MEDIA_REFERENCE');
        // This lease deletes temporary relay objects. The computer's upload cache
        // can still remember a deleted key from a former lease. The UI queue owns
        // deduplication; a real transfer must request a fresh temporary object.
        media = await this.port.fetch(device, reference, thumbnail, (): void => this.check(device), true);
        if (media.ossKey) {
          if (this.closed || !this.port.current(device)) { this.release(media.ossKey, device); this.check(device); }
          this.temporary.set(media.ossKey, device);
          while (this.temporary.size > 128) {
            const first = this.temporary.keys().next(); if (first.done) break;
            const owner = this.temporary.get(first.value) ?? device;
            this.temporary.delete(first.value); this.release(first.value, owner);
          }
        }
      }
      this.check(device);
      if (media.inlineBase64) {
        if (!/^image\/[A-Za-z0-9.+-]+$/.test(media.mimeType) || media.inlineBase64.length > 2 * 1024 * 1024
          || !/^[A-Za-z0-9+/=]+$/.test(media.inlineBase64)) throw new Error('INVALID_MEDIA_RESPONSE');
        return 'data:' + media.mimeType + ';base64,' + media.inlineBase64;
      }
      if (!media.ossKey) throw new Error('INVALID_MEDIA_RESPONSE');
      const result = await this.port.presign(media.ossKey); this.check(device); return result;
    } finally { this.active--; }
  }
  dispose(): void {
    if (this.closed) return; this.closed = true;
    this.temporary.forEach((device: string, key: string): void => this.release(key, device));
    this.temporary.clear();
  }
}
