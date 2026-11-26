import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { asset } from '@kit.AssetStoreKit';

const PAYLOAD_TAGS: asset.Tag[] = [asset.Tag.DATA_LABEL_NORMAL_1, asset.Tag.DATA_LABEL_NORMAL_2,
  asset.Tag.DATA_LABEL_NORMAL_3, asset.Tag.DATA_LABEL_NORMAL_4];
const CHUNK_BYTES = 2048;
const MAX_RECORD_BYTES = PAYLOAD_TAGS.length * CHUNK_BYTES;

export class RelayMembershipStore {
  // Store metadata, the seed and any relay credentials as one atomic encrypted record.
  async save(realm: string, accountId: string, value: string, assertCurrent: () => void): Promise<void> {
    const query = await this.alias(realm, accountId);
    const encoder = new util.TextEncoder();
    const bytes = encoder.encodeInto(value);
    if (bytes.length === 0 || bytes.length > MAX_RECORD_BYTES) throw new Error('RELAY_MEMBERSHIP_TOO_LARGE');
    // SECRET is limited to 1024 bytes. API 14+ can encrypt the mutable data labels as well.
    // Keep an encrypted length+digest in SECRET to authenticate the ordered payload, including missing chunks.
    query.set(asset.Tag.SECRET, encoder.encodeInto(JSON.stringify({
      format: 2, length: bytes.length, digest: await this.digest(bytes),
    })));
    query.set(asset.Tag.REQUIRE_ATTR_ENCRYPTED, true);
    for (let i = 0; i < PAYLOAD_TAGS.length; i++) {
      const chunk = bytes.slice(i * CHUNK_BYTES, (i + 1) * CHUNK_BYTES);
      query.set(PAYLOAD_TAGS[i], chunk.length > 0 ? chunk : new Uint8Array([0]));
    }
    query.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    query.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    query.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    assertCurrent();
    await asset.add(query);
    assertCurrent();
  }

  async read(realm: string, accountId: string, assertCurrent: () => void): Promise<string | null> {
    const query = await this.alias(realm, accountId);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    assertCurrent();
    try {
      const result = await asset.query(query);
      assertCurrent();
      const value = result[0]?.get(asset.Tag.SECRET);
      if (value instanceof Uint8Array) {
        const text = util.TextDecoder.create('utf-8').decodeToString(value);
        const header = JSON.parse(text) as Record<string, Object>;
        // Read the earlier single-SECRET development format without rewriting it during a read.
        if (header['format'] !== 2) return text;
        const length = header['length'];
        if (typeof length !== 'number' || !Number.isSafeInteger(length) || length < 1 || length > MAX_RECORD_BYTES) {
          throw new Error('RELAY_INVALID_STORED_MEMBERSHIP');
        }
        const bytes = new Uint8Array(length);
        for (let i = 0; i * CHUNK_BYTES < length; i++) {
          const chunk = result[0].get(PAYLOAD_TAGS[i]);
          const expected = Math.min(CHUNK_BYTES, length - i * CHUNK_BYTES);
          if (!(chunk instanceof Uint8Array) || chunk.length !== expected) throw new Error('RELAY_INVALID_STORED_MEMBERSHIP');
          bytes.set(chunk, i * CHUNK_BYTES);
        }
        if (await this.digest(bytes) !== header['digest']) throw new Error('RELAY_INVALID_STORED_MEMBERSHIP');
        assertCurrent();
        return util.TextDecoder.create('utf-8').decodeToString(bytes);
      }
      throw new Error('RELAY_INVALID_STORED_MEMBERSHIP');
    } catch (error) {
      if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) return null;
      throw new Error('RELAY_MEMBERSHIP_UNAVAILABLE');
    }
  }

  async remove(realm: string, accountId: string, assertCurrent: () => void): Promise<void> {
    const query = await this.alias(realm, accountId);
    assertCurrent();
    try {
      await asset.remove(query);
    } catch (error) {
      if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) throw new Error('RELAY_MEMBERSHIP_UNAVAILABLE');
    }
    assertCurrent();
  }

  private async digest(bytes: Uint8Array): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: bytes });
    return new util.Base64Helper().encodeToStringSync((await digest.digest()).data);
  }

  private async alias(realm: string, accountId: string): Promise<asset.AssetMap> {
    if (!realm || !accountId) throw new Error('RELAY_ACCOUNT_REQUIRED');
    const encoder = new util.TextEncoder();
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: encoder.encodeInto(JSON.stringify([realm, accountId])) });
    const suffix = new util.Base64Helper().encodeToStringSync((await digest.digest()).data);
    const alias = new Map<asset.Tag, asset.Value>();
    alias.set(asset.Tag.ALIAS, encoder.encodeInto('cindy.relay.v1.' + suffix));
    // Encrypted attributes use a separate lookup namespace on Harmony Asset Store.
    alias.set(asset.Tag.REQUIRE_ATTR_ENCRYPTED, true);
    return alias;
  }
}
