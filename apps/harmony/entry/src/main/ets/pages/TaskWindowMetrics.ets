import { display, window } from '@kit.ArkUI';
import { taskWindowIsMultiWindow } from './TaskSplitLayout';

export class TaskWindowMetrics {
  safeWidth: number = 0;
  safeHeight: number = 0;
  leftInset: number = 0;
  rightInset: number = 0;
  topInset: number = 0;
  bottomInset: number = 0;
  windowWidth: number = 0;
  windowHeight: number = 0;
  creaseLeft: number = 0;
  creaseRight: number = 0;
  creaseTop: number = 0;
  creaseBottom: number = 0;
  horizontalHover: boolean = false;
  /** 系统分屏或悬浮窗；设备不支持窗口状态查询时按全屏处理。 */
  multiWindow: boolean = false;
}

export function readTaskWindowMetrics(hostWindow: window.Window,
  pxToVp: (value: number) => number): TaskWindowMetrics {
  const properties = hostWindow.getWindowProperties();
  const rect = properties.windowRect;
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
  result.leftInset = pxToVp(left);
  result.rightInset = pxToVp(right);
  result.topInset = pxToVp(top);
  result.bottomInset = pxToVp(bottom);
  result.windowWidth = pxToVp(rect.width);
  result.windowHeight = pxToVp(rect.height);
  if (!result.multiWindow) {
    try {
      const posture = display.getFoldStatus();
      if (posture !== display.FoldStatus.FOLD_STATUS_UNKNOWN && posture !== display.FoldStatus.FOLD_STATUS_FOLDED) {
        const region = display.getCurrentFoldCreaseRegion();
        if (properties.displayId !== undefined && region.displayId === properties.displayId) {
          for (const crease of region.creaseRects) {
            const start = display.convertGlobalToRelativeCoordinate({ x: crease.left, y: crease.top }, region.displayId);
            const end = display.convertGlobalToRelativeCoordinate({
              x: crease.left + crease.width,
              y: crease.top + crease.height,
            }, region.displayId);
            const x0 = Math.max(0, Math.min(start.position.x, end.position.x) - rect.left);
            const x1 = Math.min(rect.width, Math.max(start.position.x, end.position.x) - rect.left);
            const y0 = Math.max(0, Math.min(start.position.y, end.position.y) - rect.top);
            const y1 = Math.min(rect.height, Math.max(start.position.y, end.position.y) - rect.top);
            if (x1 <= x0 || y1 <= y0) continue;
            const width = x1 - x0;
            const height = y1 - y0;
            if (height > width && height >= rect.height * 0.8) {
              result.creaseLeft = result.creaseRight === 0 ? pxToVp(x0) : Math.min(result.creaseLeft, pxToVp(x0));
              result.creaseRight = Math.max(result.creaseRight, pxToVp(x1));
            } else if (width > height && width >= rect.width * 0.8) {
              result.horizontalHover = posture === display.FoldStatus.FOLD_STATUS_HALF_FOLDED
                || posture === display.FoldStatus.FOLD_STATUS_EXPANDED_WITH_SECOND_HALF_FOLDED
                || posture === display.FoldStatus.FOLD_STATUS_FOLDED_WITH_SECOND_HALF_FOLDED
                || posture === display.FoldStatus.FOLD_STATUS_HALF_FOLDED_WITH_SECOND_HALF_FOLDED
                || posture === display.FoldStatus.FOLD_STATUS_HALF_FOLDED_WITH_SECOND_EXPANDED;
              result.creaseTop = result.creaseBottom === 0 ? pxToVp(y0) : Math.min(result.creaseTop, pxToVp(y0));
              result.creaseBottom = Math.max(result.creaseBottom, pxToVp(y1));
            }
          }
        }
      }
    } catch (_error) {
      // Non-foldables and devices without crease geometry use the normal window layout.
    }
  }
  return result;
}
