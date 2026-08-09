/**
 * 消息附件与工具产物的防御式归一化。
 *
 * 只处理展示模型，不发起网络请求；字段和判定对齐 maker-shared payloadSummary。
 * 所有入口都限制条目数和字符串长度，避免损坏的远端 payload 撑爆消息列表。
 */

import { RemoteSerializedAttachment } from '../attachments/AttachmentModels';
import { readStr } from '../tasks/TaskModels';

const MAX_PAYLOAD_ITEMS = 64;
const MAX_SHORT_TEXT = 240;
const MAX_BODY_TEXT = 200_000;

export class RenderMediaPayload {
  kind: string = ''; // 'image' | 'video' | 'audio'
  url: string = '';
  title: string = '';
  mimeType: string = '';
  previewable: boolean = false;
}

export class RenderDiffSegment {
  key: string = '';
  label: string = '';
  oldString: string = '';
  newString: string = '';
}

export class RenderDiffPayload {
  filePath: string = '';
  insertions: number = 0;
  deletions: number = 0;
  segments: RenderDiffSegment[] = [];
}

function clipped(value: string, max: number): string {
  if (value.length <= max) return value;
  return `${value.slice(0, Math.max(0, max - 1))}…`;
}

function readRecord(value: Object | undefined): Record<string, Object> | null {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, Object>
    : null;
}

function readPositiveNumber(record: Record<string, Object>, key: string): number {
  const value = record[key];
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
}

function normalizedMime(value: string): string {
  return value.trim().toLowerCase().split(';')[0];
}

function attachmentCategory(mimeType: string, ext: string): string {
  if (mimeType.startsWith('image/')) return 'image';
  if (mimeType === 'application/pdf' || ext === 'pdf') return 'pdf';
  if (mimeType.startsWith('text/') || ['txt', 'md', 'json', 'csv', 'log', 'diff', 'patch'].includes(ext)) {
    return 'text';
  }
  return 'office';
}

function attachmentFromRecord(raw: Record<string, Object>): RemoteSerializedAttachment | null {
  const path = readStr(raw, 'path').length > 0 ? readStr(raw, 'path') : readStr(raw, 'url');
  const name = readStr(raw, 'name').length > 0
    ? readStr(raw, 'name')
    : (readStr(raw, 'originalName').length > 0 ? readStr(raw, 'originalName') : path.split(/[\\/]/).pop() ?? '');
  if (path.length === 0 && name.length === 0) return null;
  const attachment = new RemoteSerializedAttachment();
  attachment.id = clipped(readStr(raw, 'id'), MAX_SHORT_TEXT);
  attachment.name = clipped(name, MAX_SHORT_TEXT);
  attachment.path = clipped(path, MAX_BODY_TEXT);
  attachment.url = clipped(readStr(raw, 'url'), MAX_BODY_TEXT);
  attachment.originalName = clipped(readStr(raw, 'originalName'), MAX_SHORT_TEXT);
  attachment.mimeType = clipped(normalizedMime(readStr(raw, 'mimeType')), MAX_SHORT_TEXT);
  attachment.size = readPositiveNumber(raw, 'size');
  attachment.sha256 = clipped(readStr(raw, 'sha256'), MAX_SHORT_TEXT);
  let ext = readStr(raw, 'ext').trim().toLowerCase().replace(/^\./, '');
  if (ext.length === 0 && attachment.name.includes('.')) {
    ext = attachment.name.split('.').pop()?.toLowerCase() ?? '';
  }
  attachment.ext = clipped(ext, 32);
  attachment.category = clipped(readStr(raw, 'category'), 32);
  if (attachment.category.length === 0) {
    attachment.category = attachmentCategory(attachment.mimeType, attachment.ext);
  }
  return attachment;
}

/** 兼容 persisted files[]、chatMessage.files[] 与归一化 attachments[]。 */
export function parseMessageFiles(content: Object | undefined): RemoteSerializedAttachment[] {
  const record = readRecord(content);
  if (record === null) return [];
  const out: RemoteSerializedAttachment[] = [];
  const seen = new Set<string>();
  const append = (value: Object | undefined): void => {
    if (out.length >= MAX_PAYLOAD_ITEMS) return;
    const raw = readRecord(value);
    if (raw === null) return;
    const attachment = attachmentFromRecord(raw);
    if (attachment === null || attachment.category === 'image') return;
    const key = `${attachment.path}\u0000${attachment.name}`;
    if (seen.has(key)) return;
    seen.add(key);
    out.push(attachment);
  };
  const files = record['files'];
  if (Array.isArray(files)) {
    const list = files as Object[];
    for (let i = 0; i < list.length; i++) append(list[i]);
  }
  const attachments = record['attachments'];
  if (Array.isArray(attachments)) {
    const list = attachments as Object[];
    for (let i = 0; i < list.length; i++) append(list[i]);
  }
  return out;
}

export function isDesktopLocalMediaUrl(url: string): boolean {
  return /^(?:xdt-image|xdt-video|xdt-audio|cindy-media|xdt-file):\/\//i.test(url);
}

export function isDirectPreviewableMediaUrl(url: string): boolean {
  return /^(?:https?:|data:)/i.test(url);
}

function mediaUrlAllowed(kind: string, url: string): boolean {
  if (url.startsWith('cindy-media://')) return true;
  if (kind === 'image') return url.startsWith('xdt-image://');
  if (kind === 'video') return url.startsWith('xdt-video://');
  return url.startsWith('xdt-audio://');
}

/** tool_result JSON → 受托管媒体，按 URL 稳定去重。 */
export function extractToolResultMedia(content: string): RenderMediaPayload[] {
  if (content.length === 0
    || (!content.includes('xdt_image_url')
      && !content.includes('xdt_video_url')
      && !content.includes('xdt_audio_url')
      && !content.includes('xdt_media_produced'))) return [];
  let parsed: Object;
  try {
    parsed = JSON.parse(content) as Object;
  } catch (e) {
    return [];
  }
  const record = readRecord(parsed);
  if (record === null || record['_xdt_render_image'] === false) return [];
  const out: RenderMediaPayload[] = [];
  const seen = new Set<string>();
  const push = (kind: string, url: string, title: string = '', mimeType: string = ''): void => {
    if (out.length >= MAX_PAYLOAD_ITEMS || !mediaUrlAllowed(kind, url) || seen.has(url)) return;
    seen.add(url);
    const item = new RenderMediaPayload();
    item.kind = kind;
    item.url = clipped(url, MAX_BODY_TEXT);
    item.title = clipped(title, MAX_SHORT_TEXT);
    item.mimeType = clipped(normalizedMime(mimeType), MAX_SHORT_TEXT);
    item.previewable = isDirectPreviewableMediaUrl(url);
    out.push(item);
  };
  const pushStringList = (kind: string, value: Object | undefined): void => {
    if (!Array.isArray(value)) return;
    const list = value as Object[];
    for (let i = 0; i < list.length; i++) {
      if (typeof list[i] === 'string') push(kind, list[i] as string);
    }
  };
  const singleImage = record['xdt_image_url'];
  if (typeof singleImage === 'string') push('image', singleImage);
  pushStringList('image', record['xdt_image_urls']);
  const singleVideo = record['xdt_video_url'];
  if (typeof singleVideo === 'string') push('video', singleVideo);
  pushStringList('video', record['xdt_video_urls']);
  const tracks = Array.isArray(record['xdt_audio_tracks'])
    ? record['xdt_audio_tracks']
    : record['_xdt_audio_tracks'];
  if (Array.isArray(tracks)) {
    const list = tracks as Object[];
    for (let i = 0; i < list.length; i++) {
      const track = readRecord(list[i]);
      if (track === null) continue;
      const url = readStr(track, 'xdt_audio_url').length > 0
        ? readStr(track, 'xdt_audio_url')
        : readStr(track, 'audioUrl');
      push('audio', url, readStr(track, 'title'), readStr(track, 'mimeType'));
    }
  }
  pushStringList('audio', record['xdt_audio_urls']);
  const produced = record['xdt_media_produced'];
  if (Array.isArray(produced)) {
    const list = produced as Object[];
    for (let i = 0; i < list.length; i++) {
      const raw = readRecord(list[i]);
      if (raw === null) continue;
      const url = readStr(raw, 'url').length > 0 ? readStr(raw, 'url') : readStr(raw, 'xdt_image_url');
      const mimeType = normalizedMime(readStr(raw, 'mimeType'));
      const declared = readStr(raw, 'kind').toLowerCase();
      const kind = declared === 'video' || mimeType.startsWith('video/')
        ? 'video'
        : declared === 'audio' || mimeType.startsWith('audio/') ? 'audio' : 'image';
      push(kind, url, readStr(raw, 'title'), mimeType);
    }
  }
  return out;
}

function countLines(value: string): number {
  if (value.length === 0) return 0;
  return value.split('\n').length;
}

function addDiffSegment(out: RenderDiffPayload, oldString: string, newString: string, label: string): void {
  if (out.segments.length >= MAX_PAYLOAD_ITEMS) return;
  const segment = new RenderDiffSegment();
  segment.key = `edit:${out.segments.length}`;
  segment.label = clipped(label, MAX_SHORT_TEXT);
  segment.oldString = clipped(oldString, MAX_BODY_TEXT);
  segment.newString = clipped(newString, MAX_BODY_TEXT);
  out.deletions += countLines(segment.oldString);
  out.insertions += countLines(segment.newString);
  out.segments.push(segment);
}

/** Edit / MultiEdit / Write / pi edit 输入 → 原生 Diff 卡模型。 */
export function buildToolDiff(toolName: string, inputRaw: string): RenderDiffPayload | null {
  let parsed: Object;
  try {
    parsed = JSON.parse(inputRaw) as Object;
  } catch (e) {
    return null;
  }
  const input = readRecord(parsed);
  if (input === null) return null;
  const filePath = readStr(input, 'file_path').length > 0 ? readStr(input, 'file_path') : readStr(input, 'path');
  if (filePath.length === 0) return null;
  const out = new RenderDiffPayload();
  out.filePath = clipped(filePath, MAX_BODY_TEXT);
  if (toolName === 'Edit') {
    addDiffSegment(out, readStr(input, 'old_string'), readStr(input, 'new_string'), '');
  } else if (toolName === 'Write' || toolName === 'write') {
    addDiffSegment(out, '', readStr(input, 'content'), '');
  } else if (toolName === 'MultiEdit') {
    const edits = input['edits'];
    if (Array.isArray(edits)) {
      const list = edits as Object[];
      for (let i = 0; i < list.length; i++) {
        const edit = readRecord(list[i]);
        if (edit !== null) addDiffSegment(out, readStr(edit, 'old_string'), readStr(edit, 'new_string'),
          list.length > 1 ? `Edit ${i + 1}/${list.length}` : '');
      }
    }
  } else if (toolName === 'edit') {
    const edits = input['edits'];
    if (Array.isArray(edits)) {
      const list = edits as Object[];
      for (let i = 0; i < list.length; i++) {
        const edit = readRecord(list[i]);
        if (edit !== null) addDiffSegment(out,
          readStr(edit, 'oldText').length > 0 ? readStr(edit, 'oldText') : readStr(edit, 'old_string'),
          readStr(edit, 'newText').length > 0 ? readStr(edit, 'newText') : readStr(edit, 'new_string'),
          list.length > 1 ? `Edit ${i + 1}/${list.length}` : '');
      }
    } else {
      addDiffSegment(out,
        readStr(input, 'oldText').length > 0 ? readStr(input, 'oldText') : readStr(input, 'old_string'),
        readStr(input, 'newText').length > 0 ? readStr(input, 'newText') : readStr(input, 'new_string'), '');
    }
  }
  return out.segments.length > 0 ? out : null;
}

export function attachmentMediaKind(attachment: RemoteSerializedAttachment): string {
  const mime = normalizedMime(attachment.mimeType);
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return 'audio';
  return '';
}

