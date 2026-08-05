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
  /** 后续登录需要确认账号时服务端给的票据 */
  loginTicket: string = '';
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
    }
    return outcome;
  }

  private readString(obj: Record<string, Object>, key: string): string {
    const v = obj[key];
    return typeof v === 'string' ? v : '';
  }
}
