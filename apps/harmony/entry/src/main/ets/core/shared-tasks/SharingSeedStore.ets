import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { sharedTaskError, SharedTaskFault } from './SharedTaskModels';

export interface SharingAssetPort {
  query(request: asset.AssetMap): Promise<asset.AssetMap[]>;
  add(request: asset.AssetMap): Promise<void>;
  remove(request: asset.AssetMap): Promise<void>;
}
class NativeSharingAsset implements SharingAssetPort {
  async query(request: asset.AssetMap): Promise<asset.AssetMap[]> { return await asset.query(request); }
  async add(request: asset.AssetMap): Promise<void> { await asset.add(request); }
  async remove(request: asset.AssetMap): Promise<void> { await asset.remove(request); }
}

/** System crypto/encoding boundary; the production implementation exclusively uses Harmony APIs. */
export interface SharingSeedSystemPort {
  utf8Encode(text: string): Uint8Array;
  utf8Decode(bytes: Uint8Array): string;
  sha256(bytes: Uint8Array): Promise<Uint8Array>;
  randomBytes(length: number): Uint8Array;
  base64(bytes: Uint8Array): string;
}
class NativeSharingSeedSystem implements SharingSeedSystemPort {
  utf8Encode(text: string): Uint8Array { return new util.TextEncoder().encodeInto(text); }
  utf8Decode(bytes: Uint8Array): string { return util.TextDecoder.create('utf-8').decodeToString(bytes); }
  async sha256(bytes: Uint8Array): Promise<Uint8Array> {
    const hash = cryptoFramework.createMd('SHA256'); await hash.update({ data: bytes }); return (await hash.digest()).data;
  }
  randomBytes(length: number): Uint8Array { return cryptoFramework.createRandom().generateRandomSync(length).data; }
  base64(bytes: Uint8Array): string { return new util.Base64Helper().encodeToStringSync(bytes); }
}

/** Independent encrypted namespace; no signing seed is written to preferences or the workspace. */
export class SharingSeedStore {
  private pending: Map<string, Promise<string>> = new Map();
  private storage: SharingAssetPort;
  private system: SharingSeedSystemPort;
  constructor(storage: SharingAssetPort = new NativeSharingAsset(), system: SharingSeedSystemPort = new NativeSharingSeedSystem()) {
    this.storage = storage; this.system = system;
  }
  private async alias(realm: string, account: string, name: string): Promise<asset.AssetMap> {
    if (!realm || !account || !name) throw new SharedTaskFault('ACCESS_REVOKED');
    const identity = this.system.utf8Encode(JSON.stringify([realm, account, name]));
    if (!(identity instanceof Uint8Array) || identity.length === 0) throw new SharedTaskFault('AGENT_NET_SHARING_SEED_UNAVAILABLE');
    const digest = await this.system.sha256(identity);
    if (!(digest instanceof Uint8Array) || digest.length !== 32) throw new SharedTaskFault('AGENT_NET_SHARING_SEED_UNAVAILABLE');
    const suffix = this.system.base64(digest);
    if (!/^[A-Za-z0-9+/]{43}=$/.test(suffix)) throw new SharedTaskFault('AGENT_NET_SHARING_SEED_UNAVAILABLE');
    const alias = 'cindy.shared-task-seed.v1.' + suffix, encoded = this.system.utf8Encode(alias);
    if (!(encoded instanceof Uint8Array) || encoded.length !== alias.length) throw new SharedTaskFault('AGENT_NET_SHARING_SEED_UNAVAILABLE');
    const query = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, encoded);
    query.set(asset.Tag.REQUIRE_ATTR_ENCRYPTED, true); return query;
  }
  private async read(query: asset.AssetMap, current: () => void): Promise<string | null> {
    const request = new Map<asset.Tag, asset.Value>();
    query.forEach((value: asset.Value, key: asset.Tag): void => { request.set(key, value); }); request.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    current();
    try {
      const rows = await this.storage.query(request); current();
      const secret = rows[0]?.get(asset.Tag.SECRET);
      if (!(secret instanceof Uint8Array)) throw new SharedTaskFault('AGENT_NET_SHARING_SEED_UNREADABLE');
      const seed = this.system.utf8Decode(secret);
      if (!/^[A-Za-z0-9_-]{43}$/.test(seed)) throw new SharedTaskFault('AGENT_NET_SHARING_SEED_UNREADABLE'); return seed;
    } catch (error) { current(); if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) return null; throw sharedTaskError(error); }
  }
  getOrCreate(realm: string, account: string, name: string, current: () => void): Promise<string> {
    current(); const identity = JSON.stringify([realm, account, name]);
    const existing = this.pending.get(identity);
    if (existing) return existing.then((seed: string): string => { current(); return seed; });
    const work = this.create(realm, account, name, current);
    this.pending.set(identity, work);
    void work.finally((): void => { if (this.pending.get(identity) === work) this.pending.delete(identity); }).catch((): void => {});
    return work;
  }
  private async create(realm: string, account: string, name: string, current: () => void): Promise<string> {
    const query = await this.alias(realm, account, name); current();
    const saved = await this.read(query, current); current(); if (saved !== null) return saved;
    const entropy = this.system.randomBytes(32);
    if (!(entropy instanceof Uint8Array) || entropy.length !== 32) throw new SharedTaskFault('AGENT_NET_SHARING_SEED_UNAVAILABLE');
    const seed = this.system.base64(entropy).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    if (!/^[A-Za-z0-9_-]{43}$/.test(seed)) throw new SharedTaskFault('AGENT_NET_SHARING_SEED_UNAVAILABLE');
    const request = new Map<asset.Tag, asset.Value>();
    query.forEach((value: asset.Value, key: asset.Tag): void => { request.set(key, value); });
    const secret = this.system.utf8Encode(seed);
    if (!(secret instanceof Uint8Array) || secret.length !== 43) throw new SharedTaskFault('AGENT_NET_SHARING_SEED_UNAVAILABLE');
    request.set(asset.Tag.SECRET, secret);
    request.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED); request.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    // Default conflict policy rejects duplicates. Never rotate an established signing identity on a racing create.
    current();
    try { await this.storage.add(request); current(); return seed; }
    catch (error) { current(); const winner = await this.read(query, current); if (winner !== null) return winner; throw sharedTaskError(error); }
  }
  async remove(realm: string, account: string, name: string, current: () => void): Promise<void> {
    const query = await this.alias(realm, account, name); current();
    try { await this.storage.remove(query); } catch (error) { if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) throw sharedTaskError(error); }
    current();
  }
  clearPending(): void { this.pending.clear(); }
}
