import { UI_FONT_ACTION, UI_ICON_SIZE_COMPACT, UI_SPACE_PAGE, UI_TOUCH_TARGET_MIN } from '../UiKit';

export enum UiActionKind {
  Primary,
  Secondary,
  Danger,
}

@Component
export struct UiActionButton {
  @Require @Prop label: ResourceStr = '';
  @Prop kind: UiActionKind = UiActionKind.Secondary;
  @Prop actionEnabled: boolean = true;
  onAction: () => void = () => {};

  build() {
    Button(this.label)
      .buttonStyle(this.kind === UiActionKind.Secondary ? ButtonStyleMode.NORMAL : ButtonStyleMode.EMPHASIZED)
      .role(this.kind === UiActionKind.Danger ? ButtonRole.ERROR : ButtonRole.NORMAL)
      .fontSize(UI_FONT_ACTION)
      .fontWeight(FontWeight.Medium)
      .padding({ left: UI_SPACE_PAGE, right: UI_SPACE_PAGE })
      .constraintSize({ minHeight: UI_TOUCH_TARGET_MIN })
      .enabled(this.actionEnabled)
      .onClick(() => this.onAction())
  }
}

@Component
export struct UiIconButton {
  @Require @Prop label: string = '';
  @Require @Prop glyph: Resource = $r('sys.symbol.plus');
  @Prop actionEnabled: boolean = true;
  @Prop disabledHint?: ResourceStr;
  onAction: () => void = () => {};

  build() {
    Button() {
      SymbolGlyph(this.glyph)
        .fontSize(UI_ICON_SIZE_COMPACT)
        .fontColor([$r('app.color.text_primary')])
        .accessibilityLevel('no')
    }
    .type(ButtonType.Circle)
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .width(UI_TOUCH_TARGET_MIN)
    .height(UI_TOUCH_TARGET_MIN)
    .padding(0)
    .enabled(this.actionEnabled)
    .accessibilityText(this.label)
    .bindTips(this.actionEnabled ? this.label : this.disabledHint ?? this.label)
    .onClick(() => this.onAction())
  }
}
