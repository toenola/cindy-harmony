import { ChatHomeAuthIdentity, captureChatHomeAccount } from '../../core/chat/ChatHomeAccount';
import { ChatHostMediaResolver, ChatHostMediaOpen } from '../../core/chat/ChatHostMedia';
import { common } from '@kit.AbilityKit';
import { AuthStore } from '../../core/auth/AuthStore';
import { SecureStore } from '../../core/storage/SecureStore';
import { ChatStore } from '../../core/chat/ChatStore';
import { ChatServerApi } from '../../core/chat/ChatServerApi';
import { ChatResourceAdapter, ChatRemoteInvoke, ChatResource, ChatResourceBlock, ChatResourceAction } from '../../core/chat/ChatResourceAdapter';
import { ChatHostDirectory } from '../../core/chat/ChatHostDirectory';
import { ChatResourceStore, ChatHostOutbox } from '../../core/chat/ChatResourceStore';
import { ChatInviteServices, createOfficialChatInviteServices } from '../../core/chat/ChatInviteServices';
import { ChatInviteServiceScope } from '../../core/chat/ChatInviteShares';
import { ChatAttachmentPicker } from '../../core/chat/ChatAttachmentPicker';
import { createChatAuthenticatedRequest, createAuthenticatedCloudRequest } from '../../core/chat/ChatAuthenticatedRequest';
import { pickChatAvatar } from '../../core/chat/ChatAvatarPicker';
import { ChatOwnedTaskTarget } from '../../core/chat/ChatCards';
import { ChatWorkspace } from '../../pages/chat/ChatWorkspace';
import { ChatResourceWorkspace } from '../../pages/chat/ChatResourceWorkspace';
import { ChatSettingsPanel } from './ChatSettingsPanel';
import { ChatInvitePanel } from './ChatInvitePanel';
import { ChatGroupCreatePanel } from './ChatGroupCreatePanel';
import { TeammateRosterEntry } from '../../core/tasks/TeammateRoster';
import { ResourceItem } from '../../core/resources/ResourceModels';
import { recordOrEmpty, readStr } from '../../core/tasks/TaskModels';
import { chatStrings, chatActionStrings, chatErrorText, chatDestructiveText } from '../../core/chat/ChatStrings';

export type ChatHomePushListener=(deviceId:string,channel:string,payload:Object|undefined)=>void;
export type ChatHomePushSubscribe=(listener:ChatHomePushListener)=>()=>void;
interface ChatHomeLabels { cloud:string;host:string;create:string;choose:string }
function homeLabels(locale:string):ChatHomeLabels{
  let w:string[];
  if(locale.startsWith('zh-TW')||locale.startsWith('zh-Hant'))w=['雲端群聊','電腦群聊','新建群聊','請選擇電腦'];
  else if(locale.startsWith('zh'))w=['云端群聊','电脑群聊','新建群聊','请选择电脑'];
  else if(locale.startsWith('ja'))w=['クラウドチャット','コンピューターのグループ','グループを作成','コンピューターを選択'];
  else if(locale.startsWith('ko'))w=['클라우드 그룹','컴퓨터 그룹','그룹 만들기','컴퓨터 선택'];
  else w=['Cloud chats','Computer groups','Create group','Choose a computer'];
  return {cloud:w[0],host:w[1],create:w[2],choose:w[3]};
}
/** Instance-owned native composition only. Auth, cloud Store/API and host transport remain root-owned. */
@Component
export struct ChatHomePanel {
  cloudStore:ChatStore|null=null;
  cloudApi:ChatServerApi|null=null;
  auth:AuthStore|null=null;
  secureStore:SecureStore|null=null;
  current:()=>boolean=():boolean=>false;
  resourceInvoke:ChatRemoteInvoke|null=null;
  subscribePush:ChatHomePushSubscribe|null=null;
  @Prop @Watch('receiveInitialInvitation') initialInvitation:string='';
  @Prop @Watch('reconcile') scopeKey:string='';
  @Prop @Watch('reconcile') foreground:boolean=true;
  @Prop @Watch('sourceChanged') selectedDevice:string='';
  @Prop locale:string='zh-CN';
  @Prop region:string='cn';
  @Prop realm:string='cn';
  @Prop chatBaseUrl:string='https://chat.cindy.app';
  @Prop shareBaseUrl:string='';
  @Prop ossBaseUrl:string='';
  @Prop localCompanions:TeammateRosterEntry[]=[];
  deviceName:(deviceId:string)=>string=(_device:string):string=>'';
  canControlDevice:(deviceId:string)=>boolean=(_device:string):boolean=>false;
  onLocalCompanion:(entry:TeammateRosterEntry)=>void=(_entry:TeammateRosterEntry):void=>{};
  onOwnedTask:(target:ChatOwnedTaskTarget)=>void=(_target:ChatOwnedTaskTarget):void=>{};
  onMedia:(room:string,id:string)=>void=(_room:string,_id:string):void=>{};
  resolveHostMedia:ChatHostMediaResolver=async(_device:string,_reference:string,_thumbnail:boolean):Promise<string>=>'';
  onHostMedia:ChatHostMediaOpen=(_device:string,_reference:string,_name:string,_mime:string):void=>{};
  onClose:()=>void=():void=>{};
  onSelectDevice:(()=>void)|null=null;
  onCloudVisibility:(visible:boolean,listVisible:boolean)=>void=(_visible:boolean,_list:boolean):void=>{};
  @State private mode:string='cloud';
  @State private ready:boolean=false;
  @State private version:number=0;
  @State private error:string='';
  @State private hostName:string='';
  @State private hostBusy:boolean=false;
  private alive:boolean=false;
  private generation:number=0;
  private hostNavigation:number=0;
  private prepared:string='';
  private invitationSeen:string='';
  private invitationNavigating:string='';
  private offInvitation:(()=>void)|null=null;
  private hostSource:string='';
  private services:ChatInviteServices|null=null;
  private picker:ChatAttachmentPicker|null=null;
  private storage:SecureStore|null=null;
  private directory:ChatHostDirectory|null=null;
  private adapter:ChatResourceAdapter|null=null;
  private host:ChatResourceStore|null=null;
  private offCloud:(()=>void)|null=null;
  private offHostDrain:(()=>void)|null=null;
  private offHost:(()=>void)|null=null;
  private offDirectory:(()=>void)|null=null;
  private offPush:(()=>void)|null=null;
  private closeTail:Promise<void>=Promise.resolve();
  aboutToAppear():void{
    this.alive=true;this.offCloud=this.cloudStore?.onChanged(():void=>{if(this.alive){this.version++;this.syncCloudVisibility();}})??null;
    this.offPush=this.subscribePush?.((device:string,channel:string,payload:Object|undefined):void=>this.push(device,channel,payload))??null;
    this.reconcile();
  }
  aboutToDisappear():void{this.alive=false;this.generation++;this.offCloud?.();this.offPush?.();this.offDirectory?.();this.offHost?.();this.offInvitation?.();this.services?.dispose();this.picker?.dispose();this.directory?.dispose();this.releaseHost();this.onCloudVisibility(false,false);}
  private syncCloudVisibility():void{this.onCloudVisibility(this.alive&&this.foreground&&(this.mode==='cloud'||this.mode==='settings'),this.mode==='cloud'&&this.cloudStore?.page===null);}
  private cloudScope():string{
    const auth=this.auth,store=this.cloudStore;
    return auth&&store?JSON.stringify([this.region,this.realm,store.owner,auth.cacheAccountId,auth.sessionEpoch,this.chatBaseUrl,this.shareBaseUrl,this.ossBaseUrl]):'';
  }
  private reconcile():void{
    if(!this.alive)return;this.syncCloudVisibility();if(!this.foreground||!this.current())return;
    const cloudScope=this.cloudScope();
    if(this.prepared!==cloudScope||!this.ready){this.prepared=cloudScope;this.prepare();}
    else {
      this.sourceChanged();this.receiveInitialInvitation();
      const invitation=this.services?.invitation,joined=invitation?.joinedRoom;
      if(this.mode==='invite'&&invitation?.phase==='joined'&&joined){this.invitationJoined(joined);return;}
      if(this.mode==='host-list')this.directory?.refresh();else if(this.mode==='host')this.host?.refresh();
    }
  }
  private async prepare():Promise<void>{
    const g=++this.generation,store=this.cloudStore,api=this.cloudApi,auth=this.auth;
    this.ready=false;this.invitationSeen='';this.offInvitation?.();this.offInvitation=null;this.services?.dispose();this.picker?.dispose();this.releaseHost();this.offDirectory?.();this.directory?.dispose();this.adapter?.dispose();this.directory=null;this.adapter=null;this.hostSource='';
    this.offCloud?.();this.offCloud=store?.onChanged(():void=>{if(this.alive){this.version++;this.syncCloudVisibility();}})??null;
    if(!store||!api||!auth||!this.current()){this.error='CHAT_UNAVAILABLE';return;}
    const accountCurrent=captureChatHomeAccount(new ChatHomeAuthIdentity(auth),this.current);
    const live=():boolean=>this.alive&&g===this.generation&&accountCurrent();
    try{
      const context=this.getUIContext().getHostContext() as common.UIAbilityContext;
      const storage=this.secureStore??new SecureStore();if(!this.secureStore)await storage.init(context);
      if(!live())return;this.storage=storage;
      const scope:ChatInviteServiceScope={region:this.region,realm:this.realm,shareBaseUrl:this.shareBaseUrl||undefined,current:live};
      this.services=createOfficialChatInviteServices(store.owner,api,auth,scope);
      this.offInvitation=this.services.invitation.onChanged(():void=>{if(live()){this.version++;if(this.services?.invitation.phase!=='joining')this.receiveInitialInvitation();}});
      this.picker=new ChatAttachmentPicker(context,createChatAuthenticatedRequest(auth,this.chatBaseUrl,live),live);
      this.mode='cloud';this.ready=true;this.error='';this.sourceChanged();this.receiveInitialInvitation();this.syncCloudVisibility();if(!this.incomingVisible())await store.ensureConversations();
    }catch(e){if(live())this.error=e instanceof Error?e.message:'CHAT_UNAVAILABLE';}
  }
  private incomingVisible():boolean{return this.mode==='invite';}
  private receiveInitialInvitation():void{
    const link=this.initialInvitation.trim();if(!link){this.invitationSeen='';return;}
    if(!this.alive||!this.ready||!this.foreground||!this.current()||!this.services)return;
    const key=JSON.stringify([this.prepared,link]);if(key===this.invitationSeen)return;
    if(this.services.invitation.phase==='joining')return;
    // This is an explicit incoming invite intent. Enter PREVIEW only; accept stays
    // exclusively in ChatInvitePanel's user-click handler.
    this.invitationSeen=key;this.releaseHost();this.mode='invite';this.syncCloudVisibility();
    this.services.invitation.read(link);
  }
  private async invitationJoined(id:string):Promise<void>{
    const store=this.cloudStore,g=this.generation,key=this.invitationSeen;
    if(!store||!this.alive||!this.foreground||!this.current()||this.invitationNavigating===id)return;
    this.invitationNavigating=id;
    try{
      await store.loadConversations();
      if(!this.alive||g!==this.generation||!this.current()||!this.foreground||this.mode!=='invite'||key!==this.invitationSeen)return;
      this.mode='cloud';this.syncCloudVisibility();await store.open(id);
    }catch(e){if(this.alive&&g===this.generation)this.error=e instanceof Error?e.message:'CHAT_UNAVAILABLE';}
    finally{if(this.invitationNavigating===id)this.invitationNavigating='';}
  }
  private closeInvitation():void{if(this.services?.invitation.phase==='joining')return;this.mode='cloud';this.syncCloudVisibility();this.cloudStore?.ensureConversations().catch((e:Object):void=>{if(this.alive)this.error=e instanceof Error?e.message:'CHAT_UNAVAILABLE';});}
  private scopedInvoke():ChatRemoteInvoke{
    const g=this.generation,invoke=this.resourceInvoke,auth=this.auth;
    const accountCurrent=auth?captureChatHomeAccount(new ChatHomeAuthIdentity(auth),this.current):():boolean=>false;
    return async(device:string,channel:string,args:Object[]):Promise<Object|undefined>=>{
      if(!this.alive||g!==this.generation||!accountCurrent()||!this.foreground||!invoke)throw new Error('OWNER_CHANGED');
      if(device!==this.selectedDevice||!this.canControlDevice(device))throw new Error('PERMISSION_DENIED');
      const result=await invoke(device,channel,args);
      if(!this.alive||g!==this.generation||!accountCurrent()||device!==this.selectedDevice)throw new Error('OWNER_CHANGED');return result;
    };
  }
  private sourceChanged():void{
    if(!this.alive||!this.ready)return;
    const source=JSON.stringify([this.scopeKey,this.selectedDevice]);if(source===this.hostSource)return;this.hostSource=source;
    this.offDirectory?.();this.directory?.dispose();this.adapter?.dispose();this.releaseHost();this.directory=null;this.adapter=null;
    if(this.mode.startsWith('host')||this.mode==='create')this.mode='cloud';
    if(this.selectedDevice&&this.resourceInvoke){
      const adapter=new ChatResourceAdapter(this.scopedInvoke(),this.selectedDevice,this.locale);this.adapter=adapter;
      this.directory=new ChatHostDirectory(adapter,this.locale,():boolean=>this.alive&&this.current()&&this.foreground);
      this.offDirectory=this.directory.onChanged(():void=>{this.version++;});
    }this.syncCloudVisibility();
  }
  private releaseHost():void{
    this.hostNavigation++;const old=this.host,remove=this.offHostDrain;this.offHost?.();this.offHost=null;this.offHostDrain=null;this.host=null;
    if(old){const drain=old.shutdown();this.closeTail=this.closeTail.catch(():void=>{}).then(():Promise<void>=>drain).then(():void=>{remove?.();},():void=>{remove?.();});}
  }
  private async showHostList():Promise<void>{if(!this.selectedDevice){this.onSelectDevice?.();return;}if(!this.directory){this.hostSource='';this.sourceChanged();}this.mode='host-list';this.syncCloudVisibility();this.releaseHost();await this.directory?.refresh();}
  private async showCreate():Promise<void>{if(!this.selectedDevice){this.onSelectDevice?.();return;}if(!this.directory){this.hostSource='';this.sourceChanged();}try{if(!await this.directory?.probe())throw new Error('UNSUPPORTED_OPERATION');this.mode='create';this.error='';this.syncCloudVisibility();}catch(e){this.error=e instanceof Error?e.message:'CHAT_UNAVAILABLE';}}
  private async openHost(id:string):Promise<void>{
    const device=this.selectedDevice,storage=this.storage,owner=this.cloudStore?.owner,g=this.generation;
    if(!device||!storage||!owner)return;this.releaseHost();const nav=this.hostNavigation;await this.closeTail;
    if(!this.alive||g!==this.generation||nav!==this.hostNavigation||!this.current()||!this.cloudStore)return;
    const adapter=new ChatResourceAdapter(this.scopedInvoke(),device,this.locale),host=new ChatResourceStore(owner,id,adapter,new ChatHostOutbox(storage));
    this.host=host;this.offHostDrain=this.cloudStore?.registerOwnedDrain(():Promise<void>=>host.shutdown())??null;this.offHost=host.onChanged(():void=>{this.version++;});this.mode='host';this.syncCloudVisibility();
    try{await host.restore();if(!this.alive||g!==this.generation||nav!==this.hostNavigation||!this.current()){await host.shutdown();return;}await host.refresh();}
    catch(e){if(this.alive&&g===this.generation&&nav===this.hostNavigation){this.error=e instanceof Error?e.message:'CHAT_UNAVAILABLE';this.releaseHost();}}
  }
  private push(device:string,channel:string,payload:Object|undefined):void{
    if(!this.alive||!this.current()||device!==this.selectedDevice)return;
    if(channel==='link-closed'){this.releaseHost();this.directory?.dispose();this.directory=null;this.hostSource='';this.error='SOURCE_OFFLINE';return;}
    if(!this.foreground||channel!=='maker:remote-resources:changed')return;
    const data=recordOrEmpty(payload);if(readStr(data,'collectionId')!=='bot-groups')return;
    if(this.mode==='host-list')this.directory?.refresh();
    const refs=data['resourceRefs'];
    if((this.mode==='host'||this.mode==='host-settings')&&this.host&&(!Array.isArray(refs)||(refs as Object[]).some((r:Object):boolean=>readStr(recordOrEmpty(r),'id')===this.host?.groupId)))this.host.refresh();
  }
  private async confirm(title:string,body:string):Promise<boolean>{return new Promise<boolean>((resolve)=>this.getUIContext().showAlertDialog({title,message:body,primaryButton:{value:chatActionStrings(this.locale).cancel,action:():void=>resolve(false)},secondaryButton:{value:chatActionStrings(this.locale).confirm,action:():void=>resolve(true)},cancel:():void=>resolve(false)}));}
  private async avatar():Promise<string>{const auth=this.auth,g=this.generation;if(!auth)return '';const accountCurrent=captureChatHomeAccount(new ChatHomeAuthIdentity(auth),this.current);const live=():boolean=>this.alive&&g===this.generation&&accountCurrent();return pickChatAvatar(createAuthenticatedCloudRequest(auth,this.ossBaseUrl||(this.region==='cn'?'https://oss.cindy.com.cn':'https://oss.cindy.app'),'/api/',live),live);}
  private async hostThumbnail(device:string,reference:string,thumbnail:boolean):Promise<string>{
    const auth=this.auth,g=this.generation,source=this.hostSource,host=this.host;
    if(!auth||!host||!this.alive||!this.foreground||!this.current()||device!==this.selectedDevice||!this.canControlDevice(device))throw new Error('OWNER_CHANGED');
    const accountCurrent=captureChatHomeAccount(new ChatHomeAuthIdentity(auth),this.current);
    const url=await this.resolveHostMedia(device,reference,thumbnail);
    if(!this.alive||!this.foreground||g!==this.generation||source!==this.hostSource||host!==this.host||!host.isActive()||!accountCurrent()||device!==this.selectedDevice||!this.canControlDevice(device))throw new Error('OWNER_CHANGED');
    return url;
  }
  private openHostMedia(device:string,reference:string,name:string,mime:string):void{
    if(!this.alive||!this.foreground||!this.current()||!this.host?.isActive()||device!==this.selectedDevice||!this.canControlDevice(device))return;
    this.onHostMedia(device,reference,name,mime);
  }
  private hostAction(id:string):boolean{return this.host?.resource?.actions?.some((a:ChatResourceAction):boolean=>a.id===id&&a.disabled!==true)??false;}
  private async hostAct(action:string):Promise<void>{
    if(this.hostBusy)return;const host=this.host;if(!host)return;this.hostBusy=true;
    try{if((action==='leave'||action==='dissolve')&&!await this.confirm(chatActionStrings(this.locale).confirm,chatDestructiveText(this.locale,action,this.hostName)))return;
      const input:Record<string,Object>={};if(action==='update')input['name']=this.hostName.trim();await host.perform(action,input);
      if(action==='leave'||action==='dissolve')await this.showHostList();this.error='';
    }catch(e){this.error=e instanceof Error?e.message:'CHAT_UNAVAILABLE';}finally{this.hostBusy=false;}
  }
  private cloudBack():void{if(this.cloudStore?.page)this.cloudStore.closePage();else this.onClose();}
  build(){
    Column({space:8}){
      Flex({wrap:FlexWrap.Wrap}){
        Button(homeLabels(this.locale).cloud).height(44).onClick(():void=>{this.mode='cloud';this.cloudStore?.closePage();this.syncCloudVisibility();})
        Button(this.selectedDevice?`${homeLabels(this.locale).host} · ${this.deviceName(this.selectedDevice)}`:homeLabels(this.locale).choose).height(44).enabled(!!this.selectedDevice||this.onSelectDevice!==null).onClick(():void=>{this.showHostList();})
        Button(homeLabels(this.locale).create).height(44).enabled(!!this.selectedDevice&&this.resourceInvoke!==null).onClick(():void=>{this.showCreate();})
      }.width('100%')
      if(this.error){Text(chatErrorText(this.locale,this.error)).fontColor($r('app.color.danger'))}
      if(!this.ready){LoadingProgress().width(32).height(32)}
      else if(this.mode==='invite'){
        Button(chatStrings(this.locale).back).height(44).enabled(this.version>=0&&this.services?.invitation.phase!=='joining').onClick(():void=>this.closeInvitation())
        ChatInvitePanel({store:this.services?.invitation??null,initialInput:this.initialInvitation,locale:this.locale,
          inputLabel:chatActionStrings(this.locale).invite,previewLabel:chatActionStrings(this.locale).preview,
          acceptLabel:chatActionStrings(this.locale).join,openLabel:chatStrings(this.locale).groups,retryLabel:chatStrings(this.locale).retry,
          uncertainLabel:chatStrings(this.locale).unknown,onJoined:(id:string):void=>{this.invitationJoined(id);}}).layoutWeight(1)
      }else if(this.mode==='settings'){
        Button(chatStrings(this.locale).back).height(44).onClick(():void=>{this.mode='cloud';this.syncCloudVisibility();})
        ChatSettingsPanel({store:this.cloudStore,locale:this.locale,shares:this.services?.shares??null,pickAvatar:():Promise<string>=>this.avatar(),confirm:(title:string,body:string):Promise<boolean>=>this.confirm(title,body)})
      }else if(this.mode==='create'){
        Button(chatStrings(this.locale).back).height(44).onClick(():void=>{this.mode='cloud';this.syncCloudVisibility();})
        ChatGroupCreatePanel({adapter:this.adapter,actors:this.cloudStore?.actors??[],locale:this.locale,onCreated:(id:string,_device:string):void=>{this.openHost(id);},onReviewUnknown:():void=>{this.showHostList();}}).layoutWeight(1)
      }else if(this.mode==='host-list'){
        if(this.version>=0&&this.directory?.loading){LoadingProgress().width(32).height(32)}
        if(this.version>=0&&this.directory?.error){Text(chatErrorText(this.locale,this.directory.error)).fontColor($r('app.color.danger'))}
        Button(chatStrings(this.locale).refresh).height(44).onClick(():void=>{if(!this.directory){this.hostSource='';this.sourceChanged();}this.directory?.refresh();})
        List(){
          ForEach(this.version>=0?this.directory?.items??[]:[],(item:ResourceItem)=>{ListItem(){Column({space:4}){Text(item.title).fontColor($r('app.color.text_primary'));Text(item.preview||item.subtitle).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(2)}.width('100%').padding(12).onClick(():void=>{this.openHost(item.ref.id);})}},(item:ResourceItem):string=>item.ref.id)
          if(this.directory?.nextCursor){ListItem(){Button(chatStrings(this.locale).older).height(44).onClick(():void=>{this.directory?.refresh(true);})}}
        }.width('100%').layoutWeight(1)
      }else if(this.mode==='host-settings'){
        Button(chatStrings(this.locale).back).height(44).onClick(():void=>{this.mode='host';})
        TextInput({text:this.hostName,placeholder:chatActionStrings(this.locale).name}).height(44).enabled(!this.hostBusy&&this.hostAction('update')).onChange((value:string):void=>{this.hostName=value;})
        if(this.hostAction('update')){Button(chatActionStrings(this.locale).save).height(44).enabled(!this.hostBusy&&!!this.hostName.trim()).onClick(():void=>{this.hostAct('update');})}
        if(this.hostAction('leave')){Button(chatActionStrings(this.locale).leave).height(44).enabled(!this.hostBusy).onClick(():void=>{this.hostAct('leave');})}
        if(this.hostAction('dissolve')){Button(chatActionStrings(this.locale).dissolve).height(44).enabled(!this.hostBusy).onClick(():void=>{this.hostAct('dissolve');})}
      }else if(this.mode==='host'){
        ChatResourceWorkspace({store:this.host,locale:this.locale,foreground:this.foreground,
          resolveHostMedia:(device:string,reference:string,thumbnail:boolean):Promise<string>=>this.hostThumbnail(device,reference,thumbnail),
          onHostMedia:(device:string,reference:string,name:string,mime:string):void=>this.openHostMedia(device,reference,name,mime),
          onBack:():void=>{this.showHostList();},onSettings:(resource:ChatResource):void=>{const name=resource.blocks.find((b:ChatResourceBlock):boolean=>b.primitive==='bot-group-chat')?.data['name'];this.hostName=typeof name==='string'?name:'';this.mode='host-settings';}}).layoutWeight(1)
      }else{
        ChatWorkspace({store:this.cloudStore,locale:this.locale,foreground:this.foreground,localCompanions:this.localCompanions,invitation:this.services?.invitation??null,attachmentPicker:this.picker,
          onBack:():void=>this.cloudBack(),onLocalCompanion:this.onLocalCompanion,deviceName:this.deviceName,canControlDevice:this.canControlDevice,onOwnedTask:this.onOwnedTask,onMedia:this.onMedia,onSettings:():void=>{this.mode='settings';this.syncCloudVisibility();}}).layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
