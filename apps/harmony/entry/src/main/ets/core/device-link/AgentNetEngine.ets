export class AgentNetEngineOptions {
  seed: string = '';
  context: string = '';
  deviceId: string = '';
  legacySigning: boolean = true;
  udp: boolean = false;
  enhancedTransport: boolean = false;
}

export class AgentNetEngine {
  private handle: object | undefined;
  private execute: (engine: object, input: string) => string;
  private release: (engine: object) => void;
  private assertCurrent: () => void;

  private constructor(handle: object, execute: (engine: object, input: string) => string,
    release: (engine: object) => void, assertCurrent: () => void) {
    this.handle = handle;
    this.execute = execute;
    this.release = release;
    this.assertCurrent = assertCurrent;
  }

  static async create(options: AgentNetEngineOptions, assertCurrent: () => void): Promise<AgentNetEngine> {
    assertCurrent();
    const loaded = await import('libcindy_agent_net.so');
    // Harmony NAPI modules expose their exports through the dynamic import's default value.
    const native = loaded.default ?? loaded;
    if (typeof native.create !== 'function' || typeof native.command !== 'function'
      || typeof native.destroy !== 'function') throw new Error('AGENT_NET_NATIVE_EXPORTS_UNAVAILABLE');
    assertCurrent();
    const handle = native.create(JSON.stringify(options));
    return new AgentNetEngine(handle, native.command, native.destroy, assertCurrent);
  }

  command(input: string): string {
    this.assertCurrent();
    const handle = this.handle;
    if (handle === undefined) throw new Error('AGENT_NET_ENGINE_CLOSED');
    return this.execute(handle, input);
  }

  close(): void {
    const handle = this.handle;
    this.handle = undefined;
    if (handle !== undefined) this.release(handle);
  }
}
