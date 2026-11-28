import { REQUEST_TIMEOUT_MS } from './DlProtocol';

/**
 * Harmony 消费的慢调用预算：对齐官方 device-link allowlist.ts
 * (91179cedad)。仅延长该次请求；队列等待、心跳、重试和 peer 生命周期不变。
 */
export function resolveInvokeTimeoutMs(channel: string, explicit: number | undefined): number {
  if (explicit !== undefined && Number.isFinite(explicit) && explicit > 0) return explicit;
  if (channel === 'maker:create-session') return 120_000;
  if (channel === 'maker:compact-session') return 660_000;
  if (channel === 'maker:predict-prompt') return 45_000;
  return REQUEST_TIMEOUT_MS;
}
