import {
  RemoteImageRef,
  composerAttachmentRenderKey,
  createComposerAttachmentLocalId,
} from '../core/attachments/AttachmentModels';
import { ComposerFile } from '../core/attachments/ComposerFileQueue';
import {
  ComposerAtomPresentation,
  LONG_PASTE_MAX_CHARS,
} from '../core/messages/ComposerDocument';
import {
  UI_CLICK_EFFECT,
  UI_ICON_CLICK_EFFECT,
  UI_CURVE_MOVE,
  UI_MOTION_BASE,
  UI_MOTION_FAST,
  UI_RADIUS_CONTAINER,
  UI_RADIUS_CONTROL,
  UI_RADIUS_PILL,
  uiFontSize,
  uiScaledMaxWidth,
  uiLineHeight,
  uiRevealTransition,
} from './UiKit';
import { uiMaterial } from '@kit.ArkUI';

/** 待发送图片（上传状态机：uploading → ready / failed）。 */
export class ComposerImage {
  /** 跨 @Prop 深拷贝仍可定位父页面真实条目的本地 ID。 */
  localId: string = createComposerAttachmentLocalId();
  uri: string = '';
  name: string = '';
  status: string = 'uploading';
  ref: RemoteImageRef | null = null;
  /** 用户已移除；异步上传若稍后成功，立即回收中转对象。 */
  removed: boolean = false;
  /** 每次上传/重试/移除递增；旧异步回调不得覆盖新尝试。 */
  uploadRevision: number = 0;
}

export function composerPermissionSymbol(mode: string): Resource {
  if (mode === 'bypassPermissions') return $r('sys.symbol.lock_open');
  if (mode === 'auto') return $r('sys.symbol.wand_and_stars');
  if (mode === 'ask' || mode === 'default') return $r('sys.symbol.hand_raised_fingers_spread');
  if (mode === 'plan') return $r('sys.symbol.text_clipboard');
  if (mode === 'acceptEdits') return $r('sys.symbol.code');
  return $r('sys.symbol.checkmark_shield');
}

export function composerPermissionTint(mode: string): Resource {
  return mode === 'bypassPermissions' ? $r('app.color.danger') : $r('app.color.text_secondary');
}

/**
 * 任务详情和新建任务共用的会话 Composer。
 *
 * 页面只注入状态与行为，输入胶囊、焦点展开、模型/权限/计划控件以及发送按钮
 * 由这里统一维护，避免新建任务再复制一套视觉和交互。
 */
@Component
export struct ConversationComposer {
  @Prop input: string = '';
  @Prop focused: boolean = false;
  /** 父页面在选择层打开期间保留完整 Composer，避免清焦后退回收起态。 */
  @Prop surfaceExpanded: boolean = false;
  @Prop images: ComposerImage[] = [];
  @Prop files: ComposerFile[] = [];
  @Prop atoms: ComposerAtomPresentation[] = [];
  @Prop sending: boolean = false;
  @Prop streaming: boolean = false;
  @Prop streamingElapsedText: string = '0s';
  @Prop hasContent: boolean = false;
  @Prop canSend: boolean = false;
  @Prop composerEnabled: boolean = true;
  @Prop pickingImages: boolean = false;
  @Prop pickingFiles: boolean = false;
  @Prop contextBusy: boolean = false;
  /** 运行时能力与 provider 目录全部落定后再一次性展示工具栏，避免按钮分批插入跳动。 */
  @Prop toolbarReady: boolean = true;
  @Prop runtimeRouteLocked: boolean = false;
  @Prop hasPermissionOptions: boolean = false;
  @Prop hasAgentOptions: boolean = false;
  @Prop hasModelOptions: boolean = false;
  @Prop permissionMode: string = '';
  @Prop permissionLabel: string = '权限模式';
  @Prop planModeEnabled: boolean = false;
  @Prop agentLabel: string = '';
  @Prop modelLabel: string = '';
  @Prop effortLabel: string = '';
  /** Agent / 模型选择器由页面持有业务状态，Composer 只统一锚点、材质与尺寸。 */
  @Prop @Watch('syncPicker') permissionPopupVisible: boolean = false;
  @Prop @Watch('syncPicker') agentPopupVisible: boolean = false;
  @Prop @Watch('syncPicker') modelPopupVisible: boolean = false;
  @Prop showAddButton: boolean = true;
  @Prop showStreamingStatus: boolean = true;
  /** 会话详情与新建任务共用华为官方浮动操作栏同款组件材质。 */
  @Prop floatingGlass: boolean = false;
  /** 浮动背板距当前可用区域底边的间距，由分栏父页面与 HdsTabs 共用同一口径。 */
  @Prop floatingBottomInset: number = 2;
  @Prop inputId: string = 'task-composer-input';
  /** 宽度上限；0 时沿用默认（悬浮样式 720，普通样式 760）。会话详情会传入更宽的值。 */
  @Prop maxContentWidth: number = 0;
  @Prop placeholder: string = '输入远程消息';

  onInputChange: (value: string) => void = () => {};
  onFocusChange: (focused: boolean) => void = () => {};
  onAdd: () => void = () => {};
  onPermission: () => void = () => {};
  onAgent: () => void = () => {};
  onModel: () => void = () => {};
  onPermissionPopupDismiss: () => void = () => {};
  onAgentPopupDismiss: () => void = () => {};
  onModelPopupDismiss: () => void = () => {};
  onPlanToggle: () => void = () => {};
  onExpand: () => void = () => {};
  onSend: () => void = () => {};
  onAbort: () => void = () => {};
  onPreviewImage: (image: ComposerImage) => void = () => {};
  onRemoveImage: (localId: string) => void = () => {};
  onRetryImage: (localId: string) => void = () => {};
  onRemoveFile: (localId: string) => void = () => {};
  onRetryFile: (localId: string) => void = () => {};
  onRemoveAtom: (atom: ComposerAtomPresentation) => void = () => {};
  @Builder
  emptyPopupContent() {
  }
  @BuilderParam permissionPopupContent: () => void = this.emptyPopupContent;
  @BuilderParam agentPopupContent: () => void = this.emptyPopupContent;
  @BuilderParam modelPopupContent: () => void = this.emptyPopupContent;
  @Prop @Watch('syncPicker') externalPickerTitle: string = '';
  @BuilderParam externalPickerContent: (title: string) => void = this.emptyExternalPickerContent;
  onExternalPickerDismiss: () => void = () => {};

  @Builder
  emptyExternalPickerContent(_title: string) {}

  @Prop pickerWindowHeight: number = 0;
  @State private pickerPage: string = '';
  @State private pickerVisible: boolean = false;
  @State private inputVisible: boolean = true;
  private pickerGeneration: number = 0;

  private readonly floatingGlassMaterial: uiMaterial.ImmersiveMaterial =
    new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      colorInvert: true,
      // 容器内有横向列表和多个按钮，交互反馈由子控件承担，整块背板不参与形变。
      interactive: false,
    });
  @State inputMaxHeight: number = 120;
  @State resizing: boolean = false;
  private resizeStartY: number = 0;
  private resizeStartHeight: number = 120;

  aboutToAppear(): void {
    this.syncPicker();
  }

  aboutToDisappear(): void {
    this.pickerGeneration += 1;
  }

  private syncPicker(): void {
    const next = this.permissionPopupVisible ? 'permission'
      : this.modelPopupVisible ? 'model' : this.agentPopupVisible ? 'agent' : this.externalPickerTitle;
    const generation = ++this.pickerGeneration;
    if (next.length > 0) {
      this.getUIContext().animateTo({
        duration: UI_MOTION_FAST, curve: UI_CURVE_MOVE, onFinish: (): void => {
          if (generation !== this.pickerGeneration) return;
          this.pickerPage = next;
          this.getUIContext().animateTo({ duration: UI_MOTION_BASE, curve: UI_CURVE_MOVE },
            (): void => { this.pickerVisible = true; });
        },
      }, (): void => { this.inputVisible = false; });
    } else if (this.pickerPage.length > 0) {
      this.getUIContext().animateTo({
        duration: UI_MOTION_FAST, curve: UI_CURVE_MOVE, onFinish: (): void => {
          if (generation !== this.pickerGeneration) return;
          this.pickerPage = '';
          this.getUIContext().animateTo({ duration: UI_MOTION_BASE, curve: UI_CURVE_MOVE },
            (): void => { this.inputVisible = true; });
        },
      }, (): void => { this.pickerVisible = false; });
    } else {
      this.inputVisible = true;
    }
  }

  private dismissPicker(): void {
    if (this.permissionPopupVisible) this.onPermissionPopupDismiss();
    else if (this.modelPopupVisible) this.onModelPopupDismiss();
    else if (this.agentPopupVisible) this.onAgentPopupDismiss();
    else this.onExternalPickerDismiss();
  }

  private pickerTitle(): ResourceStr {
    if (this.pickerPage === 'permission') return $r('app.string.composer_picker_permission');
    if (this.pickerPage === 'model') return $r('app.string.v138_models');
    return this.pickerPage === 'agent' ? $r('app.string.v12_search_agent') : this.pickerPage;
  }

  private pickerSlide(): TransitionEffect {
    return TransitionEffect.translate({ y: 40 }).combine(TransitionEffect.OPACITY);
  }

  private resizeInput(event: TouchEvent): void {
    if (event.type === TouchType.Cancel) {
      this.resizing = false;
      return;
    }
    if (event.changedTouches.length === 0) return;
    const y = event.changedTouches[0].displayY;
    if (event.type === TouchType.Down) {
      this.resizeStartY = y;
      this.resizeStartHeight = this.inputMaxHeight;
      this.resizing = true;
    } else if (event.type === TouchType.Move) {
      // 向上拖高；跟手阶段不用缓动。
      this.inputMaxHeight = Math.max(96, Math.min(280, this.resizeStartHeight + this.resizeStartY - y));
    } else if (event.type === TouchType.Up) {
      this.resizing = false;
    }
  }

  private hasModelChip(): boolean {
    return this.hasModelOptions || this.modelLabel.length > 0;
  }

  private hasAgentChip(): boolean {
    return this.hasAgentOptions || this.agentLabel.length > 0;
  }

  private expanded(): boolean {
    return this.surfaceExpanded || this.focused
      || this.images.length > 0 || this.files.length > 0 || this.atoms.length > 0;
  }

  /** 收起工具栏展开后等待 TextArea 出现，再请求光标与系统键盘。 */
  private focusInputAfterAppear(): void {
    if (!this.focused || !this.composerEnabled) return;
    setTimeout(() => focusControl.requestFocus(this.inputId), 0);
  }

  private primaryShowsStop(): boolean {
    // 单行优先停止；编辑中保留 Mobile 的草稿发送槽，仍可发送排队消息。
    return this.streaming && (!this.expanded() || !this.hasContent);
  }

  private tapPrimaryAction(): void {
    if (this.primaryShowsStop()) {
      this.onAbort();
    } else if (this.canSend) {
      this.onSend();
    }
  }

  @Builder
  composerImageItem(image: ComposerImage) {
    Column({ space: 3 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Image(image.uri)
          .width(56)
          .height(56)
          .borderRadius(UI_RADIUS_CONTROL)
          .objectFit(ImageFit.Cover)
          .onClick(() => {
            if (image.status === 'ready') this.onPreviewImage(image);
          })
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(11)
            .fontColor([$r('app.color.chat_overlay_text')])
        }
        .type(ButtonType.Circle)
        .width(28)
        .height(28)
        .padding(0)
        .backgroundColor($r('app.color.overlay'))
        .borderRadius(UI_RADIUS_PILL)
        .clickEffect(UI_ICON_CLICK_EFFECT)
        .zIndex(1)
        .onClick(() => this.onRemoveImage(image.localId))
      }
      if (image.status === 'uploading') {
        Text('上传中…')
          .fontSize(uiFontSize(10))
          .fontColor($r('app.color.text_secondary'))
      } else if (image.status === 'failed') {
        Text('重试')
          .fontSize(uiFontSize(10))
          .fontColor($r('app.color.danger'))
          .decoration({ type: TextDecorationType.Underline })
          .onClick(() => this.onRetryImage(image.localId))
      } else {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(11)
          .fontColor([$r('app.color.success')])
      }
    }
    .padding({ right: 8 })
  }

  @Builder
  composerFileItem(file: ComposerFile) {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.doc'))
        .fontSize(uiFontSize(18))
        .fontColor([$r('app.color.text_secondary')])
      Column({ space: 1 }) {
        Text(file.name)
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(file.status === 'uploading' ? '上传中…'
          : file.status === 'failed' ? (file.errorText || '上传失败')
            : file.size > 0 ? `${(file.size / 1024).toFixed(1)} KB` : '已就绪')
          .fontSize(uiFontSize(10))
          .fontColor(file.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_tertiary'))
          .maxLines(1)
      }
      .width(112)
      .alignItems(HorizontalAlign.Start)
      if (file.status === 'failed') {
        Button('重试')
          .height(26)
          .fontSize(uiFontSize(11))
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 8 })
          .backgroundColor(Color.Transparent)
          .onClick(() => this.onRetryFile(file.localId))
      }
      Button() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(uiFontSize(10))
          .fontColor([$r('app.color.text_secondary')])
      }
      .type(ButtonType.Circle)
      .width(26)
      .height(26)
      .padding(0)
      .backgroundColor($r('app.color.bg_chip'))
      .onClick(() => this.onRemoveFile(file.localId))
    }
    .height(54)
    .padding({ left: 10, right: 6 })
    .margin({ right: 8 })
    .backgroundColor($r('app.color.bg_chip'))
    .borderRadius(UI_RADIUS_CONTROL)
  }

  @Builder
  composerAtomItem(atom: ComposerAtomPresentation) {
    Row({ space: 7 }) {
      SymbolGlyph(atom.type === 'quote' ? $r('sys.symbol.doc')
        : atom.type === 'pasted-text' ? $r('sys.symbol.doc')
          : atom.type === 'slash-command' ? $r('sys.symbol.bolt')
            : $r('sys.symbol.link'))
        .fontSize(uiFontSize(14))
        .fontColor([$r('app.color.text_secondary')])
      Column({ space: 1 }) {
        Text(atom.label)
          .fontSize(uiFontSize(11))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (atom.detail.length > 0) {
          Text(atom.detail)
            .fontSize(uiFontSize(10))
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .constraintSize({ maxWidth: 160 })
      .alignItems(HorizontalAlign.Start)
      Button() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(uiFontSize(9))
          .fontColor([$r('app.color.text_secondary')])
      }
      .type(ButtonType.Circle)
      .width(24)
      .height(24)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .clickEffect(UI_ICON_CLICK_EFFECT)
      .onClick(() => this.onRemoveAtom(atom))
    }
    .height(42)
    .padding({ left: 10, right: 4 })
    .margin({ right: 8 })
    .backgroundColor($r('app.color.bg_chip'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(UI_RADIUS_CONTROL)
  }

  /** 胶囊内的圆形 icon 按钮（加号 / 权限）。 */
  @Builder
  composerIconButton(
    symbol: Resource,
    tint: Resource,
    enabled: boolean,
    accessibilityLabel: string,
    action: () => void,
  ) {
    Button() {
      SymbolGlyph(symbol)
        .fontSize(18)
        .fontColor([tint])
    }
    .type(ButtonType.Circle)
    .width(44)
    .height(44)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.4)
    .accessibilityText(accessibilityLabel)
    .onClick(action)
  }

  /** 权限图标保留档位读屏名，选项与确认仍由页面提供。 */
  @Builder
  composerPermissionButton() {
    Button() {
      SymbolGlyph(composerPermissionSymbol(this.permissionMode))
        .fontSize(18)
        .fontColor([composerPermissionTint(this.permissionMode)])
    }
    .type(ButtonType.Circle)
    .width(44)
    .height(44)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_CLICK_EFFECT)
    .enabled(this.composerEnabled && !this.sending && !this.contextBusy)
    .opacity(this.composerEnabled && !this.sending && !this.contextBusy ? 1 : 0.4)
    .accessibilityText(`权限模式：${this.permissionLabel}`)
    .onClick(() => this.onPermission())
  }

  /** 工具栏里的模型胶囊；窄屏只压缩文字，不挤占上方输入区域。 */
  @Builder
  composerModelButton() {
    Button() {
      Row({ space: 4 }) {
        if (this.agentLabel.length > 0) {
          Text(this.agentLabel === 'Codex' ? '✣' : this.agentLabel === 'Pi' ? 'π' : '♟')
            .fontSize(uiFontSize(13)).fontColor($r('app.color.text_secondary')).accessibilityLevel('no')
        }
        Text(this.effortLabel.length > 0
          ? `${this.modelLabel} · ${this.effortLabel}`
          : this.modelLabel)
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 上限随系统字号放大，避免放大字体后模型名 / 强度被截成省略号。
          .constraintSize({ maxWidth: uiScaledMaxWidth(176, 264) })
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(11)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .alignItems(VerticalAlign.Center)
    }
    .type(ButtonType.Normal)
    .height(44)
    .constraintSize({ maxWidth: uiScaledMaxWidth(208, 300) })
    .padding({ left: 12, right: 10 })
    .borderRadius(UI_RADIUS_PILL)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_CLICK_EFFECT)
    // 读屏播报完整元信息：视觉可能省略，但强度不能只靠看。
    .enabled(this.hasModelOptions && !this.runtimeRouteLocked && this.composerEnabled && !this.sending && !this.contextBusy)
    .opacity(!this.hasModelOptions || this.runtimeRouteLocked ? 0.4 : 1)
    .accessibilityText(this.effortLabel.length > 0
      ? `模型：${this.agentLabel} ${this.modelLabel}，思考强度：${this.effortLabel}`
      : `模型：${this.agentLabel} ${this.modelLabel}`)
    .onClick(() => this.onModel())
  }

  /** 工具栏里的独立 Agent 胶囊，位于模型胶囊之前。 */
  @Builder
  composerAgentButton() {
    Button() {
      Row({ space: 4 }) {
        Text(this.agentLabel)
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 72 })
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(11)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .alignItems(VerticalAlign.Center)
    }
    .type(ButtonType.Normal)
    .height(44)
    .constraintSize({ maxWidth: 104 })
    .padding({ left: 10, right: 8 })
    .borderRadius(UI_RADIUS_PILL)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_CLICK_EFFECT)
    .enabled(this.hasAgentOptions && !this.runtimeRouteLocked && this.composerEnabled && !this.sending && !this.contextBusy)
    .opacity(!this.hasAgentOptions || this.runtimeRouteLocked ? 0.4 : 1)
    .accessibilityText(`Agent：${this.agentLabel}`)
    .onClick(() => this.onAgent())
  }

  @Builder
  composerPickerPanel() {
    Column() {
      Text(this.pickerTitle())
        .fontSize(uiFontSize(14))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(44)
        .gesture(PanGesture({ direction: PanDirection.Down }).onActionEnd((event: GestureEvent) => {
          if (event.offsetY > 24) this.dismissPicker();
        }))
      if (this.pickerPage === 'model') {
        Column() {
          this.modelPopupContent()
        }
        .width('100%')
        .constraintSize({ maxHeight: Math.max(1, this.pickerWindowHeight * 0.5 - 44) })
      } else {
        Scroll() {
          Column() {
            if (this.pickerPage === 'permission') {
              this.permissionPopupContent()
            } else if (this.pickerPage === 'agent') {
              this.agentPopupContent()
            } else {
              this.externalPickerContent(this.pickerPage)
            }
          }.width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: Math.max(1, this.pickerWindowHeight * 0.5 - 44) })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(UI_RADIUS_CONTAINER)
    .clip(true)
    .transition(this.pickerSlide())
  }

  @Builder
  composerPrimaryButton() {
    Button() {
      if (this.sending) {
        LoadingProgress()
          .width(15)
          .height(15)
          .color($r('app.color.text_primary'))
      } else if (this.primaryShowsStop()) {
        SymbolGlyph($r('sys.symbol.square_fill'))
          .fontSize(12)
          .fontColor([$r('app.color.danger')])
      } else {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(16)
          .fontColor([this.canSend
            ? $r('app.color.text_primary')
            : $r('app.color.text_tertiary')])
      }
    }
    .type(ButtonType.Circle)
    .width(44)
    .height(44)
    .padding(0)
    .borderRadius(UI_RADIUS_PILL)
    .backgroundColor(Color.Transparent)
    .animation({ duration: UI_MOTION_BASE, curve: UI_CURVE_MOVE })
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .enabled(this.composerEnabled && !this.sending
      && ((this.primaryShowsStop()) || this.canSend))
    .accessibilityText(this.sending
      ? '发送中'
      : this.primaryShowsStop()
        ? '停止'
        : '发送')
    .onClick(() => this.tapPrimaryAction())
  }

  /** 打开态与关闭态使用不同的 ArkUI 分支，关闭时直接销毁承载原生 Popup 的锚点节点。 */
  @Builder
  composerModelOpenToolbarItem() {
    ListItem() {
      Row() {
        this.composerModelButton()
      }
      .height(44)
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  composerModelClosedToolbarItem() {
    ListItem() {
      Row() {
        this.composerModelButton()
      }
      .height(44)
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  composerAddButton() {
    this.composerIconButton(
      $r('sys.symbol.plus'),
      $r('app.color.text_primary'),
      this.composerEnabled && !this.sending && !this.pickingImages && !this.pickingFiles,
      '添加附件或上下文',
      () => this.onAdd(),
    )
  }

  /** 工具栏左侧控制保持固定顺序；末尾主操作固定到右侧。 */
  @Builder
  composerToolbarLeadingItems() {
    if (this.showAddButton) {
      ListItem() { this.composerAddButton() }
    }

    if (this.hasPermissionOptions) {
      ListItem() {
        Row() {
          this.composerPermissionButton()
        }
        .height(44)
        .alignItems(VerticalAlign.Center)
      }
    }

    if (this.planModeEnabled) {
      ListItem() {
        Row() {
          Button('计划')
            .height(44)
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.chat_cta_text'))
            .backgroundColor($r('app.color.chat_cta'))
            .borderRadius(UI_RADIUS_PILL)
            .padding({ left: 12, right: 12 })
            .clickEffect(UI_CLICK_EFFECT)
            .enabled(this.composerEnabled && !this.contextBusy)
            .accessibilityText('关闭计划模式')
            .onClick(() => this.onPlanToggle())
        }
        .height(44)
        .alignItems(VerticalAlign.Center)
      }
    }

    if (this.hasModelChip()) {
      if (this.modelPopupVisible) {
        this.composerModelOpenToolbarItem()
      } else {
        this.composerModelClosedToolbarItem()
      }
    }
  }

  /** 固定高度的统一加载占位；不提前泄露任一按钮，能力落定后整排一次替换。 */
  @Builder
  composerToolbarLoading() {
    Row({ space: 8 }) {
      LoadingProgress()
        .width(16)
        .height(16)
        .color($r('app.color.text_tertiary'))
      Text('正在加载工具栏…')
        .fontSize(uiFontSize(12))
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  composerInputSurface() {
    Column({ space: 6 }) {
      if (this.showStreamingStatus && this.streaming && this.expanded()) {
        Row({ space: 6 }) {
          LoadingProgress()
            .width(12)
            .height(12)
            .color($r('app.color.chat_status_accent'))
          Text('思考中…')
            .fontSize(uiFontSize(12))
            .lineHeight(uiLineHeight(18))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.chat_status_accent'))
          Row().layoutWeight(1)
          Text(this.streamingElapsedText)
            .fontSize(uiFontSize(12))
            .lineHeight(uiLineHeight(18))
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .height(30)
        .padding({ left: 12, right: 12 })
        .backgroundColor($r('app.color.composer_glass_surface'))
        .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR, {}, {
          disableSystemAdaptation: false,
        })
        .border({ width: 1, color: $r('app.color.composer_hairline') })
        .borderRadius(UI_RADIUS_PILL)
        .clip(true)
        .transition(uiRevealTransition())
      }

      // 系统沉浸材质是增强层，不是唯一的可见背景。外层 Stack 保留语义化底色，
      // 当设备或嵌套详情栏无法合成 ImmersiveMaterial 时，输入区仍然保持可见。
      Stack({ alignContent: Alignment.TopStart }) {
        Column({ space: 6 }) {
        if (this.images.length > 0) {
          Row() {
            Row()
              .width(24)
              .height(2)
              .backgroundColor(this.resizing
                ? $r('app.color.accent') : $r('app.color.border'))
              .borderRadius(UI_RADIUS_PILL)
          }
          .width('100%')
          // 保留 12vp 拖拽热区，仅收细可见光轨，避免视觉变轻后牺牲调高输入区的手感。
          .height(12)
          .justifyContent(FlexAlign.Center)
          .onTouch((event: TouchEvent) => this.resizeInput(event))
        }
        if (this.images.length > 0) {
          List({ space: 0 }) {
            ForEach(this.images, (image: ComposerImage) => {
              ListItem() {
                this.composerImageItem(image)
              }
            }, (image: ComposerImage) => composerAttachmentRenderKey(
              image.localId, image.status, image.uploadRevision))
          }
          .listDirection(Axis.Horizontal)
          .width('100%')
          .height(76)
          .transition(uiRevealTransition())
        }

        if (this.files.length > 0) {
          List({ space: 0 }) {
            ForEach(this.files, (file: ComposerFile) => {
              ListItem() { this.composerFileItem(file) }
            }, (file: ComposerFile) => composerAttachmentRenderKey(
              file.localId, file.status, file.uploadRevision))
          }
          .listDirection(Axis.Horizontal)
          .width('100%')
          .height(60)
          .transition(uiRevealTransition())
        }


        if (this.atoms.length > 0) {
          List({ space: 0 }) {
            ForEach(this.atoms, (atom: ComposerAtomPresentation) => {
              ListItem() { this.composerAtomItem(atom) }
            }, (atom: ComposerAtomPresentation) => `${atom.index}-${atom.type}`)
          }
          .listDirection(Axis.Horizontal)
          .width('100%')
          .height(48)
          .transition(uiRevealTransition())
        }

        if (this.expanded()) {
          Row({ space: 6 }) {
            Column() {
              TextArea({ placeholder: this.placeholder, text: this.input })
                .id(this.inputId)
                .enabled(this.composerEnabled)
                .fontSize(uiFontSize(15))
                .placeholderFont({ size: uiFontSize(15) })
                .lineHeight(uiLineHeight(22))
                .fontColor($r('app.color.text_primary'))
                .placeholderColor($r('app.color.text_placeholder'))
                .caretColor($r('app.color.chat_input_caret'))
                .backgroundColor(Color.Transparent)
                .maxLength(LONG_PASTE_MAX_CHARS)
                .align(Alignment.TopStart)
                .textAlign(TextAlign.Start)
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .width('100%')
                .constraintSize({ minHeight: 52, maxHeight: this.inputMaxHeight })
                .onAppear(() => this.focusInputAfterAppear())
                .onFocus(() => this.onFocusChange(true))
                .onBlur(() => this.onFocusChange(false))
                .onChange((value: string) => this.onInputChange(value))
            }
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)
            .animation({ duration: UI_MOTION_FAST, curve: UI_CURVE_MOVE })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 目录加载只替换左侧工具，右侧发送或停止始终保留。
          Row({ space: 6 }) {
            if (this.toolbarReady) {
              List({ space: 6 }) {
                this.composerToolbarLeadingItems()
              }
              .listDirection(Axis.Horizontal)
              .height(44)
              .layoutWeight(1)
              .scrollBar(BarState.Off)
            } else {
              Row() {
                this.composerToolbarLoading()
              }.layoutWeight(1)
            }
            this.composerPrimaryButton()
          }
          .width('100%')
          .height(44)
          .alignItems(VerticalAlign.Center)
        } else {
          Row({ space: 4 }) {
            if (this.showAddButton) {
              this.composerAddButton()
            }
            if (this.toolbarReady && this.hasPermissionOptions) {
              this.composerPermissionButton()
            }
            Button() {
              Text(this.input.length > 0 ? this.input : this.placeholder)
                .fontSize(uiFontSize(15))
                .fontColor(this.input.length > 0 ? $r('app.color.text_primary') : $r('app.color.text_placeholder'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Start)
                .width('100%')
            }
            .type(ButtonType.Normal)
            .layoutWeight(1)
            .height(44)
            .padding({ left: 4, right: 4 })
            .backgroundColor(Color.Transparent)
            .enabled(this.composerEnabled)
            .accessibilityText(this.input.length > 0 ? this.input : this.placeholder)
            .onClick(() => this.onExpand())

            if (this.sending || this.streaming || this.canSend) {
              this.composerPrimaryButton()
            }
          }
          .width('100%')
          .height(44)
          .alignItems(VerticalAlign.Center)
        }
        }
        .width('100%')
        .constraintSize({ minHeight: 36 })
        .padding({
          left: 10,
          right: 10,
          // 浮动收起态与左侧 HdsTabs/miniBar 共用 52vp：44vp 内容 + 4vp × 2。
          top: this.expanded() ? 8 : 4,
          bottom: this.expanded() ? 8 : 4,
        })
        // 只让系统材质作用于内容层；透明或不支持材质时由 Stack 底层兜底。
        .backgroundColor(Color.Transparent)
        .borderRadius(this.expanded() ? UI_RADIUS_CONTAINER : 32)
        .clip(true)
        // 只对输入区使用浮动操作栏材质，工具栏 Popup 保持系统默认。
        .systemMaterial(this.floatingGlass
          ? this.floatingGlassMaterial
          : uiMaterial.Material.empty)
      }
      .width('100%')
      .constraintSize({ minHeight: 36 })
      .backgroundColor(this.floatingGlass
        ? $r('app.color.composer_glass_surface') : $r('app.color.composer_surface'))
      .border({
        width: 1,
        color: this.floatingGlass
          ? $r('app.color.composer_hairline') : $r('app.color.composer_border'),
      })
      // 收起态使用实际高度的一半做胶囊圆角，避免动画在 999→12 间插值抖动。
      .borderRadius(this.expanded() ? UI_RADIUS_CONTAINER : 32)
      .clip(true)
      .animation({ duration: UI_MOTION_BASE, curve: UI_CURVE_MOVE })
    }
    .width('100%')
    .transition(this.pickerSlide())
  }

  build() {
    Column() {
      if (this.pickerVisible) {
        this.composerPickerPanel()
      } else if (this.inputVisible) {
        this.composerInputSurface()
      } else {
        Row().width('100%').height(52)
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: this.maxContentWidth > 0 ? this.maxContentWidth : (this.floatingGlass ? 720 : 760) })
    .alignSelf(ItemAlign.Center)
    .padding({
      left: 12,
      right: 12,
      top: this.floatingGlass ? 0 : 4,
      bottom: this.floatingGlass ? this.floatingBottomInset : 2,
    })
  }
}
