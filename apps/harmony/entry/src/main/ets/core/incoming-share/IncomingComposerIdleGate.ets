/** Coalesce busy-to-idle notifications within one UI turn; a newer lifecycle replaces the
 * previous pending callback. The page still owns its normal restore/owner/import mutex. */
export class IncomingComposerIdleGate {
  private serial: number = 0;
  private scheduledGeneration: number = -1;
  request(generation: number, isCurrent: () => boolean, consume: () => void): void {
    if (this.scheduledGeneration === generation) return;
    const serial = ++this.serial; this.scheduledGeneration = generation;
    Promise.resolve().then((): void => {
      if (serial !== this.serial) return;
      this.scheduledGeneration = -1;
      if (isCurrent()) consume();
    });
  }
}
