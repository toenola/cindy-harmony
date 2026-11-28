import { UI_FONT_LIST_TITLE, UI_FONT_SECONDARY, UI_ICON_SIZE_COMPACT, UI_LIST_CLICK_EFFECT, UI_SPACE_INLINE } from './UiKit';
import { UiIconButton } from './common/UiActions';

@Component
export struct ModelPickerListRow {
  @Prop modelName: string = '';
  @Prop providerName: string = '';
  @Prop providerIconUrl: string = '';
  @Prop showConfigure: boolean = true;
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
        Row({ space: UI_SPACE_INLINE }) {
          if (this.providerIconUrl) {
            Image(this.providerIconUrl).width(UI_ICON_SIZE_COMPACT).height(UI_ICON_SIZE_COMPACT).objectFit(ImageFit.Contain)
          } else if (this.providerKind === 'openai' || this.providerKind === 'claude') {
            Image(this.providerKind === 'openai' ? $r('app.media.usage_provider_openai')
              : $r('app.media.usage_provider_anthropic'))
              .width(UI_ICON_SIZE_COMPACT).height(UI_ICON_SIZE_COMPACT).objectFit(ImageFit.Contain).fillColor($r('app.color.text_secondary'))
          } else {
            Text(this.providerName.charAt(0).toUpperCase() || '•').width(22).textAlign(TextAlign.Center)
              .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
          }
          Column({ space: 3 }) {
            Text(this.modelName).fontSize(UI_FONT_LIST_TITLE).fontColor($r('app.color.text_primary'))
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            if (this.harness || this.effort || this.quota) {
              Row({ space: 4 }) {
                if (this.harness) {
                  Text(this.harness === 'codex' ? '✣' : this.harness === 'pi' ? 'π' : '♟')
                    .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
                }
                Text(this.effort && this.quota ? this.effort + ' · ' + this.quota : this.effort || this.quota)
                  .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
                  .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%')
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Stack() {
            if (this.selected) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.accent')])
            }
          }.width(20).height(20).accessibilityLevel('no')
        }.width('100%')
      }.type(ButtonType.Normal).layoutWeight(1).constraintSize({ minHeight: 52 })
        .padding({ left: 12, right: 4, top: 6, bottom: 6 }).backgroundColor(Color.Transparent)
        .clickEffect(UI_LIST_CLICK_EFFECT).enabled(this.available)
        .accessibilityText([this.modelName, this.providerName, this.harness, this.effort, this.quota].join(' · '))
        .accessibilitySelected(this.selected).onClick(() => this.onPick())
      if (this.showConfigure) {
        UiIconButton({ glyph: $r('sys.symbol.slider_horizontal_2'), label: this.modelName + ' 模型设置',
          actionEnabled: this.canConfigure, onAction: () => this.onConfigure() })
      }
    }.width('100%').padding({ right: 4 })
  }
}
