import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AppConfig } from '../../AppConfig';
import { HarmonyHttp, HttpResponseData } from '../../network/HarmonyHttp';
import { readNum, readObj, readStr, recordOrEmpty } from '../tasks/TaskModels';
import { AgentNetEngine, AgentNetEngineOptions } from './AgentNetEngine';
import { base64Url, engineCall, relayPairingProof } from './AgentNetPairing';
import { RelayJoinLink, normalizeRelayBaseUrl } from './RelayJoinLink';

const BASE64URL_KEY = /^[A-Za-z0-9_-]{43}$/;
const BASE64URL_SIGNATURE = /^[A-Za-z0-9_-]{86}$/;
const ID = /^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,127}$/;
const POLL_TOKEN = /^[A-Za-z0-9_-]{32,128}$/;
const API = '/api/device-link/relay';
const APPROVAL_MS = 10 * 60_000;

export class LegacyRelayMembership {
  relayId: string = '';
  name: string = '';
  baseUrl: string = '';
  deviceId: string = '';
  ownerPublicKey: string = '';
  credential: string = '';
  seed: string = '';
}

export class LegacyRelayPairing {
  private http: HarmonyHttp = new HarmonyHttp();

  async join(link: RelayJoinLink, accountId: string, deviceId: string, deviceName: string,
    assertCurrent: () => void, onWaiting: (code: string) => void, seed: string = ''): Promise<LegacyRelayMembership> {
    assertCurrent();
    if (!/^[A-Za-z0-9_-]{16,256}$/.test(link.code) || !BASE64URL_KEY.test(link.ownerPublicKey)
      || !BASE64URL_KEY.test(link.pairSecret) || !accountId || !ID.test(deviceId)
      || !link.baseUrl || normalizeRelayBaseUrl(link.baseUrl) !== link.baseUrl) {
      throw new Error('RELAY_INVALID_JOIN');
    }
    const infoResponse = await this.http.requestJson(link.baseUrl + API + '/info', 'GET', {}, undefined, 12000, true);
    assertCurrent();
    const info = this.body(infoResponse.body);
    const relayId = readStr(info, 'relayId');
    const name = readStr(info, 'name');
    const features = info['features'];
    if (infoResponse.statusCode !== 200 || !ID.test(relayId) || !name || info['protocolVersion'] !== 1
      || !Array.isArray(features) || !features.includes('pairing-v1') || !features.includes('device-signatures-v1')) {
      throw new Error('RELAY_INCOMPATIBLE');
    }
    const options = new AgentNetEngineOptions();
    options.seed = seed || base64Url(cryptoFramework.createRandom().generateRandomSync(32).data);
    options.context = relayId;
    options.deviceId = deviceId;
    const engine = await AgentNetEngine.create(options, assertCurrent);
    try {
      const identity = recordOrEmpty(engineCall(engine, { 'op': 'identity' }));
      const key = readStr(identity, 'signingKey');
      if (readStr(identity, 'deviceId') !== deviceId || !BASE64URL_KEY.test(key)) {
        throw new Error('RELAY_IDENTITY_MISMATCH');
      }
      const encodedSecret = link.pairSecret.replace(/-/g, '+').replace(/_/g, '/') + '=';
      const secret = new util.Base64Helper().decodeSync(encodedSecret);
      if (secret.length !== 32) throw new Error('RELAY_INVALID_JOIN');
      const proof = await relayPairingProof(secret, JSON.stringify(['cindy-relay-pair/1', relayId, deviceId, key]));
      assertCurrent();
      const submitted = await this.http.requestJson(link.baseUrl + API + '/pair', 'POST', {}, JSON.stringify({
        code: link.code, deviceId, deviceName: deviceName.trim().slice(0, 64) || 'Cindy',
        platform: AppConfig.platform, appVersion: AppConfig.appVersion, accountUserId: accountId,
        publicKey: key, proof: proof,
      }), 12000, true);
      assertCurrent();
      if (submitted.statusCode === 429) throw new Error('RELAY_RATE_LIMITED');
      const reply = this.body(submitted.body);
      if (readStr(readObj(reply, 'error'), 'code') === 'ACCOUNT_MISMATCH') throw new Error('RELAY_ACCOUNT_MISMATCH');
      if (submitted.statusCode === 403) throw new Error('RELAY_CODE_INVALID');
      const requestId = readStr(reply, 'requestId');
      const pollToken = readStr(reply, 'pollToken');
      const verifyCode = readStr(reply, 'verifyCode');
      if (submitted.statusCode >= 300 || !ID.test(requestId) || !POLL_TOKEN.test(pollToken) || !/^\d{4}$/.test(verifyCode)) {
        throw new Error('RELAY_PAIRING_FAILED');
      }
      onWaiting(verifyCode);
      const approved = await this.wait(link.baseUrl, requestId, pollToken, assertCurrent);
      const cert = readObj(approved, 'cert');
      const signature = readStr(cert, 'signature');
      const issuedAt = readNum(cert, 'issuedAt', -1);
      const credential = readStr(approved, 'credential');
      if (approved['deviceId'] !== deviceId || !BASE64URL_KEY.test(credential) || cert['v'] !== 1
        || cert['relayId'] !== relayId || cert['deviceId'] !== deviceId || cert['publicKey'] !== key
        || cert['role'] !== 'member' || !Number.isSafeInteger(issuedAt) || issuedAt < 0 || !BASE64URL_SIGNATURE.test(signature)
        || engineCall(engine, { 'op': 'verify', 'key': link.ownerPublicKey, 'signature': signature,
          'text': JSON.stringify(['cindy-relay-cert/1', relayId, deviceId, key, 'member', issuedAt]) }) !== true) {
        throw new Error('RELAY_OWNER_MISMATCH');
      }
      const membership = new LegacyRelayMembership();
      membership.relayId = relayId;
      membership.name = name;
      membership.baseUrl = link.baseUrl;
      membership.deviceId = deviceId;
      membership.ownerPublicKey = link.ownerPublicKey;
      membership.credential = credential;
      membership.seed = options.seed;
      assertCurrent();
      return membership;
    } finally {
      engine.close();
    }
  }

  private body(value: string): Record<string, Object> {
    try {
      return recordOrEmpty(JSON.parse(value) as Object);
    } catch (_error) {
      throw new Error('RELAY_INVALID_RESPONSE');
    }
  }

  private async wait(baseUrl: string, requestId: string, pollToken: string,
    assertCurrent: () => void): Promise<Record<string, Object>> {
    const deadline = Date.now() + APPROVAL_MS;
    const headers: Record<string, string> = { 'X-Cindy-Relay-Poll-Token': pollToken };
    let failures = 0;
    while (Date.now() < deadline) {
      assertCurrent();
      let response: HttpResponseData;
      try {
        response = await this.http.requestJson(baseUrl + API + '/pair/' + encodeURIComponent(requestId) + '?wait=20',
          'GET', headers, undefined, 25000, true);
      } catch (error) {
        if (error instanceof Error && error.message === 'PRIVATE_ENDPOINT_UNREACHABLE' && ++failures < 5) {
          await new Promise<void>((resolve): void => { setTimeout(resolve, 2000); });
          continue;
        }
        throw new Error('RELAY_APPROVAL_UNAVAILABLE');
      }
      assertCurrent();
      failures = 0;
      if (response.statusCode === 403 || response.statusCode === 404) throw new Error('RELAY_EXPIRED');
      if (response.statusCode !== 200) throw new Error('RELAY_APPROVAL_UNAVAILABLE');
      const reply = this.body(response.body);
      const status = readStr(reply, 'status');
      if (status === 'approved') return reply;
      if (status !== 'pending') throw new Error(status === 'rejected' ? 'RELAY_REJECTED' : 'RELAY_EXPIRED');
      // A relay that answers before the requested wait must not turn polling into a tight loop.
      await new Promise<void>((resolve): void => { setTimeout(resolve, 1000); });
    }
    throw new Error('RELAY_EXPIRED');
  }
}
