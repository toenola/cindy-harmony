// Asset generation only. Run from apps/harmony; never edits the existing owner portable bridge.
import { spawnSync } from 'node:child_process';
import { mkdirSync, copyFileSync, writeFileSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const harmony = path.resolve(here, '../../../../../../..');
const root = path.resolve(harmony, '../..');
const snapshot = path.join(harmony, '.cache/shared-task-portable-91179cedad');
mkdirSync(snapshot, { recursive: true });
const archive = spawnSync('git', ['archive', '91179cedad', 'packages/agent-net/src', 'packages/agent-net-protocol/src',
  'packages/device-link-protocol/src', 'packages/device-link/src/sharedTaskPeer.ts', 'packages/device-link/src/providerSharePeer.ts', 'packages/device-link/src/selfHostedRelayAuth.ts', 'packages/device-link/src/client.ts'],
  { cwd: root, maxBuffer: 64 * 1024 * 1024 });
if (archive.status !== 0) throw new Error('SHARING_SNAPSHOT_UNAVAILABLE');
const unpack = spawnSync('tar', ['-xf', '-', '-C', snapshot], { input: archive.stdout });
if (unpack.status !== 0) throw new Error('SHARING_SNAPSHOT_EXTRACTION_FAILED');
const relativeEntry = path.relative(root, path.join(here, 'SharingBridge.mjs'));
const entry = path.join(snapshot, relativeEntry);
mkdirSync(path.dirname(entry), { recursive: true }); copyFileSync(path.join(here, 'SharingBridge.mjs'), entry);
const polyfill = path.join(snapshot, 'apps/harmony/native/portable/polyfill.ts');
mkdirSync(path.dirname(polyfill), { recursive: true }); copyFileSync(path.join(harmony, 'native/portable/polyfill.ts'), polyfill);
const peers = path.join(snapshot, 'peers.ts');
const cooldown = readFileSync(path.join(snapshot, 'packages/device-link/src/client.ts'), 'utf8').match(/export function computeDuplicateIdentityCooldownMs\([\s\S]*?\n}\n/)?.[0];
if (!cooldown) throw new Error('SHARING_SNAPSHOT_COOLDOWN_MISSING');
writeFileSync(peers, "export {parseSharedTaskPeer,sharedTaskGuestPeer,sharedTaskHostPeer} from './packages/device-link/src/sharedTaskPeer.ts';\nexport {parseProviderSharePeer,providerShareGuestPeer,providerShareHostPeer} from './packages/device-link/src/providerSharePeer.ts';\nexport {decodeBase64Url,encodeBase64Url,utf8Bytes} from './packages/device-link/src/selfHostedRelayAuth.ts';\n" + cooldown + "\n");
const command = ['exec', ...(process.argv.includes('--allow-download') ? ['--yes'] : ['--offline']), '--cache', '.cache/npm',
  '--package', 'esbuild@0.28.2', '--', 'esbuild', entry, '--bundle', '--format=esm', '--platform=neutral', '--target=es2020',
  '--alias:@cindy/agent-net-protocol=' + path.join(snapshot, 'packages/agent-net-protocol/src/index.ts'),
  '--alias:@cindy/device-link-protocol=' + path.join(snapshot, 'packages/device-link-protocol/src/index.ts'),
  '--alias:@cindy/device-link=' + peers,
  '--banner:js=// Generated from fixed upstream 91179cedad; source: core/shared-tasks/portable/SharingBridge.mjs', '--outfile=' + path.join(here, 'sharing.js')];
const result = spawnSync('npm', command, { cwd: harmony, stdio: 'inherit' });
if (result.status !== 0) throw new Error('SHARING_PORTABLE_BUILD_FAILED');
