/** 共享 UI 角色与兼容桥接，见 apps/harmony/docs/harmony-ui-design.md。 */

// ArkUI 的 fontSize 使用 fp，正文随系统字号，不在此另外乘 fontSizeScale。
export const UI_FONT_TITLE_L = '30fp';
export const UI_FONT_TITLE_M = '24fp';
export const UI_FONT_TITLE_S = '20fp';
export const UI_FONT_LIST_TITLE = '18fp';
export const UI_FONT_ACTION = '16fp';
export const UI_FONT_ACTION_SMALL = '14fp';
export const UI_FONT_BODY = '16fp';
export const UI_FONT_SECONDARY = '14fp';
export const UI_FONT_HINT = '12fp';
export const UI_FONT_CAPTION = '12fp';
export const UI_FONT_CAPTION_SMALL = '10fp';
export const UI_FONT_CHART_LABEL = '8fp';

/** @deprecated 旧页面兼容。新文本直接用对应角色的 fp Token，不按裸数字推断语义。 */
export function uiFontSize(base: number): number {
  return Math.max(8, Math.round(base));
}

/** @deprecated 旧调用方保留数值接口。新文本优先使用 ArkUI 默认行高。 */
export function uiLineHeight(base: number): number {
  return Math.max(10, Math.round(base));
}

/**
 * 系统字体缩放倍数。由 EntryAbility 在启动和 onConfigurationUpdate 时写入
 * （`UIAbilityContext.config.fontSizeScale`），供随字号增长的容器上限使用。
 * 读不到时保持 1，不改变既有布局。
 */
let systemFontSizeScale = 1;

export function setSystemFontSizeScale(scale: number | undefined): void {
  systemFontSizeScale = typeof scale === 'number' && Number.isFinite(scale) && scale > 0
    ? scale : 1;
}

export function getSystemFontSizeScale(): number {
  return systemFontSizeScale;
}

/**
 * 随系统字体缩放的文本容器上限。
 *
 * 固定像素上限在系统字体放大时会把文字挤成省略号（模型名 / 强度这类元信息会直接
 * 读不出来）。这里按系统 `fontSizeScale` 放大上限让容器跟着长，同时用 `cap`
 * 兜住，避免超大字号下挤占同排其它控件。
 */
export function uiScaledMaxWidth(base: number, cap: number): number {
  return Math.round(Math.min(cap, Math.max(base, base * systemFontSizeScale)));
}

/** EntryAbility 写入当前深浅色，Canvas 绘制内容据此重绘。 */
export const UI_COLOR_MODE_STORAGE_KEY = 'cindyColorMode';

export const UI_SPACE_TIGHT = 4;
export const UI_SPACE_INLINE = 8;
export const UI_SPACE_GROUP = 12;
export const UI_SPACE_PAGE = 16;
export const UI_SPACE_SECTION = 24;

export const UI_RADIUS_SMALL_CONTROL = 8;
export const UI_RADIUS_CONTENT = 12;
export const UI_RADIUS_CARD = 20;
export const UI_RADIUS_CAPSULE = 999; // 由实际控件尺寸限制为半高
export const UI_RADIUS_CONTROL = UI_RADIUS_SMALL_CONTROL;
export const UI_RADIUS_CONTAINER = UI_RADIUS_CONTENT;
export const UI_RADIUS_PILL = UI_RADIUS_CAPSULE;

export const UI_ICON_SIZE_STANDARD = 24;
export const UI_ICON_SIZE_COMPACT = 20;
export const UI_ICON_CUSTOM_STROKE = 2; // 24vp 自绘操作图标的基线，不用于 HMSymbol
export const UI_TOUCH_TARGET_MIN = 44;

/** ArkUI 默认转场优先，这些档位仅供应用自绘的局部场景使用。 */
export const UI_MOTION_FEEDBACK_MS = 80;
export const UI_MOTION_REVEAL_MS = 150;
export const UI_MOTION_LAYOUT_MS = 200;
export const UI_MOTION_BUSY_CYCLE_MS = 1000;
export const UI_MOTION_INSTANT = UI_MOTION_FEEDBACK_MS;
export const UI_MOTION_FAST = UI_MOTION_REVEAL_MS;
export const UI_MOTION_BASE = UI_MOTION_LAYOUT_MS;
export const UI_MOTION_SPINNER_CYCLE = UI_MOTION_BUSY_CYCLE_MS;

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
