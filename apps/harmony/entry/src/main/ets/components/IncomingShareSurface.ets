import { AppServices } from '../core/AppServices';
import { IncomingShareBatch, IncomingShareDestination, incomingShareText } from '../core/incoming-share/IncomingShareStore';
import { IncomingSharePreview, IncomingShareTarget, IncomingSharePreviewLabels } from '../incomingshareextension/IncomingSharePreview';
import { harmonyV12String } from '../core/HarmonyStrings';
import { uiSheetOptions, UiSheetExtras } from './common/UiOverlay';

/** One account-bound preview. Navigation follows durable adoption; it never sends. */
@Component
export struct IncomingShareSurface {
  onOpen: (target: IncomingShareDestination) => void = (): void => {};
  @Prop @Watch('refresh') activeDeviceId: string = '';
  @Prop @Watch('refresh') activeSessionId: string = '';
  @State private batch: IncomingShareBatch | null = null;
  @State private targets: IncomingShareTarget[] = [];
  @State private recovery: IncomingShareDestination | null = null;
  @State private busy: boolean = false;
  @State private error: string = '';
  private off: Array<() => void> = [];
  private alive: boolean = false;
  private copy(key: string): string { return harmonyV12String(this.getUIContext().getHostContext(), 'incoming_share_' + key); }
  private labels(): IncomingSharePreviewLabels {
    const labels = new IncomingSharePreviewLabels();
    labels.title = this.copy('title'); labels.target = this.copy('target'); labels.confirm = this.copy('confirm');
    labels.cancel = this.copy('cancel'); labels.hint = this.copy('hint'); labels.openInvite = this.copy('openInvite'); return labels;
  }
  aboutToAppear(): void {
    this.alive = true;
    const services = AppServices.instance;
    this.off.push(services.auth.onChanged((): void => this.refresh()));
    this.off.push(services.tasks.onChanged((): void => this.refresh()));
    this.off.push(services.onDeepLink((): void => this.refresh()));
    if (services.incomingShare) this.off.push(services.incomingShare.onChanged((): void => this.refresh()));
    if (services.incomingComposer) this.off.push(services.incomingComposer.onChanged((): void => this.refresh()));
    this.refresh();
  }
  aboutToDisappear(): void { this.alive = false; this.off.forEach((off: () => void): void => off()); this.off = []; }
  private refresh(): void {
    if (!this.alive) return;
    const services = AppServices.instance;
    this.batch = services.auth.isLoggedIn ? services.incomingShare?.pending() ?? null : null;
    const targets: IncomingShareTarget[] = [];
    for (const device of services.tasks.deviceList) {
      if (!device.remoteControlEnabled) continue;
      const fresh = new IncomingShareTarget(); fresh.id = JSON.stringify([device.deviceId, '']);
      fresh.deviceId = device.deviceId; fresh.label = device.deviceName + ' · ' + this.copy('newTask');
      fresh.enabled = device.online; targets.push(fresh);
      for (const session of services.tasks.getSessions(device.deviceId)) {
        if (session.status !== 'active') continue;
        const target = new IncomingShareTarget(); target.id = JSON.stringify([device.deviceId, session.id]);
        target.deviceId = device.deviceId; target.sessionId = session.id;
        target.label = session.title || this.copy('newTask'); target.detail = device.deviceName;
        target.enabled = device.online; targets.push(target);
      }
    }
    this.targets = targets;
    this.recovery = services.incomingComposer?.pendingTargets().find((target: IncomingShareDestination): boolean =>
      !(target.deviceId === this.activeDeviceId && target.sessionId === this.activeSessionId) && targets.some((row: IncomingShareTarget): boolean =>
        row.deviceId === target.deviceId && row.sessionId === target.sessionId && row.enabled)) ?? null;
  }
  private async adopt(id: string): Promise<void> {
    const services = AppServices.instance, batch = this.batch;
    const target = this.targets.find((row: IncomingShareTarget): boolean => row.id === id && row.enabled);
    const bridge = services.incomingComposer, inbox = services.incomingShare;
    if (!target || !batch || !bridge || !inbox || this.busy) return;
    const destination = new IncomingShareDestination(); destination.ownerKey = services.usageCardOwner;
    destination.deviceId = target.deviceId; destination.sessionId = target.sessionId;
    const epoch = services.auth.sessionEpoch;
    this.busy = true; this.error = '';
    try {
      await inbox.adopt(batch.id, destination, bridge);
      if (!this.alive || epoch !== services.auth.sessionEpoch) return;
      this.recovery = null; this.onOpen(destination);
    } catch (_error) { if (this.alive && epoch === services.auth.sessionEpoch) this.error = this.copy('failed'); }
    finally { if (this.alive) { this.busy = false; this.refresh(); } }
  }
  private async openInvitation(): Promise<void> {
    const services = AppServices.instance, inbox = services.incomingShare, batch = this.batch;
    if (this.busy || !inbox || !batch) return;
    const epoch = services.auth.sessionEpoch;
    this.busy = true; this.error = '';
    try {
      await inbox.openInvitation(batch.id, async (text: string, owner: string): Promise<boolean> =>
        this.alive && epoch === services.auth.sessionEpoch && owner === services.usageCardOwner && services.acceptDeepLinkUri(text));
    } catch (_error) { if (this.alive && epoch === services.auth.sessionEpoch) this.error = this.copy('failed'); }
    finally { if (this.alive) { this.busy = false; this.refresh(); } }
  }
  private async cancel(): Promise<void> {
    if (this.busy || !this.batch) return;
    const services = AppServices.instance, epoch = services.auth.sessionEpoch;
    this.busy = true; this.error = '';
    try { await services.incomingShare?.cancel(this.batch.id); }
    catch (_error) { if (this.alive && epoch === services.auth.sessionEpoch) this.error = this.copy('failed'); }
    finally { if (this.alive) { this.busy = false; this.refresh(); } }
  }
  private sheetOptions(): SheetOptions {
    const extras = new UiSheetExtras();
    extras.detents = [SheetSize.MEDIUM, SheetSize.LARGE];
    // 系统关闭按钮 / 下滑等同于「取消」；批次被取消后 isShow 变 false，表单随之收起。
    extras.onWillDismiss = (_action: DismissSheetAction): void => { void this.cancel(); };
    return uiSheetOptions(this.copy('title'), (): void => {}, SheetSize.FIT_CONTENT, extras);
  }
  @Builder
  private previewSheet() {
    Column() {
      if (this.batch !== null) {
        IncomingSharePreview({ batch: this.batch, targets: this.targets, labels: this.labels(), busy: this.busy,
          error: this.error,
          canOpenInvite: this.batch.items.length === 1 && AppServices.instance.moduleInvitationKind(incomingShareText(this.batch)).length > 0,
          onOpenInvite: (): void => { void this.openInvitation(); }, onConfirm: (id: string): void => { void this.adopt(id); },
          onCancel: (): void => { void this.cancel(); },
        })
      }
    }.width('100%').padding({ left: 16, right: 16, bottom: 16 })
  }
  build() {
    Column() {
      if (this.batch === null && this.recovery !== null) {
        Button(this.copy('resume')).height(44).margin(16)
          .onClick((): void => {
            const target = this.recovery;
            if (target !== null) { this.recovery = null; this.onOpen(target); }
          })
      }
    }.width('100%').height('100%').justifyContent(FlexAlign.End).hitTestBehavior(HitTestMode.Transparent)
      .bindSheet(this.batch !== null, this.previewSheet(), this.sheetOptions())
  }
}
