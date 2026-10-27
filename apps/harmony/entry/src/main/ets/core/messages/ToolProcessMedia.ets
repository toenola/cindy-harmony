/**
 * 工具原生过程媒体（MCP / Anthropic / Pi 内容块里的图片、视频）。
 *
 * 事实源：`packages/maker-shared/src/toolProcessMedia.ts`。Host 把原生媒体写进工具结果的展示信封
 * `{"text": …, "cindy_process_media": [{kind, url}], "cindy_process_media_omitted": n}`；
 * 媒体留在所属工具步骤里，正文只显示信封中的文字。绝不从正文或命令里推断媒体。
 */
export class ProcessMediaRef {
  kind: string = ''; // image | video
  url: string = '';
}

const ENVELOPE_KEY = 'cindy_process_media';
const OMITTED_KEY = 'cindy_process_media_omitted';

function envelope(text: string): Record<string, Object> | null {
  if (text.indexOf(ENVELOPE_KEY) === -1) return null;
  try {
    const parsed = JSON.parse(text) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
    const record = parsed as Record<string, Object>;
    return Array.isArray(record[ENVELOPE_KEY]) ? record : null;
  } catch (_error) {
    return null;
  }
}

export function isProcessMediaUrl(url: string): boolean {
  return /^cindy-media:\/\/blobs\/[a-f0-9]{64}\.(?:png|jpg|jpeg|gif|webp|mp4|webm|mov)$/.test(url)
    || /^xdt-(?:image|video):\/\//.test(url)
    || /^https?:\/\//.test(url);
}

export function readToolProcessMedia(text: string): ProcessMediaRef[] {
  const record = envelope(text);
  if (record === null) return [];
  const out: ProcessMediaRef[] = [];
  const list = record[ENVELOPE_KEY] as Object[];
  for (let i = 0; i < list.length; i++) {
    const item = list[i];
    if (item === null || typeof item !== 'object' || Array.isArray(item)) continue;
    const media = item as Record<string, Object>;
    const kind = media['kind'];
    const url = media['url'];
    if ((kind !== 'image' && kind !== 'video') || typeof url !== 'string' || !isProcessMediaUrl(url as string)) {
      continue;
    }
    const ref = new ProcessMediaRef();
    ref.kind = kind as string;
    ref.url = url as string;
    out.push(ref);
  }
  return out;
}

/** 只剥掉我们的展示信封；普通 JSON 工具输出保持原样。 */
export function readToolProcessText(text: string): string {
  const record = envelope(text);
  if (record === null) return text;
  const body: Record<string, Object> = {};
  Object.keys(record).forEach((key: string) => {
    if (key !== ENVELOPE_KEY && key !== OMITTED_KEY) body[key] = record[key];
  });
  const keys = Object.keys(body);
  if (keys.length === 1 && keys[0] === 'text' && typeof body['text'] === 'string') return body['text'] as string;
  return JSON.stringify(body, null, 2);
}

/** 只有 Host 签发的交付记录才允许重试；任意路径 / URL 都不行。返回空串表示不可重试。 */
export function readFailedImageDelivery(text: string): string {
  if (text.indexOf('native_image_delivery') === -1) return '';
  try {
    const parsed = JSON.parse(text) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return '';
    const record = parsed as Record<string, Object>;
    const delivery = record['native_image_delivery'];
    if (record['kind'] !== 'generation' || delivery === null || typeof delivery !== 'object'
      || Array.isArray(delivery)) return '';
    const value = delivery as Record<string, Object>;
    const id = value['id'];
    return value['state'] === 'failed' && typeof id === 'string' && /^[a-f0-9]{64}$/.test(id as string)
      ? id as string : '';
  } catch (_error) {
    return '';
  }
}
