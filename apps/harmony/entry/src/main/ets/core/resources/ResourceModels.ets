import { recordOrEmpty, readStr, readNum } from '../tasks/TaskModels';

// Port returns unwrapped business data. Caller owns same-account authorization and link opening.
export type ResourceInvoke = (deviceId: string, channel: string, args: Object[], timeoutMs?: number) => Promise<Object | undefined>;
export interface ResourceClient { protocolVersion: number; primitives: string[]; locale: string; }
export interface ResourceActionInput { at: number; }
export interface ResourceRequest { client: ResourceClient; collectionId?: string; limit?: number; cursor?: string;
  query?: string; ref?: ResourceRef; actionId?: string; resourceRef?: ResourceRef; input?: ResourceActionInput; }
export interface ResourceRawLink { rel: string; target: Object; }
export interface ResourceRef { collectionId: string; kind: string; id: string; }
export interface ResourceLink { rel: string; kind: string; sessionId: string; ref: ResourceRef | null; label: string; }
export interface ResourceAction { id: string; label: string; disabled: boolean; destructive: boolean;
  confirmation: string; confirmationBody: string; confirmLabel: string; supported: boolean; }
export interface ResourceBlock { id: string; primitive: string; title: string; markdown: string; }
export interface ResourceItem { ref: ResourceRef; revision: string; title: string; subtitle: string; preview: string;
  lastReplyAt: number; lastReadAt: number; readSupported: boolean; links: ResourceLink[]; actions: ResourceAction[]; blocks: ResourceBlock[]; }
export interface ResourceCollection { id: string; resourceKind: string; title: string; placement: string; actions: ResourceAction[]; }
export function resourceKey(ref: ResourceRef): string { return JSON.stringify([ref.collectionId, ref.kind, ref.id]); }
export function resourceAllowed(id: string): boolean {
  // Excluded surfaces must not accidentally become a plugin runtime through discovery.
  return id.length > 0 && id !== 'routines' && id !== 'plugins' && !id.startsWith('plugin-');
}
export function resourceText(value: Object | undefined, locale: string): string {
  if (typeof value === 'string') return value.slice(0, 20000);
  const row = recordOrEmpty(value);
  const translated = recordOrEmpty(row['translations']);
  return (readStr(translated, locale) || readStr(translated, locale.split('-')[0]) || readStr(row, 'fallback')).slice(0, 20000);
}
export function parseResourceRef(raw: Object | undefined): ResourceRef | null {
  const row = recordOrEmpty(raw);
  const collectionId = readStr(row, 'collectionId'), kind = readStr(row, 'kind'), id = readStr(row, 'id');
  if (!resourceAllowed(collectionId) || collectionId.length > 160 || !kind || kind.length > 160 || !id || id.length > 256) return null;
  return { collectionId, kind, id };
}
export function parseResourceActions(raw: Object | undefined, locale: string): ResourceAction[] {
  if (!Array.isArray(raw)) return [];
  const result: ResourceAction[] = [];
  for (const value of (raw as Object[]).slice(0, 16)) {
    const row = recordOrEmpty(value), confirm = recordOrEmpty(row['confirmation']);
    const id = readStr(row, 'id'), label = resourceText(row['label'], locale);
    if (!id || id.length > 160 || !label) continue;
    const title = resourceText(confirm['title'], locale);
    const malformed = row['confirmation'] !== undefined && (!title
      || (confirm['body'] !== undefined && !resourceText(confirm['body'], locale))
      || (confirm['confirmLabel'] !== undefined && !resourceText(confirm['confirmLabel'], locale)));
    // Generic forms are deliberately unsupported, as in Mobile's ordinary resource view.
    result.push({ id, label, disabled: row['disabled'] !== undefined && row['disabled'] !== false,
      destructive: row['tone'] === 'destructive', confirmation: title,
      confirmationBody: resourceText(confirm['body'], locale), confirmLabel: resourceText(confirm['confirmLabel'], locale),
      supported: row['fields'] === undefined && !malformed });
  }
  return result;
}
export function parseResourceLinks(raw: Object | undefined, locale: string): ResourceLink[] {
  if (!Array.isArray(raw)) return [];
  const result: ResourceLink[] = [];
  for (const value of (raw as Object[]).slice(0, 256)) {
    const row = recordOrEmpty(value), target = recordOrEmpty(row['target']);
    const kind = readStr(target, 'kind'), sessionId = readStr(target, 'sessionId');
    const ref = parseResourceRef(target['ref']);
    if ((kind === 'session' && sessionId.length > 0 && sessionId.length <= 160) || (kind === 'resource' && ref !== null)) {
      result.push({ rel: readStr(row, 'rel'), kind, sessionId, ref, label: resourceText(row['label'], locale) });
    }
  }
  return result;
}
export function parseResourceItem(raw: Object | undefined, collectionId: string, locale: string): ResourceItem | null {
  const row = recordOrEmpty(raw), display = recordOrEmpty(row['display']);
  const ref = parseResourceRef(row['ref']), revision = readStr(row, 'revision'), title = resourceText(display['title'], locale);
  if (!ref || ref.collectionId !== collectionId || !revision || revision.length > 1024 || !title) return null;
  const blocks: ResourceBlock[] = [];
  if (Array.isArray(row['blocks'])) {
    for (const value of (row['blocks'] as Object[]).slice(0, 256)) {
      const block = recordOrEmpty(value), markdown = readStr(block, 'fallbackMarkdown');
      const id = readStr(block, 'id'), primitive = readStr(block, 'primitive');
      if (id && primitive && typeof block['fallbackMarkdown'] === 'string' && markdown.length <= 131072) {
        blocks.push({ id, primitive, title: resourceText(block['title'], locale), markdown });
      }
    }
  }
  return { ref, revision, title, subtitle: resourceText(display['subtitle'], locale), preview: resourceText(display['preview'], locale),
    lastReplyAt: readNum(display, 'lastReplyAt', 0), lastReadAt: readNum(display, 'lastReadAt', 0), readSupported: typeof display['lastReadAt'] === 'number',
    links: parseResourceLinks(row['links'], locale), actions: parseResourceActions(row['actions'], locale), blocks };
}
export function resourceUnread(item: ResourceItem): boolean { return item.lastReplyAt > item.lastReadAt; }
export function resourceError(error: Object): string {
  const code = readStr(recordOrEmpty(error), 'code');
  const message = error instanceof Error ? error.message : code;
  if (/NOT_FOUND|FORBIDDEN|PERMISSION_DENIED|ACCESS_REVOKED|DEVICE_REVOKED/.test(code + message)) return 'unavailable';
  if (/CHANNEL_NOT_ALLOWED/.test(code + message)) return 'unsupported';
  return 'failed';
}
