import { common } from '@kit.AbilityKit';

/**
 * v1.2.0 新增界面文案的统一资源读取入口。
 *
 * 静态组件直接使用 $r('app.string.v12_*')，需要拼接运行时参数的状态
 * 通过这里读取，确保格式化仍然走当前系统的 locale 资源，而不是回到硬编码。
 */
export function harmonyV12String(
  context: common.Context | undefined,
  name: string,
  ...args: Array<string | number>
): string {
  if (context === undefined) return '';
  try {
    return context.resourceManager.getStringByNameSync(name, ...args);
  } catch (_error) {
    return '';
  }
}
