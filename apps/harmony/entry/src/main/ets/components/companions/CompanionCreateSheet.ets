import { i18n } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';
import { AppServices } from '../../core/AppServices';
import { harmonyV12String } from '../../core/HarmonyStrings';
import {
  CompanionCreateForm, COMPANION_NAME_MAX, classifyCompanionCreateFailure, companionLocale, normalizeTeammateName,
} from '../../core/tasks/CompanionCreate';
import { companionPortraits, pickCompanionAvatar, randomCompanionPortrait } from '../../core/tasks/CompanionAvatar';
import { UI_CLICK_EFFECT, UI_RADIUS_PILL } from '../UiKit';

/** 外层 sheet 关闭前读取：有未保存内容时先确认，提交中不允许关闭。 */
export class CompanionCreateSheetState {
  dirty: boolean = false;
  busy: boolean = false;
}

/**
 * 「新建伙伴」表单内容，由 `CompanionCreateMenu` 放进 bindSheet。
 *
 * 行为对齐 `apps/mobile/src/session/CompanionProfileSheet.tsx` 的 CompanionCreateSheet：
 * - 打开时读取电脑端 `teammates/bot/create` 表单；默认随机选一张预置头像；
 * - 可提交条件：电脑在线、电脑端 action 可用、名字非空、已有头像、名字不与该电脑已知伙伴重名；
 * - 失败：重名 / 参数无效视为未创建，换新 requestId；其他失败视为结果未确认，锁定表单并在重试时
 *   复用同一 requestId，避免重复创建；失败后重新读取表单但保留输入和提示；
 * - 成功：交回电脑端确认的伙伴 id，由外层在 sheet 关闭后处理跳转。
 * 与 Mobile 相比本期不做模型选择和「从其他 Agent 导入」：提交不带 modelChain，由电脑端用默认模型。
 */
@Component
export struct CompanionCreateSheet {
  @Prop deviceId: string = '';
  @Prop deviceName: string = '';
  @Prop @Watch('onlineChanged') online: boolean = false;
  sheetState: CompanionCreateSheetState = new CompanionCreateSheetState();
  onCreated: (botId: string) => void = (_botId: string): void => {};
  onRequestClose: () => void = (): void => {};
  @State private form: CompanionCreateForm | null = null;
  @State private loading: boolean = false;
  @State private busy: boolean = false;
  @State private failed: boolean = false;
  @State private nameTaken: boolean = false;
  @State private unconfirmed: boolean = false;
  @State private name: string = '';
  @State private avatar: string = '';
  @State private portraitChanged: boolean = false;
  @State private avatarBusy: boolean = false;
  @State private avatarFailed: boolean = false;
  @State private portraits: string[] = [];
  private takenNames: string[] = [];
  private requestId: string = '';
  private sequence: number = 0;
  private alive: boolean = false;
  private epoch: number = 0;
  private locale: string = companionLocale(i18n.System.getSystemLocale());

  aboutToAppear(): void {
    this.alive = true;
    this.epoch = AppServices.instance.auth.sessionEpoch;
    this.portraits = companionPortraits(this.getUIContext().getHostContext());
    this.avatar = randomCompanionPortrait(this.portraits);
    // 每次打开重新读一次已知名字；列表缓存不是响应式的。
    this.takenNames = AppServices.instance.teammateRoster.takenNames(this.deviceId);
    this.syncState();
    if (this.online) void this.reload(false);
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.sequence++;
  }

  /** 与 Mobile 一致：电脑上下线后丢弃旧表单，重新在线时重读；输入与 requestId 保留。 */
  onlineChanged(): void {
    if (!this.alive) return;
    this.sequence++;
    this.form = null;
    this.failed = false;
    this.loading = false;
    if (this.online) void this.reload(false);
  }

  private copy(name: string, ...args: Array<string | number>): string {
    return harmonyV12String(this.getUIContext().getHostContext(), name, ...args);
  }

  private current(): boolean {
    return this.alive && this.epoch === AppServices.instance.auth.sessionEpoch;
  }

  private syncState(): void {
    this.sheetState.dirty = this.name.trim().length > 0 || this.portraitChanged;
    this.sheetState.busy = this.busy;
  }

  private duplicate(): boolean {
    const typed = this.name.trim();
    return typed.length > 0 && this.takenNames.includes(normalizeTeammateName(typed));
  }

  /** 一次性的创建 action 会被失败的提交消耗；重新读取时不清空输入，也可保留失败提示。 */
  private async reload(keepError: boolean): Promise<void> {
    const sequence = ++this.sequence;
    if (!keepError) this.failed = false;
    this.loading = true;
    try {
      const form = await AppServices.instance.teammateRoster.createForm(this.deviceId, this.locale);
      if (this.current() && sequence === this.sequence) this.form = form;
    } catch (_error) {
      if (this.current() && sequence === this.sequence) this.failed = true;
    } finally {
      if (this.current() && sequence === this.sequence) this.loading = false;
    }
  }

  private blocked(): boolean {
    const form = this.form;
    return this.busy || !this.online || form === null || !form.actionId || form.modelMissing
      || !this.name.trim() || !this.avatar || this.duplicate();
  }

  private async submit(): Promise<void> {
    const form = this.form;
    if (this.blocked() || form === null) return;
    this.busy = true;
    this.failed = false;
    this.nameTaken = false;
    this.syncState();
    const sequence = this.sequence;
    if (!this.requestId) this.requestId = util.generateRandomUUID();
    try {
      const botId = await AppServices.instance.teammateRoster.create(this.deviceId, this.locale, form.actionId,
        this.name, this.avatar, this.requestId);
      if (!this.current() || sequence !== this.sequence) return;
      this.onCreated(botId);
    } catch (error) {
      if (this.current() && sequence === this.sequence) {
        const failure = classifyCompanionCreateFailure(error as Object);
        this.nameTaken = failure === 'taken';
        this.failed = true;
        this.unconfirmed = failure === 'unconfirmed';
        if (failure !== 'unconfirmed') this.requestId = '';
        void this.reload(true);
      }
    } finally {
      if (this.alive) {
        this.busy = false;
        this.syncState();
      }
    }
  }

  private choosePortrait(value: string): void {
    if (this.busy || this.unconfirmed || this.avatarBusy || value === this.avatar) return;
    this.avatar = value;
    this.portraitChanged = true;
    this.syncState();
  }

  private async upload(): Promise<void> {
    if (this.busy || this.unconfirmed || this.avatarBusy) return;
    this.avatarBusy = true;
    this.avatarFailed = false;
    try {
      const bytes = await pickCompanionAvatar((): boolean => this.current());
      if (bytes && this.current() && !this.unconfirmed) this.choosePortraitValue(bytes);
    } catch (_error) {
      if (this.current()) this.avatarFailed = true;
    } finally {
      if (this.alive) this.avatarBusy = false;
    }
  }

  private choosePortraitValue(bytes: string): void {
    this.avatar = bytes;
    this.portraitChanged = true;
    this.syncState();
  }

  private notice(): string {
    if (!this.online) return this.copy('v140_companion_create_offline', this.deviceName);
    if (this.duplicate() || this.nameTaken) return this.copy('v140_companion_create_name_taken');
    if (this.failed) return this.copy('v140_companion_create_failed');
    return '';
  }

  /** 灰掉的按钮要说明原因：电脑不能新建、没有默认模型、缺名字或头像。读取完成前不下结论。 */
  private hint(): string {
    const form = this.form;
    if (this.notice() || this.loading || form === null) return '';
    if (!form.actionId) return this.copy('v140_companion_create_unsupported');
    if (form.modelMissing) return this.copy('v140_companion_create_model_missing');
    if (!this.name.trim() || !this.avatar) return this.copy('v140_companion_create_needs_details');
    return '';
  }

  private uploadedAvatar(): boolean {
    return this.avatar.length > 0 && !this.portraits.includes(this.avatar);
  }

  private fieldsDisabled(): boolean {
    return this.busy || !this.online || this.unconfirmed;
  }

  @Builder
  private noteText(text: string) {
    Text(text)
      .fontSize(13)
      .lineHeight(18)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
  }

  @Builder
  private heading(text: string) {
    Text(text)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
      .width('100%')
  }

  @Builder
  private portraitChoice(bytes: string, index: number) {
    Column() {
      Image('data:image/jpeg;base64,' + bytes)
        .width(52)
        .height(52)
        .borderRadius(UI_RADIUS_PILL)
        .objectFit(ImageFit.Cover)
    }
    .width(60)
    .height(60)
    .justifyContent(FlexAlign.Center)
    .borderRadius(UI_RADIUS_PILL)
    .border({ width: 1, color: bytes === this.avatar ? $r('app.color.text_primary') : Color.Transparent })
    .margin({ right: 8, bottom: 8 })
    .opacity(this.fieldsDisabled() || this.avatarBusy ? 0.45 : 1)
    .accessibilityText(this.copy('v140_companion_create_portrait', index + 1))
    .accessibilitySelected(bytes === this.avatar)
    .onClick((): void => this.choosePortrait(bytes))
  }

  @Builder
  private uploadChoice() {
    Column() {
      if (this.uploadedAvatar()) {
        Image('data:image/jpeg;base64,' + this.avatar)
          .width(52)
          .height(52)
          .borderRadius(UI_RADIUS_PILL)
          .objectFit(ImageFit.Cover)
      } else {
        SymbolGlyph($r('sys.symbol.picture'))
          .fontSize(22)
          .fontColor([$r('app.color.text_secondary')])
      }
    }
    .width(60)
    .height(60)
    .justifyContent(FlexAlign.Center)
    .borderRadius(UI_RADIUS_PILL)
    .border({ width: 1, color: this.uploadedAvatar() ? $r('app.color.text_primary') : $r('app.color.border') })
    .margin({ right: 8, bottom: 8 })
    .opacity(this.fieldsDisabled() || this.avatarBusy ? 0.45 : 1)
    .accessibilityText(this.copy('v140_companion_create_upload'))
    .accessibilitySelected(this.uploadedAvatar())
    .onClick((): void => { void this.upload(); })
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.notice()) {
          this.noteText(this.notice())
        }
        if (this.hint()) {
          this.noteText(this.hint())
        }
        if (this.loading) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color($r('app.color.text_secondary'))
            .accessibilityText(this.copy('v140_companion_create_loading'))
        }
        if (this.form !== null) {
          Column({ space: 8 }) {
            this.heading(this.form?.nameLabel ?? '')
            TextInput({ text: this.name })
              .maxLength(COMPANION_NAME_MAX)
              .enabled(!this.fieldsDisabled())
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_placeholder'))
              .caretColor($r('app.color.accent'))
              .backgroundColor($r('app.color.bg_page'))
              .border({ width: 1, color: $r('app.color.border') })
              .borderRadius(UI_RADIUS_PILL)
              .padding({ left: 16, right: 16 })
              .height(50)
              .width('100%')
              .accessibilityText(this.form?.nameLabel ?? '')
              .onChange((value: string): void => {
                if (this.unconfirmed) return;
                this.name = value;
                this.syncState();
              })
          }
          Column({ space: 8 }) {
            this.heading(this.form?.avatarLabel ?? '')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.portraits, (bytes: string, index: number) => {
                this.portraitChoice(bytes, index)
              }, (_bytes: string, index: number): string => String(index))
              this.uploadChoice()
            }
            .width('100%')
            if (this.avatarBusy || this.avatarFailed) {
              this.noteText(this.copy(this.avatarBusy ? 'v140_companion_create_loading' : 'v140_companion_create_avatar_failed'))
            }
          }
        }
        if (this.form === null && this.online && !this.loading) {
          Button(this.copy('v140_companion_create_retry'), { type: ButtonType.Capsule })
            .width('100%')
            .height(50)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.bg_page'))
            .border({ width: 1, color: $r('app.color.border') })
            .enabled(!this.busy)
            .clickEffect(UI_CLICK_EFFECT)
            .onClick((): void => { void this.reload(false); })
        }
        Button({ type: ButtonType.Capsule }) {
          if (this.busy) {
            LoadingProgress()
              .width(24)
              .height(24)
              .color($r('app.color.chat_cta_text'))
          } else {
            Text(this.copy('v140_companion_create_title'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.chat_cta_text'))
          }
        }
        .width('100%')
        .height(50)
        .margin({ top: 8 })
        .backgroundColor($r('app.color.chat_cta'))
        .enabled(!this.blocked())
        .opacity(this.blocked() && !this.busy ? 0.45 : 1)
        .accessibilityText(this.copy('v140_companion_create_title'))
        .onClick((): void => { void this.submit(); })
        // 草稿阻止下滑关闭时，这是明确的退出入口；有改动仍会先确认。
        Button(this.copy('v140_companion_create_cancel'), { type: ButtonType.Capsule })
          .width('100%')
          .height(44)
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .enabled(!this.busy)
          .onClick((): void => this.onRequestClose())
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 12, bottom: 24 })
    }
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }
}
