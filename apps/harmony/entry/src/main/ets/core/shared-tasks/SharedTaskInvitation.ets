import { SharedTaskInvitation, SharedTaskFault } from './SharedTaskModels';
const PATH = '/shared-task/join';
const TOKEN = /^[A-Za-z0-9_-]{43}$/;
export interface SharedTaskWebAddress { scheme: string; host: string; origin: string; path: string; search: string; hash: string; }
function ipv6Host(host: string): string | null {
  const address = host.slice(1, -1).toLowerCase(), compressed = address.indexOf('::');
  if (!address || address.includes('.') || compressed !== address.lastIndexOf('::')
    || (address.startsWith(':') && !address.startsWith('::')) || (address.endsWith(':') && !address.endsWith('::'))) return null;
  let groups = address.split(':').filter((part: string): boolean => part.length > 0);
  if (groups.some((part: string): boolean => !/^[0-9a-f]{1,4}$/.test(part)) || (compressed < 0 ? groups.length !== 8 : groups.length >= 8)) return null;
  if (compressed >= 0) {
    const left = address.slice(0, compressed).split(':').filter((part: string): boolean => !!part);
    const right = address.slice(compressed + 2).split(':').filter((part: string): boolean => !!part);
    const zeroes: string[] = []; for (let index = left.length + right.length; index < 8; index++) zeroes.push('0');
    groups = left.concat(zeroes, right);
  }
  groups = groups.map((part: string): string => parseInt(part, 16).toString(16));
  let start = -1, length = 0;
  for (let index = 0; index < groups.length;) {
    if (groups[index] !== '0') { index++; continue; }
    const first = index; while (index < groups.length && groups[index] === '0') index++;
    if (index - first > length && index - first >= 2) { start = first; length = index - first; }
  }
  return '[' + (start < 0 ? groups.join(':') : groups.slice(0, start).join(':') + '::' + groups.slice(start + length).join(':')) + ']';
}
/** Strict string grammar: no platform URL constructor, credentials, escaped authority or backslash normalization. */
export function parseSharedTaskWebAddress(value: string): SharedTaskWebAddress | null {
  if (!value || value.length > 8192 || /[\s\\\u0000-\u001f\u007f]/.test(value)) return null;
  const parts = /^(https?):\/\/(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(?::([0-9]{1,5}))?(\/[^?#]*)?(\?[^#]*)?(#.*)?$/i.exec(value);
  if (!parts) return null;
  const scheme = parts[1].toLowerCase(); let host = parts[2].toLowerCase();
  if (host.startsWith('[')) { const normalized = ipv6Host(host); if (!normalized) return null; host = normalized; }
  else {
    const domain = host.endsWith('.') ? host.slice(0, -1) : host;
    if (!domain || domain.length > 253 || domain.split('.').some((part: string): boolean => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(part))) return null;
    if (/^[0-9.]+$/.test(domain)) {
      const octets = domain.split('.');
      if (octets.length !== 4 || octets.some((part: string): boolean => !/^(?:0|[1-9][0-9]{0,2})$/.test(part) || Number(part) > 255)) return null;
    }
  }
  const port = parts[3] ? Number(parts[3]) : -1; if (port > 65535) return null;
  const authority = host + (port < 0 || (scheme === 'https' && port === 443) || (scheme === 'http' && port === 80) ? '' : ':' + port);
  const path = parts[4] || '/';
  if (/%(?![0-9A-Fa-f]{2})/.test(path) || path.split('/').some((part: string): boolean => /^(?:\.|%2e){1,2}$/i.test(part))) return null;
  return { scheme, host, origin: scheme + '://' + authority, path, search: parts[5] || '', hash: parts[6] || '' };
}
export function sharedTaskInvitationServer(value: string): string | null {
  const address = parseSharedTaskWebAddress(value);
  if (!address || address.search || address.hash
    || (address.scheme !== 'https' && !(address.scheme === 'http' && ['localhost', '127.0.0.1', '[::1]'].includes(address.host)))) return null;
  return address.origin + address.path.replace(/\/+$/, '');
}
/** Fixed upstream native handoff grammar. The server remains comparison metadata, never an API target. */
export function parseOfficialSharedTaskInvitationIntent(input: string): SharedTaskInvitation | null {
  if (input.length > 4096) return null;
  const parts = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(?:\?([^#]*))?$/.exec(input);
  if (!parts || !['cindy', 'cindycn', 'cindydev'].includes(parts[1].toLowerCase()) || parts[4] === undefined) return null;
  if (!(parts[2] === 'shared-task' && parts[3] === '/join') && !(parts[2] === 'shared-session' && parts[3] === '')) return null;
  const fields: Map<string, string> = new Map();
  try {
    for (const pair of parts[4].split('&')) {
      if (!pair) continue;
      const equal = pair.indexOf('=');
      const key = decodeURIComponent((equal < 0 ? pair : pair.slice(0, equal)).replace(/\+/g, ' '));
      const value = decodeURIComponent((equal < 0 ? '' : pair.slice(equal + 1)).replace(/\+/g, ' '));
      if (!['invitation', 'server'].includes(key) || fields.has(key)) return null;
      fields.set(key, value);
    }
    const invitation = fields.get('invitation') ?? '', server = sharedTaskInvitationServer(fields.get('server') ?? '');
    return fields.size === 2 && TOKEN.test(invitation) && server ? { kind: 'official', invitation, server, sharedTaskId: '' } : null;
  } catch { return null; }
}
/** The input URL only participates in comparison; it never supplies a network destination. */
export function parseOfficialSharedTaskInvitation(input: string, configuredOfficialServer: string): SharedTaskInvitation | null {
  const server = sharedTaskInvitationServer(configuredOfficialServer);
  if (!server || input.length > 8192) return null;
  const text = input.trim();
  if (TOKEN.test(text)) return { kind: 'official', invitation: text, server, sharedTaskId: '' };
  if (/^(?:cindy|cindycn|cindydev):\/\//i.test(text)) {
    const intent = parseOfficialSharedTaskInvitationIntent(text);
    if (!intent) return null;
    if (intent.server !== server) throw new SharedTaskFault('different-server');
    return intent;
  }
  const matches = text.match(/https?:\/\/(?:\[[0-9A-Fa-f:.]+\])?[^\s<>"'，。！？、（）「」“”‘’[\])]+/g) ?? [];
  const links: string[] = [];
  for (const match of matches) {
    const candidate = match.replace(/[.,;!?]+$/, '');
    // Include invitation-shaped invalid/foreign links in ambiguity counting.
    if (candidate.split(/[?#]/)[0].endsWith(PATH)) links.push(candidate);
  }
  if (links.length !== 1) return null;
  const address = parseSharedTaskWebAddress(links[0]);
  if (!address || address.search || !address.path.endsWith(PATH)) return null;
  const parts = address.hash.slice(1).split('?');
  if (parts.length > 2 || (parts.length === 2 && !/^app=(cindy|cindycn|cindydev)$/.test(parts[1])) || !TOKEN.test(parts[0])) return null;
  const source = sharedTaskInvitationServer(address.origin + address.path.slice(0, -PATH.length));
  if (!source) return null;
  if (source !== server) throw new SharedTaskFault('different-server');
  return { kind: 'official', invitation: parts[0], server, sharedTaskId: '' };
}
export function buildOfficialSharedTaskInvitation(invitation: string, configuredOfficialServer: string, app: string = 'cindy'): string {
  const server = sharedTaskInvitationServer(configuredOfficialServer);
  if (!server || !TOKEN.test(invitation) || !['cindy', 'cindycn', 'cindydev'].includes(app)) throw new SharedTaskFault('invitation');
  return server + PATH + '#' + invitation + (app === 'cindy' ? '' : '?app=' + app);
}
/** In-memory pending explicit deep link: first sign-in may claim it; switching accounts cannot. */
export class SharedTaskInvitationIntent {
  private value: SharedTaskInvitation | null = null;
  private owner: string = '';
  private deadline: number = 0;
  receive(invitation: SharedTaskInvitation, owner: string, now: number = Date.now()): void {
    this.value = invitation; this.owner = owner; this.deadline = now + 15 * 60000;
  }
  ownerChanged(owner: string, switching: boolean): void {
    if (switching || (this.owner && owner !== this.owner)) this.clear();
    else if (owner) this.owner = owner;
  }
  take(owner: string, now: number = Date.now()): SharedTaskInvitation | null {
    if (!owner || (this.owner && this.owner !== owner) || now >= this.deadline) { this.clear(); return null; }
    const value = this.value; this.clear(); return value;
  }
  clear(): void { this.value = null; this.owner = ''; this.deadline = 0; }
}
