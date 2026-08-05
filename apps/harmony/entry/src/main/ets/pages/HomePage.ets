/**
 * 首页：设备列表 + 连接状态。
 * 点在线设备 → 任务列表页。退出登录 → 登录页。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../core/AppServices';
import { PresenceSnapshot } from '../core/device-link/DlProtocol';

@Entry
@Component
struct HomePage {
  @State devices: PresenceSnapshot[] = [];
  @State status: string = 'connecting';
  private unsubs: Array<() => void> = [];

  aboutToAppear(): void {
    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      this.devices = AppServices.instance.tasks.deviceList;
    }));
    this.unsubs.push(AppServices.instance.onStatus((s: string) => {
      this.status = s;
    }));
    this.devices = AppServices.instance.tasks.deviceList;
    this.status = AppServices.instance.client.getStatus();
  }

  aboutToDisappear(): void {
    for (const u of this.unsubs) {
      u();
    }
    this.unsubs = [];
  }

  private openDevice(deviceId: string): void {
    router.pushUrl({
      url: 'pages/TaskListPage',
      params: { deviceId: deviceId },
    });
  }

  private logout(): void {
    AppServices.instance.client.stop();
    AppServices.instance.auth.logout().then(() => {
      router.replaceUrl({ url: 'pages/LoginPage' });
    });
  }

  build() {
    Column() {
      Row() {
        Text('我的设备')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button('⚙')
          .fontSize(14)
          .onClick(() => {
            router.pushUrl({ url: 'pages/SettingsPage' });
          })
        Button('退出')
          .fontSize(12)
          .onClick(() => this.logout())
      }
      .width('100%')
      .padding(16)

      Text(this.statusText())
        .fontSize(12)
        .fontColor(this.status === 'online' ? $r('app.color.success') : $r('app.color.warn'))
        .width('100%')
        .padding({ left: 16, right: 16 })

      if (this.devices.length === 0) {
        Column({ space: 8 }) {
          Text('没有发现设备')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Text('请确认桌面端已登录并在线')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .padding({ top: 80 })
      } else {
        List() {
          ForEach(this.devices, (d: PresenceSnapshot) => {
            ListItem() {
              this.deviceRow(d)
            }
          }, (d: PresenceSnapshot) => d.deviceId)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  deviceRow(d: PresenceSnapshot) {
    Row({ space: 12 }) {
      Text(d.online ? '●' : '○')
        .fontSize(18)
        .fontColor(d.online ? $r('app.color.success') : $r('app.color.text_tertiary'))

      Column({ space: 4 }) {
        Text(d.deviceName)
          .fontSize(16)
        Text(`${d.platform} · ${d.online ? '在线' : '离线'}`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (d.online) {
        Text('›')
          .fontSize(22)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick(() => {
      if (d.online) {
        this.openDevice(d.deviceId);
      }
    })
  }

  private statusText(): string {
    if (this.status === 'online') {
      return '● 已连接';
    }
    if (this.status === 'connecting') {
      return '○ 连接中…';
    }
    return '○ 未连接';
  }
}
