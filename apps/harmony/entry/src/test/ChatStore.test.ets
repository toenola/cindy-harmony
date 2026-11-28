import { ChatHomeAccountIdentity, captureChatHomeAccount } from '../main/ets/core/chat/ChatHomeAccount';
import { ChatDraftBook, ChatDraftText, emptyChatDraft, consumeChatDraftText } from '../main/ets/core/chat/ChatDraftHandoff';
import { ChatHostThumbnailQueue, ChatHostAttachment } from '../main/ets/core/chat/ChatHostMedia';
import { ChatResourceStore, ChatHostPersistence, ChatHostPending } from '../main/ets/core/chat/ChatResourceStore';
import { ChatHostDirectory } from '../main/ets/core/chat/ChatHostDirectory';
import { ChatResourceAdapter, ChatResourceRef, ChatResourceAction, ChatResource, ChatResourceBlock } from '../main/ets/core/chat/ChatResourceAdapter';
import { createOfficialChatInviteShares, ChatInviteServiceScope } from '../main/ets/core/chat/ChatInviteShares';
import { ChatCloudAuth, ChatCloudHttp } from '../main/ets/core/chat/ChatAuthenticatedRequest';
import { ChatSubscription, ChatSubscriptionClock } from '../main/ets/core/chat/ChatSubscription';
import { HttpMethod, HttpResponseData } from '../main/ets/network/HarmonyHttp';
import { WsAdapter, WsCallbacks, WsMessage } from '../main/ets/network/WsAdapter';
import { ChatHistory, ChatHistoryState, ChatHistoryStorage } from '../main/ets/core/chat/ChatHistory';
import { ChatInvitationStore, ChatInviteShares, ChatInvitationPreview, parseChatInviteReference } from '../main/ets/core/chat/ChatInvitationStore';
import { describe, expect, it } from '@ohos/hypium';
import { ChatStore } from '../main/ets/core/chat/ChatStore';
import { ChatServerApi } from '../main/ets/core/chat/ChatServerApi';
import { ChatActor, ChatDelta, ChatMe, ChatHttpError, ChatDeltaBatch, ChatPending, ChatOutboxStorage, ChatSnapshot, ChatMessage, ChatSendBody, compareChatSequence } from '../main/ets/core/chat/ChatModels';

// Unit tier. Exercise the production Store/API boundary, no timers, disk or sockets.
// Rule basis: bot-group-chat.md §2 unread / §10 Chat Server; credentials-and-local-storage account isolation.
// Runtime budget: no real I/O or waits; execution timing awaits lead-owned serial Hvigor.
// Gaps: account-disposal late responses, exact-body unknown receipt retry, large read cursors,
// and role changes between presentation and mutation. Minimal fixture: one room and one actor.
const ROOM = '00000000-0000-4000-8000-000000000001';
const SELF = '00000000-0000-4000-8000-000000000002';
const MESSAGE = '00000000-0000-4000-8000-000000000003';
class ChatTestHomeIdentity implements ChatHomeAccountIdentity {
  value:string='old-account'; version:number=1; logged:boolean=true;
  account():string{return this.value;} epoch():number{return this.version;} signedIn():boolean{return this.logged;}
}
class ChatTestHostDisk implements ChatHostPersistence {
  async read(_owner: string, _device: string, _group: string): Promise<ChatHostPending[]> { return []; }
  async write(_owner: string, _device: string, _group: string, _rows: ChatHostPending[]): Promise<void> {}
}
class ChatFailingHostDisk extends ChatTestHostDisk {
  writes: number = 0; failAt: number = 0;
  beforeWrite: (count: number) => void = (_count: number): void => {};
  async write(_owner: string, _device: string, _group: string, _rows: ChatHostPending[]): Promise<void> {
    this.writes++; this.beforeWrite(this.writes); if (this.writes === this.failAt) throw new Error('DISK_WRITE_FAILED');
  }
}
interface ChatTestMediaCall { device: string; reference: string; thumbnail: boolean }
interface ChatHttpCall { url: string; method: string; body: string; headers: Record<string,string>; privateEndpoint: boolean; timeout: number }
class ChatServiceAuth implements ChatCloudAuth {
  refreshes: number=0;
  async getAccessToken(): Promise<string|null> { return 'old-token'; }
  async forceRefreshToken(): Promise<string|null> { this.refreshes++; return 'fresh-token'; }
}
class ChatServiceHttp implements ChatCloudHttp {
  calls: ChatHttpCall[]=[]; responses: HttpResponseData[]=[];
  beforeResponse: () => void=(): void => {};
  async requestJson(address: string, method: HttpMethod, headers: Record<string,string>, body?: string, timeout?: number, privateEndpoint?: boolean): Promise<HttpResponseData> {
    this.calls.push({url:address,method,headers:JSON.parse(JSON.stringify(headers)) as Record<string,string>,body:body??'',privateEndpoint:privateEndpoint??false,timeout:timeout??0});
    this.beforeResponse(); const result=this.responses.shift(); if(!result) throw new Error('UNEXPECTED_HTTP'); return result;
  }
}
class ChatTestClock implements ChatSubscriptionClock {
  id: number=0; repeats: Map<number,()=>void>=new Map(); onceTasks: Map<number,()=>void>=new Map();
  once(run:()=>void,_ms:number):number { const id=++this.id; this.onceTasks.set(id,run); return id; }
  repeat(run:()=>void,ms:number):number { expect(ms).assertEqual(30000); const id=++this.id; this.repeats.set(id,run); return id; }
  cancelOnce(id:number):void {this.onceTasks.delete(id);}
  cancelRepeat(id:number):void {this.repeats.delete(id);}
  tick():void {this.repeats.forEach((run:()=>void):void=>run());}
}
class ChatTestFrame implements WsMessage {
  private frame: string;
  constructor(frame:string){this.frame=frame;}
  toString():string{return this.frame;}
}
class ChatTestSocket implements WsAdapter {
  callbacks: WsCallbacks=new WsCallbacks(); sent:Record<string,Object>[]=[];
  setCallbacks(callbacks:WsCallbacks):void {this.callbacks=callbacks;}
  connect(_address:string,_headers:Record<string,string>):void {this.callbacks.onOpen();}
  send(frame:string):boolean {this.sent.push(JSON.parse(frame) as Record<string,Object>);return true;}
  close(_code?:number,_reason?:string):void {}
  terminate():void {}
  receive(frame:Record<string,Object>):void {this.callbacks.onMessage(new ChatTestFrame(JSON.stringify(frame)));}
}
async function chatMicrotasks():Promise<void>{for(let i=0;i<80;i++)await Promise.resolve();}
class ChatMemoryStorage implements ChatOutboxStorage {
  rows: ChatPending[] = [];
  async read(_owner: string): Promise<ChatPending[]> { return this.rows; }
  async write(_owner: string, rows: ChatPending[]): Promise<void> { this.rows = JSON.parse(JSON.stringify(rows)) as ChatPending[]; }
}
class ChatFailingOutbox extends ChatMemoryStorage {
  writes: number = 0; failAt: number = 0;
  async write(owner: string, rows: ChatPending[]): Promise<void> {
    this.writes++; if (this.writes === this.failAt) throw new Error('DISK_WRITE_FAILED'); await super.write(owner, rows);
  }
}
function hostSendFixture(disk: ChatHostPersistence, send: (input: Record<string, Object>) => Promise<Object | undefined>): ChatResourceStore {
  const data: Record<string, Object> = {}; data['messages'] = []; data['supportsAttachments'] = true;
  const ref: ChatResourceRef = { collectionId: 'bot-groups', kind: 'bot-group', id: ROOM };
  const block: ChatResourceBlock = { primitive: 'bot-group-chat', data }, action: ChatResourceAction = { id: 'send' };
  const resource: ChatResource = { ref, blocks: [block], actions: [action] };
  const adapter = new ChatResourceAdapter(async (_device: string, channel: string, args: Object[]): Promise<Object | undefined> => {
    if (channel.endsWith(':get')) return resource;
    const request = args[0] as Record<string, Object>; return send(request['input'] as Record<string, Object>);
  }, 'actual-host');
  return new ChatResourceStore('account', ROOM, adapter, disk);
}
function cloudSendFixture(disk: ChatOutboxStorage, send: (body: Object | undefined) => Promise<Object>): ChatStore {
  return new ChatStore('account', new ChatServerApi(async (path: string, method: string, body?: Object): Promise<Object> => {
    if (path === '/v1/me') return identity(); if (path === '/v1/actors') return [];
    if (path.endsWith('/snapshot')) return snapshot();
    if (method === 'POST' && path.endsWith('/messages')) return send(body); return [];
  }), disk);
}
class ChatDeferredOutbox implements ChatOutboxStorage {
  started: Promise<void>;
  private onStart: () => void = (): void => {};
  finish: () => void = (): void => {};
  constructor() { this.started = new Promise<void>((resolve) => { this.onStart = resolve; }); }
  async read(_owner: string): Promise<ChatPending[]> { return []; }
  write(_owner: string, _rows: ChatPending[]): Promise<void> {
    this.onStart(); return new Promise<void>((resolve) => { this.finish = resolve; });
  }
}
class FailingChatHistory extends ChatHistory { async shutdown(): Promise<void> { throw new Error('HISTORY_SHUTDOWN_FAILED'); } }
class ChatMemoryHistory implements ChatHistoryStorage {
  states: Map<string, ChatHistoryState> = new Map(); fail: boolean = false;
  async read(owner: string, room: string): Promise<ChatHistoryState | null> { return this.states.get(`${owner}:${room}`) ?? null; }
  async write(owner: string, room: string, state: ChatHistoryState | null): Promise<void> {
    if (this.fail) throw new Error('DISK_FULL');
    if (!state) this.states.delete(`${owner}:${room}`); else this.states.set(`${owner}:${room}`, JSON.parse(JSON.stringify(state)) as ChatHistoryState);
  }
}
class TestInviteShares implements ChatInviteShares {
  async resolve(_id: string): Promise<string> { return 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; }
  async create(_group: string, _token: string, _actor: string): Promise<string> { return ''; }
}
class FailingShareCleanup extends TestInviteShares { async revoked(_shareId:string):Promise<void>{throw new Error('SHARE_PAGE_UNAVAILABLE');} }
function invitePreview(): ChatInvitationPreview { return { groupId: ROOM, name: 'group', inviterName: 'friend', joined: false }; }
function identity(): ChatMe { return { actor: { id: SELF, kind: 'human', externalId: '', name: 'self' } }; }
function snapshot(role: string = 'owner'): ChatSnapshot {
  return { room: { id: ROOM, name: 'group', kind: 'group', archived: false, revision: 1, created_at: '', updated_at: '' },
    members: [{ id: SELF, kind: 'human', name: 'self', state: 'joined', ownerActorId: SELF, role }],
    messages: [], cursor: '0', reads: [{ thread_key: 'main', read_seq: '0' }] };
}
function message(): ChatMessage {
  return { id: MESSAGE, seq: '90071992547409930001', authorId: SELF, author: { name: 'self', kind: 'human' },
    createdAt: '', deleted: false, threadRootId: null, content: [{ type: 'text', text: 'hello' }] };
}
export default function chatStoreTests(): void {
  describe('ChatStore', () => {
    it('discard_late_history_after_dispose', 0, async () => {
      let resolveSnapshot: (value: Object) => void = (_v: Object): void => {};
      const api = new ChatServerApi((_path: string, _method: string): Promise<Object> => new Promise<Object>((resolve) => { resolveSnapshot = resolve; }));
      const store = new ChatStore('account:realm:epoch', api, new ChatMemoryStorage());
      const opening = store.open(ROOM); store.dispose(); resolveSnapshot(snapshot()); await opening;
      expect(store.page === null).assertTrue(); expect(store.rooms.length).assertEqual(0);
    });
    it('persist_before_post_and_retry_exact_unknown_body', 0, async () => {
      const disk = new ChatMemoryStorage(); let calls = 0; const sent: string[] = [];
      const api = new ChatServerApi(async (path: string, method: string, body?: Object): Promise<Object> => {
        if (path === '/v1/me') return identity();
        if (path === '/v1/actors') return [];
        if (path.endsWith('/snapshot')) return snapshot();
        if (method === 'POST' && path.endsWith('/messages')) {
          expect(disk.rows.length).assertEqual(1); sent.push(JSON.stringify(body)); calls++;
          if (calls === 1) throw new Error('NETWORK_TIMEOUT'); return message();
        }
        return [];
      });
      const store = new ChatStore('account', api, disk);
      await store.loadConversations(); await store.open(ROOM);
      const body: ChatSendBody = { operationId: 'stable-id', mentions: [], content: [{ type: 'text', text: 'hello' }] };
      await store.send(body); expect(store.pending[0].state).assertEqual('unknown');
      body.content[0].text = 'changed draft'; await store.retry('stable-id');
      expect(sent[0]).assertEqual(sent[1]); expect(store.pending.length).assertEqual(0);
    });
    it('manager_role_revoked_before_update_prevents_write', 0, async () => {
      let role = 'owner', writes = 0;
      const api = new ChatServerApi(async (path: string, method: string): Promise<Object> => {
        if (path === '/v1/me') return identity();
        if (path.endsWith('/snapshot')) return snapshot(role);
        if (method !== 'GET') writes++; return [];
      });
      const store = new ChatStore('account', api, new ChatMemoryStorage());
      await store.loadConversations(); await store.open(ROOM); role = 'member';
      let refused = false;
      try { const input: Record<string, Object> = {}; input['name'] = 'new name'; await store.manage('update', input, 'update-id'); } catch (_) { refused = true; }
      expect(refused).assertTrue(); expect(writes).assertEqual(0);
    });
    it('read_visible_main_only_without_rounding_large_sequence', 0, async () => {
      let readSeq = '';
      const api = new ChatServerApi(async (path: string, method: string, body?: Object): Promise<Object> => {
        if (path.endsWith('/snapshot')) return snapshot();
        if (method === 'POST') { readSeq = (body as Record<string, Object>)['readSeq'] as string; const receipt: Record<string, Object> = {}; receipt['readSeq'] = readSeq; return receipt; }
        return [message()];
      });
      const store = new ChatStore('account', api, new ChatMemoryStorage()); await store.open(ROOM);
      await store.markRead([MESSAGE], true, false); expect(readSeq).assertEqual('');
      await store.markRead([MESSAGE], true, true); expect(readSeq).assertEqual('90071992547409930001');
      expect(compareChatSequence(readSeq, '90071992547409930000') > 0).assertTrue();
    });
    it('one_request_for_concurrent_same_history_page', 0, async () => {
      let reads = 0;
      const api = new ChatServerApi(async (path: string, _method: string): Promise<Object> => {
        if (path.endsWith('/snapshot')) return snapshot(); reads++;
        if (path.includes('before=')) return [];
        const rows: ChatMessage[] = [];
        for (let i = 0; i < 100; i++) { const row = message(); row.id = `00000000-0000-4000-8000-${String(i + 100).padStart(12, '0')}`; row.seq = String(100 - i); rows.push(row); }
        return rows;
      });
      const store = new ChatStore('account', api, new ChatMemoryStorage()); await store.open(ROOM);
      await Promise.all([store.loadOlder(), store.loadOlder()]); expect(reads).assertEqual(2);
    });
    it('invite_preview_never_joins_and_uncertain_retry_keeps_operation_id', 0, async () => {
      const operations: string[] = []; let joins = 0, ids = 0;
      const api = new ChatServerApi(async (path: string, _method: string, body?: Object): Promise<Object> => {
        if (path.endsWith('/preview')) return invitePreview();
        operations.push((body as Record<string, Object>)['operationId'] as string); joins++;
        if (joins === 1) throw new Error('NETWORK_TIMEOUT'); const receipt: Record<string, Object> = {}; receipt['groupId'] = ROOM; return receipt;
      });
      const shares = new TestInviteShares();
      const invite = new ChatInvitationStore('account', api, shares, (): string => `join-${++ids}`, (): boolean => true);
      await invite.read('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'); expect(joins).assertEqual(0);
      await invite.accept(); expect(invite.phase).assertEqual('uncertain');
      await invite.accept(); expect(invite.joinedRoom).assertEqual(ROOM); expect(operations[0]).assertEqual(operations[1]);
    });
    it('invite_account_revocation_drops_late_join_receipt', 0, async () => {
      let finish: (value: Object) => void = (_value: Object): void => {};
      const api = new ChatServerApi(async (path: string, _method: string): Promise<Object> => {
        if (path.endsWith('/preview')) return invitePreview();
        return new Promise<Object>((resolve) => { finish = resolve; });
      });
      const invite = new ChatInvitationStore('account', api, new TestInviteShares(), (): string => 'join-id', (): boolean => true);
      await invite.read('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
      const joining = invite.accept(); invite.dispose(); const receipt: Record<string, Object> = {}; receipt['groupId'] = ROOM; finish(receipt); await joining;
      expect(invite.joinedRoom).assertEqual(''); expect(invite.preview === null).assertTrue();
    });
    it('durable_delta_updates_loaded_old_message_and_retains_tombstone_offline', 0, async () => {
      const disk = new ChatMemoryHistory();
      const api = new ChatServerApi(async (path: string, _method: string): Promise<Object> => {
        if (path.endsWith('/snapshot')) { const snap = snapshot(); snap.messages = [message()]; snap.cursor = '10'; return snap; }
        return [message()];
      });
      const history = new ChatHistory('account', api, disk, (): boolean => true, (): string => 'generation');
      await history.page(ROOM, '', '', true);
      const edited = message(); edited.content = [{ type: 'text', text: 'edited' }]; edited.revision = 2;
      const edit: ChatDeltaBatch = { cursor: '11', changes: [{ type: 'message.updated', data: { message: edited } }] };
      await history.receive(ROOM, edit, '10'); expect((await history.page(ROOM, '')).messages[0].content[0].text).assertEqual('edited');
      const deleted = message(); deleted.deleted = true; deleted.revision = 3;
      const tombstone: ChatDeltaBatch = { cursor: '12', changes: [{ type: 'message.deleted', data: { message: deleted } }] };
      await history.receive(ROOM, tombstone, '11');
      const restarted = new ChatHistory('account', api, disk, (): boolean => true, (): string => 'next');
      expect((await restarted.offline(ROOM, ''))?.messages[0].deleted).assertTrue();
      const otherAccount = new ChatHistory('other', api, disk, (): boolean => true, (): string => 'next');
      expect(await otherAccount.offline(ROOM, '') === null).assertTrue();
    });
    it('delta_durable_commit_failure_does_not_publish_or_ack_new_cursor', 0, async () => {
      const disk = new ChatMemoryHistory();
      const api = new ChatServerApi(async (path: string, _method: string): Promise<Object> => {
        if (path.endsWith('/snapshot')) { const snap = snapshot(); snap.messages = [message()]; snap.cursor = '10'; return snap; } return [message()];
      });
      const history = new ChatHistory('account', api, disk, (): boolean => true, (): string => 'generation'); await history.page(ROOM, '', '', true);
      disk.fail = true; const edited = message(); edited.revision = 2;
      const batch: ChatDeltaBatch = { cursor: '11', changes: [{ type: 'message.updated', data: { message: edited } }] };
      let rejected = false; try { await history.receive(ROOM, batch, '10'); } catch (_) { rejected = true; }
      expect(rejected).assertTrue(); expect(history.cursor(ROOM)).assertEqual('10');
    });
    it('explicit_lost_membership_purges_durable_room_before_offline_read', 0, async () => {
      const disk = new ChatMemoryHistory(); let revoked = false;
      const api = new ChatServerApi(async (path: string, _method: string): Promise<Object> => {
        if (revoked) throw new ChatHttpError(403);
        if (path.endsWith('/snapshot')) { const snap = snapshot(); snap.messages = [message()]; snap.cursor = '10'; return snap; } return [message()];
      });
      const history = new ChatHistory('account', api, disk, (): boolean => true, (): string => 'generation'); await history.page(ROOM, '', '', true); revoked = true;
      try { await history.page(ROOM, '', '', true); } catch (_) {}
      expect(await history.offline(ROOM, '') === null).assertTrue();
    });
    it('shutdown_drains_outbox_despite_history_error_and_is_reentrant_idempotent', 0, async () => {
      const disk = new ChatDeferredOutbox();
      const api = new ChatServerApi(async (path: string, _method: string): Promise<Object> => {
        if (path === '/v1/me') return identity(); if (path.endsWith('/snapshot')) return snapshot(); return [];
      });
      const store = new ChatStore('account', api, disk); await store.loadConversations(); await store.open(ROOM);
      store.attachHistory(new FailingChatHistory('account',api,new ChatMemoryHistory(),(): boolean => true,(): string => 'generation'));
      const body: ChatSendBody = { operationId:'shutdown-send', content:[{type:'text',text:'hello'}],mentions:[] };
      const sending = store.send(body); await disk.started;
      let reentrant: Promise<void> | null = null; store.onChanged((): void => { reentrant=store.shutdown(); });
      const shutdown=store.shutdown(); expect(shutdown===store.shutdown()).assertTrue(); expect(shutdown===reentrant).assertTrue();
      let settled=false; const observed=shutdown.catch((): void => { settled=true; });
      await Promise.resolve(); await Promise.resolve(); expect(settled).assertFalse();
      disk.finish(); await sending; await observed; expect(settled).assertTrue();
    });
    it('official_share_factory_uses_build_origin_realm_refresh_and_public_resolution_without_token',0,async()=>{
      const auth=new ChatServiceAuth(), http=new ChatServiceHttp(), shareId='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
      const scope:ChatInviteServiceScope={region:'cn',realm:'global',current:():boolean=>true};
      const service=createOfficialChatInviteShares(auth,scope,http);
      const receipt:Record<string,Object>={};receipt['schemaVersion']=1;receipt['kind']='chat-invite';receipt['includeAttribution']=true;receipt['shareId']=shareId;receipt['url']=`https://share.cindy.com.cn/chat-invite/${shareId}`;
      http.responses=[{statusCode:401,body:''},{statusCode:200,body:JSON.stringify(receipt)},{statusCode:200,body:'{"token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}'}];
      expect(await service.create(ROOM,'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',SELF)).assertEqual(receipt['url'] as string);
      expect(auth.refreshes).assertEqual(1);expect(http.calls[0].headers['Authorization']).assertEqual('Bearer old-token');expect(http.calls[1].headers['Authorization']).assertEqual('Bearer fresh-token');
      expect((JSON.parse(http.calls[1].body) as Record<string,Object>)['authRealm']).assertEqual('global');
      expect(http.calls[1].url).assertEqual('https://share.cindy.com.cn/api/shares');expect(http.calls[1].privateEndpoint).assertTrue();expect(http.calls[1].timeout).assertEqual(20000);
      const parsed=parseChatInviteReference(`https://untrusted.example/chat-invite/${shareId}`);await service.resolve(parsed.shareId);
      expect(http.calls[2].url).assertEqual(`https://share.cindy.com.cn/api/chat-invites/${shareId}/token`);
      expect(Object.keys(http.calls[2].headers).length).assertEqual(0);
    });
    it('share_factory_rejects_account_change_before_exposing_invitation_receipt',0,async()=>{
      const http=new ChatServiceHttp();let current=true;
      const scope:ChatInviteServiceScope={region:'global',realm:'global',current:():boolean=>current};
      const service=createOfficialChatInviteShares(new ChatServiceAuth(),scope,http);
      http.responses=[{statusCode:200,body:'{}'}];http.beforeResponse=():void=>{current=false;};
      let rejected=false;try{await service.create(ROOM,'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',SELF);}catch(_){rejected=true;}
      expect(rejected).assertTrue();expect(http.calls.length).assertEqual(1);
    });
    it('list_only_socket_subscribes_actor_and_stops_head_reads_when_list_hidden',0,async()=>{
      let listReads=0;
      const api=new ChatServerApi(async(path:string,_method:string):Promise<Object>=>{
        if(path.includes('/changes?')){const result:Record<string,Object>={};result['head']='10';return result;}
        if(path==='/v1/me')return identity();if(path.startsWith('/v1/conversations?'))listReads++;return [];
      });
      const store=new ChatStore('account',api,new ChatMemoryStorage()),clock=new ChatTestClock(),socket=new ChatTestSocket();
      const subscription=new ChatSubscription(store,'https://chat.cindy.app',async():Promise<string|null>=>'token',():boolean=>true,():WsAdapter=>socket,clock);
      subscription.setListVisible(true);subscription.start();await chatMicrotasks();
      const ready:Record<string,Object>={};ready['type']='ready';ready['actorId']=SELF;socket.receive(ready);await chatMicrotasks();
      expect(store.page===null).assertTrue();expect(socket.sent.some((f:Record<string,Object>):boolean=>f['type']==='subscribe'&&f['scope']===`actor:${SELF}`)).assertTrue();
      const before=listReads;
      const hints:ChatDelta[]=[{type:'work.available'}],hintFrame:Record<string,Object>={};hintFrame['type']='changes';hintFrame['scope']=`actor:${SELF}`;hintFrame['cursor']='11';hintFrame['changes']=hints;socket.receive(hintFrame);await chatMicrotasks();expect(listReads).assertEqual(before);
      clock.tick();await chatMicrotasks();expect(listReads).assertEqual(before+1);
      subscription.setListVisible(false);clock.tick();await chatMicrotasks();expect(listReads).assertEqual(before+1);subscription.stop();expect(clock.repeats.size).assertEqual(0);
    });
    it('actor_read_event_refreshes_group_unread_even_without_room_head_change',0,async()=>{
      let alreadyRead=false;
      const incoming=message();incoming.authorId='00000000-0000-4000-8000-000000000004';
      const api=new ChatServerApi(async(path:string,_method:string):Promise<Object>=>{
        if(path==='/v1/me')return identity();
        if(path.startsWith('/v1/conversations?'))return [snapshot().room];
        if(path.endsWith('/snapshot')){const value=snapshot();value.messages=[incoming];if(alreadyRead)value.reads=[{thread_key:'main',read_seq:incoming.seq}];return value;}return [];
      });
      const store=new ChatStore('account',api,new ChatMemoryStorage());await store.loadConversations();expect(store.summaries[0].unread).assertEqual(1);
      alreadyRead=true;const batch:ChatDeltaBatch={cursor:'12',changes:[{type:'read.changed',entityId:ROOM}]};await store.actorChanged(batch,true);expect(store.summaries[0].unread).assertEqual(0);
    });
    it('authoritative_invite_revocation_survives_public_share_cleanup_failure',0,async()=>{
      let posts=0,actor='';
      const api=new ChatServerApi(async(path:string,method:string,_body?:Object,asActor?:string):Promise<Object>=>{
        if(path==='/v1/me')return identity();if(path.endsWith('/snapshot'))return snapshot();
        if(method==='POST'&&path.endsWith('/invite-links/revoke')){posts++;actor=asActor??'';const result:Record<string,Object>={};result['revoked']=true;return result;}return [];
      });
      const store=new ChatStore('account',api,new ChatMemoryStorage());await store.loadConversations();await store.open(ROOM);
      await store.revokeInvite(new FailingShareCleanup(),'https://share.cindy.app/chat-invite/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB','revoke-id');
      expect(posts).assertEqual(1);expect(actor).assertEqual(SELF);
    });
    it('actor_scope_event_refreshes_companion_directory_without_open_detail',0,async()=>{
      let updated=false;
      const companion:ChatActor={id:MESSAGE,kind:'bot',externalId:'owned-bot',name:'Companion',homeDeviceId:'real-home'};
      const api=new ChatServerApi(async(path:string,_method:string):Promise<Object>=>{
        if(path.includes('/changes?')){const result:Record<string,Object>={};result['head']='10';return result;}
        if(path==='/v1/me')return identity();if(path==='/v1/actors')return updated?[companion]:[];return [];
      });
      const store=new ChatStore('account',api,new ChatMemoryStorage()),clock=new ChatTestClock(),socket=new ChatTestSocket();
      const subscription=new ChatSubscription(store,'https://chat.cindy.app',async():Promise<string|null>=>'token',():boolean=>true,():WsAdapter=>socket,clock);
      subscription.setListVisible(true);subscription.start();await chatMicrotasks();const ready:Record<string,Object>={};ready['type']='ready';ready['actorId']=SELF;socket.receive(ready);await chatMicrotasks();
      expect(store.actors.length).assertEqual(0);updated=true;
      const changes:ChatDelta[]=[{type:'actor.updated',entityId:MESSAGE}],frame:Record<string,Object>={};frame['type']='changes';frame['scope']=`actor:${SELF}`;frame['cursor']='11';frame['changes']=changes;
      socket.receive(frame);await chatMicrotasks();expect(store.page===null).assertTrue();expect(store.actors[0].id).assertEqual(MESSAGE);
      expect(socket.sent.some((f:Record<string,Object>):boolean=>f['type']==='ack'&&f['scope']===`actor:${SELF}`&&f['cursor']==='11')).assertTrue();subscription.stop();
    });
    it('canonical_invite_links_parse_without_platform_url_runtime_and_reject_authority_ambiguity',0,()=>{
      const share='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
      const accepted:string[]=[`https://share.cindy.com.cn/chat-invite/${share}`,`邀请 https://untrusted.example/chat-invite/${share}.`,`http://localhost:8080/chat-invite/${share}`,`http://[::1]/chat-invite/${share}`];
      accepted.forEach((input:string):void=>{expect(parseChatInviteReference(input).shareId).assertEqual(share);});
      const rejected:string[]=[`https://user:password@share.cindy.app/chat-invite/${share}`,`https://share.cindy.app/chat-invite/${share}?token=x`,`https://share.cindy.app/chat-invite/${share}#x`,`http://untrusted.example/chat-invite/${share}`,`https://share.cindy.app:70000/chat-invite/${share}`,`https://a.example/chat-invite/${share} https://b.example/chat-invite/${share}`];
      rejected.forEach((input:string):void=>{let failed=false;try{parseChatInviteReference(input);}catch(_){failed=true;}expect(failed).assertTrue();});
    });
    it('cloud_shutdown_waits_registered_host_write_drain_before_credential_cleanup',0,async()=>{
      const api=new ChatServerApi(async(_path:string,_method:string):Promise<Object>=>[]),store=new ChatStore('account',api,new ChatMemoryStorage());
      let finish:()=>void=():void=>{};const child=new Promise<void>((resolve)=>{finish=resolve;});
      store.registerOwnedDrain(():Promise<void>=>child);let settled=false;
      const closing=store.shutdown().then(():void=>{settled=true;});await Promise.resolve();await Promise.resolve();expect(settled).assertFalse();finish();await closing;expect(settled).assertTrue();
    });
    it('host_group_directory_preserves_real_channel_and_rechecks_create_capability',0,async()=>{
      let disabled=false,writes=0;const devices:string[]=[];
      const adapter=new ChatResourceAdapter(async(device:string,channel:string,_args:Object[]):Promise<Object|undefined>=>{
        devices.push(device);const output:Record<string,Object>={};
        if(channel.endsWith(':manifest')){
          const action:ChatResourceAction={id:'create',disabled};const collection:Record<string,Object>={};collection['id']='bot-groups';collection['resourceKind']='bot-group';collection['actions']=[action];output['collections']=[collection];return output;
        }
        if(channel.endsWith(':list')){
          const ref:ChatResourceRef={collectionId:'bot-groups',kind:'bot-group',id:ROOM},display:Record<string,Object>={},row:Record<string,Object>={};display['title']='Host group';row['ref']=ref;row['display']=display;row['revision']='1';output['collectionId']='bot-groups';output['items']=[row];return output;
        }
        writes++;return output;
      },'real-computer');
      const directory=new ChatHostDirectory(adapter,'zh-CN',():boolean=>true);await directory.refresh();expect(directory.items[0].title).assertEqual('Host group');expect(directory.canCreate).assertTrue();
      disabled=true;let refused=false;try{await adapter.create('New group',[]);}catch(_){refused=true;}
      expect(refused).assertTrue();expect(writes).assertEqual(0);expect(devices.every((id:string):boolean=>id==='real-computer')).assertTrue();directory.dispose();
    });
    it('home_scope_captures_account_epoch_even_if_root_mutable_predicate_becomes_true_again',0,()=>{
      const identity=new ChatTestHomeIdentity(),current=captureChatHomeAccount(identity,():boolean=>true);
      expect(current()).assertTrue();identity.value='new-account';identity.version=2;expect(current()).assertFalse();
      identity.value='old-account';identity.version=3;expect(current()).assertFalse();
    });
    // Production refresh -> visible attachment rows: previous parser discarded the
    // only content of these messages. bot-group-chat.md §3.1 requires sent order,
    // pending placeholders and no inferred task/workdir access. Unit, no I/O/waits;
    // existing cloud media tests never exercise the original host resource payload.
    it('host_attachment_only_refresh_preserves_order_states_and_opaque_media_context',0,async()=>{
      const imageRef='cindy-media://item?sessionId=lane-1&workdir=%2Fwork%2Fa%20b&remoteHostId=ssh-host';
      const fileRef='xdt-file://open?path=%2Fwork%2Freport.pdf&sessionId=lane-1&workdir=%2Fwork&remoteHostId=ssh-host';
      const image:Record<string,Object>={};image['id']='image';image['name']='Photo';image['category']='image';image['mimeType']='image/png';image['url']=imageRef;image['size']=100;
      const file:Record<string,Object>={};file['id']='file';file['name']='Report.pdf';file['category']='pdf';file['mimeType']='application/pdf';file['url']=fileRef;
      const pending:Record<string,Object>={};pending['id']='pending';pending['name']='';pending['category']='file';pending['state']='loading';
      const unavailable:Record<string,Object>={};unavailable['id']='unavailable';unavailable['name']='Unavailable';unavailable['state']='unavailable';
      const unsafe:Record<string,Object>={};unsafe['id']='unsafe';unsafe['name']='Unsupported';unsafe['url']='file:///private/secret';
      const row:Record<string,Object>={};row['id']=MESSAGE;row['content']='';row['sequence']=1;row['createdAt']=100;row['kind']='message';row['authorKind']='user';row['authorName']='Person';row['attachments']=[image,file,pending,unavailable,unsafe];
      const deleted=JSON.parse(JSON.stringify(row)) as Record<string,Object>;deleted['id']='deleted-message';deleted['deleted']=true;deleted['sequence']=2;
      const data:Record<string,Object>={};data['messages']=[row,deleted];const block:ChatResourceBlock={primitive:'bot-group-chat',data};
      const ref:ChatResourceRef={collectionId:'bot-groups',kind:'bot-group',id:ROOM};const resource:ChatResource={ref,blocks:[block]};
      const devices:string[]=[];
      const adapter=new ChatResourceAdapter(async(device:string,_channel:string,_args:Object[]):Promise<Object|undefined>=>{devices.push(device);return resource;},'real-host');
      const store=new ChatResourceStore('owner',ROOM,adapter,new ChatTestHostDisk());await store.refresh();
      expect(store.messages.length).assertEqual(2);expect(store.messages[0].content).assertEqual('');
      const items=store.messages[0].attachments;expect(items.map((a:ChatHostAttachment):string=>a.id).join(',')).assertEqual('image,file,pending,unavailable,unsafe');
      expect(items[0].reference).assertEqual(imageRef);expect(items[1].reference).assertEqual(fileRef);
      expect(items[2].state).assertEqual('loading');expect(items[2].name).assertEqual('');expect(items[3].state).assertEqual('unavailable');
      expect(items[4].reference).assertEqual('');expect(store.messages[1].attachments.length).assertEqual(0);
      expect(devices[0]).assertEqual('real-host');await store.shutdown();
    });
    // Production queue: one visible picture duplicated across rows must not cause
    // duplicate desktop uploads; thumbnail bytes must never satisfy original reads.
    // Minimal concurrency fixture: two active keys and one queued key. Unit, fake I/O.
    it('host_media_queue_coalesces_bounds_transfers_and_separates_thumbnail_from_original',0,async()=>{
      const calls:ChatTestMediaCall[]=[],finish:Array<(value:string)=>void>=[];
      const queue=new ChatHostThumbnailQueue((device:string,reference:string,thumbnail:boolean):Promise<string>=>{
        calls.push({device,reference,thumbnail});return new Promise<string>((resolve)=>{finish.push(resolve);});
      },():boolean=>true,():number=>1000);
      const first=queue.request('real-host','cindy-media://photo',true),duplicate=queue.request('real-host','cindy-media://photo',true);
      const original=queue.request('real-host','cindy-media://photo',false),next=queue.request('real-host','cindy-media://next',true);
      expect(calls.length).assertEqual(2);finish[0]('https://owned/thumb');
      expect(await first).assertEqual('https://owned/thumb');expect(await duplicate).assertEqual('https://owned/thumb');
      expect(calls.length).assertEqual(3);expect(calls[1].thumbnail).assertFalse();expect(calls[2].reference).assertEqual('cindy-media://next');
      finish[1]('https://owned/original');finish[2]('https://owned/next');
      expect(await original).assertEqual('https://owned/original');await next;
      expect(await queue.request('real-host','cindy-media://photo',true)).assertEqual('https://owned/thumb');expect(calls.length).assertEqual(3);queue.release();
    });
    // A fast scroll/account change while native transfers wait must neither start
    // queued invisible work nor publish a former owner's URL. Unit, manual promises.
    it('host_media_queue_discards_hidden_queue_and_late_account_results',0,async()=>{
      let current=true,wanted=true;const finish:Array<(value:string)=>void>=[];let calls=0;
      const queue=new ChatHostThumbnailQueue((_device:string,_reference:string,_thumbnail:boolean):Promise<string>=>{
        calls++;return new Promise<string>((resolve)=>{finish.push(resolve);});
      },():boolean=>current);
      const first=queue.request('host','cindy-media://one',true).then(():boolean=>false,():boolean=>true);
      const second=queue.request('host','cindy-media://two',true).then(():boolean=>false,():boolean=>true);
      const hidden=queue.request('host','cindy-media://hidden',true,():boolean=>wanted).then(():boolean=>false,():boolean=>true);
      wanted=false;current=false;finish[0]('https://former-account/one');
      expect(await first).assertTrue();expect(await hidden).assertTrue();expect(calls).assertEqual(2);
      queue.release();expect(await second).assertTrue();finish[1]('https://former-account/two');
    });
    // User retry must escape both passive failure cooldown and a cached URL rejected
    // by native Image decoding; passive scrolling must not bypass the cooldown.
    // Production queue, one address, no clock/network waits (unit).
    it('host_media_explicit_retry_invalidates_failed_and_decoding_failed_cached_url',0,async()=>{
      let calls=0,broken=true;
      const queue=new ChatHostThumbnailQueue(async(_device:string,_reference:string,_thumbnail:boolean):Promise<string>=>{
        calls++;if(broken)throw new Error('MEDIA_UNAVAILABLE');return 'https://owned/retry-'+calls;
      },():boolean=>true,():number=>1000);
      expect(await queue.request('host','cindy-media://one',true).then(():boolean=>false,():boolean=>true)).assertTrue();
      expect(await queue.request('host','cindy-media://one',true).then(():boolean=>false,():boolean=>true)).assertTrue();expect(calls).assertEqual(1);
      broken=false;expect(await queue.retry('host','cindy-media://one',true)).assertEqual('https://owned/retry-2');
      expect(await queue.request('host','cindy-media://one',true)).assertEqual('https://owned/retry-2');
      expect(await queue.retry('host','cindy-media://one',true)).assertEqual('https://owned/retry-3');expect(calls).assertEqual(3);
      queue.release();expect(await queue.request('host','cindy-media://one',true).then(():boolean=>false,():boolean=>true)).assertTrue();expect(calls).assertEqual(3);
    });
    // Home replaces its temporary-object lease on background. A quick foreground
    // resume must not re-publish deleted old URLs or let old finalizers remove a new
    // same-key job. Unit: one reference, manually settled native promises.
    it('host_media_background_reset_fences_inflight_and_keeps_new_same_key_request',0,async()=>{
      const finish:Array<(value:string)=>void>=[];let calls=0;
      const queue=new ChatHostThumbnailQueue((_device:string,_reference:string,_thumbnail:boolean):Promise<string>=>{
        calls++;return new Promise<string>((resolve)=>{finish.push(resolve);});
      },():boolean=>true);
      const old=queue.request('host','cindy-media://one',true).then(():boolean=>false,():boolean=>true);
      queue.reset();const fresh=queue.request('host','cindy-media://one',true);finish[0]('https://deleted-old-lease/one');expect(await old).assertTrue();
      const same=queue.request('host','cindy-media://one',true);expect(calls).assertEqual(2);
      finish[1]('https://new-lease/one');expect(await fresh).assertEqual('https://new-lease/one');expect(await same).assertEqual('https://new-lease/one');
      queue.reset();const afterReset=queue.request('host','cindy-media://one',true);expect(calls).assertEqual(3);finish[2]('https://another-lease/one');
      expect(await afterReset).assertEqual('https://another-lease/one');queue.release();
    });
    // Production draft book used by the native workspace. Regression: text-only
    // equality/page-object checks erased new files or restored a sent away-thread
    // draft as a fresh UUID intent. Minimal two keys/two files; unit, no I/O.
    it('draft_handoff_consumes_exact_away_snapshot_and_preserves_new_edits',0,()=>{
      const book=new ChatDraftBook(),sent=emptyChatDraft();sent.text='A';sent.revision=1;
      sent.attachments=[{type:'media',mediaId:'old-file'}];sent.mentions=[SELF];sent.mentionAll=true;sent.quoteId=MESSAGE;
      book.write('account/main',sent);
      const edited=book.read('account/main');edited.text='B';edited.revision=2;edited.attachments.push({type:'media',mediaId:'new-file'});
      edited.mentions=['new-mention'];edited.mentionAll=false;edited.mentionRevision=1;edited.quoteId='new-quote';edited.quoteRevision=1;
      book.write('account/main',edited);const other=emptyChatDraft();other.text='other thread';book.write('account/thread',other);
      const next=book.consume('account/main',sent);
      expect(next.text).assertEqual('B');expect(next.attachments.length).assertEqual(1);expect(next.attachments[0].mediaId).assertEqual('new-file');
      expect(next.quoteId).assertEqual('new-quote');expect(next.mentions[0]).assertEqual('new-mention');expect(book.read('account/thread').text).assertEqual('other thread');
      book.write('unchanged',sent);const cleared=book.consume('unchanged',sent);expect(cleared.text).assertEqual('');expect(cleared.attachments.length).assertEqual(0);expect(cleared.mentions.length).assertEqual(0);expect(cleared.quoteId).assertEqual('');
      const retyped:ChatDraftText={text:'A',revision:2};expect(consumeChatDraftText(retyped,sent).text).assertEqual('A');
    });
    // Original host send + real durable ownership callback. A timeout followed by
    // unknown-state write failure previously left a fresh-send composer with a
    // second clientId. New text entered during first persistence must remain.
    it('host_unknown_write_failure_hands_off_once_and_retry_keeps_original_id_body',0,async()=>{
      const disk=new ChatFailingHostDisk();disk.failAt=2;
      const sent:ChatDraftText={text:'A',revision:1};let draft:ChatDraftText={text:'A',revision:1},handoffs=0;
      disk.beforeWrite=(count:number):void=>{if(count===1)draft={text:'B',revision:2};};
      const bodies:string[]=[];
      const store=hostSendFixture(disk,async(input:Record<string,Object>):Promise<Object|undefined>=>{
        bodies.push(JSON.stringify(input));if(bodies.length===1)throw new Error('NETWORK_TIMEOUT');return undefined;
      });await store.refresh();let failed=false;
      try{await store.send(sent.text,[],'original-client-id',[],():void=>{handoffs++;draft=consumeChatDraftText(draft,sent);});}catch(_){failed=true;}
      expect(failed).assertTrue();expect(handoffs).assertEqual(1);expect(draft.text).assertEqual('B');expect(store.pending[0].clientId).assertEqual('original-client-id');expect(store.pending[0].state).assertEqual('unknown');
      await store.retry('original-client-id');expect(bodies.length).assertEqual(2);expect(bodies[0]).assertEqual(bodies[1]);expect(store.pending.length).assertEqual(0);expect(handoffs).assertEqual(1);await store.shutdown();
    });
    // Cloud send transfers ownership before waiting for the network. Switching to
    // another real Store thread during the request cannot restore an old draft;
    // a failed unknown-state write still leaves exactly the original pending ID.
    it('cloud_unknown_write_failure_consumes_old_thread_draft_before_rpc_and_preserves_new_thread',0,async()=>{
      const disk=new ChatFailingOutbox();disk.failAt=2;const book=new ChatDraftBook(),sent=emptyChatDraft();sent.text='A';sent.revision=1;book.write('main',sent);
      let rejectSend:(error:Error)=>void=(_error:Error):void=>{},started:()=>void=():void=>{};const start=new Promise<void>((resolve)=>{started=resolve;});const bodies:string[]=[];
      const store=cloudSendFixture(disk,(body:Object|undefined):Promise<Object>=>{
        bodies.push(JSON.stringify(body));if(bodies.length===1){started();return new Promise<Object>((_resolve,reject)=>{rejectSend=reject;});}return Promise.resolve(message());
      });await store.loadConversations();await store.open(ROOM);
      const body:ChatSendBody={operationId:'original-operation',content:[{type:'text',text:'A'}],mentions:[]};let handoffs=0;
      const sending=store.send(body,'',():void=>{handoffs++;book.consume('main',sent);}).then(():boolean=>false,():boolean=>true);
      await start;expect(book.read('main').text).assertEqual('');await store.open(ROOM,MESSAGE);
      const other=emptyChatDraft();other.text='new thread';book.write('thread',other);rejectSend(new Error('NETWORK_TIMEOUT'));
      expect(await sending).assertTrue();expect(book.read('main').text).assertEqual('');expect(book.read('thread').text).assertEqual('new thread');expect(handoffs).assertEqual(1);
      expect(store.pending[0].body.operationId).assertEqual('original-operation');expect(store.pending[0].state).assertEqual('unknown');
      await store.retry('original-operation');expect(bodies[0]).assertEqual(bodies[1]);expect(store.pending.length).assertEqual(0);await store.shutdown();
    });
    // Both real Stores: a failed first write dispatches nothing, never consumes a
    // draft, and cannot leave a phantom retry row alongside a later new intent.
    it('initial_outbox_failure_does_not_handoff_or_leave_retryable_host_or_cloud_intent',0,async()=>{
      let calls=0,handoffs=0;const cloudDisk=new ChatFailingOutbox();cloudDisk.failAt=1;
      const cloud=cloudSendFixture(cloudDisk,async():Promise<Object>=>{calls++;return message();});await cloud.loadConversations();await cloud.open(ROOM);
      const body:ChatSendBody={operationId:'not-dispatched',content:[{type:'text',text:'A'}],mentions:[]};
      let cloudFailed=false;try{await cloud.send(body,'',():void=>{handoffs++;});}catch(_){cloudFailed=true;}
      const hostDisk=new ChatFailingHostDisk();hostDisk.failAt=1;const host=hostSendFixture(hostDisk,async():Promise<Object|undefined>=>{calls++;return undefined;});await host.refresh();
      let hostFailed=false;try{await host.send('A',[],'not-dispatched',[],():void=>{handoffs++;});}catch(_){hostFailed=true;}
      expect(cloudFailed&&hostFailed).assertTrue();expect(calls).assertEqual(0);expect(handoffs).assertEqual(0);expect(cloud.pending.length).assertEqual(0);expect(host.pending.length).assertEqual(0);
      let drainFailed=false;try{await cloud.shutdown();}catch(_){drainFailed=true;}expect(drainFailed).assertTrue();await host.shutdown();
    });
    // A confirmed server response is not made unknown/replayed when removing its
    // durable row fails. Draft ownership was already handed off, once per intent.
    it('accepted_host_and_cloud_receipts_do_not_become_unknown_after_cleanup_write_failure',0,async()=>{
      let calls=0,handoffs=0;const cloudDisk=new ChatFailingOutbox();cloudDisk.failAt=2;
      const cloud=cloudSendFixture(cloudDisk,async():Promise<Object>=>{calls++;return message();});await cloud.loadConversations();await cloud.open(ROOM);
      const body:ChatSendBody={operationId:'accepted',content:[{type:'text',text:'A'}],mentions:[]};
      try{await cloud.send(body,'',():void=>{handoffs++;});}catch(_){}
      const hostDisk=new ChatFailingHostDisk();hostDisk.failAt=2;const host=hostSendFixture(hostDisk,async():Promise<Object|undefined>=>{calls++;return undefined;});await host.refresh();
      try{await host.send('A',[],'accepted',[],():void=>{handoffs++;});}catch(_){}
      expect(cloud.pending.length).assertEqual(0);expect(host.pending.length).assertEqual(0);expect(cloud.error).assertEqual('OUTBOX_NOT_SAVED');expect(host.error).assertEqual('OUTBOX_NOT_SAVED');
      let refusals=0;try{await cloud.retry('accepted');}catch(_){refusals++;}try{await host.retry('accepted');}catch(_){refusals++;}
      expect(refusals).assertEqual(2);expect(calls).assertEqual(2);expect(handoffs).assertEqual(2);
      let drainFailed=false;try{await cloud.shutdown();}catch(_){drainFailed=true;}expect(drainFailed).assertTrue();await host.shutdown();
    });
  });
}
