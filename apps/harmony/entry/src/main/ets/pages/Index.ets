/**
 * 入口页：初始化服务 + 会话恢复 → 路由到登录页或首页。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../core/AppServices';

@Entry
@Component
struct Index {
  @State booting: boolean = true;
  @State bootError: string = '';

  aboutToAppear(): void {
    this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    try {
      await AppServices.instance.init(getContext(this));
      const restored = await AppServices.instance.auth.restoreSession();
      if (restored) {
        // 先画 last-known 列表，再连 relay 用远端权威快照对账。
        AppServices.instance.restoreTaskListSnapshot();
        AppServices.instance.client.start();
        router.replaceUrl({ url: 'pages/TaskListPage' });
      } else {
        router.replaceUrl({ url: 'pages/LoginPage' });
      }
    } catch (e) {
      this.bootError = '启动失败，请重试';
      this.booting = false;
    }
  }

  build() {
    Column({ space: 16 }) {
      Text('Cindy Harmony')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      if (this.booting) {
        LoadingProgress()
          .width(40)
          .height(40)
      }
      if (this.bootError.length > 0) {
        Text(this.bootError)
          .fontSize(14)
          .fontColor($r('app.color.danger'))
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.bg_page'))
  }
}
