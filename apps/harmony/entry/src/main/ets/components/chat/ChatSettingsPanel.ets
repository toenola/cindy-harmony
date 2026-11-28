import { ChatStore } from '../../core/chat/ChatStore';
import { ChatMember, ChatActor, chatManager } from '../../core/chat/ChatModels';
import { ChatInviteShares } from '../../core/chat/ChatInvitationStore';
import { chatActionStrings, chatErrorText, chatDestructiveText, chatRevokeInviteText } from '../../core/chat/ChatStrings';
import { util } from '@kit.ArkTS';
import { pasteboard } from '@kit.BasicServicesKit';

@Component
export struct ChatSettingsPanel {
  store: ChatStore | null = null;
  shares: ChatInviteShares | null = null;
  pickAvatar: (() => Promise<string>) | null = null;
  confirm: ((title: string, body: string) => Promise<boolean>) | null = null;
  @Prop locale: string = 'zh-CN';
  @Prop nameLabel: string = '';
  @Prop saveLabel: string = '';
  @Prop archiveLabel: string = '';
  @Prop restoreLabel: string = '';
  @State private name: string = '';
  @State private nickname: string = '';
  @State private error: string = '';
  @State private busy: boolean = false;
  @State private version: number = 0;
  @State private invite: string = '';
  private off: (() => void) | null = null;
  private operations: Map<string, string> = new Map();
  private inviteOperation: string = '';
  private revokeOperation: string = '';
  aboutToAppear(): void {
    this.name = this.store?.page?.snapshot.room.name ?? '';
    this.nickname = this.store?.page?.snapshot.members.find((m: ChatMember): boolean => m.id === this.store?.me?.actor.id)?.nickname ?? '';
    this.off = this.store?.onChanged((): void => { this.version++; }) ?? null;
  }
  aboutToDisappear(): void { this.off?.(); this.off = null; }
  private manager(): boolean { const page = this.store?.page, self = this.store?.me?.actor.id; return !!page && !!self && !!chatManager(page.snapshot, self); }
  private owner(): boolean { const page = this.store?.page, self = this.store?.me?.actor.id; return !!page && !!self && chatManager(page.snapshot, self)?.role === 'owner'; }
  private editable(): boolean { return this.manager() && !this.store?.page?.snapshot.room.archived && !this.store?.page?.snapshot.room.dissolved_at; }
  private own(member: ChatMember): boolean { return member.kind === 'bot' && member.ownerActorId === this.store?.me?.actor.id && !member.assistant; }
  private role(role: string): string { const s = chatActionStrings(this.locale); return role === 'owner' ? s.owner : role === 'admin' ? s.admin : s.member; }
  private async act(type: string, input: Record<string, Object | null>, destructive: boolean = false): Promise<void> {
    const store = this.store; if (!store || this.busy) return;
    const page = store.page; this.busy = true;
    try {
      if (destructive && (!this.confirm || !await this.confirm(chatActionStrings(this.locale).confirm, chatDestructiveText(this.locale, type, page?.snapshot.room.name ?? '')))) return;
      if (page?.snapshot.room.id !== store.page?.snapshot.room.id) return;
      const key = JSON.stringify([type, input]); let operation = this.operations.get(key);
      if (!operation) { operation = util.generateRandomUUID(); this.operations.set(key, operation); }
      await store.manage(type, input, operation); this.operations.delete(key); this.error = '';
    } catch (e) { this.error = e instanceof Error ? e.message : 'CHAT_UNAVAILABLE'; }
    finally { this.busy = false; }
  }
  private async saveName(): Promise<void> { const input: Record<string, Object> = {}; input['name'] = this.name.trim(); await this.act('update', input); }
  private async saveNickname(): Promise<void> { const input: Record<string, Object | null> = {}; input['nickname'] = this.nickname.trim() || null; await this.act('nickname', input); }
  private async simple(type: string): Promise<void> { const input: Record<string, Object> = {}; await this.act(type, input, type === 'leave' || type === 'dissolve'); }
  private async member(member: ChatMember, action: string): Promise<void> {
    const input: Record<string, Object> = {}; input['actorId'] = member.id; input['action'] = action;
    if (action === 'role') input['role'] = member.role === 'admin' ? 'member' : 'admin';
    await this.act('member', input, action === 'remove');
  }
  private async transfer(member: ChatMember): Promise<void> { const input: Record<string, Object> = {}; input['actorId'] = member.id; await this.act('transfer', input, true); }
  private async addBot(actor: ChatActor): Promise<void> { const input: Record<string, Object> = {}; input['actorId'] = actor.id; input['action'] = 'invite'; await this.act('member', input); }
  private async notifications(mode: string): Promise<void> { const input: Record<string, Object> = {}; input['mode'] = mode; await this.act('notifications', input); }
  private async access(member: ChatMember, value: string): Promise<void> {
    const input: Record<string, Object> = {}; input['actorId'] = member.id; input['access'] = value; input['expectedRevision'] = member.accessRevision ?? -1; await this.act('botAccess', input);
  }
  private async toggle(key: string, value: boolean): Promise<void> { const input: Record<string, Object> = {}; input[key] = value; await this.act('update', input); }
  private async avatar(): Promise<void> {
    if (!this.pickAvatar || this.busy) return;
    try { const avatar = await this.pickAvatar(); if (!avatar) return; const input: Record<string, Object> = {}; input['avatar'] = avatar; await this.act('avatar', input); }
    catch (_) { this.error = 'PROFILE_AVATAR_UPLOAD_FAILED'; }
  }
  private async createInvite(): Promise<void> {
    if (!this.store || !this.shares || this.busy) return; this.busy = true;
    try { this.inviteOperation = this.inviteOperation || util.generateRandomUUID(); this.invite = await this.store.inviteLink(this.shares, this.inviteOperation); this.error = ''; }
    catch (e) { this.error = e instanceof Error ? e.message : 'CHAT_UNAVAILABLE'; } finally { this.busy = false; }
  }
  private async revokeInvite():Promise<void>{
    const store=this.store,shares=this.shares,link=this.invite;if(!store||!shares||!link||this.busy||!this.confirm)return;
    this.busy=true;
    try{if(!await this.confirm(chatActionStrings(this.locale).confirm,chatRevokeInviteText(this.locale)))return;
      this.revokeOperation=this.revokeOperation||util.generateRandomUUID();await store.revokeInvite(shares,link,this.revokeOperation);
      this.invite='';this.inviteOperation='';this.revokeOperation='';this.error='';
    }catch(e){this.error=e instanceof Error?e.message:'CHAT_UNAVAILABLE';}finally{this.busy=false;}
  }
  private async copyInvite(): Promise<void> { if (this.invite) await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.invite)); }
  build() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.version >= 0 && this.store?.page) {
          Text(this.nameLabel || chatActionStrings(this.locale).name).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: this.name }).height(44).fontColor($r('app.color.text_primary')).enabled(!this.busy && this.editable()).onChange((name: string): void => { this.name = name; })
          if (this.editable()) { Button(this.saveLabel || chatActionStrings(this.locale).save).height(44).enabled(!this.busy && !!this.name.trim()).onClick((): void => { this.saveName(); }) }
          if (this.manager() && !this.store.page.snapshot.room.dissolved_at) {
            Button(this.store.page.snapshot.room.archived ? this.restoreLabel || chatActionStrings(this.locale).restore : this.archiveLabel || chatActionStrings(this.locale).archive).height(44).enabled(!this.busy).onClick((): void => { this.simple(this.store?.page?.snapshot.room.archived ? 'restore' : 'archive'); })
          }
          if (!this.store.page.snapshot.room.archived && !this.store.page.snapshot.room.dissolved_at) {
            Text(chatActionStrings(this.locale).nickname).fontColor($r('app.color.text_secondary'))
            TextInput({ text: this.nickname }).height(44).onChange((value: string): void => { this.nickname = value; })
            Button(chatActionStrings(this.locale).save).height(44).enabled(!this.busy).onClick((): void => { this.saveNickname(); })
            if (this.pickAvatar && this.store.capability('groupMemberAvatar')) { Button(chatActionStrings(this.locale).photos).height(44).enabled(!this.busy).onClick((): void => { this.avatar(); }) }
            if (this.shares && (this.manager() || this.store.page.snapshot.room.allow_member_invites)) { Button(chatActionStrings(this.locale).invite).height(44).enabled(!this.busy).onClick((): void => { this.createInvite(); }) }
            if (this.invite) { Text(this.invite).fontColor($r('app.color.text_primary')).copyOption(CopyOptions.LocalDevice); Button(chatActionStrings(this.locale).copy).height(44).onClick((): void => { this.copyInvite(); }); if(this.confirm&&this.shares){Button(chatRevokeInviteText(this.locale)).height(44).enabled(!this.busy).onClick(():void=>{this.revokeInvite();})} }
            if (this.store.capability('groupNotificationSettings')) {
              Text(chatActionStrings(this.locale).notifications).fontColor($r('app.color.text_secondary'))
              Flex({ wrap: FlexWrap.Wrap }) {
                Button(chatActionStrings(this.locale).all).height(44).enabled(!this.busy).onClick((): void => { this.notifications('all'); })
                Button(chatActionStrings(this.locale).mentions).height(44).enabled(!this.busy).onClick((): void => { this.notifications('mentions'); })
                Button(chatActionStrings(this.locale).none).height(44).enabled(!this.busy).onClick((): void => { this.notifications('none'); })
              }
            }
            if (this.editable() && this.store.capability('groupMemberInvites')) { Row() { Text(chatActionStrings(this.locale).invite).layoutWeight(1); Toggle({ type: ToggleType.Switch, isOn: this.store.page.snapshot.room.allow_member_invites === true }).enabled(!this.busy).onChange((value: boolean): void => { this.toggle('allowMemberInvites', value); }) } }
            if (this.editable() && this.store.capability('groupMemberMentionAll')) { Row() { Text(chatActionStrings(this.locale).mentionAll).layoutWeight(1); Toggle({ type: ToggleType.Switch, isOn: this.store.page.snapshot.room.allow_member_mention_all === true }).enabled(!this.busy).onChange((value: boolean): void => { this.toggle('allowMemberMentionAll', value); }) } }
            Text(chatActionStrings(this.locale).members).fontColor($r('app.color.text_secondary'))
            ForEach(this.store.page.snapshot.members.filter((m: ChatMember): boolean => m.state === 'joined'), (member: ChatMember) => {
              Column({ space: 8 }) {
                Row({ space: 8 }) { Text(member.nickname || member.name).layoutWeight(1).fontColor($r('app.color.text_primary')); Text(this.role(member.role)).fontColor($r('app.color.text_secondary')) }
                Flex({ wrap: FlexWrap.Wrap }) {
                  if ((this.editable() && member.role !== 'owner') || this.own(member)) { Button(chatActionStrings(this.locale).remove).height(44).enabled(!this.busy).onClick((): void => { this.member(member, 'remove'); }) }
                  if (this.editable() && this.owner() && member.role !== 'owner') {
                    Button(this.role(member.role === 'admin' ? 'member' : 'admin')).height(44).enabled(!this.busy).onClick((): void => { this.member(member, 'role'); })
                    Button(chatActionStrings(this.locale).transfer).height(44).enabled(!this.busy).onClick((): void => { this.transfer(member); })
                  }
                  if (this.own(member) && member.accessRevision !== undefined) {
                    ForEach(['none', 'chat', 'tools'], (value: string) => { Button(value).height(44).enabled(!this.busy).onClick((): void => { this.access(member, value); }) }, (value: string): string => value)
                  }
                }
              }.width('100%').padding(8)
            }, (member: ChatMember): string => member.id)
            ForEach(this.store.actors.filter((a: ChatActor): boolean => !this.store?.page?.snapshot.members.some((m: ChatMember): boolean => m.id === a.id && m.state === 'joined')), (actor: ChatActor) => { Button(`+ ${actor.name}`).height(44).enabled(!this.busy).onClick((): void => { this.addBot(actor); }) }, (actor: ChatActor): string => actor.id)
            if (this.confirm) {
              Button(chatActionStrings(this.locale).leave).height(44).enabled(!this.busy).onClick((): void => { this.simple('leave'); })
              if (this.owner() && this.store.capability('groupLifecycleVersion')) { Button(chatActionStrings(this.locale).dissolve).height(44).enabled(!this.busy).onClick((): void => { this.simple('dissolve'); }) }
            }
          }
        }
        if (this.error) { Text(chatErrorText(this.locale, this.error)).fontColor($r('app.color.danger')) }
      }.width('100%').padding(16)
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
