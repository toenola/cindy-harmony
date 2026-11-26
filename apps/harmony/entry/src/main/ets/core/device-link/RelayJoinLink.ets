import { url } from '@kit.ArkTS';

const JOIN_LINK = /^(?:(cindy|cindycn|cindydev):\/\/relay|\/relay)\/join\/?\?([^#]+)$/i;
const JOIN_CODE = /^[A-Za-z0-9_-]{16,256}$/;
const AGENT_NET_CODE = /^[A-Za-z0-9_-]{32}$/;
const PUBLIC_KEY = /^[A-Za-z0-9_-]{43}$/;
const ACCOUNT_TAG = /^[A-Za-z0-9_-]{22}$/;
const RELAY_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export class RelayJoinLink {
  baseUrl: string = '';
  code: string = '';
  ownerPublicKey: string = '';
  pairSecret: string = '';
  agentNetCode: string = '';
  relayId: string = '';
  tenantCode: string = '';
  ownerAccountTag: string = '';
  ownerName: string = '';
}

// Keep the same origin rules as packages/device-link/src/selfHostedRelay.ts.
export function normalizeRelayBaseUrl(value: string): string | null {
  try {
    const address = url.URL.parseURL(value.trim());
    if ((address.protocol !== 'http:' && address.protocol !== 'https:')
      || !address.hostname || address.username || address.password || address.search || address.hash) {
      return null;
    }
    const path = address.pathname.replace(/\/+$/, '');
    if (path.startsWith('/api/device-link')) return null;
    return address.protocol + '//' + address.host + path;
  } catch (_error) {
    return null;
  }
}

export function parseRelayJoinLink(value: string): RelayJoinLink | null {
  const trimmed = value.trim();
  if (trimmed.length > 2048) return null;
  const match = JOIN_LINK.exec(trimmed);
  if (!match) return null;
  const params = new url.URLParams(match[2]);
  const baseUrl = normalizeRelayBaseUrl(params.get('u') ?? '');
  const code = params.get('c') ?? null;
  const agentNetCode = params.get('a') ?? null;
  const ownerKey = params.get('o') ?? '';
  const secret = params.get('s') ?? '';
  const relayId = params.get('r') ?? '';
  const tenantCode = params.get('g') ?? null;
  const accountTag = params.get('h') ?? null;
  if (!baseUrl || !PUBLIC_KEY.test(ownerKey) || !PUBLIC_KEY.test(secret)) return null;
  if (code !== null && !JOIN_CODE.test(code)) return null;
  if (agentNetCode !== null && !AGENT_NET_CODE.test(agentNetCode)) return null;
  if (code === null && (agentNetCode === null || !RELAY_ID.test(relayId))) return null;
  if ((tenantCode === null) !== (accountTag === null)) return null;
  if (tenantCode !== null && (!AGENT_NET_CODE.test(tenantCode) || !ACCOUNT_TAG.test(accountTag ?? ''))) return null;

  const link = new RelayJoinLink();
  link.baseUrl = baseUrl;
  link.code = code ?? '';
  link.agentNetCode = agentNetCode ?? '';
  link.ownerPublicKey = ownerKey;
  link.pairSecret = secret;
  link.relayId = code === null ? relayId : '';
  link.tenantCode = tenantCode ?? '';
  link.ownerAccountTag = accountTag ?? '';
  const name = (params.get('n') ?? '').trim();
  link.ownerName = name.length <= 64 ? name : '';
  return link;
}
