import { promptAction } from '@kit.ArkUI';
import {
  RemoteImageRef,
  composerAttachmentRenderKey,
} from '../core/attachments/AttachmentModels';
import { ComposerFile } from '../core/attachments/ComposerFileQueue';
import { ComposerAtomPresentation } from '../core/messages/ComposerDocument';
import {
  UI_CLICK_EFFECT,
  UI_ICON_CLICK_EFFECT,
  UI_CURVE_MOVE,
  UI_MOTION_BASE,
  UI_RADIUS_CONTAINER,
  UI_RADIUS_CONTROL,
  UI_RADIUS_PILL,
  uiFontSize,
  uiLineHeight,
  uiRevealTransition,
} from './UiKit';

/** 待发送图片（上传状态机：uploading → ready / failed）。 */
export class ComposerImage {
  uri: string = '';
  name: string = '';
  status: string = 'uploading';
  ref: RemoteImageRef | null = null;
  /** 用户已移除；异步上传若稍后成功，立即回收中转对象。 */
  removed: boolean = false;
  /** 每次上传/重试/移除递增；旧异步回调不得覆盖新尝试。 */
  uploadRevision: number = 0;
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
  @Prop contextBusy: boolean = false;
  @Prop hasPermissionOptions: boolean = false;
  @Prop hasAgentOptions: boolean = false;
  @Prop hasModelOptions: boolean = false;
  @Prop permissionMode: string = '';
  @Prop planModeEnabled: boolean = false;
  @Prop agentLabel: string = '';
  @Prop modelLabel: string = '';
  @Prop effortLabel: string = '';
  @Prop showAddButton: boolean = true;
  @Prop showStreamingStatus: boolean = true;
  @Prop inputId: string = 'task-composer-input';
  @Prop placeholder: string = '输入远程消息';

  onInputChange: (value: string) => void = () => {};
  onFocusChange: (focused: boolean) => void = () => {};
  onAdd: () => void = () => {};
  onPermission: () => void = () => {};
  onAgent: () => void = () => {};
  onModel: () => void = () => {};
  onPlanToggle: () => void = () => {};
  onSend: () => void = () => {};
  onAbort: () => void = () => {};
  onPreviewImage: (image: ComposerImage) => void = () => {};
  onRemoveImage: (image: ComposerImage) => void = () => {};
  onRetryImage: (image: ComposerImage) => void = () => {};
  onRemoveFile: (file: ComposerFile) => void = () => {};
  onRetryFile: (file: ComposerFile) => void = () => {};
  onRemoveAtom: (atom: ComposerAtomPresentation) => void = () => {};
  @State inputMaxHeight: number = 120;
  @State resizing: boolean = false;
  private resizeStartY: number = 0;
  private resizeStartHeight: number = 120;

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
    return this.hasModelOptions && this.expanded();
  }

  private hasAgentChip(): boolean {
    return this.hasAgentOptions && this.expanded();
  }

  private expanded(): boolean {
    return this.focused || this.images.length > 0 || this.files.length > 0 || this.atoms.length > 0;
  }

  private tapPrimaryAction(): void {
    if (this.streaming && !this.hasContent) {
      this.onAbort();
    } else if (this.canSend) {
      this.onSend();
    } else {
      this.onFocusChange(true);
      setTimeout(() => {
        focusControl.requestFocus(this.inputId);
        promptAction.showToast({ message: '请点击系统键盘中的麦克风' });
      }, 0);
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
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(10)
            .fontColor([$r('app.color.chat_overlay_text')])
        }
        .width(18)
        .height(18)
        .backgroundColor($r('app.color.overlay'))
        .borderRadius(UI_RADIUS_PILL)
        .clickEffect(UI_ICON_CLICK_EFFECT)
        .onClick(() => this.onRemoveImage(image))
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
          .onClick(() => this.onRetryImage(image))
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
          .onClick(() => this.onRetryFile(file))
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
      .onClick(() => this.onRemoveFile(file))
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
  composerIconButton(symbol: Resource, tint: Resource, enabled: boolean, action: () => void) {
    Button() {
      SymbolGlyph(symbol)
        .fontSize(18)
        .fontColor([tint])
    }
    .type(ButtonType.Circle)
    .width(40)
    .height(40)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.4)
    .onClick(action)
  }

  /** 展开态工具栏里的模型胶囊；窄屏只压缩文字，不挤占上方输入区域。 */
  @Builder
  composerModelButton() {
    Button() {
      Row({ space: 4 }) {
        Text(this.effortLabel.length > 0
          ? `${this.modelLabel} · ${this.effortLabel}`
          : this.modelLabel)
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(11)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .type(ButtonType.Normal)
    .height(30)
    .constraintSize({ minWidth: 72, maxWidth: this.planModeEnabled ? 88 : 136 })
    .padding({ left: 12, right: 10 })
    .borderRadius(UI_RADIUS_PILL)
    .backgroundColor($r('app.color.bg_chip'))
    .clickEffect(UI_CLICK_EFFECT)
    .enabled(this.composerEnabled && !this.sending && !this.contextBusy)
    .onClick(() => this.onModel())
  }

  /** 展开态工具栏里的独立 Agent 胶囊，位于模型胶囊之前。 */
  @Builder
  composerAgentButton() {
    Button() {
      Row({ space: 4 }) {
        Text(this.agentLabel)
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(11)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .type(ButtonType.Normal)
    .height(30)
    .constraintSize({ minWidth: 58, maxWidth: 92 })
    .padding({ left: 10, right: 8 })
    .borderRadius(UI_RADIUS_PILL)
    .backgroundColor($r('app.color.bg_chip'))
    .clickEffect(UI_CLICK_EFFECT)
    .enabled(this.composerEnabled && !this.sending && !this.contextBusy)
    .onClick(() => this.onAgent())
  }

  @Builder
  composerPrimaryButton() {
    Button() {
      if (this.sending) {
        LoadingProgress()
          .width(15)
          .height(15)
          .color($r('app.color.chat_cta_text'))
      } else if (this.streaming && !this.hasContent) {
        SymbolGlyph($r('sys.symbol.square'))
          .fontSize(11)
          .fontColor([$r('app.color.chat_cta_text')])
      } else if (this.canSend) {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(17)
          .fontColor([$r('app.color.chat_cta_text')])
      } else {
        SymbolGlyph($r('sys.symbol.mic'))
          .fontSize(18)
          .fontColor([$r('app.color.chat_text_secondary')])
      }
    }
    .type(ButtonType.Circle)
    .width(40)
    .height(40)
    .padding(0)
    .borderRadius(UI_RADIUS_PILL)
    .backgroundColor((this.streaming && !this.hasContent) || this.canSend
      ? $r('app.color.chat_cta')
      : Color.Transparent)
    .animation({ duration: UI_MOTION_BASE, curve: UI_CURVE_MOVE })
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .enabled(this.composerEnabled && !this.sending)
    .onClick(() => this.tapPrimaryAction())
  }

  build() {
    Column({ space: 6 }) {
      if (this.showStreamingStatus && this.streaming) {
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
        .height(20)
        .padding({ left: 12, right: 12 })
        .transition(uiRevealTransition())
      }

      Column({ space: 6 }) {
        if (this.expanded()) {
          Row() {
            Row()
              .width(36)
              .height(4)
              .backgroundColor(this.resizing
                ? $r('app.color.accent') : $r('app.color.border'))
              .borderRadius(UI_RADIUS_PILL)
          }
          .width('100%')
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
              image.uri, image.status, image.uploadRevision))
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
              file.uri, file.status, file.uploadRevision))
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

        // 输入节点始终留在同一行内，聚焦切换布局时不会因重挂载而丢焦点。
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
              .align(Alignment.Center)
              .textAlign(TextAlign.Start)
              .padding({ left: 4, right: 4 })
              .width('100%')
              .constraintSize({
                minHeight: 40,
                maxHeight: this.expanded() ? this.inputMaxHeight : 40,
              })
              .onFocus(() => this.onFocusChange(true))
              .onBlur(() => this.onFocusChange(false))
              .onChange((value: string) => this.onInputChange(value))
          }
          .layoutWeight(1)

          if (!this.expanded()) {
            this.composerPrimaryButton()
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.expanded()) {
          // Mobile 同源卡片态：上方输入独占整行，所有控制固定在底部工具栏。
          Row({ space: 6 }) {
            if (this.showAddButton) {
              this.composerIconButton(
                $r('sys.symbol.plus'),
                $r('app.color.text_primary'),
                this.composerEnabled && !this.sending && !this.pickingImages,
                () => this.onAdd(),
              )
            }

            if (this.hasPermissionOptions) {
              this.composerIconButton(
                $r('sys.symbol.lock'),
                this.permissionMode === 'bypassPermissions' || this.permissionMode === 'auto'
                  ? $r('app.color.danger')
                  : $r('app.color.text_secondary'),
                this.composerEnabled && !this.sending && !this.contextBusy,
                () => this.onPermission(),
              )
            }

            if (this.planModeEnabled) {
              Button('计划')
                .height(30)
                .fontSize(uiFontSize(12))
                .fontColor($r('app.color.chat_cta_text'))
                .backgroundColor($r('app.color.chat_cta'))
                .borderRadius(UI_RADIUS_PILL)
                .padding({ left: 12, right: 12 })
                .clickEffect(UI_CLICK_EFFECT)
                .enabled(this.composerEnabled && !this.contextBusy)
                .onClick(() => this.onPlanToggle())
            }

            Row().layoutWeight(1)

            if (this.hasAgentChip()) {
              this.composerAgentButton()
            }

            if (this.hasModelChip()) {
              this.composerModelButton()
            }

            this.composerPrimaryButton()
          }
          .width('100%')
          .constraintSize({ minHeight: 40 })
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 36 })
      .padding({
        left: 10,
        right: 10,
        top: this.expanded() ? 8 : 4,
        bottom: this.expanded() ? 8 : 4,
      })
      .backgroundColor($r('app.color.composer_surface'))
      .border({ width: 1, color: $r('app.color.composer_border') })
      // 收起态使用实际高度的一半做胶囊圆角，避免动画在 999→12 间插值抖动。
      .borderRadius(this.expanded() ? UI_RADIUS_CONTAINER : 24)
      .animation({ duration: UI_MOTION_BASE, curve: UI_CURVE_MOVE })
    }
    .width('100%')
    .constraintSize({ maxWidth: 760 })
    .alignSelf(ItemAlign.Center)
    .padding({
      left: 12,
      right: 12,
      top: 4,
      bottom: 2,
    })
  }
}
