import { curves } from '@kit.ArkUI';
import { KeyCode } from '@kit.InputKit';
import { UI_TOUCH_TARGET_MIN } from '../UiKit';
import { uiMenuOptions } from './UiOverlay';
import { SplitHandleStep, splitHandlePreviewProgress, splitHandleStep } from './SplitHandleInteraction';

export const SPLIT_HANDLE_HIT_WIDTH = 24;
const HALF_SPAN = 14;
const STROKE_VP = 4;
const MAX_BEND_VP = 9;
const RETURN_CURVE = curves.springMotion(0.26, 0.72);

/** Decorative only. The parent owns the fixed drag target and commits actions on release. */
@Component
export struct SplitHandle {
  @Prop overrun: number = 0;

  private progress(): number {
    return splitHandlePreviewProgress(this.overrun);
  }

  private bend(): number {
    return this.progress() === 0 ? 0 : MAX_BEND_VP * this.progress() * Math.sign(this.overrun);
  }

  private segmentHeight(): number {
    return Math.hypot(HALF_SPAN, this.bend()) + STROKE_VP;
  }

  private segmentAngle(): number {
    return Math.atan2(this.bend(), HALF_SPAN) * 180 / Math.PI;
  }

  // Two round-capped strokes meet at the moving tip. Their outer endpoints stay
  // on the divider. Numeric transforms can spring back without morphing a path string.
  @Builder
  segment(isTop: boolean) {
    Stack() {
      Row().width('100%').height('100%').borderRadius(STROKE_VP / 2)
        .backgroundColor($r('app.color.text_tertiary'))
      Row().width('100%').height('100%').borderRadius(STROKE_VP / 2)
        .backgroundColor($r('app.color.accent')).opacity(this.progress())
    }
    .width(STROKE_VP)
    .height(this.segmentHeight())
    .position({ x: (SPLIT_HANDLE_HIT_WIDTH - STROKE_VP) / 2,
      y: isTop ? 0 : 2 * HALF_SPAN + STROKE_VP - this.segmentHeight() })
    .rotate({ angle: isTop ? -this.segmentAngle() : this.segmentAngle(),
      centerX: STROKE_VP / 2, centerY: isTop ? STROKE_VP / 2 : this.segmentHeight() - STROKE_VP / 2 })
    .animation(this.overrun === 0 ? { duration: 240, curve: RETURN_CURVE } : { duration: 0 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.segment(true)
      this.segment(false)
    }
    .width(SPLIT_HANDLE_HIT_WIDTH).height(2 * HALF_SPAN + STROKE_VP)
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no')
  }
}

/**
 * Focusable centre control for a splitter. Place on the parent-owned drag rail. A click opens
 * native resize / pane actions. Parent retains width preferences, drag commits and pane state.
 */
@Component
export struct UiSplitHandle {
  @Require @Prop label: string = '';
  @Require @Prop narrowLabel: ResourceStr = '';
  @Require @Prop widenLabel: ResourceStr = '';
  @Prop paneStartActionLabel?: ResourceStr;
  @Prop paneEndActionLabel?: ResourceStr;
  @Prop leadingWidthVp: number = 0;
  @Prop minWidthVp: number = 0;
  @Prop maxWidthVp: number = 0;
  @Prop overrun: number = 0;
  /** When true the leading pane grows toward the physical left, as in mirrored layouts. */
  @Prop leadingOnRight: boolean = false;
  onWidthChange: (widthVp: number) => void = () => {};
  onPaneStartAction?: () => void;
  onPaneEndAction?: () => void;
  @State private menuOpen: boolean = false;

  private step(action: SplitHandleStep): void {
    const next = splitHandleStep(this.leadingWidthVp, this.minWidthVp, this.maxWidthVp, action);
    if (Number.isFinite(next) && next !== this.leadingWidthVp) this.onWidthChange(next);
  }

  private handleKey(event: KeyEvent): void {
    if (event.type !== KeyType.Down || this.menuOpen) return;
    if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT) this.step(this.leadingOnRight ? 'widen' : 'narrow');
    else if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) this.step(this.leadingOnRight ? 'narrow' : 'widen');
    else if (event.keyCode === KeyCode.KEYCODE_MOVE_HOME) this.step('minimum');
    else if (event.keyCode === KeyCode.KEYCODE_MOVE_END) this.step('maximum');
    else return; // Keep the Button's native keyboard and assistive activation.
    event.stopPropagation();
  }

  @Builder
  private resizeMenu() {
    Menu() {
      MenuItem({ content: this.narrowLabel })
        .enabled(this.leadingWidthVp > this.minWidthVp)
        .onClick(() => this.step('narrow'))
      MenuItem({ content: this.widenLabel })
        .enabled(this.leadingWidthVp < this.maxWidthVp)
        .onClick(() => this.step('widen'))
      if (this.paneStartActionLabel !== undefined && this.onPaneStartAction !== undefined) {
        MenuItem({ content: this.paneStartActionLabel })
          .onClick(() => this.onPaneStartAction?.())
      }
      if (this.paneEndActionLabel !== undefined && this.onPaneEndAction !== undefined) {
        MenuItem({ content: this.paneEndActionLabel })
          .onClick(() => this.onPaneEndAction?.())
      }
    }
  }

  build() {
    Button() {
      SplitHandle({ overrun: this.overrun })
    }
    .type(ButtonType.Circle)
    .buttonStyle(ButtonStyleMode.TEXTUAL)
    .width(UI_TOUCH_TARGET_MIN)
    .height(UI_TOUCH_TARGET_MIN)
    .padding(0)
    .accessibilityText(this.label)
    .bindTips(this.label)
    .onKeyEvent((event: KeyEvent): void => this.handleKey(event))
    .onClick(() => { this.menuOpen = true; })
    .bindMenu(this.menuOpen, this.resizeMenu(), uiMenuOptions(() => { this.menuOpen = false; }))
  }
}
