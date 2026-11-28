import { AppServices } from '../core/AppServices';
import {
  formatSessionActivityTokens,
  sessionActivityDuration,
  sessionActivityElapsedMs,
} from '../core/messages/SessionActivityPresentation';
import { UI_RADIUS_PILL, uiFontSize } from './UiKit';

@Component
export struct TurnStatusBar {
  @Prop @Watch('syncActivity') running: boolean = false;
  @Prop @Watch('syncActivity') startedAtMs: number = 0;
  @Prop tokenUsage: number = 0;
  @Prop sideTaskRunning: boolean = false;
  @Prop retryPhase: string = '';
  @Prop retryProgress: string = '';
  @State visible: boolean = false;
  @State elapsedMs: number = 0;
  private fallbackStartMs: number = 0;
  private clock: number = -1;
  private settle: number = -1;
  private offLifecycle?: () => void;

  aboutToAppear(): void {
    this.offLifecycle = AppServices.instance.onModulePush(
      (_device: string, channel: string, _payload: Object | undefined): void => {
        if (channel === 'app-foreground') this.syncActivity();
      });
    this.syncActivity();
  }

  aboutToDisappear(): void {
    this.offLifecycle?.();
    this.offLifecycle = undefined;
    this.stopClock();
    this.cancelSettle();
  }

  private cancelSettle(): void {
    if (this.settle < 0) return;
    clearTimeout(this.settle);
    this.settle = -1;
  }

  private stopClock(): void {
    if (this.clock < 0) return;
    clearInterval(this.clock);
    this.clock = -1;
  }

  private updateElapsed(): void {
    const start = this.startedAtMs > 0 ? this.startedAtMs : this.fallbackStartMs;
    const elapsed = Math.floor(sessionActivityElapsedMs(Date.now(), start) / 1000) * 1000;
    if (elapsed !== this.elapsedMs) this.elapsedMs = elapsed;
  }

  private syncActivity(): void {
    if (!this.running) {
      this.stopClock();
      if (this.visible && this.settle < 0) {
        // Mobile keeps the row alive across the send → streaming handoff.
        this.settle = setTimeout((): void => {
          this.settle = -1;
          this.visible = false;
          this.fallbackStartMs = 0;
        }, 600);
      }
      return;
    }
    this.cancelSettle();
    if (this.fallbackStartMs === 0) this.fallbackStartMs = Date.now();
    this.visible = true;
    if (!AppServices.instance.appInForeground) {
      this.stopClock();
      return;
    }
    this.updateElapsed();
    if (this.clock < 0) this.clock = setInterval((): void => this.updateElapsed(), 1000);
  }

  private phaseLabel(): Resource {
    if (this.retryPhase === 'reconnect') return $r('app.string.turn_status_reconnect');
    if (this.retryPhase === 'overload') return $r('app.string.turn_status_overload');
    if (this.retryPhase === 'rate_limit') return $r('app.string.turn_status_rate_limit');
    return $r('app.string.turn_status_thinking');
  }

  private elapsedLabel(): Resource {
    const time = sessionActivityDuration(this.elapsedMs);
    if (time.days > 0) return $r('app.string.turn_status_days', time.days, time.hours, time.minutes);
    if (time.hours > 0) return $r('app.string.turn_status_hours', time.hours, time.minutes);
    if (time.minutes > 0) return $r('app.string.turn_status_minutes', time.minutes, time.seconds);
    return $r('app.string.turn_status_seconds', time.seconds);
  }

  build() {
    Row({ space: 6 }) {
      if (this.visible) {
        Row({ space: 4 }) {
          Text('✧')
            .fontSize(uiFontSize(14))
            .fontColor($r('app.color.chat_status_accent'))
            .accessibilityLevel('no')
          Text(this.phaseLabel())
            .fontSize(uiFontSize(12))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.chat_status_accent'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          if (this.retryProgress.length > 0) {
            Text(this.retryProgress)
              .fontSize(uiFontSize(11)).fontFamily('monospace')
              .fontColor($r('app.color.chat_status_accent'))
          }
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor($r('app.color.bg_chip'))
        .borderRadius(UI_RADIUS_PILL)
        .flexShrink(1)

        Row().layoutWeight(1)

        Row({ space: 4 }) {
          Text(this.elapsedLabel())
            .fontSize(uiFontSize(11)).fontFamily('monospace')
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
          if (!this.sideTaskRunning && this.retryPhase.length === 0
            && formatSessionActivityTokens(this.tokenUsage).length > 0) {
            Text('· ↓')
              .fontSize(uiFontSize(11))
              .fontColor($r('app.color.text_secondary'))
              .accessibilityLevel('no')
            Text($r('app.string.turn_status_tokens', formatSessionActivityTokens(this.tokenUsage)))
              .fontSize(uiFontSize(11)).fontFamily('monospace')
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
          }
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor($r('app.color.bg_chip'))
        .borderRadius(UI_RADIUS_PILL)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 44 })
    .padding({ left: 16, right: 16 })
    .hitTestBehavior(HitTestMode.None)
  }
}
