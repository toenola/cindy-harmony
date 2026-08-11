/**
 * 鸿蒙 WebSocket 适配器（基于 @kit.NetworkKit 的 webSocket 模块）。
 *
 * 风险点（切片 0 需在真机验证）：
 * 1. wss 是否可用；
 * 2. connect 的 options.header 是否能携带 Authorization 等自定义 Header；
 * 3. 前后台切换、弱网下的 close/error 回调与 close code/reason 语义。
 *
 * 验证方式：不写过渡界面，直接调 SystemProbe.probeWs()（hilog 输出结果）。
 */

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { WsAdapter, WsCallbacks, WsMessage } from './WsAdapter';

const DOMAIN = 0x0000;
const TAG = 'CindyWs';

class WsMessageImpl implements WsMessage {
  private readonly raw: string;

  constructor(raw: string) {
    this.raw = raw;
  }

  toString(): string {
    return this.raw;
  }
}

export class HarmonyWsAdapter implements WsAdapter {
  private ws: webSocket.WebSocket | undefined = undefined;
  private callbacks: WsCallbacks = new WsCallbacks();
  private closed = false;

  setCallbacks(callbacks: WsCallbacks): void {
    this.callbacks = callbacks;
  }

  connect(url: string, headers: Record<string, string>): void {
    this.closed = false;
    const ws = webSocket.createWebSocket();
    this.ws = ws;

    ws.on('open', (err: BusinessError) => {
      if (err) {
        hilog.error(DOMAIN, TAG, 'open error: %{public}s', JSON.stringify(err));
        this.callbacks.onError(new Error(err.message));
        return;
      }
      hilog.info(DOMAIN, TAG, 'opened');
      this.callbacks.onOpen();
    });

    ws.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (err) {
        hilog.error(DOMAIN, TAG, 'message error: %{public}s', JSON.stringify(err));
        this.callbacks.onError(new Error(err.message));
        return;
      }
      if (typeof data === 'string') {
        this.callbacks.onMessage(new WsMessageImpl(data));
      } else {
        // 二进制帧：一期 Device Link 走文本帧，按 UTF-8 解码后透传。
        // 若后续协议出现大消息二进制分片，这里需要改成 ArrayBuffer 直传。
        const decoder = util.TextDecoder.create('utf-8');
        const text = decoder.decodeToString(new Uint8Array(data));
        this.callbacks.onMessage(new WsMessageImpl(text));
      }
    });

    ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      if (err) {
        hilog.error(DOMAIN, TAG, 'close error: %{public}s', JSON.stringify(err));
        this.callbacks.onError(new Error(err.message));
      }
      hilog.info(DOMAIN, TAG, 'closed code=%{public}d reason=%{public}s',
        value.code, value.reason);
      this.closed = true;
      this.callbacks.onClose(value.code, value.reason);
    });

    ws.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'error: %{public}s', JSON.stringify(err));
      // 鸿蒙 WS 的握手失败信息在 err.data（如 "401"），message 常为空——
      // 必须透传完整信息（JSON.stringify(err) 含 code/data），client 侧靠它
      // 识别鉴权失败（401/unauthorized）。
      const detail = `${err.message} ${JSON.stringify(err)}`.trim();
      this.callbacks.onError(new Error(detail.length > 0 ? detail : 'WebSocket error'));
    });

    // 风险点：header 是否生效。若真机验证不生效，需改为走 relay 的
    // token 交换通道或查询参数方案，且必须更新 decision-log。
    ws.connect(url, { header: headers });
  }

  send(data: string): boolean {
    const ws = this.ws;
    if (!ws || this.closed) {
      hilog.warn(DOMAIN, TAG, 'send on closed ws, drop');
      return false;
    }
    ws.send(data);
    return true;
  }

  close(code?: number, reason?: string): void {
    const ws = this.ws;
    if (!ws) {
      return;
    }
    ws.close({ code: code ?? 1000, reason: reason ?? '' });
  }

  terminate(): void {
    const ws = this.ws;
    if (!ws) {
      return;
    }
    // 等价于 rnWebSocket.terminate：鸿蒙无 destroy，用 close 尽力实现。
    try {
      ws.close();
    } catch (e) {
      // 已断开的 socket close 可能抛，忽略
    }
  }
}
