/** Bounded retries belong to one resource; successful siblings are never replayed. */
export class RemoteReadRetries {
  private timers: Map<string, number> = new Map();
  private attempts: Map<string, number> = new Map();

  schedule(key: string, isCurrent: () => boolean, retry: () => void): void {
    if (this.timers.has(key) || !isCurrent()) return;
    const attempt = this.attempts.get(key) ?? 0;
    if (attempt >= 3) return;
    this.attempts.set(key, attempt + 1);
    const timer = setTimeout(() => {
      this.timers.delete(key);
      if (isCurrent()) retry(); else this.cancel(key);
    }, 2000 * Math.pow(2, attempt));
    this.timers.set(key, timer);
  }

  cancel(key: string): void {
    const timer = this.timers.get(key);
    if (timer !== undefined) clearTimeout(timer);
    this.timers.delete(key);
    this.attempts.delete(key);
  }

  clear(): void {
    this.timers.forEach((timer: number) => clearTimeout(timer));
    this.timers.clear();
    this.attempts.clear();
  }
}
