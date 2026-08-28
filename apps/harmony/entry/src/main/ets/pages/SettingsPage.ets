/**
 * 设置页：按 Mobile 的信息架构呈现账号、版本、通知、设备、调试与法律信息。
 *
 * Harmony 独有的 Huawei Push Token 逻辑仍由 TaskCompletionPushService 负责，
 * 本页只调整它的分组、行高和颜色语义；推送开关、token 获取/刷新/删除流程不改。
 */

import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppConfig } from '../AppConfig';
import { AppServices } from '../core/AppServices';
import {
  AccountDeletionChallenge, AccountDeletionAvailability, AuthApiError,
} from '../core/auth/AuthApi';
import { PresenceSnapshot } from '../core/device-link/DlProtocol';
import {
  VoiceDictionaryEntryView, buildVoiceDictionaryEntryViews,
} from '../core/messages/VoiceDictionaryStore';
import {
  UI_LIST_CLICK_EFFECT,
  UI_RADIUS_CONTAINER, UI_RADIUS_CONTROL, UI_RADIUS_PILL,
  uiFontSize, uiLineHeight,
} from '../components/UiKit';

type SettingsScreen = 'main' | 'voice' | 'rename' | 'deletion';

@Entry
@Component
struct SettingsPage {
  @State screen: SettingsScreen = 'main';
  @State deviceId: string = '';
  @State relayStatus: string = 'stopped';
  @State selfDeviceName: string = '';
  @State accountDisplayName: string = '';
  @State accountEmail: string = '';
  @State debugExpanded: boolean = false;
  @State settingsRevision: number = 0;

  @State taskCompletionPushEnabled: boolean = false;
  @State taskCompletionPushBusy: boolean = false;
  @State taskCompletionPushToken: string = '';
  @State taskCompletionPushStatus: string = '';

  @State dictionaryRefreshing: boolean = false;
  @State dictionaryError: string = '';

  @State renameDraft: string = '';
  @State renameMessage: string = '';
  @State renameSaving: boolean = false;

  @State languageSheetOpen: boolean = false;
  @State loggingOut: boolean = false;

  @State deletionAvailable: boolean = false;
  @State deletionAvailabilityLoading: boolean = false;
  @State deletionAvailability: AccountDeletionAvailability | null = null;
  @State deletionChallenge: AccountDeletionChallenge | null = null;
  @State deletionCode: string = '';
  @State deletionAcknowledged: boolean = false;
  @State deletionBusy: boolean = false;
  @State deletionError: string = '';

  private pushUnsubscribe: (() => void) | null = null;
  private deepLinkUnsubscribe: (() => void) | null = null;
  private statusUnsubscribe: (() => void) | null = null;
  private taskUnsubscribe: (() => void) | null = null;
  private voiceUnsubscribe: (() => void) | null = null;
  private authUnsubscribe: (() => void) | null = null;
  private renameTimer: number = -1;
  private renameWriteInFlight: boolean = false;
  private queuedRename: string | null = null;

  aboutToAppear(): void {
    this.syncPageState();
    const services = AppServices.instance;
    this.pushUnsubscribe = services.taskCompletionPush.onChanged(() => {
      this.syncTaskCompletionPushState();
    });
    this.statusUnsubscribe = services.onStatus((status: string) => {
      this.relayStatus = status;
      this.settingsRevision += 1;
    });
    this.taskUnsubscribe = services.tasks.onChanged(() => {
      this.settingsRevision += 1;
      if (this.screen === 'voice') void this.hydrateVoiceDictionary();
    });
    this.voiceUnsubscribe = services.voiceDictionary.onChanged(() => {
      this.settingsRevision += 1;
    });
    this.authUnsubscribe = services.auth.onChanged(() => {
      this.accountDisplayName = services.auth.displayName;
      this.accountEmail = services.auth.email;
      this.settingsRevision += 1;
    });
    this.deepLinkUnsubscribe = services.onDeepLink(() => {
      router.replaceUrl({ url: 'pages/TaskListPage' });
    });
    // 保留现有 Huawei Push Kit 状态同步与通知权限刷新逻辑。
    void services.taskCompletionPush.refreshNotificationStatus();
    void services.auth.ensureDeviceId().then((id: string) => {
      this.deviceId = id;
      this.settingsRevision += 1;
    });
    void services.loadDevices();
    void this.hydrateVoiceDictionary();
    void this.refreshDeletionAvailability();
  }

  aboutToDisappear(): void {
    if (this.renameTimer >= 0) {
      clearTimeout(this.renameTimer);
      this.renameTimer = -1;
    }
    if (this.pushUnsubscribe !== null) this.pushUnsubscribe();
    if (this.deepLinkUnsubscribe !== null) this.deepLinkUnsubscribe();
    if (this.statusUnsubscribe !== null) this.statusUnsubscribe();
    if (this.taskUnsubscribe !== null) this.taskUnsubscribe();
    if (this.voiceUnsubscribe !== null) this.voiceUnsubscribe();
    if (this.authUnsubscribe !== null) this.authUnsubscribe();
    this.pushUnsubscribe = null;
    this.deepLinkUnsubscribe = null;
    this.statusUnsubscribe = null;
    this.taskUnsubscribe = null;
    this.voiceUnsubscribe = null;
    this.authUnsubscribe = null;
  }

  private syncPageState(): void {
    const services = AppServices.instance;
    this.syncTaskCompletionPushState();
    this.relayStatus = services.client.getStatus();
    this.selfDeviceName = services.getSelfDeviceName();
    this.accountDisplayName = services.auth.displayName;
    this.accountEmail = services.auth.email;
  }

  // ─── 现有 Harmony 推送逻辑：保持服务调用与状态语义不变 ──────────────────────

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

  // ─── Mobile 对齐能力 ───────────────────────────────────────────────────────

  private desktopDevices(): PresenceSnapshot[] {
    const out: PresenceSnapshot[] = [];
    const devices = AppServices.instance.tasks.deviceList;
    for (let i = 0; i < devices.length; i++) {
      const device = devices[i];
      if (device.deviceId === this.deviceId) continue;
      if (device.platform !== 'darwin' && device.platform !== 'win32' && device.platform !== 'linux') continue;
      out.push(device);
    }
    return out;
  }

  private voiceEntries(): VoiceDictionaryEntryView[] {
    const hosts = this.desktopDevices();
    const ids: string[] = [];
    for (let i = 0; i < hosts.length; i++) ids.push(hosts[i].deviceId);
    return buildVoiceDictionaryEntryViews(AppServices.instance.voiceDictionary.all(ids));
  }

  private async hydrateVoiceDictionary(): Promise<void> {
    const hosts = this.desktopDevices();
    for (let i = 0; i < hosts.length; i++) {
      await AppServices.instance.voiceDictionary.hydrate(hosts[i].deviceId);
    }
    this.settingsRevision += 1;
  }

  private async refreshVoiceDictionary(): Promise<void> {
    if (this.dictionaryRefreshing) return;
    this.dictionaryRefreshing = true;
    this.dictionaryError = '';
    const hosts = this.desktopDevices();
    if (hosts.length === 0) {
      await this.hydrateVoiceDictionary();
      this.dictionaryRefreshing = false;
      return;
    }
    let failed = false;
    for (let i = 0; i < hosts.length; i++) {
      await AppServices.instance.voiceDictionary.hydrate(hosts[i].deviceId);
      if (!hosts[i].online) continue;
      try {
        await AppServices.instance.fetchVoiceDictionary(hosts[i].deviceId);
      } catch (_) {
        failed = true;
      }
    }
    if (failed) this.dictionaryError = '部分电脑暂时无法同步，已保留上次同步内容。';
    this.dictionaryRefreshing = false;
    this.settingsRevision += 1;
  }

  private voiceStatus(): string {
    const hosts = this.desktopDevices();
    if (hosts.length === 0) {
      return '还没有可同步的电脑。在电脑上登录同一账号后，词典会自动出现在这里。';
    }
    let online = false;
    for (let i = 0; i < hosts.length; i++) {
      if (hosts[i].online) {
        online = true;
        break;
      }
    }
    return online
      ? '手机只能查看，添加和删除请回电脑操作。'
      : '电脑当前都不在线，显示的是上次同步到手机的内容。';
  }

  private openVoiceDictionary(): void {
    this.screen = 'voice';
    void this.refreshVoiceDictionary();
  }

  private openRename(): void {
    const current = this.deviceName();
    this.renameDraft = current;
    this.renameMessage = '';
    this.renameSaving = false;
    this.screen = 'rename';
  }

  private deviceName(): string {
    return this.selfDeviceName.trim().length > 0 ? this.selfDeviceName : 'Cindy Harmony';
  }

  private updateRenameDraft(value: string): void {
    this.renameDraft = value.slice(0, 64);
    this.renameMessage = '';
    if (this.renameTimer >= 0) clearTimeout(this.renameTimer);
    const name = this.renameDraft.trim();
    if (name.length === 0) return;
    this.renameTimer = setTimeout(() => {
      this.renameTimer = -1;
      void this.saveRename(name, false);
    }, 650);
  }

  private async saveRename(name: string, acceptClosedDraft: boolean): Promise<void> {
    const trimmed = name.trim();
    if (trimmed.length === 0) {
      this.renameMessage = '设备名称不能为空。';
      return;
    }
    if (trimmed === this.deviceName().trim()) {
      this.renameMessage = '';
      return;
    }
    if (this.renameWriteInFlight) {
      this.queuedRename = trimmed;
      this.renameMessage = '保存中…';
      return;
    }
    this.renameWriteInFlight = true;
    this.renameSaving = true;
    this.renameMessage = '保存中…';
    try {
      const saved = await AppServices.instance.renameSelfDevice(trimmed);
      if (acceptClosedDraft || this.renameDraft.trim() === trimmed) {
        this.selfDeviceName = saved;
        this.renameDraft = saved.length > 0 ? saved : 'Cindy Harmony';
        this.renameMessage = '已保存。';
      }
    } catch (e) {
      this.renameMessage = this.errorText(e, '设备名称保存失败，请稍后重试。');
    } finally {
      this.renameWriteInFlight = false;
      this.renameSaving = false;
      const queued = this.queuedRename;
      this.queuedRename = null;
      if (queued !== null && queued !== this.deviceName().trim()) {
        void this.saveRename(queued, false);
      }
    }
  }

  private resetRename(): void {
    if (this.renameSaving) return;
    this.renameDraft = '';
    this.renameMessage = '正在恢复默认名称…';
    if (this.renameTimer >= 0) clearTimeout(this.renameTimer);
    this.renameWriteInFlight = true;
    this.renameSaving = true;
    AppServices.instance.renameSelfDevice('').then((saved: string) => {
      this.selfDeviceName = saved;
      this.renameDraft = saved.length > 0 ? saved : 'Cindy Harmony';
      this.renameMessage = '已恢复默认名称。';
    }).catch((e: Object) => {
      this.renameMessage = this.errorText(e, '恢复默认名称失败，请稍后重试。');
    }).finally(() => {
      this.renameWriteInFlight = false;
      this.renameSaving = false;
    });
  }

  private closeRename(): void {
    if (this.renameTimer >= 0) {
      clearTimeout(this.renameTimer);
      this.renameTimer = -1;
    }
    const draft = this.renameDraft.trim();
    if (draft.length > 0 && draft !== this.deviceName().trim()) {
      void this.saveRename(draft, true);
    }
    this.screen = 'main';
  }

  private openLanguageSheet(): void {
    this.languageSheetOpen = true;
  }

  private selectLanguage(value: string): void {
    this.languageSheetOpen = false;
    if (value === 'system') {
      promptAction.showToast({ message: '当前 Harmony 版本使用简体中文界面' });
    }
  }

  private copyText(value: string, successMessage: string = '已复制'): void {
    if (value.length === 0) return;
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: successMessage });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败' });
    });
  }

  private openExternal(url: string): void {
    const context = getContext(this) as common.UIAbilityContext;
    context.startAbility({ action: 'ohos.want.action.viewData', uri: url }).catch(() => {
      promptAction.showToast({ message: '无法打开链接' });
    });
  }

  private privacyPolicyUrl(): string {
    return AppConfig.region === 'global'
      ? 'https://protocol.xd.com/cindy/privacy.html'
      : 'https://protocol.xd.cn/cindy/privacy-1.0.html';
  }

  private userAgreementUrl(): string {
    return AppConfig.region === 'global'
      ? 'https://protocol.xd.com/cindy/agreement-1.0.html'
      : 'https://protocol.xd.cn/cindy/agreement.html';
  }

  private relayLabel(): string {
    if (this.relayStatus === 'online') return 'Relay 已连接';
    if (this.relayStatus === 'connecting') return '正在连接 Relay';
    return 'Relay 未连接';
  }

  private relayDetail(): string {
    if (this.relayStatus === 'online') return '可以同步远程任务。';
    if (this.relayStatus === 'connecting') return '网络恢复后会自动重新订阅远程任务。';
    return '回到前台或重新登录后会恢复连接。';
  }

  private accountNameLabel(): string {
    if (this.accountDisplayName.trim().length > 0) return this.accountDisplayName.trim();
    if (this.accountEmail.trim().length > 0) return this.accountEmail.trim();
    return '已登录';
  }

  private accountInitial(): string {
    return this.accountNameLabel().slice(0, 1).toUpperCase();
  }

  private async refreshDeletionAvailability(): Promise<void> {
    if (!AppServices.instance.auth.isLoggedIn) return;
    this.deletionAvailabilityLoading = true;
    try {
      const availability = await AppServices.instance.auth.getAccountDeletionAvailability();
      this.deletionAvailability = availability;
      this.deletionAvailable = availability.available;
    } catch (_) {
      this.deletionAvailability = null;
      this.deletionAvailable = false;
    } finally {
      this.deletionAvailabilityLoading = false;
    }
  }

  private openDeletion(): void {
    this.deletionError = '';
    this.deletionChallenge = null;
    this.deletionCode = '';
    this.deletionAcknowledged = false;
    this.screen = 'deletion';
    if (this.deletionAvailability === null) void this.refreshDeletionAvailability();
  }

  private async requestDeletionChallenge(): Promise<void> {
    if (this.deletionBusy) return;
    this.deletionBusy = true;
    this.deletionError = '';
    try {
      this.deletionChallenge = await AppServices.instance.auth.requestAccountDeletionChallenge();
      this.deletionCode = '';
      this.deletionAcknowledged = false;
    } catch (e) {
      this.deletionError = this.errorText(e, '验证码发送失败，请稍后重试。');
    } finally {
      this.deletionBusy = false;
    }
  }

  private async confirmDeletion(): Promise<void> {
    const challenge = this.deletionChallenge;
    if (challenge === null || this.deletionCode.length !== 6
      || !this.deletionAcknowledged || this.deletionBusy) return;
    this.deletionBusy = true;
    this.deletionError = '';
    try {
      await AppServices.instance.auth.confirmAccountDeletion(
        challenge.challengeId, challenge.receiptToken, this.deletionCode,
      );
      await AppServices.instance.auth.completeAccountDeletion();
      promptAction.showToast({ message: '账号注销已提交' });
      router.replaceUrl({ url: 'pages/LoginPage' });
    } catch (e) {
      this.deletionError = this.errorText(e, '操作未完成，请稍后重试。');
    } finally {
      this.deletionBusy = false;
    }
  }

  private errorText(error: Object | undefined, fallback: string): string {
    if (error instanceof AuthApiError) {
      if (error.code === 'ACCOUNT_DELETION_CHALLENGE_INVALID') return '验证码已失效，请重新发送。';
      if (error.code === 'CODE_ATTEMPTS_EXCEEDED') return '验证码尝试次数过多，请重新发送。';
      if (error.code === 'RATE_LIMITED') return '操作过于频繁，请稍后再试。';
      if (error.code === 'ACCOUNT_DELETION_PENDING') return '账号已经在注销处理中。';
      if (error.code === 'ACCOUNT_DELETION_PROCESSING') return '账号注销正在处理，暂时不能重复操作。';
      if (error.code === 'ACCOUNT_DELETION_UNAVAILABLE') return '当前暂不支持账号注销。';
      if (error.code === 'HTTP_401') return '登录状态已失效，请重新登录。';
      if (error.code === 'HTTP_429') return '操作过于频繁，请稍后再试。';
      if (error.code === 'HTTP_400') return '验证码错误或已过期，请检查后重试。';
      if (error.code === 'HTTP_409') return '账号当前正在注销处理中。';
    }
    return fallback;
  }

  private logout(): void {
    if (this.loggingOut) return;
    this.loggingOut = true;
    AppServices.instance.client.stop();
    AppServices.instance.auth.logout().then(() => {
      promptAction.showToast({ message: '已退出登录' });
      router.replaceUrl({ url: 'pages/LoginPage' });
    }).catch(() => {
      this.loggingOut = false;
      promptAction.showToast({ message: '退出登录失败，请重试' });
    });
  }

  // ─── 页面 ───────────────────────────────────────────────────────────────────

  @Builder
  private pageHeader(title: string, onBack: () => void) {
    Row({ space: 8 }) {
      Button() {
        Text('‹')
          .fontSize(uiFontSize(24))
          .fontColor($r('app.color.text_primary'))
      }
      .type(ButtonType.Circle)
      .width(40)
      .height(40)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .stateStyles({
        pressed: { opacity: 0.6 },
      })
      .onClick(onBack)
      Text(title)
        .fontSize(uiFontSize(20))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(56)
    .padding({ left: 12, right: 16 })
  }

  @Builder
  private accountHeader() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Text(this.accountInitial())
          .fontSize(uiFontSize(21))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width(56)
      .height(56)
      .backgroundColor($r('app.color.bg_card'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_PILL)

      Column({ space: 3 }) {
        Text(this.accountNameLabel())
          .fontSize(uiFontSize(17))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.accountEmail.trim().length > 0
          && this.accountEmail.trim() !== this.accountNameLabel()) {
          Text(this.accountEmail)
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Row({ space: 6 }) {
          Circle()
            .width(7)
            .height(7)
            .fill(this.relayStatus === 'online'
              ? $r('app.color.success')
              : this.relayStatus === 'connecting'
                ? $r('app.color.warn') : $r('app.color.text_tertiary'))
          Text(`${this.relayLabel()} · ${this.relayDetail()}`)
            .fontSize(uiFontSize(12))
            .lineHeight(uiLineHeight(17))
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 4, right: 4 })
  }

  @Builder
  private mainScreen() {
    Column() {
      this.pageHeader('设置', () => router.back())
      Stack({ alignContent: Alignment.Bottom }) {
        Scroll() {
          Column({ space: 20 }) {
            this.accountHeader()

            HarmonySettingsGroup({ title: '版本' }) {
              HarmonySettingsRow({ label: '当前版本', value: `整包版本 ${AppConfig.appVersion}` })
              this.settingsDivider()
              HarmonySettingsRow({
                label: '运行来源',
                value: '随整包',
                detail: '鸿蒙版本通过应用安装包更新；当前不使用 Mobile 的 OTA 热更新。',
              })
              this.settingsDivider()
              HarmonySettingsRow({ label: 'Beta 测试渠道', value: '当前版本不支持' })
            }

            HarmonySettingsGroup({ title: '通知' }) {
              HarmonySettingsSwitchRow({
                label: '任务完成通知',
                detail: '电脑上的任务完成、出错或需要你回复时，推送到这台手机。',
                value: this.taskCompletionPushEnabled,
                rowEnabled: !this.taskCompletionPushBusy,
                onInfo: () => this.showTaskCompletionPushInfo(),
                onChange: (enabled: boolean) => void this.setTaskCompletionPushEnabled(enabled),
              })
              if (this.taskCompletionPushEnabled || this.taskCompletionPushStatus.length > 0) {
                Divider().color($r('app.color.border')).margin({ left: 16, right: 16 })
                Column({ space: 10 }) {
                  Row() {
                    Text('Push Token')
                      .fontSize(uiFontSize(13))
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                    Blank()
                    if (this.taskCompletionPushStatus.length > 0) {
                      Text(this.taskCompletionPushStatus)
                        .fontSize(uiFontSize(12))
                        .fontColor(this.taskCompletionPushStatus === '已开启'
                          ? $r('app.color.success') : $r('app.color.text_secondary'))
                    }
                  }
                  .width('100%')
                  if (this.taskCompletionPushToken.length > 0) {
                    Text(this.taskCompletionPushToken)
                      .fontSize(uiFontSize(12))
                      .fontFamily('monospace')
                      .fontColor($r('app.color.code_text'))
                      .width('100%')
                      .padding(12)
                      .backgroundColor($r('app.color.bg_code'))
                      .borderRadius(UI_RADIUS_CONTROL)
                      .wordBreak(WordBreak.BREAK_ALL)
                    Row({ space: 10 }) {
                      Button('复制')
                        .fontSize(uiFontSize(13))
                        .fontColor($r('app.color.text_primary'))
                        .backgroundColor($r('app.color.bg_chip'))
                        .layoutWeight(1)
                        .onClick(() => this.copyTaskCompletionPushToken())
                      Button('重新获取')
                        .fontSize(uiFontSize(13))
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

            HarmonySettingsGroup({ title: '语音词典', footer: this.voiceStatus() }) {
              HarmonySettingsRow({
                label: '查看词典',
                value: `${this.voiceEntries().length} 个词条`,
                showChevron: true,
                onRowClick: () => this.openVoiceDictionary(),
              })
            }

            HarmonySettingsGroup({ title: '语言', footer: '仅影响应用界面。Agent 回复语言由 Agent 自身决定。' }) {
              HarmonySettingsRow({
                label: '语言',
                value: '简体中文',
                showChevron: true,
                onRowClick: () => this.openLanguageSheet(),
              })
            }

            HarmonySettingsGroup({ title: '关于这台手机' }) {
              HarmonySettingsRow({
                label: '设备名称',
                value: this.deviceName(),
                detail: '电脑端授权列表会显示这个名称。',
                showChevron: true,
                onRowClick: () => this.openRename(),
              })
              this.settingsDivider()
              HarmonySettingsRow({ label: '平台', value: 'HarmonyOS' })
              this.settingsDivider()
              HarmonySettingsRow({
                label: '被控权限',
                value: '电脑端管理',
                detail: '手机只作为控制端。允许被控、撤销和恢复权限仍在电脑端设置里完成。',
              })
            }

            HarmonySettingsGroup({
              title: '调试 / 开发者',
              collapsible: true,
              expanded: this.debugExpanded,
              onToggle: () => this.debugExpanded = !this.debugExpanded,
            }) {
              HarmonySettingsRow({
                label: '用户 ID',
                value: this.accountUserId(),
                showChevron: false,
                onRowClick: () => this.copyText(this.accountUserId()),
              })
              this.settingsDivider()
              HarmonySettingsRow({
                label: '设备 ID',
                value: this.deviceId.length > 0 ? this.deviceId : '初始化中',
                showChevron: false,
                onRowClick: () => this.copyText(this.deviceId),
              })
              this.settingsDivider()
              HarmonySettingsRow({
                label: 'Auth Server',
                value: AppConfig.authApiBaseUrl,
                showChevron: false,
                onRowClick: () => this.copyText(AppConfig.authApiBaseUrl),
              })
              this.settingsDivider()
              HarmonySettingsRow({ label: '登录区域', value: AppConfig.region === 'global' ? 'Global' : 'CN' })
              this.settingsDivider()
              HarmonySettingsRow({
                label: 'Device Link',
                value: this.relayLabel(),
                detail: this.relayDetail(),
              })
            }

            HarmonySettingsGroup({ title: '备案信息' }) {
              HarmonySettingsRow({
                label: '使用统计',
                value: '当前未启用',
                detail: '鸿蒙版当前未接入统计 SDK，不会上报使用统计。',
              })
              this.settingsDivider()
              HarmonySettingsRow({
                label: '隐私政策',
                value: '查看',
                showChevron: true,
                onRowClick: () => this.openExternal(this.privacyPolicyUrl()),
              })
              this.settingsDivider()
              HarmonySettingsRow({
                label: '用户协议',
                value: '查看',
                showChevron: true,
                onRowClick: () => this.openExternal(this.userAgreementUrl()),
              })
              if (AppConfig.region !== 'global') {
                this.settingsDivider()
                HarmonySettingsRow({ label: 'App 备案号', value: '沪ICP备11033765号-89A' })
              }
              if (this.deletionAvailable) {
                this.settingsDivider()
                HarmonySettingsRow({
                  label: '注销账号',
                  value: '继续',
                  showChevron: true,
                  onRowClick: () => this.openDeletion(),
                })
              }
            }

            Column({ space: 10 }) {
              Text('退出只会清除这台手机上的登录态和本地远程镜像，不会影响电脑端任务。')
                .fontSize(uiFontSize(12))
                .lineHeight(uiLineHeight(17))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: 12, right: 12 })
              Button(this.loggingOut ? '退出中' : '退出登录')
                .width('100%')
                .height(48)
                .fontSize(uiFontSize(15))
                .fontColor($r('app.color.chat_cta_text'))
                .backgroundColor($r('app.color.danger'))
                .enabled(!this.loggingOut)
                .onClick(() => this.logout())
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 32 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Auto)

        if (this.languageSheetOpen) {
          Column() {
          }
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.overlay'))
          .onClick(() => this.languageSheetOpen = false)

          Column({ space: 4 }) {
            Row() {
              Text('语言')
                .fontSize(uiFontSize(17))
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              Button('关闭')
                .fontSize(uiFontSize(13))
                .fontColor($r('app.color.text_secondary'))
                .backgroundColor(Color.Transparent)
                .onClick(() => this.languageSheetOpen = false)
            }
            .width('100%')
            .padding({ left: 16, right: 10, top: 12, bottom: 8 })
            HarmonySettingsRow({
              label: '跟随系统',
              value: '当前不支持',
              onRowClick: () => this.selectLanguage('system'),
            })
            HarmonySettingsRow({ label: '简体中文', value: '已选择' })
          }
          .width('100%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius({ topLeft: UI_RADIUS_CONTAINER, topRight: UI_RADIUS_CONTAINER })
          .padding({ bottom: 16 })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  private accountUserId(): string {
    const id = AppServices.instance.auth.cacheAccountId;
    return id.length > 0 ? id : '未同步';
  }

  @Builder
  private settingsDivider() {
    Divider()
      .color($r('app.color.border'))
      .margin({ left: 16 })
  }

  @Builder
  private voiceScreen() {
    Column() {
      this.pageHeader('语音词典', () => this.screen = 'main')
      Column() {
        Row() {
          Text(`${this.voiceEntries().length} 个词条`)
            .fontSize(uiFontSize(14))
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          Button(this.dictionaryRefreshing ? '刷新中…' : '刷新')
            .fontSize(uiFontSize(13))
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.bg_chip'))
            .enabled(!this.dictionaryRefreshing)
            .onClick(() => void this.refreshVoiceDictionary())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })

        if (this.dictionaryError.length > 0) {
          Text(this.dictionaryError)
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.warn'))
            .padding({ left: 16, right: 16, bottom: 10 })
        }
      }
      .width('100%')
      .backgroundColor($r('app.color.bg_card'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_CONTAINER)
      .margin({ left: 16, right: 16, top: 12 })

      List({ space: 0 }) {
        if (this.voiceEntries().length === 0) {
          ListItem() {
            Text(this.voiceStatus())
              .fontSize(uiFontSize(13))
              .lineHeight(uiLineHeight(19))
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding(20)
          }
        } else {
          ForEach(this.voiceEntries(), (entry: VoiceDictionaryEntryView) => {
            ListItem() {
              Column({ space: 4 }) {
                Text(entry.text)
                  .fontSize(uiFontSize(14))
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                if (entry.aliases.length > 0) {
                  Text(`常被听成：${entry.aliases.join('、')}`)
                    .fontSize(uiFontSize(12))
                    .lineHeight(uiLineHeight(17))
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%')
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .border({ width: { bottom: 1 }, color: { bottom: $r('app.color.border') } })
            }
          }, (entry: VoiceDictionaryEntryView) => entry.key)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .margin({ left: 16, right: 16, top: 12 })
      .backgroundColor($r('app.color.bg_card'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_CONTAINER)
      .scrollBar(BarState.Auto)

      Text('词典保存在电脑上，并在你的电脑之间自动同步；手机只能查看，添加和删除请回电脑操作。')
        .fontSize(uiFontSize(12))
        .lineHeight(uiLineHeight(17))
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: 28, right: 28, top: 10, bottom: 18 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  private renameScreen() {
    Column() {
      this.pageHeader('设备名称', () => this.closeRename())
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          TextInput({ placeholder: '本机名称', text: this.renameDraft })
            .fontSize(uiFontSize(16))
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .maxLength(64)
            .enabled(!this.renameSaving)
            .onChange((value: string) => this.updateRenameDraft(value))
            .onSubmit(() => this.closeRename())
          Button('×')
            .type(ButtonType.Circle)
            .width(28)
            .height(28)
            .padding(0)
            .fontSize(uiFontSize(17))
            .fontColor($r('app.color.chat_cta_text'))
            .backgroundColor($r('app.color.text_tertiary'))
            .enabled(!this.renameSaving)
            .onClick(() => this.resetRename())
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 12 })
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(UI_RADIUS_PILL)
        if (this.renameMessage.length > 0) {
          Text(this.renameMessage)
            .fontSize(uiFontSize(12))
            .lineHeight(uiLineHeight(17))
            .fontColor($r('app.color.text_tertiary'))
            .padding({ left: 16, right: 16 })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 20 })
      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  private deletionScreen() {
    Column() {
      this.pageHeader('注销账号', () => this.screen = 'main')
      Scroll() {
        Column({ space: 16 }) {
          if (this.deletionAvailabilityLoading) {
            Text('正在确认账号状态…')
              .fontSize(uiFontSize(13))
              .fontColor($r('app.color.text_secondary'))
              .padding(16)
          } else if (!this.deletionAvailable) {
            HarmonySettingsGroup({ title: '当前无法进行此操作' }) {
              Text('请返回设置页稍后重试。')
                .fontSize(uiFontSize(13))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding(16)
            }
          } else if (this.deletionChallenge !== null) {
            HarmonySettingsGroup({ title: '验证账号所有权' }) {
              Text(`验证码已发送至 ${this.deletionChallenge.maskedTarget}，10 分钟内有效。`)
                .fontSize(uiFontSize(13))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 14 })
              TextInput({ placeholder: '6 位验证码', text: this.deletionCode })
                .type(InputType.Number)
                .fontSize(uiFontSize(17))
                .fontColor($r('app.color.text_primary'))
                .width('calc(100% - 32vp)')
                .margin({ left: 16, right: 16, top: 8, bottom: 16 })
                .maxLength(6)
                .enabled(!this.deletionBusy)
                .onChange((value: string) => this.deletionCode = value.replace(/\D/g, ''))
            }
            Row({ space: 10 }) {
              Stack({ alignContent: Alignment.Center }) {
                if (this.deletionAcknowledged) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(uiFontSize(15))
                    .fontColor([$r('app.color.chat_cta_text')])
                }
              }
              .width(24)
              .height(24)
              .backgroundColor(this.deletionAcknowledged ? $r('app.color.danger') : Color.Transparent)
              .border({ width: 1, color: this.deletionAcknowledged
                ? $r('app.color.danger') : $r('app.color.border') })
              .borderRadius(UI_RADIUS_CONTROL)
              Text('我已了解：这台手机会立即退出；30 天内重新登录可撤销；到期后账号将永久删除且无法恢复。')
                .fontSize(uiFontSize(12))
                .lineHeight(uiLineHeight(17))
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 16, right: 16 })
            .onClick(() => this.deletionAcknowledged = !this.deletionAcknowledged)
            Button(this.deletionBusy ? '确认中' : '确认注销账号')
              .width('calc(100% - 32vp)')
              .height(48)
              .margin({ left: 16, right: 16, top: 12 })
              .fontSize(uiFontSize(15))
              .fontColor($r('app.color.chat_cta_text'))
              .backgroundColor($r('app.color.danger'))
              .enabled(!this.deletionBusy && this.deletionCode.length === 6 && this.deletionAcknowledged)
              .onClick(() => void this.confirmDeletion())
            Button('重新发送验证码')
              .width('calc(100% - 32vp)')
              .height(40)
              .margin({ left: 16, right: 16 })
              .fontSize(uiFontSize(13))
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.bg_chip'))
              .enabled(!this.deletionBusy)
              .onClick(() => void this.requestDeletionChallenge())
          } else {
            HarmonySettingsGroup({ title: '注销前请确认' }) {
              Text('确认后，这台手机立即退出；其他客户端会在登录状态失效后退出。')
                .fontSize(uiFontSize(13))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 14 })
              Text('账号进入 30 天等待期；期间重新登录即可取消注销。')
                .fontSize(uiFontSize(13))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 8 })
              Text('等待期结束后，Cindy 登录账号将被永久删除。')
                .fontSize(uiFontSize(13))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 8, bottom: 14 })
            }
            if (this.deletionAvailability?.manualAppleRevocationRequired === true) {
              Text('使用 Apple 登录的授权可能需要你在 Apple ID 设置中手动停止使用 Cindy。')
                .fontSize(uiFontSize(12))
                .lineHeight(uiLineHeight(17))
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ left: 16, right: 16 })
            }
            Text(`验证码将发送至 ${this.deletionAvailability?.maskedTarget ?? ''}。`)
              .fontSize(uiFontSize(12))
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding({ left: 16, right: 16 })
            Button(this.deletionBusy ? '发送中' : '发送验证码')
              .width('calc(100% - 32vp)')
              .height(48)
              .margin({ left: 16, right: 16 })
              .fontSize(uiFontSize(15))
              .fontColor($r('app.color.chat_cta_text'))
              .backgroundColor($r('app.color.danger'))
              .enabled(!this.deletionBusy)
              .onClick(() => void this.requestDeletionChallenge())
          }
          if (this.deletionError.length > 0) {
            Text(this.deletionError)
              .fontSize(uiFontSize(12))
              .lineHeight(uiLineHeight(17))
              .fontColor($r('app.color.danger'))
              .width('100%')
              .padding({ left: 16, right: 16 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 32 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  build() {
    if (this.screen === 'voice') {
      this.voiceScreen();
    } else if (this.screen === 'rename') {
      this.renameScreen();
    } else if (this.screen === 'deletion') {
      this.deletionScreen();
    } else {
      this.mainScreen();
    }
  }
}

@Component
struct HarmonySettingsGroup {
  @Prop title: string = '';
  @Prop footer: string = '';
  @Prop collapsible: boolean = false;
  @Prop expanded: boolean = true;
  @BuilderParam content: () => void = this.emptyContent;
  onToggle: () => void = () => {
  };

  @Builder
  private emptyContent() {
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.title)
          .fontSize(uiFontSize(13))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
        if (this.collapsible) {
          SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
            .fontSize(uiFontSize(15))
            .fontColor([$r('app.color.text_tertiary')])
        }
      }
      .width('100%')
      .height(24)
      .padding({ left: 12, right: 12 })
      .enabled(this.collapsible)
      .onClick(() => {
        if (this.collapsible) this.onToggle();
      })
      if (!this.collapsible || this.expanded) {
        Column() {
          this.content()
        }
        .width('100%')
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: 1, color: $r('app.color.border') })
        .borderRadius(UI_RADIUS_CONTAINER)
        .clip(true)
      }
      if (this.footer.length > 0 && (!this.collapsible || this.expanded)) {
        Text(this.footer)
          .fontSize(uiFontSize(12))
          .lineHeight(uiLineHeight(17))
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ left: 12, right: 12 })
      }
    }
    .width('100%')
  }
}

@Component
struct HarmonySettingsRow {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop detail: string = '';
  @Prop showChevron: boolean = false;
  onRowClick: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.label)
          .fontSize(uiFontSize(14))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.detail.length > 0) {
          Text(this.detail)
            .fontSize(uiFontSize(12))
            .lineHeight(uiLineHeight(17))
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(uiFontSize(13))
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.End)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '48%' })
      }
      if (this.showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(uiFontSize(15))
          .fontColor([$r('app.color.text_tertiary')])
      }
    }
    .width('100%')
    .height(this.detail.length > 0 ? 64 : 52)
    .padding({ left: 16, right: 12, top: 10, bottom: 10 })
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => this.onRowClick())
  }
}

@Component
struct HarmonySettingsSwitchRow {
  @Prop label: string = '';
  @Prop detail: string = '';
  @Prop value: boolean = false;
  @Prop rowEnabled: boolean = true;
  onInfo: () => void = () => {
  };
  onChange: (enabled: boolean) => void = (_enabled: boolean) => {
  };

  build() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Row({ space: 4 }) {
          Text(this.label)
            .fontSize(uiFontSize(14))
            .fontColor($r('app.color.text_secondary'))
          Button() {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(uiFontSize(15))
              .fontColor([$r('app.color.text_secondary')])
          }
          .type(ButtonType.Circle)
          .width(28)
          .height(28)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .onClick(() => this.onInfo())
        }
        if (this.detail.length > 0) {
          Text(this.detail)
            .fontSize(uiFontSize(12))
            .lineHeight(uiLineHeight(17))
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .selectedColor($r('app.color.accent'))
        .enabled(this.rowEnabled)
        .onChange((enabled: boolean) => this.onChange(enabled))
    }
    .width('100%')
    .height(this.detail.length > 0 ? 68 : 52)
    .padding({ left: 16, right: 12, top: 10, bottom: 10 })
  }
}
