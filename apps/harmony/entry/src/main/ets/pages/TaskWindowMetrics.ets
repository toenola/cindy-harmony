import { window } from '@kit.ArkUI';
import { taskWindowIsMultiWindow } from './TaskSplitLayout';

export class TaskWindowMetrics {
  safeWidth: number = 0;
  safeHeight: number = 0;
  /** 系统分屏或悬浮窗；设备不支持窗口状态查询时按全屏处理。 */
  multiWindow: boolean = false;
}

export function readTaskWindowMetrics(hostWindow: window.Window,
  pxToVp: (value: number) => number): TaskWindowMetrics {
  const rect = hostWindow.getWindowProperties().windowRect;
  const system = hostWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
  const navigation = hostWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
  const cutout = hostWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
  const left = Math.max(system.leftRect.width, navigation.leftRect.width, cutout.leftRect.width);
  const right = Math.max(system.rightRect.width, navigation.rightRect.width, cutout.rightRect.width);
  const top = Math.max(system.topRect.height, navigation.topRect.height, cutout.topRect.height);
  const bottom = Math.max(system.bottomRect.height, navigation.bottomRect.height, cutout.bottomRect.height);
  const result = new TaskWindowMetrics();
  result.safeWidth = Math.max(0, pxToVp(rect.width - left - right));
  result.safeHeight = Math.max(0, pxToVp(rect.height - top - bottom));
  try {
    result.multiWindow = taskWindowIsMultiWindow(Number(hostWindow.getWindowStatus()));
  } catch (_error) {
    result.multiWindow = false;
  }
  return result;
}
