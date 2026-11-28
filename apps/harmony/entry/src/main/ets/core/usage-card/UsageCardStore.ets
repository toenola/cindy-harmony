import { UsageSnapshot, UsageSource, usageCompact, usageSum } from '../usage/UsageDashboard';
import { recordOrEmpty } from '../tasks/TaskModels';
export class UsageCardData {
  formId: string = ''; deviceId: string = ''; deviceName: string = '';
  dimension: number = 2;
  status: string = 'signed-out'; updatedAt: number = 0; stale: boolean = true;
  source1: string = ''; value1: string = ''; reset1: string = ''; fill1: number = 0;
  source2: string = ''; value2: string = ''; reset2: string = ''; fill2: number = 0;
  tokens: string = ''; paid: string = '';
}
export class UsageCardInstance {
  formId: string = ''; owner: string = ''; deviceId: string = ''; dimension: number = 2;
}
export class UsageCardSnapshot {
  deviceId: string = ''; data: UsageCardData = new UsageCardData();
}
export class UsageCardLedger {
  version: number = 1; owner: string = ''; generation: number = 0;
  instances: UsageCardInstance[] = []; snapshots: UsageCardSnapshot[] = [];
  autoDeviceId: string = '';
}
/** Synchronous private-file transactions in the card provider app process. Native adapter reads
 * the current on-disk owner on every operation; no credential or auth token is stored here. */
export interface UsageCardStorage { read(): string; write(json: string): void; }
export type UsageCardPublish = (formId: string, data: UsageCardData) => Promise<void>;
export function projectUsageCard(snapshot: UsageSnapshot, device: string, name: string): UsageCardData {
  const data = new UsageCardData(); data.deviceId = device; data.deviceName = name.slice(0, 120);
  data.status = 'snapshot'; data.updatedAt = snapshot.updatedAtMs || snapshot.generatedAtMs;
  const sources = snapshot.sources.filter((source: UsageSource): boolean => source.kind === 'subscription').slice(0, 2);
  if (sources[0]) {
    data.source1 = sources[0].name.slice(0, 100); data.value1 = (sources[0].value + sources[0].unit).slice(0, 100);
    data.reset1 = sources[0].when.slice(0, 100); data.fill1 = Math.round(100 * sources[0].fill);
  }
  if (sources[1]) {
    data.source2 = sources[1].name.slice(0, 100); data.value2 = (sources[1].value + sources[1].unit).slice(0, 100);
    data.reset2 = sources[1].when.slice(0, 100); data.fill2 = Math.round(100 * sources[1].fill);
  }
  const day = snapshot.days[snapshot.days.length - 1];
  if (day) { data.tokens = usageCompact(usageSum(day.tokens)); data.paid = snapshot.moneySymbol.slice(0, 4) + day.paid.toFixed(2); }
  data.stale = snapshot.sources.some((source: UsageSource): boolean => source.stale);
  return data;
}
export class UsageCardStore {
  private storage: UsageCardStorage;
  private publish: UsageCardPublish;
  private now: () => number;
  private failedForms: Set<string> = new Set();
  // All Store instances in the provider process share publication order, including the extension.
  private static publishing: Promise<void> = Promise.resolve();
  constructor(storage: UsageCardStorage, publish: UsageCardPublish, now: () => number = Date.now) {
    this.storage = storage; this.publish = publish; this.now = now;
  }
  private read(): UsageCardLedger {
    const json = this.storage.read();
    if (!json) return new UsageCardLedger();
    const raw = recordOrEmpty(JSON.parse(json) as Object);
    if (raw['version'] !== 1) throw new Error('USAGE_CARD_INVALID_STATE');
    const data = JSON.parse(json) as UsageCardLedger;
    if (!Array.isArray(data.instances) || !Array.isArray(data.snapshots) || data.instances.length > 64 || data.snapshots.length > 64) throw new Error('USAGE_CARD_INVALID_STATE');
    return data;
  }
  private save(data: UsageCardLedger): void { this.storage.write(JSON.stringify(data)); }
  /** Ownership changes/logout clear personal data. A same-owner process-generation change is
   * only a request fence: persistent widget computer choices survive application restarts. */
  setOwner(owner: string, generation: number): Promise<void> {
    const state = this.read();
    if (state.owner === owner && state.generation === generation) return Promise.resolve();
    const ownerChanged = state.owner !== owner;
    state.owner = owner; state.generation = generation;
    if (ownerChanged || !owner) {
      state.snapshots = []; state.autoDeviceId = '';
      state.instances.forEach((instance: UsageCardInstance): void => { instance.owner = owner; instance.deviceId = ''; });
    }
    this.save(state); return this.publishAll();
  }
  register(formId: string, deviceId: string = '', dimension: number = 2): UsageCardData {
    if (!formId || formId.length > 128) throw new Error('USAGE_CARD_INVALID_ID');
    const state = this.read();
    if (!state.instances.some((instance: UsageCardInstance): boolean => instance.formId === formId)) {
      if (state.instances.length >= 64) throw new Error('USAGE_CARD_TOO_MANY');
      const instance = new UsageCardInstance(); instance.formId = formId; instance.owner = state.owner;
      instance.deviceId = deviceId; instance.dimension = dimension === 3 ? 3 : 2; state.instances.push(instance); this.save(state);
    }
    return this.data(formId);
  }
  resize(formId: string, dimension: number): Promise<void> {
    const state = this.read(), instance = state.instances.find((instance: UsageCardInstance): boolean => instance.formId === formId);
    if (instance) { instance.dimension = dimension === 3 ? 3 : 2; this.save(state); }
    return this.publishAll();
  }
  remove(formId: string): void {
    const state = this.read(); state.instances = state.instances.filter((instance: UsageCardInstance): boolean => instance.formId !== formId); this.save(state);
  }
  configure(formId: string, deviceId: string): Promise<void> {
    const state = this.read(), instance = state.instances.find((instance: UsageCardInstance): boolean => instance.formId === formId);
    if (!state.owner || !instance || instance.owner !== state.owner) throw new Error('USAGE_CARD_OWNER_REQUIRED');
    instance.deviceId = deviceId; this.save(state); return this.publishAll();
  }
  /** Publish only a current owner's already-authorized snapshot. Never fetch vendors/background WS. */
  sync(owner: string, generation: number, snapshot: UsageSnapshot, deviceId: string, deviceName: string): Promise<void> {
    const state = this.read();
    if (!owner || owner !== state.owner || generation !== state.generation) throw new Error('USAGE_CARD_STALE');
    if (!deviceId) throw new Error('USAGE_CARD_INVALID_DEVICE');
    const entry = new UsageCardSnapshot(); entry.deviceId = deviceId; entry.data = projectUsageCard(snapshot, deviceId, deviceName);
    state.snapshots = state.snapshots.filter((item: UsageCardSnapshot): boolean => item.deviceId !== deviceId).concat([entry]).slice(-64);
    state.autoDeviceId = deviceId; this.save(state); return this.publishAll();
  }
  invalidateDevice(deviceId: string): Promise<void> {
    const state = this.read(); state.snapshots = state.snapshots.filter((entry: UsageCardSnapshot): boolean => entry.deviceId !== deviceId);
    if (state.autoDeviceId === deviceId) state.autoDeviceId = '';
    this.save(state); return this.publishAll();
  }
  data(formId: string): UsageCardData {
    const state = this.read(), instance = state.instances.find((instance: UsageCardInstance): boolean => instance.formId === formId);
    const blank = new UsageCardData(); blank.formId = formId;
    if (!state.owner || !instance || instance.owner !== state.owner) return blank;
    blank.dimension = instance.dimension; blank.status = 'unavailable'; blank.deviceId = instance.deviceId;
    const snapshot = state.snapshots.find((snapshot: UsageCardSnapshot): boolean => snapshot.deviceId === (instance.deviceId || state.autoDeviceId));
    if (!snapshot) return blank;
    const data = JSON.parse(JSON.stringify(snapshot.data)) as UsageCardData;
    data.formId = formId; data.dimension = instance.dimension; data.stale = data.stale || !data.updatedAt || this.now() - data.updatedAt > 15 * 60 * 1000;
    return data;
  }
  target(formId: string, owner: string): string | null {
    const state = this.read();
    if (!owner || state.owner !== owner) return null;
    const instance = state.instances.find((instance: UsageCardInstance): boolean => instance.formId === formId && instance.owner === owner);
    return instance ? instance.deviceId : null;
  }
  failedPublications(): string[] { return Array.from(this.failedForms); }
  /** System onUpdateForm only republishes the cached projection and recomputes its age. */
  publishAll(): Promise<void> {
    const run = UsageCardStore.publishing.then(async (): Promise<void> => {
      const ids = this.read().instances.map((instance: UsageCardInstance): string => instance.formId);
      for (const id of ids) {
        const data = this.data(id); // Ledger read failures remain reportable, outside the publish-only catch.
        try { await this.publish(id, data); this.failedForms.delete(id); }
        catch { this.failedForms.add(id); }
      }
      this.failedForms.forEach((id: string): void => { if (!ids.includes(id)) this.failedForms.delete(id); });
    });
    UsageCardStore.publishing = run.catch(() => {}); return run;
  }
}
