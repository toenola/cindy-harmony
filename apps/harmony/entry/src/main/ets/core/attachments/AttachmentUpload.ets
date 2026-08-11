/**
 * 附件上传（ArkTS 移植 mobileAttachmentUpload.ts 语义）。
 *
 * 链路：SHA-256 → presign（POST /api/device-link/media/presign-put）→
 * PUT OSS（presign URL 自带签名，无需 token）→ 生成 OSS 引用串 → RemoteImageRef。
 * 上传失败时 best-effort 删除中转对象（避免 OSS 孤儿）。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AppConfig } from '../../AppConfig';
import { HarmonyHttp } from '../../network/HarmonyHttp';
import {
  AttachmentPresignResult, ImageAttachmentCandidate, RemoteImageRef,
  RemoteSerializedAttachment, MAX_ATTACHMENT_BYTES,
} from './AttachmentModels';
import { AttachmentOssRef, buildAttachmentOssRef } from './AttachmentOssRef';
import { preprocessImage, readFileBytes } from './ImagePreprocess';

export class AttachmentUploadError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AttachmentUploadError';
  }
}

export function isRetryablePresignStatus(statusCode: number): boolean {
  return statusCode === 408 || statusCode === 429
    || (statusCode >= 500 && statusCode <= 599);
}

export function isUploadRevisionCurrent(
  currentRevision: number,
  capturedRevision: number,
  removed: boolean,
  present: boolean,
): boolean {
  return !removed && present && currentRevision === capturedRevision;
}

/** SHA-256（小写 hex）。 */
export async function sha256Hex(bytes: ArrayBuffer): Promise<string> {
  try {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new Uint8Array(bytes) });
    const out = await md.digest();
    let hex = '';
    for (let i = 0; i < out.data.length; i++) {
      hex += out.data[i].toString(16).padStart(2, '0');
    }
    return hex;
  } catch (e) {
    if (e instanceof Error) throw e;
    throw new AttachmentUploadError('sha256 failed');
  }
}

/** presign：向 relay 申请 OSS 预签名上传。 */
export async function presignUpload(
  size: number,
  contentType: string,
  ext: string,
  token: string,
): Promise<AttachmentPresignResult> {
  const http = new HarmonyHttp();
  const headers: Record<string, string> = {};
  headers['Authorization'] = `Bearer ${token}`;
  const body = JSON.stringify({
    size: size,
    contentType: contentType,
    ext: ext,
  });
  for (let attempt = 0; attempt < 2; attempt++) {
    let receivedResponse = false;
    try {
      const res = await http.requestJson(
        `${AppConfig.deviceLinkApiBaseUrl}/api/device-link/media/presign-put`,
        'POST',
        headers,
        body,
      );
      receivedResponse = true;
      if (res.statusCode < 200 || res.statusCode >= 300) {
        if (attempt === 0 && isRetryablePresignStatus(res.statusCode)) continue;
        throw new AttachmentUploadError(`presign failed: ${res.statusCode}`);
      }
      let obj: Record<string, Object>;
      try {
        obj = JSON.parse(res.body) as Record<string, Object>;
      } catch (e) {
        throw new AttachmentUploadError('presign: invalid response');
      }
      const putUrl = obj['putUrl'];
      const key = obj['key'];
      if (typeof putUrl !== 'string' || putUrl.length === 0 ||
        typeof key !== 'string' || key.length === 0) {
        throw new AttachmentUploadError('presign: missing putUrl/key');
      }
      const out = new AttachmentPresignResult();
      out.putUrl = putUrl;
      out.key = key;
      const expiresAt = obj['expiresAt'];
      out.expiresAt = typeof expiresAt === 'string' ? expiresAt : '';
      return out;
    } catch (e) {
      // 只有 transport rejection 自动重试；已收到的无效 2xx 不可重放。
      if (!receivedResponse && attempt === 0) continue;
      if (e instanceof Error) throw e;
      throw new AttachmentUploadError('presign failed');
    }
  }
  throw new AttachmentUploadError('presign failed');
}

/** PUT 字节到 presign URL。 */
export async function putUpload(
  putUrl: string,
  bytes: ArrayBuffer,
  mimeType: string,
): Promise<void> {
  const http = new HarmonyHttp();
  const headers: Record<string, string> = {};
  headers['Content-Type'] = mimeType.length > 0 ? mimeType : 'application/octet-stream';
  headers['x-oss-object-acl'] = 'private';
  for (let attempt = 0; attempt < 2; attempt++) {
    let receivedStatus = false;
    try {
      const status = await http.uploadBytes(putUrl, 'PUT', headers, bytes);
      receivedStatus = true;
      if (status < 200 || status >= 300) {
        throw new AttachmentUploadError(`upload failed: ${status}`);
      }
      return;
    } catch (e) {
      // OSS 已返回状态码时绝不自动重放；仅 transport exception 重试一次。
      if (!receivedStatus && attempt === 0) continue;
      if (e instanceof Error) throw e;
      throw new AttachmentUploadError('upload failed');
    }
  }
  throw new AttachmentUploadError('upload failed');
}

/** 获取 OSS 下载 URL（历史图片加载用；cindy-oss-attach 引用 → presign-get → OSS GET URL）。 */
export async function presignGet(key: string, token: string): Promise<string> {
  const http = new HarmonyHttp();
  const headers: Record<string, string> = {};
  headers['Authorization'] = `Bearer ${token}`;
  const body = JSON.stringify({ key: key });
  const res = await http.requestJson(
    `${AppConfig.deviceLinkApiBaseUrl}/api/device-link/media/presign-get`,
    'POST',
    headers,
    body,
  );
  if (res.statusCode >= 300) {
    throw new AttachmentUploadError(`presign-get failed: ${res.statusCode}`);
  }
  let obj: Record<string, Object>;
  try {
    obj = JSON.parse(res.body) as Record<string, Object>;
  } catch (e) {
    throw new AttachmentUploadError('presign-get: invalid response');
  }
  const getUrl = obj['getUrl'];
  if (typeof getUrl !== 'string' || getUrl.length === 0) {
    throw new AttachmentUploadError('presign-get: missing getUrl');
  }
  return getUrl;
}

/** 删除中转对象（上传失败/移除附件时回收，best-effort）。 */
export async function deleteUpload(
  ossKey: string,
  token: string,
): Promise<void> {
  const http = new HarmonyHttp();
  const headers: Record<string, string> = {};
  headers['Authorization'] = `Bearer ${token}`;
  const body = JSON.stringify({ key: ossKey });
  const res = await http.requestJson(
    `${AppConfig.deviceLinkApiBaseUrl}/api/device-link/media`,
    'DELETE',
    headers,
    body,
  );
  if (res.statusCode >= 300) {
    throw new AttachmentUploadError(`delete failed: ${res.statusCode}`);
  }
}

/** 从文件名提取扩展名（不带点，小写；无则 'bin'）。 */
export function uploadExtForName(name: string): string {
  const dotIdx = name.lastIndexOf('.');
  if (dotIdx >= 0 && dotIdx < name.length - 1) {
    const ext = name.slice(dotIdx + 1).toLowerCase();
    if (ext.length > 0 && ext.length <= 10) return ext;
  }
  return 'bin';
}

/**
 * 完整上传一张图：压缩 → sha256 → presign → PUT → 生成 RemoteImageRef。
 * 任一步失败抛 AttachmentUploadError（调用方展示失败态并允许重试）。
 */
export async function uploadImage(
  candidate: ImageAttachmentCandidate,
  token: string,
): Promise<RemoteImageRef> {
  if (candidate.size > MAX_ATTACHMENT_BYTES) {
    throw new AttachmentUploadError('图片超过大小限制');
  }
  const processed = await preprocessImage(
    candidate.uri,
    candidate.name,
    candidate.mimeType,
    candidate.size,
    candidate.width,
    candidate.height,
  );
  const sha = await sha256Hex(processed.bytes);
  const presigned = await presignUpload(
    processed.size,
    processed.mimeType,
    uploadExtForName(processed.name),
    token,
  );
  try {
    await putUpload(presigned.putUrl, processed.bytes, processed.mimeType);
  } catch (e) {
    // 上传失败：回收中转对象（best-effort）。
    try {
      await deleteUpload(presigned.key, token);
    } catch (e2) {
      // 忽略回收失败
    }
    if (e instanceof Error) {
      throw e;
    }
    throw new AttachmentUploadError('upload failed');
  }
  const ref = new AttachmentOssRef();
  ref.ossKey = presigned.key;
  ref.mimeType = processed.mimeType;
  ref.originalName = processed.name;
  ref.size = processed.size;
  ref.sha256 = sha;
  const refStr = buildAttachmentOssRef(ref);

  const imageRef = new RemoteImageRef();
  imageRef.url = refStr;
  imageRef.originalName = processed.name;
  imageRef.mimeType = processed.mimeType;
  imageRef.size = processed.size;
  imageRef.sha256 = sha;
  return imageRef;
}

const OFFICE_EXTENSIONS: string[] = ['doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx'];
const TEXT_EXTENSIONS: string[] = [
  'txt', 'text', 'md', 'markdown', 'mdx', 'rst', 'log', 'csv', 'tsv', 'json', 'json5',
  'jsonc', 'jsonl', 'yaml', 'yml', 'xml', 'toml', 'ini', 'conf', 'cfg', 'properties',
  'js', 'ts', 'tsx', 'jsx', 'mjs', 'cjs', 'py', 'go', 'rs', 'java', 'c', 'cpp', 'cc',
  'h', 'hpp', 'cs', 'rb', 'php', 'swift', 'kt', 'kts', 'sh', 'bash', 'zsh', 'fish',
  'html', 'htm', 'css', 'scss', 'less', 'vue', 'svelte', 'sql', 'graphql', 'proto',
  'diff', 'patch', 'tex', 'bib', 'srt', 'vtt', 'env', 'lock',
];

export function attachmentCategoryForName(name: string): string {
  const ext = uploadExtForName(name);
  if (ext === 'pdf') return 'pdf';
  if (OFFICE_EXTENSIONS.indexOf(ext) >= 0) return 'office';
  if (TEXT_EXTENSIONS.indexOf(ext) >= 0) return 'text';
  const lower = name.toLowerCase();
  if (lower === 'dockerfile' || lower === 'makefile' || lower === 'gemfile'
    || lower === 'rakefile' || lower === 'jenkinsfile' || lower.startsWith('.')) return 'text';
  return '';
}

export function attachmentMimeType(name: string, category: string): string {
  const ext = uploadExtForName(name);
  if (category === 'pdf') return 'application/pdf';
  if (category === 'text') return 'text/plain';
  if (ext === 'docx') return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  if (ext === 'xlsx') return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  if (ext === 'pptx') return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
  if (ext === 'doc') return 'application/msword';
  if (ext === 'xls') return 'application/vnd.ms-excel';
  if (ext === 'ppt') return 'application/vnd.ms-powerpoint';
  return 'application/octet-stream';
}

/** 普通文档上传：不做图片重编码，保留原文件 SHA 与体积。 */
export async function uploadDocument(
  uri: string,
  name: string,
  token: string,
): Promise<RemoteSerializedAttachment> {
  const category = attachmentCategoryForName(name);
  if (category.length === 0) throw new AttachmentUploadError('不支持这种文件类型');
  const bytes = await readFileBytes(uri);
  if (bytes.byteLength <= 0) throw new AttachmentUploadError('不能添加空文件');
  if (bytes.byteLength > MAX_ATTACHMENT_BYTES) throw new AttachmentUploadError('文件超过 30MB');
  const mimeType = attachmentMimeType(name, category);
  const sha = await sha256Hex(bytes);
  const presigned = await presignUpload(bytes.byteLength, mimeType, uploadExtForName(name), token);
  try {
    await putUpload(presigned.putUrl, bytes, mimeType);
  } catch (e) {
    try { await deleteUpload(presigned.key, token); } catch (e2) {}
    if (e instanceof Error) throw e;
    throw new AttachmentUploadError('upload failed');
  }
  const oss = new AttachmentOssRef();
  oss.ossKey = presigned.key;
  oss.mimeType = mimeType;
  oss.originalName = name;
  oss.size = bytes.byteLength;
  oss.sha256 = sha;
  const attachment = new RemoteSerializedAttachment();
  attachment.id = `harmony-upload:${presigned.key}`;
  attachment.name = name;
  attachment.originalName = name;
  attachment.path = buildAttachmentOssRef(oss);
  attachment.ext = uploadExtForName(name);
  attachment.size = bytes.byteLength;
  attachment.sha256 = sha;
  attachment.category = category;
  attachment.mimeType = mimeType;
  return attachment;
}
