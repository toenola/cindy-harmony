import { webview } from '@kit.ArkWeb';
import { WorkdirHtmlSnapshot } from '../../core/files/WorkdirHtmlSnapshot';

const HTML_POLICY: string = "default-src 'none'; script-src 'none'; style-src 'self' 'unsafe-inline'; " +
  "img-src 'self' data:; font-src 'self'; connect-src 'none'; object-src 'none'; frame-src 'none'; " +
  "base-uri 'none'; form-action 'none'";

@Component
export struct WorkdirHtmlReader {
  snapshot: WorkdirHtmlSnapshot = new WorkdirHtmlSnapshot();
  private controller: webview.WebviewController = new webview.WebviewController();

  private intercept(raw: string): WebResourceResponse {
    const url = raw.split(/[?#]/, 1)[0];
    const asset = this.snapshot.resources.get(url);
    const response = new WebResourceResponse();
    response.setResponseCode(asset ? 200 : 404);
    response.setReasonMessage(asset ? 'OK' : 'Not Found');
    response.setResponseMimeType(asset?.mime ?? 'text/plain');
    response.setResponseHeader([{ headerKey: 'Content-Security-Policy', headerValue: HTML_POLICY },
      { headerKey: 'X-Content-Type-Options', headerValue: 'nosniff' }]);
    if (asset?.bytes) response.setResponseData(asset.bytes);
    else response.setResponseData(asset?.body ?? '');
    response.setResponseIsReady(true);
    return response;
  }

  build() {
    Web({ src: this.snapshot.entry, controller: this.controller })
      .javaScriptAccess(false)
      .fileAccess(false)
      .blockNetwork(true)
      .domStorageAccess(false)
      .multiWindowAccess(false)
      .geolocationAccess(false)
      .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
        const url = event.data.getRequestUrl().split(/[?#]/, 1)[0];
        return this.snapshot.resources.get(url)?.mime !== 'text/html';
      })
      .onInterceptRequest((event: OnInterceptRequestEvent): WebResourceResponse =>
        this.intercept(event.request.getRequestUrl()))
      .width('100%').height('100%')
  }
}
