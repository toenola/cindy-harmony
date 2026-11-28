import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { pickImageUris } from '../attachments/ImagePicker';
import { COMPANION_AVATAR_MAX } from './CompanionCreate';

/**
 * 新建伙伴的头像：预置头像与相册上传。
 *
 * 对齐 `apps/mobile/src/session/CompanionPortraitPicker.tsx`：
 * - 预置头像与 Mobile 同源（`apps/mobile/assets/bot-presets/portrait-gallery.json` 原样复制到
 *   rawfile），值是不带前缀的 JPEG base64，直接作为 avatarImageBase64 提交；
 * - 上传：正方形 256×256，JPEG 质量依次 85 / 65 / 40，base64 不超过 55000 字符，否则视为失败。
 *   Mobile 由系统裁剪框裁成正方形；鸿蒙相册选择器没有裁剪框，这里取中心正方形。
 */
const PORTRAIT_GALLERY = 'bot-presets/portrait-gallery.json';
let portraitCache: string[] | null = null;

export function companionPortraits(context: common.Context | undefined): string[] {
  if (portraitCache !== null) return portraitCache;
  if (context === undefined) return [];
  try {
    const bytes = context.resourceManager.getRawFileContentSync(PORTRAIT_GALLERY);
    const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
    const parsed = JSON.parse(text) as Object;
    const result: string[] = [];
    if (Array.isArray(parsed)) {
      for (const item of parsed as Object[]) {
        if (typeof item === 'string' && item.length > 0 && item.length <= COMPANION_AVATAR_MAX) result.push(item as string);
      }
    }
    portraitCache = result;
    return result;
  } catch (_error) {
    return [];
  }
}

export function randomCompanionPortrait(portraits: string[]): string {
  return portraits.length ? portraits[Math.floor(Math.random() * portraits.length)] : '';
}

/** 从相册选一张图做成头像；用户取消返回空字符串，无法处理时抛错。 */
export async function pickCompanionAvatar(current: () => boolean): Promise<string> {
  const uris = await pickImageUris(1);
  if (!current() || !uris.length) return '';
  const source = image.createImageSource(uris[0]);
  let pixel: image.PixelMap | null = null;
  let packer: image.ImagePacker | null = null;
  try {
    const info = await source.getImageInfo();
    const side = Math.min(info.size.width, info.size.height);
    if (side <= 0) throw new Error('Avatar unavailable');
    pixel = await source.createPixelMap();
    const region: image.Region = {
      x: Math.floor((info.size.width - side) / 2),
      y: Math.floor((info.size.height - side) / 2),
      size: { width: side, height: side },
    };
    await pixel.crop(region);
    await pixel.scale(256 / side, 256 / side);
    packer = image.createImagePacker();
    const encoder = new util.Base64Helper();
    let bytes = '';
    for (const quality of [85, 65, 40]) {
      const options: image.PackingOption = { format: 'image/jpeg', quality: quality };
      const data = await packer.packToData(pixel, options);
      bytes = encoder.encodeToStringSync(new Uint8Array(data));
      if (bytes && bytes.length <= COMPANION_AVATAR_MAX) break;
    }
    if (!bytes || bytes.length > COMPANION_AVATAR_MAX) throw new Error('Avatar unavailable');
    return current() ? bytes : '';
  } finally {
    await packer?.release();
    await pixel?.release();
    await source.release();
  }
}
