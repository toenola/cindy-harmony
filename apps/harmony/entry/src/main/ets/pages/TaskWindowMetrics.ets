import { window } from '@kit.ArkUI';

export class TaskWindowMetrics {
  safeWidth: number = 0;
  safeHeight: number = 0;
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
  return result;
}
