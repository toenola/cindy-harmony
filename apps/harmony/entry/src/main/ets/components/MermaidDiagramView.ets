/**
 * Mermaid 图表（含时序图）渲染（v1.3.5 D1）。
 *
 * 行为对齐 Mobile `mermaidWebView.tsx` / `mermaidWebViewHtml.ts`：随包分发固定版本的 Mermaid
 * （rawfile/mermaid，11.16.0，与 Mobile 同一份运行时），零外链；消息内为锁定缩放的内联预览，
 * 点开后全屏查看可双指缩放。渲染失败停留源码。深浅色切换后按新主题重画。
 * 页面只加载随包的 rawfile，拒绝任何其他地址的导航。
 */

import { webview } from '@kit.ArkWeb';
import { UI_COLOR_MODE_STORAGE_KEY } from './UiKit';
import { harmonyV12String } from '../core/HarmonyStrings';

class MermaidRenderPayload {
  source: string = '';
  dark: boolean = false;
  zoomable: boolean = false;
  deferSource: boolean = false;
  textPrimary: string = '';
  textSecondary: string = '';
  textTertiary: string = '';
  emptyLabel: string = '';
  failedLabel: string = '';
}

function argbToCss(argb: number): string {
  const value = argb >>> 0;
  const a = ((value >>> 24) & 255) / 255;
  return `rgba(${(value >>> 16) & 255},${(value >>> 8) & 255},${value & 255},${a.toFixed(3)})`;
}

/** 按背景亮度判断深浅色，与资源色系统同源，不另读系统设置。 */
function isDarkArgb(argb: number): boolean {
  const value = argb >>> 0;
  const r = (value >>> 16) & 255;
  const g = (value >>> 8) & 255;
  const b = value & 255;
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 < 0.5;
}

const MERMAID_PAGE_PREFIX = 'resource://rawfile/';

@Component
export struct MermaidDiagramView {
  @Prop @Watch('redrawDiagram') source: string = '';
  /** 全屏查看允许双指缩放；内联预览锁定缩放，避免和消息列表滚动手势打架。 */
  @Prop zoomable: boolean = false;
  /** 全屏查看首屏不闪源码，SVG 就绪后直接浮现；源码只作失败降级。 */
  @Prop deferSource: boolean = false;
  @StorageProp(UI_COLOR_MODE_STORAGE_KEY) @Watch('redrawDiagram') colorMode: number = -1;
  private controller: webview.WebviewController = new webview.WebviewController();
  private pageReady: boolean = false;

  redrawDiagram(): void {
    if (this.pageReady) this.render();
  }

  private payload(): MermaidRenderPayload {
    const payload = new MermaidRenderPayload();
    payload.source = this.source;
    payload.zoomable = this.zoomable;
    payload.deferSource = this.deferSource;
    const context = this.getUIContext().getHostContext();
    payload.emptyLabel = harmonyV12String(context, 'v135_mermaid_empty');
    payload.failedLabel = harmonyV12String(context, 'v135_mermaid_failed');
    if (context === undefined) return payload;
    const resources = context.resourceManager.getOverrideResourceManager();
    const read = (name: string): number => {
      try {
        return resources.getColorByNameSync(name);
      } catch (_error) {
        return 0xff000000;
      }
    };
    payload.dark = isDarkArgb(read('bg_card'));
    payload.textPrimary = argbToCss(read('text_primary'));
    payload.textSecondary = argbToCss(read('text_secondary'));
    payload.textTertiary = argbToCss(read('text_tertiary'));
    return payload;
  }

  private render(): void {
    const json = JSON.stringify(this.payload());
    try {
      this.controller.runJavaScript(`window.cindyMermaidRender && window.cindyMermaidRender(${JSON.stringify(json)})`);
    } catch (_error) {
      // 页面已销毁或尚未就绪：下次加载完成时重画。
    }
  }

  build() {
    Web({ src: $rawfile('mermaid/viewer.html'), controller: this.controller })
      .javaScriptAccess(true)
      .fileAccess(false)
      .domStorageAccess(false)
      .onlineImageAccess(false)
      .geolocationAccess(false)
      .zoomAccess(this.zoomable)
      .backgroundColor(Color.Transparent)
      .onLoadIntercept((event: OnLoadInterceptEvent): boolean =>
        !event.data.getRequestUrl().startsWith(MERMAID_PAGE_PREFIX))
      .onPageEnd(() => {
        this.pageReady = true;
        this.render();
      })
      .width('100%')
      .height('100%')
  }
}
