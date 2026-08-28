/**
 * 登录页：手机验证码登录。
 * 流程：输手机号 → 获取验证码 → 输验证码 → 登录 → 启动 Device Link → 首页。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../core/AppServices';
import { AccountDeletionStatus, AuthApiError } from '../core/auth/AuthApi';
import { UI_RADIUS_CONTAINER, uiFontSize, uiLineHeight } from '../components/UiKit';

@Entry
@Component
struct LoginPage {
  @State phone: string = '';
  @State code: string = '';
  @State codeSent: boolean = false;
  @State sending: boolean = false;
  @State submitting: boolean = false;
  @State error: string = '';
  @State countdown: number = 0;
  @State accountDeletionStatus: AccountDeletionStatus | null = null;
  private timer: number = -1;
  private deletionPollTimer: number = -1;
  private deletionPollInFlight: boolean = false;

  aboutToAppear(): void {
    void this.refreshAccountDeletionStatus();
    this.deletionPollTimer = setInterval(() => void this.refreshAccountDeletionStatus(), 30000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.deletionPollTimer >= 0) {
      clearInterval(this.deletionPollTimer);
      this.deletionPollTimer = -1;
    }
  }

  private async refreshAccountDeletionStatus(): Promise<void> {
    const auth = AppServices.instance.auth;
    if (auth.isLoggedIn || auth.deletionReceipt.length === 0) {
      this.accountDeletionStatus = null;
      if (auth.deletionReceipt.length === 0 && this.deletionPollTimer >= 0) {
        clearInterval(this.deletionPollTimer);
        this.deletionPollTimer = -1;
      }
      return;
    }
    if (this.deletionPollInFlight) return;
    this.deletionPollInFlight = true;
    try {
      const status = await auth.getAccountDeletionStatus();
      if (status === null) return;
      if (status.status === 'cancelled') {
        await auth.clearAccountDeletionReceipt();
        this.accountDeletionStatus = null;
        return;
      }
      this.accountDeletionStatus = status;
      if (status.status === 'completed' && this.deletionPollTimer >= 0) {
        clearInterval(this.deletionPollTimer);
        this.deletionPollTimer = -1;
      }
    } catch (e) {
      if (e instanceof AuthApiError && e.code === 'ACCOUNT_DELETION_RECEIPT_INVALID') {
        await auth.clearAccountDeletionReceipt();
        this.accountDeletionStatus = null;
      }
    } finally {
      this.deletionPollInFlight = false;
    }
  }

  private accountDeletionStatusTitle(): string {
    const status = this.accountDeletionStatus?.status;
    if (status === 'processing') return '账号注销处理中';
    if (status === 'completed') return '账号已注销';
    return '账号注销待处理';
  }

  private accountDeletionStatusDetail(): string {
    const status = this.accountDeletionStatus;
    if (status === null) return '';
    if (status.status === 'processing') return '账号正在处理注销请求，请稍候。';
    if (status.status === 'completed') return '账号注销已完成。';
    const date = status.deleteAfter.length > 0 ? `（预计 ${status.deleteAfter.slice(0, 10)}）` : '';
    return `账号将在等待期结束后永久删除；等待期间重新登录可撤销${date}。`;
  }

  private dismissAccountDeletionStatus(): void {
    void AppServices.instance.auth.clearAccountDeletionReceipt().then(() => {
      this.accountDeletionStatus = null;
    });
  }

  private sendCode(): void {
    if (this.phone.length < 6 || this.sending) {
      return;
    }
    this.sending = true;
    this.error = '';
    AppServices.instance.auth.requestCode(this.phone).then(() => {
      this.sending = false;
      this.codeSent = true;
      this.countdown = 60;
      this.timer = setInterval(() => {
        this.countdown -= 1;
        if (this.countdown <= 0) {
          clearInterval(this.timer);
          this.timer = -1;
        }
      }, 1000);
    }).catch((e: Error) => {
      this.sending = false;
      this.error = `发送失败：${e.message}`;
    });
  }

  private login(): void {
    if (this.phone.length < 6 || this.code.length < 4 || this.submitting) {
      return;
    }
    this.submitting = true;
    this.error = '';
    AppServices.instance.auth.loginWithCode(this.phone, this.code).then(() => {
      // 登录成功：连接 relay 并进入首页。
      AppServices.instance.client.start();
      router.replaceUrl({ url: 'pages/TaskListPage' });
    }).catch((e: Error) => {
      this.submitting = false;
      this.error = `登录失败：${e.message}`;
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 与 MobileLoginHandoffStage 同源的登录立绘，作为品牌层置于表单后方。
      Image($r('app.media.mobile_login_hero_3x'))
        .width('100%')
        .height('48%')
        .objectFit(ImageFit.Contain)
        .position({ x: 0, y: 12 })

      Column({ space: 16 }) {
        Image($r('app.media.login_wordmark'))
          .width(160)
          .height(55)
          .objectFit(ImageFit.Contain)
        Image($r('app.media.login_slogan'))
          .width(150)
          .height(43)
          .objectFit(ImageFit.Contain)

        if (this.accountDeletionStatus !== null) {
          Column({ space: 7 }) {
            Text(this.accountDeletionStatusTitle())
              .fontSize(uiFontSize(15))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text(this.accountDeletionStatusDetail())
              .fontSize(uiFontSize(12))
              .lineHeight(uiLineHeight(17))
              .fontColor($r('app.color.text_secondary'))
            if (this.accountDeletionStatus.status === 'completed') {
              Button('关闭')
                .fontSize(uiFontSize(13))
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.bg_chip'))
                .onClick(() => this.dismissAccountDeletionStatus())
            }
          }
          .width('85%')
          .constraintSize({ maxWidth: 540 })
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .border({ width: 1, color: $r('app.color.border') })
          .borderRadius(UI_RADIUS_CONTAINER)
        }

        Column({ space: 16 }) {
          TextInput({ placeholder: '手机号', text: this.phone })
            .type(InputType.PhoneNumber)
            .onChange((v: string) => {
              this.phone = v;
            })
            .width('100%')

          Row({ space: 8 }) {
            TextInput({ placeholder: '验证码', text: this.code })
              .type(InputType.Number)
              .onChange((v: string) => {
                this.code = v;
              })
              .layoutWeight(1)
            Button(this.codeSent && this.countdown > 0 ? `${this.countdown}s` : '获取验证码')
              .enabled(!this.sending && this.countdown <= 0)
              .onClick(() => this.sendCode())
          }
          .width('100%')

          if (this.error.length > 0) {
            Text(this.error)
              .fontSize(12)
              .fontColor($r('app.color.danger'))
              .width('100%')
          }

          Button(this.submitting ? '登录中…' : '登录')
            .enabled(!this.submitting && this.phone.length >= 6 && this.code.length >= 4)
            .width('100%')
            .onClick(() => this.login())
        }
        .width('85%')
        .constraintSize({ maxWidth: 540 })
        .margin({ top: 32 })
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 136, left: 16, right: 16, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
