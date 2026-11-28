import { chatCards, ChatCardView } from '../../core/chat/ChatCards';
import { ChatMessage, ChatBlock, ChatReaction, chatMessageText } from '../../core/chat/ChatModels';
import { chatQuotePreview } from '../../core/chat/ChatQuote';
import { chatActionStrings } from '../../core/chat/ChatStrings';
import { ChatStrings } from '../../core/chat/ChatStrings';

@Component
export struct ChatTimeline {
  @Prop locale: string = 'zh-CN';
  @Prop interactive: boolean = true;
  @Prop allowTopics: boolean = true;
  @Prop initialIndex: number = 0;
  @Prop @Watch('locate') targetMessage: string = '';
  private scroller: Scroller = new Scroller();
  private visible: Set<string> = new Set();
  onCard: (message: ChatMessage) => void = (_m: ChatMessage): void => {};
  onQuote: (message: ChatMessage) => void = (_m: ChatMessage): void => {};
  onAddReaction: (message: ChatMessage) => void = (_m: ChatMessage): void => {};
  onViewport: (ids: string[], atEnd: boolean, first: number) => void = (_ids: string[], _atEnd: boolean, _first: number): void => {};
  private first: number = 0;
  private end: number = -1;
  private locate(): void { const i = this.messages.findIndex((m: ChatMessage): boolean => m.id === this.targetMessage); if (i >= 0) this.scroller.scrollToIndex(i, false, ScrollAlign.CENTER); }
  @Prop messages: ChatMessage[] = [];
  @Prop labels: ChatStrings = new ChatStrings();
  onTopic: (message: ChatMessage) => void = (_m: ChatMessage): void => {};
  onMention: (message: ChatMessage) => void = (_m: ChatMessage): void => {};
  onMedia: (id: string) => void = (_id: string): void => {};
  onReact: (message: ChatMessage, reaction: ChatReaction) => void = (_m: ChatMessage, _r: ChatReaction): void => {};
  build() {
    List({ space: 16, scroller: this.scroller, initialIndex: this.initialIndex }) {
      ForEach(this.messages, (message: ChatMessage) => {
        ListItem() {
          Column({ space: 8 }) {
            Text(message.author.name).fontSize(13).fontColor($r('app.color.text_secondary'))
              .gesture(LongPressGesture({ repeat: false }).onAction((): void => this.onMention(message)))
            Text(message.deleted ? this.labels.removed : message.content.map((block: ChatBlock): string => block.namespace === 'cindy.quote' ? chatQuotePreview(block, this.messages, this.labels.removed) : (block.text ?? block.fallback ?? block.caption ?? '')).join('\n')).fontSize(15)
              .fontColor($r('app.color.text_primary')).copyOption(CopyOptions.LocalDevice).width('100%')
            if (!message.deleted) {
              ForEach(chatCards(message), (card: ChatCardView) => {
                Column({ space: 4 }) {
                  Text(card.title).fontSize(15).fontColor($r('app.color.text_primary')).maxLines(3)
                  if (card.summary) { Text(card.summary).fontSize(13).fontColor($r('app.color.text_secondary')) }
                }.width('100%').padding(12).border({ width: 1, color: $r('app.color.border') })
                .onClick((): void => this.onCard(message))
              }, (card: ChatCardView): string => card.key)
              ForEach(message.content.filter((block: ChatBlock): boolean => block.type === 'media' && !!block.mediaId), (block: ChatBlock) => {
                Button(block.caption ?? this.labels.message).height(44)
                  .onClick((): void => this.onMedia(block.mediaId ?? ''))
              }, (block: ChatBlock): string => block.mediaId ?? '')
              if (this.interactive) { Flex({ wrap: FlexWrap.Wrap }) {
                if (this.allowTopics) { Button(`${this.labels.topic}${message.replyCount ? ` · ${message.replyCount}` : ''}`)
                  .height(44).onClick((): void => this.onTopic(message)) }
                Button(chatActionStrings(this.locale).quote).height(44).onClick((): void => this.onQuote(message))
                Button(chatActionStrings(this.locale).react).height(44).onClick((): void => this.onAddReaction(message))
                ForEach(message.reactions ?? [], (reaction: ChatReaction) => {
                  Button(`${reaction.emoji} ${reaction.count}`).height(44)
                    .onClick((): void => this.onReact(message, reaction))
                }, (reaction: ChatReaction): string => reaction.emoji)
              }.width('100%') }
            }
          }.alignItems(HorizontalAlign.Start).width('100%').padding(12)
          .border({ width: this.targetMessage === message.id ? 1 : 0, color: $r('app.color.accent') })
        }.onVisibleAreaChange([0, 0.5, 1], (visible: boolean, ratio: number): void => {
          if (visible && ratio >= 0.5) this.visible.add(message.id); else this.visible.delete(message.id);
          this.onViewport(Array.from(this.visible), this.end >= this.messages.length - 1, this.first);
        })
      }, (message: ChatMessage): string => message.id)
    }.onScrollIndex((start: number, end: number): void => { this.first = start; this.end = end; this.onViewport(Array.from(this.visible), end >= this.messages.length - 1, start); })
    .width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
