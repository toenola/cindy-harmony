import { ChatResourceAdapter, ChatResourceRef } from '../../core/chat/ChatResourceAdapter';
import { ChatActor } from '../../core/chat/ChatModels';
import { chatStrings, chatActionStrings, chatErrorText } from '../../core/chat/ChatStrings';
interface ChatCreateTarget { kind: string; ref?: ChatResourceRef }
interface ChatCreateEffect { kind: string; target?: ChatCreateTarget }
interface ChatCreateReceipt { effects: ChatCreateEffect[] }
/** Uses the selected real host's existing group creation action, as Mobile does. */
@Component
export struct ChatGroupCreatePanel {
  adapter: ChatResourceAdapter | null = null;
  @Prop actors: ChatActor[] = [];
  @Prop locale: string = 'zh-CN';
  onCreated: (groupId: string, deviceId: string) => void = (_group: string, _device: string): void => {};
  onReviewUnknown: () => void = (): void => {};
  @State private name: string = '';
  @State private selected: string[] = [];
  @State private busy: boolean = false;
  @State private unknown: boolean = false;
  @State private error: string = '';
  private mounted: boolean = false;
  aboutToAppear(): void { this.mounted = true; }
  aboutToDisappear(): void { this.mounted = false; }
  private async create(): Promise<void> {
    const adapter = this.adapter; if (!adapter || this.busy || this.unknown || !this.name.trim()) return;
    this.busy = true;
    try {
      const bots = this.actors.filter((a: ChatActor): boolean => this.selected.includes(a.id) && !a.disabled).map((a: ChatActor): string => a.externalId);
      const receipt = await adapter.create(this.name, bots) as ChatCreateReceipt;
      if (!this.mounted || adapter !== this.adapter) return;
      const effect = receipt?.effects?.find((e: ChatCreateEffect): boolean => e.kind === 'navigate' && e.target?.kind === 'resource'
        && e.target.ref?.collectionId === 'bot-groups' && e.target.ref.kind === 'bot-group');
      const groupId = effect?.target?.ref?.id;
      if (!groupId) { this.unknown = true; this.error = 'CREATE_RESULT_UNKNOWN'; return; }
      this.onCreated(groupId, adapter.deviceId);
    } catch (e) {
      if (this.mounted) { this.error = e instanceof Error ? e.message : 'CHAT_UNAVAILABLE'; this.unknown = !/PERMISSION|INVALID|NAME_REQUIRED|MEMBER_LIMIT/.test(this.error); }
    } finally { this.busy = false; }
  }
  build() {
    Column({ space: 12 }) {
      TextInput({ text: this.name, placeholder: chatActionStrings(this.locale).name }).height(44).enabled(!this.busy && !this.unknown).onChange((value: string): void => { this.name = value; })
      List() {
        ForEach(this.actors.filter((a: ChatActor): boolean => a.kind === 'bot' && !a.disabled && !!a.externalId), (actor: ChatActor) => {
          ListItem() {
            Row({ space: 8 }) {
              Checkbox({ name: actor.id }).select(this.selected.includes(actor.id)).enabled(!this.busy && !this.unknown)
                .onChange((selected: boolean): void => { this.selected = selected ? this.selected.concat([actor.id]) : this.selected.filter((id: string): boolean => id !== actor.id); })
              Text(actor.name).fontColor($r('app.color.text_primary')).layoutWeight(1)
            }.padding(8).constraintSize({ minHeight: 44 })
          }
        }, (actor: ChatActor): string => actor.id)
      }.layoutWeight(1).width('100%')
      if (this.error) { Text(this.unknown ? chatStrings(this.locale).unknown : chatErrorText(this.locale, this.error)).fontColor($r('app.color.warn')) }
      if (this.unknown) { Button(chatStrings(this.locale).refresh).height(44).onClick(this.onReviewUnknown) }
      else { Button(chatActionStrings(this.locale).confirm).height(44).enabled(!this.busy && !!this.name.trim() && this.adapter !== null).onClick((): void => { this.create(); }) }
    }.padding(16).width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
