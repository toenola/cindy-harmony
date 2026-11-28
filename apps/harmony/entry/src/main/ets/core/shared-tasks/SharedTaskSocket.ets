import { WsAdapter, WsCallbacks, WsMessage } from '../../network/WsAdapter';
import { SharedTaskScopeCodec } from './SharedTaskScope';
class SharedTaskText implements WsMessage {
  private text: string;
  constructor(text: string) { this.text = text; }
  toString(): string { return this.text; }
}
/** Wrap the same native socket implementation as DlClient; scope exists only at the wire boundary. */
export class SharedTaskSocket implements WsAdapter {
  private socket: WsAdapter;
  private codec: SharedTaskScopeCodec;
  private current: () => boolean;
  private failed: (error: Error) => void;
  private callbacks: WsCallbacks = new WsCallbacks();
  private active: boolean = true;
  constructor(socket: WsAdapter, codec: SharedTaskScopeCodec, current: () => boolean, failed: (error: Error) => void) {
    this.socket = socket; this.codec = codec; this.current = current; this.failed = failed;
  }
  setCallbacks(callbacks: WsCallbacks): void { this.callbacks = callbacks; }
  connect(address: string, headers: Record<string, string>): void {
    this.codec.reset();
    const callbacks = new WsCallbacks();
    callbacks.onOpen = (): void => { if (this.active && this.current()) this.callbacks.onOpen(); };
    callbacks.onMessage = (message: WsMessage): void => {
      if (!this.active || !this.current()) return;
      try { const text = this.codec.decode(message.toString()); if (text !== null) this.callbacks.onMessage(new SharedTaskText(text)); }
      catch (error) { this.failed(error instanceof Error ? error : new Error('SHARED_TASK_SOCKET_ERROR'));
        if (this.active) this.callbacks.onClose(1008, 'shared-task-scope-invalid'); this.terminate(); }
    };
    callbacks.onClose = (code: number, reason: string): void => { if (this.active && this.current()) { this.active = false; this.callbacks.onClose(code, reason); } };
    callbacks.onError = (error: Error): void => { if (this.active && this.current()) this.callbacks.onError(error); };
    this.socket.setCallbacks(callbacks);
    if (!this.current()) return;
    this.socket.connect(address, headers);
  }
  send(text: string): boolean {
    if (!this.active || !this.current()) return false;
    return this.socket.send(this.codec.encode(text));
  }
  close(code?: number, reason?: string): void { this.active = false; this.socket.close(code, reason); }
  terminate(): void { this.active = false; this.socket.terminate(); }
}
