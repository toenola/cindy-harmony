import { recordOrEmpty, readStr } from '../tasks/TaskModels';
/** Desktop groups keep their host resource identity; never pass these IDs to ChatServerApi. */
export type ChatRemoteInvoke = (deviceId: string, channel: string, args: Object[]) => Promise<Object | undefined>;
export interface ChatResourceRef { collectionId: string; kind: string; id: string }
export interface ChatResourceBlock { primitive: string; data: Record<string, Object> }
export interface ChatResourceAction { id: string; disabled?: boolean }
export interface ChatResource {
  ref: ChatResourceRef; blocks: ChatResourceBlock[]; actions?: ChatResourceAction[];
}
export class ChatResourceAdapter {
  private generation: number = 0;
  private invoke: ChatRemoteInvoke;
  readonly deviceId: string;
  private locale: string;
  constructor(invoke: ChatRemoteInvoke, deviceId: string, locale: string = 'zh-CN') { this.invoke = invoke; this.deviceId = deviceId; this.locale = locale;
    if (!deviceId) throw new Error('INVALID_HOST_IDENTITY');
  }
  dispose(): void { this.generation++; }
  async manifest():Promise<Object|undefined>{
    const g=this.generation,request:Record<string,Object>={};request['client']=this.client();
    const result=await this.invoke(this.deviceId,'maker:remote-resources:manifest',[request]);
    if(g!==this.generation)throw new Error('OWNER_CHANGED');return result;
  }
  async list(cursor: string = ''): Promise<Object | undefined> {
    const g = this.generation;
    const request: Record<string, Object> = {}; request['client'] = this.client(); request['collectionId'] = 'bot-groups';
    if (cursor) request['cursor'] = cursor;
    const result = await this.invoke(this.deviceId, 'maker:remote-resources:list', [request]);
    if (g !== this.generation) throw new Error('OWNER_CHANGED'); return result;
  }
  async get(id: string): Promise<ChatResource> {
    const g = this.generation;
    const request: Record<string, Object> = {}; request['client'] = this.client(); request['ref'] = this.ref(id);
    const result = await this.invoke(this.deviceId, 'maker:remote-resources:get', [request]) as ChatResource;
    if (g !== this.generation) throw new Error('OWNER_CHANGED');
    if (!result || result.ref?.collectionId !== 'bot-groups' || result.ref?.kind !== 'bot-group' || result.ref.id !== id
      || !Array.isArray(result.blocks) || !result.blocks.some((b: ChatResourceBlock): boolean => b.primitive === 'bot-group-chat')) throw new Error('UNSUPPORTED_GROUP_RESOURCE');
    return result;
  }
  /** Only host-declared enabled actions can be executed. No local role extrapolation. */
  async act(resource: ChatResource, actionId: string, input: Record<string, Object>): Promise<Object | undefined> {
    if (actionId === 'mask' || actionId === 'mask-mentions') throw new Error('UNSUPPORTED_OPERATION');
    const fresh = await this.get(resource.ref.id);
    const action = fresh.actions?.find((a: ChatResourceAction): boolean => a.id === actionId);
    if (!action || action.disabled === true) throw new Error('UNSUPPORTED_OPERATION');
    const g = this.generation;
    const request: Record<string, Object> = {}; request['client'] = this.client(); request['collectionId'] = 'bot-groups';
    request['resourceRef'] = this.ref(resource.ref.id); request['actionId'] = actionId; request['input'] = input;
    const result = await this.invoke(this.deviceId, 'maker:remote-resources:invoke', [request]);
    if (g !== this.generation) throw new Error('OWNER_CHANGED'); return result;
  }
  /** Official Mobile creates via the selected computer, not an invented cloud create body. */
  async create(name: string, botIds: string[]): Promise<Object | undefined> {
    if (!name.trim()) throw new Error('NAME_REQUIRED');
    const manifest=recordOrEmpty(await this.manifest()),collections=manifest['collections'];
    if(!Array.isArray(collections))throw new Error('UNSUPPORTED_OPERATION');
    const collection=(collections as Object[]).map((c:Object):Record<string,Object>=>recordOrEmpty(c)).find((c:Record<string,Object>):boolean=>readStr(c,'id')==='bot-groups'&&readStr(c,'resourceKind')==='bot-group');
    const actions=collection?.['actions'];
    if(!Array.isArray(actions)||!(actions as Object[]).some((a:Object):boolean=>{const row=recordOrEmpty(a);return readStr(row,'id')==='create'&&row['disabled']!==true;}))throw new Error('UNSUPPORTED_OPERATION');
    const g = this.generation;
    const input: Record<string, Object> = {}; input['name'] = name.trim(); input['botIds'] = botIds;
    const request: Record<string, Object> = {}; request['client'] = this.client(); request['collectionId'] = 'bot-groups';
    request['actionId'] = 'create'; request['input'] = input;
    const result = await this.invoke(this.deviceId, 'maker:remote-resources:invoke', [request]);
    if (g !== this.generation) throw new Error('OWNER_CHANGED'); return result;
  }
  private ref(id: string): ChatResourceRef { return { collectionId: 'bot-groups', kind: 'bot-group', id }; }
  private client(): Record<string, Object> {
    const value: Record<string, Object> = {}; value['protocolVersion'] = 1; value['locale'] = this.locale;
    value['primitives'] = ['status', 'session-link', 'session-controls', 'bot-group-chat']; return value;
  }
}
