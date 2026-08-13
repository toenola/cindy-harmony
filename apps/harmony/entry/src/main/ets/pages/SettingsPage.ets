/**
 * 设置页：账号 / 设备 / 登出 / 关于。
 */

import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppConfig } from '../AppConfig';
import { AppServices } from '../core/AppServices';

@Entry
@Component
struct SettingsPage {
  @State deviceId: string = '';
  @State taskCompletionPushEnabled: boolean = false;
  @State taskCompletionPushBusy: boolean = false;
  @State taskCompletionPushToken: string = '';
  @State taskCompletionPushStatus: string = '';
  private pushUnsubscribe: (() => void) | null = null;
  private deepLinkUnsubscribe: (() => void) | null = null;

  aboutToAppear(): void {
    this.syncTaskCompletionPushState();
    this.pushUnsubscribe = AppServices.instance.taskCompletionPush.onChanged(() => {
      this.syncTaskCompletionPushState();
    });
    this.deepLinkUnsubscribe = AppServices.instance.onDeepLink(() => {
      router.replaceUrl({ url: 'pages/TaskListPage' });
    });
    void AppServices.instance.taskCompletionPush.refreshNotificationStatus();
    void AppServices.instance.auth.ensureDeviceId().then((id: string) => {
      this.deviceId = id;
    });
  }

  aboutToDisappear(): void {
    if (this.pushUnsubscribe !== null) this.pushUnsubscribe();
    if (this.deepLinkUnsubscribe !== null) this.deepLinkUnsubscribe();
    this.pushUnsubscribe = null;
    this.deepLinkUnsubscribe = null;
  }

  private syncTaskCompletionPushState(): void {
    const service = AppServices.instance.taskCompletionPush;
    this.taskCompletionPushEnabled = service.enabled;
    this.taskCompletionPushBusy = service.status === 'loading';
    this.taskCompletionPushToken = service.token;
    if (service.status === 'loading') {
      this.taskCompletionPushStatus = service.enabled ? '正在获取 Push Token…' : '正在开启推送…';
    } else if (service.errorMessage.length > 0) {
      this.taskCompletionPushStatus = service.errorMessage;
    } else if (service.enabled && service.token.length > 0) {
      this.taskCompletionPushStatus = '已开启';
    } else {
      this.taskCompletionPushStatus = '';
    }
  }

  private async setTaskCompletionPushEnabled(enabled: boolean): Promise<void> {
    if (this.taskCompletionPushBusy) return;
    const service = AppServices.instance.taskCompletionPush;
    const success = enabled
      ? await service.enable(getContext(this) as common.UIAbilityContext)
      : await service.disable();
    this.syncTaskCompletionPushState();
    if (!success && service.errorMessage.length > 0) {
      promptAction.showToast({ message: service.errorMessage });
    }
  }

  private async refreshTaskCompletionPushToken(): Promise<void> {
    const success = await AppServices.instance.taskCompletionPush.refreshToken();
    this.syncTaskCompletionPushState();
    promptAction.showToast({
      message: success ? 'Push Token 已更新' : AppServices.instance.taskCompletionPush.errorMessage,
    });
  }

  private copyTaskCompletionPushToken(): void {
    if (this.taskCompletionPushToken.length === 0) return;
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.taskCompletionPushToken);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: 'Push Token 已复制' });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败' });
    });
  }

  private showTaskCompletionPushInfo(): void {
    this.getUIContext().showAlertDialog({
      title: '任务完成推送',
      message: '鸿蒙端的任务完成推送通过桌面端插件实现。请先在 Cindy Desktop 安装并配置“华为任务完成推送”插件。',
      primaryButton: {
        value: '知道了',
        action: () => {
        },
      },
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

      Text('通知')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: 20, right: 20 })
        .margin({ top: 8, bottom: 8 })

      Column() {
        Row() {
          Row({ space: 4 }) {
            Text('任务完成推送')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))

            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.info_circle'))
                .fontSize(17)
                .fontColor([$r('app.color.text_secondary')])
            }
            .width(32)
            .height(32)
            .borderRadius(999)
            .accessibilityText('了解任务完成推送')
            .onClick(() => this.showTaskCompletionPushInfo())
          }
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.taskCompletionPushEnabled })
            .selectedColor($r('app.color.accent'))
            .enabled(!this.taskCompletionPushBusy)
            .accessibilityText('任务完成推送')
            .onChange((enabled: boolean) => {
              void this.setTaskCompletionPushEnabled(enabled);
            })
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 12 })

        if (this.taskCompletionPushEnabled || this.taskCompletionPushStatus.length > 0) {
          Divider()
            .color($r('app.color.border'))
            .margin({ left: 16, right: 16 })

          Column({ space: 10 }) {
            Row() {
              Text('Push Token')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Blank()
              if (this.taskCompletionPushStatus.length > 0) {
                Text(this.taskCompletionPushStatus)
                  .fontSize(12)
                  .fontColor(this.taskCompletionPushStatus === '已开启'
                    ? $r('app.color.success') : $r('app.color.text_secondary'))
              }
            }
            .width('100%')

            if (this.taskCompletionPushToken.length > 0) {
              Text(this.taskCompletionPushToken)
                .fontSize(12)
                .fontFamily('monospace')
                .fontColor($r('app.color.code_text'))
                .width('100%')
                .padding(12)
                .backgroundColor($r('app.color.bg_code'))
                .borderRadius(8)
                .wordBreak(WordBreak.BREAK_ALL)

              Row({ space: 10 }) {
                Button('复制')
                  .fontSize(13)
                  .fontColor($r('app.color.text_primary'))
                  .backgroundColor($r('app.color.bg_chip'))
                  .layoutWeight(1)
                  .onClick(() => this.copyTaskCompletionPushToken())
                Button('重新获取')
                  .fontSize(13)
                  .fontColor($r('app.color.text_primary'))
                  .backgroundColor($r('app.color.bg_chip'))
                  .layoutWeight(1)
                  .enabled(!this.taskCompletionPushBusy)
                  .onClick(() => void this.refreshTaskCompletionPushToken())
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 16 })
        }
      }
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(10)
      .margin({ left: 16, right: 16 })

      Text('关于')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: 20, right: 20 })
        .margin({ top: 20, bottom: 8 })

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
      .margin({ left: 16, right: 16 })

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
