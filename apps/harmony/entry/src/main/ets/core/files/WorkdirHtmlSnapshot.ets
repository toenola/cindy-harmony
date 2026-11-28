import { readStr, recordOrEmpty } from '../tasks/TaskModels';
import { safeWorkdirRelative, WorkdirRequest } from './WorkdirFiles';

export const WORKDIR_HTML_ORIGIN: string = 'https://cindy-file-preview.invalid/';
const LIMIT_BYTES: number = 4 * 1024 * 1024;
const LIMIT_FILES: number = 24;

export class WorkdirHtmlAsset {
  mime: string = '';
  body: string = '';
  bytes: ArrayBuffer | null = null;
}

export class WorkdirHtmlSnapshot {
  entry: string = '';
  resources: Map<string, WorkdirHtmlAsset> = new Map();
}

export function workdirHtmlUrl(path: string): string {
  return WORKDIR_HTML_ORIGIN + path.split('/').map((part: string): string => encodeURIComponent(part)).join('/');
}

function mimeFor(path: string): string {
  if (/\.html?$/i.test(path)) return 'text/html';
  if (/\.css$/i.test(path)) return 'text/css';
  if (/\.png$/i.test(path)) return 'image/png';
  if (/\.jpe?g$/i.test(path)) return 'image/jpeg';
  if (/\.gif$/i.test(path)) return 'image/gif';
  if (/\.webp$/i.test(path)) return 'image/webp';
  if (/\.woff2?$/i.test(path)) return 'font/woff2';
  return '';
}

export function htmlAssetPath(directory: string, relative: string): string {
  const raw = relative.trim().split(/[?#]/, 1)[0];
  if (!raw || raw.startsWith('/') || raw.includes(':') || raw.includes('\\')) return '';
  try {
    const decoded = decodeURIComponent(raw).replace(/^\.\//, '');
    if (!decoded || !safeWorkdirRelative(decoded)) return '';
    return directory ? directory + '/' + decoded : decoded;
  } catch (_error) {
    return '';
  }
}

export async function buildWorkdirHtmlSnapshot(root: string, entry: string,
  read: (request: WorkdirRequest) => Promise<Object | undefined>,
  readBinary: (path: string) => Promise<ArrayBuffer>, current: () => boolean): Promise<WorkdirHtmlSnapshot> {
  const snapshot = new WorkdirHtmlSnapshot();
  snapshot.entry = workdirHtmlUrl(entry);
  const todo: string[] = [entry];
  const seen: Set<string> = new Set([entry]);
  let budget = LIMIT_BYTES;
  while (todo.length > 0 && current()) {
    const path = todo.shift() ?? '';
    const mime = mimeFor(path);
    const asset = new WorkdirHtmlAsset();
    asset.mime = mime;
    if (mime.startsWith('text/')) {
      const result = recordOrEmpty(await read(new WorkdirRequest('readFile', root, path)));
      const payload = recordOrEmpty(result['data']);
      if (result['ok'] !== true || payload['truncated'] === true) {
        if (path === entry) throw new Error('HTML_PREVIEW_UNAVAILABLE');
        continue;
      }
      asset.body = readStr(payload, 'content');
      budget -= asset.body.length * 4;
    } else {
      // Do not start another file transfer after leaving the visible preview.
      try { asset.bytes = await readBinary(path); } catch (_error) { continue; }
      budget -= asset.bytes?.byteLength ?? 0;
    }
    if (budget < 0) throw new Error('HTML_PREVIEW_TOO_LARGE');
    snapshot.resources.set(workdirHtmlUrl(path), asset);
    if (asset.body.length === 0) continue;
    const split = path.lastIndexOf('/');
    const directory = split >= 0 ? path.substring(0, split) : '';
    const refs = /(?:\b(?:src|href|poster)\s*=\s*["']([^"']+)["']|\burl\(\s*["']?([^"'\s)]+))/gi;
    let match = refs.exec(asset.body);
    while (match !== null && seen.size < LIMIT_FILES) {
      const target = htmlAssetPath(directory, match[1] || match[2] || '');
      if (target && mimeFor(target) && !seen.has(target)) {
        seen.add(target);
        todo.push(target);
      }
      match = refs.exec(asset.body);
    }
  }
  if (!current()) throw new Error('OWNER_CHANGED');
  return snapshot;
}
