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

/** 异步草稿回读只能填充读取开始后从未被用户修改过的同一 Composer。 */
export function shouldApplyComposerDraftRead(
  expectedSessionId: string,
  currentSessionId: string,
  expectedGeneration: number,
  currentGeneration: number,
  expectedInputRevision: number,
  currentInputRevision: number,
  creationDraftHandoffDone: boolean,
): boolean {
  return expectedSessionId === currentSessionId
    && expectedGeneration === currentGeneration
    && expectedInputRevision === currentInputRevision
    && !creationDraftHandoffDone;
}

export class ComposerDraftStore {
  private store: SecureStore = new SecureStore();
  private memory: Map<string, ComposerDocument> = new Map();
  /** clear/空文档在当前进程内是权威状态，磁盘旧值不得在异步 remove 完成前回流。 */
  private cleared: Set<string> = new Set();
  private generations: Map<string, number> = new Map();
  private timers: Map<string, number> = new Map();
  /** 同一草稿键的 set/remove 必须严格有序，避免旧异步写在 clear 后复活内容。 */
  private operations: Map<string, Promise<void>> = new Map();

  async init(context: common.Context): Promise<void> {
    await this.store.init(context);
  }

  private key(sessionId: string): string {
    return `${KEY_PREFIX}${encodeURIComponent(sessionId)}`;
  }

  async read(sessionId: string): Promise<ComposerDocument | null> {
    if (sessionId.length === 0 || this.cleared.has(sessionId)) return null;
    const inMemory = this.memory.get(sessionId);
    if (inMemory !== undefined) return inMemory;
    const generation = this.generations.get(sessionId) ?? 0;
    const stored = await this.store.get(this.key(sessionId), '');
    if (this.cleared.has(sessionId)) return null;
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
      this.cleared.add(sessionId);
      void this.enqueueOperation(sessionId, (): Promise<void> => this.store.remove(this.key(sessionId)))
        .catch(() => {});
      return;
    }
    this.cleared.delete(sessionId);
    this.memory.set(sessionId, document);
    const timer = setTimeout(() => {
      this.timers.delete(sessionId);
      void this.persistIfCurrent(sessionId, generation, document).catch(() => {});
    }, PERSIST_DEBOUNCE_MS);
    this.timers.set(sessionId, timer);
  }

  clear(sessionId: string): void {
    if (sessionId.length === 0) return;
    this.cancelTimer(sessionId);
    this.generations.set(sessionId, (this.generations.get(sessionId) ?? 0) + 1);
    this.memory.delete(sessionId);
    this.cleared.add(sessionId);
    void this.enqueueOperation(sessionId, (): Promise<void> => this.store.remove(this.key(sessionId)))
      .catch(() => {});
  }

  async flush(sessionId: string): Promise<void> {
    const current = this.memory.get(sessionId);
    this.cancelTimer(sessionId);
    if (current === undefined) {
      await (this.operations.get(sessionId) ?? Promise.resolve());
      return;
    }
    const generation = this.generations.get(sessionId) ?? 0;
    await this.persistIfCurrent(sessionId, generation, current);
  }

  private persistIfCurrent(
    sessionId: string,
    generation: number,
    document: ComposerDocument,
  ): Promise<void> {
    return this.enqueueOperation(sessionId, async (): Promise<void> => {
      if ((this.generations.get(sessionId) ?? 0) !== generation
        || this.memory.get(sessionId) !== document) return;
      await this.store.set(this.key(sessionId), composerDocumentToStorage(document));
    });
  }

  private enqueueOperation(
    sessionId: string,
    operation: () => Promise<void>,
  ): Promise<void> {
    const previous = this.operations.get(sessionId) ?? Promise.resolve();
    const next = previous.catch(() => {}).then((): Promise<void> => operation());
    this.operations.set(sessionId, next);
    const cleanup = (): void => {
      if (this.operations.get(sessionId) === next) this.operations.delete(sessionId);
    };
    void next.then(cleanup, cleanup);
    return next;
  }

  private cancelTimer(sessionId: string): void {
    const timer = this.timers.get(sessionId);
    if (timer === undefined) return;
    clearTimeout(timer);
    this.timers.delete(sessionId);
  }
}
