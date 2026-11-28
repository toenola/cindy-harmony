import { ChatResourceAdapter } from './ChatResourceAdapter';
import { ResourceItem, parseResourceItem } from '../resources/ResourceModels';
import { recordOrEmpty, readStr } from '../tasks/TaskModels';
import { chatError } from './ChatModels';

export class ChatHostDirectory {
  items: ResourceItem[]=[];
  canCreate: boolean=false;
  supported: boolean=false;
  nextCursor: string='';
  error: string='';
  loading: boolean=false;
  private adapter: ChatResourceAdapter;
  private locale: string;
  private current: ()=>boolean;
  private closed: boolean=false;
  private task: Promise<void>|null=null;
  private again: boolean=false;
  private listeners: Array<()=>void>=[];
  constructor(adapter:ChatResourceAdapter,locale:string,current:()=>boolean){this.adapter=adapter;this.locale=locale;this.current=current;}
  onChanged(fn:()=>void):()=>void{this.listeners.push(fn);return():void=>{this.listeners=this.listeners.filter((f:()=>void):boolean=>f!==fn);};}
  private live():boolean{return !this.closed&&this.current();}
  private notify():void{if(this.live())this.listeners.forEach((fn:()=>void):void=>fn());}
  refresh(more:boolean=false):Promise<void>{
    if(this.task){if(!more)this.again=true;return this.task;}
    const run=async():Promise<void>=>{
      do{this.again=false;await this.read(more);more=false;}while(this.again&&this.live());
    };
    const task=run().finally(():void=>{if(this.task===task)this.task=null;});this.task=task;return task;
  }
  async probe():Promise<boolean>{
    const manifest=recordOrEmpty(await this.adapter.manifest());if(!this.live())return false;
    const collections=manifest['collections'];if(!Array.isArray(collections))throw new Error('INVALID_RESOURCE_MANIFEST');
    const group=(collections as Object[]).map((r:Object):Record<string,Object>=>recordOrEmpty(r)).find((r:Record<string,Object>):boolean=>readStr(r,'id')==='bot-groups'&&readStr(r,'resourceKind')==='bot-group');
    this.supported=group!==undefined;this.canCreate=false;
    if(!group)throw new Error('UNSUPPORTED_OPERATION');
    const actions=group['actions'];if(Array.isArray(actions))this.canCreate=(actions as Object[]).some((a:Object):boolean=>{const row=recordOrEmpty(a);return readStr(row,'id')==='create'&&row['disabled']!==true;});
    this.notify();return this.canCreate;
  }
  private async read(more:boolean):Promise<void>{
    if(!this.live())return;this.loading=true;this.notify();
    try{
      await this.probe();if(!this.live())return;
      const response=recordOrEmpty(await this.adapter.list(more?this.nextCursor:''));if(!this.live())return;
      if(readStr(response,'collectionId')!=='bot-groups'||!Array.isArray(response['items']))throw new Error('INVALID_GROUP_DIRECTORY');
      const parsed:ResourceItem[]=[];
      (response['items'] as Object[]).forEach((row:Object):void=>{const item=parseResourceItem(row,'bot-groups',this.locale);if(item?.ref.kind==='bot-group')parsed.push(item);});
      const known=new Set((more?this.items:[]).map((i:ResourceItem):string=>i.ref.id));
      this.items=more?this.items.concat(parsed.filter((i:ResourceItem):boolean=>!known.has(i.ref.id))):parsed;
      const next=readStr(response,'nextCursor');if(more&&next&&next===this.nextCursor)throw new Error('INVALID_CHAT_PAGE');
      this.nextCursor=next;this.error='';
    }catch(e){if(this.live()){this.error=chatError(e);if(!more){this.items=[];this.canCreate=false;}}}
    finally{if(this.live()){this.loading=false;this.notify();}}
  }
  dispose():void{this.closed=true;this.adapter.dispose();this.items=[];this.listeners=[];}
}
