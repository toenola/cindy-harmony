import { UI_FONT_ACTION, UI_ICON_SIZE_COMPACT, UI_SPACE_PAGE, UI_TOUCH_TARGET_MIN } from '../UiKit';
import { uiAccessibleString } from './UiAccessibility';

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

/** Icon colors are selected by role, never passed as raw colors. */
export type UiIconRole = 'normal' | 'danger' | 'onMedia';

@Component
export struct UiIconButton {
  @Require @Prop label: string = '';
  @Require @Prop glyph: Resource = $r('sys.symbol.plus');
  @Prop actionEnabled: boolean = true;
  @Prop disabledHint?: ResourceStr;
  @Prop iconRole: UiIconRole = 'normal';
  @Prop loading: boolean = false;
  @Prop loadingLabel: ResourceStr = $r('app.string.v140_companion_create_loading');
  onAction: () => void = () => {};

  private iconTint(): Resource {
    if (this.iconRole === 'danger') return $r('app.color.danger');
    if (this.iconRole === 'onMedia') return $r('app.color.chat_overlay_text');
    return $r('app.color.text_primary');
  }

  private spokenLabel(): string {
    const reason = uiAccessibleString(this.getUIContext(),
      this.loading ? this.loadingLabel : this.actionEnabled ? undefined : this.disabledHint);
    return reason.length > 0 && reason !== this.label ? this.label + ' · ' + reason : this.label;
  }

  build() {
    Button() {
      if (this.loading) {
        LoadingProgress()
          .width(UI_ICON_SIZE_COMPACT)
          .height(UI_ICON_SIZE_COMPACT)
          .color(this.iconTint())
          .accessibilityLevel('no-hide-descendants')
      } else {
        SymbolGlyph(this.glyph)
          .fontSize(UI_ICON_SIZE_COMPACT)
          .fontColor([this.iconTint()])
          .accessibilityLevel('no')
      }
    }
    .type(ButtonType.Circle)
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .width(UI_TOUCH_TARGET_MIN)
    .height(UI_TOUCH_TARGET_MIN)
    .padding(0)
    .enabled(this.actionEnabled && !this.loading)
    .accessibilityLevel('yes')
    .accessibilityText(this.spokenLabel())
    .bindTips(this.spokenLabel())
    .onClick(() => { if (this.actionEnabled && !this.loading) this.onAction(); })
  }
}
