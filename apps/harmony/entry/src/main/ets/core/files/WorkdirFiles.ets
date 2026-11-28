import { readStr, recordOrEmpty } from '../tasks/TaskModels';

export type WorkdirOp = 'listDir' | 'listAllFiles' | 'searchCollect' | 'readFile' | 'thumbnail' |
  'caps' | 'fileUrl' | 'exportFileStart' | 'exportFileStatus';

export class WorkdirRequest {
  op: WorkdirOp = 'listDir';
  workdir: string = '';
  relPath?: string;

  constructor(op: WorkdirOp, workdir: string, relPath?: string) {
    this.op = op;
    this.workdir = workdir;
    this.relPath = relPath;
  }

  showIgnoredDirs?: boolean;
  query?: string;
  cap?: number;
  maxMatches?: number;
  transferId?: string;
}

export function workdirListRequest(root: string, path: string, showIgnored: boolean,
  supported: boolean | undefined): WorkdirRequest {
  const request = new WorkdirRequest('listDir', root, path);
  if (showIgnored && supported === true) request.showIgnoredDirs = true;
  return request;
}

export function isWorkdirRead(op: WorkdirOp): boolean {
  return ['listDir', 'listAllFiles', 'searchCollect', 'readFile', 'thumbnail', 'caps', 'fileUrl',
    'exportFileStart', 'exportFileStatus'].indexOf(op) >= 0;
}

export function safeWorkdirRelative(path: string): boolean {
  if (!path) return true;
  return !path.includes('\\') && !path.includes(':') && !path.includes('\u0000') &&
    path.split('/').every((part: string): boolean => !!part && part !== '.' && part !== '..');
}

export class WorkdirEntry {
  name: string = '';
  path: string = '';
  folder: boolean = false;
  size: number = 0;
  modified: number = 0;
  line: number = 0;
  excerpt: string = '';

  constructor(name: string, path: string, folder: boolean, size: number, modified: number, line: number = 0) {
    this.name = name;
    this.path = path;
    this.folder = folder;
    this.size = size;
    this.modified = modified;
    this.line = line;
  }
}

export function workdirEntries(value: Object | undefined): WorkdirEntry[] {
  if (!Array.isArray(value)) return [];
  const rows: WorkdirEntry[] = [];
  (value as Object[]).forEach((item: Object): void => {
    const row = recordOrEmpty(item);
    const path = readStr(row, 'relPath');
    const name = readStr(row, 'name');
    const kind = readStr(row, 'type');
    if (path && name && safeWorkdirRelative(path) && (kind === 'directory' || kind === 'file')) {
      rows.push(new WorkdirEntry(name, path, kind === 'directory', Number(row['size']) || 0,
        Number(row['mtimeMs']) || 0));
    }
  });
  return rows;
}

export function workdirParent(path: string): string {
  const index = path.lastIndexOf('/');
  return index < 0 ? '' : path.substring(0, index);
}

export function workdirName(path: string): string {
  const parts = path.split(/[\\/]+/).filter((part: string): boolean => part.length > 0);
  return parts[parts.length - 1] ?? path;
}

export class WorkdirWatchListener {
  device: string = '';
  workdir: string = '';
  callback: () => void = (): void => {};
  current: () => boolean = (): boolean => false;

  dispatch(device: string, workdir: string): void {
    if (device === this.device && workdir === this.workdir && this.current()) this.callback();
  }

  constructor(device: string, workdir: string, callback: () => void, current: () => boolean) {
    this.device = device;
    this.workdir = workdir;
    this.callback = callback;
    this.current = current;
  }
}

/** Only expose an absolute chat target as a relative path inside the selected root. */
export function workdirRelative(root: string, absolute: string): string | null {
  if (!root || !absolute) return null;
  const windows = /^[a-z]:[\\/]/i.test(root) || root.startsWith('\\\\');
  const base = (windows ? root.replace(/\\/g, '/') : root).replace(/\/+$/, '');
  const target = (windows ? absolute.replace(/\\/g, '/') : absolute).replace(/\/+$/, '');
  const compareBase = windows ? base.toLowerCase() : base;
  const compareTarget = windows ? target.toLowerCase() : target;
  if (compareTarget === compareBase) return '';
  if (!compareTarget.startsWith(compareBase + '/')) return null;
  const relative = target.substring(base.length + 1);
  return safeWorkdirRelative(relative) ? relative : null;
}

export class WorkdirReadFence {
  private sequence: number = 0;

  capture(path: string, currentPath: () => string, ownerCurrent: () => boolean): () => boolean {
    const sequence = ++this.sequence;
    return (): boolean => sequence === this.sequence && path === currentPath() && ownerCurrent();
  }
}

export class WorkdirWatchDebounce {
  private revision: number = 0;

  next(current: () => boolean, refresh: () => void): () => void {
    const revision = ++this.revision;
    return (): void => {
      if (revision === this.revision && current()) refresh();
    };
  }

  cancel(): void {
    ++this.revision;
  }
}
