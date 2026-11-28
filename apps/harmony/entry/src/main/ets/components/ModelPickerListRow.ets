import { UI_ICON_CLICK_EFFECT, UI_LIST_CLICK_EFFECT, uiFontSize } from './UiKit';

@Component
export struct ModelPickerListRow {
  @Prop modelName: string = '';
  @Prop providerName: string = '';
  @Prop providerKind: string = '';
  @Prop harness: string = '';
  @Prop effort: string = '';
  @Prop quota: string = '';
  @Prop selected: boolean = false;
  @Prop available: boolean = true;
  @Prop canConfigure: boolean = true;
  onPick: () => void = () => {};
  onConfigure: () => void = () => {};

  build() {
    Row() {
      Button() {
        Row({ space: 8 }) {
          if (this.providerKind === 'openai' || this.providerKind === 'claude') {
            Image(this.providerKind === 'openai' ? $r('app.media.usage_provider_openai')
              : $r('app.media.usage_provider_anthropic'))
              .width(22).height(22).objectFit(ImageFit.Contain).fillColor($r('app.color.text_secondary'))
          } else {
            Text(this.providerName.charAt(0).toUpperCase() || '•').width(22).textAlign(TextAlign.Center)
              .fontSize(uiFontSize(15)).fontColor($r('app.color.text_secondary'))
          }
          Column({ space: 3 }) {
            Row({ space: 6 }) {
              Text(this.modelName).fontSize(uiFontSize(14)).fontColor($r('app.color.text_primary'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              if (this.effort) {
                Text(this.effort).fontSize(uiFontSize(12)).fontColor($r('app.color.text_secondary'))
              }
              Text(this.harness === 'codex' ? '✣' : this.harness === 'pi' ? 'π' : '♟')
                .fontSize(uiFontSize(14)).fontColor($r('app.color.text_secondary'))
            }.width('100%')
            if (this.quota) {
              Text(this.quota).fontSize(uiFontSize(12)).fontColor($r('app.color.text_secondary'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          if (this.selected) {
            SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.text_primary')])
          }
        }.width('100%')
      }.type(ButtonType.Normal).layoutWeight(1).constraintSize({ minHeight: 52 })
        .padding({ left: 12, right: 4, top: 6, bottom: 6 }).backgroundColor(Color.Transparent)
        .clickEffect(UI_LIST_CLICK_EFFECT).enabled(this.available)
        .accessibilityText([this.modelName, this.providerName, this.harness, this.effort, this.quota].join(' · '))
        .accessibilitySelected(this.selected).onClick(() => this.onPick())
      Button() {
        SymbolGlyph($r('sys.symbol.slider_horizontal_2')).fontSize(17).fontColor([$r('app.color.text_secondary')])
      }.type(ButtonType.Circle).width(44).height(44).padding(0).backgroundColor(Color.Transparent)
        .clickEffect(UI_ICON_CLICK_EFFECT).accessibilityText(this.modelName + ' 模型设置')
        .enabled(this.canConfigure).onClick(() => this.onConfigure())
    }.width('100%').padding({ right: 4 })
  }
}
