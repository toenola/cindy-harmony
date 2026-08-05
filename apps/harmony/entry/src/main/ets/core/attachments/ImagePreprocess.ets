/**
 * 图片上传前压缩（ArkTS 移植 mobileImagePreprocess.ts 语义）。
 *
 * - gif 跳过（重编码毁动画）；
 * - png/webp 只在长边 > 2048 时缩尺寸，输出 PNG（保透明）；
 * - 其他输出 JPEG quality 80；文件 < 400KB 且不长边 → 原样；
 * - 处理失败或产物反而更大 → 回退原图字节。
 *
 * 压缩产物为内存 ArrayBuffer（上传 PUT 直接复用，无需落盘）。
 */

import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';

export class PreprocessPlan {
  resize: boolean = false;
  format: string = 'jpeg'; // 'jpeg' | 'png'
  quality: number = 80;
}

/** 长边超过此值才缩尺寸（对齐 mobile：2048 > Anthropic 上限 ~1568）。 */
export const MAX_LONG_EDGE = 2048;
export const JPEG_QUALITY = 80;
/** 小于此值不值得重编码。 */
export const SKIP_BYTES = 400 * 1024;

/** 决定要不要 / 怎么压缩。返回 null = 原样上传。 */
export function planImagePreprocess(
  mimeType: string,
  size: number,
  width: number,
  height: number,
): PreprocessPlan | null {
  const mime = mimeType.trim().toLowerCase();
  if (mime === 'image/gif') {
    return null;
  }
  const longEdge = Math.max(width, height);
  const needsResize = longEdge > MAX_LONG_EDGE;
  const isBig = size > SKIP_BYTES;
  if (mime === 'image/png' || mime === 'image/webp') {
    // 可能带透明，只缩尺寸不重编码格式（输出 PNG 保 alpha）。
    if (!needsResize) return null;
    const plan = new PreprocessPlan();
    plan.resize = true;
    plan.format = 'png';
    plan.quality = 100;
    return plan;
  }
  if (!needsResize && !isBig) {
    return null;
  }
  const plan = new PreprocessPlan();
  plan.resize = needsResize;
  plan.format = 'jpeg';
  plan.quality = JPEG_QUALITY;
  return plan;
}

/** 读取本地文件字节。 */
export async function readFileBytes(uri: string): Promise<ArrayBuffer> {
  const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const stat = fileIo.statSync(file.fd);
    const buf = new ArrayBuffer(stat.size);
    fileIo.readSync(file.fd, buf);
    return buf;
  } finally {
    fileIo.closeSync(file);
  }
}

export class PreprocessResult {
  bytes: ArrayBuffer = new ArrayBuffer(0);
  mimeType: string = '';
  size: number = 0;
}

/**
 * 压缩入口：plan 为 null 或执行失败或产物更大 → 返回原图字节。
 */
export async function preprocessImage(
  uri: string,
  mimeType: string,
  size: number,
  width: number,
  height: number,
): Promise<PreprocessResult> {
  const plan = planImagePreprocess(mimeType, size, width, height);
  if (plan === null) {
    const bytes = await readFileBytes(uri);
    const out = new PreprocessResult();
    out.bytes = bytes;
    out.mimeType = mimeType;
    out.size = bytes.byteLength;
    return out;
  }
  try {
    const source = image.createImageSource(uri);
    const info = await source.getImageInfo();
    const pixelMap = await source.createPixelMap();
    if (plan.resize) {
      // 等比缩放（长边压到 2048）——PackingOption 无缩尺寸字段，走 PixelMap.scale。
      const w = info.size.width;
      const h = info.size.height;
      const longEdge = Math.max(w, h);
      if (longEdge > MAX_LONG_EDGE) {
        const scale = MAX_LONG_EDGE / longEdge;
        await pixelMap.scale(scale, scale);
      }
    }
    const packer = image.createImagePacker();
    const packingOptions: image.PackingOption = {
      format: plan.format === 'png' ? 'image/png' : 'image/jpeg',
      quality: plan.quality,
    };
    const buffer = await packer.packing(pixelMap, packingOptions);
    pixelMap.release();
    source.release();
    // 产物没变小 → 白做，回退原图。
    if (buffer.byteLength >= size) {
      const bytes = await readFileBytes(uri);
      const out = new PreprocessResult();
      out.bytes = bytes;
      out.mimeType = mimeType;
      out.size = bytes.byteLength;
      return out;
    }
    const out = new PreprocessResult();
    out.bytes = buffer;
    out.mimeType = plan.format === 'png' ? 'image/png' : 'image/jpeg';
    out.size = buffer.byteLength;
    return out;
  } catch (e) {
    // 压缩失败不能挡发图，回退原图。
    const bytes = await readFileBytes(uri);
    const out = new PreprocessResult();
    out.bytes = bytes;
    out.mimeType = mimeType;
    out.size = bytes.byteLength;
    return out;
  }
}
