import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { ChatHistoryStorage, ChatHistoryState } from './ChatHistory';
import { chatId, chatCursor, ChatMessage, validateChatMessage } from './ChatModels';
/** Derived room cache in a dedicated app-private directory. No tokens/URLs in filenames. */
export class ChatHistoryFiles implements ChatHistoryStorage {
  private root: string;
  private current: () => boolean;
  private chain: Promise<void> = Promise.resolve();
  constructor(context: common.Context, current: () => boolean) {
    this.root = `${context.filesDir}/chat-history-v1`; this.current = current;
    if (!fileIo.accessSync(this.root)) fileIo.mkdirSync(this.root);
  }
  private check(): void { if (!this.current()) throw new Error('OWNER_CHANGED'); }
  private async tag(owner: string): Promise<string> {
    this.check(); const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: new util.TextEncoder().encodeInto(owner) }); const bytes = (await digest.digest()).data; this.check();
    return Array.from(bytes).map((b: number): string => b.toString(16).padStart(2, '0')).join('');
  }
  async read(owner: string, room: string): Promise<ChatHistoryState | null> {
    const path = `${this.root}/${await this.tag(owner)}-${chatId(room)}.json`; this.check();
    if (!fileIo.accessSync(path)) return null;
    if (fileIo.statSync(path).size > 4 * 1024 * 1024) throw new Error('CHAT_HISTORY_CACHE_FULL');
    const value = JSON.parse(fileIo.readTextSync(path)) as ChatHistoryState;
    if (value.version !== 1 || value.snapshot?.room?.id !== room || !Array.isArray(value.messages) || !Array.isArray(value.pages)) throw new Error('INVALID_CHAT_CACHE');
    chatCursor(value.cursor); value.messages.forEach((m: ChatMessage): void => { validateChatMessage(m); }); return value;
  }
  write(owner: string, room: string, state: ChatHistoryState | null): Promise<void> {
    const serialized = state ? JSON.stringify(state) : '';
    const task = this.chain.catch((): void => {}).then(async (): Promise<void> => {
      const tag = await this.tag(owner), path = `${this.root}/${tag}-${chatId(room)}.json`; this.check();
      if (!state) { if (fileIo.accessSync(path)) fileIo.unlinkSync(path); return; }
      if (serialized.length > 4 * 1024 * 1024) throw new Error('CHAT_HISTORY_CACHE_FULL');
      const bytes = new util.TextEncoder().encodeInto(serialized);
      if (bytes.byteLength > 4 * 1024 * 1024) throw new Error('CHAT_HISTORY_CACHE_FULL');
      const temp = `${path}.tmp`, file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { const written = fileIo.writeSync(file.fd, bytes.buffer); if (written !== bytes.byteLength) throw new Error('CHAT_HISTORY_WRITE_FAILED'); fileIo.fsyncSync(file.fd); }
      finally { fileIo.closeSync(file); }
      this.check(); fileIo.renameSync(temp, path);
      // All files here are derived cache owned by this adapter. Bound each owner to 32 rooms.
      const files = fileIo.listFileSync(this.root).filter((name: string): boolean => name.startsWith(`${tag}-`) && name.endsWith('.json'));
      files.sort((a: string, b: string): number => fileIo.statSync(`${this.root}/${a}`).mtime - fileIo.statSync(`${this.root}/${b}`).mtime);
      for (let i = 0; i < files.length - 32; i++) { const old = `${this.root}/${files[i]}`; if (old !== path) fileIo.unlinkSync(old); }
    }); this.chain = task; return task;
  }
  /** Call after ChatStore.shutdown on logout; deletes only this account's derived caches. */
  async clearOwner(owner: string): Promise<void> {
    await this.chain.catch((): void => {}); const tag = await this.tag(owner); this.check();
    const files = fileIo.listFileSync(this.root).filter((name: string): boolean => name.startsWith(`${tag}-`) && (name.endsWith('.json') || name.endsWith('.json.tmp')));
    files.forEach((name: string): void => { fileIo.unlinkSync(`${this.root}/${name}`); });
  }
}
