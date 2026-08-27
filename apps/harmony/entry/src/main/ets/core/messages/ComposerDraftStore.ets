/** 按任务持久化完整 ComposerDocument；400ms 防抖且旧异步写不能复活草稿。 */
import { common } from '@kit.AbilityKit';
import { SecureStore } from '../storage/SecureStore';
import {
  ComposerDocument,
  composerDocumentToStorage,
  parseStoredComposerDocument,
} from './ComposerDocument';

const LEGACY_KEY_PREFIX = 'composer.document.v1.';
const SCOPED_KEY_PREFIX = 'composer.document.v2.';
const PERSIST_DEBOUNCE_MS = 400;

/** 内存与持久化键都按设备隔离；空 deviceId 保留新建页的全局草稿语义。 */
export function composerDraftScopeKey(sessionId: string, deviceId: string = ''): string {
  return `${deviceId}\u0000${sessionId}`;
}

export function composerDraftStorageKey(sessionId: string, deviceId: string = ''): string {
  if (deviceId.length === 0) {
    return `${LEGACY_KEY_PREFIX}${encodeURIComponent(sessionId)}`;
  }
  return `${SCOPED_KEY_PREFIX}${encodeURIComponent(deviceId)}.${encodeURIComponent(sessionId)}`;
}

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
  private store: SecureStore;
  private memory: Map<string, ComposerDocument> = new Map();
  /** clear/空文档在当前进程内是权威状态，磁盘旧值不得在异步 remove 完成前回流。 */
  private cleared: Set<string> = new Set();
  private generations: Map<string, number> = new Map();
  private timers: Map<string, number> = new Map();
  /** 同一草稿键的 set/remove 必须严格有序，避免旧异步写在 clear 后复活内容。 */
  private operations: Map<string, Promise<void>> = new Map();

  constructor(store: SecureStore = new SecureStore()) {
    this.store = store;
  }

  async init(context: common.Context): Promise<void> {
    await this.store.init(context);
  }

  private legacyOperationKey(sessionId: string): string {
    return `legacy\u0000${sessionId}`;
  }

  async read(sessionId: string, deviceId: string = ''): Promise<ComposerDocument | null> {
    const scope = composerDraftScopeKey(sessionId, deviceId);
    if (sessionId.length === 0 || this.cleared.has(scope)) return null;
    const inMemory = this.memory.get(scope);
    if (inMemory !== undefined) return inMemory;
    const generation = this.generations.get(scope) ?? 0;
    const stored = await this.store.get(composerDraftStorageKey(sessionId, deviceId), '');
    if (this.cleared.has(scope)) return null;
    const newer = this.memory.get(scope);
    if (newer !== undefined) return newer;
    if ((this.generations.get(scope) ?? 0) !== generation) return null;
    if (stored.length > 0) {
      const parsed = parseStoredComposerDocument(stored);
      if (parsed !== null) {
        this.memory.set(scope, parsed);
        return parsed;
      }
    }
    if (deviceId.length === 0) return null;
    return this.claimLegacyDraft(sessionId, deviceId, scope);
  }

  save(sessionId: string, document: ComposerDocument, deviceId: string = ''): void {
    const scope = composerDraftScopeKey(sessionId, deviceId);
    if (sessionId.length === 0) return;
    this.cancelTimer(scope);
    const generation = (this.generations.get(scope) ?? 0) + 1;
    this.generations.set(scope, generation);
    if (document.nodes.length === 0) {
      this.memory.delete(scope);
      this.cleared.add(scope);
      void this.enqueueOperation(scope, (): Promise<void> =>
        this.store.remove(composerDraftStorageKey(sessionId, deviceId)))
        .catch(() => {});
      this.removeLegacyDraftLater(sessionId, deviceId);
      return;
    }
    this.cleared.delete(scope);
    this.memory.set(scope, document);
    const timer = setTimeout(() => {
      this.timers.delete(scope);
      void this.persistIfCurrent(
        sessionId, deviceId, scope, generation, document).catch(() => {});
    }, PERSIST_DEBOUNCE_MS);
    this.timers.set(scope, timer);
    this.removeLegacyDraftLater(sessionId, deviceId);
  }

  clear(sessionId: string, deviceId: string = ''): void {
    const scope = composerDraftScopeKey(sessionId, deviceId);
    if (sessionId.length === 0) return;
    this.cancelTimer(scope);
    this.generations.set(scope, (this.generations.get(scope) ?? 0) + 1);
    this.memory.delete(scope);
    this.cleared.add(scope);
    void this.enqueueOperation(scope, (): Promise<void> =>
      this.store.remove(composerDraftStorageKey(sessionId, deviceId)))
      .catch(() => {});
    this.removeLegacyDraftLater(sessionId, deviceId);
  }

  async flush(sessionId: string, deviceId: string = ''): Promise<void> {
    const scope = composerDraftScopeKey(sessionId, deviceId);
    this.cancelTimer(scope);
    await (this.operations.get(scope) ?? Promise.resolve());
    if (deviceId.length > 0) {
      await (this.operations.get(this.legacyOperationKey(sessionId)) ?? Promise.resolve());
    }
    const current = this.memory.get(scope);
    if (current === undefined) return;
    const generation = this.generations.get(scope) ?? 0;
    await this.persistIfCurrent(sessionId, deviceId, scope, generation, current);
  }

  private persistIfCurrent(
    sessionId: string,
    deviceId: string,
    scope: string,
    generation: number,
    document: ComposerDocument,
  ): Promise<void> {
    return this.enqueueOperation(scope, async (): Promise<void> => {
      if ((this.generations.get(scope) ?? 0) !== generation
        || this.memory.get(scope) !== document) return;
      await this.store.set(
        composerDraftStorageKey(sessionId, deviceId), composerDocumentToStorage(document));
    });
  }

  /** 将 v1 的无设备草稿原子地认领给首次打开它的远端设备。 */
  private async claimLegacyDraft(
    sessionId: string,
    deviceId: string,
    scope: string,
  ): Promise<ComposerDocument | null> {
    let claimed: ComposerDocument | null = null;
    await this.enqueueOperation(this.legacyOperationKey(sessionId), async (): Promise<void> => {
      if (this.cleared.has(scope)) return;
      const current = this.memory.get(scope);
      if (current !== undefined) {
        await this.store.remove(composerDraftStorageKey(sessionId, ''));
        claimed = current;
        return;
      }

      const scopedStored = await this.store.get(composerDraftStorageKey(sessionId, deviceId), '');
      if (scopedStored.length > 0) {
        const scoped = parseStoredComposerDocument(scopedStored);
        if (scoped !== null) {
          this.memory.set(scope, scoped);
          claimed = scoped;
          return;
        }
      }

      const legacyStored = await this.store.get(composerDraftStorageKey(sessionId, ''), '');
      if (legacyStored.length === 0) return;
      const legacy = parseStoredComposerDocument(legacyStored);
      if (legacy === null || this.cleared.has(scope) || this.memory.get(scope) !== undefined) return;
      const generation = this.generations.get(scope) ?? 0;
      let persisted = false;
      await this.enqueueOperation(scope, async (): Promise<void> => {
        if ((this.generations.get(scope) ?? 0) !== generation
          || this.cleared.has(scope) || this.memory.get(scope) !== undefined) return;
        await this.store.set(
          composerDraftStorageKey(sessionId, deviceId), composerDocumentToStorage(legacy));
        if ((this.generations.get(scope) ?? 0) !== generation || this.cleared.has(scope)) return;
        this.memory.set(scope, legacy);
        claimed = legacy;
        persisted = true;
      });
      if (persisted) await this.store.remove(composerDraftStorageKey(sessionId, ''));
    });
    return claimed;
  }

  private removeLegacyDraftLater(sessionId: string, deviceId: string): void {
    if (deviceId.length === 0) return;
    void this.enqueueOperation(this.legacyOperationKey(sessionId), (): Promise<void> =>
      this.store.remove(composerDraftStorageKey(sessionId, ''))).catch(() => {});
  }

  private enqueueOperation(
    operationKey: string,
    operation: () => Promise<void>,
  ): Promise<void> {
    const previous = this.operations.get(operationKey) ?? Promise.resolve();
    const next = previous.catch(() => {}).then((): Promise<void> => operation());
    this.operations.set(operationKey, next);
    const cleanup = (): void => {
      if (this.operations.get(operationKey) === next) this.operations.delete(operationKey);
    };
    void next.then(cleanup, cleanup);
    return next;
  }

  private cancelTimer(scope: string): void {
    const timer = this.timers.get(scope);
    if (timer === undefined) return;
    clearTimeout(timer);
    this.timers.delete(scope);
  }
}
