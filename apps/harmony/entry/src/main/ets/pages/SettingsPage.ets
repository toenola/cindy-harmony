/**
 * 设置页：账号 / 设备 / 登出 / 关于。
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppConfig } from '../AppConfig';
import { AppServices } from '../core/AppServices';

@Entry
@Component
struct SettingsPage {
  @State deviceId: string = '';

  aboutToAppear(): void {
    void AppServices.instance.auth.ensureDeviceId().then((id: string) => {
      this.deviceId = id;
    });
  }

  private logout(): void {
    AppServices.instance.client.stop();
    AppServices.instance.auth.logout().then(() => {
      promptAction.showToast({ message: '已退出登录' });
      router.replaceUrl({ url: 'pages/LoginPage' });
    });
  }

  build() {
    Column() {
      Row() {
        Button('‹')
          .fontSize(18)
          .onClick(() => router.back())
        Text('设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 8 })
          .layoutWeight(1)
      }
      .width('100%')
      .padding(12)

      Column({ space: 1 }) {
        Row() {
          Text('设备 ID')
            .fontSize(14)
          Text(this.deviceId.length > 0 ? this.deviceId.slice(0, 8) : '…')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .padding(16)

        Row() {
          Text('版本')
            .fontSize(14)
          Text(AppConfig.appVersion)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .padding(16)

        Row() {
          Text('远程控制桌面端 Cindy，本端不运行 Agent。')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .padding(16)
      }
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(10)
      .margin({ left: 16, right: 16, top: 8 })

      Button('退出登录')
        .fontSize(15)
        .width('100%')
        .margin({ left: 16, right: 16, top: 24 })
        .backgroundColor($r('app.color.danger'))
        .onClick(() => this.logout())

      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
