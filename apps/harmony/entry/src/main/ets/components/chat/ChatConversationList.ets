import { UiEmptyState } from '../common/UiStatus';
import { UI_FONT_BODY, UI_FONT_LIST_TITLE, UI_FONT_SECONDARY, UI_FONT_CAPTION, UI_SPACE_TIGHT, UI_SPACE_INLINE, UI_SPACE_GROUP, UI_SPACE_PAGE, UI_TOUCH_TARGET_MIN } from '../UiKit';
import { ChatActor, ChatRoom } from '../../core/chat/ChatModels';
import { ChatStrings } from '../../core/chat/ChatStrings';
import { ChatConversationSummary } from '../../core/chat/ChatConversationSummary';
import { ChatListRow, chatListRows } from '../../core/chat/ChatListPresentation';
import { TeammateRosterEntry } from '../../core/tasks/TeammateRoster';
import { UI_RADIUS_CONTROL, UI_RADIUS_PILL } from '../UiKit';

const CHAT_AVATAR_DIAMETER = UI_TOUCH_TARGET_MIN;

@Component
export struct ChatConversationList {
  @Prop showEmpty: boolean = false;
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
  private visibleRows(): ChatListRow[] {
    return chatListRows(this.actors, this.rooms, this.summaries, this.query, this.localCompanions);
  }

  build() {
    Column({ space: UI_SPACE_INLINE }) {
      TextInput({ text: this.query, placeholder: this.labels.search })
        .constraintSize({ minHeight: UI_TOUCH_TARGET_MIN }).fontSize(UI_FONT_BODY).fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_placeholder'))
        .backgroundColor($r('app.color.bg_chip')).borderRadius(UI_RADIUS_CONTROL)
        .margin({ left: UI_SPACE_PAGE, right: UI_SPACE_PAGE }).constraintSize({ maxWidth: '100%' })
        .onChange((value: string): void => { this.query = value; })
      List() {
        if (this.showEmpty && this.visibleRows().length === 0) {
          ListItem() { UiEmptyState({ heading: this.labels.empty }) }
        }
        ForEach(this.visibleRows(), (row: ChatListRow) => {
          ListItem() {
            Row({ space: UI_SPACE_GROUP }) {
              if (/^https:\/\/[^/]*[^@]\//.test(row.avatar) && !/^https:\/\/[^/]*@/.test(row.avatar)) {
                Image(row.avatar).width(CHAT_AVATAR_DIAMETER).height(CHAT_AVATAR_DIAMETER).borderRadius(CHAT_AVATAR_DIAMETER / 2).objectFit(ImageFit.Cover).flexShrink(0)
              } else {
                Text(Array.from(row.title)[0] ?? '').fontSize(UI_FONT_LIST_TITLE).maxFontScale(1.15).maxLines(1).accessibilityLevel('no').fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
                  .width(CHAT_AVATAR_DIAMETER).height(CHAT_AVATAR_DIAMETER).textAlign(TextAlign.Center).borderRadius(CHAT_AVATAR_DIAMETER / 2).backgroundColor($r('app.color.bg_chip')).flexShrink(0)
              }
              Column({ space: UI_SPACE_TIGHT }) {
                Text(row.title).fontSize(UI_FONT_LIST_TITLE).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(row.summary || (row.deviceId ? this.deviceName(row.deviceId) || this.labels.cloud : this.labels.cloud))
                  .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (row.hasUnread) {
                if (row.unread > 0) {
                  Text(String(row.unread)).fontSize(UI_FONT_CAPTION).fontColor($r('app.color.chat_cta_text')).backgroundColor($r('app.color.chat_cta'))
                    .borderRadius(UI_RADIUS_PILL).padding({ left: 6, right: 6 }).constraintSize({ minWidth: UI_SPACE_PAGE }).constraintSize({ minHeight: UI_SPACE_PAGE }).textAlign(TextAlign.Center)
                } else {
                  Circle().width(UI_SPACE_INLINE).height(UI_SPACE_INLINE).fill($r('app.color.accent'))
                }
              }
            }.width('100%').padding({ left: UI_SPACE_PAGE, right: UI_SPACE_PAGE, top: UI_SPACE_GROUP, bottom: UI_SPACE_GROUP }).constraintSize({ minHeight: CHAT_AVATAR_DIAMETER + 2 * UI_SPACE_GROUP })
            .alignItems(VerticalAlign.Center).focusable(true).onClick((): void => this.open(row))
          }.onVisibleAreaChange([0, 0.5], (visible: boolean, ratio: number): void => { if (visible && ratio >= 0.5 && row.kind === 'group') this.onVisibleGroups([row.id]); })
        }, (row: ChatListRow): string => row.key)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      .divider({ strokeWidth: 0.5, color: $r('app.color.border'), startMargin: 72, endMargin: 16 })
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
