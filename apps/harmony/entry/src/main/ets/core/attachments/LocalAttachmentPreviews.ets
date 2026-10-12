/** Short-lived URI references bridge composer, queued input and persisted media. No file ownership. */
export class LocalAttachmentPreviews {
  private values: Map<string, string> = new Map();
  private key(deviceId: string, url: string): string { return JSON.stringify([deviceId, url]); }

  remember(deviceId: string, url: string, uri: string): void {
    if (!deviceId || !url || !uri) return;
    const key = this.key(deviceId, url);
    this.values.delete(key);
    this.values.set(key, uri);
    if (this.values.size > 128) {
      const oldest = this.values.keys().next();
      if (!oldest.done) this.values.delete(oldest.value);
    }
  }

  read(deviceId: string, url: string): string { return this.values.get(this.key(deviceId, url)) ?? ''; }
  release(deviceId: string, url: string): void { this.values.delete(this.key(deviceId, url)); }
  clear(): void { this.values.clear(); }
}
