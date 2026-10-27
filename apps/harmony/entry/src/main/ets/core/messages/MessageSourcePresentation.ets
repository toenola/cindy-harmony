import { readObj, readStr } from '../tasks/TaskModels';

const MCP_APP_PLUGIN_PREFIX = 'mcp-app:';

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
  deviceNames: Map<string, string>): MessageSourceBadge[] {
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
    badge.name = sanitizeSourceName(deviceNames.get(deviceId) ?? '') || sanitizeSourceName(readStr(device, 'name'));
    if (badge.name.length > 0) {
      const nameKey = badge.name.trim().toLocaleLowerCase();
      let collides = false;
      deviceNames.forEach((name: string, id: string): void => {
        if (id !== deviceId && name.trim().toLocaleLowerCase() === nameKey) collides = true;
      });
      if (collides) badge.name += ' (' + deviceId.slice(0, 6) + ')';
    }
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
