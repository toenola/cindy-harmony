import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const harmony=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const result=spawnSync('npm',['exec','--yes','--cache','.cache/npm','--package','esbuild@0.28.2','--',
  'esbuild','native/portable/host.ts','--bundle','--format=esm','--platform=neutral','--target=es2020',
  '--alias:@cindy/agent-net-protocol=../../packages/agent-net-protocol/src/index.ts',
  '--alias:@cindy/device-link-protocol=../../packages/device-link-protocol/src/index.ts',
  '--alias:@cindy/device-link=../../packages/device-link/src/index.ts',
  '--outfile=entry/src/main/ets/core/device-link/portable/index.js'],{cwd:harmony,stdio:'inherit'});
if(result.status!==0)throw new Error('HARMONY_PORTABLE_BUILD_FAILED');
