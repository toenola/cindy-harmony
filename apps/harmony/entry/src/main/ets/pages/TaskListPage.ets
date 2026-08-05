/**
 * 任务列表页：某设备的会话（任务）列表。
 * 进入时订阅 `sessions` topic 并拉一次列表；离开时退订。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../core/AppServices';
import { SESSIONS_TOPIC } from '../core/device-link/DlProtocol';
import { RemoteSession, readStr } from '../core/tasks/TaskModels';

@Entry
@Component
struct TaskListPage {
  @State sessions: RemoteSession[] = [];
  @State deviceName: string = '';
  private deviceId: string = '';
  private unsubs: Array<() => void> = [];

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.deviceId = readStr(params, 'deviceId');
    this.deviceName = AppServices.instance.tasks.getDeviceName(this.deviceId);

    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      this.sessions = AppServices.instance.tasks.getSessions(this.deviceId);
    }));
    this.sessions = AppServices.instance.tasks.getSessions(this.deviceId);

    // 订阅会话列表变更 + 拉一次
    AppServices.instance.client.subscribe(this.deviceId, [SESSIONS_TOPIC]).then(() => {
      AppServices.instance.tasks.loadSessions(this.deviceId);
    }).catch(() => {
      // 订阅失败：仍尝试直接拉列表
      AppServices.instance.tasks.loadSessions(this.deviceId);
    });
  }

  aboutToDisappear(): void {
    for (const u of this.unsubs) {
      u();
    }
    this.unsubs = [];
    AppServices.instance.client.unsubscribe(this.deviceId, [SESSIONS_TOPIC]);
  }

  private openSession(session: RemoteSession): void {
    router.pushUrl({
      url: 'pages/TaskPage',
      params: { deviceId: this.deviceId, sessionId: session.id },
    });
  }

  build() {
    Column() {
      Row() {
        Button('‹')
          .fontSize(18)
          .onClick(() => router.back())
        Text(this.deviceName)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 8 })
          .layoutWeight(1)
      }
      .width('100%')
      .padding(12)

      if (this.sessions.length === 0) {
        Text('暂无任务')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 80 })
      } else {
        List() {
          ForEach(this.sessions, (s: RemoteSession) => {
            ListItem() {
              this.sessionRow(s)
            }
          }, (s: RemoteSession) => s.id)
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
  sessionRow(s: RemoteSession) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(s.title.length > 0 ? s.title : '（未命名任务）')
          .fontSize(16)
          .layoutWeight(1)
        if (s.status === 'archived') {
          Text('已归档')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .width('100%')

      if (s.preview.length > 0) {
        Text(s.preview)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Row({ space: 8 }) {
        Text(this.agentLabel(s.agentKind))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
        Text(this.timeLabel(s.updatedAt))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .onClick(() => this.openSession(s))
  }

  private agentLabel(kind: string): string {
    if (kind === 'cc') return 'Claude Code';
    if (kind === 'codex') return 'Codex';
    if (kind === 'pi') return 'Pi';
    return kind;
  }

  private timeLabel(iso: string): string {
    if (iso.length === 0) return '';
    // ISO 取日期部分即可，完整格式化留到切片 2。
    return iso.length >= 10 ? iso.slice(0, 10) : iso;
  }
}
