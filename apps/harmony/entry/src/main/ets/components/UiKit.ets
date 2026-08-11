/**
 * 鸿蒙端共享 UI 规范：字号缩放、圆角、间距与动效常量。
 *
 * 视觉口径以 docs/design-rules/DESIGN.md 为准：
 * - 圆角只有三档：8（内部控件）/ 12（容器）/ 胶囊（交互元素）；
 * - 动效只做功能性过渡，时长分 80/150/200/250ms 四档，曲线统一；
 * - 列表行、卡片等可点区域统一使用系统 clickEffect 弹性按压反馈。
 */

/** 会话域字号缩放：对齐 iOS 详情页信息密度，全局唯一来源。 */
const UI_FONT_SCALE = 0.84;
const UI_MIN_FONT_SIZE = 8;
const UI_MIN_LINE_HEIGHT = 10;

export function uiFontSize(base: number): number {
  return Math.max(UI_MIN_FONT_SIZE, Math.round(base * UI_FONT_SCALE));
}

export function uiLineHeight(base: number): number {
  return Math.max(UI_MIN_LINE_HEIGHT, Math.round(base * UI_FONT_SCALE));
}

/** 三档圆角（DESIGN.md §5）：内部控件 / 容器 / 胶囊。 */
export const UI_RADIUS_CONTROL = 8;
export const UI_RADIUS_CONTAINER = 12;
export const UI_RADIUS_PILL = 999;

/** 动效时长档位（DESIGN.md §14.4）。 */
export const UI_MOTION_INSTANT = 80;
export const UI_MOTION_FAST = 150;
export const UI_MOTION_BASE = 200;
/** 功能性加载圆环完整旋转一周的语义周期（DESIGN.md §14.4）。 */
export const UI_MOTION_SPINNER_CYCLE = 1000;

/** 进入/展开使用的 ease-out 曲线；收起用 EaseIn，位移/尺寸用 EaseInOut。 */
export const UI_CURVE_ENTER: Curve = Curve.EaseOut;
export const UI_CURVE_EXIT: Curve = Curve.EaseIn;
export const UI_CURVE_MOVE: Curve = Curve.EaseInOut;

/** 列表行/卡片的统一按压反馈（HarmonyOS 推荐 spring 动效）。 */
export const UI_CLICK_EFFECT: ClickEffect = {
  level: ClickEffectLevel.LIGHT,
  scale: 0.98,
};

/** 列表和菜单整行的按压反馈：只做极轻缩放，避免宽组件边缘明显跳动。 */
export const UI_LIST_CLICK_EFFECT: ClickEffect = {
  level: ClickEffectLevel.LIGHT,
  scale: 0.995,
};

/** 透明 icon 按钮的按压反馈（幅度更小，避免图标跳动）。 */
export const UI_ICON_CLICK_EFFECT: ClickEffect = {
  level: ClickEffectLevel.LIGHT,
  scale: 0.96,
};

/** 统一触发普通状态变化，供折叠、选中和局部内容切换使用。 */
export function uiAnimateState(context: UIContext, apply: () => void): void {
  context.animateTo({ duration: UI_MOTION_BASE, curve: UI_CURVE_MOVE }, apply);
}

/** 统一触发轻量可见性变化，供菜单、遮罩和即时提示使用。 */
export function uiAnimateFastState(context: UIContext, apply: () => void): void {
  context.animateTo({ duration: UI_MOTION_FAST, curve: UI_CURVE_MOVE }, apply);
}

/** 轻量浮层（菜单 / 弹层）的进入过渡：淡入 + 轻微下移归位。 */
export function uiOverlayEnterTransition(): TransitionEffect {
  return TransitionEffect.OPACITY
    .animation({ duration: UI_MOTION_FAST, curve: UI_CURVE_ENTER })
    .combine(TransitionEffect.translate({ y: -6 })
      .animation({ duration: UI_MOTION_FAST, curve: UI_CURVE_ENTER }));
}

/** 轻量浮层退出只淡出，不做位移（退出永远比进入快）。 */
export function uiOverlayExitTransition(): TransitionEffect {
  return TransitionEffect.OPACITY
    .animation({ duration: UI_MOTION_INSTANT, curve: UI_CURVE_EXIT });
}

/** 轻量浮层完整进退场：进入轻移淡入，退出原地快速淡出。 */
export function uiOverlayTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(uiOverlayEnterTransition(), uiOverlayExitTransition());
}

/** 区块内容出现/消失的通用过渡（折叠展开、提示条等）。 */
export function uiRevealTransition(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.animation({ duration: UI_MOTION_FAST, curve: UI_CURVE_ENTER }),
    TransitionEffect.OPACITY.animation({ duration: UI_MOTION_INSTANT, curve: UI_CURVE_EXIT }),
  );
}
