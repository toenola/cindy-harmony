// Unit tier: actual PersistentInputOutbox public API under a deterministic SDK fake.
// Basis: local-storage ownership rule / v1.3.9 incoming rollback. Minimal failure:
// one unlink error or one sendStarted record must not lose its durable ownership.
// No native account, files, network or timers. Lead runs serially with its TS compiler.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const ts = require(process.env.CINDY_ARKTS_TYPESCRIPT || 'typescript');
const source = new URL('../main/ets/core/messages/PersistentInputOutbox.ets', import.meta.url);
const disk = new Map(), handles = new Map(); let nextFd = 0, unlinkCode = 0, unlinkCalls = 0;
const error = code => Object.assign(new Error('SDK fake error'), { code });
const fileIo = {
  OpenMode: { READ_ONLY: 1, CREATE: 2, READ_WRITE: 4, TRUNC: 8 },
  mkdirSync() {}, listFileSync(dir) { return [...disk.keys()].filter(p => p.startsWith(dir + '/')).map(p => p.slice(dir.length + 1)); },
  openSync(path, mode) { if (mode & 2) disk.set(path, ''); else if (!disk.has(path)) throw error(13900002); const fd = ++nextFd; handles.set(fd, path); return { fd }; },
  closeSync() {}, statSync(fd) { return { size: Buffer.byteLength(disk.get(handles.get(fd)) || '') }; },
  readSync(fd, buffer) { const bytes = Buffer.from(disk.get(handles.get(fd))); new Uint8Array(buffer).set(bytes); return bytes.length; },
  writeSync(fd, text) { disk.set(handles.get(fd), text); return text.length; },
  renameSync(from, to) { disk.set(to, disk.get(from)); disk.delete(from); },
  unlinkSync(path) { unlinkCalls++; if (unlinkCode) throw error(unlinkCode); if (!disk.delete(path)) throw error(13900002); },
};
const exports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(source, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText,
  { exports, require(name) { if (name === '@kit.CoreFileKit') return { fileIo }; if (name === '@kit.ArkTS') return { util: { TextDecoder: { create: () => ({ decodeToString: bytes => new TextDecoder().decode(bytes) }) } } }; return {}; }, Math, Map, Object, Array, JSON, Error });
const { PersistentInputOutbox } = exports;
function store() { const box = new PersistentInputOutbox(); box.init({ filesDir: '/fake' }); box.setAccountScope('owner'); return box; }
function item(id) { return { clientId: id, text: 'Shared', persistedContent: '{}', chatMessage: { createdAt: id } }; }
let box = store(); box.put('device', 'session', item('a'), false);
unlinkCode = 13900012; assert.throws(() => box.removeReservedStrict('device', 'session', 'a'));
assert.equal(box.forSession('device', 'session').length, 1); assert.equal(disk.size, 1);
unlinkCode = 0; box = store(); assert.equal(box.forSession('device', 'session').length, 1);
box.put('device', 'session', item('a'), true); const before = unlinkCalls;
assert.throws(() => box.removeReservedStrict('device', 'session', 'a')); assert.equal(unlinkCalls, before);
assert.equal(box.forSession('device', 'session')[0].sendStarted, true);
box.put('device', 'session', item('a'), false); box.removeReservedStrict('device', 'session', 'a');
assert.equal(box.forSession('device', 'session').length, 0); assert.equal(disk.size, 0);
// A missing file is accepted ONLY for the SDK's precise ENOENT code.
box.put('device', 'session', item('a'), false); disk.clear();
box.removeReservedStrict('device', 'session', 'a'); assert.equal(box.forSession('device', 'session').length, 0);
box.put('device', 'session', item('b'), false); unlinkCode = 'ENOENT';
assert.throws(() => box.removeReservedStrict('device', 'session', 'b')); assert.equal(box.forSession('device', 'session').length, 1);
console.log('PersistentInputOutbox strict reservation SDK fake: passed');
