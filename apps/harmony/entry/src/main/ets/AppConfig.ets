/**
 * 应用配置：官方端点（CN / Global 两套）与客户端身份。
 *
 * 端点来自 config/endpoint*.json（仓库根目录），与桌面端构建配置同源。
 * 一期在编译期静态选择区域；如需运行时切换，改为从 SecureStore 读取。
 *
 * 注意：账号体系按区域隔离（auth realm 分离），CN 账号不能连 Global relay。
 * 用户桌面端装的是哪个区域版本，这里就配哪个区域。
 */

export class AppConfig {
  /** 当前区域：'cn' | 'global'。默认 cn（cindy.com.cn）。 */
  static readonly region: string = 'cn';

  /** 认证 API base（验证码登录 / 刷新 / 账号）。 */
  static readonly authApiBaseUrl: string = 'https://auth.cindy.com.cn';

  /** Device Link relay REST base（设备列表 / media presign）。 */
  static readonly deviceLinkApiBaseUrl: string = 'https://device-link.cindy.com.cn';

  /** Device Link WebSocket 端点（http→ws / https→wss 推导规则）。 */
  static readonly deviceLinkWsUrl: string =
    'wss://device-link.cindy.com.cn/api/device-link/ws';

  /**
   * 认证 clientType。服务端按值分派行为，mobile 端固定传 'mobile'；
   * 鸿蒙端作为手机形态沿用该值（服务端无需感知新平台）。
   */
  static readonly clientType: string = 'mobile';

  /** hello 帧的 platform 字段（presence 展示用，允许新值）。 */
  static readonly platform: string = 'harmony';

  /** 认证接口 locale 参数。 */
  static readonly locale: string = 'zh-CN';

  /**
   * 本应用版本（hello appVersion / link-open appVersion）。
   *
   * 必须与 `AppScope/app.json5` 的 `versionName` 保持一致：设置页展示与
   * Device Link 上报共用这一个值，漂移会让被控端看到错误的客户端版本。
   */
  static readonly appVersion: string = '1.1.0';
}

/** Global 区域端点（换区时把上面的 region/authApiBaseUrl/... 换成这些值）。 */
export class AppConfigGlobal {
  static readonly region: string = 'global';
  static readonly authApiBaseUrl: string = 'https://auth.cindy.app';
  static readonly deviceLinkApiBaseUrl: string = 'https://device-link.cindy.app';
  static readonly deviceLinkWsUrl: string =
    'wss://device-link.cindy.app/api/device-link/ws';
}
