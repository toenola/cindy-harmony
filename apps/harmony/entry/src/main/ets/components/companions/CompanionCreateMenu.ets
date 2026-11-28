import { SymbolGlyphModifier } from '@kit.ArkUI';
import { harmonyV12String } from '../../core/HarmonyStrings';
import { UI_ICON_CLICK_EFFECT, UI_RADIUS_PILL } from '../UiKit';
import { CompanionCreateSheet, CompanionCreateSheetState } from './CompanionCreateSheet';
import {
  UiSheetExtras, uiConfirm, uiConfirmCopy, uiMenuOptions, uiOverlayBuildId, uiOverlayTrace, uiSheetOptions,
} from '../common/UiOverlay';

/** 「+」菜单里可选的一台电脑。 */
export class CompanionHostOption {
  deviceId: string = '';
  name: string = '';
}

type CompanionCreateKind = 'companion' | 'group';

/**
 * 首页「伙伴」标题行右侧的「+」：新建伙伴 / 新建群聊 / 加入群聊。
 *
 * 行为对齐 Mobile：
 * - `apps/mobile/src/session/TeammateCreateController.tsx`：只有一台可用电脑时菜单项直接进入；
 *   多台时展开二级列出电脑；没有可用电脑时不显示该项；「加入群聊」单独一组放在最后。
 *   菜单关闭后才打开下一层，不让两个浮层叠在一起。
 * - `apps/mobile/src/session/HomeTeammatesSection.tsx`：加入群聊只要求已登录，不依赖电脑在线。
 * - `apps/mobile/src/chat/ChatInviteSheet.tsx`、`ChatInviteView.ios.tsx`：手动输入态为标题「加入群聊」、
 *   邀请链接输入框、说明文字和「继续」，输入为空时禁用。读取预览与接受加入仍由现有
 *   `ChatHomePanel` / `ChatInvitePanel` 完成，本组件只负责收集链接。
 * - 新建伙伴表单见 `CompanionCreateSheet`；与 Mobile 一样在表单关闭后才回报创建结果，
 *   由调用方负责刷新列表与打开新伙伴。
 */
@Component
export struct CompanionCreateMenu {
  /** 可新建伙伴的在线电脑；`onCreateCompanion` 为空时不显示「新建伙伴」。 */
  @Prop companionHosts: CompanionHostOption[] = [];
  /** 可新建群聊的在线电脑。 */
  @Prop groupHosts: CompanionHostOption[] = [];
  /** 新建伙伴成功、表单已关闭后回报：所在电脑与电脑端确认的伙伴 id。 */
  onCreateCompanion: ((deviceId: string, botId: string) => void) | null = null;
  onCreateGroup: ((deviceId: string) => void) | null = null;
  onJoinGroup: (link: string) => void = (_link: string): void => {};
  @State private menuOpen: boolean = false;
  @State private sheetOpen: boolean = false;
  @State private joinInput: string = '';
  private pendingSheet: boolean = false;
  private pendingJoin: string = '';
  @State private createOpen: boolean = false;
  @State private createDeviceId: string = '';
  @State private createDeviceName: string = '';
  private pendingCreate: string = '';
  private createdBotId: string = '';
  private createState: CompanionCreateSheetState = new CompanionCreateSheetState();

  private hostName(deviceId: string): string {
    const host = this.companionHosts.find((item: CompanionHostOption): boolean => item.deviceId === deviceId);
    return host?.name ?? this.createDeviceName;
  }

  private copy(name: string): string {
    return harmonyV12String(this.getUIContext().getHostContext(), name);
  }

  private showsCompanion(): boolean {
    return this.onCreateCompanion !== null && this.companionHosts.length > 0;
  }

  private showsGroup(): boolean {
    return this.onCreateGroup !== null && this.groupHosts.length > 0;
  }

  private start(kind: CompanionCreateKind, deviceId: string): void {
    const hosts = kind === 'companion' ? this.companionHosts : this.groupHosts;
    if (!hosts.some((host: CompanionHostOption): boolean => host.deviceId === deviceId)) return;
    this.menuOpen = false;
    // 表单等菜单消失后再打开，不让两个浮层叠在一起。
    if (kind === 'companion') this.pendingCreate = deviceId;
    else this.onCreateGroup?.(deviceId);
  }

  private requestJoinSheet(): void {
    this.pendingSheet = true;
    this.menuOpen = false;
  }

  private menuDisappeared(): void {
    this.menuOpen = false;
    const create = this.pendingCreate;
    this.pendingCreate = '';
    if (create && this.onCreateCompanion !== null) {
      this.pendingSheet = false;
      this.createDeviceId = create;
      this.createDeviceName = this.hostName(create);
      this.createdBotId = '';
      this.createState = new CompanionCreateSheetState();
      this.createOpen = true;
      return;
    }
    if (!this.pendingSheet) return;
    this.pendingSheet = false;
    this.joinInput = '';
    this.pendingJoin = '';
    this.sheetOpen = true;
  }

  private submitJoin(): void {
    const link = this.joinInput.trim();
    if (!link) return;
    this.pendingJoin = link;
    this.sheetOpen = false;
  }

  private sheetDisappeared(): void {
    this.sheetOpen = false;
    const link = this.pendingJoin;
    this.pendingJoin = '';
    this.joinInput = '';
    if (link) this.onJoinGroup(link);
  }

  /** 下滑、点关闭或「取消」：提交中不关闭；有改动先确认放弃（Mobile CompanionCreateSheet close）。 */
  private requestCreateClose(dismiss: () => void): void {
    if (this.createState.busy) return;
    if (!this.createState.dirty) { dismiss(); return; }
    const copy = uiConfirmCopy(this.copy('v140_companion_create_unsaved_title'),
      this.copy('v140_companion_create_unsaved_body'), this.copy('v140_companion_create_discard'),
      this.copy('v140_companion_create_cancel'), true);
    void uiConfirm(this.getUIContext(), copy).then((confirmed: boolean): void => {
      if (confirmed && !this.createState.busy) dismiss();
    });
  }

  private companionCreated(botId: string): void {
    this.createdBotId = botId;
    this.createOpen = false;
  }

  private createDisappeared(): void {
    this.createOpen = false;
    const botId = this.createdBotId;
    const deviceId = this.createDeviceId;
    this.createdBotId = '';
    if (botId && deviceId) this.onCreateCompanion?.(deviceId, botId);
  }

  @Builder
  private createSheet() {
    CompanionCreateSheet({
      deviceId: this.createDeviceId,
      deviceName: this.createDeviceName,
      online: this.companionHosts.some((host: CompanionHostOption): boolean => host.deviceId === this.createDeviceId),
      sheetState: this.createState,
      onCreated: (botId: string): void => this.companionCreated(botId),
      onRequestClose: (): void => this.requestCreateClose((): void => { this.createOpen = false; }),
    })
  }

  @Builder
  private hostSubmenu(kind: CompanionCreateKind) {
    Menu() {
      ForEach(kind === 'companion' ? this.companionHosts : this.groupHosts, (host: CompanionHostOption) => {
        MenuItem({ content: host.name })
          .onClick((): void => this.start(kind, host.deviceId))
      }, (host: CompanionHostOption): string => JSON.stringify([kind, host.deviceId, host.name]))
    }
  }

  @Builder
  private createItem(kind: CompanionCreateKind) {
    if ((kind === 'companion' ? this.companionHosts : this.groupHosts).length === 1) {
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier(kind === 'companion'
          ? $r('sys.symbol.person_badge_plus') : $r('sys.symbol.person_2')),
        content: this.copy(kind === 'companion' ? 'v140_companion_create' : 'v140_group_create'),
      })
        .onClick((): void => this.start(kind,
          (kind === 'companion' ? this.companionHosts : this.groupHosts)[0].deviceId))
    } else {
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier(kind === 'companion'
          ? $r('sys.symbol.person_badge_plus') : $r('sys.symbol.person_2')),
        content: this.copy(kind === 'companion' ? 'v140_companion_create' : 'v140_group_create'),
        builder: (): void => this.hostSubmenu(kind),
      })
    }
  }

  @Builder
  private menuContent() {
    Menu() {
      if (this.showsCompanion() || this.showsGroup()) {
        MenuItemGroup() {
          if (this.showsCompanion()) {
            this.createItem('companion')
          }
          if (this.showsGroup()) {
            this.createItem('group')
          }
        }
      }
      MenuItemGroup() {
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.link')),
          content: this.copy('v140_group_join'),
        })
          .onClick((): void => this.requestJoinSheet())
      }
    }
    .subMenuExpandingMode(SubMenuExpandingMode.STACK_EXPAND)
    .id(uiOverlayBuildId('companion-menu'))
  }

  @Builder
  private joinSheet() {
    Column() {
      TextInput({ text: this.joinInput, placeholder: this.copy('v140_group_join_placeholder') })
        .type(InputType.URL)
        .enterKeyType(EnterKeyType.Go)
        .maxLength(8192)
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
        .accessibilityText(this.copy('v140_group_join_input_label'))
        .onChange((value: string): void => { this.joinInput = value; })
        .onSubmit((): void => this.submitJoin())
      Text(this.copy('v140_group_join_description'))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 8 })
      Button(this.copy('v140_group_join_continue'), { type: ButtonType.Capsule })
        .width('100%')
        .height(50)
        .margin({ top: 24 })
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.chat_cta_text'))
        .backgroundColor($r('app.color.chat_cta'))
        .enabled(this.joinInput.trim().length > 0)
        .opacity(this.joinInput.trim().length > 0 ? 1 : 0.45)
        .onClick((): void => this.submitJoin())
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 12, bottom: 24 })
  }

  build() {
    // 两张 sheet 分别挂在按钮和外层上，避免同一节点绑定两个 bindSheet。
    Column() {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(18)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .clickEffect(UI_ICON_CLICK_EFFECT)
      .accessibilityText(this.copy('v140_companion_create_menu'))
      .onClick((): void => {
        uiOverlayTrace('companion-menu', 'open');
        this.menuOpen = true;
      })
      .bindMenu(this.menuOpen, this.menuContent(),
        uiMenuOptions((): void => this.menuDisappeared(), Placement.BottomRight, 'companion-menu'))
      .bindSheet($$this.sheetOpen, this.joinSheet(),
        uiSheetOptions(this.copy('v140_group_join'), (): void => this.sheetDisappeared(), SheetSize.FIT_CONTENT,
          this.joinSheetExtras()))
    }
    .bindSheet($$this.createOpen, this.createSheet(), this.createSheetOptions())
  }

  private joinSheetExtras(): UiSheetExtras {
    const extras = new UiSheetExtras();
    extras.traceTag = 'group-join';
    return extras;
  }

  /** 新建伙伴表单：统一表单选项（docs/overlay-standard.md §3.2），高度 LARGE，关闭前先确认放弃改动。 */
  private createSheetOptions(): SheetOptions {
    const extras = new UiSheetExtras();
    extras.onWillDismiss = (action: DismissSheetAction): void => this.requestCreateClose((): void => action.dismiss());
    extras.traceTag = 'companion-create';
    return uiSheetOptions(this.copy('v140_companion_create_title'), (): void => this.createDisappeared(),
      SheetSize.LARGE, extras);
  }
}
