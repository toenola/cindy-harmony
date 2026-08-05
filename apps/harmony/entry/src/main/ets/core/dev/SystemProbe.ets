/**
 * 切片 0 系统能力自检工具。
 *
 * 不提供任何过渡界面：三个探针都是可独立调用的方法，结果走 hilog。
 * 在 DevEco 中通过 ohosTest（真机/模拟器）调用，或在 EntryAbility 临时
 * 调用一次后移除。全部通过后更新 decision-log 并进入切片 1。
 *
 * 用法示例（ohosTest 内）：
 *   const ok = await SystemProbe.probeWs('wss://...', { Authorization: 'Bearer x' });
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HarmonyWsAdapter } from '../../network/HarmonyWsAdapter';
import { WsCallbacks } from '../../network/WsAdapter';
import { HarmonyHttp } from '../../network/HarmonyHttp';
import { SecureStore } from '../storage/SecureStore';

const DOMAIN = 0x0000;
const TAG = 'CindyProbe';

export class SystemProbe {
  /**
   * 验证 wss + 自定义 Header 握手：连接成功即关闭，失败返回 false。
   * 需等待 onOpen/onError 回调，超时判失败。
   */
  static probeWs(url: string, headers: Record<string, string>, timeoutMs: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const adapter = new HarmonyWsAdapter();
      const callbacks = new WsCallbacks();
      let settled = false;

      callbacks.onOpen = () => {
        if (settled) {
          return;
        }
        settled = true;
        hilog.info(DOMAIN, TAG, '[ws] open OK: %{public}s', url);
        adapter.close(1000, 'probe done');
        resolve(true);
      };
      callbacks.onError = (err: Error) => {
        if (settled) {
          return;
        }
        settled = true;
        hilog.error(DOMAIN, TAG, '[ws] FAILED: %{public}s (%{public}s)', url, err.message);
        adapter.terminate();
        resolve(false);
      };
      callbacks.onClose = (code: number, reason: string) => {
        hilog.info(DOMAIN, TAG, '[ws] closed code=%{public}d reason=%{public}s', code, reason);
      };

      adapter.setCallbacks(callbacks);
      adapter.connect(url, headers);

      setTimeout(() => {
        if (!settled) {
          settled = true;
          hilog.error(DOMAIN, TAG, '[ws] TIMEOUT after %{public}d ms: %{public}s', timeoutMs, url);
          adapter.terminate();
          resolve(false);
        }
      }, timeoutMs);
    });
  }

  /** 验证 HTTP / JSON / TLS：GET 目标 URL，2xx 即通过。 */
  static probeHttp(url: string, timeoutMs: number): Promise<boolean> {
    const client = new HarmonyHttp();
    return client.requestJson(url, 'GET', {}, undefined, timeoutMs)
      .then((data: { statusCode: number; body: string }) => {
        const ok = data.statusCode >= 200 && data.statusCode < 300;
        if (ok) {
          hilog.info(DOMAIN, TAG, '[http] OK status=%{public}d url=%{public}s', data.statusCode, url);
        } else {
          hilog.error(DOMAIN, TAG, '[http] status=%{public}d url=%{public}s', data.statusCode, url);
        }
        return ok;
      })
      .catch((err: Error) => {
        hilog.error(DOMAIN, TAG, '[http] FAILED: %{public}s', err.message);
        return false;
      });
  }

  /** 验证安全存储：写 → 读 → 删 闭环。 */
  static async probeStorage(context: common.Context): Promise<boolean> {
    try {
      const store = new SecureStore();
      await store.init(context);
      const key = 'probe_key';
      const value = 'probe_value_' + Date.now().toString();
      await store.set(key, value);
      const read = await store.get(key, '');
      await store.remove(key);
      const afterRemove = await store.get(key, '');
      const ok = read === value && afterRemove === '';
      if (ok) {
        hilog.info(DOMAIN, TAG, '[storage] OK read-back matched, remove clean');
      } else {
        hilog.error(DOMAIN, TAG, '[storage] MISMATCH read=%{public}s expect=%{public}s', read, value);
      }
      return ok;
    } catch (e) {
      hilog.error(DOMAIN, TAG, '[storage] FAILED: %{public}s', JSON.stringify(e));
      return false;
    }
  }
}
