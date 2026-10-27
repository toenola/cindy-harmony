/**
 * 模型速度档：标准 / 快速 / 超快（Codex Ultrafast，#6559）。
 *
 * 线协议事实源：`packages/device-link/src/sessionListTransport.ts` 的 encode/decodeModelSpeedPayload。
 * Host 对设置类频道做加法编码：`fastMode: 'ultrafast'` → `fastMode: true, fastModeTier: 'ultrafast'`，
 * 旧客户端只看到布尔「快速」；新客户端据 tier 还原。Harmony 读取两种形态都认，回写 Host 时与 Mobile
 * 一样直接发送 `'ultrafast'`，避免把桌面设好的超快静默降成快速。
 */
export const MODEL_SPEED_ULTRAFAST = 'ultrafast';

function tierKey(key: string): string {
  return `${key}Tier`;
}

/** 快速是否开启（超快也算开启）。 */
export function readFastEnabled(raw: Record<string, Object> | null | undefined, key: string = 'fastMode'): boolean {
  if (raw === undefined || raw === null) return false;
  const value = raw[key];
  return value === true || value === MODEL_SPEED_ULTRAFAST;
}

/** 速度档位：`'ultrafast'` 或空串（标准 / 快速由布尔决定）。 */
export function readFastTier(raw: Record<string, Object> | null | undefined, key: string = 'fastMode'): string {
  if (raw === undefined || raw === null) return '';
  const value = raw[key];
  if (value === MODEL_SPEED_ULTRAFAST) return MODEL_SPEED_ULTRAFAST;
  return value === true && raw[tierKey(key)] === MODEL_SPEED_ULTRAFAST ? MODEL_SPEED_ULTRAFAST : '';
}

/** 字段原样可接受：布尔或 `'ultrafast'`；其它类型视为非法（不当作关闭）。 */
export function isFastModeWireValue(value: Object | undefined): boolean {
  return typeof value === 'boolean' || value === MODEL_SPEED_ULTRAFAST;
}

/** 发给 Host 的值：超快发 `'ultrafast'`，其余发布尔。 */
export function fastModeWireValue(enabled: boolean, tier: string): boolean | string {
  return enabled && tier === MODEL_SPEED_ULTRAFAST ? MODEL_SPEED_ULTRAFAST : enabled;
}

/** Harmony 内部记录（缓存、合并）沿用 Host 的编码形态，旧读取方仍只看到布尔。 */
export function writeFastMode(out: Record<string, Object>, enabled: boolean, tier: string,
  key: string = 'fastMode'): void {
  out[key] = enabled;
  if (enabled && tier === MODEL_SPEED_ULTRAFAST) out[tierKey(key)] = MODEL_SPEED_ULTRAFAST;
}

/**
 * 恢复记忆的超快档前重验（对齐 Mobile isFastRestorable / agentCapabilities）：只有 Codex 且模型明确声明
 * supportsUltrafastMode 才可恢复；否则整体关闭（不是降成快速）。非超快档不受影响。
 */
export function ultrafastRestorable(tier: string, agentKind: string, supportsUltrafast: boolean): boolean {
  return tier !== MODEL_SPEED_ULTRAFAST || (agentKind === 'codex' && supportsUltrafast);
}

export function sameFastSpeed(aEnabled: boolean, aTier: string, bEnabled: boolean, bTier: string): boolean {
  return fastModeWireValue(aEnabled, aTier) === fastModeWireValue(bEnabled, bTier);
}
