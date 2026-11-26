import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { HarmonyHttp } from '../../network/HarmonyHttp';
import { readNum, readObj, readStr, recordOrEmpty } from '../tasks/TaskModels';
import { AgentNetEngine, AgentNetEngineOptions } from './AgentNetEngine';
import { RelayJoinLink, normalizeRelayBaseUrl } from './RelayJoinLink';

const ID = /^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,127}$/;
const KEY = /^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/;
const POLL_TOKEN = /^[A-Za-z0-9_-]{32,128}$/;
const JOIN_TIMEOUT_MS = 10 * 60_000;

export class AgentNetMembership {
  name: string = '';
  networkId: string = '';
  seed: string = '';
  rootPublicKey: string = '';
  certificate: Record<string, Object> = {};
}

export function base64Url(data: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(data).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function readJson(text: string): Record<string, Object> {
  return recordOrEmpty(JSON.parse(text) as Object);
}

export function engineCall(engine: AgentNetEngine, command: Record<string, Object>): Object {
  const reply = readJson(engine.command(JSON.stringify(command)));
  if (reply['ok'] !== true || reply['value'] === undefined) throw new Error('AGENT_NET_ENGINE_FAILED');
  return reply['value'];
}

export async function relayPairingProof(secret: Uint8Array, payload: string): Promise<string> {
  const encoder = new util.TextEncoder();
  const generator = cryptoFramework.createSymKeyGenerator('HMAC');
  const key = await generator.convertKey({ data: secret });
  const spec: cryptoFramework.HmacSpec = { algName: 'HMAC', mdName: 'SHA256' };
  const mac = cryptoFramework.createMac(spec);
  await mac.init(key);
  await mac.update({ data: encoder.encodeInto(payload) });
  return base64Url((await mac.doFinal()).data);
}

async function pairingCode(proof: string): Promise<string> {
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data: new util.TextEncoder().encodeInto('cindy-relay-verify/1:' + proof) });
  const bytes = (await md.digest()).data;
  const value = ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) >>> 0;
  return String(value % 10_000).padStart(4, '0');
}

// Use the exact certificate payload and field order from agent-net-protocol.
function certificatePayload(cert: Record<string, Object>, now: number): string {
  const issuedAt = readNum(cert, 'issuedAt', -1);
  const expiresAt = readNum(cert, 'expiresAt', -1);
  const networkId = readStr(cert, 'networkId');
  const deviceId = readStr(cert, 'deviceId');
  const subject = readStr(cert, 'subject');
  const serial = readStr(cert, 'serial');
  const signingKey = readStr(cert, 'signingKey');
  const transportKey = readStr(cert, 'transportKey');
  if (Object.keys(cert).length !== 11 || cert['v'] !== 2 || cert['role'] !== 'member'
    || !networkId.startsWith('private:') || !ID.test(networkId) || !ID.test(deviceId)
    || !ID.test(subject) || !ID.test(serial) || !KEY.test(signingKey) || !KEY.test(transportKey)
    || !Number.isSafeInteger(issuedAt) || !Number.isSafeInteger(expiresAt)
    || issuedAt < 0 || issuedAt > now + 30_000 || expiresAt <= now || expiresAt <= issuedAt
    || !/^[A-Za-z0-9_-]{86}$/.test(readStr(cert, 'signature'))) {
    throw new Error('AGENT_NET_OWNER_MISMATCH');
  }
  return JSON.stringify(['cindy-agent-net/certificate/2', 2, networkId, subject, deviceId,
    signingKey, transportKey, 'member', issuedAt, expiresAt, serial]);
}

export class AgentNetPairing {
  private http: HarmonyHttp = new HarmonyHttp();

  // The caller owns cancellation and must guard the captured account generation on every callback.
  async join(link: RelayJoinLink, accountId: string, deviceId: string, deviceName: string,
    assertCurrent: () => void, onWaiting: (code: string) => void, seed: string = '',
    afterSubmission?: () => Promise<void>): Promise<AgentNetMembership> {
    assertCurrent();
    if (!ID.test(accountId) || !ID.test(deviceId) || !link.relayId || !link.agentNetCode
      || !link.baseUrl || normalizeRelayBaseUrl(link.baseUrl) !== link.baseUrl || !KEY.test(link.ownerPublicKey)) {
      throw new Error('AGENT_NET_INVALID_JOIN');
    }
    const binding: AgentNetEngineOptions = new AgentNetEngineOptions();
    binding.seed = seed || base64Url(cryptoFramework.createRandom().generateRandomSync(32).data);
    binding.context = link.relayId;
    binding.deviceId = deviceId;
    const engine = await AgentNetEngine.create(binding, assertCurrent);
    try {
      const identity = recordOrEmpty(engineCall(engine, { 'op': 'identity' }));
      const signingKey = readStr(identity, 'signingKey');
      const transportKey = readStr(identity, 'transportKey');
      if (readStr(identity, 'deviceId') !== deviceId || !KEY.test(signingKey) || !KEY.test(transportKey)) {
        throw new Error('AGENT_NET_IDENTITY_MISMATCH');
      }
      const networkId = 'private:' + link.relayId;
      const requestId = util.generateRandomUUID();
      const name = deviceName.trim().slice(0, 64) || 'Cindy';
      const payload = JSON.stringify(['cindy-agent-net/join/2', requestId, link.agentNetCode,
        networkId, deviceId, name, signingKey, transportKey]);
      const proof = await relayPairingProof(new util.TextEncoder().encodeInto(link.pairSecret), payload);
      const signature = engineCall(engine, { 'op': 'sign', 'text': payload });
      const submitted = await this.post(link, '/join', {
        'requestId': requestId, 'joinCode': link.agentNetCode, 'networkId': networkId, 'deviceId': deviceId,
        'name': name, 'signingKey': signingKey, 'transportKey': transportKey, 'pairingProof': proof, 'signature': signature,
      }, assertCurrent);
      const pollToken = readStr(submitted, 'pollToken');
      if (readStr(submitted, 'requestId') !== requestId || !POLL_TOKEN.test(pollToken)) throw new Error('AGENT_NET_PAIRING_FAILED');
      const code = await pairingCode(proof);
      assertCurrent();
      onWaiting(code);
      if (afterSubmission) await afterSubmission();
      const approved = await this.waitForApproval(link, networkId, requestId, pollToken, assertCurrent);
      const cert = readObj(approved, 'certificate');
      if (readStr(approved, 'rootPublicKey') !== link.ownerPublicKey
        || cert['networkId'] !== networkId || cert['subject'] !== accountId || cert['deviceId'] !== deviceId
        || cert['signingKey'] !== signingKey || cert['transportKey'] !== transportKey
        || engineCall(engine, { 'op': 'verify', 'key': link.ownerPublicKey,
          'text': certificatePayload(cert, Date.now()), 'signature': readStr(cert, 'signature') }) !== true) {
        throw new Error('AGENT_NET_OWNER_MISMATCH');
      }
      assertCurrent();
      const membership = new AgentNetMembership();
      membership.name = link.ownerName;
      membership.networkId = networkId;
      membership.seed = binding.seed;
      membership.rootPublicKey = link.ownerPublicKey;
      membership.certificate = cert;
      return membership;
    } finally {
      engine.close();
    }
  }

  private async waitForApproval(link: RelayJoinLink, networkId: string, requestId: string, pollToken: string,
    assertCurrent: () => void): Promise<Record<string, Object>> {
    const deadline = Date.now() + JOIN_TIMEOUT_MS;
    while (Date.now() < deadline) {
      await new Promise<void>((resolve): void => { setTimeout(resolve, 2000); });
      assertCurrent();
      let reply: Record<string, Object>;
      try {
        reply = await this.post(link, '/join/status', {
          'networkId': networkId, 'requestId': requestId, 'pollToken': pollToken,
        }, assertCurrent);
      } catch (error) {
        if (error instanceof Error) {
          if (error.message === 'PRIVATE_ENDPOINT_UNREACHABLE') continue;
          throw error;
        }
        throw new Error('AGENT_NET_PAIRING_FAILED');
      }
      const status = readStr(reply, 'status');
      if (status === 'approved') return reply;
      if (status !== 'pending') throw new Error(status === 'rejected' ? 'AGENT_NET_REJECTED' : 'AGENT_NET_EXPIRED');
    }
    throw new Error('AGENT_NET_EXPIRED');
  }

  private async post(link: RelayJoinLink, path: string, body: Record<string, Object>,
    assertCurrent: () => void): Promise<Record<string, Object>> {
    assertCurrent();
    const response = await this.http.requestJson(link.baseUrl + '/api/agent-net' + path, 'POST', {},
      JSON.stringify(body), 12000, true);
    assertCurrent();
    if (response.statusCode === 429) throw new Error('AGENT_NET_RATE_LIMITED');
    if (response.statusCode === 403) {
      throw new Error(path === '/join' ? 'AGENT_NET_CODE_INVALID' : 'AGENT_NET_EXPIRED');
    }
    if (response.statusCode >= 300) throw new Error('AGENT_NET_PAIRING_FAILED');
    return readJson(response.body);
  }
}
