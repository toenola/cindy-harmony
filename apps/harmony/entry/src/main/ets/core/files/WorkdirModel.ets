import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { recordOrEmpty } from '../tasks/TaskModels';

const TOTAL_BYTES: number = 20 * 1024 * 1024;

function modelJson(path: string, bytes: ArrayBuffer): Object {
  let source = new Uint8Array(bytes);
  if (/\.glb$/i.test(path)) {
    if (bytes.byteLength < 20) throw new Error('MODEL_INVALID');
    const header = new DataView(bytes);
    const length = header.getUint32(12, true);
    if (header.getUint32(0, true) !== 0x46546c67 || header.getUint32(4, true) !== 2 ||
      header.getUint32(8, true) !== bytes.byteLength || header.getUint32(16, true) !== 0x4e4f534a ||
      length > bytes.byteLength - 20) throw new Error('MODEL_INVALID');
    source = new Uint8Array(bytes, 20, length);
  }
  return JSON.parse(util.TextDecoder.create('utf-8').decodeToString(source)) as Object;
}

export function localModelDependencies(value: Object): string[] {
  const root = recordOrEmpty(value);
  const dependencies: Set<string> = new Set();
  // Reject URLs anywhere in the document (including extensions), not only in
  // core glTF buffers/images, before handing it off to the native importer.
  const todo: Object[] = [root];
  while (todo.length > 0) {
    const item = todo.pop();
    if (!item || typeof item !== 'object') continue;
    if (Array.isArray(item)) {
      for (const child of (item as Object[])) todo.push(child);
      continue;
    }
    const record = recordOrEmpty(item);
    for (const key of Object.keys(record)) {
      const child = record[key];
      if (key.toLowerCase() !== 'uri') { if (child && typeof child === 'object') todo.push(child); continue; }
      if (typeof child !== 'string') throw new Error('MODEL_RESOURCE_INVALID');
      if (/^data:(?:application\/(?:octet-stream|gltf-buffer)|image\/(?:png|jpeg|webp|ktx2));base64,[A-Za-z0-9+/=]+$/i.test(child)) continue;
      if (!/^[A-Za-z0-9_-][A-Za-z0-9._-]{0,118}\.(?:bin|png|jpe?g|webp|ktx2)$/i.test(child)) {
        throw new Error('MODEL_RESOURCE_UNSAFE');
      }
      dependencies.add(child);
      if (dependencies.size > 16) throw new Error('MODEL_RESOURCE_LIMIT');
    }
  }
  return Array.from(dependencies);
}

export class WorkdirModelLease {
  private root: string;
  private paths: string[] = [];
  entry: string = '';

  constructor(context: common.Context) {
    this.root = context.cacheDir + '/cindy-workdir-model-' + util.generateRandomUUID();
    fileIo.mkdirSync(this.root);
  }

  write(name: string, bytes: ArrayBuffer): string {
    const path = this.root + '/' + name;
    this.paths.push(path);
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    try { fileIo.writeSync(file.fd, bytes); } finally { fileIo.closeSync(file); }
    return path;
  }

  dispose(): void {
    for (const path of this.paths) {
      try { fileIo.unlinkSync(path); } catch (_error) {}
    }
    this.paths = [];
    try { fileIo.rmdirSync(this.root); } catch (_error) {}
  }
}

export async function stageWorkdirModel(context: common.Context, path: string,
  fetch: (path: string, maxBytes: number) => Promise<ArrayBuffer>,
  current: () => boolean): Promise<WorkdirModelLease> {
  const main = await fetch(path, TOTAL_BYTES);
  if (!current() || main.byteLength > TOTAL_BYTES) throw new Error('MODEL_PREVIEW_UNAVAILABLE');
  const dependencies = localModelDependencies(modelJson(path, main));
  const parentEnd = path.lastIndexOf('/');
  const parent = parentEnd >= 0 ? path.substring(0, parentEnd + 1) : '';
  const lease = new WorkdirModelLease(context);
  let remaining = TOTAL_BYTES - main.byteLength;
  try {
    for (const name of dependencies) {
      if (!current() || remaining <= 0) throw new Error('MODEL_PREVIEW_UNAVAILABLE');
      const bytes = await fetch(parent + name, remaining);
      remaining -= bytes.byteLength;
      if (!current() || remaining < 0) throw new Error('MODEL_PREVIEW_UNAVAILABLE');
      lease.write(name, bytes);
    }
    lease.entry = lease.write(/\.glb$/i.test(path) ? 'model.glb' : 'model.gltf', main);
    return lease;
  } catch (error) {
    lease.dispose();
    throw (error instanceof Error ? error : new Error('MODEL_PREVIEW_UNAVAILABLE'));
  }
}
