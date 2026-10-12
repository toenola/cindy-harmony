import { DlError } from './DlProtocol';

const MAX_ACTIVE = 12;
const MAX_BACKGROUND_ACTIVE = 4;
const MAX_QUEUED = 128;
const MAX_BACKGROUND_QUEUED = 96;

const BACKGROUND_INVOKE_CHANNELS: string[] = [
  'git-context:pr-refs:list',
  'git-context:pr-status',
  'maker:schedule:list-sidebar-index-runs',
  'maker:usage:device-rows',
  'maker:session-background-activity',
  'maker:session-background-tasks:list',
];

export function isBackgroundInvoke(channel: string): boolean {
  return BACKGROUND_INVOKE_CHANNELS.indexOf(channel) >= 0;
}

export function bypassInvokeScheduling(channel: string, args: Object[]): boolean {
  if (channel === 'device-link:subscribe' || channel === 'device-link:unsubscribe') return true;
  const request = args.length > 0 ? args[0] : undefined;
  return channel === 'device-link:remote-desktop:v1' && request !== undefined && request !== null
    && typeof request === 'object' && !Array.isArray(request)
    && (request as Record<string, Object>)['op'] === 'heartbeat';
}

export function invokePhysicalPeerId(peerId: string): string {
  if (peerId.length <= 128 || peerId.length > 2048) return peerId;
  try {
    const parsed: Object = JSON.parse(peerId.replace(/~+$/, '')) as Object;
    if (!Array.isArray(parsed)) return peerId;
    const parts = parsed as Object[];
    if (parts.length !== 4 || typeof parts[0] !== 'string'
      || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(parts[0] as string)
      || typeof parts[3] !== 'string' || (parts[3] as string).length < 1
      || (parts[3] as string).length > 128) return peerId;
    if (parts[1] === 'host') {
      if (parts[2] !== null) return peerId;
    } else if (parts[1] === 'guest') {
      if (typeof parts[2] !== 'string'
        || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(parts[2] as string)) return peerId;
    } else {
      return peerId;
    }
    return JSON.stringify(parts).padEnd(129, '~') === peerId ? parts[3] as string : peerId;
  } catch (_error) {
    return peerId;
  }
}

class InvokeJob {
  peerId: string = '';
  background: boolean = false;
  start: () => void = () => {};
  cancel: (error: DlError) => void = (_error: DlError) => {};
}

class PeerQueue {
  active: number = 0;
  background: number = 0;
  jobs: InvokeJob[] = [];
}

export class InvokeScheduler {
  private peers: Map<string, PeerQueue> = new Map();
  private now: () => number;

  constructor(now: () => number = () => Date.now()) {
    this.now = now;
  }

  run<T>(peerId: string, background: boolean, waitMs: number, run: () => Promise<T>): Promise<T> {
    const deviceId = invokePhysicalPeerId(peerId);
    let peer = this.peers.get(deviceId);
    if (peer === undefined) {
      peer = new PeerQueue();
      this.peers.set(deviceId, peer);
    }
    const state = peer;
    if (state.jobs.length >= (background ? MAX_BACKGROUND_QUEUED : MAX_QUEUED)) {
      return Promise.reject(new DlError('BACKPRESSURE', 'local remote invoke queue is full'));
    }
    return new Promise<T>((resolve, reject) => {
      const queuedAt = this.now();
      const job = new InvokeJob();
      let timer: number = -1;
      job.peerId = peerId;
      job.background = background;
      job.cancel = (error: DlError): void => {
        if (timer >= 0) clearTimeout(timer);
        reject(new DlError(error.code, error.message));
      };
      job.start = (): void => {
        if (timer >= 0) clearTimeout(timer);
        if (this.now() - queuedAt >= waitMs) {
          reject(new DlError('BACKPRESSURE', 'remote invoke expired before dispatch'));
          return;
        }
        state.active += 1;
        if (background) state.background += 1;
        let result: Promise<T>;
        try {
          result = run();
        } catch (error) {
          result = Promise.reject(error);
        }
        void result.then(resolve, reject).finally(() => {
          state.active -= 1;
          if (background) state.background -= 1;
          this.drain(deviceId, state);
        });
      };
      timer = setTimeout(() => {
        const index = state.jobs.indexOf(job);
        if (index < 0) return;
        state.jobs.splice(index, 1);
        job.cancel(new DlError('BACKPRESSURE', 'remote invoke expired before dispatch'));
        this.drain(deviceId, state);
      }, waitMs);
      state.jobs.push(job);
      this.drain(deviceId, state);
    });
  }

  cancel(peerId: string, error: DlError): void {
    const deviceId = invokePhysicalPeerId(peerId);
    const state = this.peers.get(deviceId);
    if (state === undefined) return;
    const cancelled = state.jobs.filter((job: InvokeJob) => job.peerId === peerId);
    state.jobs = state.jobs.filter((job: InvokeJob) => job.peerId !== peerId);
    for (const job of cancelled) job.cancel(error);
    this.drain(deviceId, state);
  }

  clear(error: DlError): void {
    this.peers.forEach((state: PeerQueue, peerId: string) => {
      for (const job of state.jobs.splice(0)) job.cancel(error);
      this.drain(peerId, state);
    });
  }

  private drain(peerId: string, state: PeerQueue): void {
    while (state.active < MAX_ACTIVE && state.jobs.length > 0) {
      let index = state.jobs.findIndex((job: InvokeJob) => !job.background);
      if (index < 0) {
        if (state.background >= MAX_BACKGROUND_ACTIVE) break;
        index = 0;
      }
      state.jobs.splice(index, 1)[0].start();
    }
    if (state.active === 0 && state.jobs.length === 0) this.peers.delete(peerId);
  }
}
