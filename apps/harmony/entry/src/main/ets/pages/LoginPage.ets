/**
 * 登录页：手机验证码登录。
 * 流程：输手机号 → 获取验证码 → 输验证码 → 登录 → 启动 Device Link → 首页。
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../core/AppServices';

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
  private timer: number = -1;

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
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
      router.replaceUrl({ url: 'pages/HomePage' });
    }).catch((e: Error) => {
      this.submitting = false;
      this.error = `登录失败：${e.message}`;
    });
  }

  build() {
    Column({ space: 16 }) {
      Image($r('app.media.login_wordmark'))
        .width(160)
        .height(55)
        .objectFit(ImageFit.Contain)
        .margin({ top: 120 })
      Image($r('app.media.login_slogan'))
        .width(150)
        .height(43)
        .objectFit(ImageFit.Contain)

      TextInput({ placeholder: '手机号', text: this.phone })
        .type(InputType.PhoneNumber)
        .onChange((v: string) => {
          this.phone = v;
        })
        .width('85%')

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
      .width('85%')

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(12)
          .fontColor($r('app.color.danger'))
      }

      Button(this.submitting ? '登录中…' : '登录')
        .enabled(!this.submitting && this.phone.length >= 6 && this.code.length >= 4)
        .width('85%')
        .onClick(() => this.login())
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
