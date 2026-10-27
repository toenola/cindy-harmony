import { readObj, readStr } from '../tasks/TaskModels';
import { deviceDisplayName } from '../tasks/DeviceDisplayName';

const MCP_APP_PLUGIN_PREFIX = 'mcp-app:';

const FORWARDED_DIALECTS: string[][] = [
  ['[Source] ', 'User’s original words:', 'Agent supplement:', '[Task source] ', 'Task ID:'],
  ['[来源] ', '用户原话：', 'Agent补充：', '[任务来源] ', '任务 ID：'],
  ['[来源] ', '用户原话：', 'agent补充：', '[任务来源] ', '任务 ID：'],
  ['[來源] ', '使用者原話：', 'Agent補充：', '[任務來源] ', '任務 ID：'],
  ['[出典] ', 'ユーザーの原文：', 'Agent の補足：', '[タスクの出典] ', 'タスク ID：'],
  ['[출처] ', '사용자 원문:', 'Agent 보충:', '[작업 출처] ', '작업 ID:'],
];

export function forwardedRequestDisplayText(body: string): string {
  if (!body.startsWith('[')) return body;
  const lines = body.split('\n');
  for (const dialect of FORWARDED_DIALECTS) {
    const offset = lines.length === 7 && lines[0].startsWith(dialect[3])
      && lines[1] === '' && lines[2].startsWith(dialect[4] + ' ') && lines[3] === '' ? 4 : 0;
    if (lines.length !== offset + 3 || !lines[offset].startsWith(dialect[0])
      || !lines[offset + 1].startsWith(dialect[1]) || !lines[offset + 2].startsWith(dialect[2])) continue;
    const quotedUser = lines[offset + 1].slice(dialect[1].length);
    const quotedAgent = lines[offset + 2].slice(dialect[2].length);
    try {
      const user = JSON.parse(quotedUser) as Object;
      const agent = JSON.parse(quotedAgent) as Object;
      if (typeof user !== 'string' || typeof agent !== 'string'
        || JSON.stringify(user) !== quotedUser || JSON.stringify(agent) !== quotedAgent) continue;
      return lines.slice(0, offset).concat([lines[offset], '', dialect[1], '', user, '', dialect[2], '', agent]).join('\n');
    } catch (_error) {
      continue;
    }
  }
  return body;
}

export class MessageSourceBadge {
  kind: string = '';
  id: string = '';
  name: string = '';
}

export function sanitizeSourceName(value: string): string {
  const cleaned = value.replace(/[\u0000-\u001f\u007f\u2028\u2029]/g, ' ')
    .replace(/[「」]/g, '"').replace(/\s+/g, ' ').trim();
  return cleaned.length > 80 ? cleaned.slice(0, 79) + '…' : cleaned;
}

export function messageSourceBadges(meta: Record<string, Object>, viewerDeviceId: string,
  deviceNames: Map<string, string>, unnamedComputer: string = '未命名电脑'): MessageSourceBadge[] {
  const result: MessageSourceBadge[] = [];
  const plugin = readObj(meta, 'sourcePlugin');
  const origin = readObj(meta, 'origin');
  if (readStr(plugin, 'pluginId').trim().length > 0) {
    const badge = new MessageSourceBadge();
    const pluginId = readStr(plugin, 'pluginId').trim();
    badge.name = sanitizeSourceName(readStr(plugin, 'name'));
    // 对齐共享 messageSourceIdEntries：MCP App 用 `mcp-app:<serverId>` 记来源，ID 只露服务器 ID。
    if (pluginId.startsWith(MCP_APP_PLUGIN_PREFIX) && pluginId.length > MCP_APP_PLUGIN_PREFIX.length) {
      badge.kind = 'mcpApp';
      badge.id = pluginId.slice(MCP_APP_PLUGIN_PREFIX.length);
      if (badge.name.length === 0) badge.name = sanitizeSourceName(badge.id);
    } else {
      badge.kind = 'plugin';
      badge.id = pluginId;
    }
    result.push(badge);
  } else if (readStr(origin, 'kind') === 'session') {
    const badge = new MessageSourceBadge();
    badge.kind = 'session';
    badge.id = readStr(origin, 'senderSessionId').trim();
    badge.name = sanitizeSourceName(readStr(origin, 'senderSessionTitle'));
    result.push(badge);
  }
  const device = readObj(meta, 'sourceDevice');
  const deviceId = readStr(device, 'deviceId').trim();
  const platform = readStr(device, 'platform');
  if (deviceId.length > 0 && deviceId !== viewerDeviceId && (platform === 'mobile' || platform === 'desktop')) {
    const badge = new MessageSourceBadge();
    badge.kind = platform;
    badge.id = deviceId;
    const sourceName = sanitizeSourceName(deviceNames.get(deviceId) ?? '')
      || sanitizeSourceName(readStr(device, 'name'));
    const safeNames = new Map<string, string>();
    deviceNames.forEach((name: string, id: string): void => {
      safeNames.set(id, sanitizeSourceName(name));
    });
    badge.name = deviceDisplayName(deviceId, sourceName, platform === 'desktop' ? unnamedComputer : '', safeNames);
    result.push(badge);
  }
  return result;
}

export function formatWorkDuration(milliseconds: number): string {
  const totalSeconds = Math.max(1, Math.round((Number.isFinite(milliseconds) ? milliseconds : 0) / 1000));
  if (totalSeconds < 60) return totalSeconds + 's';
  const minutes = Math.floor(totalSeconds / 60);
  if (minutes < 60) return totalSeconds % 60 > 0 ? minutes + 'm ' + totalSeconds % 60 + 's' : minutes + 'm';
  const days = Math.floor(totalSeconds / 86400);
  const hours = Math.floor(totalSeconds % 86400 / 3600);
  const remainder = Math.floor(totalSeconds % 3600 / 60);
  return days > 0 ? days + 'd ' + hours + 'h ' + remainder + 'm' : hours + 'h ' + remainder + 'm';
}
