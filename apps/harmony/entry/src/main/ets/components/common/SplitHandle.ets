import { curves } from '@kit.ArkUI';

export const SPLIT_HANDLE_HIT_WIDTH = 24;
const PREVIEW_VP = 16;
const TRIGGER_VP = 44;
const HALF_SPAN = 14;
const STROKE_VP = 4;
const MAX_BEND_VP = 9;
const RETURN_CURVE = curves.springMotion(0.26, 0.72);

/** Decorative only. The parent owns the fixed drag target and commits actions on release. */
@Component
export struct SplitHandle {
  @Prop overrun: number = 0;

  private progress(): number {
    return Math.max(0, Math.min(1, (Math.abs(this.overrun) - PREVIEW_VP) / (TRIGGER_VP - PREVIEW_VP)));
  }

  private bend(): number {
    return MAX_BEND_VP * this.progress() * Math.sign(this.overrun);
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
