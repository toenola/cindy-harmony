import {URL as PlatformURL, URLSearchParams as PlatformURLParams} from 'node:url';
// Host adapters for the ArkTS integration test only; cryptography uses Node Ed25519 and the real Rust ABI.
import {createHash,createHmac,createPublicKey,createPrivateKey,sign,verify,randomBytes,randomUUID} from 'node:crypto';
import koffi from '../.cache/interop/node_modules/koffi/index.js';
import WebSocket from '../.cache/interop/node_modules/ws/wrapper.mjs';
const lib=koffi.load('.cache/agent-net-host/release/libcindy_agent_net_native.dylib');
const create=lib.func('void *cindy_agent_net_create(const uint8_t *data, size_t length)');
const command=lib.func('void *cindy_agent_net_command(void *handle, const uint8_t *data, size_t length)');
const free=lib.func('void cindy_agent_net_free_string(void *value)');
const destroy=lib.func('void cindy_agent_net_destroy(void *handle)');
export class AgentNetEngineOptions {legacySigning=true;udp=false;enhancedTransport=false;}
export class AgentNetEngine {
 static async create(options,guard){guard();const bytes=Buffer.from(JSON.stringify(options)),engine=new AgentNetEngine();engine.guard=guard;engine.handle=create(bytes,bytes.length);if(!engine.handle)throw Error('NATIVE_CREATE_FAILED');return engine;}
 command(text){this.guard();const bytes=Buffer.from(text),out=command(this.handle,bytes,bytes.length);if(!out)throw Error('NATIVE_COMMAND_FAILED');try{return koffi.decode(out,'char',-1)}finally{free(out)}}
 close(){if(this.handle){destroy(this.handle);this.handle=null;}}
}
class Encoder {static create(){return new Encoder()}encodeInto(text){return new TextEncoder().encode(text)}}
class Decoder {static create(){return new Decoder()}decodeToString(bytes){return new TextDecoder().decode(bytes)}}
export const util={TextEncoder:Encoder,TextDecoder:Decoder,generateRandomUUID:randomUUID,
 Base64Helper:class {encodeToStringSync(bytes){return Buffer.from(bytes).toString('base64')}decodeSync(text){return new Uint8Array(Buffer.from(text,'base64'))}}};
export const url={URL:{parseURL:text=>new PlatformURL(text)},URLParams:PlatformURLParams};
export const cryptoFramework={
 createRandom:()=>({generateRandomSync:size=>({data:new Uint8Array(randomBytes(size))})}),
 createMd:()=>{const hash=createHash('sha256');const update=value=>{hash.update(value.data)};const digest=()=>({data:new Uint8Array(hash.digest())});return {update:async value=>update(value),updateSync:update,digest:async()=>digest(),digestSync:digest}},
 createSymKeyGenerator:()=>({convertKey:async value=>value.data}),
 createMac:()=>{let mac;return {init:async key=>{mac=createHmac('sha256',key)},update:async value=>{mac.update(value.data)},doFinal:async()=>({data:new Uint8Array(mac.digest())})}},
 createAsyKeyGenerator:()=>({convertKeySync:(pub,pri)=>({pubKey:pub?createPublicKey({key:Buffer.from(pub.data),type:'spki',format:'der'}):undefined,priKey:pri?createPrivateKey({key:Buffer.from(pri.data),type:'pkcs8',format:'der'}):undefined})}),
 createSign:()=>{let key;return {initSync:value=>{key=value},signSync:value=>({data:new Uint8Array(sign(null,value.data,key))})}},
 createVerify:()=>{let key;return {initSync:value=>{key=value},verifySync:(value,sig)=>verify(null,value.data,key,sig.data)}}
};
export const asset={Tag:{ALIAS:1,SECRET:2,ACCESSIBILITY:3,SYNC_TYPE:4,CONFLICT_RESOLUTION:5,RETURN_TYPE:6,REQUIRE_ATTR_ENCRYPTED:7,DATA_LABEL_NORMAL_1:8,DATA_LABEL_NORMAL_2:9,DATA_LABEL_NORMAL_3:10,DATA_LABEL_NORMAL_4:11},Accessibility:{DEVICE_UNLOCKED:1},SyncType:{NEVER:0},ConflictResolution:{OVERWRITE:1},ReturnType:{ALL:1},ErrorCode:{NOT_FOUND:404},
 records:new Map(),async add(value){if(value.get(2).length>1024||value.get(7)!==true)throw Error('INVALID_ASSET_ATTRIBUTES');for(let tag=8;tag<=11;tag++){if(value.get(tag).length>2048)throw Error('INVALID_ASSET_LABEL')}asset.records.set(Buffer.from(value.get(1)).toString('hex'),new Map(value))},
 async query(value){if(value.get(7)!==true)throw {code:404};const found=asset.records.get(Buffer.from(value.get(1)).toString('hex'));if(!found)throw {code:404};return [found]},
 async remove(value){if(value.get(7)!==true)throw {code:404};asset.records.delete(Buffer.from(value.get(1)).toString('hex'))}};
export const requests=[];
let interceptor;
export function interceptRequests(handler){interceptor=handler;}
export class HarmonyHttp {
 async requestJson(url,method,headers,body,timeout,privateEndpoint){requests.push({url,method,headers:{...headers}});if(interceptor){const mocked=await interceptor(url,method,headers,body);if(mocked)return mocked}const r=await fetch(url,{method,headers:{'content-type':'application/json',...headers},body,redirect:privateEndpoint?'error':'follow',signal:AbortSignal.timeout(timeout||15000)});return {statusCode:r.status,body:await r.text()};}
}
export class HarmonyWsAdapter {
 setCallbacks(value){this.cb=value}
 connect(url,headers){this.ws=new WebSocket(url,{headers});this.ws.on('open',()=>this.cb.onOpen());this.ws.on('message',data=>this.cb.onMessage({toString:()=>data.toString()}));this.ws.on('error',error=>this.cb.onError(error));this.ws.on('close',(code,reason)=>this.cb.onClose(code,reason.toString()))}
 send(text){if(this.ws?.readyState!==WebSocket.OPEN)return false;this.ws.send(text);return true}
 close(code=1000,reason=''){this.ws?.close(code,reason)}terminate(){this.ws?.terminate()}
}
// The transport being tested here is the real LegacyRelaySocket. Agent-Net is covered by relay-interop.mjs.
export class AgentNetSocket {}
export class AgentNetSocketConfig {}

export const hilog={info(){},warn(){},error(){}};
