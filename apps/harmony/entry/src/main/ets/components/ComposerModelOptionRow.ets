import {
  UI_RADIUS_CONTROL,
  UI_RADIUS_PILL,
  uiFontSize,
  uiLineHeight,
} from './UiKit';

/** 新建任务与任务详情共用的模型选项行；页面只负责业务状态与回调。 */
@Component
export struct ComposerModelOptionRow {
  @Prop label: string = '';
  @Prop providerKind: string = 'other';
  @Prop providerInitial: string = 'S';
  @Prop selected: boolean = false;
  @Prop subscription: boolean = false;
  @Prop paymentRequired: boolean = false;
  @Prop disabled: boolean = false;
  @Prop effortIds: string[] = [];
  @Prop selectedEffort: string = '';
  @Prop effortPickerOpen: boolean = false;
  @Prop fastModeVisible: boolean = false;
  @Prop fastModeOn: boolean = false;
  effortLabel: (effort: string) => string = (effort: string): string => effort;
  onSelect: () => void = () => {};
  onToggleEffortPicker: () => void = () => {};
  onSelectEffort: (effort: string) => void = (_effort: string): void => {};
  onFastModeChange: (enabled: boolean) => void = (_enabled: boolean): void => {};

  @Builder
  private providerMark() {
    if (this.providerKind === 'claude') {
      Text('♟')
        .fontSize(uiFontSize(15))
        .fontColor($r('app.color.text_secondary'))
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
    } else if (this.providerKind === 'deepseek') {
      Text('◉')
        .fontSize(uiFontSize(15))
        .fontColor($r('app.color.text_secondary'))
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
    } else if (this.providerKind === 'openai') {
      Text('✣')
        .fontSize(uiFontSize(14))
        .fontColor($r('app.color.text_secondary'))
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
    } else {
      Text(this.providerInitial)
        .fontSize(uiFontSize(11))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .width(20)
        .height(20)
        .textAlign(TextAlign.Center)
        .border({ width: 1, color: $r('app.color.text_secondary') })
        .borderRadius(UI_RADIUS_PILL)
    }
  }

  build() {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        Stack() {
          this.providerMark()
        }
        .onClick(() => this.onSelect())

        Text(this.label)
          .fontSize(uiFontSize(14))
          .lineHeight(uiLineHeight(20))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .onClick(() => this.onSelect())

        if (this.effortIds.length > 0) {
          Button() {
            Row({ space: 3 }) {
              Text(this.effortLabel(this.selectedEffort))
                .fontSize(uiFontSize(12))
                .fontColor($r('app.color.text_secondary'))
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(uiFontSize(9))
                .fontColor([$r('app.color.text_tertiary')])
            }
          }
          .height(28)
          .padding({ left: 5, right: 5 })
          .backgroundColor(Color.Transparent)
          .enabled(!this.disabled && (!this.paymentRequired || this.selected))
          .accessibilityText(`${this.label}思考强度`)
          .onClick(() => this.onToggleEffortPicker())
        }

        if (this.fastModeVisible) {
          Toggle({ type: ToggleType.Switch, isOn: this.fastModeOn })
            .selectedColor($r('app.color.accent'))
            .enabled(!this.disabled && (!this.paymentRequired || this.selected))
            .accessibilityText(`${this.label}快速模式`)
            .onChange((enabled: boolean) => this.onFastModeChange(enabled))
        }

        // 固定保留尾部状态位，选中勾出现或消失时不重新挤压模型名称与右侧控件。
        Stack({ alignContent: Alignment.Center }) {
          if (this.selected) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(uiFontSize(17))
              .fontColor([$r('app.color.text_primary')])
              .onClick(() => this.onSelect())
          } else if (this.paymentRequired) {
            Text('需付费')
              .fontSize(uiFontSize(10))
              .fontColor($r('app.color.text_tertiary'))
              .backgroundColor($r('app.color.bg_chip'))
              .borderRadius(UI_RADIUS_CONTROL)
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          } else if (this.subscription) {
            Text('订阅')
              .fontSize(uiFontSize(10))
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.bg_chip'))
              .borderRadius(UI_RADIUS_CONTROL)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          }
        }
        .width(32)
        .height(28)
      }
      .width('100%')
      .constraintSize({ minHeight: 38 })

      if (this.effortPickerOpen) {
        Row({ space: 4 }) {
          ForEach(this.effortIds, (effort: string) => {
            Button(this.effortLabel(effort))
              .height(26)
              .fontSize(uiFontSize(11))
              .fontColor(effort === this.selectedEffort
                ? $r('app.color.chat_cta_text') : $r('app.color.text_secondary'))
              .padding({ left: 9, right: 9 })
              .backgroundColor(effort === this.selectedEffort
                ? $r('app.color.chat_cta') : $r('app.color.bg_chip'))
              .borderRadius(UI_RADIUS_PILL)
              .onClick(() => this.onSelectEffort(effort))
          }, (effort: string) => effort)
        }
        .width('100%')
        .padding({ left: 26, right: 4, bottom: 4 })
      }
    }
    .width('calc(100% - 24vp)')
    .padding({ left: 9, right: 7, top: 3, bottom: 3 })
    .margin({ left: 12, right: 12 })
    .backgroundColor(this.selected ? $r('app.color.bg_chip') : Color.Transparent)
    .borderRadius(UI_RADIUS_CONTROL)
    .opacity(this.disabled || (this.paymentRequired && !this.selected) ? 0.55 : 1)
    .enabled(!this.disabled && (!this.paymentRequired || this.selected))
  }
}

/** 模型目录的供应商分组标题，与两种会话入口的行宽保持一致。 */
@Component
export struct ComposerModelProviderHeader {
  @Prop name: string = '';

  build() {
    Row() {
      Text(this.name)
        .fontSize(uiFontSize(12))
        .fontWeight(FontWeight.Normal)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('calc(100% - 36vp)')
    .height(26)
    .margin({ left: 18, right: 18, top: 4 })
  }
}
