import { SharedTaskGuestTransport, SharedTaskSessionTarget, SharedTaskFault } from './SharedTaskModels';

/** Lifetime fence around the host's authenticated scoped transport. It never opens an owner link. */
export class SharedTaskAccess {
  target: SharedTaskSessionTarget;
  active: boolean = true;
  private transport: SharedTaskGuestTransport;
  private current: () => boolean;
  private unsubs: Array<() => void> = [];
  private onEnded: () => void;
  constructor(transport: SharedTaskGuestTransport, current: () => boolean, onEnded: () => void) {
    this.transport = transport; this.target = transport.target; this.current = current; this.onEnded = onEnded;
    this.unsubs.push(transport.onRevoked((): void => this.revoke()));
  }
  private assertCurrent(): void { if (!this.active || !this.current()) throw new SharedTaskFault('ACCESS_REVOKED'); }
  async invoke(channel: string, args: Object[]): Promise<Object | undefined> {
    this.assertCurrent(); const value = await this.transport.invoke(channel, args); this.assertCurrent(); return value;
  }
  subscribe(listener: (channel: string, payload: Object) => void): () => void {
    this.assertCurrent();
    const off = this.transport.subscribe((channel: string, payload: Object): void => {
      if (this.active && this.current()) listener(channel, payload);
    });
    this.unsubs.push(off);
    return (): void => { const index = this.unsubs.indexOf(off); if (index >= 0) { this.unsubs.splice(index, 1); off(); } };
  }
  async upload(localUri: string, name: string, mime: string): Promise<string> {
    this.assertCurrent(); const ref = await this.transport.upload(localUri, name, mime); this.assertCurrent(); return ref;
  }
  async fetch(reference: string): Promise<Object | undefined> {
    this.assertCurrent(); const result = await this.transport.fetch(reference); this.assertCurrent(); return result;
  }
  async delete(key: string): Promise<void> {
    this.assertCurrent();
    if (!this.transport.delete) throw new SharedTaskFault('unsupported');
    await this.transport.delete(key); this.assertCurrent();
  }
  revoke(): void { if (!this.active) return; this.close(); this.onEnded(); }
  close(): void {
    if (!this.active) return; this.active = false;
    const unsubs = this.unsubs.slice(); this.unsubs = [];
    unsubs.forEach((off: () => void): void => off()); this.transport.close();
  }
}
