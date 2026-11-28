import { common, Want } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { systemShare } from '@kit.ShareKit';
import { MAX_ATTACHMENT_BYTES } from '../attachments/AttachmentModels';
import { IncomingShareFile, IncomingShareItem, IncomingShareStaging, IncomingShareStorage, IncomingShareStore } from './IncomingShareStore';

/** Private persistent inbox, not cacheDir: survives login/cold-start until explicit adoption/cancel. */
export class HarmonyIncomingShareStorage implements IncomingShareStorage {
  private path: string;
  constructor(context: common.Context) { this.path = context.filesDir + '/incoming-share-inbox-v1.json'; }
  async read(): Promise<string> { return fileIo.accessSync(this.path) ? fileIo.readTextSync(this.path) : ''; }
  async write(json: string): Promise<void> {
    const temp = this.path + '.tmp';
    const file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, json); fileIo.fsyncSync(file.fd); } finally { fileIo.closeSync(file); }
    fileIo.renameSync(temp, this.path);
  }
}
export class HarmonyIncomingShareStaging implements IncomingShareStaging {
  private root: string;
  constructor(context: common.Context) {
    this.root = context.filesDir + '/incoming-share-files';
    if (!fileIo.accessSync(this.root)) fileIo.mkdirSync(this.root);
  }
  async stage(uri: string, name: string, mime: string): Promise<IncomingShareFile> {
    if (!uri.startsWith('file://') && !uri.startsWith('datashare://')) throw new Error('INCOMING_SHARE_URI_UNSUPPORTED');
    const source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    const path = this.root + '/' + util.generateRandomUUID(false);
    try {
      const stat = await fileIo.stat(source.fd);
      if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_ATTACHMENT_BYTES) throw new Error('INCOMING_SHARE_FILE_SIZE');
      await fileIo.copyFile(source.fd, path);
      const copied = await fileIo.stat(path);
      if (copied.size !== stat.size || copied.size > MAX_ATTACHMENT_BYTES) throw new Error('INCOMING_SHARE_FILE_CHANGED');
      const result = new IncomingShareFile(); result.uri = fileUri.getUriFromPath(path);
      result.name = name.slice(0, 256) || 'attachment'; result.mime = mime || 'application/octet-stream'; result.size = copied.size;
      return result;
    } catch (error) {
      if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
      if (error instanceof Error) throw error; throw new Error('INCOMING_SHARE_FAILED');
    } finally { fileIo.closeSync(source); }
  }
  async remove(uri: string): Promise<void> {
    const path = new fileUri.FileUri(uri).path;
    const suffix = path.substring(this.root.length + 1);
    if (!path.startsWith(this.root + '/') || !/^[0-9a-f-]{36}$/i.test(suffix)) throw new Error('INCOMING_SHARE_NOT_OWNED');
    if (fileIo.accessSync(path)) fileIo.unlinkSync(path);
  }
}
/** API26 SDK: systemShare.getSharedData(Want).getRecords(). No guessed Want payload keys.
 * receiptId is the native ingress event identity. Repeated delivery of the same event must reuse it;
 * a deliberate later share of identical content must get a new identity. */
export async function receiveHarmonyShare(want: Want, receiptId: string, store: IncomingShareStore): Promise<boolean> {
  if (want.action !== 'ohos.want.action.sendData') return false;
  if (!receiptId) throw new Error('INCOMING_SHARE_RECEIPT_REQUIRED');
  const data = await systemShare.getSharedData(want);
  const records = data.getRecords();
  if (!records.length || records.length > 20) throw new Error('INCOMING_SHARE_ITEM_LIMIT');
  const items: IncomingShareItem[] = [];
  for (const record of records) {
    const item = new IncomingShareItem(); item.name = record.title ?? '';
    if (record.content && !record.uri) {
      const descriptor = uniformTypeDescriptor.getTypeDescriptor(record.utd);
      if (record.utd !== 'general.hyperlink' && !descriptor.belongsTo('general.text')) throw new Error('INCOMING_SHARE_TYPE_UNSUPPORTED');
      item.kind = record.utd === 'general.hyperlink' ? 'url' : 'text'; item.text = record.content;
    } else if (record.uri) {
      item.kind = 'file'; item.uri = record.uri;
      try {
        const descriptor = uniformTypeDescriptor.getTypeDescriptor(record.utd);
        item.mime = descriptor.mimeTypes[0] ?? 'application/octet-stream';
        if (!item.name) item.name = new fileUri.FileUri(record.uri).name;
        const extension = descriptor.filenameExtensions[0] ?? '';
        if (/^\.?[a-zA-Z0-9]{1,16}$/.test(extension)) {
          const suffix = extension.startsWith('.') ? extension : '.' + extension;
          if (!descriptor.filenameExtensions.some((ext: string): boolean => item.name.toLowerCase().endsWith(ext.startsWith('.') ? ext.toLowerCase() : '.' + ext.toLowerCase()))) item.name += suffix;
        }
        if (descriptor.belongsTo('general.image')) item.kind = 'image';
      } catch { throw new Error('INCOMING_SHARE_TYPE_UNSUPPORTED'); }
    } else throw new Error('INCOMING_SHARE_EMPTY_RECORD');
    items.push(item);
  }
  const digest = cryptoFramework.createMd('SHA256');
  await digest.update({ data: util.TextEncoder.create('utf-8').encodeInto(JSON.stringify(items)) });
  const bytes = (await digest.digest()).data; let fingerprint = '';
  for (let i = 0; i < bytes.length; i++) fingerprint += bytes[i].toString(16).padStart(2, '0');
  await store.receive(util.generateRandomUUID(false), receiptId, items, Date.now(), fingerprint); return true;
}

/** Reuses a receipt for repeated callbacks holding the same Want. Distinct Want objects with
 * equivalent content coalesce while pending by their SHA256 fingerprint; a later deliberate share
 * after adoption is allowed. The OS API exposes no documented universal cross-launch receipt ID. */
export class HarmonyIncomingShareReceiver {
  private receipts: WeakMap<Want, string> = new WeakMap();
  private store: IncomingShareStore;
  constructor(store: IncomingShareStore) { this.store = store; }
  receive(want: Want): Promise<boolean> {
    let receipt = this.receipts.get(want);
    if (!receipt) { receipt = util.generateRandomUUID(false); this.receipts.set(want, receipt); }
    return receiveHarmonyShare(want, receipt, this.store);
  }
}
