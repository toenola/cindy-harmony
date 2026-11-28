import { UiActionButton, UiActionKind, UiIconButton } from '../../components/common/UiActions';
import { UiPanelHeading } from '../../components/common/UiNavigation';
import { UiInlineError } from '../../components/common/UiStatus';
import { ComposerImage } from '../../components/ConversationComposer';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ChatResourceStore, ChatHostMessage, ChatHostPending } from '../../core/chat/ChatResourceStore';
import { ChatResource, ChatResourceBlock } from '../../core/chat/ChatResourceAdapter';
import { ComposerFileQueue, ComposerFile } from '../../core/attachments/ComposerFileQueue';
import { ComposerImageQueue } from '../../core/attachments/ComposerImageQueue';
import { RemoteSerializedAttachment, RemoteImageRef } from '../../core/attachments/AttachmentModels';
import { chatActionStrings, chatStrings, chatErrorText } from '../../core/chat/ChatStrings';
import { ChatHostAttachment, ChatHostMediaResolver, ChatHostMediaOpen, ChatHostThumbnailQueue } from '../../core/chat/ChatHostMedia';
import { ChatHostAttachmentRow } from '../../components/chat/ChatHostAttachmentRow';
import { ChatDraftText, consumeChatDraftText } from '../../core/chat/ChatDraftHandoff';

/** Host resource groups keep their existing path. Cloud-only topic/reaction controls are not fabricated. */
@Component
export struct ChatResourceWorkspace {
  store: ChatResourceStore | null = null;
  @Prop locale: string = 'zh-CN';
  @Prop @Watch('foregroundChanged') foreground: boolean = true;
  resolveHostMedia: ChatHostMediaResolver = async (_device: string, _reference: string, _thumbnail: boolean): Promise<string> => '';
  onHostMedia: ChatHostMediaOpen = (_device: string, _reference: string, _name: string, _mime: string): void => {};
  onBack: () => void = (): void => {};
  onSettings: (resource: ChatResource) => void = (_resource: ChatResource): void => {};
  @State private version: number = 0;
  @State private draft: string = '';
  private draftRevision: number = 0;
  @State private sending: boolean = false;
  @State private error: string = '';
  @State private images: ComposerImage[] = [];
  @State private files: ComposerFile[] = [];
  private imageQueue: ComposerImageQueue = new ComposerImageQueue();
  private fileQueue: ComposerFileQueue = new ComposerFileQueue();
  private visibleIds: Set<string> = new Set();
  private atEnd: boolean = false;
  private async readVisible(): Promise<void> { try { await this.store?.markRead(Array.from(this.visibleIds), this.atEnd, this.foreground); } catch (_) {} }
  private off: (() => void) | null = null;
  private alive: boolean = false;
  private media: ChatHostThumbnailQueue | null = null;
  private foregroundChanged(): void { if (!this.foreground) this.media?.reset(); }
  aboutToAppear(): void {
    this.alive = true;
    const store = this.store;
    this.media = new ChatHostThumbnailQueue(this.resolveHostMedia, (): boolean => this.alive && this.foreground && this.store === store && (store?.isActive() ?? false));
    this.off = this.store?.onChanged((): void => { this.version++; }) ?? null;
    this.imageQueue.targetDevice = (): string => this.store?.adapter.deviceId ?? '';
    this.fileQueue.targetDevice = (): string => this.store?.adapter.deviceId ?? '';
    this.imageQueue.isBusy = (): boolean => this.sending;
    this.fileQueue.isBusy = (): boolean => this.sending;
    this.imageQueue.occupiedByOtherAttachments = (): number => this.files.length;
    this.fileQueue.occupiedByOtherAttachments = (): number => this.images.length;
    this.imageQueue.onChanged = (rows: ComposerImage[]): void => { this.images = rows; };
    this.fileQueue.onChanged = (rows: ComposerFile[]): void => { this.files = rows; };
  }
  aboutToDisappear(): void { this.alive = false; this.media?.release(); this.media = null; this.off?.(); this.off = null; this.imageQueue.cancelPicking(); this.fileQueue.cancelPicking(); }
  private attachmentsAllowed(): boolean { return this.store?.resource?.blocks.find((b: ChatResourceBlock): boolean => b.primitive === 'bot-group-chat')?.data['supportsAttachments'] === true; }
  private title(): string { const value = this.store?.resource?.blocks.find((b: ChatResourceBlock): boolean => b.primitive === 'bot-group-chat')?.data['name']; return typeof value === 'string' ? value : chatStrings(this.locale).groups; }
  private async send(): Promise<void> {
    const store = this.store; if (!store || this.sending || !this.imageQueue.allSettled() || !this.fileQueue.allSettled()) return;
    this.sending = true; const sent: ChatDraftText = { text: this.draft, revision: this.draftRevision };
    const attachments = this.fileQueue.readyFiles().slice();
    this.imageQueue.readyImages().forEach((image: RemoteImageRef): void => {
      const file = new RemoteSerializedAttachment(); file.id = util.generateRandomUUID(); file.name = image.originalName; file.path = image.url;
      file.mimeType = image.mimeType; file.size = image.size; file.category = 'image'; file.sha256 = image.sha256; attachments.push(file);
    });
    const imageIds = this.images.map((i: ComposerImage): string => i.localId), fileIds = this.files.map((f: ComposerFile): string => f.localId);
    try {
      await store.send(sent.text, [], util.generateRandomUUID(), attachments, (): void => {
        if (!this.alive || this.store !== store) return;
        const current: ChatDraftText = { text: this.draft, revision: this.draftRevision };
        this.draft = consumeChatDraftText(current, sent).text;
        this.imageQueue.removeSent(imageIds); this.fileQueue.removeSent(fileIds);
      }); this.error = '';
    }
    catch (e) { this.error = e instanceof Error ? e.message : 'CHAT_UNAVAILABLE'; }
    finally { this.sending = false; }
  }
  build() {
    Column({ space: 8 }) {
      Row() {
        UiIconButton({ glyph: $r('sys.symbol.chevron_left'), label: chatStrings(this.locale).back, onAction: this.onBack })
        Column() { UiPanelHeading({ heading: this.title() }) }.layoutWeight(1)
        UiIconButton({ glyph: $r('sys.symbol.arrow_clockwise'), label: chatStrings(this.locale).refresh,
          onAction: (): void => { this.store?.refresh(); } })
        if (this.version >= 0 && this.store?.resource) {
          UiIconButton({ glyph: $r('sys.symbol.gearshape'), label: chatStrings(this.locale).settings,
            onAction: (): void => { if (this.store?.resource) this.onSettings(this.store.resource); } })
        }
      }.width('100%')
      if (this.error || this.store?.error) {
        UiInlineError({ message: chatErrorText(this.locale, this.error || this.store?.error || '') })
      }
      List({ space: 12 }) {
        ForEach(this.version >= 0 ? this.store?.messages.filter((m: ChatHostMessage): boolean => !m.threadRootId) ?? [] : [], (message: ChatHostMessage) => {
          ListItem() {
            Column({ space: 6 }) {
              Text(message.authorName).fontSize(13).fontColor($r('app.color.text_secondary'))
              if (message.deleted || message.content) {
                Text(message.deleted ? chatStrings(this.locale).removed : message.content).fontSize(15).fontColor($r('app.color.text_primary')).copyOption(CopyOptions.LocalDevice)
              }
              ForEach(message.attachments, (attachment: ChatHostAttachment) => {
                ChatHostAttachmentRow({ attachment, deviceId: this.store?.adapter.deviceId ?? '', locale: this.locale,
                  foreground: this.foreground, queue: this.media, onOpen: this.onHostMedia })
              }, (attachment: ChatHostAttachment): string => JSON.stringify([attachment.id, attachment.reference, attachment.state, attachment.category]))
            }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
          }.onVisibleAreaChange([0,0.5,1], (visible: boolean, ratio: number): void => { if (visible && ratio>=0.5) this.visibleIds.add(message.id); else this.visibleIds.delete(message.id); this.readVisible(); })
        }, (message: ChatHostMessage): string => message.id)
      }.onScrollIndex((_start: number,end: number): void => { this.atEnd=end >= (this.store?.messages.filter((m: ChatHostMessage): boolean => !m.threadRootId).length ?? 0)-1; this.readVisible(); }).layoutWeight(1).width('100%')
      if (this.attachmentsAllowed()) {
        Flex({ wrap: FlexWrap.Wrap }) {
          Button(chatActionStrings(this.locale).photos).height(44).enabled(!this.sending).onClick((): void => { this.imageQueue.pickImages(); })
          Button(chatActionStrings(this.locale).files).height(44).enabled(!this.sending).onClick((): void => { this.fileQueue.pick(getContext(this) as common.UIAbilityContext); })
          ForEach(this.images, (image: ComposerImage) => { Button(`${image.name} ×`).height(44).enabled(!this.sending).onClick((): void => { this.imageQueue.remove(image.localId); }) }, (image: ComposerImage): string => `${image.localId}:${image.status}`)
          ForEach(this.files, (file: ComposerFile) => { Button(`${file.name} ×`).height(44).enabled(!this.sending).onClick((): void => { this.fileQueue.remove(file.localId); }) }, (file: ComposerFile): string => `${file.localId}:${file.status}`)
        }
      }
      ForEach(this.store?.pending ?? [], (pending: ChatHostPending) => {
        Row() { Text(pending.state === 'unknown' ? chatStrings(this.locale).unknown : chatErrorText(this.locale, pending.state)); Button(chatStrings(this.locale).retry).height(44).enabled(pending.state !== 'sending').onClick((): void => { this.store?.retry(pending.clientId); }) }
      }, (pending: ChatHostPending): string => pending.clientId)
      Row({ space: 8 }) {
        TextInput({ text: this.draft, placeholder: chatStrings(this.locale).message }).layoutWeight(1).onChange((value: string): void => { this.draftRevision++; this.draft = value; })
        UiActionButton({ label: chatStrings(this.locale).send, kind: UiActionKind.Primary,
          actionEnabled: !this.sending && (!!this.draft.trim() || !!this.files.length || !!this.images.length),
          onAction: (): void => { this.send(); } })
      }.width('100%')
    }.padding(12).width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
