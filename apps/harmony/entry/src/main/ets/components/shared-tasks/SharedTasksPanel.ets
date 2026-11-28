import { SharedTasksStore } from '../../core/shared-tasks/SharedTasksStore';
import { UnavailableSharedTasksHost, SharedTaskItem, SharedTaskMember } from '../../core/shared-tasks/SharedTaskModels';
import { SharedTaskAccess } from '../../core/shared-tasks/SharedTaskAccess';
import { SharedTaskLabels } from './SharedTaskStrings';

/** A management surface; the original task screen owns messages, queue and composer. */
@Component
export struct SharedTasksPanel {
  store: SharedTasksStore = new SharedTasksStore(new UnavailableSharedTasksHost());
  labels: SharedTaskLabels = new SharedTaskLabels();
  ownerDeviceId: string = '';
  ownerSessionId: string = '';
  initialInvitation: string = '';
  onOpenGuest: (access: SharedTaskAccess) => void = (): void => {};
  onCopy: (invitation: string) => Promise<void> = async (): Promise<void> => {};
  @State private revision: number = 0;
  @State private tabOwned: boolean = true;
  @State private input: string = '';
  @State private joinOpen: boolean = false;
  @State private selected: boolean = false;
  private unsubscribe: (() => void) | null = null;
  private lastAccess: SharedTaskAccess | null = null;
  aboutToAppear(): void {
    this.unsubscribe = this.store.onChanged((): void => {
      this.revision++;
      if (this.store.access && this.lastAccess !== this.store.access) {
        this.lastAccess = this.store.access; this.store.setTaskVisible(true); this.onOpenGuest(this.store.access);
      }
    });
    // An explicit incoming link only prefills the form; joining still requires the button.
    if (this.initialInvitation) { this.input = this.initialInvitation; this.joinOpen = true; }
    if (this.ownerDeviceId && this.ownerSessionId) { this.selected = true; this.store.selectOwnerTask(this.ownerDeviceId, this.ownerSessionId); }
    this.store.setVisible(true);
  }
  aboutToDisappear(): void { this.unsubscribe?.(); this.unsubscribe = null; this.store.setVisible(false); this.input = ''; this.joinOpen = false; }
  private confirm(title: string, action: () => void): void {
    this.getUIContext().showAlertDialog({ title, message: this.labels.confirmBody,
      primaryButton: { value: this.labels.cancel, action: (): void => {} },
      secondaryButton: { value: this.labels.confirm, action } });
  }
  build() {
    Column({ space: 12 }) {
      if (this.revision >= 0) {
        Row({ space: 8 }) {
          if (this.selected) { Button(this.labels.back).height(44).onClick((): void => { this.selected = false; this.store.showList(); }) }
          Text(this.labels.title).fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Button(this.labels.join).height(44).enabled(!this.store.busy).onClick((): void => { this.joinOpen = !this.joinOpen; this.input = ''; })
        }.width('100%')
        if (this.store.issue) { Text(this.labels.issue(this.store.issue)).fontSize(14).fontColor($r('app.color.text_secondary')) }
        if (this.store.loading || this.store.busy) { LoadingProgress().width(28).height(28) }
        if (this.joinOpen) {
          TextArea({ text: this.input, placeholder: this.labels.invitation }).height(100).maxLength(8192).enabled(!this.store.busy)
            .onChange((value: string): void => { this.input = value; })
          Row({ space: 8 }) {
            Button(this.labels.cancel).height(44).onClick((): void => { this.input = ''; this.joinOpen = false; })
            Button(this.labels.join).height(44).enabled(!this.store.busy && !!this.input.trim()).onClick((): void => {
              void this.store.join(this.input).then((): void => { if (this.store.access) { this.input = ''; this.joinOpen = false; } });
            })
          }
        }
        Button(this.labels.refresh).height(44).enabled(!this.store.loading && !this.store.busy).onClick((): void => { void this.store.refresh(); })
        if (this.selected && this.store.detail) {
          Text(this.store.detail.title).fontSize(18).fontColor($r('app.color.text_primary'))
          Button(this.labels.open).height(44).enabled(!this.store.busy).onClick((): void => { if (this.store.detail) void this.store.open(this.store.detail.sharedTaskId); })
          if (this.store.isOwner()) {
            Button(this.labels.invite).height(44).enabled(!this.store.busy).onClick((): void => { void this.store.invite(); })
            if (this.store.invitation) {
              Button(this.labels.copy).height(44).onClick((): void => { void this.onCopy(this.store.invitation).catch((): void => { this.store.issue = 'failed'; this.revision++; }); })
            }
            Text(this.labels.members).fontSize(14).fontColor($r('app.color.text_secondary'))
            List({ space: 8 }) {
              ForEach(this.store.detail.guests, (member: SharedTaskMember) => {
                ListItem() {
                  Row({ space: 8 }) {
                    Text(member.displayName).fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
                    Button(this.labels.remove).height(44).enabled(!this.store.busy).onClick((): void => this.confirm(this.labels.remove, (): void => { void this.store.remove(member.memberId); }))
                  }.width('100%')
                }
              }, (member: SharedTaskMember): string => member.memberId)
            }.layoutWeight(1)
            Button(this.labels.stop).height(44).fontColor($r('app.color.danger')).enabled(!this.store.busy)
              .onClick((): void => this.confirm(this.labels.stop, (): void => { void this.store.closeSharing(); }))
          } else {
            Button(this.labels.leave).height(44).fontColor($r('app.color.danger')).enabled(!this.store.busy)
              .onClick((): void => this.confirm(this.labels.leave, (): void => { void this.store.leave(); }))
          }
        } else if (this.selected && this.ownerSessionId && !this.store.ended && !this.store.issue) {
          Button(this.labels.share).height(44).enabled(!this.store.busy && this.store.loaded).onClick((): void => { void this.store.start(); })
        } else if (!this.selected) {
          Row({ space: 8 }) {
            Button(this.labels.owned).height(44).onClick((): void => { this.tabOwned = true; })
            Button(this.labels.joined).height(44).onClick((): void => { this.tabOwned = false; })
          }
          List({ space: 8 }) {
            ForEach(this.tabOwned ? this.store.owned() : this.store.joined(), (item: SharedTaskItem) => {
              ListItem() {
                Row({ space: 8 }) {
                  Text(item.title).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
                  Button(this.labels.manage).height(44).onClick((): void => { this.selected = true; this.store.select(item.sharedTaskId); })
                  Button(this.labels.open).height(44).enabled(!this.store.busy).onClick((): void => { void this.store.open(item.sharedTaskId); })
                }.width('100%')
              }
            }, (item: SharedTaskItem): string => item.sharedTaskId)
            if (this.store.loaded && !(this.tabOwned ? this.store.owned() : this.store.joined()).length) { ListItem() { Text(this.labels.empty).fontColor($r('app.color.text_secondary')) } }
          }.layoutWeight(1).width('100%')
        }
      }
    }.width('100%').height('100%').padding(16).backgroundColor($r('app.color.bg_page'))
  }
}
