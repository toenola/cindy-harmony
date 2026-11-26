import { HarmonyHttp } from '../../network/HarmonyHttp';
import { readStr, recordOrEmpty } from '../tasks/TaskModels';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AgentNetPairing, base64Url } from './AgentNetPairing';
import { LegacyRelayPairing, LegacyRelayMembership } from './LegacyRelayPairing';
import { parseRelayJoinLink } from './RelayJoinLink';
import { RelayMembershipStore } from './RelayMembershipStore';

export class RelayEnrollmentAccount {
  realm: string = '';
  accountId: string = '';
  deviceId: string = '';
  deviceName: string = '';
}

export class RelayEnrollmentResult {
  mode: string = '';
  name: string = '';
  baseUrl: string = '';
}

// Only a verified approval is persisted. The connection owner decides when its transport can activate it.
export class RelayEnrollment {
  private active: boolean = false;
  private readonly store: RelayMembershipStore = new RelayMembershipStore();

  async join(uri: string, account: RelayEnrollmentAccount, assertCurrent: () => void,
    onWaiting: (code: string) => void, preferAgentNet: boolean = false, presetSeed: string = ''): Promise<RelayEnrollmentResult> {
    assertCurrent();
    if (this.active) throw new Error('RELAY_JOIN_IN_PROGRESS');
    if (!account.realm || !account.accountId || !account.deviceId) throw new Error('RELAY_ACCOUNT_REQUIRED');
    const link = parseRelayJoinLink(uri);
    if (!link) throw new Error('RELAY_INVALID_JOIN');
    this.active = true;
    try {
      if (link.ownerAccountTag) {
        const digest = cryptoFramework.createMd('SHA256');
        await digest.update({ data: new util.TextEncoder().encodeInto('cindy-relay-account/1:' + account.accountId) });
        const accountTag = base64Url((await digest.digest()).data).slice(0, 22);
        assertCurrent();
        // Cross-account links need the separate tenant invitation flow before enrollment.
        if (accountTag !== link.ownerAccountTag) throw new Error('RELAY_ACCOUNT_INVITATION_REQUIRED');
      }
      const result = new RelayEnrollmentResult();
      result.baseUrl = link.baseUrl;
      if (link.code && link.agentNetCode) {
        // Mixed stations approve the V2 CSR when the owner approves the same signing key over V1.
        const response = await new HarmonyHttp().requestJson(link.baseUrl + '/api/device-link/relay/info',
          'GET', {}, undefined, 12000, true);
        assertCurrent();
        if (response.statusCode !== 200) throw new Error('RELAY_INFO_UNAVAILABLE');
        link.relayId = readStr(recordOrEmpty(JSON.parse(response.body) as Object), 'relayId');
        if (!/^[0-9a-f-]{36}$/.test(link.relayId)) throw new Error('RELAY_INCOMPATIBLE');
        const seed = presetSeed || base64Url(cryptoFramework.createRandom().generateRandomSync(32).data);
        let legacy: LegacyRelayMembership | undefined;
        const encrypted = await new AgentNetPairing().join(link, account.accountId, account.deviceId,
          account.deviceName, assertCurrent, (): void => {}, seed, async (): Promise<void> => {
            legacy = await new LegacyRelayPairing().join(link, account.accountId, account.deviceId,
              account.deviceName, assertCurrent, onWaiting, seed);
            // The one-shot V1 credential is safe before any further V2 request.
            await this.store.save(account.realm, account.accountId, JSON.stringify({
              version: 1, mode: preferAgentNet ? 'pending-agent-net' : 'legacy', baseUrl: link.baseUrl,
              deviceId: account.deviceId, membership: legacy,
            }), assertCurrent);
          });
        assertCurrent();
        if (!legacy) throw new Error('RELAY_PAIRING_FAILED');
        await this.store.save(account.realm, account.accountId, JSON.stringify({
          version: 1, mode: preferAgentNet ? 'agent-net' : 'legacy', baseUrl: link.baseUrl,
          deviceId: account.deviceId, membership: legacy, agentNet: encrypted,
        }), assertCurrent);
        result.mode = preferAgentNet ? 'agent-net' : 'legacy';
        result.name = legacy.name;
      } else if (link.code) {
        const membership = await new LegacyRelayPairing().join(link, account.accountId, account.deviceId,
          account.deviceName, assertCurrent, onWaiting, presetSeed);
        await this.store.save(account.realm, account.accountId, JSON.stringify({
          version: 1, mode: 'legacy', baseUrl: link.baseUrl, deviceId: account.deviceId, membership: membership,
        }), assertCurrent);
        result.mode = 'legacy';
        result.name = membership.name;
      } else {
        const membership = await new AgentNetPairing().join(link, account.accountId, account.deviceId,
          account.deviceName, assertCurrent, onWaiting, presetSeed);
        await this.store.save(account.realm, account.accountId, JSON.stringify({
          version: 1, mode: 'agent-net', baseUrl: link.baseUrl, deviceId: account.deviceId, membership: membership,
        }), assertCurrent);
        result.mode = 'agent-net';
        result.name = link.ownerName;
      }
      return result;
    } finally {
      this.active = false;
    }
  }
}
