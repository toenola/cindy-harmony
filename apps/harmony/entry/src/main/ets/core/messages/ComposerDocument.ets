/**
 * Composer 的单一语义源。
 *
 * ArkUI TextArea 只负责投影可编辑文本；quote / mention / session-link /
 * pasted-text 的语义保存在节点中，发送与草稿都从这里序列化，禁止从展示文本反推。
 * JS/ArkTS string.length 正好是 UTF-16 code-unit，range 可直接用于 wire。
 */

export const LONG_PASTE_CHAR_THRESHOLD = 4000;
export const LONG_PASTE_LINE_THRESHOLD = 24;
export const LONG_PASTE_MAX_CHARS = 2000000;

export class ComposerNode {
  type: string = 'text';
  text: string = '';
  slashCommand: string = '';
  sourcePath: string = '';
  startLine: number = 0;
  endLine: number = 0;
  mentionKind: string = '';
  label: string = '';
  raw: string = '';
  href: string = '';
  workingDir: string = '';
  titled: boolean = false;
  messageClientId: string = '';
  agentText: string = '';
  agentTextTruncated: boolean = false;
  display: string = '';
}

export class ComposerDocument {
  version: number = 1;
  nodes: ComposerNode[] = [];
}

export class SerializedComposerDocument {
  text: string = '';
  quotesEncoded: boolean = false;
  agentReferences: Object[] = [];
  pastedTextRanges: Object[] = [];
  slashCommandRanges: Object[] = [];
}

export function emptyComposerDocument(): ComposerDocument {
  return new ComposerDocument();
}

export function textComposerDocument(text: string): ComposerDocument {
  const document = new ComposerDocument();
  if (text.length > 0) document.nodes.push(textNode(text));
  return document;
}

export function textNode(text: string, slashCommand: string = ''): ComposerNode {
  const node = new ComposerNode();
  node.type = 'text';
  node.text = text;
  node.slashCommand = slashCommand;
  return node;
}

export function quoteNode(text: string, sourcePath: string = '', startLine: number = 0,
  endLine: number = 0): ComposerNode {
  const node = new ComposerNode();
  node.type = 'quote';
  node.text = text;
  node.sourcePath = sourcePath;
  node.startLine = startLine;
  node.endLine = endLine;
  return node;
}

export function mentionNode(kind: string, label: string, raw: string): ComposerNode {
  const node = new ComposerNode();
  node.type = 'mention';
  node.mentionKind = kind;
  node.label = label;
  node.raw = raw;
  return node;
}

export function pastedTextNode(text: string): ComposerNode {
  const node = new ComposerNode();
  node.type = 'pasted-text';
  node.text = text.slice(0, LONG_PASTE_MAX_CHARS);
  let lineCount = 1;
  for (let i = 0; i < node.text.length; i++) if (node.text.charCodeAt(i) === 10) lineCount += 1;
  node.display = `已粘贴文本（${lineCount} 行）`;
  return node;
}

export function slashCommandNode(commandName: string): ComposerNode {
  const value = commandName.startsWith('/') ? commandName : `/${commandName}`;
  return textNode(value, value);
}

export function isLongComposerPaste(text: string): boolean {
  if (text.length >= LONG_PASTE_CHAR_THRESHOLD) return true;
  let lines = 1;
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) === 10 && ++lines >= LONG_PASTE_LINE_THRESHOLD) return true;
  }
  return false;
}

function projectedNodeText(node: ComposerNode): string {
  if (node.type === 'quote') return '';
  if (node.type === 'mention') return node.raw;
  if (node.type === 'session-link') {
    if (node.messageClientId.length > 0) return node.href;
    return node.titled && node.label.length > 0 ? `[${sanitizeLinkLabel(node.label)}](${node.href})` : node.href;
  }
  return node.text;
}

export function composerDocumentProjectedText(document: ComposerDocument): string {
  let out = '';
  for (let i = 0; i < document.nodes.length; i++) out += projectedNodeText(document.nodes[i]);
  return out;
}

export function composerDocumentHasContent(document: ComposerDocument): boolean {
  for (let i = 0; i < document.nodes.length; i++) {
    const node = document.nodes[i];
    if (node.type === 'quote' || projectedNodeText(node).trim().length > 0) return true;
  }
  return false;
}

export function normalizeComposerDocument(document: ComposerDocument): ComposerDocument {
  const out = new ComposerDocument();
  for (let i = 0; i < document.nodes.length; i++) {
    const node = document.nodes[i];
    if (!validNode(node)) continue;
    const previous = out.nodes.length > 0 ? out.nodes[out.nodes.length - 1] : null;
    if (node.type === 'text' && previous !== null && previous.type === 'text'
      && previous.slashCommand === node.slashCommand) {
      previous.text += node.text;
    } else {
      out.nodes.push(node);
    }
  }
  return out;
}

function validNode(node: ComposerNode): boolean {
  if (node.type === 'quote') return node.text.length > 0;
  if (node.type === 'mention') return node.raw.length > 0;
  if (node.type === 'session-link') return node.href.length > 0;
  if (node.type === 'pasted-text') return node.text.length > 0;
  return node.type === 'text' && node.text.length > 0;
}

/** TextArea 的普通文本变化只替换变化区；区外原子节点继续保留。 */
export function reconcileComposerProjectedText(document: ComposerDocument, nextText: string): ComposerDocument {
  if (nextText.length === 0) return emptyComposerDocument();
  const previousText = composerDocumentProjectedText(document);
  if (previousText === nextText) return document;
  let prefix = 0;
  while (prefix < previousText.length && prefix < nextText.length
    && previousText.charCodeAt(prefix) === nextText.charCodeAt(prefix)) prefix += 1;
  let suffix = 0;
  while (suffix < previousText.length - prefix && suffix < nextText.length - prefix
    && previousText.charCodeAt(previousText.length - 1 - suffix)
      === nextText.charCodeAt(nextText.length - 1 - suffix)) suffix += 1;
  const replacement = nextText.slice(prefix, nextText.length - suffix);
  return replaceComposerTextRange(document, prefix, previousText.length - suffix,
    replacement.length > 0 ? [textNode(replacement)] : []);
}

export function replaceComposerTextRange(document: ComposerDocument, from: number, to: number,
  replacement: ComposerNode[]): ComposerDocument {
  const start = Math.max(0, Math.min(from, to));
  const end = Math.max(start, Math.max(from, to));
  const before: ComposerNode[] = [];
  const after: ComposerNode[] = [];
  let offset = 0;
  for (let i = 0; i < document.nodes.length; i++) {
    const node = document.nodes[i];
    const text = projectedNodeText(node);
    const nodeStart = offset;
    const nodeEnd = nodeStart + text.length;
    offset = nodeEnd;
    if (nodeEnd <= start) {
      before.push(node);
      continue;
    }
    if (nodeStart >= end) {
      after.push(node);
      continue;
    }
    if (node.type === 'text') {
      const localStart = Math.max(0, start - nodeStart);
      const localEnd = Math.min(text.length, end - nodeStart);
      if (localStart > 0) before.push(textNode(text.slice(0, localStart)));
      if (localEnd < text.length) after.unshift(textNode(text.slice(localEnd)));
    }
  }
  const out = new ComposerDocument();
  out.nodes = before.concat(replacement).concat(after);
  return normalizeComposerDocument(out);
}

export function appendComposerNode(document: ComposerDocument, node: ComposerNode): ComposerDocument {
  const out = new ComposerDocument();
  out.nodes = document.nodes.concat([node]);
  return normalizeComposerDocument(out);
}

function stripOuterNewlines(text: string): string {
  let start = 0;
  while (start < text.length && text.charCodeAt(start) === 10) start += 1;
  let end = text.length;
  while (end > start && text.charCodeAt(end - 1) === 10) end -= 1;
  return text.slice(start, end);
}

function quoteWireText(node: ComposerNode): string {
  const lines = stripOuterNewlines(node.text).split('\n');
  if (node.sourcePath.length > 0) {
    let source = node.sourcePath;
    if (node.startLine > 0) {
      const end = node.endLine >= node.startLine ? node.endLine : node.startLine;
      source += end === node.startLine ? `#L${node.startLine}` : `#L${node.startLine}-L${end}`;
    }
    lines.push(`— source: ${source}`);
  }
  const out: string[] = ['> <!-- cindy-composer-quote -->'];
  for (let i = 0; i < lines.length; i++) out.push(lines[i].length > 0 ? `> ${lines[i]}` : '>');
  return out.join('\n');
}

function sanitizeLinkLabel(label: string): string {
  return label.replace(/\[/g, ' ').replace(/\]/g, ' ').replace(/@/g, '＠').replace(/\s+/g, ' ').trim();
}

function wireText(node: ComposerNode): string {
  return node.type === 'quote' ? quoteWireText(node) : projectedNodeText(node);
}

function pushRange(target: Object[], start: number, end: number, display: string = ''): void {
  const range: Record<string, Object> = {};
  range['start'] = start;
  range['end'] = end;
  if (display.length > 0) range['display'] = display;
  target.push(range);
}

function sessionIdFromHref(href: string): string {
  const prefix = 'cindy://session/';
  if (!href.startsWith(prefix)) return '';
  const rest = href.slice(prefix.length);
  const q = rest.indexOf('?');
  const encoded = q >= 0 ? rest.slice(0, q) : rest;
  try { return decodeURIComponent(encoded); } catch (e) { return encoded; }
}

export function serializeComposerDocument(document: ComposerDocument): SerializedComposerDocument {
  const result = new SerializedComposerDocument();
  let serialized = '';
  let previous: ComposerNode | null = null;
  const normalized = normalizeComposerDocument(document);
  for (let i = 0; i < normalized.nodes.length; i++) {
    const node = normalized.nodes[i];
    const value = wireText(node);
    if (value.length === 0) continue;
    if (previous !== null && (previous.type === 'quote' || node.type === 'quote')) serialized += '\n\n';
    const start = serialized.length;
    serialized += value;
    const end = serialized.length;
    if (node.type === 'quote') result.quotesEncoded = true;
    if (node.type === 'pasted-text') pushRange(result.pastedTextRanges, start, end, node.display);
    if (node.type === 'text' && node.slashCommand === node.text) pushRange(result.slashCommandRanges, start, end);
    if (node.type === 'session-link') {
      const ref: Record<string, Object> = {};
      ref['kind'] = node.messageClientId.length > 0 ? 'message' : 'session';
      ref['start'] = start;
      ref['end'] = end;
      ref['href'] = node.href;
      ref['sessionId'] = sessionIdFromHref(node.href);
      if (node.messageClientId.length > 0) ref['messageClientId'] = node.messageClientId;
      if (node.agentText.length > 0) ref['text'] = node.agentText.slice(0, 12000);
      if (node.agentTextTruncated || node.agentText.length > 12000) ref['truncated'] = true;
      if (node.titled && node.label.length > 0) ref['title'] = node.label;
      result.agentReferences.push(ref);
    } else if (node.type === 'mention' && node.mentionKind === 'project'
      && node.href.length > 0 && node.workingDir.length > 0) {
      const ref: Record<string, Object> = {};
      ref['kind'] = 'project'; ref['start'] = start; ref['end'] = end;
      ref['href'] = node.href; ref['name'] = node.label; ref['workingDir'] = node.workingDir;
      result.agentReferences.push(ref);
    }
    previous = node;
  }
  let leading = 0;
  while (leading < serialized.length && /\s/.test(serialized[leading])) leading += 1;
  result.text = serialized.trim();
  result.agentReferences = trimRanges(result.agentReferences, leading, result.text.length);
  result.pastedTextRanges = trimRanges(result.pastedTextRanges, leading, result.text.length);
  result.slashCommandRanges = trimRanges(result.slashCommandRanges, leading, result.text.length);
  return result;
}

function trimRanges(source: Object[], leading: number, textLength: number): Object[] {
  const out: Object[] = [];
  for (let i = 0; i < source.length; i++) {
    const raw = source[i] as Record<string, Object>;
    const rawStart = raw['start']; const rawEnd = raw['end'];
    if (typeof rawStart !== 'number' || typeof rawEnd !== 'number') continue;
    const start = Math.max(0, rawStart - leading);
    const end = Math.min(textLength, rawEnd - leading);
    if (start >= end) continue;
    const next: Record<string, Object> = {};
    const keys = Object.keys(raw);
    for (let j = 0; j < keys.length; j++) next[keys[j]] = raw[keys[j]];
    next['start'] = start; next['end'] = end;
    out.push(next);
  }
  return out;
}

export function composerDocumentToStorage(document: ComposerDocument): string {
  const nodes: Object[] = [];
  for (let i = 0; i < document.nodes.length; i++) nodes.push(document.nodes[i]);
  const raw: Record<string, Object> = {};
  raw['version'] = 1;
  raw['nodes'] = nodes;
  return JSON.stringify(raw);
}

export function parseStoredComposerDocument(value: string): ComposerDocument | null {
  try {
    const raw = JSON.parse(value) as Record<string, Object>;
    if (raw['version'] !== 1 || !Array.isArray(raw['nodes'])) return null;
    const source = raw['nodes'] as Object[];
    const document = new ComposerDocument();
    for (let i = 0; i < source.length; i++) {
      const item = source[i];
      if (item === null || typeof item !== 'object' || Array.isArray(item)) continue;
      const row = item as Record<string, Object>;
      const node = new ComposerNode();
      if (typeof row['type'] === 'string') node.type = row['type'] as string;
      copyString(row, 'text', (v: string) => node.text = v);
      copyString(row, 'slashCommand', (v: string) => node.slashCommand = v);
      copyString(row, 'sourcePath', (v: string) => node.sourcePath = v);
      copyString(row, 'mentionKind', (v: string) => node.mentionKind = v);
      copyString(row, 'label', (v: string) => node.label = v);
      copyString(row, 'raw', (v: string) => node.raw = v);
      copyString(row, 'href', (v: string) => node.href = v);
      copyString(row, 'workingDir', (v: string) => node.workingDir = v);
      copyString(row, 'messageClientId', (v: string) => node.messageClientId = v);
      copyString(row, 'agentText', (v: string) => node.agentText = v);
      copyString(row, 'display', (v: string) => node.display = v);
      if (typeof row['startLine'] === 'number') node.startLine = row['startLine'] as number;
      if (typeof row['endLine'] === 'number') node.endLine = row['endLine'] as number;
      node.titled = row['titled'] === true;
      node.agentTextTruncated = row['agentTextTruncated'] === true;
      document.nodes.push(node);
    }
    return normalizeComposerDocument(document);
  } catch (e) {
    return null;
  }
}

function copyString(row: Record<string, Object>, key: string, write: (value: string) => void): void {
  const value = row[key];
  if (typeof value === 'string') write(value);
}
