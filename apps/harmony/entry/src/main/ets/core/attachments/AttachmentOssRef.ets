/**
 * 附件 OSS 引用编解码（ArkTS 移植 attachmentOssRef.ts）。
 *
 * 引用串：`cindy-oss-attach://m/<base64url(JSON)>`，JSON 含
 * { ossKey, mimeType?, originalName?, size?, sha256? }。
 * 发送端沿用 legacy scheme `xdt-oss-attach`（老桌面端只认它）；解析端同时
 * 接受当前 `cindy-oss-attach` 和 legacy scheme，保证混合版本历史消息可读。
 */

import { util } from '@kit.ArkTS';

const SCHEME = 'xdt-oss-attach';
const CURRENT_SCHEME = 'cindy-oss-attach';
const PREFIX = `${SCHEME}://m/`;
const CURRENT_PREFIX = `${CURRENT_SCHEME}://m/`;

const SHA256_HEX_PATTERN = /^[0-9a-f]{64}$/;

/** 附件引用（可选完整性声明必须 size/sha256 成对）。 */
export class AttachmentOssRef {
  ossKey: string = '';
  mimeType: string = '';
  originalName: string = '';
  size: number = 0;
  hasIntegrity: boolean = false;
  sha256: string = '';
}

/** 组装引用串；拒绝缺 ossKey 或半套完整性。 */
export function buildAttachmentOssRef(ref: AttachmentOssRef): string {
  if (ref.ossKey.length === 0) {
    throw new Error('Attachment OSS reference requires a non-empty ossKey');
  }
  const hasSize = ref.size > 0;
  const hasSha256 = ref.sha256.length > 0;
  if (hasSize !== hasSha256 || (hasSize && !SHA256_HEX_PATTERN.test(ref.sha256))) {
    throw new Error('Attachment OSS reference requires valid size and sha256 together');
  }
  const payload: Record<string, Object> = {};
  payload['ossKey'] = ref.ossKey;
  if (ref.mimeType.length > 0) payload['mimeType'] = ref.mimeType;
  if (ref.originalName.length > 0) payload['originalName'] = ref.originalName;
  if (hasSize) {
    payload['size'] = ref.size;
    payload['sha256'] = ref.sha256;
  }
  return `${PREFIX}${toBase64Url(JSON.stringify(payload))}`;
}

/** 判断字符串是否为附件 OSS 引用。 */
export function isAttachmentOssRef(value: string): boolean {
  return attachmentPrefix(value).length > 0;
}

/** 解析引用；半套完整性返回 null。 */
export function parseAttachmentOssRef(value: string): AttachmentOssRef | null {
  const prefix = attachmentPrefix(value);
  if (prefix.length === 0) {
    return null;
  }
  const segment = value.slice(prefix.length).split('/')[0];
  if (segment.length === 0) {
    return null;
  }
  let obj: Object;
  try {
    obj = JSON.parse(fromBase64Url(segment)) as Object;
  } catch (e) {
    return null;
  }
  if (obj === undefined || obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
    return null;
  }
  const record = obj as Record<string, Object>;
  const ossKey = readStr(record, 'ossKey');
  if (ossKey.length === 0) {
    return null;
  }
  const hasSize = record['size'] !== undefined;
  const hasSha256 = readStr(record, 'sha256').length > 0;
  if (hasSize !== hasSha256) {
    return null;
  }
  if (hasSize) {
    const size = record['size'];
    const sha = readStr(record, 'sha256');
    if (typeof size !== 'number' || size <= 0 || !SHA256_HEX_PATTERN.test(sha)) {
      return null;
    }
  }
  const out = new AttachmentOssRef();
  out.ossKey = ossKey;
  out.mimeType = readStr(record, 'mimeType');
  out.originalName = readStr(record, 'originalName');
  const size = record['size'];
  out.size = typeof size === 'number' ? size : 0;
  out.hasIntegrity = hasSize;
  out.sha256 = readStr(record, 'sha256');
  return out;
}

function attachmentPrefix(value: string): string {
  if (value.startsWith(CURRENT_PREFIX)) {
    return CURRENT_PREFIX;
  }
  if (value.startsWith(PREFIX)) {
    return PREFIX;
  }
  return '';
}

function readStr(obj: Record<string, Object>, key: string): string {
  const v = obj[key];
  return typeof v === 'string' ? v : '';
}

function toBase64Url(input: string): string {
  const bytes = utf8Bytes(input);
  const base64 = base64Encode(bytes);
  return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromBase64Url(input: string): string {
  const base64 = input.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, '=');
  return utf8String(base64Decode(padded));
}

function utf8Bytes(input: string): Uint8Array {
  const encoder = util.TextEncoder.create('utf-8');
  return encoder.encodeInto(input);
}

function utf8String(bytes: Uint8Array): string {
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(bytes);
}

function base64Encode(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes);
}

function base64Decode(input: string): Uint8Array {
  const helper = new util.Base64Helper();
  return helper.decodeSync(input);
}
