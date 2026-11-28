import { chatErrorText } from '../../core/chat/ChatStrings';
import { ChatInvitationStore } from '../../core/chat/ChatInvitationStore';

@Component
export struct ChatInvitePanel {
  @Prop locale:string='zh-CN';
  @Prop @Watch('syncInitialInput') initialInput:string='';
  private syncInitialInput():void{this.input=this.initialInput;}
  store: ChatInvitationStore | null = null;
  @Prop inputLabel: string = '';
  @Prop previewLabel: string = '';
  @Prop acceptLabel: string = '';
  @Prop openLabel: string = '';
  @Prop retryLabel: string = '';
  @Prop uncertainLabel: string = '';
  onJoined: (groupId: string) => void = (_groupId: string): void => {};
  @State private input: string = '';
  @State private version: number = 0;
  private mounted: boolean = false;
  private off: (() => void) | null = null;
  aboutToAppear(): void {
    this.mounted = true;this.syncInitialInput(); this.off = this.store?.onChanged((): void => { if (this.mounted) this.version++; }) ?? null;
  }
  aboutToDisappear(): void { this.mounted = false; this.off?.(); this.off = null; }
  private async accept(): Promise<void> {
    const store = this.store; if (!store) return;
    await store.accept();
    if (this.mounted && store === this.store && store.phase === 'joined' && store.joinedRoom) this.onJoined(store.joinedRoom);
  }
  build() {
    Column({ space: 12 }) {
      TextInput({ text: this.input, placeholder: this.inputLabel }).height(44)
        .fontColor($r('app.color.text_primary')).enabled(this.store?.phase !== 'joining' && this.store?.phase !== 'reading')
        .onChange((value: string): void => { this.input = value; })
      Button(this.previewLabel).height(44).enabled(!!this.input.trim() && this.store?.phase !== 'joining' && this.store?.phase !== 'reading')
        .onClick((): void => { this.store?.read(this.input); })
      if (this.version >= 0 && (this.store?.phase === 'reading' || this.store?.phase === 'joining')) { LoadingProgress().width(32).height(32) }
      if (this.version >= 0 && this.store?.preview) {
        Text(this.store.preview.name).fontSize(18).fontColor($r('app.color.text_primary'))
        Text(this.store.preview.inviterName).fontColor($r('app.color.text_secondary'))
        if (this.store.phase === 'uncertain') { Text(this.uncertainLabel).fontColor($r('app.color.warn')) }
        if (this.store.phase === 'preview' || this.store.phase === 'uncertain') {
          Button(this.store.preview.joined ? this.openLabel : this.store.phase === 'uncertain' ? this.retryLabel : this.acceptLabel)
            .height(44).onClick((): void => { this.accept(); })
        }
        if (this.store.phase === 'joined' && this.store.joinedRoom) {
          Button(this.openLabel).height(44).onClick((): void => {
            const room=this.store?.joinedRoom;if(room)this.onJoined(room);
          })
        }
      }
      if (this.version >= 0 && this.store?.error) { Text(chatErrorText(this.locale,this.store.error)).fontColor($r('app.color.danger')) }
    }.padding(16).width('100%').backgroundColor($r('app.color.bg_page'))
  }
}
