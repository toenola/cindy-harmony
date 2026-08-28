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
import {
  AccountDeletionAvailability, AccountDeletionChallenge, AccountDeletionStatus,
  AuthApi, AuthApiError, LoginOutcome,
} from './AuthApi';
import { SecureStore } from '../storage/SecureStore';
import { safeErrorMessage } from '../tasks/TaskModels';

const DOMAIN = 0x0000;
const TAG = 'CindyAuth';

const KEY_ACCESS = 'auth.accessToken';
const KEY_REFRESH = 'auth.refreshToken';
const KEY_DEVICE_ID = 'auth.deviceId';
const KEY_RELAY_USER_ID = 'auth.relayUserId';
const KEY_ACCOUNT_NAME = 'auth.accountName';
const KEY_ACCOUNT_EMAIL = 'auth.accountEmail';
const KEY_ACCOUNT_DELETION_RECEIPT = 'auth.accountDeletionReceipt';

export class AuthStore {
  private api: AuthApi = new AuthApi();
  private store: SecureStore = new SecureStore();
  private deviceId: string = '';
  private accessToken: string = '';
  private refreshToken: string = '';
  /** relay hello-ack 的稳定账号 id；仅用于隔离可丢弃的本地列表快照。 */
  private relayUserId: string = '';
  /** 当前 membership 展示名；用于设置页账号头部，不参与鉴权。 */
  private accountName: string = '';
  /** 当前 membership 邮箱；用于设置页账号头部，不参与鉴权。 */
  private accountEmail: string = '';
  /** 注销确认后用于登录页查询状态的短期 receipt；普通登出会清除。 */
  private accountDeletionReceipt: string = '';
  /** 登录/登出账号代次；旧网络响应不得跨代写回新账号状态。 */
  private authEpoch: number = 0;
  /** 同一账号代次只允许一个 refresh 在途，避免并发 401 互相覆盖 token pair。 */
  private refreshInFlight: Promise<string | null> | undefined = undefined;
  private refreshInFlightEpoch: number = -1;
  /** 登录状态（UI 订阅用）。 */
  private listeners: Array<() => void> = [];
  private logoutCleanup: (() => Promise<void>) | undefined = undefined;

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

  setLogoutCleanup(cleanup: () => Promise<void>): void {
    this.logoutCleanup = cleanup;
  }

  get isLoggedIn(): boolean {
    // 冷启动时 access 可能尚未刷新，但只要 refresh 仍在就应进入主流程，
    // 由首次网络请求统一换取新 access；两者都为空才是真正的未登录。
    return this.accessToken.length > 0 || this.refreshToken.length > 0;
  }

  get cacheAccountId(): string {
    return this.relayUserId;
  }

  get displayName(): string {
    return this.accountName;
  }

  get email(): string {
    return this.accountEmail;
  }

  get deletionReceipt(): string {
    return this.accountDeletionReceipt;
  }

  get sessionEpoch(): number {
    return this.authEpoch;
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

  /** 启动时恢复本地会话；返回 true = 有可恢复的登录凭据。 */
  async restoreSession(): Promise<boolean> {
    await this.ensureDeviceId();
    const access = await this.store.get(KEY_ACCESS, '');
    const refresh = await this.store.get(KEY_REFRESH, '');
    this.relayUserId = await this.store.get(KEY_RELAY_USER_ID, '');
    this.accountName = await this.store.get(KEY_ACCOUNT_NAME, '');
    this.accountEmail = await this.store.get(KEY_ACCOUNT_EMAIL, '');
    this.accountDeletionReceipt = await this.store.get(KEY_ACCOUNT_DELETION_RECEIPT, '');
    // access 可能在上次进程退出前已被清空，但 refresh 仍然有效；必须恢复它，
    // 否则冷启动后的第一次 Device Link 会被误判为未登录。
    this.accessToken = access;
    this.refreshToken = refresh;
    if (access.length > 0 || refresh.length > 0) {
      this.authEpoch += 1;
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
    this.accountName = outcome.displayName.trim();
    this.accountEmail = outcome.email.trim();
    // 新登录已经进入正常会话，旧账号的注销状态不应泄露到新账号。
    this.accountDeletionReceipt = '';
    this.authEpoch += 1;
    // 持久化；写入失败不阻断内存会话（下次启动重新登录即可）。
    void this.store.set(KEY_ACCESS, this.accessToken);
    void this.store.set(KEY_REFRESH, this.refreshToken);
    if (this.accountName.length > 0) void this.store.set(KEY_ACCOUNT_NAME, this.accountName);
    else void this.store.remove(KEY_ACCOUNT_NAME);
    if (this.accountEmail.length > 0) void this.store.set(KEY_ACCOUNT_EMAIL, this.accountEmail);
    else void this.store.remove(KEY_ACCOUNT_EMAIL);
    void this.store.remove(KEY_ACCOUNT_DELETION_RECEIPT);
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

    const epoch = this.authEpoch;
    const existing = this.refreshInFlight;
    if (existing !== undefined && this.refreshInFlightEpoch === epoch) {
      return await existing;
    }
    const refreshToken = this.refreshToken;
    const operation = this.refreshAccessToken(refreshToken, epoch);
    this.refreshInFlight = operation;
    this.refreshInFlightEpoch = epoch;
    void operation.finally(() => {
      if (this.refreshInFlight === operation) {
        this.refreshInFlight = undefined;
        this.refreshInFlightEpoch = -1;
      }
    });
    return await operation;
  }

  private async refreshAccessToken(refreshToken: string, epoch: number): Promise<string | null> {
    try {
      const outcome = await this.api.refresh(refreshToken, await this.ensureDeviceId());
      // refresh 响应是 tokenPair（accessToken/refreshToken/membership），没有 status 字段，
      // 与登录响应不同——成功只看 accessToken 非空。旧账号代次的回包不得写入新会话。
      if (this.authEpoch !== epoch || this.refreshToken !== refreshToken) {
        return null;
      }
      if (outcome.accessToken.length > 0) {
        this.accessToken = outcome.accessToken;
        if (outcome.displayName.trim().length > 0) {
          this.accountName = outcome.displayName.trim();
          void this.store.set(KEY_ACCOUNT_NAME, this.accountName);
        }
        if (outcome.email.trim().length > 0) {
          this.accountEmail = outcome.email.trim();
          void this.store.set(KEY_ACCOUNT_EMAIL, this.accountEmail);
        }
        if (outcome.refreshToken.length > 0) {
          this.refreshToken = outcome.refreshToken;
          void this.store.set(KEY_REFRESH, this.refreshToken);
        }
        void this.store.set(KEY_ACCESS, this.accessToken);
        return this.accessToken;
      }
      // 刷新失败（token 已失效）→ 清会话；只清理仍属于同一代次的会话。
      if (this.authEpoch === epoch && this.refreshToken === refreshToken) {
        await this.logout();
      }
      return null;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'refresh failed: %{public}s', safeErrorMessage(e));
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

  async getAccountDeletionAvailability(): Promise<AccountDeletionAvailability> {
    const token = await this.getAccessToken();
    if (token === null || token.length === 0) throw new AuthApiError('UNAUTHENTICATED', 'not signed in');
    return await this.api.getAccountDeletionAvailability(token);
  }

  async requestAccountDeletionChallenge(): Promise<AccountDeletionChallenge> {
    const token = await this.getAccessToken();
    if (token === null || token.length === 0) throw new AuthApiError('UNAUTHENTICATED', 'not signed in');
    const challenge = await this.api.requestAccountDeletionChallenge(token);
    this.accountDeletionReceipt = challenge.receiptToken;
    await this.store.set(KEY_ACCOUNT_DELETION_RECEIPT, this.accountDeletionReceipt);
    this.notifyChanged();
    return challenge;
  }

  async confirmAccountDeletion(
    challengeId: string,
    receiptToken: string,
    code: string,
  ): Promise<AccountDeletionStatus> {
    const token = await this.getAccessToken();
    if (token === null || token.length === 0) throw new AuthApiError('UNAUTHENTICATED', 'not signed in');
    return await this.api.confirmAccountDeletion(token, challengeId, receiptToken, code);
  }

  async getAccountDeletionStatus(): Promise<AccountDeletionStatus | null> {
    if (this.accountDeletionReceipt.length === 0) return null;
    return await this.api.getAccountDeletionStatus(this.accountDeletionReceipt);
  }

  async clearAccountDeletionReceipt(): Promise<void> {
    this.accountDeletionReceipt = '';
    await this.store.remove(KEY_ACCOUNT_DELETION_RECEIPT);
    this.notifyChanged();
  }

  /** 注销确认成功后清理本地会话，但保留 receipt 供登录页展示服务端状态。 */
  async completeAccountDeletion(): Promise<void> {
    await this.clearSession(true);
  }

  /**
   * hello-ack 到达后记住稳定账号 id。返回 true 表示账号作用域发生变化，调用方
   * 必须让旧请求/旧快照失效并重新拉取。
   */
  rememberRelayUserId(userId: string): boolean {
    if (userId.length === 0 || userId === this.relayUserId) return false;
    this.relayUserId = userId;
    this.authEpoch += 1;
    void this.store.set(KEY_RELAY_USER_ID, userId);
    return true;
  }

  async logout(): Promise<void> {
    await this.clearSession(false);
  }

  private async clearSession(preserveDeletionReceipt: boolean): Promise<void> {
    this.authEpoch += 1;
    this.accessToken = '';
    this.refreshToken = '';
    this.relayUserId = '';
    this.accountName = '';
    this.accountEmail = '';
    if (!preserveDeletionReceipt) this.accountDeletionReceipt = '';
    if (this.logoutCleanup !== undefined) {
      await this.logoutCleanup();
    }
    // 只清 token 等敏感信息，保留 deviceId（设备身份与服务端一致）。
    if (preserveDeletionReceipt) {
      await this.store.remove(KEY_ACCESS);
      await this.store.remove(KEY_REFRESH);
      await this.store.remove(KEY_RELAY_USER_ID);
      await this.store.remove(KEY_ACCOUNT_NAME);
      await this.store.remove(KEY_ACCOUNT_EMAIL);
    } else {
      await this.store.clearSensitive();
    }
    this.notifyChanged();
  }
}
