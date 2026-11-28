import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { MAX_ATTACHMENT_BYTES } from '../attachments/AttachmentModels';
import { IncomingComposerDraftBridge, IncomingComposerFiles, IncomingComposerStorage } from './IncomingComposerDraftBridge';

export class HarmonyIncomingComposerStorage implements IncomingComposerStorage {
  private path: string;
  constructor(context: common.Context) { this.path = context.filesDir + '/incoming-composer-ledger-v1.json'; }
  read(): string { return fileIo.accessSync(this.path) ? fileIo.readTextSync(this.path) : ''; }
  write(json: string): void {
    const temp = this.path + '.tmp', file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, json); fileIo.fsyncSync(file.fd); } finally { fileIo.closeSync(file); }
    fileIo.renameSync(temp, this.path);
  }
}
/** Inbox and composer own disjoint paths. Every destination is journaled before it is created. */
export class HarmonyIncomingComposerFiles implements IncomingComposerFiles {
  private root: string;
  private inboxRoot: string;
  constructor(context: common.Context) {
    this.root = context.filesDir + '/incoming-composer-files';
    this.inboxRoot = context.filesDir + '/incoming-share-files';
  }
  allocate(name: string): string {
    let safeName = Array.from(name.replace(/[\x00-\x1f\x7f/\\:]/g, '_')).slice(-180).join('');
    const encoder = util.TextEncoder.create('utf-8');
    while (encoder.encodeInto(safeName).length > 200) safeName = Array.from(safeName).slice(1).join('');
    if (!safeName || safeName === '.' || safeName === '..') safeName = 'attachment';
    return fileUri.getUriFromPath(this.root + '/' + util.generateRandomUUID(false) + '/' + safeName);
  }
  private ownedPath(uri: string): string {
    const path = new fileUri.FileUri(uri).path;
    if (fileUri.getUriFromPath(path) !== uri || !path.startsWith(this.root + '/')) throw new Error('INCOMING_COMPOSER_NOT_OWNED');
    const segments = path.slice(this.root.length + 1).split('/');
    if (segments.length !== 2 || !/^[0-9a-f-]{36}$/i.test(segments[0]) || !segments[1] || segments[1] === '.' || segments[1] === '..') {
      throw new Error('INCOMING_COMPOSER_NOT_OWNED');
    }
    return path;
  }
  async copy(sourceUri: string, ownedUri: string, size: number): Promise<void> {
    const sourcePath = new fileUri.FileUri(sourceUri).path;
    const relative = sourcePath.slice(this.inboxRoot.length + 1);
    if (fileUri.getUriFromPath(sourcePath) !== sourceUri || !sourcePath.startsWith(this.inboxRoot + '/') || !/^[0-9a-f-]{36}$/i.test(relative)) throw new Error('INCOMING_COMPOSER_SOURCE_NOT_INBOX');
    if (!Number.isFinite(size) || size <= 0 || size > MAX_ATTACHMENT_BYTES) throw new Error('INCOMING_COMPOSER_FILE_SIZE');
    const path = this.ownedPath(ownedUri);
    if (fileIo.accessSync(path)) {
      if (fileIo.statSync(path).size === size) return;
      fileIo.unlinkSync(path);
    }
    const parent = path.slice(0, path.lastIndexOf('/'));
    if (!fileIo.accessSync(this.root)) fileIo.mkdirSync(this.root);
    if (!fileIo.accessSync(parent)) fileIo.mkdirSync(parent);
    const source = await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY), temp = path + '.partial';
    try {
      const stat = await fileIo.stat(source.fd);
      if (!stat.isFile() || stat.size !== size) throw new Error('INCOMING_COMPOSER_SOURCE_CHANGED');
      await fileIo.copyFile(source.fd, temp);
      const copied = await fileIo.open(temp, fileIo.OpenMode.READ_WRITE);
      try {
        if ((await fileIo.stat(copied.fd)).size !== size) throw new Error('INCOMING_COMPOSER_COPY_INCOMPLETE');
        fileIo.fsyncSync(copied.fd);
      } finally { fileIo.closeSync(copied); }
      fileIo.renameSync(temp, path);
    } catch (error) {
      if (fileIo.accessSync(temp)) fileIo.unlinkSync(temp);
      if (error instanceof Error) throw error;
      throw new Error('INCOMING_COMPOSER_COPY_FAILED');
    } finally { fileIo.closeSync(source); }
  }
  async remove(uri: string): Promise<void> {
    const path = this.ownedPath(uri), parent = path.slice(0, path.lastIndexOf('/'));
    if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
    if (fileIo.accessSync(path + '.partial')) fileIo.unlinkSync(path + '.partial');
    if (fileIo.accessSync(parent) && fileIo.listFileSync(parent).length === 0) fileIo.rmdirSync(parent);
  }
}
export function createHarmonyIncomingComposerBridge(context: common.Context): IncomingComposerDraftBridge {
  return new IncomingComposerDraftBridge(new HarmonyIncomingComposerStorage(context), new HarmonyIncomingComposerFiles(context));
}
