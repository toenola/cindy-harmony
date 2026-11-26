import { AgentNetSocket, AgentNetSocketConfig } from './AgentNetSocket';
import { AppConfig } from '../../AppConfig';
import { RelayMembershipStore } from './RelayMembershipStore';
import { LegacyRelayMembership } from './LegacyRelayPairing';
import { readStr, readObj, recordOrEmpty } from '../tasks/TaskModels';
import { normalizeRelayBaseUrl } from './RelayJoinLink';

export class RelayRoute {
  static readonly instance: RelayRoute = new RelayRoute();
  private readonly store: RelayMembershipStore = new RelayMembershipStore();
  socket: AgentNetSocket | undefined;
  private encrypted: AgentNetSocketConfig | undefined;
  private owner: string = '';
  private revision: number = 0;
  private membership: LegacyRelayMembership | undefined;
  private loading: Promise<void> | undefined;
  private error: string = '';
  private dual: boolean = false;
  get canToggleEncryption(): boolean { return this.dual; }

  get agentNet(): AgentNetSocketConfig | undefined { return this.encrypted; }
  get custom(): boolean { return this.membership !== undefined || this.encrypted !== undefined; }
  get legacy(): LegacyRelayMembership | undefined { return this.membership; }
  get generation(): number { return this.revision; }
  get issue(): string { return this.error; }
  get apiBase(): string { return this.membership?.baseUrl ?? this.encrypted?.baseUrl ?? AppConfig.deviceLinkApiBaseUrl; }
  get wsUrl(): string { return this.custom
    ? this.apiBase.replace(/^http/, 'ws') + (this.encrypted ? '/api/agent-net/ws' : '/api/device-link/ws')
    : AppConfig.deviceLinkWsUrl; }

  cacheScope(accountId: string): string {
    return this.custom ? JSON.stringify([accountId, this.apiBase, this.membership?.relayId ?? this.encrypted?.relayId]) : accountId;
  }

  async prepare(accountId: string): Promise<void> {
    if (this.owner === accountId) {
      if (this.loading) await this.loading;
      if (this.error) throw new Error(this.error);
      return;
    }
    this.reset();
    if (!accountId) return;
    this.owner = accountId;
    const revision = this.revision;
    const guard = (): void => {
      if (revision !== this.revision || this.owner !== accountId) throw new Error('RELAY_ACCOUNT_CHANGED');
    };
    const operation = this.load(accountId, guard);
    this.loading = operation;
    try {
      await operation;
    } finally {
      if (this.loading === operation) this.loading = undefined;
    }
  }

  private async load(accountId: string, guard: () => void): Promise<void> {
    try {
      const value = await this.store.read(AppConfig.region, accountId, guard);
      guard();
      if (value === null) return;
      const data = recordOrEmpty(JSON.parse(value) as Object);
      this.dual = data['agentNet'] !== undefined;
      if (data['version'] !== 1) throw new Error('RELAY_STORED_MEMBERSHIP_INVALID');
      if (data['mode'] === 'agent-net') {
        const raw = readObj(data, this.dual ? 'agentNet' : 'membership');
        const config = new AgentNetSocketConfig();
        config.accountId = accountId;
        config.name = readStr(readObj(data, 'membership'), 'name');
        config.baseUrl = readStr(data, 'baseUrl');
        config.seed = readStr(raw, 'seed');
        config.rootPublicKey = readStr(raw, 'rootPublicKey');
        config.certificate = readObj(raw, 'certificate');
        config.deviceId = readStr(data, 'deviceId');
        config.relayId = readStr(raw, 'networkId').replace(/^private:/, '');
        if (!config.baseUrl || normalizeRelayBaseUrl(config.baseUrl) !== config.baseUrl || !config.relayId
          || config.certificate['subject'] !== accountId || config.certificate['deviceId'] !== config.deviceId
          || !/^[A-Za-z0-9_-]{43}$/.test(config.seed) || !/^[A-Za-z0-9_-]{43}$/.test(config.rootPublicKey)) {
          throw new Error('RELAY_STORED_MEMBERSHIP_INVALID');
        }
        this.encrypted = config;
        return;
      }
      if (data['mode'] !== 'legacy') throw new Error('RELAY_STORED_MEMBERSHIP_INVALID');
      const raw = readObj(data, 'membership');
      const membership = new LegacyRelayMembership();
      membership.baseUrl = readStr(data, 'baseUrl');
      membership.relayId = readStr(raw, 'relayId');
      membership.deviceId = readStr(raw, 'deviceId');
      membership.name = readStr(raw, 'name');
      membership.seed = readStr(raw, 'seed');
      membership.credential = readStr(raw, 'credential');
      membership.ownerPublicKey = readStr(raw, 'ownerPublicKey');
      if (!membership.baseUrl || normalizeRelayBaseUrl(membership.baseUrl) !== membership.baseUrl
        || raw['baseUrl'] !== membership.baseUrl || data['deviceId'] !== membership.deviceId
        || !membership.relayId || !membership.deviceId
        || !/^[A-Za-z0-9_-]{43}$/.test(membership.seed)
        || !/^[A-Za-z0-9_-]{43}$/.test(membership.credential)
        || !/^[A-Za-z0-9_-]{43}$/.test(membership.ownerPublicKey)) throw new Error('RELAY_STORED_MEMBERSHIP_INVALID');
      this.membership = membership;
    } catch (error) {
      guard();
      this.error = error instanceof Error ? error.message : 'RELAY_MEMBERSHIP_UNAVAILABLE';
      throw new Error(this.error);
    }
  }

  reset(): void {
    this.socket?.terminate();
    this.socket = undefined;
    this.revision += 1;
    this.owner = '';
    this.membership = undefined;
    this.encrypted = undefined;
    this.loading = undefined;
    this.error = '';
    this.dual = false;
  }

  async setEncryption(accountId: string, enabled: boolean): Promise<void> {
    const generation = this.revision;
    const guard = (): void => {
      this.assertGeneration(generation);
      if (this.owner !== accountId) throw new Error('RELAY_ACCOUNT_CHANGED');
    };
    guard();
    if (!this.dual) throw new Error('RELAY_ROUTE_UNAVAILABLE');
    const value = await this.store.read(AppConfig.region, accountId, guard);
    if (!value) throw new Error('RELAY_MEMBERSHIP_UNAVAILABLE');
    const data = recordOrEmpty(JSON.parse(value) as Object);
    if (!data['agentNet'] || !readStr(readObj(data, 'membership'), 'credential')) throw new Error('RELAY_ROUTE_UNAVAILABLE');
    data['mode'] = enabled ? 'agent-net' : 'legacy';
    await this.store.save(AppConfig.region, accountId, JSON.stringify(data), guard);
  }

  async official(accountId: string): Promise<void> {
    const revision = this.revision;
    await this.store.remove(AppConfig.region, accountId, (): void => {
      if (revision !== this.revision) throw new Error('RELAY_ACCOUNT_CHANGED');
    });
    this.reset();
  }

  authorization(officialToken: string): string {
    if (this.error || this.loading || this.encrypted) throw new Error('RELAY_ROUTE_UNAVAILABLE');
    return this.membership ? 'CindyRelay ' + this.membership.credential : 'Bearer ' + officialToken;
  }

  assertGeneration(generation: number): void {
    if (this.revision !== generation || this.error) throw new Error('RELAY_ROUTE_CHANGED');
  }
}
