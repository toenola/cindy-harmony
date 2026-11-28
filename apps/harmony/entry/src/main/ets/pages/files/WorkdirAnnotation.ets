import { LengthMetricsUnit } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';

class InkPoint {
  x: number = 0;
  y: number = 0;
}

@Component
export struct WorkdirAnnotation {
  source: image.PixelMap | null = null;
  @Prop pixelWidth: number = 0;
  @Prop pixelHeight: number = 0;
  attach: (bytes: ArrayBuffer) => boolean = (_bytes: ArrayBuffer): boolean => false;
  cancel: () => void = (): void => {};
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private hasInk: boolean = false;
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private strokes: InkPoint[][] = [];
  private stroke: InkPoint[] | null = null;
  private viewportWidth: number = 0;
  private viewportHeight: number = 0;
  private live: boolean = true;

  aboutToDisappear(): void { this.live = false; }

  private fitted(): number[] {
    const scale = Math.min(this.viewportWidth / Math.max(1, this.pixelWidth), this.viewportHeight / Math.max(1, this.pixelHeight));
    const w = this.pixelWidth * scale;
    const h = this.pixelHeight * scale;
    return [(this.viewportWidth - w) / 2, (this.viewportHeight - h) / 2, w, h];
  }

  private draw(context: CanvasRenderer, left: number, top: number, w: number, h: number): void {
    context.strokeStyle = '#ec4747';
    context.lineWidth = Math.max(2, Math.min(w, h) * 0.012);
    context.lineCap = 'round';
    context.lineJoin = 'round';
    for (const stroke of this.strokes) {
      if (stroke.length === 0) continue;
      context.beginPath();
      context.moveTo(left + stroke[0].x * w, top + stroke[0].y * h);
      if (stroke.length === 1) context.lineTo(left + stroke[0].x * w + 0.1, top + stroke[0].y * h);
      for (let i = 1; i < stroke.length; i++) context.lineTo(left + stroke[i].x * w, top + stroke[i].y * h);
      context.stroke();
    }
  }

  private redraw(): void {
    this.canvas.clearRect(0, 0, this.viewportWidth, this.viewportHeight);
    const box = this.fitted();
    this.draw(this.canvas, box[0], box[1], box[2], box[3]);
  }

  private touch(event: TouchEvent): void {
    if (this.busy) return;
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.stroke = null; return; }
    const touch = event.touches[0];
    if (!touch || event.touches.length !== 1) return;
    const box = this.fitted();
    if (box[2] <= 0 || box[3] <= 0) return;
    const point = new InkPoint();
    point.x = (touch.x - box[0]) / box[2];
    point.y = (touch.y - box[1]) / box[3];
    if (point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) return;
    if (event.type === TouchType.Down && this.strokes.length < 128) {
      this.stroke = [];
      this.strokes.push(this.stroke);
    }
    if (!this.stroke || this.stroke.length >= 1024) return;
    this.stroke.push(point);
    this.hasInk = true;
    this.redraw();
  }

  private async finish(): Promise<void> {
    if (!this.source || !this.hasInk || this.busy) return;
    this.busy = true;
    this.error = '';
    const packer = image.createImagePacker();
    let merged: image.PixelMap | null = null;
    try {
      const output = new OffscreenCanvasRenderingContext2D(this.pixelWidth, this.pixelHeight,
        new RenderingContextSettings(true), LengthMetricsUnit.PX);
      output.drawImage(this.source, 0, 0, this.pixelWidth, this.pixelHeight);
      this.draw(output, 0, 0, this.pixelWidth, this.pixelHeight);
      merged = output.getPixelMap(0, 0, this.pixelWidth, this.pixelHeight);
      const bytes = await packer.packing(merged, { format: 'image/jpeg', quality: 92 });
      if (this.live && !this.attach(bytes)) this.error = '当前任务无法接收图片，请检查附件数量后重试';
    } catch (_error) {
      if (this.live) this.error = '无法生成标注图片';
    } finally {
      if (merged) void merged.release();
      void packer.release();
      if (this.live) this.busy = false;
    }
  }

  build() {
    Column() {
      Stack() {
        if (this.source !== null) {
          Image(this.source).objectFit(ImageFit.Contain).width('100%').height('100%')
        }
        Canvas(this.canvas).width('100%').height('100%')
          .onReady((): void => this.redraw())
          .onAreaChange((_old: Area, area: Area): void => {
            this.viewportWidth = Number(area.width);
            this.viewportHeight = Number(area.height);
            this.redraw();
          })
          .onTouch((event: TouchEvent): void => this.touch(event))
      }.width('100%').layoutWeight(1)
      if (this.error) { Text(this.error).fontColor($r('app.color.text_secondary')) }
      Row({ space: 8 }) {
        Button('取消').height(44).onClick((): void => this.cancel())
        Button('撤销').height(44).enabled(!this.busy && this.hasInk).onClick((): void => {
          this.strokes.pop();
          this.hasInk = this.strokes.length > 0;
          this.redraw();
        })
        Button(this.busy ? '正在合成…' : '添加到任务').height(44).enabled(!this.busy && this.hasInk)
          .onClick((): void => { void this.finish(); })
      }.width('100%').justifyContent(FlexAlign.Center)
    }.width('100%').height('100%')
  }
}
