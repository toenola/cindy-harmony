import { OperationType, SubHeader } from '@kit.ArkUI';
import { UI_FONT_CAPTION, UI_FONT_LIST_TITLE, UI_FONT_SECONDARY, UI_ICON_SIZE_COMPACT, UI_RADIUS_CARD,
  UI_RADIUS_CONTROL, UI_SPACE_INLINE, UI_SPACE_PAGE, UI_SPACE_TIGHT, UI_TOUCH_TARGET_MIN } from '../UiKit';
import { uiAccessibleString } from './UiAccessibility';

@Component
export struct UiCard {
  @BuilderParam content: () => void = this.emptyContent;
  @Prop inset: number = UI_SPACE_PAGE;

  @Builder
  private emptyContent() {}

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(this.inset)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(UI_RADIUS_CARD)
  }
}

/** A single native Button owns an actionable row; its content slots never receive separate focus. */
@Component
export struct UiListRow {
  @Require @Prop label: ResourceStr = '';
  @Prop value?: ResourceStr;
  @Prop detail?: ResourceStr;
  @Prop showChevron: boolean = false;
  @Prop rowEnabled: boolean = true;
  /** Optional localized status and specific action hint. The Button supplies the generic activation hint. */
  @Prop status?: ResourceStr;
  @Prop actionHint?: ResourceStr;
  onRowClick?: () => void;

  private spokenLabel(): string {
    const context = this.getUIContext();
    return [this.label, this.value, this.detail, this.status]
      .map((entry: ResourceStr | undefined): string => uiAccessibleString(context, entry))
      .filter((entry: string): boolean => entry.length > 0)
      .join(' · ');
  }

  @Builder
  private rowContent() {
    Row({ space: UI_SPACE_INLINE }) {
      Column({ space: UI_SPACE_TIGHT }) {
        Text(this.label)
          .fontSize(UI_FONT_LIST_TITLE).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.detail !== undefined) {
          Text(this.detail)
            .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.value !== undefined) {
        Text(this.value)
          .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
          .constraintSize({ maxWidth: '45%' })
          .textAlign(TextAlign.End).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (this.showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(UI_ICON_SIZE_COMPACT).fontColor([$r('app.color.text_secondary')])
          .flexShrink(0)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: UI_TOUCH_TARGET_MIN })
    .padding({ left: UI_SPACE_PAGE, right: UI_SPACE_PAGE, top: UI_SPACE_INLINE, bottom: UI_SPACE_INLINE })
    .focusable(false)
    .accessibilityLevel('no-hide-descendants')
  }

  build() {
    if (this.onRowClick !== undefined) {
      Button() {
        this.rowContent()
      }
      .type(ButtonType.Normal)
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .backgroundColor(Color.Transparent)
      .borderRadius(UI_RADIUS_CONTROL)
      .width('100%')
      .constraintSize({ minHeight: UI_TOUCH_TARGET_MIN })
      .padding(0)
      .enabled(this.rowEnabled)
      .accessibilityLevel('yes')
      .accessibilityText(this.spokenLabel())
      .accessibilityDescription(uiAccessibleString(this.getUIContext(), this.actionHint))
      .onClick(() => { if (this.rowEnabled) this.onRowClick?.(); })
    } else {
      Column() {
        this.rowContent()
      }
      .width('100%')
      .focusable(false)
      .accessibilityLevel('yes')
      .accessibilityText(this.spokenLabel())
    }
  }
}

/** Migration counterpart to HarmonySettingsGroup. The owning page still holds the collapsed state. */
@Component
export struct UiListGroup {
  @Require @Prop heading: ResourceStr = '';
  @Prop footer?: ResourceStr;
  @Prop expanded: boolean = true;
  /** Localized action for the current state, e.g. “Expand devices” or “Collapse devices”. */
  @Prop toggleLabel?: ResourceStr;
  onToggle?: () => void;
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  private emptyContent() {}

  build() {
    Column({ space: UI_SPACE_INLINE }) {
      if (this.onToggle !== undefined && this.toggleLabel !== undefined) {
        SubHeader({
          primaryTitle: this.heading,
          operationType: OperationType.BUTTON,
          operationItem: [{ value: this.toggleLabel, action: () => this.onToggle?.() }],
        })
      } else {
        SubHeader({ primaryTitle: this.heading })
      }
      if (this.onToggle === undefined || this.toggleLabel === undefined || this.expanded) {
        UiCard({ inset: 0 }) {
          this.content()
        }
        if (this.footer !== undefined) {
          Text(this.footer)
            .fontSize(UI_FONT_CAPTION)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: UI_SPACE_PAGE, right: UI_SPACE_PAGE })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
