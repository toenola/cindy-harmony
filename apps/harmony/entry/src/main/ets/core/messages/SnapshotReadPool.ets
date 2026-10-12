/** Only identical, still-current reads share an invoke. Failure never poisons retries. */
export class SnapshotReadPool<T> {
  private pending: Map<string, Promise<T>> = new Map();

  async read(key: string, isCurrent: () => boolean, invoke: () => Promise<T>): Promise<T> {
    const previous = this.pending.get(key);
    if (previous !== undefined) return previous;
    const operation = this.run(isCurrent, invoke);
    this.pending.set(key, operation);
    try { return await operation; }
    finally { if (this.pending.get(key) === operation) this.pending.delete(key); }
  }

  clear(): void { this.pending.clear(); }

  private async run(isCurrent: () => boolean, invoke: () => Promise<T>): Promise<T> {
    if (!isCurrent()) throw new Error('Remote sync superseded');
    const result = await invoke();
    if (!isCurrent()) throw new Error('Remote sync superseded');
    return result;
  }
}
