import { ChatHostAttachment, ChatHostThumbnailQueue, ChatHostMediaOpen, chatHostMediaStrings } from '../../core/chat/ChatHostMedia';
import { chatStrings } from '../../core/chat/ChatStrings';

/** Ready and unavailable attachments keep their original position within the bubble. */
@Component
export struct ChatHostAttachmentRow {
  @Prop @Watch('changed') attachment: ChatHostAttachment = { id: '', name: '', category: 'file', mimeType: '', size: 0, reference: '', state: '', annotated: false };
  @Prop deviceId: string = '';
  @Prop locale: string = 'zh-CN';
  @Prop @Watch('foregroundChanged') foreground: boolean = true;
  queue: ChatHostThumbnailQueue | null = null;
  onOpen: ChatHostMediaOpen = (_device: string, _reference: string, _name: string, _mime: string): void => {};
  @State private url: string = '';
  @State private loading: boolean = false;
  @State private failed: boolean = false;
  private alive: boolean = false;
  private visible: boolean = false;
  private generation: number = 0;
  aboutToAppear(): void { this.alive = true; }
  aboutToDisappear(): void { this.alive = false; this.generation++; this.url = ''; }
  private changed(): void { this.generation++; this.url = ''; this.failed = false; this.loading = false; this.load(); }
  private foregroundChanged(): void {
    if (!this.foreground) { this.generation++; this.loading = false; this.url = ''; this.failed = false; }
    else this.load();
  }
  private async load(retry: boolean = false): Promise<void> {
    const attachment = this.attachment, queue = this.queue;
    if (!this.alive || !this.visible || !this.foreground || !queue || this.loading || this.url || this.failed
      || attachment.category !== 'image' || !attachment.reference || attachment.state) return;
    const generation = ++this.generation;
    const wanted = (): boolean => this.alive && this.visible && this.foreground && generation === this.generation;
    this.loading = true;
    try {
      const url = retry ? await queue.retry(this.deviceId, attachment.reference, true, wanted)
        : await queue.request(this.deviceId, attachment.reference, true, wanted);
      if (wanted()) { this.url = url; this.failed = false; }
    } catch (_) { if (wanted()) this.failed = true; }
    finally { if (wanted()) this.loading = false; }
  }
  private name(): string { return this.attachment.name || chatHostMediaStrings(this.locale).attachment; }
  private status(): string {
    const copy = chatHostMediaStrings(this.locale);
    if (this.attachment.state === 'loading' || this.loading) return copy.loading;
    if (this.attachment.state || this.failed) return copy.unavailable;
    if (!this.attachment.reference) return copy.onComputer;
    return copy.open;
  }
  build() {
    Column({ space: 4 }) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 6 }) {
          if (this.url && this.attachment.category === 'image') {
            Image(this.url).width('100%').height(180).objectFit(ImageFit.Contain)
              .onError((): void => { this.url = ''; this.failed = true; })
          }
          Text(this.name()).fontSize(14).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
          Text(this.status()).fontSize(12).fontColor($r('app.color.text_secondary'))
        }.padding(10).width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').constraintSize({ minHeight: 44 }).borderRadius(12)
        .backgroundColor($r('app.color.bg_page')).border({ width: 1, color: $r('app.color.border') })
        .enabled(this.foreground && !this.attachment.state && !!this.attachment.reference)
        .onClick((): void => {
          const mime = this.attachment.mimeType || (this.attachment.category === 'image' ? 'image/*' : '');
          this.onOpen(this.deviceId, this.attachment.reference, this.name(), mime);
        })
        .onVisibleAreaChange([0, 0.1, 1], (visible: boolean, ratio: number): void => {
          const next = visible && ratio > 0; if (next === this.visible) return; this.visible = next;
          if (this.visible) { this.failed = false; this.load(); }
          else { this.generation++; this.loading = false; this.url = ''; }
        })
      if (this.failed && this.attachment.category === 'image' && !this.attachment.state && this.attachment.reference) {
        Button(chatStrings(this.locale).retry).height(44).enabled(this.foreground && !this.loading)
          .onClick((): void => { this.failed = false; this.load(true); })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
