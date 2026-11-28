import { hilog } from '@kit.PerformanceAnalysisKit';
import { drawing } from '@kit.ArkGraphics2D';

@Component
export struct PluginEngineMark {
  @Prop iconDataUrl: string = '';
  @Prop markSize: number = 24;
  @Prop monochrome: boolean = false;
  @Prop running: boolean = false;
  @Prop remoteExecution: boolean = false;
  @State private failedSource: string = '';

  private silhouette(): drawing.ColorFilter {
    const color = this.getUIContext().getHostContext()?.resourceManager.getColorSync(
      $r('app.color.text_tertiary').id) ?? 0;
    const alpha = (color >>> 24) & 255;
    return drawing.ColorFilter.createBlendModeColorFilter({
      alpha: alpha, red: (color >>> 16) & 255, green: (color >>> 8) & 255, blue: color & 255,
    }, drawing.BlendMode.SRC_IN);
  }

  private imageDecodeFailed(): void {
    this.failedSource = this.iconDataUrl;
    const formats: string[] = ['png', 'jpeg', 'webp', 'gif', 'svg+xml'];
    const format = formats.find((item: string): boolean => this.iconDataUrl.startsWith('data:image/' + item + ';'))
      ?? 'other';
    hilog.debug(0, 'CindyPluginMark', 'image_decode_failed format=%{public}s', format);
  }

  private remoteSignalPath(): string {
    const unit = this.getUIContext().vp2px(1);
    return `M${unit} ${unit} A${4 * unit} ${4 * unit} 0 0 1 ${5 * unit} ${5 * unit}`;
  }

  @Builder
  artwork() {
    if (this.iconDataUrl && this.failedSource !== this.iconDataUrl) {
      if (this.monochrome && !this.running) {
        Image(this.iconDataUrl).width(this.markSize).height(this.markSize).objectFit(ImageFit.Contain)
          .colorFilter(this.silhouette())
          .onError((): void => this.imageDecodeFailed())
      } else {
        Image(this.iconDataUrl).width(this.markSize).height(this.markSize).objectFit(ImageFit.Contain)
          .onError((): void => this.imageDecodeFailed())
      }
    } else {
      Image($r('app.media.plugin_engine_puzzle')).width(this.markSize).height(this.markSize)
        .objectFit(ImageFit.Contain).fillColor(this.running ? $r('app.color.chat_status_accent')
          : this.monochrome ? $r('app.color.text_tertiary') : $r('app.color.text_secondary'))
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      this.artwork()
      if (this.remoteExecution) {
        Stack({ alignContent: Alignment.TopStart }) {
          Path().width(6).height(6).commands(this.remoteSignalPath()).fill(Color.Transparent)
            .stroke(this.running ? $r('app.color.chat_status_accent') : $r('app.color.text_tertiary')).strokeWidth(1.2)
          Circle().width(1.8).height(1.8).position({ x: 0.8, y: 3.1 })
            .fill(this.running ? $r('app.color.chat_status_accent') : $r('app.color.text_tertiary'))
        }.width(6).height(6).hitTestBehavior(HitTestMode.None)
      }
    }.width(this.markSize).height(this.markSize)
  }
}
