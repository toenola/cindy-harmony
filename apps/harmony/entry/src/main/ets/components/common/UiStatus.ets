import { ExceptionPrompt, MarginType } from '@kit.ArkUI';
import { UI_FONT_SECONDARY, UI_FONT_TITLE_S, UI_SPACE_INLINE, UI_SPACE_SECTION } from '../UiKit';
import { UiActionButton } from './UiActions';

@Component
export struct UiInlineError {
  @Require @Prop message: ResourceStr = '';
  @Prop actionLabel?: ResourceStr;
  onAction?: () => void;

  build() {
    ExceptionPrompt({
      options: {
        tip: this.message,
        actionText: this.onAction !== undefined ? this.actionLabel : undefined,
        marginType: MarginType.FIT_MARGIN,
        marginTop: 0,
        isShown: true,
      },
      onActionTextClick: () => this.onAction?.(),
    })
  }
}

/** Empty is not an exception. Keep the first useful action available without a warning surface. */
@Component
export struct UiEmptyState {
  @Require @Prop heading: ResourceStr = '';
  @Prop message?: ResourceStr;
  @Prop actionLabel?: ResourceStr;
  onAction?: () => void;

  build() {
    Column({ space: UI_SPACE_INLINE }) {
      Text(this.heading)
        .fontSize(UI_FONT_TITLE_S)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Center)
      if (this.message !== undefined) {
        Text(this.message)
          .fontSize(UI_FONT_SECONDARY)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
      }
      if (this.actionLabel !== undefined && this.onAction !== undefined) {
        UiActionButton({ label: this.actionLabel, onAction: () => this.onAction?.() })
      }
    }
    .width('100%')
    .padding(UI_SPACE_SECTION)
  }
}
