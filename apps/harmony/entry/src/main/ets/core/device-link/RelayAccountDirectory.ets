import { util, url } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AppConfig } from '../../AppConfig';
import { HarmonyHttp, HttpResponseData } from '../../network/HarmonyHttp';
import { readStr, readObj, readNum, recordOrEmpty } from '../tasks/TaskModels';
import { accountOffers, accountBoard, editAccountBoard, installUrlParser } from './portable/index';
import { AgentNetEngine, AgentNetEngineOptions } from './AgentNetEngine';
import { base64Url, engineCall } from './AgentNetPairing';
import { parseRelayJoinLink } from './RelayJoinLink';

export class RelayAccountOffer {
  ownerDeviceId: string = '';
  ownerDeviceName: string = '';
  relayId: string = '';
  name: string = '';
  kind: string = '';
  baseUrl: string = '';
  ownerPublicKey: string = '';
}
export class RelayAccountInvitation {
  uri: string = '';
  seed: string = '';
}
class PreferenceValue {
  value: Object | null = null;
  revision: number = 0;
}

// Official account preferences remain official even while the device connection uses a private station.
export class RelayAccountDirectory {
  private token: () => Promise<string | null>;
  private guard: () => void;
  private refresh: (() => Promise<string | null>) | undefined;
  constructor(token: () => Promise<string | null>, guard: () => void, refresh?: () => Promise<string | null>) {
    this.token = token; this.guard = guard; this.refresh = refresh;
    installUrlParser((value: string): string => {
      const parsed = url.URL.parseURL(value);
      const properties: Record<string, string> = {
        'protocol': parsed.protocol, 'hostname': parsed.hostname, 'host': parsed.host,
        'username': parsed.username, 'password': parsed.password, 'search': parsed.search,
        'hash': parsed.hash, 'pathname': parsed.pathname, 'href': parsed.href,
      };
      return JSON.stringify(properties);
    }, (value: string): string => {
      const params = new url.URLParams(value);
      const fields: Record<string, string> = {};
      for (const key of ['u', 'c', 'o', 's', 'a', 'r', 'g', 'h', 'n']) {
        const field = params.get(key);
        if (field !== null) fields[key] = field;
      }
      return JSON.stringify(fields);
    });
  }

  async offers(): Promise<RelayAccountOffer[]> {
    const rows = JSON.parse(accountOffers(JSON.stringify((await this.preference('relay.offers.v1')).value))) as Object[];
    return rows.map((raw: Object): RelayAccountOffer => {
      const item = recordOrEmpty(raw);
      const offer = new RelayAccountOffer();
      offer.ownerDeviceId = readStr(item, 'ownerDeviceId'); offer.ownerDeviceName = readStr(item, 'ownerDeviceName');
      offer.kind = readStr(item, 'kind');
      offer.name = readStr(item, 'name'); offer.relayId = readStr(item, 'relayId');
      offer.baseUrl = readStr(item, 'baseUrl'); offer.ownerPublicKey = readStr(item, 'ownerPublicKey');
      return offer;
    });
  }

  async invite(offer: RelayAccountOffer, deviceId: string, deviceName: string): Promise<RelayAccountInvitation> {
    this.guard();
    // Probe once before creating a request on the official account board.
    if (offer.kind !== 'shared') {
      const probe = await new HarmonyHttp().requestJson(offer.baseUrl + '/api/device-link/relay/info',
        'GET', {}, undefined, 8000, true);
      this.guard();
      if (probe.statusCode !== 200) throw new Error('RELAY_INFO_UNAVAILABLE');
    }
    const options = new AgentNetEngineOptions();
    options.seed = base64Url(cryptoFramework.createRandom().generateRandomSync(32).data);
    options.context = offer.relayId; options.deviceId = deviceId;
    const engine = await AgentNetEngine.create(options, this.guard);
    let publicKey = '';
    try { publicKey = readStr(recordOrEmpty(engineCall(engine, { 'op': 'identity' })), 'signingKey'); }
    finally { engine.close(); }
    const requestId = util.generateRandomUUID();
    const request: Record<string, Object> = {
      'requestId': requestId, 'deviceId': deviceId, 'deviceName': deviceName.slice(0, 128) || 'Cindy',
      'platform': AppConfig.platform, 'relayId': offer.relayId, 'ownerDeviceId': offer.ownerDeviceId,
      'publicKey': publicKey, 'createdAt': Date.now(),
    };
    await this.edit(deviceId, requestId, JSON.stringify(request));
    try {
      const started = Date.now();
      let acknowledged = false;
      while (Date.now() - started < 45000 && (acknowledged || Date.now() - started < 12000)) {
        await new Promise<void>((resolve): void => { setTimeout(resolve, 2000); });
        this.guard();
        const value = await this.preference('relay.join.v1');
        const board = recordOrEmpty(JSON.parse(accountBoard(JSON.stringify(value.value), Date.now())) as Object);
        const invite = readObj(readObj(board, 'invites'), deviceId);
        if (invite['requestId'] !== requestId) continue;
        if (invite['pending'] === true) { acknowledged = true; continue; }
        const uri = readStr(invite, 'link');
        const link = parseRelayJoinLink(uri);
        if (invite['error']) throw new Error('RELAY_OWNER_UNAVAILABLE');
        if (!link) throw new Error('RELAY_INVITE_LINK_INVALID');
        if (invite['relayId'] !== offer.relayId) throw new Error('RELAY_INVITE_NETWORK_MISMATCH');
        if (link.ownerPublicKey !== offer.ownerPublicKey) throw new Error('RELAY_OWNER_MISMATCH');
        if (link.baseUrl !== offer.baseUrl) throw new Error('RELAY_INVITE_ADDRESS_MISMATCH');
        if (!link.code && link.relayId !== offer.relayId) throw new Error('RELAY_INVITE_NETWORK_MISMATCH');
        const result = new RelayAccountInvitation(); result.uri = uri; result.seed = options.seed;
        return result;
      }
      throw new Error('RELAY_OWNER_UNAVAILABLE');
    } finally {
      // Account-private one-shot links are removed with compare-and-swap, never copied into UI route parameters.
      await this.edit(deviceId, requestId, '').catch(() => {});
    }
  }

  private async edit(deviceId: string, requestId: string, request: string): Promise<void> {
    for (let attempt = 0; attempt < 4; attempt++) {
      const old = await this.preference('relay.join.v1');
      const value = JSON.parse(editAccountBoard(JSON.stringify(old.value), Date.now(), deviceId, requestId, request)) as Object;
      const response = await this.request('/preferences', 'POST', JSON.stringify({
        operationId: 'relay.' + util.generateRandomUUID(), key: 'relay.join.v1', expectedRevision: old.revision, value,
      }));
      if (response.statusCode === 409) continue;
      if (response.statusCode !== 200 && response.statusCode !== 201) throw new Error('RELAY_ACCOUNT_DIRECTORY_UNAVAILABLE');
      return;
    }
    throw new Error('RELAY_ACCOUNT_DIRECTORY_UNAVAILABLE');
  }

  private async preference(key: string): Promise<PreferenceValue> {
    const response = await this.request('/preferences?key=' + encodeURIComponent(key), 'GET');
    if (response.statusCode !== 200) throw new Error('RELAY_ACCOUNT_DIRECTORY_UNAVAILABLE');
    const rows = JSON.parse(response.body) as Object;
    if (!Array.isArray(rows)) throw new Error('RELAY_ACCOUNT_DIRECTORY_UNAVAILABLE');
    const found = new PreferenceValue();
    for (const raw of rows as Object[]) {
      const item = recordOrEmpty(raw);
      if (item['key'] === key) { found.value = item['value'] ?? null; found.revision = readNum(item, 'revision', 0); }
    }
    return found;
  }

  private async request(resource: string, method: 'GET' | 'POST', body?: string): Promise<HttpResponseData> {
    this.guard();
    const token = await this.token();
    this.guard();
    if (!token) throw new Error('RELAY_ACCOUNT_REQUIRED');
    let result = await new HarmonyHttp().requestJson(AppConfig.chatApiBaseUrl + '/v1' + resource, method,
      { 'Authorization': 'Bearer ' + token, 'Cache-Control': 'no-cache, no-store', 'Pragma': 'no-cache' }, body, 12000, true);
    this.guard();
    if (result.statusCode === 401 && this.refresh) {
      const fresh = await this.refresh();
      this.guard();
      if (fresh) result = await new HarmonyHttp().requestJson(AppConfig.chatApiBaseUrl + '/v1' + resource, method,
        { 'Authorization': 'Bearer ' + fresh, 'Cache-Control': 'no-cache, no-store', 'Pragma': 'no-cache' }, body, 12000, true);
    }
    this.guard();
    return result;
  }
}
