import './polyfill';
import { uploadNativeMedia, openNativeMediaReader } from '../../../../packages/agent-net/src/nativeMedia';
import { buildAgentNetMediaKey, parseAgentNetMediaKey, agentNetMediaBinding } from '../../../../packages/agent-net-protocol/src/index';
import { AgentNetSocket } from '../../../../packages/agent-net/src/portableSocket';
import { PortableAgentNetClient } from '../../../../packages/agent-net/src/portableClient';
import { NativeTransport } from '../../../../packages/agent-net/src/nativeTransport';
import { certificatePayload, certificatePolicyValid } from '../../../../packages/agent-net-protocol/src/index';
import { fromBase64Url, toBase64Url } from '../../../../packages/agent-net/src/portableBytes';

export async function connect(configText, host) {
  if (typeof globalThis.URL !== 'function') globalThis.URL=class {
    constructor(value){Object.assign(this,JSON.parse(host.parseUrl(value)));}
  };
  const config = JSON.parse(configText);
  const assertCurrent = () => host.check();
  let closed = false;
  const guard = () => { if (closed) throw new Error('AGENT_NET_CLOSED'); assertCurrent(); };
  const command = input => {
    guard();
    const reply = JSON.parse(host.command(JSON.stringify(input)));
    if (!reply.ok) throw new Error(reply.code || 'AGENT_NET_ENGINE_FAILED');
    return reply.value;
  };
  const engine = {
    command: async input => command(input),
    assertCurrent: guard,
    destroy: async () => host.destroy()
  };
  const identity = command({op:'identity'});
  const verifyCertificate = (root, certificate, now = Date.now()) => certificatePolicyValid(certificate, now)
    && command({op:'verify', key:root, text:certificatePayload(certificate), signature:certificate.signature}) === true;
  const sockets = new Set();
  const createWebSocket = (url, headers) => {
    const ws = {readyState:0, bufferedAmount:0, binaryType:'arraybuffer', onmessage:null, onerror:null, onclose:null,
      send(data) { guard(); wire.send(typeof data === 'string' ? data : toBase64Url(data), typeof data !== 'string'); },
      close() { sockets.delete(wire); wire.close(); }};
    const wire = host.socket(url, JSON.stringify(headers), {
      open() { ws.readyState=1; },
      message(data,binary) { if(!closed) ws.onmessage?.({data:binary ? fromBase64Url(data).buffer : data}); },
      error() { ws.onerror?.({message:'AGENT_NET_NETWORK_ERROR'}); },
      close(code) { ws.readyState=3; ws.onclose?.({code}); }
    });
    sockets.add(wire);
    return ws;
  };
  const fetch = async (url, init={}) => {
    guard();
    if (init.signal?.aborted) throw new Error('AGENT_NET_CANCELLED');
    const binary=init.body instanceof Uint8Array;
    const result=JSON.parse(await host.binaryRequest(url,init.method||'GET',JSON.stringify(init.headers||{}),
      binary?toBase64Url(init.body):(init.body||''),binary));
    guard();
    const bytes=fromBase64Url(result.body);
    return {ok:result.status>=200&&result.status<300,status:result.status,
      headers:{get(name){const key=Object.keys(result.headers||{}).find(k=>k.toLowerCase()===name.toLowerCase());return key?result.headers[key]:null}},
      json:async()=>JSON.parse(new TextDecoder().decode(bytes)),
      arrayBuffer:async()=>bytes.buffer};

  };
  const client = new PortableAgentNetClient(config.baseUrl, {
    identity,
    sign:async text=>command({op:'sign',text}),
    random:async()=>command({op:'random'})
  }, config.certificate, config.rootPublicKey, {
    assertCurrent:guard,
    sha256:bytes=>host.sha256(toBase64Url(bytes)),
    verifyCertificate, createWebSocket, fetch,
    ownerPinnedHttp:true,
    relayUdpEnabled:()=>false
  });
  let transport;
  let socket;
  try {
    socket = await AgentNetSocket.openWithBindings({
      client,userId:config.accountId,assertCurrent:guard,lanDiscovery:false,
      bindings: {
        verifyCertificate,
        createTransport: async options => {
          transport = await NativeTransport.create(engine,options,[],false);
          return transport;
        }
      }
    });
    socket.on('message', event => host.message(typeof event === 'string' ? event : event.toString()));
    socket.on('close', code=>host.close(code||1006));
    socket.on('error', ()=>host.error());
    return {
      send(text) {guard();socket.send(text);},
      async upload(deviceId,encoded,contentType) {
        guard();
        const bytes=fromBase64Url(encoded);
        if(bytes.length>30*1024*1024)throw new Error('ATTACHMENT_TOO_LARGE');
        const directory=await client.directory();guard();
        const recipient=directory.find(item=>item.certificate.deviceId===deviceId);
        if(!recipient)throw new Error('AGENT_NET_MEDIA_PEER_UNAVAILABLE');
        const result=await uploadNativeMedia(client,engine,deviceId,recipient.certificate.transportKey,bytes.length,
          async(offset,length)=>bytes.slice(offset,offset+length),{assertCurrent:guard,binding:agentNetMediaBinding(config.relayId)});
        return buildAgentNetMediaKey({slot:config.relayId,networkId:config.certificate.networkId,id:result.id,headerSha256:result.headerSha256,contentType});
      },
      async download(key) {
        guard();
        const ref=parseAgentNetMediaKey(key);
        if(!ref||ref.slot!==config.relayId||ref.networkId!==config.certificate.networkId||ref.grantId||ref.sharedTask)
          throw new Error('AGENT_NET_MEDIA_SCOPE_MISMATCH');
        const reader=await openNativeMediaReader(client,engine,ref.id,ref.headerSha256,{assertCurrent:guard,binding:agentNetMediaBinding(ref.slot)});
        try{
          if(reader.size>30*1024*1024)throw new Error('ATTACHMENT_TOO_LARGE');
          const output=new Uint8Array(reader.size);
          await reader.read(0,reader.size-1,async(bytes,offset)=>{output.set(bytes,offset);});
          guard();return 'data:'+ref.contentType+';base64,'+toBase64Url(output).replace(/-/g,'+').replace(/_/g,'/');
        }finally{await reader.close();}
      },
      async deleteMedia(key) {
        const ref=parseAgentNetMediaKey(key);
        if(!ref||ref.slot!==config.relayId||ref.networkId!==config.certificate.networkId)throw new Error('AGENT_NET_MEDIA_SCOPE_MISMATCH');
        await client.request('DELETE','/media/'+encodeURIComponent(ref.id));
      },
      close() {if(closed)return;socket.close();sockets.forEach(wire=>wire.close());sockets.clear();host.destroy();closed=true;},
      async request(method,resource,body){guard();return JSON.stringify(await client.request(method,resource,body?JSON.parse(body):undefined));},
      async directory() {guard();const devices=await client.directory();return JSON.stringify(devices);}
    };
  } catch(error) {
    socket?.close();sockets.forEach(wire=>wire.close());sockets.clear();await engine.destroy();closed=true;throw error;
  }
}

// Shared account-directory parsers keep Harmony's invitation rules identical to Mobile.
export { parseRelayAccountOffers, parseRelayAccountJoinBoard, serializeRelayAccountJoinBoard }
  from '../../../../packages/device-link/src/relayAccountDirectory';
import {parseRelayAccountOffers,parseRelayAccountJoinBoard,serializeRelayAccountJoinBoard} from '../../../../packages/device-link/src/relayAccountDirectory';
export function accountOffers(value){return JSON.stringify(parseRelayAccountOffers(JSON.parse(value)))}
export function accountBoard(value,now){return JSON.stringify(parseRelayAccountJoinBoard(JSON.parse(value),now))}
export function editAccountBoard(value,now,deviceId,requestId,request){
 const board=parseRelayAccountJoinBoard(JSON.parse(value),now);
 if(request){board.requests[deviceId]=JSON.parse(request);delete board.invites[deviceId]}
 else {if(board.requests[deviceId]?.requestId===requestId)delete board.requests[deviceId];if(board.invites[deviceId]?.requestId===requestId)delete board.invites[deviceId]}
 return JSON.stringify(serializeRelayAccountJoinBoard(board));
}
// Account-directory parsing runs before any Agent-Net connection exists.
export function installUrlParser(parse, query) {
  if (typeof globalThis.URLSearchParams !== 'function') globalThis.URLSearchParams = class {
    constructor(value) { this.values = JSON.parse(query(String(value))); }
    get(key) { return Object.prototype.hasOwnProperty.call(this.values, key) ? this.values[key] : null; }
  };
  if (typeof globalThis.URL !== 'function') globalThis.URL = class {
    constructor(value) { Object.assign(this, JSON.parse(parse(value))); }
  };
}
