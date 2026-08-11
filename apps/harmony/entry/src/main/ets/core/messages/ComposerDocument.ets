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

/** Composer 原子节点的轻量展示模型；正文仍由 TextArea 编辑。 */
export class ComposerAtomPresentation {
  index: number = -1;
  type: string = '';
  label: string = '';
  detail: string = '';
}

class ComposerSemanticRange {
  start: number = 0;
  end: number = 0;
  node: ComposerNode = new ComposerNode();
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

export function removeComposerNode(document: ComposerDocument, index: number): ComposerDocument {
  if (index < 0 || index >= document.nodes.length) return document;
  const out = new ComposerDocument();
  out.nodes = document.nodes.filter((_node: ComposerNode, nodeIndex: number) => nodeIndex !== index);
  return normalizeComposerDocument(out);
}

export function composerAtomPresentations(document: ComposerDocument): ComposerAtomPresentation[] {
  const out: ComposerAtomPresentation[] = [];
  for (let i = 0; i < document.nodes.length; i++) {
    const node = document.nodes[i];
    if (node.type === 'text' && node.slashCommand.length === 0) continue;
    const item = new ComposerAtomPresentation();
    item.index = i;
    item.type = node.type === 'text' ? 'slash-command' : node.type;
    if (node.type === 'quote') {
      item.label = '引用';
      item.detail = node.sourcePath.length > 0 ? node.sourcePath : compactAtomText(node.text);
    } else if (node.type === 'pasted-text') {
      item.label = node.display.length > 0 ? node.display : '已粘贴文本';
      item.detail = compactAtomText(node.text);
    } else if (node.type === 'mention') {
      item.label = node.label.length > 0 ? node.label : node.raw;
      item.detail = node.mentionKind === 'project' ? '项目' : '提及';
    } else if (node.type === 'session-link') {
      item.label = node.messageClientId.length > 0 ? '消息引用' : '任务引用';
      item.detail = node.label.length > 0 ? node.label : node.href;
    } else {
      item.label = node.slashCommand.length > 0 ? node.slashCommand : node.text;
      item.detail = '命令';
    }
    out.push(item);
  }
  return out;
}

function compactAtomText(value: string): string {
  return value.replace(/\s+/g, ' ').trim().slice(0, 64);
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

/** 从队列 persistedContent 恢复结构化文档，编辑时不再把引用/粘贴/命令压成纯文本。 */
export function composerDocumentFromPersistedContent(value: string): ComposerDocument | null {
  try {
    const raw = JSON.parse(value) as Record<string, Object>;
    const rawText = raw['text'];
    if (typeof rawText !== 'string') return null;
    const text = rawText as string;
    const ranges: ComposerSemanticRange[] = [];
    collectMetadataRanges(raw['pastedTextRanges'], text, 'pasted-text', ranges);
    collectMetadataRanges(raw['slashCommandRanges'], text, 'slash-command', ranges);
    collectAgentReferenceRanges(raw['agentReferences'], text, ranges);
    if (raw['quotesEncoded'] === true) collectQuoteRanges(text, ranges);
    ranges.sort((a: ComposerSemanticRange, b: ComposerSemanticRange) => {
      if (a.start !== b.start) return a.start - b.start;
      return b.end - a.end;
    });

    const document = new ComposerDocument();
    let cursor = 0;
    for (let i = 0; i < ranges.length; i++) {
      const range = ranges[i];
      if (range.start < cursor || range.end <= range.start || range.end > text.length) continue;
      if (range.start > cursor) document.nodes.push(textNode(text.slice(cursor, range.start)));
      document.nodes.push(range.node);
      cursor = range.end;
    }
    if (cursor < text.length) document.nodes.push(textNode(text.slice(cursor)));
    return normalizeComposerDocument(document);
  } catch (e) {
    return null;
  }
}

function collectMetadataRanges(value: Object | undefined, text: string, kind: string,
  target: ComposerSemanticRange[]): void {
  if (!Array.isArray(value)) return;
  const rows = value as Object[];
  for (let i = 0; i < rows.length; i++) {
    const record = asRecord(rows[i]);
    if (record === null) continue;
    const start = rangeNumber(record, 'start');
    const end = rangeNumber(record, 'end');
    if (!validSemanticRange(start, end, text.length)) continue;
    const range = new ComposerSemanticRange();
    range.start = start;
    range.end = end;
    const slice = text.slice(start, end);
    if (kind === 'pasted-text') {
      range.node = pastedTextNode(slice);
      if (typeof record['display'] === 'string') range.node.display = record['display'] as string;
    } else {
      range.node = textNode(slice, slice);
    }
    target.push(range);
  }
}

function collectAgentReferenceRanges(value: Object | undefined, text: string,
  target: ComposerSemanticRange[]): void {
  if (!Array.isArray(value)) return;
  const rows = value as Object[];
  for (let i = 0; i < rows.length; i++) {
    const record = asRecord(rows[i]);
    if (record === null) continue;
    const start = rangeNumber(record, 'start');
    const end = rangeNumber(record, 'end');
    if (!validSemanticRange(start, end, text.length)) continue;
    const kind = typeof record['kind'] === 'string' ? record['kind'] as string : '';
    const node = new ComposerNode();
    if (kind === 'project') {
      node.type = 'mention';
      node.mentionKind = 'project';
      node.raw = text.slice(start, end);
      node.label = stringField(record, 'name');
      node.href = stringField(record, 'href');
      node.workingDir = stringField(record, 'workingDir');
    } else if (kind === 'session' || kind === 'message') {
      node.type = 'session-link';
      node.href = stringField(record, 'href');
      if (node.href.length === 0) node.href = text.slice(start, end);
      node.messageClientId = stringField(record, 'messageClientId');
      node.agentText = stringField(record, 'text');
      node.agentTextTruncated = record['truncated'] === true;
      node.label = stringField(record, 'title');
      node.titled = node.label.length > 0;
    } else {
      continue;
    }
    const range = new ComposerSemanticRange();
    range.start = start;
    range.end = end;
    range.node = node;
    target.push(range);
  }
}

function collectQuoteRanges(text: string, target: ComposerSemanticRange[]): void {
  const marker = '> <!-- cindy-composer-quote -->';
  let searchAt = 0;
  for (;;) {
    const markerAt = text.indexOf(marker, searchAt);
    if (markerAt < 0) return;
    let lineAt = text.indexOf('\n', markerAt + marker.length);
    if (lineAt < 0) lineAt = text.length;
    let cursor = lineAt < text.length ? lineAt + 1 : lineAt;
    const lines: string[] = [];
    let end = lineAt;
    while (cursor < text.length) {
      let lineEnd = text.indexOf('\n', cursor);
      if (lineEnd < 0) lineEnd = text.length;
      const line = text.slice(cursor, lineEnd);
      if (!line.startsWith('>')) break;
      lines.push(line.startsWith('> ') ? line.slice(2) : line.slice(1));
      end = lineEnd;
      cursor = lineEnd < text.length ? lineEnd + 1 : lineEnd;
    }
    let sourcePath = '';
    let startLine = 0;
    let endLine = 0;
    if (lines.length > 0 && lines[lines.length - 1].startsWith('— source: ')) {
      const source = lines.pop()?.slice('— source: '.length) ?? '';
      const lineMarker = source.lastIndexOf('#L');
      sourcePath = lineMarker >= 0 ? source.slice(0, lineMarker) : source;
      if (lineMarker >= 0) {
        const lineRange = source.slice(lineMarker + 2).split('-L');
        startLine = Number.parseInt(lineRange[0], 10);
        endLine = lineRange.length > 1 ? Number.parseInt(lineRange[1], 10) : startLine;
        if (!Number.isFinite(startLine)) startLine = 0;
        if (!Number.isFinite(endLine)) endLine = startLine;
      }
    }
    if (lines.length > 0) {
      let start = markerAt;
      if (start >= 2 && text.slice(start - 2, start) === '\n\n') start -= 2;
      if (end + 2 <= text.length && text.slice(end, end + 2) === '\n\n') end += 2;
      const range = new ComposerSemanticRange();
      range.start = start;
      range.end = end;
      range.node = quoteNode(lines.join('\n'), sourcePath, startLine, endLine);
      target.push(range);
    }
    searchAt = Math.max(markerAt + marker.length, end);
  }
}

function asRecord(value: Object): Record<string, Object> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, Object> : null;
}

function rangeNumber(record: Record<string, Object>, key: string): number {
  const value = record[key];
  return typeof value === 'number' && Number.isFinite(value) ? Math.floor(value) : -1;
}

function validSemanticRange(start: number, end: number, length: number): boolean {
  return start >= 0 && end > start && end <= length;
}

function stringField(record: Record<string, Object>, key: string): string {
  const value = record[key];
  return typeof value === 'string' ? value as string : '';
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
