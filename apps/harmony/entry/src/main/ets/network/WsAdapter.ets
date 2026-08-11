/**
 * 鸿蒙侧 WebSocket 抽象接口。
 *
 * 形态对齐 packages/device-link 的 WsLike（apps/mobile/src/device-link/rnWebSocket.ts
 * 的参考），后续 Device Link 客户端（core/device-link/）只消费本接口，
 * 不直接依赖鸿蒙 webSocket API。
 *
 * 用 WsCallbacks 回调集合替代函数重载，规避 ArkTS 对函数重载的限制。
 */

/** 消息事件载荷：与 rnWebSocket 一致，提供 toString 访问原始文本。 */
export interface WsMessage {
  toString(): string;
}

/** WebSocket 事件回调集合。默认空实现，连接前由使用方替换。 */
export class WsCallbacks {
  onOpen: () => void = () => {
  };
  onMessage: (data: WsMessage) => void = () => {
  };
  onClose: (code: number, reason: string) => void = () => {
  };
  onError: (err: Error) => void = () => {
  };
}

/** 平台 WebSocket 适配器必须实现的能力。 */
export interface WsAdapter {
  /** 建立连接。headers 用于握手阶段的 HTTP Header（如 Authorization: Bearer）。 */
  connect(url: string, headers: Record<string, string>): void;

  /** 发送文本帧；false 表示适配器在进入平台 send 前已确认连接关闭。 */
  send(data: string): boolean;

  /** 正常关闭（发 close 帧）。 */
  close(code?: number, reason?: string): void;

  /** 硬断开（释放本地资源，不保证 close 帧送达）。 */
  terminate(): void;

  /** 设置/替换事件回调。 */
  setCallbacks(callbacks: WsCallbacks): void;
}
