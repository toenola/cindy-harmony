/**
 * Token 等敏感信息的安全存储（基于 @kit.ArkData 的 preferences）。
 *
 * preferences 落盘在应用沙箱内，对普通文件系统访问不可见；鸿蒙侧进程隔离
 * 下满足一期要求。若后续安全要求提升（如防 root 读取），可迁移到
 * @kit.AssetStoreKit 的 asset 加密存储——届时只需替换本类的内部实现，
 * 接口不变，并更新 decision-log。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'CindyStore';

const STORE_NAME = 'cindy_secure';
const KEY_DEVICE_ID_HINT = 'auth.deviceId';

export class SecureStore {
  private pref: preferences.Preferences | undefined = undefined;

  /** 必须在使用前调用一次（拿到 UIAbility 或 stage 的 context）。 */
  async init(context: common.Context): Promise<void> {
    if (this.pref !== undefined) {
      return;
    }
    const options: preferences.Options = {
      name: STORE_NAME,
    };
    this.pref = await preferences.getPreferences(context, options);
    hilog.info(DOMAIN, TAG, 'secure store initialized');
  }

  async get(key: string, defaultValue: string): Promise<string> {
    const pref = this.pref;
    if (!pref) {
      return defaultValue;
    }
    const value = await pref.get(key, defaultValue);
    if (typeof value === 'string') {
      return value;
    }
    return defaultValue;
  }

  async set(key: string, value: string): Promise<void> {
    const pref = this.pref;
    if (!pref) {
      throw new Error('SecureStore not initialized');
    }
    await pref.put(key, value);
    await pref.flush();
  }

  async remove(key: string): Promise<void> {
    const pref = this.pref;
    if (!pref) {
      return;
    }
    await pref.delete(key);
    await pref.flush();
  }

  /** 清空敏感信息（token 等）。deviceId 由调用方单独保留/清除，避免误删设备身份。 */
  async clearSensitive(): Promise<void> {
    const pref = this.pref;
    if (!pref) {
      return;
    }
    const raw = await pref.get(KEY_DEVICE_ID_HINT, '');
    let deviceId = '';
    if (typeof raw === 'string') {
      deviceId = raw;
    }
    await pref.clear();
    if (deviceId.length > 0) {
      await pref.put(KEY_DEVICE_ID_HINT, deviceId);
    }
    await pref.flush();
  }
}
