/**
 * 认证 API（对齐 packages/auth-client/src/client.ts 的接口语义）。
 *
 * 一期只实现手机验证码登录路径：
 *   POST /api/auth/phone/request-code   → { status: 'sent' }
 *   POST /api/auth/phone/verify-code    → LoginOutcome
 *   POST /api/auth/refresh              → LoginOutcome（token 刷新）
 *
 * LoginOutcome 完整形态见 auth-client types.ts：
 *   ok → { accessToken, refreshToken, membership, ... }
 *   select_account / binding_required / sso_verification_required 一期
 *   按「需人工介入」处理（抛 AuthApiError 带 code，UI 层决定提示）。
 */

import { HarmonyHttp } from '../../network/HarmonyHttp';
import { AppConfig } from '../../AppConfig';

/** verify-code 的完整响应（非 ok 时只填 status 与附带字段）。 */
export class LoginOutcome {
  status: string = ''; // 'ok' | 'select_account' | 'binding_required' | 'sso_verification_required'
  accessToken: string = '';
  refreshToken: string = '';
  membershipId: string = '';
  displayName: string = '';
  email: string = '';
  /** 后续登录需要确认账号时服务端给的票据 */
  loginTicket: string = '';
}

export class AccountDeletionAvailability {
  available: boolean = false;
  channel: string = '';
  maskedTarget: string = '';
  manualAppleRevocationRequired: boolean = false;
}

export class AccountDeletionChallenge {
  challengeId: string = '';
  receiptToken: string = '';
  channel: string = '';
  maskedTarget: string = '';
  expiresAt: string = '';
}

export class AccountDeletionStatus {
  status: string = '';
  requestedAt: string = '';
  deleteAfter: string = '';
  processingAt: string = '';
  completedAt: string = '';
  cancelledAt: string = '';
}

export class AuthApiError extends Error {
  /** 认证服务返回的状态码或错误类型；'ok' 以外的 outcome 也算「需介入」。 */
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'AuthApiError';
    this.code = code;
  }
}

export class AuthApi {
  private http: HarmonyHttp = new HarmonyHttp();

  /** 发送手机验证码。返回后服务端已发出短信。 */
  async requestPhoneCode(phone: string): Promise<void> {
    const body = JSON.stringify({
      phone: phone,
      locale: AppConfig.locale,
    });
    const res = await this.http.requestJson(
      `${AppConfig.authApiBaseUrl}/api/auth/phone/request-code`,
      'POST',
      {},
      body,
    );
    if (res.statusCode >= 300) {
      throw new AuthApiError(`HTTP_${res.statusCode}`, `request-code ${res.statusCode}`);
    }
  }

  /** 校验手机验证码并换取登录结果。 */
  async verifyPhoneCode(phone: string, code: string, deviceId: string): Promise<LoginOutcome> {
    const body = JSON.stringify({
      phone: phone,
      code: code,
      deviceId: deviceId,
      clientType: AppConfig.clientType,
      locale: AppConfig.locale,
    });
    const res = await this.http.requestJson(
      `${AppConfig.authApiBaseUrl}/api/auth/phone/verify-code`,
      'POST',
      {},
      body,
    );
    if (res.statusCode >= 300) {
      throw new AuthApiError(`HTTP_${res.statusCode}`, `verify-code ${res.statusCode}`);
    }
    return this.parseLoginOutcome(res.body);
  }

  /** 用 refresh token 刷新 access token（桌面端 token 轮换语义相同）。 */
  async refresh(refreshToken: string, deviceId: string): Promise<LoginOutcome> {
    const body = JSON.stringify({
      refreshToken: refreshToken,
      deviceId: deviceId,
      clientType: AppConfig.clientType,
    });
    const res = await this.http.requestJson(
      `${AppConfig.authApiBaseUrl}/api/auth/refresh`,
      'POST',
      {},
      body,
    );
    if (res.statusCode >= 300) {
      throw new AuthApiError(`HTTP_${res.statusCode}`, `refresh ${res.statusCode}`);
    }
    return this.parseLoginOutcome(res.body);
  }

  async getAccountDeletionAvailability(accessToken: string): Promise<AccountDeletionAvailability> {
    const headers: Record<string, string> = {};
    headers['Authorization'] = `Bearer ${accessToken}`;
    const res = await this.http.requestJson(
      `${AppConfig.authApiBaseUrl}/api/auth/account/deletion`,
      'GET',
      headers,
    );
    if (res.statusCode >= 300) {
      throw this.responseError(res.body, res.statusCode, 'account deletion');
    }
    let obj: Record<string, Object>;
    try {
      obj = JSON.parse(res.body) as Record<string, Object>;
    } catch (_) {
      throw new AuthApiError('INVALID_RESPONSE', 'account deletion response is not valid json');
    }
    const result = new AccountDeletionAvailability();
    result.available = obj['available'] === true;
    const verification = obj['verification'];
    if (verification !== undefined && verification !== null
      && typeof verification === 'object' && !Array.isArray(verification)) {
      const record = verification as Record<string, Object>;
      result.channel = this.readString(record, 'channel');
      result.maskedTarget = this.readString(record, 'maskedTarget');
    }
    result.manualAppleRevocationRequired = obj['manualAppleRevocationRequired'] === true;
    return result;
  }

  async requestAccountDeletionChallenge(accessToken: string): Promise<AccountDeletionChallenge> {
    const headers: Record<string, string> = {};
    headers['Authorization'] = `Bearer ${accessToken}`;
    const res = await this.http.requestJson(
      `${AppConfig.authApiBaseUrl}/api/auth/account/deletion/challenge`,
      'POST',
      headers,
      JSON.stringify({ locale: AppConfig.locale }),
    );
    if (res.statusCode >= 300) {
      throw this.responseError(res.body, res.statusCode, 'account deletion challenge');
    }
    let obj: Record<string, Object>;
    try {
      obj = JSON.parse(res.body) as Record<string, Object>;
    } catch (_) {
      throw new AuthApiError('INVALID_RESPONSE', 'account deletion challenge is not valid json');
    }
    const result = new AccountDeletionChallenge();
    result.challengeId = this.readString(obj, 'challengeId');
    result.receiptToken = this.readString(obj, 'receiptToken');
    result.channel = this.readString(obj, 'channel');
    result.maskedTarget = this.readString(obj, 'maskedTarget');
    result.expiresAt = this.readString(obj, 'expiresAt');
    if (result.challengeId.length === 0 || result.receiptToken.length === 0) {
      throw new AuthApiError('INVALID_RESPONSE', 'account deletion challenge is incomplete');
    }
    return result;
  }

  async confirmAccountDeletion(
    accessToken: string,
    challengeId: string,
    receiptToken: string,
    code: string,
  ): Promise<AccountDeletionStatus> {
    const headers: Record<string, string> = {};
    headers['Authorization'] = `Bearer ${accessToken}`;
    const res = await this.http.requestJson(
      `${AppConfig.authApiBaseUrl}/api/auth/account/deletion/confirm`,
      'POST',
      headers,
      JSON.stringify({
        challengeId,
        receiptToken,
        code,
        acknowledged: true,
      }),
    );
    if (res.statusCode >= 300) {
      throw this.responseError(res.body, res.statusCode, 'account deletion confirm');
    }
    let obj: Record<string, Object>;
    try {
      obj = JSON.parse(res.body) as Record<string, Object>;
    } catch (_) {
      throw new AuthApiError('INVALID_RESPONSE', 'account deletion status is not valid json');
    }
    return this.parseAccountDeletionStatus(obj);
  }

  /** 查询确认后保留的 receipt；该接口不再携带登录 token。 */
  async getAccountDeletionStatus(receiptToken: string): Promise<AccountDeletionStatus> {
    const res = await this.http.requestJson(
      `${AppConfig.authApiBaseUrl}/api/auth/account/deletion/status`,
      'POST',
      {},
      JSON.stringify({ receiptToken }),
    );
    if (res.statusCode >= 300) {
      throw this.responseError(res.body, res.statusCode, 'account deletion status');
    }
    let obj: Record<string, Object>;
    try {
      obj = JSON.parse(res.body) as Record<string, Object>;
    } catch (_) {
      throw new AuthApiError('INVALID_RESPONSE', 'account deletion status is not valid json');
    }
    return this.parseAccountDeletionStatus(obj);
  }

  private parseLoginOutcome(rawBody: string): LoginOutcome {
    const outcome = new LoginOutcome();
    let obj: Record<string, Object> = {};
    try {
      obj = JSON.parse(rawBody) as Record<string, Object>;
    } catch (e) {
      throw new AuthApiError('INVALID_RESPONSE', 'login outcome is not valid json');
    }
    const status = this.readString(obj, 'status');
    outcome.status = status;
    outcome.accessToken = this.readString(obj, 'accessToken');
    outcome.refreshToken = this.readString(obj, 'refreshToken');
    outcome.loginTicket = this.readString(obj, 'loginTicket');

    const membership = obj['membership'];
    if (membership && typeof membership === 'object') {
      const m = membership as Record<string, Object>;
      outcome.membershipId = this.readString(m, 'id');
      outcome.displayName = this.readString(m, 'displayName');
      outcome.email = this.readString(m, 'email');
    }
    return outcome;
  }

  private parseAccountDeletionStatus(obj: Record<string, Object>): AccountDeletionStatus {
    const result = new AccountDeletionStatus();
    result.status = this.readString(obj, 'status');
    result.requestedAt = this.readString(obj, 'requestedAt');
    result.deleteAfter = this.readString(obj, 'deleteAfter');
    result.processingAt = this.readString(obj, 'processingAt');
    result.completedAt = this.readString(obj, 'completedAt');
    result.cancelledAt = this.readString(obj, 'cancelledAt');
    if (result.status !== 'pending' && result.status !== 'processing'
      && result.status !== 'completed' && result.status !== 'cancelled') {
      throw new AuthApiError('INVALID_RESPONSE', 'account deletion status is incomplete');
    }
    return result;
  }

  private responseError(body: string, statusCode: number, operation: string): AuthApiError {
    let code = `HTTP_${statusCode}`;
    let message = `${operation} ${statusCode}`;
    try {
      const obj = JSON.parse(body) as Record<string, Object>;
      const directCode = this.readString(obj, 'code');
      const directMessage = this.readString(obj, 'message');
      if (directCode.length > 0) code = directCode;
      if (directMessage.length > 0) message = directMessage;
      const nested = obj['error'];
      if (nested !== undefined && nested !== null && typeof nested === 'object'
        && !Array.isArray(nested)) {
        const error = nested as Record<string, Object>;
        const nestedCode = this.readString(error, 'code');
        const nestedMessage = this.readString(error, 'message');
        if (nestedCode.length > 0) code = nestedCode;
        if (nestedMessage.length > 0) message = nestedMessage;
      }
    } catch (_) {
    }
    return new AuthApiError(code, message);
  }

  private readString(obj: Record<string, Object>, key: string): string {
    const v = obj[key];
    return typeof v === 'string' ? v : '';
  }
}
