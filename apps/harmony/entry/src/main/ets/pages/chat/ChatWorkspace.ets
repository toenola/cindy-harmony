import { ChatInvitationStore } from '../../core/chat/ChatInvitationStore';
import { ChatInvitePanel } from '../../components/chat/ChatInvitePanel';
import { TeammateRosterEntry } from '../../core/tasks/TeammateRoster';
import { ownedChatTask, ChatOwnedTaskTarget } from '../../core/chat/ChatCards';
import { util } from '@kit.ArkTS';
import { ChatStore } from '../../core/chat/ChatStore';
import { ChatActor, ChatMember, ChatMessage, ChatPending, ChatSendBody, ChatReaction, ChatBlock, chatMessageText, chatManager } from '../../core/chat/ChatModels';
import { chatStrings, chatActionStrings, chatErrorText, chatDestructiveText } from '../../core/chat/ChatStrings';
import { ChatAttachmentPickerPort } from '../../core/chat/ChatAttachmentPicker';
import { ChatConversationList } from '../../components/chat/ChatConversationList';
import { ChatTimeline } from '../../components/chat/ChatTimeline';
import { ChatDraftBook, ChatDraftContent } from '../../core/chat/ChatDraftHandoff';

/** Embeddable native detail pane. Root owns fold navigation, account lifecycle and media presentation. */
@Component
export struct ChatWorkspace {
  @Prop localCompanions: TeammateRosterEntry[] = [];
  onLocalCompanion: (entry: TeammateRosterEntry) => void = (_entry: TeammateRosterEntry): void => {};
  deviceName: (deviceId: string) => string = (_device: string): string => '';
  invitation: ChatInvitationStore | null = null;
  store: ChatStore | null = null;
  canControlDevice: (deviceId: string) => boolean = (_deviceId: string): boolean => false;
  onOwnedTask: (target: ChatOwnedTaskTarget) => void = (_target: ChatOwnedTaskTarget): void => {};
  attachmentPicker: ChatAttachmentPickerPort | null = null;
  @Prop locale: string = 'zh-CN';
  @Prop foreground: boolean = true;
  onBack: () => void = (): void => {};
  onCompanion: ((actor: ChatActor) => void) | null = null;
  onSettings: (store: ChatStore) => void = (_store: ChatStore): void => {};
  onMedia: (room: string, mediaId: string) => void = (_room: string, _media: string): void => {};
  @State private version: number = 0;
  @State private draft: string = '';
  @State private sending: boolean = false;
  @State private picking: boolean = false;
  @State private error: string = '';
  @State private mentions: string[] = [];
  @State private mentionAll: boolean = false;
  @State private quoteId: string = '';
  @State private attachments: ChatBlock[] = [];
  @State private menu: string = '';
  @State private reactionId: string = '';
  @State private targetMessage: string = '';
  private draftKey: string = '';
  private drafts: ChatDraftBook = new ChatDraftBook();
  private draftRevision: number = 0;
  private quoteRevision: number = 0;
  private mentionRevision: number = 0;
  private positions: Map<string, number> = new Map();
  private reading: boolean = false;
  private off: (() => void) | null = null;
  private alive: boolean = false;
  private draftContent(): ChatDraftContent {
    return { text: this.draft, revision: this.draftRevision, attachments: this.attachments.slice(), mentions: this.mentions.slice(),
      mentionAll: this.mentionAll, mentionRevision: this.mentionRevision, quoteId: this.quoteId, quoteRevision: this.quoteRevision };
  }
  private applyDraft(value: ChatDraftContent): void {
    this.draft = value.text; this.draftRevision = value.revision; this.attachments = value.attachments; this.mentions = value.mentions;
    this.mentionAll = value.mentionAll; this.mentionRevision = value.mentionRevision; this.quoteId = value.quoteId; this.quoteRevision = value.quoteRevision;
  }
  private handoff(key: string, sent: ChatDraftContent): void {
    if (this.draftKey === key) this.drafts.write(key, this.draftContent());
    const next = this.drafts.consume(key, sent); if (this.draftKey === key) this.applyDraft(next);
  }
  private sync(): void {
    const page = this.store?.page;
    const next = page ? JSON.stringify([this.store?.owner, page.snapshot.room.id, page.threadRootId]) : '';
    if (next !== this.draftKey) {
      if (this.draftKey) this.drafts.write(this.draftKey, this.draftContent());
      this.draftKey = next; this.applyDraft(this.drafts.read(next));
      this.menu = ''; this.reactionId = '';
      if (!this.store?.me) { this.drafts.clear(); this.positions.clear(); }
    }
    this.version++;
  }
  aboutToAppear(): void { this.alive = true; this.off = this.store?.onChanged((): void => this.sync()) ?? null; this.sync(); }
  aboutToDisappear(): void { this.alive = false; this.off?.(); this.off = null; }
  private async run(action: () => Promise<void>): Promise<void> {
    try { await action(); this.error = ''; } catch (e) { this.error = e instanceof Error ? e.message : 'CHAT_UNAVAILABLE'; }
  }
  private async pick(images: boolean): Promise<void> {
    const picker = this.attachmentPicker, page = this.store?.page; if (!picker || !page || this.picking) return;
    const key = this.draftKey; this.picking = true;
    await this.run(async (): Promise<void> => {
      await picker.pick(page.snapshot.room.id, images, 20 - this.attachments.length, (block: ChatBlock): void => {
        if (key === this.draftKey) this.attachments = this.attachments.concat([block]);
        else { const draft = this.drafts.read(key); draft.attachments.push(block); this.drafts.write(key, draft); }
      });
    }); this.picking = false;
  }
  private async send(): Promise<void> {
    const store = this.store, page = store?.page;
    if (!store || !page || this.sending || this.picking || (!this.draft.trim() && !this.attachments.length)) return;
    this.sending = true; const sent = this.draftContent(), key = this.draftKey, text = sent.text;
    this.drafts.write(key, sent);
    const content: ChatBlock[] = text ? [{ type: 'text', text }] : [];
    const body: ChatSendBody = { operationId: util.generateRandomUUID(), content: content.concat(sent.attachments), mentions: sent.mentions.slice() };
    if (page.threadRootId) body.threadRootId = page.threadRootId;
    if (sent.mentionAll) body.mentionAudience = 'humans';
    await this.run(async (): Promise<void> => {
      await store.send(body, sent.quoteId, (): void => { if (this.alive && this.store === store) this.handoff(key, sent); });
    }); this.sending = false;
  }
  private async viewport(ids: string[], atEnd: boolean, first: number): Promise<void> {
    if (this.draftKey) this.positions.set(this.draftKey, first);
    if (this.reading || !this.foreground || !atEnd) return;
    this.reading = true; try { await this.store?.markRead(ids, atEnd, this.foreground); } catch (_) {} finally { this.reading = false; }
  }
  build() {
    Column({ space: 8 }) {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        Button(chatStrings(this.locale).back).height(44).onClick(this.onBack)
        Text(this.store?.page?.snapshot.room.name ?? chatStrings(this.locale).groups).fontColor($r('app.color.text_primary')).maxLines(1)
        Button(chatStrings(this.locale).refresh).height(44).onClick((): void => {
          this.run(async (): Promise<void> => { if (this.store?.page) await this.store.refresh(); else await this.store?.loadConversations(); });
        })
        if (this.invitation && !this.store?.page) { Button(chatActionStrings(this.locale).join).height(44).onClick((): void => { this.menu = this.menu === 'join' ? '' : 'join'; }) }
        if (this.version >= 0 && this.store?.page?.snapshot.room.kind === 'group') {
          Button(chatStrings(this.locale).settings).height(44).onClick((): void => { if (this.store) this.onSettings(this.store); })
          Button(chatActionStrings(this.locale).topics).height(44).onClick((): void => { this.menu = this.menu === 'topics' ? '' : 'topics'; this.run(async (): Promise<void> => { await this.store?.loadTopics(); }); })
          if (this.store.capability('personalMentionHistory') && this.store.capability('personalMask')) {
            Button(chatActionStrings(this.locale).mentions).height(44).onClick((): void => { this.menu = 'mentions'; this.run(async (): Promise<void> => { await this.store?.loadMentions(); }); })
          }
        }
      }.width('100%')
      if (this.error || this.store?.error) { Text(chatErrorText(this.locale, this.error || this.store?.error || '')).fontColor($r('app.color.danger')).width('100%') }
      if (this.version >= 0 && this.store?.loading) { LoadingProgress().width(32).height(32) }
      if (this.version >= 0 && this.store?.page) {
        if (this.store.page.verified === false) { Text(chatActionStrings(this.locale).offline).fontColor($r('app.color.warn')) }
        if (this.menu === 'topics' || this.menu === 'mentions') {
          List() {
            ForEach(this.menu === 'topics' ? this.store.topicRoots : this.store.mentionMessages, (m: ChatMessage) => {
              ListItem() {
                Button(`${m.author.name}: ${chatMessageText(m).slice(0, 100)}`).height(44).onClick((): void => {
                  this.run(async (): Promise<void> => {
                    if (this.menu === 'topics') await this.store?.open(this.store.page?.snapshot.room.id ?? '', m.id);
                    else { await this.store?.locate(m); this.targetMessage = m.id; }
                    this.menu = '';
                  });
                })
              }
            }, (m: ChatMessage): string => m.id)
            if (this.menu === 'topics' && this.store.topicBefore) {
              ListItem() { Button(chatStrings(this.locale).older).height(44).onClick((): void => { this.run(async (): Promise<void> => { await this.store?.loadTopics(true); }); }) }
            }
          }.constraintSize({ maxHeight: 220 }).width('100%')
        }
        if (this.store.page.threadRootId) {
          Button(chatStrings(this.locale).main).height(44).onClick((): void => {
            const id = this.store?.page?.snapshot.room.id; if (id) this.run(async (): Promise<void> => { await this.store?.open(id); });
          })
        }
        if (this.store.page.before) { Button(chatStrings(this.locale).older).height(44).onClick((): void => { this.run(async (): Promise<void> => { await this.store?.loadOlder(); }); }) }
        ChatTimeline({ messages: this.store.page.messages.slice(), labels: chatStrings(this.locale), locale: this.locale,
          interactive: this.store.page.snapshot.room.kind !== 'direct', allowTopics: this.store.page.snapshot.room.kind === 'group', initialIndex: this.positions.get(this.draftKey) ?? 0, targetMessage: this.targetMessage,
          onCard: (message: ChatMessage): void => {
            const page = this.store?.page; if (!page || !this.store?.me) return;
            for (let i = 0; i < message.content.length; i++) {
              const target = ownedChatTask(message, message.content[i], page.snapshot, this.store.actors, this.store.me.actor.id, this.canControlDevice);
              if (target) { this.onOwnedTask(target); return; }
            }
          },
          onViewport: (ids: string[], atEnd: boolean, first: number): void => { this.viewport(ids, atEnd, first); },
          onQuote: (message: ChatMessage): void => { this.quoteRevision++; this.quoteId = message.id; },
          onAddReaction: (message: ChatMessage): void => { this.reactionId = message.id; },
          onTopic: (message: ChatMessage): void => { const id = this.store?.page?.snapshot.room.id; if (id) this.run(async (): Promise<void> => { await this.store?.open(id, message.threadRootId || message.id); }); },
          onMention: (message: ChatMessage): void => { this.mentionRevision++; this.draftRevision++; if (!this.mentions.includes(message.authorId)) this.mentions = this.mentions.concat([message.authorId]); this.draft += `@${message.author.name} `; },
          onMedia: (id: string): void => { const room = this.store?.page?.snapshot.room.id; if (room) this.onMedia(room, id); },
          onReact: (message: ChatMessage, reaction: ChatReaction): void => { this.run(async (): Promise<void> => { await this.store?.react(message.id, reaction.emoji, !reaction.me, util.generateRandomUUID()); }); },
        }).layoutWeight(1)
        if (this.store.page.snapshot.room.kind !== 'direct') {
        if (this.reactionId) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(['👍', '❤️', '🎉', '👀', '✅', '🙏'], (emoji: string) => { Button(emoji).height(44).onClick((): void => { const id = this.reactionId; this.run(async (): Promise<void> => { await this.store?.react(id, emoji, true, util.generateRandomUUID()); }); this.reactionId = ''; }) }, (emoji: string): string => emoji)
            Button(chatActionStrings(this.locale).cancel).height(44).onClick((): void => { this.reactionId = ''; })
          }
        }
        if (this.quoteId) {
          Row() { Text(`${chatActionStrings(this.locale).quote}: ${this.store.page.messages.find((m: ChatMessage): boolean => m.id === this.quoteId)?.author.name ?? ''}`).layoutWeight(1); Button(chatActionStrings(this.locale).cancel).height(44).onClick((): void => { this.quoteRevision++; this.quoteId = ''; }) }
        }
        if (this.menu === 'members') {
          Scroll() { Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.store.page.snapshot.members.filter((m: ChatMember): boolean => m.state === 'joined'), (m: ChatMember) => { Button(`@${m.name}`).height(44).onClick((): void => { this.mentionRevision++; this.draftRevision++; if (!this.mentions.includes(m.id)) this.mentions = this.mentions.concat([m.id]); this.draft += `@${m.name} `; this.menu = ''; }) }, (m: ChatMember): string => m.id)
            if (this.store.capability('groupMentionAudiences') && this.store.page.snapshot.room.kind === 'group' && (this.store.page.snapshot.room.allow_member_mention_all || chatManager(this.store.page.snapshot, this.store.me?.actor.id ?? ''))) {
              Button(chatActionStrings(this.locale).mentionAll).height(44).onClick((): void => { this.mentionRevision++; this.draftRevision++; this.mentionAll = true; this.draft += `${chatActionStrings(this.locale).mentionAll} `; this.menu = ''; })
            }
          } }.constraintSize({ maxHeight: 160 })
        }
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.attachments, (block: ChatBlock) => { Button(`${block.caption ?? ''} ×`).height(44).onClick((): void => { this.attachments = this.attachments.filter((b: ChatBlock): boolean => b.mediaId !== block.mediaId); }) }, (block: ChatBlock): string => block.mediaId ?? '')
          if (this.attachmentPicker) {
            Button(chatActionStrings(this.locale).photos).height(44).enabled(!this.picking && this.attachments.length < 20).onClick((): void => { this.pick(true); })
            Button(chatActionStrings(this.locale).files).height(44).enabled(!this.picking && this.attachments.length < 20).onClick((): void => { this.pick(false); })
          }
          Button('@').height(44).onClick((): void => { this.menu = this.menu === 'members' ? '' : 'members'; })
        }
        ForEach(this.store.pending.filter((p: ChatPending): boolean => p.roomId === this.store?.page?.snapshot.room.id), (p: ChatPending) => {
          Row({ space: 8 }) { Text(p.state === 'unknown' ? chatStrings(this.locale).unknown : chatErrorText(this.locale, p.state)).fontColor($r('app.color.text_secondary')); if (p.state !== 'sending') { Button(chatStrings(this.locale).retry).height(44).onClick((): void => { this.run(async (): Promise<void> => { await this.store?.retry(p.body.operationId); }); }) } }
        }, (p: ChatPending): string => p.body.operationId)
        Row({ space: 8 }) {
          TextInput({ text: this.draft, placeholder: chatStrings(this.locale).message }).layoutWeight(1).fontColor($r('app.color.text_primary')).onChange((value: string): void => { this.draftRevision++; this.draft = value; })
          Button(chatStrings(this.locale).send).height(44).enabled(!this.sending && !this.picking && (!!this.draft.trim() || !!this.attachments.length)).onClick((): void => { this.send(); })
        }.width('100%')
        }
      } else {
        if (this.menu === 'join' && this.invitation) {
          ChatInvitePanel({store:this.invitation,locale:this.locale,inputLabel:chatActionStrings(this.locale).invite,previewLabel:chatActionStrings(this.locale).preview,
            acceptLabel:chatActionStrings(this.locale).join,openLabel:chatStrings(this.locale).groups,retryLabel:chatStrings(this.locale).retry,
            uncertainLabel:chatStrings(this.locale).unknown,onJoined:(id:string):void=>{this.run(async():Promise<void>=>{await this.store?.loadConversations();await this.store?.open(id);this.menu='';});}})
        }
        ChatConversationList({ localCompanions: this.localCompanions, onLocalCompanion: this.onLocalCompanion, deviceName: this.deviceName, summaries: this.store?.summaries ?? [],
          onVisibleGroups: (ids: string[]): void => { this.run(async (): Promise<void> => { await this.store?.loadSummaries(ids); }); }, rooms: (this.store?.rooms ?? []).slice(), actors: this.store?.me?.capabilities?.['companionHome'] === true ? this.store.actors : [], labels: chatStrings(this.locale),
          onOpenCompanion: (actor: ChatActor): void => { if (this.onCompanion) this.onCompanion(actor); else this.run(async (): Promise<void> => { await this.store?.openCompanion(actor); }); },
          onOpenGroup: (id: string): void => { this.run(async (): Promise<void> => { await this.store?.open(id); }); },
        }).layoutWeight(1)
      }
    }.width('100%').height('100%').padding(12).backgroundColor($r('app.color.bg_page'))
  }
}
