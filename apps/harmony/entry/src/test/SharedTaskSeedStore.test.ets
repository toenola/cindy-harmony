import { describe, expect, it } from '@ohos/hypium';
import { asset } from '@kit.AssetStoreKit';
import { SharingSeedStore, SharingAssetPort, SharingSeedSystemPort } from '../main/ets/core/shared-tasks/SharingSeedStore';

// Unit tier: real seed store public entry with Asset, crypto and text codec system ports replaced.
// A single first write or a delayed query exposes namespace/plaintext-fallback/epoch regressions;
// transport/store tests do not exercise this credential boundary. No disk, network or sleeps.
// Deterministic byte/hash service fake, not a cryptographic implementation or success claim.
// ASCII fixtures make byte ownership observable without the LocalUnit SDK's empty TextEncoder mock.
class SeedSystemFixture implements SharingSeedSystemPort {
  randomCalls: number = 0;
  shortRandom: boolean = false;
  private digests: Map<string, number> = new Map();
  utf8Encode(text: string): Uint8Array {
    const bytes = new Uint8Array(text.length);
    for (let index = 0; index < text.length; index++) {
      if (text.charCodeAt(index) > 127) throw new Error('fixture accepts ASCII only'); bytes[index] = text.charCodeAt(index);
    }
    return bytes;
  }
  utf8Decode(bytes: Uint8Array): string { let text = ''; for (const byte of bytes) text += String.fromCharCode(byte); return text; }
  async sha256(bytes: Uint8Array): Promise<Uint8Array> {
    const key = this.utf8Decode(bytes); let value = this.digests.get(key);
    if (value === undefined) { value = this.digests.size + 1; this.digests.set(key, value); }
    return new Uint8Array(32).fill(value);
  }
  randomBytes(length: number): Uint8Array { this.randomCalls++; return new Uint8Array(this.shortRandom ? 16 : length).fill(this.randomCalls); }
  base64(bytes: Uint8Array): string {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'; let text = '';
    for (let index = 0; index < bytes.length; index += 3) {
      const first = bytes[index], second = index + 1 < bytes.length ? bytes[index + 1] : 0, third = index + 2 < bytes.length ? bytes[index + 2] : 0;
      text += alphabet.charAt(first >> 2) + alphabet.charAt(((first & 3) << 4) | (second >> 4))
        + (index + 1 < bytes.length ? alphabet.charAt(((second & 15) << 2) | (third >> 6)) : '=')
        + (index + 2 < bytes.length ? alphabet.charAt(third & 63) : '=');
    }
    return text;
  }
}
class MissingAssetError extends Error { code: number = asset.ErrorCode.NOT_FOUND; }
class MemoryAsset implements SharingAssetPort {
  private codec: SeedSystemFixture;
  constructor(codec: SeedSystemFixture) { this.codec = codec; }
  rows: Map<string, asset.AssetMap> = new Map();
  writes: asset.AssetMap[] = [];
  fail: boolean = false;
  delay: (() => Promise<void>) | null = null;
  private key(request: asset.AssetMap): string {
    return this.codec.utf8Decode(request.get(asset.Tag.ALIAS) as Uint8Array);
  }
  async query(request: asset.AssetMap): Promise<asset.AssetMap[]> {
    if (this.delay) await this.delay();
    if (this.fail) throw new Error('system store unavailable');
    const row = this.rows.get(this.key(request));
    if (!row) throw new MissingAssetError('not found');
    return [row];
  }
  async add(request: asset.AssetMap): Promise<void> {
    const key = this.key(request); if (this.rows.has(key)) throw new Error('conflict');
    this.rows.set(key, request); this.writes.push(request);
  }
  async remove(request: asset.AssetMap): Promise<void> { this.rows.delete(this.key(request)); }
}
export default function sharedTaskSeedStoreTests(): void {
  describe('SharedTaskSeedStore', () => {
    it('first_create_uses_encrypted_device_only_asset_and_retains_identity_per_account', 0, async () => {
      const crypto = new SeedSystemFixture(), system = new MemoryAsset(crypto), store = new SharingSeedStore(system, crypto), current = (): void => {};
      const first = await store.getOrCreate('cn', 'account-a', 'business', current);
      expect(/^[A-Za-z0-9_-]{43}$/.test(first)).assertTrue();
      expect(await store.getOrCreate('cn', 'account-a', 'business', current)).assertEqual(first);
      expect(await store.getOrCreate('cn', 'account-b', 'business', current) === first).assertFalse();
      expect(await store.getOrCreate('global', 'account-a', 'business', current) === first).assertFalse();
      expect(await store.getOrCreate('cn', 'account-a', 'applicant', current) === first).assertFalse();
      expect(system.writes.length).assertEqual(4); expect(crypto.randomCalls).assertEqual(4);
      const written = system.writes[0];
      expect(written.get(asset.Tag.REQUIRE_ATTR_ENCRYPTED)).assertEqual(true);
      expect(written.get(asset.Tag.ACCESSIBILITY)).assertEqual(asset.Accessibility.DEVICE_UNLOCKED);
      expect(written.get(asset.Tag.SYNC_TYPE)).assertEqual(asset.SyncType.NEVER);
      const alias = crypto.utf8Decode(written.get(asset.Tag.ALIAS) as Uint8Array);
      expect(crypto.utf8Decode(written.get(asset.Tag.SECRET) as Uint8Array)).assertEqual(first);
      expect(alias.startsWith('cindy.shared-task-seed.v1.')).assertTrue(); expect(alias.includes('account-a')).assertFalse();
    });
    it('invalid_system_random_bytes_fail_before_asset_write', 0, async () => {
      const crypto = new SeedSystemFixture(), system = new MemoryAsset(crypto), store = new SharingSeedStore(system, crypto); crypto.shortRandom = true;
      let rejected = false; try { await store.getOrCreate('cn', 'account', 'business', (): void => {}); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(system.writes.length).assertEqual(0);
    });
    it('system_store_failure_never_creates_replacement_identity', 0, async () => {
      const crypto = new SeedSystemFixture(), system = new MemoryAsset(crypto); system.fail = true; const store = new SharingSeedStore(system, crypto); let rejected = false;
      try { await store.getOrCreate('cn', 'account', 'business', (): void => {}); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(system.writes.length).assertEqual(0);
    });
    it('logout_during_query_rejects_late_secret_and_does_not_write_new_seed', 0, async () => {
      const crypto = new SeedSystemFixture(), system = new MemoryAsset(crypto), store = new SharingSeedStore(system, crypto); let valid = true;
      system.delay = async (): Promise<void> => { valid = false; };
      let rejected = false;
      try { await store.getOrCreate('cn', 'account', 'business', (): void => { if (!valid) throw new Error('account changed'); }); }
      catch { rejected = true; }
      expect(rejected).assertTrue(); expect(system.writes.length).assertEqual(0);
    });
  });
}
