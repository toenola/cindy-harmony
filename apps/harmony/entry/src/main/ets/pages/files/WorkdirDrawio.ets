import { webview } from '@kit.ArkWeb';

const DRAWIO_PAGE: string = 'resource://rawfile/drawio/viewer.html';

@Component
export struct WorkdirDrawio {
  @Prop @Watch('render') source: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private ready: boolean = false;

  render(): void {
    if (!this.ready) return;
    const source = JSON.stringify(this.source);
    try {
      this.controller.runJavaScript(
        `window.cindyDrawioRender && window.cindyDrawioRender(${source}, matchMedia('(prefers-color-scheme: dark)').matches)`);
    } catch (_error) {}
  }

  build() {
    Web({ src: $rawfile('drawio/viewer.html'), controller: this.controller })
      .javaScriptAccess(true)
      .fileAccess(false)
      .blockNetwork(true)
      .domStorageAccess(false)
      .onlineImageAccess(false)
      .multiWindowAccess(false)
      .geolocationAccess(false)
      .zoomAccess(true)
      .onLoadIntercept((event: OnLoadInterceptEvent): boolean =>
        this.ready || event.data.getRequestUrl() !== DRAWIO_PAGE)
      .onPageEnd((): void => {
        this.ready = true;
        this.render();
      })
      .width('100%').height('100%')
  }
}
