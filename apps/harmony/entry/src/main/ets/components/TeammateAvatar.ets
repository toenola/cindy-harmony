import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppServices } from '../core/AppServices';
import { TeammateRosterEntry } from '../core/tasks/TeammateRoster';

@Component
export struct TeammateAvatar {
  @Prop @Watch('avatarChanged') teammate: TeammateRosterEntry = new TeammateRosterEntry();
  @Prop @Watch('avatarChanged') online: boolean = false;
  @Prop diameter: number = 28;
  @State private accountCurrent: boolean = true;
  @State private source: string = '';
  private revision: number = 0;
  private identity: string = '';
  private visible: boolean = false;
  private inFlight: boolean = false;
  private retries: number = 0;
  private attempted: boolean = false;
  private retryTimer: number = -1;
  private wasOnline: boolean = false;
  private request: Promise<string> | undefined = undefined;
  private ownerEpoch: number = -1;
  private unsubscribeAuth: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.ownerEpoch = AppServices.instance.auth.sessionEpoch;
    this.unsubscribeAuth = AppServices.instance.auth.onChanged(() => this.avatarChanged());
    this.avatarChanged();
  }

  aboutToDisappear(): void {
    this.revision += 1;
    this.visible = false;
    this.clearRetry();
    this.unsubscribeAuth?.();
  }

  private clearRetry(): void {
    if (this.retryTimer >= 0) clearTimeout(this.retryTimer);
    this.retryTimer = -1;
  }

  private scheduleRetry(): void {
    if (!this.accountCurrent || !this.visible || !this.online || this.retryTimer >= 0 || this.retries >= 1) return;
    this.retries++;
    const revision = this.revision;
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (revision === this.revision) { this.attempted = false; this.avatarChanged(); }
    }, 750);
  }

  private avatarChanged(): void {
    const services = AppServices.instance;
    const epoch = services.auth.sessionEpoch;
    this.accountCurrent = epoch === this.ownerEpoch;
    const row = this.teammate;
    const identity = JSON.stringify([epoch, row.deviceId, row.avatarKind, row.avatarValue]);
    if (this.identity !== identity) {
      this.identity = identity;
      this.revision++;
      this.inFlight = false;
      this.request = undefined;
      this.source = '';
      this.retries = 0;
      this.attempted = false;
      this.clearRetry();
    }
    if (this.online && !this.wasOnline) { this.retries = 0; this.attempted = false; }
    if (!this.online) this.clearRetry();
    this.wasOnline = this.online;
    if (!this.accountCurrent || !this.visible || !this.online || this.source || this.inFlight ||
      this.retryTimer >= 0 || this.attempted || row.avatarKind !== 'media') return;
    const revision = this.revision;
    this.inFlight = true;
    this.attempted = true;
    const request = services.teammateAvatarSource(row.deviceId, row.avatarValue);
    this.request = request;
    void request.then((source: string): void => {
      if (revision !== this.revision || epoch !== services.auth.sessionEpoch) return;
      this.inFlight = false;
      if (source) this.source = source;
      else this.scheduleRetry();
    }).catch((): void => {
      if (revision !== this.revision || epoch !== services.auth.sessionEpoch) return;
      this.inFlight = false;
      hilog.debug(0, 'CindyCompanionPerf', 'avatar_failure reason=request_rejected');
      this.scheduleRetry();
    });
  }

  private avatarImageFailed(): void {
    if (!this.source || !this.accountCurrent) return;
    hilog.debug(0, 'CindyCompanionPerf', 'avatar_failure reason=image_decode_or_download');
    const request = this.request;
    if (request !== undefined) {
      AppServices.instance.invalidateTeammateAvatarSource(this.teammate.deviceId, this.teammate.avatarValue, request);
    }
    this.source = '';
    this.scheduleRetry();
  }

  private preset(): Resource | undefined {
    if (this.teammate.avatarKind !== 'asset') return undefined;
    switch (this.teammate.avatarValue) {
      case 'cindy://avatar/preset/cindy': return $r('app.media.teammate_preset_cindy');
      case 'cindy://avatar/preset/dash': return $r('app.media.teammate_preset_dash');
      case 'cindy://avatar/preset/lizi': return $r('app.media.teammate_preset_lizi');
      default: return undefined;
    }
  }

  private imageSource(): ResourceStr {
    return this.source || this.preset() || '';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.accountCurrent && this.imageSource()) {
        Image(this.imageSource())
          .width('100%').height('100%').objectFit(ImageFit.Cover)
          .onError((): void => this.avatarImageFailed())
      } else if (this.accountCurrent) {
        Text(this.teammate.avatarKind === 'emoji' && this.teammate.avatarValue
          ? this.teammate.avatarValue : this.teammate.avatarFallback)
          .fontSize(`${Math.round(this.diameter / 2)}fp`).maxFontScale(1).maxLines(1).fontColor($r('app.color.text_primary'))
      }
    }
    .width(this.diameter).height(this.diameter).borderRadius(this.diameter / 2).clip(true)
    .onVisibleAreaChange([0, 0.01], (visible: boolean, ratio: number) => {
      const next = visible && ratio > 0;
      if (this.visible === next) return;
      this.visible = next;
      if (next) { this.retries = 0; this.attempted = false; }
      else this.clearRetry();
      this.avatarChanged();
    })
    .backgroundColor($r('app.color.bg_chip')).accessibilityLevel('no')
  }
}
