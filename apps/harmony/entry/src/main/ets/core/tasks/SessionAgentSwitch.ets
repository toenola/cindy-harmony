/**
 * 任务内跨 Agent 切换的公开契约适配。
 *
 * 被控端持有 pending intent 的唯一真相；Harmony 只展示公开投影，绝不在
 * sessions:patched 回流前伪造 RemoteSession.agentKind / model。
 */

import { RemoteSession, readBool, readStr } from './TaskModels';

export const SESSION_AGENT_KINDS: string[] = ['claude-code', 'codex', 'pi'];

export function isRuntimeRouteMutation(channel: string): boolean {
  return ['maker:set-model', 'maker:set-effort', 'maker:set-fast-mode',
    'maker:switch-session-agent'].indexOf(channel) >= 0;
}

export class SessionAgentSwitchIntent {
  targetAgentKind: string = '';
  model: string = '';
  providerId: string = '';
  hasProviderId: boolean = false;
  effort: string = '';
  fastMode: boolean = false;
  hasFastMode: boolean = false;
  agentDeviceId: string | null | undefined = undefined;
}

export function effectiveAgentDeviceId(
  session: RemoteSession | undefined,
  intent: SessionAgentSwitchIntent | null,
): string | null {
  if ((session?.remoteHostId.length ?? 0) > 0) return null;
  if (intent !== null && intent.agentDeviceId !== undefined) return intent.agentDeviceId;
  return session !== undefined && session.agentDeviceId.length > 0 ? session.agentDeviceId : null;
}

export function runtimeRouteNeedsRemoteCatalog(
  session: RemoteSession | undefined,
  intent: SessionAgentSwitchIntent | null,
): boolean {
  if ((session?.remoteHostId.length ?? 0) > 0) return false;
  return (session?.agentDeviceId.length ?? 0) > 0 || effectiveAgentDeviceId(session, intent) !== null;
}

export function agentLocationLabel(
  session: RemoteSession | undefined,
  intent: SessionAgentSwitchIntent | null,
  deviceNames: Map<string, string>,
): string {
  const deviceId = effectiveAgentDeviceId(session, intent);
  return deviceId === null ? '' : deviceNames.get(deviceId)?.trim() || deviceId;
}

/** SSH 与 Orca 会话保持单 Agent；能力未明确声明时也不展示切换入口。 */
export function supportsSessionAgentSwitch(
  session: RemoteSession | undefined,
  capabilitySupported: boolean,
): boolean {
  return session !== undefined
    && capabilitySupported
    && session.remoteHostId.length === 0
    && session.orcaRole.length === 0;
}

/** 将不可信 device-link 返回收窄成公开 intent；非法值按“无意图”处理。 */
export function parseSessionAgentSwitchIntent(value: Object | undefined): SessionAgentSwitchIntent | null {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  const raw = value as Record<string, Object>;
  const targetAgentKind = readStr(raw, 'targetAgentKind');
  if (SESSION_AGENT_KINDS.indexOf(targetAgentKind) < 0) return null;
  const model = readStr(raw, 'model');
  if (model.length === 0) return null;

  const providerValue = raw['providerId'];
  if (providerValue !== undefined && providerValue !== null && typeof providerValue !== 'string') {
    return null;
  }
  const effortValue = raw['effort'];
  if (effortValue !== undefined && typeof effortValue !== 'string') return null;
  const locationValue = raw['agentDeviceId'];
  if (locationValue !== undefined && locationValue !== null
    && (typeof locationValue !== 'string' || locationValue.length === 0)) return null;
  const fastModeValue = raw['fastMode'];
  if (fastModeValue !== undefined && typeof fastModeValue !== 'boolean') return null;

  const intent = new SessionAgentSwitchIntent();
  intent.targetAgentKind = targetAgentKind;
  intent.model = model;
  intent.providerId = typeof providerValue === 'string' ? providerValue : '';
  intent.hasProviderId = providerValue === null || typeof providerValue === 'string';
  intent.effort = typeof effortValue === 'string' ? effortValue : '';
  intent.fastMode = readBool(raw, 'fastMode', false);
  intent.hasFastMode = typeof fastModeValue === 'boolean';
  intent.agentDeviceId = locationValue === null ? null
    : typeof locationValue === 'string' ? locationValue : undefined;
  return intent;
}
