import { ChatActor, ChatRoom } from '../../core/chat/ChatModels';
import { ChatStrings } from '../../core/chat/ChatStrings';
import { ChatConversationSummary } from '../../core/chat/ChatConversationSummary';
import { ChatListRow, chatListRows } from '../../core/chat/ChatListPresentation';
import { TeammateRosterEntry } from '../../core/tasks/TeammateRoster';

@Component
export struct ChatConversationList {
  @Prop rooms: ChatRoom[] = [];
  @Prop actors: ChatActor[] = [];
  @Prop localCompanions: TeammateRosterEntry[] = [];
  @Prop summaries: ChatConversationSummary[] = [];
  @Prop labels: ChatStrings = new ChatStrings();
  @State private query: string = '';
  deviceName: (deviceId: string) => string = (_id: string): string => '';
  onOpenGroup: (id: string) => void = (_id: string): void => {};
  onOpenCompanion: (actor: ChatActor) => void = (_actor: ChatActor): void => {};
  onLocalCompanion: (entry: TeammateRosterEntry) => void = (_entry: TeammateRosterEntry): void => {};
  onVisibleGroups: (ids: string[]) => void = (_ids: string[]): void => {};
  private open(row: ChatListRow): void {
    if (row.kind === 'group') { this.onOpenGroup(row.id); return; }
    if (row.kind === 'local') { const local = this.localCompanions.find((e: TeammateRosterEntry): boolean => e.id === row.id && e.deviceId === row.deviceId); if (local) this.onLocalCompanion(local); return; }
    const actor = this.actors.find((a: ChatActor): boolean => a.id === row.id); if (actor) this.onOpenCompanion(actor);
  }
  build() {
    Column({ space: 8 }) {
      TextInput({ text: this.query, placeholder: this.labels.search }).height(44).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_card')).onChange((value: string): void => { this.query = value; })
      List() {
        ForEach(chatListRows(this.actors, this.rooms, this.summaries, this.query, this.localCompanions), (row: ChatListRow) => {
          ListItem() {
            Row({ space: 12 }) {
              if (/^https:\/\/[^/]*[^@]\//.test(row.avatar) && !/^https:\/\/[^/]*@/.test(row.avatar)) { Image(row.avatar).width(40).height(40).borderRadius(20).objectFit(ImageFit.Cover) }
              else { Text(Array.from(row.title)[0] ?? '').fontSize(20).width(40).height(40).textAlign(TextAlign.Center) }
              Column({ space: 4 }) {
                Text(row.title).fontColor($r('app.color.text_primary')).maxLines(1)
                Text(row.summary || (row.deviceId ? this.deviceName(row.deviceId) || this.labels.cloud : this.labels.cloud)).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (row.hasUnread) { Text(row.unread > 0 ? String(row.unread) : '•').fontColor($r('app.color.accent')) }
            }.width('100%').padding(12).constraintSize({ minHeight: 56 }).onClick((): void => this.open(row))
          }.onVisibleAreaChange([0, 0.5], (visible: boolean, ratio: number): void => { if (visible && ratio >= 0.5 && row.kind === 'group') this.onVisibleGroups([row.id]); })
        }, (row: ChatListRow): string => row.key)
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
