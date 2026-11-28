import { UI_ICON_CLICK_EFFECT, UI_RADIUS_PILL, uiAnimateFastState, uiFontSize } from './UiKit';

const MAX_ZOOM: number = 4;
const DOUBLE_TAP_ZOOM: number = 2.5;
const DISMISS_DISTANCE: number = 120;

@Component
export struct ImageViewer {
  @Prop source: string = '';
  @Prop imageIndex: number = 0;
  @Prop imageCount: number = 0;
  onClose: () => void = (): void => {};
  onStep: (direction: number) => void = (_direction: number): void => {};
  @State zoom: number = 1;
  @State panX: number = 0;
  @State panY: number = 0;
  @State dismissY: number = 0;
  @State chromeVisible: boolean = true;
  private viewportW: number = 0;
  private viewportH: number = 0;
  private naturalW: number = 0;
  private naturalH: number = 0;
  private pinching: boolean = false;
  private ignorePan: boolean = false;
  private startZoom: number = 1;
  private anchorX: number = 0;
  private anchorY: number = 0;
  private panStartX: number = 0;
  private panStartY: number = 0;
  // Lock direction at recognition so a diagonal drag cannot both page and dismiss.
  private dragAxis: string = '';

  private transformedAxis(value: number, horizontal: boolean, rubberBand: boolean): number {
    const viewport = horizontal ? this.viewportW : this.viewportH;
    if (viewport <= 0 || this.naturalW <= 0 || this.naturalH <= 0 || this.zoom <= 1) return 0;
    const fit = Math.min(this.viewportW / this.naturalW, this.viewportH / this.naturalH);
    const content = (horizontal ? this.naturalW : this.naturalH) * fit * this.zoom;
    const limit = Math.max(0, (content - viewport) / 2);
    const clamped = Math.max(-limit, Math.min(limit, value));
    if (!rubberBand || limit <= 0) return clamped;
    // Only a short elastic overshoot is visible while pulling an image edge.
    const excess = value - clamped;
    return clamped + excess / (3 + Math.abs(excess) / 4);
  }

  private reclamp(): void {
    this.panX = this.transformedAxis(this.panX, true, false);
    this.panY = this.transformedAxis(this.panY, false, false);
  }

  private settlePan(): void {
    uiAnimateFastState(this.getUIContext(), (): void => {
      this.dismissY = 0;
      this.reclamp();
    });
  }

  private updateViewport(area: Area): void {
    const w = Number(area.width);
    const h = Number(area.height);
    if (w <= 0 || h <= 0 || w === this.viewportW && h === this.viewportH) return;
    this.viewportW = w;
    this.viewportH = h;
    this.reclamp();
    this.dismissY = 0;
  }

  private startPinch(event: GestureEvent): void {
    this.pinching = true;
    this.ignorePan = true;
    this.dismissY = 0;
    this.startZoom = this.zoom;
    this.anchorX = (event.pinchCenterX - this.viewportW / 2 - this.panX) / this.zoom;
    this.anchorY = (event.pinchCenterY - this.viewportH / 2 - this.panY) / this.zoom;
  }

  private updatePinch(event: GestureEvent): void {
    this.zoom = Math.max(1, Math.min(MAX_ZOOM, this.startZoom * event.scale));
    this.panX = this.transformedAxis(event.pinchCenterX - this.viewportW / 2 - this.anchorX * this.zoom, true, false);
    this.panY = this.transformedAxis(event.pinchCenterY - this.viewportH / 2 - this.anchorY * this.zoom, false, false);
  }

  private endPinch(): void {
    this.pinching = false;
    this.settlePan();
  }

  private startPan(): void {
    this.ignorePan = this.pinching;
    this.dragAxis = '';
    this.panStartX = this.panX;
    this.panStartY = this.panY;
  }

  private updatePan(event: GestureEvent): void {
    if (this.ignorePan || this.pinching) return;
    if (this.zoom > 1) {
      this.panX = this.transformedAxis(this.panStartX + event.offsetX, true, true);
      this.panY = this.transformedAxis(this.panStartY + event.offsetY, false, true);
      return;
    }
    if (this.dragAxis.length === 0) {
      this.dragAxis = Math.abs(event.offsetY) > Math.abs(event.offsetX) ? 'vertical' : 'horizontal';
    }
    this.dismissY = this.dragAxis === 'vertical' ? Math.max(0, event.offsetY) : 0;
  }

  private endPan(event: GestureEvent): void {
    if (this.ignorePan || this.pinching) return;
    if (this.zoom === 1) {
      if (this.dragAxis === 'vertical' && this.dismissY > 0 &&
        (this.dismissY >= DISMISS_DISTANCE || event.velocityY >= 800)) {
        this.onClose();
        return;
      }
      if (this.dragAxis === 'horizontal' &&
        (Math.abs(event.offsetX) >= 60 || Math.abs(event.offsetX) >= 16 && Math.abs(event.velocityX) >= 650)) {
        this.onStep(event.offsetX < 0 ? 1 : -1);
      }
    }
    this.settlePan();
  }

  private doubleTap(event: GestureEvent): void {
    const finger = event.fingerList.find((point: FingerInfo): boolean => point !== undefined);
    if (finger === undefined || this.pinching || this.naturalW <= 0) return;
    const focalX = finger.localX - this.viewportW / 2;
    const focalY = finger.localY - this.viewportH / 2;
    uiAnimateFastState(this.getUIContext(), (): void => {
      this.zoom = this.zoom > 1 ? 1 : DOUBLE_TAP_ZOOM;
      this.panX = this.transformedAxis(focalX * (1 - this.zoom), true, false);
      this.panY = this.transformedAxis(focalY * (1 - this.zoom), false, false);
    });
  }

  @Builder
  imageCanvas() {
    Stack() {
      Image(this.source)
        .width('100%').height('100%')
        .objectFit(ImageFit.Contain)
        .onComplete((event) => {
          if (event === undefined || event.width <= 0 || event.height <= 0) return;
          this.naturalW = event.width;
          this.naturalH = event.height;
          this.reclamp();
        })
        .scale({ x: this.zoom, y: this.zoom })
        .translate({ x: this.panX, y: this.panY + this.dismissY })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%').height('100%')
    .onAreaChange((_previous: Area, area: Area): void => this.updateViewport(area))
    .gesture(GestureGroup(GestureMode.Parallel,
      PinchGesture({ fingers: 2 })
        .onActionStart((event: GestureEvent): void => this.startPinch(event))
        .onActionUpdate((event: GestureEvent): void => this.updatePinch(event))
        .onActionEnd((): void => this.endPinch())
        .onActionCancel((): void => this.endPinch()),
      PanGesture({ fingers: 1, direction: PanDirection.All, distance: 8 })
        .onActionStart((): void => this.startPan())
        .onActionUpdate((event: GestureEvent): void => this.updatePan(event))
        .onActionEnd((event: GestureEvent): void => this.endPan(event))
        .onActionCancel((): void => { if (!this.pinching) this.settlePan(); }),
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 2, distanceThreshold: 12 })
          .onAction((event: GestureEvent): void => this.doubleTap(event)),
        TapGesture({ count: 1, distanceThreshold: 7 })
          .onAction((): void => { if (!this.pinching) this.chromeVisible = !this.chromeVisible; })
      )
    ))
  }

  @Builder
  galleryButton(previous: boolean) {
    Button(previous ? $r('app.string.image_viewer_previous') : $r('app.string.image_viewer_next'))
      .fontSize(uiFontSize(14))
      .fontColor($r('app.color.chat_overlay_text'))
      .backgroundColor($r('app.color.chat_overlay_surface'))
      .height(44)
      .padding({ left: 14, right: 14 })
      .borderRadius(UI_RADIUS_PILL)
      .onClick((): void => this.onStep(previous ? -1 : 1))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column().width('100%').height('100%')
        .backgroundColor($r('app.color.chat_overlay_surface'))
        .opacity(Math.max(0.08, 1 - this.dismissY / (DISMISS_DISTANCE * 2)))
        .hitTestBehavior(HitTestMode.None)
      this.imageCanvas()
      if (this.chromeVisible) {
        Button() {
          Stack() {
            Circle().width(40).height(40).fill($r('app.color.chat_overlay_surface'))
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(uiFontSize(20))
              .fontColor([$r('app.color.chat_overlay_text')])
          }
          .width(44).height(44)
        }
        .type(ButtonType.Circle)
        .width(44).height(44).padding(0)
        .backgroundColor(Color.Transparent)
        .clickEffect(UI_ICON_CLICK_EFFECT)
        .accessibilityText($r('app.string.v131_close'))
        .position({ left: 12, top: 12 })
        .onClick((): void => this.onClose())

        if (this.imageCount > 1) {
          Row({ space: 8 }) {
            this.galleryButton(true)
            Text(`${this.imageIndex + 1} / ${this.imageCount}`)
              .fontSize(uiFontSize(14)).fontFamily('monospace')
              .fontColor($r('app.color.chat_overlay_text'))
              .backgroundColor($r('app.color.chat_overlay_surface'))
              .height(40).padding({ left: 12, right: 12 })
              .borderRadius(UI_RADIUS_PILL)
            this.galleryButton(false)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .hitTestBehavior(HitTestMode.Transparent)
          .position({ left: 0, bottom: 16 })
        }
      }
    }
    .width('100%').height('100%')
    .clip(true)
  }
}
