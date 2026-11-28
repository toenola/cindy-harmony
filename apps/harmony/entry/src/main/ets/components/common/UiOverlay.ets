import { uiMaterial } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { UI_COLOR_MODE_STORAGE_KEY, UI_LIST_CLICK_EFFECT, UI_RADIUS_CONTROL, uiFontSize } from '../UiKit';

/**
 * 鸿蒙端弹层统一口径（操作菜单 / 底部表单 / 确认对话框 / 轻提示）。
 *
 * 依据 API 26 官方指南「组件适配沉浸光感」：应用处于 DEFAULT 材质模式（module.json5 未开应用级开关），
 * AlertDialog / Toast 未自定义背景时默认 ULTRA_THICK / THICK；Menu / Popup / Sheet 默认无沉浸材质。
 * 2026-11-28 真机反馈打开菜单「黑白交替闪烁」：组件级沉浸材质会同时开启系统的沉浸式空间动效（形变弹出、
 * 边缘流光）和实时背景采样，首帧采样未就绪 + 流光扫过在浅色 / 深色背景上表现为明暗闪动。因此菜单与 Popup
 * 不再设置 systemMaterial，回到系统默认菜单样式（见 docs/overlay-standard.md §2）。
 * 不给菜单和对话框设置背景色 / 圆角 / 阴影，交给系统随 Light / Dark 自动适配。
 */

const OVERLAY_LOG_DOMAIN = 0x0000;
const OVERLAY_LOG_TAG = 'CindyOverlay';
const overlayOpenedAt: Map<string, number> = new Map();
const overlayBuildCount: Map<string, number> = new Map();

/**
 * 弹层调试日志（真机排查闪烁用，hilog 过滤 tag `CindyOverlay`）：记录事件、距最近一次 open 的毫秒数、
 * builder 构建次数和当前深浅色。event 为 'open' 时重置计时与计数。
 */
export function uiOverlayTrace(tag: string, event: string): void {
  const now = Date.now();
  if (event === 'open') {
    overlayOpenedAt.set(tag, now);
    overlayBuildCount.set(tag, 0);
  }
  const openedAt = overlayOpenedAt.get(tag);
  const elapsed = openedAt === undefined ? -1 : now - openedAt;
  const builds = overlayBuildCount.get(tag) ?? 0;
  const colorMode = AppStorage.get<number>(UI_COLOR_MODE_STORAGE_KEY) ?? -1;
  hilog.info(OVERLAY_LOG_DOMAIN, OVERLAY_LOG_TAG, '%{public}s %{public}s +%{public}dms builds=%{public}d colorMode=%{public}d',
    tag, event, elapsed, builds, colorMode);
}

/**
 * 放在弹层 builder 根节点的 `.id(...)` 上：表达式不依赖状态，只在该节点被创建时求值一次，
 * 因此每条 `build` 日志对应一次 builder 重新创建。重复出现说明打开过程中内容被重建。
 */
export function uiOverlayBuildId(tag: string): string {
  overlayBuildCount.set(tag, (overlayBuildCount.get(tag) ?? 0) + 1);
  uiOverlayTrace(tag, 'build');
  return 'overlay-' + tag;
}

let menuMaterial: uiMaterial.ImmersiveMaterial | null = null;

/**
 * 沉浸材质对象（THICK）。保留导出以兼容旧调用，但菜单 / Popup 默认不再使用（闪烁问题，见文件头）；
 * 只有经真机验证无闪烁的新场景，在 docs/overlay-standard.md 登记后才可手动传入 systemMaterial。
 */
export function uiMenuMaterial(): uiMaterial.ImmersiveMaterial {
  if (menuMaterial === null) {
    menuMaterial = new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK });
  }
  return menuMaterial;
}

let popupMaterial: uiMaterial.ImmersiveMaterial | null = null;

/** 同 uiMenuMaterial：保留导出以兼容，Popup 默认不再设置 systemMaterial。 */
export function uiPopupMaterial(): uiMaterial.ImmersiveMaterial {
  if (popupMaterial === null) {
    popupMaterial = new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THICK, interactive: true });
  }
  return popupMaterial;
}

/**
 * 操作菜单（bindMenu + Menu / MenuItem / MenuItemGroup）的统一选项：无蒙层（系统非模态菜单），
 * 点外部、返回键关闭由系统处理；onDisappear 用来把受控的 isShow 状态复位。
 * 不设 systemMaterial（系统默认菜单样式）。traceTag 只用于调试日志，可省略。
 */
export function uiMenuOptions(onDisappear: () => void, placement: Placement = Placement.BottomLeft,
  traceTag: string = 'menu'): MenuOptions {
  return {
    placement: placement,
    onWillAppear: (): void => uiOverlayTrace(traceTag, 'willAppear'),
    onDidAppear: (): void => uiOverlayTrace(traceTag, 'didAppear'),
    onWillDisappear: (): void => uiOverlayTrace(traceTag, 'willDisappear'),
    onDisappear: (): void => {
      uiOverlayTrace(traceTag, 'disappear');
      onDisappear();
    },
  };
}

/**
 * 底部表单的可选项（全部可省略，省略时与原默认一致）。
 * - detents：列表 / 浏览类表单的挡位，如 [SheetSize.MEDIUM, SheetSize.LARGE]；设置后不再写 height。
 * - onWillDismiss：下滑、点蒙层、点系统关闭按钮前的拦截；需要把「关闭」当成取消、或有改动先确认时使用，
 *   放行时调用 action.dismiss()。
 * - mode：显示层级，默认不设（OVERLAY）。只有「从表单里再推新页面、返回后表单内容要保留」时才用
 *   SheetMode.EMBEDDED；它只能挂在 Page / NavDestination 上，不能把表单限制在分栏的详情栏内
 *   （见 docs/overlay-standard.md §3.2「平板分栏」）。
 * - preferType：默认 BOTTOM；宽屏上锚定按钮的短操作可用 SheetType.POPUP。
 */
export class UiSheetExtras {
  detents?: [(SheetSize | Length), (SheetSize | Length)?, (SheetSize | Length)?];
  onWillDismiss?: Callback<DismissSheetAction>;
  mode?: SheetMode;
  preferType?: SheetType;
  /** 调试日志 tag，默认 'sheet'。 */
  traceTag?: string;
}

/**
 * 底部表单（bindSheet）的统一选项：系统标题 + 系统关闭按钮 + 拖动条，内容高度自适应；
 * 不开沉浸材质（大面积弹层），背景用语义色 bg_card，蒙层用语义色 overlay，Light / Dark 由资源成对提供。
 * 第 4 个参数可选，现有调用方不受影响。
 */
export function uiSheetOptions(title: ResourceStr, onDisappear: () => void,
  height: SheetSize | Length = SheetSize.FIT_CONTENT, extras?: UiSheetExtras): SheetOptions {
  const options: SheetOptions = {
    dragBar: true,
    showClose: true,
    title: { title: title },
    preferType: extras?.preferType ?? SheetType.BOTTOM,
    backgroundColor: $r('app.color.bg_card'),
    maskColor: $r('app.color.overlay'),
    onWillAppear: (): void => uiOverlayTrace(extras?.traceTag ?? 'sheet', 'willAppear'),
    onAppear: (): void => uiOverlayTrace(extras?.traceTag ?? 'sheet', 'didAppear'),
    onDisappear: (): void => {
      uiOverlayTrace(extras?.traceTag ?? 'sheet', 'disappear');
      onDisappear();
    },
  };
  if (extras?.detents !== undefined) options.detents = extras.detents;
  else options.height = height;
  if (extras?.onWillDismiss !== undefined) options.onWillDismiss = extras.onWillDismiss;
  if (extras?.mode !== undefined) options.mode = extras.mode;
  return options;
}

/**
 * 表单内的整行操作：44vp 高，图标 + 文字，无自绘底色，按压用列表行反馈。
 * 用于底部表单里的少量动作（复制 ID、打开设置等）；超过 3 项的平级操作改用操作菜单。
 */
@Component
export struct UiSheetActionRow {
  @Prop label: ResourceStr = '';
  @Prop symbol: Resource = $r('sys.symbol.ellipsis_circle');
  @Prop destructive: boolean = false;
  @Prop actionEnabled: boolean = true;
  onAction: () => void = (): void => {};

  build() {
    Button() {
      Row({ space: 10 }) {
        SymbolGlyph(this.symbol)
          .fontSize(uiFontSize(17))
          .fontColor([this.destructive ? $r('app.color.danger') : $r('app.color.text_secondary')])
          .width(24)
        Text(this.label)
          .fontSize(uiFontSize(15))
          .fontColor(this.destructive ? $r('app.color.danger') : $r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
    }
    .type(ButtonType.Normal)
    .width('100%')
    .height(44)
    .padding({ left: 10, right: 10 })
    .backgroundColor(Color.Transparent)
    .borderRadius(UI_RADIUS_CONTROL)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .enabled(this.actionEnabled)
    .opacity(this.actionEnabled ? 1 : 0.45)
    .onClick((): void => this.onAction())
  }
}

/** 确认对话框的文案。destructive 为 true 时确认按钮用 danger 语义色（删除、退出、解散等）。 */
export class UiConfirmCopy {
  title: ResourceStr = '';
  message: ResourceStr = '';
  confirm: ResourceStr = '';
  cancel: ResourceStr = '';
  destructive: boolean = false;
}

/** 一次构造确认文案，省去逐字段赋值。 */
export function uiConfirmCopy(title: ResourceStr, message: ResourceStr, confirm: ResourceStr, cancel: ResourceStr,
  destructive: boolean = false): UiConfirmCopy {
  const copy = new UiConfirmCopy();
  copy.title = title;
  copy.message = message;
  copy.confirm = confirm;
  copy.cancel = cancel;
  copy.destructive = destructive;
  return copy;
}

/**
 * 确认对话框：系统 AlertDialog，取消在左、确认在右（DESIGN.md Dialog & Modal 的按钮顺序），
 * 点蒙层不关闭（防误触），返回键等同取消。不设背景色，保留系统默认的 ULTRA_THICK 材质。
 */
export function uiConfirm(context: UIContext, copy: UiConfirmCopy): Promise<boolean> {
  return new Promise<boolean>((resolve: (value: boolean) => void): void => {
    let settled = false;
    const finish = (value: boolean): void => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    context.showAlertDialog({
      title: copy.title,
      message: copy.message,
      autoCancel: false,
      primaryButton: {
        value: copy.cancel,
        action: (): void => finish(false),
      },
      secondaryButton: {
        value: copy.confirm,
        style: DialogButtonStyle.HIGHLIGHT,
        fontColor: copy.destructive ? $r('app.color.danger') : undefined,
        action: (): void => finish(true),
      },
      cancel: (): void => finish(false),
    });
  });
}

/**
 * 通知对话框：只有一个「知道了」类确认按钮，用于需要用户读完的说明（如推送权限说明）。
 * 与 uiConfirm 同口径：系统 AlertDialog、不设背景色、点蒙层不关闭；按钮或返回键关闭后 resolve。
 */
export function uiNotice(context: UIContext, title: ResourceStr, message: ResourceStr,
  acknowledge: ResourceStr): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    let settled = false;
    const finish = (): void => {
      if (settled) return;
      settled = true;
      resolve();
    };
    context.showAlertDialog({
      title: title,
      message: message,
      autoCancel: false,
      confirm: {
        value: acknowledge,
        style: DialogButtonStyle.HIGHLIGHT,
        action: (): void => finish(),
      },
      cancel: (): void => finish(),
    });
  });
}

/** 轻提示：系统 Toast，不设背景色以保留系统 THICK 材质；只用于已完成或失败的短结果，不承载操作。 */
export function uiToast(context: UIContext, message: ResourceStr): void {
  context.getPromptAction().showToast({ message: message, duration: 2000 });
}
