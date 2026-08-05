/**
 * 认证 Store：登录状态机 + token 生命周期。
 *
 * - token 持久化走 SecureStore（preferences，应用沙箱内）。
 * - deviceId 首次生成后持久化，verify-code 与 relay 都按它标识本设备
 *   （对齐 apps/mobile/src/auth/deviceId.ts 的语义）。
 * - getAccessToken() 在 access token 可能过期时自动用 refresh token 刷新，
 *   Device Link 每次重连前都会调它取新鲜 token。
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AuthApi, AuthApiError, LoginOutcome } from './AuthApi';
import { SecureStore } from '../storage/SecureStore';

const DOMAIN = 0x0000;
const TAG = 'CindyAuth';

const KEY_ACCESS = 'auth.accessToken';
const KEY_REFRESH = 'auth.refreshToken';
const KEY_DEVICE_ID = 'auth.deviceId';

export class AuthStore {
  private api: AuthApi = new AuthApi();
  private store: SecureStore = new SecureStore();
  private deviceId: string = '';
  private accessToken: string = '';
  private refreshToken: string = '';
  /** 登录状态（UI 订阅用）。 */
  private listeners: Array<() => void> = [];

  async init(context: common.Context): Promise<void> {
    await this.store.init(context);
  }

  /** 订阅变更；返回退订函数（页面 aboutToDisappear 调用）。 */
  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return () => {
      const idx = this.listeners.indexOf(listener);
      if (idx >= 0) {
        this.listeners.splice(idx, 1);
      }
    };
  }

  private notifyChanged(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  get isLoggedIn(): boolean {
    return this.accessToken.length > 0;
  }

  async ensureDeviceId(): Promise<string> {
    if (this.deviceId.length > 0) {
      return this.deviceId;
    }
    const existing = await this.store.get(KEY_DEVICE_ID, '');
    if (existing.length > 0) {
      this.deviceId = existing;
      return existing;
    }
    const next = util.generateRandomUUID();
    await this.store.set(KEY_DEVICE_ID, next);
    this.deviceId = next;
    hilog.info(DOMAIN, TAG, 'generated deviceId=%{public}s', next.slice(0, 8));
    return next;
  }

  /** 启动时恢复本地会话；返回 true = 已有可用 access token。 */
  async restoreSession(): Promise<boolean> {
    await this.ensureDeviceId();
    const access = await this.store.get(KEY_ACCESS, '');
    const refresh = await this.store.get(KEY_REFRESH, '');
    if (access.length > 0) {
      this.accessToken = access;
      this.refreshToken = refresh;
      this.notifyChanged();
      return true;
    }
    return false;
  }

  async requestCode(phone: string): Promise<void> {
    await this.api.requestPhoneCode(phone);
  }

  /** 验证码登录。非 ok 的 outcome 抛 AuthApiError（UI 提示需人工介入）。 */
  async loginWithCode(phone: string, code: string): Promise<void> {
    const deviceId = await this.ensureDeviceId();
    const outcome = await this.api.verifyPhoneCode(phone, code, deviceId);
    this.applyOutcome(outcome);
  }

  private applyOutcome(outcome: LoginOutcome): void {
    if (outcome.status !== 'ok' || outcome.accessToken.length === 0) {
      throw new AuthApiError(outcome.status.length > 0 ? outcome.status : 'UNKNOWN', 'login needs manual handling');
    }
    this.accessToken = outcome.accessToken;
    this.refreshToken = outcome.refreshToken;
    // 持久化；写入失败不阻断内存会话（下次启动重新登录即可）。
    void this.store.set(KEY_ACCESS, this.accessToken);
    void this.store.set(KEY_REFRESH, this.refreshToken);
    this.notifyChanged();
  }

  /**
   * 取当前 access token；本地缺失时尝试用 refresh token 换新。
   * 返回 null 表示无有效登录态（调用方按未登录处理）。
   */
  async getAccessToken(): Promise<string | null> {
    if (this.accessToken.length > 0) {
      return this.accessToken;
    }
    if (this.refreshToken.length === 0) {
      return null;
    }
    try {
      const outcome = await this.api.refresh(this.refreshToken, await this.ensureDeviceId());
      // refresh 响应是 tokenPair（accessToken/refreshToken/membership），没有 status 字段，
      // 与登录响应不同——成功只看 accessToken 非空。
      if (outcome.accessToken.length > 0) {
        this.accessToken = outcome.accessToken;
        if (outcome.refreshToken.length > 0) {
          this.refreshToken = outcome.refreshToken;
          void this.store.set(KEY_REFRESH, this.refreshToken);
        }
        void this.store.set(KEY_ACCESS, this.accessToken);
        return this.accessToken;
      }
      // 刷新失败（token 已失效）→ 清会话
      await this.logout();
      return null;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'refresh failed: %{public}s', JSON.stringify(e));
      return null;
    }
  }

  /**
   * 强制刷新 token（连接层收到 401 时调用）。清掉内存 access token 走 refresh；
   * 返回 null 表示 refresh 也失败（调用方保持重连退避，不主动登出）。
   */
  async forceRefreshToken(): Promise<string | null> {
    this.accessToken = '';
    return this.getAccessToken();
  }

  async logout(): Promise<void> {
    this.accessToken = '';
    this.refreshToken = '';
    // 只清 token 等敏感信息，保留 deviceId（设备身份与服务端一致）。
    await this.store.clearSensitive();
    this.notifyChanged();
  }
}
