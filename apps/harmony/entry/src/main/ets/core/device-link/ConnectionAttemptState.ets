export class ConnectionAttemptState {
  private deadlineWallAt: number = 0;

  arm(nowMs: number, timeoutMs: number): void {
    this.deadlineWallAt = nowMs + timeoutMs;
  }

  clear(): void {
    this.deadlineWallAt = 0;
  }

  shouldKeep(status: string, hasReconnectTimer: boolean, nowMs: number): boolean {
    return status === 'connecting' && !hasReconnectTimer && nowMs < this.deadlineWallAt;
  }
}
