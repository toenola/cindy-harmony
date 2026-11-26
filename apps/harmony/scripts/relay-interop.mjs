// Tier: integration. Exercises the shipped portable connection with the real Rust engine and relay.
// Protects certificate-bound request authentication, encrypted peer traffic and encrypted attachments.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {runInNewContext} from 'node:vm';
import {mkdtemp,rm,readFile} from 'node:fs/promises';
import {createHash,generateKeyPairSync,randomBytes,randomUUID,createHmac,verify} from 'node:crypto';
import {tmpdir} from 'node:os';
import path from 'node:path';
import koffi from '../.cache/interop/node_modules/koffi/index.js';
import WebSocket from '../.cache/interop/node_modules/ws/wrapper.mjs';
import {startAgentNetRelay,issueCertificate,publicBytes,initializeRelay,startRelayServer,createDeviceCredential,issueRelayDeviceCert,nodeRelayAuthCrypto} from '../.cache/interop/server.mjs';
import {AgentNetPairing,RelayEnrollment,RelayMembershipStore} from '../.cache/interop/arkts.mjs';
import {connect} from '../entry/src/main/ets/core/device-link/portable/index.js';
// Node normally supplies these globals; force the Harmony fallback to exercise UTF-8 and cancellation.
const globals={};
runInNewContext(await readFile('native/portable/polyfill.ts','utf8'),globals);
const unicode='Harmony 中文 😀 '+String.fromCharCode(0xd800);
const encoded=new globals.TextEncoder().encode(unicode);
assert.deepEqual(Buffer.from(encoded),Buffer.from(unicode));
assert.equal(new globals.TextDecoder().decode(encoded),Buffer.from(unicode).toString());
const abort=new globals.AbortController();let cancelled=0;
abort.signal.addEventListener('abort',()=>cancelled++);abort.abort();abort.abort();assert.equal(cancelled,1);
const library=koffi.load('.cache/agent-net-host/release/libcindy_agent_net_native.dylib');
const nativeCreate=library.func('void *cindy_agent_net_create(const uint8_t *data, size_t length)');
const nativeCommand=library.func('void *cindy_agent_net_command(void *handle, const uint8_t *data, size_t length)');
const nativeFree=library.func('void cindy_agent_net_free_string(void *value)');
const nativeDestroy=library.func('void cindy_agent_net_destroy(void *handle)');
const relayId=randomUUID(),networkId='private:'+relayId,accountId='interop-account';
const root=generateKeyPairSync('ed25519').privateKey,rootPublicKey=publicBytes(root);
const handles=new Set(),connections=[];
const dataDir=await mkdtemp(path.join(tmpdir(),'cindy-harmony-interop-'));
let relay,legacy,proxy;
function host(deviceId) {
  const seed=randomBytes(32).toString('base64url');
  const options=Buffer.from(JSON.stringify({seed,context:relayId,deviceId,legacySigning:true,udp:false}));
  let handle=nativeCreate(options,options.length);
  assert(handle);handles.add(handle);
  const h={
    seed,
    check(){assert(handle,'Engine still active');},
    parseUrl(value){const u=new URL(value);return JSON.stringify(Object.fromEntries(['protocol','hostname','host','username','password','search','hash','pathname','href'].map(k=>[k,u[k]])))},
    command(text){h.check();const input=Buffer.from(text),out=nativeCommand(handle,input,input.length);assert(out);
      try{return koffi.decode(out,'char',-1);}finally{nativeFree(out)}},
    destroy(){if(handle){handles.delete(handle);nativeDestroy(handle);handle=null;}},
    sha256(encoded){return createHash('sha256').update(Buffer.from(encoded,'base64url')).digest('base64url')},
    async request(url,method,headers,body){const r=await fetch(url,{method,headers:JSON.parse(headers),body:body||undefined,redirect:'error'});return JSON.stringify({status:r.status,body:await r.text()})},
    async binaryRequest(url,method,headers,body,binary){const r=await fetch(url,{method,headers:JSON.parse(headers),body:body?(binary?Buffer.from(body,'base64url'):body):undefined,redirect:'error'});return JSON.stringify({status:r.status,headers:Object.fromEntries(r.headers),body:Buffer.from(await r.arrayBuffer()).toString('base64url')})},
    socket(url,headers,cb){const ws=new WebSocket(url,{headers:JSON.parse(headers)});ws.on('open',()=>cb.open());ws.on('message',(bytes,binary)=>cb.message(binary?bytes.toString('base64url'):bytes.toString(),binary));ws.on('error',()=>cb.error());ws.on('close',code=>cb.close(code));return {send(text,binary){ws.send(binary?Buffer.from(text,'base64url'):text)},close(){ws.close()}}},
    message(text){h.onMessage?.(JSON.parse(text));},
    error(){},
    close(){},
  };
  h.identity=JSON.parse(h.command('{"op":"identity"}')).value;
  return h;
}
function config(host,certificate) {
  return JSON.stringify({baseUrl:relay.url,accountId,rootPublicKey,certificate,deviceId:host.identity.deviceId,relayId,seed:host.seed});
}
const timeout=setTimeout(()=>{console.error('Interop deadline exceeded');process.exit(1)},25000);
try {
  const desktop=host('desktop');
  const ownerCert=issueCertificate(root,{networkId,subject:accountId,identity:desktop.identity,role:'owner'});
  relay=await startAgentNetRelay({dataDir,host:'127.0.0.1',port:0,udpPort:0,mode:'self-hosted',
    bootstrap:{networkId,name:'Harmony interop',rootPublicKey,ownerCertificate:ownerCert}});
  const owner=await connect(config(desktop,ownerCert),desktop);connections.push(owner);
  owner.send(JSON.stringify({v:1,kind:'hello',payload:{deviceName:'Desktop',platform:'darwin',appVersion:'test',remoteControlEnabled:true,busy:false}}));
  const phone=host('phone');
  const code=JSON.parse(await owner.request('POST','/join-codes','{}')).joinCode;
  const cert=issueCertificate(root,{networkId,subject:accountId,identity:phone.identity,role:'member'});
  let approval;
  const link={baseUrl:relay.url,relayId,agentNetCode:code,pairSecret:'s'.repeat(43),ownerPublicKey:rootPublicKey};
  const membership=await new AgentNetPairing().join(link,accountId,'phone','Harmony',()=>{},()=>{
    approval=(async()=>{
      const requests=JSON.parse(await owner.request('GET','/join-requests')).requests;
      assert.equal(requests.length,1);
      await owner.request('POST','/join-requests/'+requests[0].requestId+'/approve',JSON.stringify({certificate:cert}));
    })();
  },phone.seed);
  await approval;
  assert.deepEqual(membership.certificate,cert);
  const controller=await connect(config(phone,cert),phone);connections.push(controller);
  controller.send(JSON.stringify({v:1,kind:'hello',payload:{deviceName:'Harmony',platform:'harmony',appVersion:'test',remoteControlEnabled:false,busy:false}}));
  assert.equal(JSON.parse(await controller.directory()).length,2);
  desktop.onMessage=frame=>{
    if(frame.kind==='link-open') owner.send(JSON.stringify({v:1,kind:'link-accept',id:frame.id,dst:frame.src,payload:{ok:true}}));
    if(frame.kind==='invoke') owner.send(JSON.stringify({v:1,kind:'invoke-result',id:frame.id,dst:frame.src,payload:{ok:true,result:{text:'encrypted echo'}}}));
  };
  function response(kind,frame){return new Promise(resolve=>{phone.onMessage=reply=>{if(reply.kind===kind&&reply.id===frame.id)resolve(reply)};controller.send(JSON.stringify(frame))})}
  assert.equal((await response('link-accept',{v:1,kind:'link-open',id:'link',dst:'desktop',payload:{controllerName:'Harmony'}})).payload.ok,true);
  assert.equal((await response('invoke-result',{v:1,kind:'invoke',id:'invoke',dst:'desktop',payload:{channel:'test:echo',args:[]}})).payload.result.text,'encrypted echo');
  const plain=Buffer.from('encrypted attachment '.repeat(60000));
  const key=await controller.upload('desktop',plain.toString('base64url'),'image/png');
  const opened=await controller.download(key);
  assert.deepEqual(Buffer.from(opened.split(',')[1],'base64'),plain);
  const desktopOpened=await owner.download(key);
  assert.deepEqual(Buffer.from(desktopOpened.split(',')[1],'base64'),plain);
  await controller.deleteMedia(key);
  // Exercise the real mixed-enrollment choreography against both production relay implementations.
  const rootSeed=Buffer.from(root.export({format:'der',type:'pkcs8'})).subarray(-32).toString('base64url');
  const ownerCredential=createDeviceCredential();
  const ownerLegacyCert=issueRelayDeviceCert(nodeRelayAuthCrypto,rootSeed,{relayId,deviceId:'desktop',publicKey:rootPublicKey,role:'owner',issuedAt:Date.now()});
  const legacyDir=path.join(dataDir,'legacy');
  await initializeRelay({dataDir:legacyDir,relayId,name:'Mixed station',ownerUserId:accountId,ownerDeviceId:'desktop',ownerDeviceName:'Desktop',ownerCredentialHash:ownerCredential.credentialHash,ownerPublicKey:rootPublicKey,ownerCert:ownerLegacyCert});
  legacy=await startRelayServer({dataDir:legacyDir,host:'127.0.0.1',port:0});
  const legacyApi=async(method,resource,body)=>{
    const result=await fetch(legacy.localUrl+resource,{method,headers:{authorization:'CindyRelay '+ownerCredential.credential,'content-type':'application/json'},body:body?JSON.stringify(body):undefined});
    assert(result.ok,await result.clone().text());return result.status===204?null:result.json();
  };
  proxy=createServer(async(req,res)=>{
    try{
      const parts=[];for await(const part of req)parts.push(part);
      const input=Buffer.concat(parts);
      const upstream=await fetch((req.url.startsWith('/api/agent-net/')?relay.url:legacy.localUrl)+req.url,
        {method:req.method,headers:{'content-type':'application/json',...(req.headers.authorization?{authorization:req.headers.authorization}:{}),...(req.headers['x-cindy-relay-poll-token']?{'x-cindy-relay-poll-token':req.headers['x-cindy-relay-poll-token']}:{})},body:input.length?input:undefined});
      res.writeHead(upstream.status,{'content-type':'application/json'});res.end(Buffer.from(await upstream.arrayBuffer()));
    }catch{res.writeHead(502);res.end('{}')}
  });
  await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));
  const mixedUrl='http://127.0.0.1:'+proxy.address().port;
  const oldCode=await legacyApi('POST','/api/device-link/relay/admin/join-codes');
  const newCode=JSON.parse(await owner.request('POST','/join-codes','{}')).joinCode;
  const mixedUri='cindy://relay/join?'+new URLSearchParams({u:mixedUrl,c:oldCode.code,a:newCode,o:rootPublicKey,s:'s'.repeat(43)});
  let dualApproval;
  const joined=await new RelayEnrollment().join(mixedUri,{realm:'cn',accountId,deviceId:'mixedphone',deviceName:'Harmony'},()=>{},()=>{
    dualApproval=(async()=>{
      const pending=(await legacyApi('GET','/api/device-link/relay/admin/pair-requests')).requests[0];
      const csr=JSON.parse(await owner.request('GET','/join-requests')).requests.find(x=>x.deviceId==='mixedphone');
      assert.equal(csr.signingKey,pending.publicKey,'V1 and V2 approvals must bind the same key');
      await legacyApi('POST','/api/device-link/relay/admin/pair-requests/'+pending.requestId+'/approve',{cert:issueRelayDeviceCert(nodeRelayAuthCrypto,rootSeed,{relayId,deviceId:'mixedphone',publicKey:pending.publicKey,role:'member',issuedAt:Date.now()})});
      await owner.request('POST','/join-requests/'+csr.requestId+'/approve',JSON.stringify({certificate:issueCertificate(root,{networkId,subject:accountId,identity:csr,role:'member'})}));
    })();
  },true);
  await dualApproval;assert.equal(joined.mode,'agent-net');
  const qualification=JSON.parse(await new RelayMembershipStore().read('cn',accountId,()=>{}));
  assert(qualification.membership.credential);assert(qualification.agentNet.certificate);assert.equal(qualification.membership.seed,qualification.agentNet.seed);
  console.log('PASS real relay approval, encrypted link and invoke, multi-block media to sender and recipient; dual V1/V2 enrollment');
} finally {
  clearTimeout(timeout);
  connections.forEach(c=>c.close());
  for(const handle of handles)nativeDestroy(handle);
  if(proxy){proxy.closeAllConnections();await new Promise(resolve=>proxy.close(resolve));}
  if(legacy)await legacy.close();
  if(relay)await relay.close();
  await rm(dataDir,{recursive:true,force:true});
}
