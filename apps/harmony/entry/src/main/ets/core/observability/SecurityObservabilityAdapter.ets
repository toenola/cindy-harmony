/**
 * 可选安全观测身份 adapter。
 *
 * 语义对齐 `apps/mobile/src/auth/AuthContext.tsx` 的 THEMIS 绑定：
 * - 登录完成后写入当前用户标识；
 * - 登出**开始**即清空（避免崩溃 / 强杀上报误归到上一个账号）；
 * - SDK 不存在、初始化失败或当前区域不启用时安全 no-op，绝不阻断登录与退出。
 *
 * 本文件刻意**不引用任何厂商 SDK**：Harmony 侧真实 SDK 尚未提供，接入前必须先完成
 * 隐私、区域、依赖、签名和冷启动影响评审（见 docs/version/v1.1.0/开发计划.md 阶段 6）。
 * 默认实现是 no-op，真实实现由构建配置在运行时注入 `SecurityObservabilitySink`。
 *
 * 硬性约束（对齐 Mobile 差异评估「THEMIS 已完成判定」）：
 * - **不持久化 userId**：只在内存里交给 sink，不写 Preferences、不落盘；
 * - **不输出日志**：任何日志都可能把用户标识带进可上传的日志文件；
 * - 失败一律吞掉，不向上抛。
 */

/** 真实 SDK 需要实现的最小接口；由构建配置注入。 */
export interface SecurityObservabilitySink {
  /** 绑定当前登录用户标识。 */
  bindUser(userId: string): void;
  /** 清空用户绑定（登出 / 换号）。 */
  clearUser(): void;
}

/**
 * 观测身份 adapter。
 *
 * 未注入 sink 时所有调用都是安全 no-op；区域开关关闭时同样不做任何事。
 */
export class SecurityObservabilityAdapter {
  private sink: SecurityObservabilitySink | undefined = undefined;
  /** 当前区域 / 构建是否启用观测；默认关闭，必须显式打开。 */
  private enabled: boolean = false;

  /**
   * 注入真实实现。`enabled` 为 false 时即使有 sink 也不上报，
   * 用于「SDK 存在但当前区域不允许」的情况。
   */
  configure(sink: SecurityObservabilitySink | undefined, enabled: boolean): void {
    this.sink = sink;
    this.enabled = enabled;
  }

  isActive(): boolean {
    return this.enabled && this.sink !== undefined;
  }

  /** 登录完成后绑定用户标识；空 userId 视为清空。 */
  bindUser(userId: string): void {
    if (!this.isActive()) return;
    const trimmed = userId.trim();
    if (trimmed.length === 0) {
      this.clearUser();
      return;
    }
    try {
      // 失败不阻断认证：观测是可选能力，登录成功与否与它无关。
      this.sink?.bindUser(trimmed);
    } catch (e) {
      // 刻意不记日志：userId 不得进入任何可上传的日志文件。
    }
  }

  /** 登出开始即调用，确保后续崩溃上报不再归属上一个账号。 */
  clearUser(): void {
    if (!this.isActive()) return;
    try {
      this.sink?.clearUser();
    } catch (e) {
      // 同上：静默降级。
    }
  }
}
