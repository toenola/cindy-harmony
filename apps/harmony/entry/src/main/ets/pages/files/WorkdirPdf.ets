import { PdfView, pdfService, pdfViewManager } from '@kit.PDFKit';
import { HarmonyHttp } from '../../network/HarmonyHttp';

@Component
export struct WorkdirPdf {
  @Prop url: string = '';
  @State private hint: string = '正在读取 PDF…';
  private controller: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  private live: boolean = false;

  aboutToAppear(): void {
    this.live = true;
    void this.load();
  }

  aboutToDisappear(): void {
    this.live = false;
    this.release();
  }

  private release(): void {
    try { this.controller.releaseDocument(); } catch (_error) {}
  }

  private async load(): Promise<void> {
    try {
      const bytes = await new HarmonyHttp().downloadBytes(this.url);
      if (!this.live) return;
      if (bytes.byteLength > 32 * 1024 * 1024) {
        this.hint = 'PDF 超过预览大小，可以导出或分享';
        return;
      }
      const result = await this.controller.loadDocumentFromMemory(bytes);
      if (!this.live) { this.release(); return; }
      this.hint = result === pdfService.ParseResult.PARSE_SUCCESS ? '' : '无法预览此 PDF';
    } catch (_error) {
      if (this.live) this.hint = '无法预览此 PDF';
    }
  }

  build() {
    Stack() {
      PdfView({ controller: this.controller, pageLayout: pdfService.PageLayout.LAYOUT_SINGLE,
        showScroll: true, isContinuous: true, pageFit: pdfService.PageFit.FIT_WIDTH })
        .width('100%').height('100%')
      if (this.hint) {
        Text(this.hint).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_card'))
      }
    }.width('100%').height('100%')
  }
}
