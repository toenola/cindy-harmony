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
  private ownerEpoch: number = -1;
  private unsubscribeAuth: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.ownerEpoch = AppServices.instance.auth.sessionEpoch;
    this.unsubscribeAuth = AppServices.instance.auth.onChanged(() => this.avatarChanged());
    this.avatarChanged();
  }

  aboutToDisappear(): void {
    this.revision += 1;
    this.unsubscribeAuth?.();
  }

  private avatarChanged(): void {
    const services = AppServices.instance;
    const epoch = services.auth.sessionEpoch;
    this.accountCurrent = epoch === this.ownerEpoch;
    const row = this.teammate;
    const identity = JSON.stringify([epoch, row.deviceId, row.avatarKind, row.avatarValue]);
    if (this.identity !== identity) {
      this.identity = identity;
      this.source = '';
    }
    const revision = ++this.revision;
    if (!this.accountCurrent || !this.visible || !this.online || this.source || row.avatarKind !== 'media') return;
    void services.teammateAvatarSource(row.deviceId, row.avatarValue).then((source: string) => {
      if (revision === this.revision && epoch === services.auth.sessionEpoch) this.source = source;
    });
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
          .onError(() => { this.source = ''; })
      } else if (this.accountCurrent) {
        Text(this.teammate.avatarKind === 'emoji' && this.teammate.avatarValue
          ? this.teammate.avatarValue : this.teammate.avatarFallback)
          .fontSize(Math.round(this.diameter / 2)).maxLines(1).fontColor($r('app.color.text_primary'))
      }
    }
    .width(this.diameter).height(this.diameter).borderRadius(this.diameter / 2).clip(true)
    .onVisibleAreaChange([0, 0.01], (visible: boolean, ratio: number) => {
      this.visible = visible && ratio > 0;
      this.avatarChanged();
    })
    .backgroundColor($r('app.color.bg_chip')).accessibilityLevel('no')
  }
}
