import { promptAction } from '@kit.ArkUI';
import { RemoteImageRef } from '../core/attachments/AttachmentModels';
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
  @Prop sending: boolean = false;
  @Prop streaming: boolean = false;
  @Prop hasContent: boolean = false;
  @Prop canSend: boolean = false;
  @Prop composerEnabled: boolean = true;
  @Prop pickingImages: boolean = false;
  @Prop contextBusy: boolean = false;
  @Prop hasPermissionOptions: boolean = false;
  @Prop hasModelOptions: boolean = false;
  @Prop permissionMode: string = '';
  @Prop planModeEnabled: boolean = false;
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
  onModel: () => void = () => {};
  onPlanToggle: () => void = () => {};
  onSend: () => void = () => {};
  onAbort: () => void = () => {};
  onRemoveImage: (image: ComposerImage) => void = () => {};
  onRetryImage: (image: ComposerImage) => void = () => {};

  private hasModelChip(): boolean {
    return this.hasModelOptions && (this.focused || this.images.length > 0);
  }

  private hasControlRow(): boolean {
    return this.focused || this.images.length > 0;
  }

  private expanded(): boolean {
    return this.focused || this.images.length > 0;
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

  /** 胶囊内的圆形 icon 按钮（加号 / 权限）。 */
  @Builder
  composerIconButton(symbol: Resource, tint: Resource, enabled: boolean, action: () => void) {
    Button() {
      SymbolGlyph(symbol)
        .fontSize(18)
        .fontColor([tint])
    }
    .type(ButtonType.Circle)
    .width(34)
    .height(34)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.4)
    .onClick(action)
  }

  build() {
    Column({ space: 6 }) {
      if (this.showStreamingStatus && this.streaming) {
        Row({ space: 6 }) {
          LoadingProgress()
            .width(12)
            .height(12)
            .color($r('app.color.chat_status_accent'))
          Text('正在工作…')
            .fontSize(uiFontSize(12))
            .lineHeight(uiLineHeight(18))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.chat_status_accent'))
        }
        .height(20)
        .padding({ left: 12, right: 12 })
        .transition(uiRevealTransition())
      }

      Column({ space: 6 }) {
        if (this.images.length > 0) {
          List({ space: 0 }) {
            ForEach(this.images, (image: ComposerImage) => {
              ListItem() {
                this.composerImageItem(image)
              }
            }, (image: ComposerImage) => image.uri)
          }
          .listDirection(Axis.Horizontal)
          .width('100%')
          .height(76)
          .transition(uiRevealTransition())
        }

        if (this.focused) {
          Row() {
            Divider()
              .width(36)
              .strokeWidth(4)
              .color($r('app.color.composer_border'))
              .borderRadius(2)
          }
          .height(10)
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .transition(uiRevealTransition())
        }

        Row({ space: 6 }) {
          if (this.hasControlRow()) {
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
          }

          TextArea({ placeholder: this.placeholder, text: this.input })
            .id(this.inputId)
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
            .constraintSize({
              minHeight: 34,
              maxHeight: this.expanded() ? 120 : 40,
            })
            .layoutWeight(1)
            .onFocus(() => this.onFocusChange(true))
            .onBlur(() => this.onFocusChange(false))
            .onChange((value: string) => this.onInputChange(value))

          if (this.hasModelChip()) {
            Button() {
              Row({ space: 4 }) {
                Text(this.modelLabel)
                  .fontSize(uiFontSize(12))
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.effortLabel.length > 0) {
                  Text('·')
                    .fontSize(uiFontSize(12))
                    .fontColor($r('app.color.text_tertiary'))
                  Text(this.effortLabel)
                    .fontSize(uiFontSize(12))
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                SymbolGlyph($r('sys.symbol.chevron_down'))
                  .fontSize(11)
                  .fontColor([$r('app.color.text_tertiary')])
              }
              .alignItems(VerticalAlign.Center)
            }
            .type(ButtonType.Normal)
            .height(30)
            .constraintSize({ minWidth: 88, maxWidth: 170 })
            .padding({ left: 12, right: 10 })
            .borderRadius(UI_RADIUS_PILL)
            .backgroundColor($r('app.color.bg_chip'))
            .clickEffect(UI_CLICK_EFFECT)
            .enabled(this.composerEnabled && !this.sending && !this.contextBusy)
            .onClick(() => this.onModel())
          }

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
          .width(34)
          .height(34)
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
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .constraintSize({ minHeight: 36 })
      .padding({
        left: 10,
        right: 10,
        top: this.expanded() ? 6 : 3,
        bottom: this.expanded() ? 6 : 3,
      })
      .backgroundColor($r('app.color.composer_surface'))
      .border({ width: 1, color: $r('app.color.composer_border') })
      .borderRadius(this.expanded() ? UI_RADIUS_CONTAINER : UI_RADIUS_PILL)
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
