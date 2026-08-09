/** 按任务持久化完整 ComposerDocument；400ms 防抖且旧异步写不能复活草稿。 */
import { common } from '@kit.AbilityKit';
import { SecureStore } from '../storage/SecureStore';
import {
  ComposerDocument,
  composerDocumentToStorage,
  parseStoredComposerDocument,
} from './ComposerDocument';

const KEY_PREFIX = 'composer.document.v1.';
const PERSIST_DEBOUNCE_MS = 400;

export class ComposerDraftStore {
  private store: SecureStore = new SecureStore();
  private memory: Map<string, ComposerDocument> = new Map();
  private generations: Map<string, number> = new Map();
  private timers: Map<string, number> = new Map();

  async init(context: common.Context): Promise<void> {
    await this.store.init(context);
  }

  private key(sessionId: string): string {
    return `${KEY_PREFIX}${encodeURIComponent(sessionId)}`;
  }

  async read(sessionId: string): Promise<ComposerDocument | null> {
    if (sessionId.length === 0) return null;
    const inMemory = this.memory.get(sessionId);
    if (inMemory !== undefined) return inMemory;
    const generation = this.generations.get(sessionId) ?? 0;
    const stored = await this.store.get(this.key(sessionId), '');
    const newer = this.memory.get(sessionId);
    if (newer !== undefined) return newer;
    if ((this.generations.get(sessionId) ?? 0) !== generation || stored.length === 0) return null;
    const parsed = parseStoredComposerDocument(stored);
    if (parsed !== null) this.memory.set(sessionId, parsed);
    return parsed;
  }

  save(sessionId: string, document: ComposerDocument): void {
    if (sessionId.length === 0) return;
    this.cancelTimer(sessionId);
    const generation = (this.generations.get(sessionId) ?? 0) + 1;
    this.generations.set(sessionId, generation);
    if (document.nodes.length === 0) {
      this.memory.delete(sessionId);
      void this.store.remove(this.key(sessionId));
      return;
    }
    this.memory.set(sessionId, document);
    const timer = setTimeout(() => {
      this.timers.delete(sessionId);
      if ((this.generations.get(sessionId) ?? 0) !== generation) return;
      const current = this.memory.get(sessionId);
      if (current !== document) return;
      void this.store.set(this.key(sessionId), composerDocumentToStorage(document));
    }, PERSIST_DEBOUNCE_MS);
    this.timers.set(sessionId, timer);
  }

  clear(sessionId: string): void {
    if (sessionId.length === 0) return;
    this.cancelTimer(sessionId);
    this.generations.set(sessionId, (this.generations.get(sessionId) ?? 0) + 1);
    this.memory.delete(sessionId);
    void this.store.remove(this.key(sessionId));
  }

  async flush(sessionId: string): Promise<void> {
    const current = this.memory.get(sessionId);
    this.cancelTimer(sessionId);
    if (current === undefined) return;
    await this.store.set(this.key(sessionId), composerDocumentToStorage(current));
  }

  private cancelTimer(sessionId: string): void {
    const timer = this.timers.get(sessionId);
    if (timer === undefined) return;
    clearTimeout(timer);
    this.timers.delete(sessionId);
  }
}
