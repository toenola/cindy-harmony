import { UI_RADIUS_CONTAINER, UI_LIST_CLICK_EFFECT, uiFontSize, uiLineHeight } from './UiKit';

@Component
export struct HarmonySettingsGroup {
  @Prop title: string = '';
  @Prop footer: string = '';
  @Prop collapsible: boolean = false;
  @Prop expanded: boolean = true;
  @BuilderParam content: () => void = this.emptyContent;
  onToggle: () => void = () => {
  };

  @Builder
  private emptyContent() {
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.title)
          .fontSize(uiFontSize(13))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
        if (this.collapsible) {
          SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
            .fontSize(uiFontSize(15))
            .fontColor([$r('app.color.text_tertiary')])
        }
      }
      .width('100%')
      .height(24)
      .padding({ left: 12, right: 12 })
      .enabled(this.collapsible)
      .onClick(() => {
        if (this.collapsible) this.onToggle();
      })
      if (!this.collapsible || this.expanded) {
        Column() {
          this.content()
        }
        .width('100%')
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: 1, color: $r('app.color.border') })
        .borderRadius(UI_RADIUS_CONTAINER)
        .clip(true)
      }
      if (this.footer.length > 0 && (!this.collapsible || this.expanded)) {
        Text(this.footer)
          .fontSize(uiFontSize(12))
          .lineHeight(uiLineHeight(17))
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ left: 12, right: 12 })
      }
    }
    .width('100%')
  }
}

@Component
export struct HarmonySettingsRow {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop detail: string = '';
  @Prop showChevron: boolean = false;
  onRowClick: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.label)
          .fontSize(uiFontSize(14))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.detail.length > 0) {
          Text(this.detail)
            .fontSize(uiFontSize(12))
            .lineHeight(uiLineHeight(17))
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(uiFontSize(13))
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.End)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '48%' })
      }
      if (this.showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(uiFontSize(15))
          .fontColor([$r('app.color.text_tertiary')])
      }
    }
    .width('100%')
    .height(this.detail.length > 0 ? 64 : 52)
    .padding({ left: 16, right: 12, top: 10, bottom: 10 })
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => this.onRowClick())
  }
}
