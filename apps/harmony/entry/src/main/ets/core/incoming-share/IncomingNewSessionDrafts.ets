import { ComposerDraftStore } from '../messages/ComposerDraftStore';
import { ComposerDocument, composerDocumentToStorage } from '../messages/ComposerDocument';
export class IncomingNewSessionDraft {
  deviceId: string = '';
  document: ComposerDocument | null = null;
}
/** Completed routing/import history is not a draft scope. Inspect the exact scoped key
 * without legacy claiming, then migrate ordinary content only into an unchanged empty global. */
export async function restoreIncomingNewSessionDraft(store: ComposerDraftStore, key: string, device: string,
  hasPending: boolean, isCurrent: () => boolean): Promise<IncomingNewSessionDraft> {
  const result = new IncomingNewSessionDraft();
  const scoped = device ? await store.readScopedOnly(key, device) : null;
  if (!isCurrent()) return result;
  if (device && (hasPending || (scoped !== null && scoped.incomingShareBatchIds.length > 0))) {
    result.deviceId = device;
    // Only actual incoming recovery retains the existing legacy-claim behavior.
    result.document = scoped ?? await store.read(key, device); return result;
  }
  let global = await store.read(key);
  if (!isCurrent()) return result;
  if (scoped !== null) {
    const source = composerDocumentToStorage(scoped);
    const expected = global === null ? null : composerDocumentToStorage(global);
    if (global === null || (global.nodes.length === 0 && global.incomingShareBatchIds.length === 0)) {
      if (await store.compareAndFlushGlobal(key, expected, scoped, isCurrent)) {
        if (isCurrent()) await store.clearScopedOnly(key, device, source);
      }
    } else if (expected === source) {
      // Resume a crash after the global write but before scoped cleanup; no new write.
      if (isCurrent()) await store.clearScopedOnly(key, device, source);
    }
    // An existing/new global draft wins. On CAS conflict retain the source for a later recovery.
    global = await store.read(key);
  }
  result.document = global; return result;
}
