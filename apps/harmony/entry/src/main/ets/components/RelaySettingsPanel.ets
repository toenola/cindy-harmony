import { UiListGroup, UiListRow } from './common/UiList';
import { UiActionButton, UiActionKind } from './common/UiActions';
import { UiPanelHeading } from './common/UiNavigation';
import { UiInlineError } from './common/UiStatus';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import { RelayAccountDirectory, RelayAccountOffer } from '../core/device-link/RelayAccountDirectory';
import { AppServices } from '../core/AppServices';
import { AppConfig } from '../AppConfig';
import { RelayRoute } from '../core/device-link/RelayRoute';
import { RelayEnrollment, RelayEnrollmentAccount } from '../core/device-link/RelayEnrollment';
import { parseRelayJoinLink } from '../core/device-link/RelayJoinLink';
import { harmonyV12String } from '../core/HarmonyStrings';
import { UI_RADIUS_CONTAINER, uiFontSize } from './UiKit';

@Component
export struct RelaySettingsPanel {
  @Prop joinOnly: boolean = false;
  @Prop offerJson: string = '';
  @State private directoryLoading: boolean = false;
  @State private directoryIssue: boolean = false;
  @State private directoryOpen: boolean = false;
  @State private joined: boolean = false;
  @State private selectedOffer: RelayAccountOffer = new RelayAccountOffer();
  @State private uri: string = '';
  @State private busy: boolean = false;
  @State private code: string = '';
  @State private issue: string = '';
  @State private name: string = '';
  @State private address: string = '';
  @State private encrypted: boolean = false;
  @State private preferAgentNet: boolean = false;
  @State private canToggle: boolean = false;
  @State private custom: boolean = false;
  @State private editing: boolean = false;
  @State private offers: RelayAccountOffer[] = [];
  @State private phase: string = '';
  private presetSeed: string = '';
  private epoch: number = -1;
  private mounted: boolean = false;
  private generation: number = 0;
  private enrollment: RelayEnrollment = new RelayEnrollment();
  private unsubscribe: (() => void) | undefined;

  aboutToAppear(): void {
    this.mounted = true;
    this.epoch = AppServices.instance.auth.sessionEpoch;
    this.uri = AppServices.instance.takePendingRelayLink();
    this.editing = this.uri.length > 0;
    this.sync();
    if (this.joinOnly && this.offerJson) {
      this.selectedOffer = JSON.parse(this.offerJson) as RelayAccountOffer;
      void this.joinOffer(this.selectedOffer);
    } else void this.loadOffers();
    this.unsubscribe = AppServices.instance.onStatus(() => this.sync());
  }
  aboutToDisappear(): void {
    this.mounted = false;
    this.generation += 1;
    this.unsubscribe?.();
    this.uri = '';
    this.presetSeed = '';
  }
  private label(key: string): string {
    return harmonyV12String(this.getUIContext().getHostContext(), key);
  }
  private sync(): void {
    const route = RelayRoute.instance;
    this.name = route.legacy?.name ?? (route.agentNet ? (route.agentNet.name || this.label('relay_custom')) : this.label('relay_official'));
    this.address = route.custom ? route.apiBase : '';
    this.encrypted = route.agentNet !== undefined;
    this.canToggle = route.canToggleEncryption;
    this.custom = route.custom;
    if (route.issue) this.issue = this.label('relay_load_failed');
  }
  private current(generation: number): void {
    if (!this.mounted || generation !== this.generation || this.epoch !== AppServices.instance.auth.sessionEpoch) {
      throw new Error('RELAY_CANCELLED');
    }
  }
  private directory(generation: number): RelayAccountDirectory {
    return new RelayAccountDirectory(() => AppServices.instance.auth.getAccessToken(), () => this.current(generation),
      () => AppServices.instance.auth.forceRefreshToken());
  }
  private async loadOffers(): Promise<void> {
    if (this.directoryLoading || this.busy) return;
    this.directoryLoading = true;
    this.directoryIssue = false;
    const generation = this.generation;
    try {
      const offers = await this.directory(generation).offers();
      this.current(generation);
      this.offers = offers;
    } catch (_error) {
      if (this.mounted && generation === this.generation) this.directoryIssue = true;
    } finally {
      if (this.mounted) this.directoryLoading = false;
    }
  }
  private async joinOffer(offer: RelayAccountOffer): Promise<void> {
    if (this.busy) return;
    const generation = ++this.generation;
    this.busy = true;
    this.issue = '';
    this.code = '';
    this.editing = false;
    this.phase = 'account_invite';
    try {
      const services = AppServices.instance;
      const deviceId = await services.auth.ensureDeviceId();
      this.current(generation);
      const invite = await this.directory(generation).invite(offer, deviceId, services.getSelfDeviceName() || 'Cindy Harmony');
      this.current(generation);
      this.phase = 'enrollment';
      this.uri = invite.uri;
      this.presetSeed = invite.seed;
      this.busy = false;
      await this.join();
    } catch (_error) {
      if (this.mounted && generation === this.generation) this.reportFailure(_error);
    } finally {
      if (this.mounted && generation === this.generation) this.busy = false;
    }
  }
  private async join(): Promise<void> {
    if (this.busy || !this.uri.trim()) return;
    const uri = this.uri;
    if (parseRelayJoinLink(uri) === null) {
      this.issue = this.label('relay_invalid');
      return;
    }
    const services = AppServices.instance;
    const generation = ++this.generation;
    this.busy = true;
    this.issue = '';
    this.code = '';
    try {
      const account = new RelayEnrollmentAccount();
      account.realm = AppConfig.region;
      account.accountId = services.auth.cacheAccountId;
      account.deviceId = await services.auth.ensureDeviceId();
      account.deviceName = services.getSelfDeviceName() || 'Cindy Harmony';
      this.current(generation);
      await this.enrollment.join(uri, account, () => this.current(generation), (code: string) => {
        this.current(generation);
        this.uri = '';
        this.presetSeed = '';
        this.code = code;
      }, this.preferAgentNet, this.presetSeed);
      this.current(generation);
      this.phase = 'activation';
      await services.activateRelay(true);
      this.current(generation);
      this.joined = true;
      this.editing = false;
      this.uri = '';
      this.code = '';
      this.sync();
    } catch (error) {
      if (this.mounted && this.epoch === services.auth.sessionEpoch && generation === this.generation) {
        const message = error instanceof Error ? error.message : '';
        const key = /OWNER_MISMATCH/.test(message) ? 'relay_owner_mismatch'
          : /ACCOUNT_INVITATION/.test(message) ? 'relay_account_invitation'
          : /REJECTED/.test(message) ? 'relay_rejected'
          : /EXPIRED|CODE_INVALID/.test(message) ? 'relay_expired' : 'relay_join_failed';
        this.issue = this.label(key);
        this.reportFailure(error);
      }
    } finally {
      if (generation === this.generation && this.mounted) this.busy = false;
    }
  }
  private reportFailure(error: Object): void {
    const message = error instanceof Error ? error.message : '';
    const safe = /^[A-Z][A-Z0-9_]{2,100}$/.test(message) ? message : (error instanceof Error ? error.name : 'UNKNOWN');
    hilog.warn(0, 'CindyRelay', 'join stage=%{public}s code=%{public}s', this.phase, safe);
    this.issue = this.label(safe === 'RELAY_OWNER_UNAVAILABLE' ? 'relay_owner_unavailable' : 'relay_account_failed');
  }
  private cancel(): void {
    this.generation += 1;
    this.busy = false;
    this.editing = false;
    this.uri = '';
    this.presetSeed = '';
    this.code = '';
    this.issue = '';
    // A consumed code is never retried automatically; credentials already saved remain account scoped.
  }
  private async encryption(enabled: boolean): Promise<void> {
    if (this.busy || !this.canToggle) return;
    const generation = ++this.generation;
    this.busy = true;
    this.issue = '';
    try {
      await RelayRoute.instance.setEncryption(AppServices.instance.auth.cacheAccountId, enabled);
      this.current(generation);
      await AppServices.instance.activateRelay(true);
      this.current(generation);
      this.sync();
    } catch (_error) {
      if (this.mounted && generation === this.generation) this.issue = this.label('relay_switch_failed');
    } finally {
      if (this.mounted && generation === this.generation) this.busy = false;
    }
  }
  private async official(): Promise<void> {
    if (this.busy) return;
    const generation = ++this.generation;
    this.busy = true;
    this.issue = '';
    try {
      await AppServices.instance.useOfficialRelay();
      this.current(generation);
      this.sync();
    } catch (_error) {
      if (this.mounted) this.issue = this.label('relay_switch_failed');
    } finally {
      if (this.mounted) this.busy = false;
    }
  }

  @Builder
  settingsBody() {
    Column({ space: 20 }) {
      UiListGroup({ heading: this.label('relay_service'), footer: this.label(this.encrypted ? 'relay_encrypted' : 'relay_boundary') }) {
        UiListRow({ label: this.label('relay_service'), value: this.name })
        if (this.custom || RelayRoute.instance.issue) {
          UiListRow({ label: this.label('relay_switch_official'), onRowClick: () => { if (!this.busy) void this.official(); } })
        }
        ForEach(this.offers, (offer: RelayAccountOffer) => {
          UiListRow({ label: offer.name, value: offer.ownerDeviceName, showChevron: true,
            onRowClick: () => { if (!this.busy) router.pushUrl({ url: 'pages/RelayJoinPage', params: { offer: JSON.stringify(offer) } }); } })
        }, (offer: RelayAccountOffer) => offer.ownerDeviceId)
        if (this.offers.length === 0) {
          UiListRow({ label: this.label('relay_custom'), value: this.directoryLoading ? this.label('relay_loading') : this.label('relay_retry'),
            showChevron: true, onRowClick: () => { this.directoryOpen = true; void this.loadOffers(); } })
        }
        if (this.directoryIssue) {
          Text(this.label('relay_directory_failed')).fontSize(uiFontSize(13)).fontColor($r('app.color.danger')).padding(16).width('100%')
        } else if (this.directoryOpen && !this.directoryLoading && this.offers.length === 0) {
          Text(this.label('relay_directory_empty')).fontSize(uiFontSize(13)).fontColor($r('app.color.text_secondary')).padding(16).width('100%')
        }
        UiListRow({ label: this.label('relay_share_join'), showChevron: true,
          onRowClick: () => { if (!this.busy) this.editing = !this.editing; } })
        if (this.editing) {
          Column({ space: 12 }) {
            TextArea({ text: this.uri, placeholder: this.label('relay_link') }).height(100).maxLength(2048).enabled(!this.busy)
              .onChange((value: string) => { this.uri = value; this.presetSeed = ''; })
            UiActionButton({ label: this.label('relay_submit'), kind: UiActionKind.Primary,
              actionEnabled: !this.busy && this.uri.trim().length > 0, onAction: () => void this.join() })
            if (this.code) { Text(this.code).fontSize(uiFontSize(28)).fontColor($r('app.color.text_primary')) }
            if (this.issue) { Text(this.issue).fontSize(uiFontSize(13)).fontColor($r('app.color.danger')) }
          }.padding(16).width('100%')
        }
      }
      if (this.custom) {
        UiListGroup({ heading: 'Agent-Net', footer: this.label('relay_encryption_note') }) {
          Row({ space: 12 }) {
            Text(this.label('relay_enable_encryption')).fontSize(uiFontSize(14)).fontColor($r('app.color.text_primary')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.encrypted }).enabled(this.canToggle && !this.busy)
              .onChange((enabled: boolean) => { if (enabled !== this.encrypted) void this.encryption(enabled); })
          }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 16, right: 12, top: 8, bottom: 8 })
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    if (this.joinOnly) {
      Column({ space: 20 }) {
        UiPanelHeading({ heading: this.joined ? this.label('relay_joined') : this.selectedOffer.name })
        if (!this.joined) {
          Text(this.selectedOffer.baseUrl).fontSize(uiFontSize(14)).fontColor($r('app.color.text_secondary'))
          Text(this.selectedOffer.ownerDeviceName).fontSize(uiFontSize(14)).fontColor($r('app.color.text_secondary'))
        }
        if (this.busy) {
          LoadingProgress().width(28).height(28)
          Text(this.label('relay_account_waiting')).fontColor($r('app.color.text_secondary'))
          UiActionButton({ label: this.label('relay_cancel'), onAction: () => { this.cancel(); router.back(); } })
        } else if (this.joined) {
          Text(this.label('relay_joined_note')).fontColor($r('app.color.text_secondary'))
          UiActionButton({ label: this.label('relay_done'), onAction: () => router.back() })
        } else if (this.issue) {
          UiInlineError({ message: this.issue })
          UiActionButton({ label: this.label('relay_retry'), onAction: () => void this.joinOffer(this.selectedOffer) })
        }
      }.width('100%').alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Start).padding({ top: 32, bottom: 24, left: 24, right: 24 })
    } else {
      this.settingsBody()
    }
  }

}
