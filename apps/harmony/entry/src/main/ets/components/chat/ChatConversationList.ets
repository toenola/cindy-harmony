import { ChatActor, ChatRoom } from '../../core/chat/ChatModels';
import { ChatStrings } from '../../core/chat/ChatStrings';
import { ChatConversationSummary } from '../../core/chat/ChatConversationSummary';
import { ChatListRow, chatListRows } from '../../core/chat/ChatListPresentation';
import { TeammateRosterEntry } from '../../core/tasks/TeammateRoster';
import { UI_RADIUS_CONTROL, UI_RADIUS_PILL } from '../UiKit';

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
      TextInput({ text: this.query, placeholder: this.labels.search })
        .height(40).fontSize(15).fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_placeholder'))
        .backgroundColor($r('app.color.bg_chip')).borderRadius(UI_RADIUS_CONTROL)
        .margin({ left: 16, right: 16 }).constraintSize({ maxWidth: '100%' })
        .onChange((value: string): void => { this.query = value; })
      List() {
        ForEach(chatListRows(this.actors, this.rooms, this.summaries, this.query, this.localCompanions), (row: ChatListRow) => {
          ListItem() {
            Row({ space: 12 }) {
              if (/^https:\/\/[^/]*[^@]\//.test(row.avatar) && !/^https:\/\/[^/]*@/.test(row.avatar)) {
                Image(row.avatar).width(44).height(44).borderRadius(22).objectFit(ImageFit.Cover).flexShrink(0)
              } else {
                Text(Array.from(row.title)[0] ?? '').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
                  .width(44).height(44).textAlign(TextAlign.Center).borderRadius(22).backgroundColor($r('app.color.bg_chip')).flexShrink(0)
              }
              Column({ space: 2 }) {
                Text(row.title).fontSize(16).lineHeight(22).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(row.summary || (row.deviceId ? this.deviceName(row.deviceId) || this.labels.cloud : this.labels.cloud))
                  .fontSize(13).lineHeight(18).fontColor($r('app.color.text_secondary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (row.hasUnread) {
                if (row.unread > 0) {
                  Text(String(row.unread)).fontSize(11).fontColor($r('app.color.chat_cta_text')).backgroundColor($r('app.color.chat_cta'))
                    .borderRadius(UI_RADIUS_PILL).padding({ left: 6, right: 6 }).constraintSize({ minWidth: 18 }).height(18).textAlign(TextAlign.Center)
                } else {
                  Circle().width(8).height(8).fill($r('app.color.accent'))
                }
              }
            }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 }).constraintSize({ minHeight: 68 })
            .alignItems(VerticalAlign.Center).onClick((): void => this.open(row))
          }.onVisibleAreaChange([0, 0.5], (visible: boolean, ratio: number): void => { if (visible && ratio >= 0.5 && row.kind === 'group') this.onVisibleGroups([row.id]); })
        }, (row: ChatListRow): string => row.key)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      .divider({ strokeWidth: 0.5, color: $r('app.color.border'), startMargin: 72, endMargin: 16 })
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
