import { UI_ICON_CLICK_EFFECT, UI_RADIUS_CONTROL, uiFontSize } from '../UiKit';

/** Pure display chrome shared by the chat home pages: icon button, text button and segmented switch. */

/** Transparent symbol-only button; the visual is 20 vp, the hit area stays 44 vp. */
@Component
export struct ChatIconButton {
  symbol: Resource = $r('sys.symbol.chevron_left');
  label: string = '';
  enable: boolean = true;
  onTap: () => void = (): void => {};

  build() {
    Button() {
      SymbolGlyph(this.symbol).fontSize(20).fontColor([$r('app.color.text_primary')])
    }
    .type(ButtonType.Circle).width(44).height(44).padding(0).backgroundColor(Color.Transparent)
    .opacity(this.enable ? 1 : 0.4).enabled(this.enable)
    .accessibilityText(this.label).clickEffect(UI_ICON_CLICK_EFFECT)
    .onClick((): void => { this.onTap(); })
  }
}

/** Secondary text action, quiet accent colour, no filled background. */
@Component
export struct ChatTextButton {
  label: string = '';
  enable: boolean = true;
  onTap: () => void = (): void => {};

  build() {
    Button(this.label, { type: ButtonType.Normal })
      .fontSize(uiFontSize(15)).fontColor($r('app.color.accent')).backgroundColor(Color.Transparent)
      .height(44).padding({ left: 8, right: 8 }).constraintSize({ minWidth: 44 })
      .opacity(this.enable ? 1 : 0.4).enabled(this.enable)
      .accessibilityText(this.label).clickEffect(UI_ICON_CLICK_EFFECT)
      .onClick((): void => { this.onTap(); })
  }
}

/** Light segmented switch: neutral track, selected segment lifted onto the card colour. */
@Component
export struct ChatSegmented {
  @Prop labels: string[] = [];
  @Prop selected: number = 0;
  @Prop disabledIndexes: number[] = [];
  onSelect: (index: number) => void = (_index: number): void => {};

  build() {
    Row() {
      ForEach(this.labels, (label: string, index: number) => {
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          Text(label).fontSize(uiFontSize(14)).fontWeight(this.selected === index ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(this.selected === index ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).padding({ left: 8, right: 8 })
        }
        .layoutWeight(1).height(36).borderRadius(UI_RADIUS_CONTROL - 2).padding(0)
        .backgroundColor(this.selected === index ? $r('app.color.bg_card') : Color.Transparent)
        .opacity(this.disabledIndexes.includes(index) ? 0.4 : 1)
        .enabled(!this.disabledIndexes.includes(index))
        .accessibilityText(label)
        .onClick((): void => { this.onSelect(index); })
      }, (label: string, index: number): string => `${index}:${label}`)
    }
    .width('100%').height(40).padding(2).borderRadius(UI_RADIUS_CONTROL).backgroundColor($r('app.color.bg_chip'))
  }
}
