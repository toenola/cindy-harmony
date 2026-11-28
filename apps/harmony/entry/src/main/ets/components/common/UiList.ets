import { ComposeListItem, ContentItem, OperationType, OperateItem, SubHeader } from '@kit.ArkUI';
import { UI_FONT_CAPTION, UI_RADIUS_CARD, UI_SPACE_INLINE, UI_SPACE_PAGE } from '../UiKit';

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

/** Native row content. Put it in ListItem at a List/ListItemGroup call site, or in a settings card. */
@Component
export struct UiListRow {
  @Require @Prop label: ResourceStr = '';
  @Prop value?: ResourceStr;
  @Prop detail?: ResourceStr;
  @Prop showChevron: boolean = false;
  @Prop rowEnabled: boolean = true;
  onRowClick?: () => void;

  private nativeContent(): ContentItem {
    return { primaryText: this.label, secondaryText: this.detail };
  }

  private nativeOperation(): OperateItem {
    return {
      text: this.value,
      arrow: this.showChevron ? { value: $r('sys.media.ohos_ic_public_arrow_right') } : undefined,
    };
  }

  build() {
    if (this.onRowClick !== undefined) {
      ComposeListItem({ contentItem: this.nativeContent(), operateItem: this.nativeOperation() })
        .enabled(this.rowEnabled)
        .focusable(true)
        .onClick(() => this.onRowClick?.())
    } else {
      ComposeListItem({ contentItem: this.nativeContent(), operateItem: this.nativeOperation() })
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
