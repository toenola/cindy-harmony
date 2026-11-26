import {accountOffers,accountBoard} from '../entry/src/main/ets/core/device-link/portable/index.js';
/** Test value:
 * Production entry: RelayEnrollment/LegacyRelaySocket/RelayRoute, with a real V1 relay and Rust identity.
 * Contract: self-hosted-relay-plan §§5/16; credentials stay in their account/origin and forged frames never reach UI.
 * Gap: portable transport tests do not exercise ArkTS enrollment, V1 signatures, stored route selection or cancellation.
 * Minimal failures: a wrong certificate key, replayed invoke, other-account link, changed route during a request.
 * Tier: integration (loopback HTTP/WS, native library and temporary relay data); measured duration recorded in plan.
 */
import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {randomUUID,randomBytes,createPrivateKey} from 'node:crypto';
import WebSocket from '../.cache/interop/node_modules/ws/wrapper.mjs';
import {initializeRelay,startRelayServer,createDeviceCredential,createRelaySigningKey,issueRelayDeviceCert,RelayFrameAuthenticator,issueCertificate,nodeRelayAuthCrypto as crypto} from '../.cache/interop/server.mjs';
import {RelayAccountDirectory,LegacyRelaySocket,RelayEnrollment,RelayMembershipStore,RelayRoute,parseRelayJoinLink} from '../.cache/interop/arkts.mjs';
import {requests,interceptRequests,asset,AgentNetEngine,AgentNetEngineOptions} from './relay-test-platform.mjs';
const dataDir=await mkdtemp(path.join(tmpdir(),'cindy-harmony-v1-'));
const key=createRelaySigningKey(crypto),relayId=randomUUID(),credential=createDeviceCredential(),accountId='harmony-owner';
const ownerCert=issueRelayDeviceCert(crypto,key.seed,{relayId,deviceId:'desktop',publicKey:key.publicKey,role:'owner',issuedAt:Date.now()});
let relay,phone,desktop;const deadline=setTimeout(()=>{console.error('ArkTS interop deadline exceeded');process.exit(1)},25000);
try {
 await initializeRelay({dataDir,relayId,name:'Harmony V1',ownerUserId:accountId,ownerDeviceId:'desktop',ownerDeviceName:'Owner',ownerCredentialHash:credential.credentialHash,ownerPublicKey:key.publicKey,ownerCert});
 relay=await startRelayServer({dataDir,host:'127.0.0.1',port:0});
 const api=async(method,resource,body)=>{const r=await fetch(relay.localUrl+resource,{method,headers:{authorization:'CindyRelay '+credential.credential,'content-type':'application/json'},body:body?JSON.stringify(body):undefined});assert(r.ok,await r.clone().text());return r.status===204?null:r.json()};
 const code=await api('POST','/api/device-link/relay/admin/join-codes');
 const params=new URLSearchParams({u:relay.localUrl,c:code.code,o:key.publicKey,s:randomBytes(32).toString('base64url')});
 const uri='cindy://relay/join?'+params;
 assert(parseRelayJoinLink(uri));
 assert.equal(parseRelayJoinLink(uri.replace('u=http','u=ftp')),null);
 let waiting;
 const waitingStarted=new Promise(resolve=>{waiting=resolve});
 const enrollment=new RelayEnrollment();
 const joined=enrollment.join(uri,{realm:'cn',accountId,deviceId:'phone',deviceName:'Harmony'},()=>{},waiting);
 assert.match(await waitingStarted,/^\d{4}$/);
 const pending=(await api('GET','/api/device-link/relay/admin/pair-requests')).requests[0];
 const cert=issueRelayDeviceCert(crypto,key.seed,{relayId,deviceId:'phone',publicKey:pending.publicKey,role:'member',issuedAt:Date.now()});
 await api('POST','/api/device-link/relay/admin/pair-requests/'+pending.requestId+'/approve',{cert});
 assert.equal((await joined).mode,'legacy');
 const route=RelayRoute.instance;await route.prepare(accountId);
 assert.equal(route.apiBase,relay.localUrl);assert.match(route.authorization('OFFICIAL_TOKEN'),/^CindyRelay /);
 assert(!route.authorization('OFFICIAL_TOKEN').includes('OFFICIAL_TOKEN'));
 const stored=JSON.parse(await new RelayMembershipStore().read('cn',accountId,()=>{}));
 assert.equal(await new RelayMembershipStore().read('cn','other-account',()=>{}),null);
 const extended=JSON.stringify({...stored,padding:'x'.repeat(3000)});
 await new RelayMembershipStore().save('cn',accountId,extended,()=>{});
 assert.equal(await new RelayMembershipStore().read('cn',accountId,()=>{}),extended);
 const encrypted=Array.from(asset.records.values())[0];encrypted.get(asset.Tag.DATA_LABEL_NORMAL_1)[0]^=1;
 await assert.rejects(new RelayMembershipStore().read('cn',accountId,()=>{}),/RELAY_MEMBERSHIP_UNAVAILABLE/);
 await new RelayMembershipStore().save('cn',accountId,JSON.stringify(stored),()=>{});
 const auth=new RelayFrameAuthenticator({crypto,relayId,deviceId:'desktop',seed:key.seed,ownerPublicKey:key.publicKey});
 auth.setCertificates([ownerCert,cert]);
 desktop=new WebSocket(relay.localUrl.replace(/^http/,'ws')+'/api/device-link/ws',{headers:{Authorization:'CindyRelay '+credential.credential}});
 await new Promise((resolve,reject)=>{desktop.once('open',resolve);desktop.once('error',reject)});
 desktop.send(JSON.stringify({v:1,kind:'hello',payload:{deviceName:'Owner',platform:'darwin',appVersion:'test',remoteControlEnabled:true,busy:false}}));
 let response,received;
 const result=new Promise(resolve=>{response=resolve});
 const send=(kind,id,payload)=>{const frame={v:1,kind,id,dst:'phone',payload};frame.auth=auth.sign(frame);desktop.send(JSON.stringify(frame));return frame};
 desktop.on('message',data=>{
   const frame=JSON.parse(data.toString());if(!frame.src)return;
   assert.equal(auth.verify(frame),'ok');
   if(frame.payload?.channel==='device-link:relay-auth')send('push',randomUUID(),{channel:'device-link:relay-auth',payload:{type:'response'}});
   else if(frame.kind==='invoke')send('invoke-result',frame.id,{ok:true,result:'verified echo'});
 });
 phone=new LegacyRelaySocket(stored.membership,()=>route.assertGeneration(route.generation));
 let opened;const open=new Promise(resolve=>{opened=resolve});
 phone.setCallbacks({onOpen:opened,onClose(){},onError:error=>{throw error},onMessage:message=>{const frame=JSON.parse(message.toString());if(frame.kind==='invoke-result'){received=frame;response(frame)}}});
 phone.connect('',{});await open;
 phone.send(JSON.stringify({v:1,kind:'hello',payload:{deviceName:'Harmony',platform:'harmony',appVersion:'test',remoteControlEnabled:false,busy:false}}));
 phone.send(JSON.stringify({v:1,kind:'invoke',id:'echo',dst:'desktop',payload:{channel:'echo',args:[]}}));
 assert.equal((await result).payload.result,'verified echo');
 // Direct ingress is intentionally used for adversarial frames; their rejection must happen before UI delivery.
 let deliveries=0;phone.setCallbacks({onOpen(){},onClose(){},onError(){},onMessage(){deliveries++}});
 const forged={...received,id:'forged',payload:{ok:true,result:'forged'}};
 phone.socket.cb.onMessage({toString:()=>JSON.stringify(forged)});
 phone.socket.cb.onMessage({toString:()=>JSON.stringify(received)});
 assert.equal(deliveries,0,'forged and replayed frames must not reach UI');
 // Regression: one unavailable peer must not tear down the shared relay and healthy peers' subscriptions.
 const originalTimeout=globalThis.setTimeout;let peerTimeout,transportErrors=0,peerError;
 phone.setCallbacks({onOpen(){},onClose(){},onError(){transportErrors++},onMessage(message){const frame=JSON.parse(message.toString());if(frame.id==='offline-peer')peerError=frame}});
 try {
   globalThis.setTimeout=(fn,ms,...args)=>{if(ms===10000){peerTimeout=fn;return -12345}return originalTimeout(fn,ms,...args)};
   phone.send(JSON.stringify({v:1,kind:'invoke',id:'offline-peer',dst:'unavailable-desktop',payload:{channel:'echo',args:[]}}));
 }finally{globalThis.setTimeout=originalTimeout}
 assert(peerTimeout);peerTimeout();assert.equal(transportErrors,0);assert.equal(peerError.payload.code,'RELAY_PEER_AUTH_TIMEOUT');

 // The official preference service is a deterministic account-private fixture; the relay and crypto stay real.
 const inviteCode=await api('POST','/api/device-link/relay/admin/join-codes');
 const inviteUri='cindy://relay/join?'+new URLSearchParams({u:relay.localUrl,c:inviteCode.code,o:key.publicKey,s:randomBytes(32).toString('base64url')});
 let board={v:1,requests:{},invites:{}},revision=0,conflict=true,registeredKey,ownerUnavailable=false;
 interceptRequests(async(url,method,headers,body)=>{
   if(!url.startsWith('https://chat.cindy.app/v1/'))return;
   assert.equal(headers.Authorization,'Bearer ACCOUNT_TOKEN');
   const selected=new URL(url).searchParams.get('key');
   let result;
   if(method==='GET'&&selected==='relay.offers.v1')result=[{key:selected,revision:1,value:{v:1,offers:{desktop:{ownerDeviceName:'Owner',relayId,name:'Harmony V1',baseUrl:relay.localUrl,ownerPublicKey:key.publicKey,kind:'server',updatedAt:Date.now()}}}}];
   else if(method==='POST'){
     const write=JSON.parse(body);
     if(conflict){conflict=false;return {statusCode:409,body:'{}'}}
     assert.equal(write.expectedRevision,revision);board=write.value;revision++;result={};
   }else{
     const pending=board.requests['phone-auto'];
     if(pending){registeredKey=pending.publicKey;board.invites['phone-auto']={requestId:pending.requestId,relayId,...(ownerUnavailable?{error:'RELAY_UNAVAILABLE'}:{link:inviteUri}),expiresAt:Date.now()+60000}}
     result=[{key:'relay.join.v1',revision,value:board}];
   }
   return {statusCode:200,body:JSON.stringify(result)};
 });
 // Regression: Harmony has no global URL until an OS parser is installed. The account directory must do it itself.
 const originalURL=globalThis.URL,originalParams=globalThis.URLSearchParams;
 let directory;
 try {
   globalThis.URL=undefined;globalThis.URLSearchParams=undefined;
   directory=new RelayAccountDirectory(async()=>'ACCOUNT_TOKEN',()=>{});
   const fixture={v:1,offers:{desktop:{ownerDeviceName:'Owner',relayId,name:'Harmony V1',baseUrl:relay.localUrl,ownerPublicKey:key.publicKey,kind:'server',updatedAt:Date.now()}}};
   assert.equal(JSON.parse(accountOffers(JSON.stringify(fixture))).length,1,'account relays visible before an Agent-Net connection');
   assert(JSON.parse(accountBoard(JSON.stringify({v:1,requests:{},invites:{'phone-auto':{requestId:randomUUID(),relayId,link:inviteUri,expiresAt:Date.now()+60000}}}),Date.now())).invites['phone-auto'],'invitation parsing also works before Agent-Net connects');
 }finally{globalThis.URL=originalURL;globalThis.URLSearchParams=originalParams;}

 const offers=await directory.offers();assert.equal(offers.length,1);
 ownerUnavailable=true;
 await assert.rejects(directory.invite(offers[0],'phone-auto','Harmony'),/RELAY_OWNER_UNAVAILABLE/);
 assert.equal(Object.keys(board.requests).length,0,'failed account invitation is cleaned up');
 ownerUnavailable=false;
 const invitation=await directory.invite(offers[0],'phone-auto','Harmony');
 assert.equal(invitation.uri,inviteUri);assert.equal(Object.keys(board.requests).length,0);assert.equal(Object.keys(board.invites).length,0);
 interceptRequests(undefined);
 let autoWaiting;const autoReady=new Promise(resolve=>{autoWaiting=resolve});
 const autoJoin=new RelayEnrollment().join(invitation.uri,{realm:'cn',accountId,deviceId:'phone-auto',deviceName:'Harmony'},()=>{},autoWaiting,false,invitation.seed);
 await autoReady;
 const automatic=(await api('GET','/api/device-link/relay/admin/pair-requests')).requests[0];
 assert.equal(automatic.publicKey,registeredKey,'one-click enrollment must use the registered signing key');
 await api('POST','/api/device-link/relay/admin/pair-requests/'+automatic.requestId+'/approve',{cert:issueRelayDeviceCert(crypto,key.seed,{relayId,deviceId:'phone-auto',publicKey:registeredKey,role:'member',issuedAt:Date.now()})});
 await autoJoin;
 // A mixed station keeps both credentials; the explicit switch changes only the selected transport.
 const options=Object.assign(new AgentNetEngineOptions(),{seed:stored.membership.seed,context:relayId,deviceId:'phone'});
 const engine=await AgentNetEngine.create(options,()=>{});
 let identity;try{identity=JSON.parse(engine.command('{"op":"identity"}')).value}finally{engine.close()}
 const privateRoot=createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),Buffer.from(key.seed,'base64url')]),format:'der',type:'pkcs8'});
 stored.agentNet={networkId:'private:'+relayId,seed:stored.membership.seed,rootPublicKey:key.publicKey,
   certificate:issueCertificate(privateRoot,{networkId:'private:'+relayId,subject:accountId,identity,role:'member'})};
 await new RelayMembershipStore().save('cn',accountId,JSON.stringify(stored),()=>{});
 route.reset();await route.prepare(accountId);assert.equal(route.canToggleEncryption,true);
 await route.setEncryption(accountId,true);route.reset();await route.prepare(accountId);
 assert(route.agentNet);assert.equal(route.legacy,undefined);assert.throws(()=>route.authorization('OFFICIAL_TOKEN'));
 await route.setEncryption(accountId,false);route.reset();await route.prepare(accountId);
 assert(route.legacy);assert.equal(route.agentNet,undefined);
 const old=route.generation;await route.official(accountId);await route.prepare(accountId);
 assert.equal(route.custom,false);assert.equal(route.authorization('OFFICIAL_TOKEN'),'Bearer OFFICIAL_TOKEN');
 assert.throws(()=>route.assertGeneration(old));
 assert(requests.filter(r=>r.url.startsWith(relay.localUrl)).every(r=>!JSON.stringify(r.headers).includes('OFFICIAL_TOKEN')));
 console.log('PASS same-account invitation, CAS conflict and link cleanup; ArkTS V1 enrollment, native key and certificate, peer challenge, invoke, forgery/replay, account storage, encrypted-mode and official switch');
}finally{
 clearTimeout(deadline);phone?.terminate();desktop?.terminate();if(relay)await relay.close();await rm(dataDir,{recursive:true,force:true});
}
