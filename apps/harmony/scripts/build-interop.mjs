import {build} from '../.cache/interop/node_modules/esbuild/lib/main.js';
import path from 'node:path';
const alias={
 '@cindy/device-link/node-relay-crypto':path.resolve('../../packages/device-link/src/nodeRelayCrypto.ts'),
 '@cindy/device-link/relay-auth':path.resolve('../../packages/device-link/src/selfHostedRelayAuth.ts'),
  '@cindy/agent-net-protocol':path.resolve('../../packages/agent-net-protocol/src/index.ts'),
  '@cindy/device-link-protocol':path.resolve('../../packages/device-link-protocol/src/index.ts'),
  '@cindy/device-link':path.resolve('../../packages/device-link/src/index.ts'),
  'ws':path.resolve('.cache/interop/node_modules/ws/wrapper.mjs'),
  'jose':path.resolve('.cache/interop/node_modules/jose/dist/webapi/index.js')
};
for(const [key,file] of Object.entries({'repositories':'repositories','errors':'errors','pages':'pages','shared-tasks':'sharedTasks','provider-shares':'providerShares'})){
 alias['@cindy/device-link-sharing/'+key]=path.resolve('../../packages/device-link-sharing/src/'+file+'.ts');
}
await build({banner:{js:"import {createRequire} from 'node:module';const require=createRequire(import.meta.url);"},entryPoints:['scripts/relay-interop-server.ts'],bundle:true,platform:'node',format:'esm',target:'node22',outfile:'.cache/interop/server.mjs',alias});
// Compile production ArkTS as TypeScript with only OS APIs replaced. No application logic is copied.
const {readFile}=await import('node:fs/promises');
const platform=path.resolve('scripts/relay-test-platform.mjs');
const source=path.resolve('entry/src/main/ets');
await build({stdin:{contents:[
 'RelayAccountDirectory','LegacyRelaySocket','LegacyRelayPairing','AgentNetPairing','RelayEnrollment','RelayMembershipStore','RelayJoinLink','RelayRoute'
].map(name=>`export * from ${JSON.stringify(source+'/core/device-link/'+name+'.ets')}`).join('\n'),resolveDir:process.cwd(),loader:'ts'},
 bundle:true,platform:'node',format:'esm',target:'node22',outfile:'.cache/interop/arkts.mjs',packages:'external',plugins:[{name:'harmony-platform',setup(build){
 build.onResolve({filter:/^@kit[.\/]/},()=>({path:platform,external:true}));
 build.onResolve({filter:/\/(AgentNetEngine|HarmonyHttp|HarmonyWsAdapter|AgentNetSocket)$/},()=>({path:platform,external:true}));
 build.onResolve({filter:/^\./},async args=>{const resolved=path.resolve(args.resolveDir,args.path);if(args.path.endsWith('.ets'))return {path:resolved};try{await readFile(resolved+'.ets');return {path:resolved+'.ets'}}catch{return undefined}});
 build.onLoad({filter:/\.ets$/},async args=>({contents:await readFile(args.path,'utf8'),loader:'ts'}));
 }}]});
