import { image } from '@kit.ImageKit';
import { pickImageUris } from '../attachments/ImagePicker';
import { HarmonyHttp } from '../../network/HarmonyHttp';
import { ChatRequest } from './ChatModels';
/** Authenticated OSS API port accepts /api/oss/presign-put on discovered ossApiBaseUrl. */
export async function pickChatAvatar(publicAssets: ChatRequest, current: () => boolean): Promise<string> {
  const check = (): void => { if (!current()) throw new Error('OWNER_CHANGED'); };
  check(); const uris = await pickImageUris(1); check(); if (!uris.length) return '';
  const source = image.createImageSource(uris[0]);
  let pixel: image.PixelMap | null = null, packer: image.ImagePacker | null = null;
  try {
    const info = await source.getImageInfo(); pixel = await source.createPixelMap(); check();
    const longest = Math.max(info.size.width, info.size.height);
    if (longest > 512) await pixel.scale(512 / longest, 512 / longest);
    packer = image.createImagePacker(); const options: image.PackingOption = { format: 'image/jpeg', quality: 85 };
    const bytes = await packer.packToData(pixel, options); check();
    if (bytes.byteLength <= 0 || bytes.byteLength > 5 * 1024 * 1024) throw new Error('AVATAR_TOO_LARGE');
    const body: Record<string, Object> = {}; body['scene'] = 'avatar'; body['contentType'] = 'image/jpeg'; body['size'] = bytes.byteLength;
    const signed = await publicAssets('/api/oss/presign-put', 'POST', body) as Record<string, Object>; check();
    const putUrl = signed['putUrl'], publicUrl = signed['publicUrl'];
    if (typeof putUrl !== 'string' || typeof publicUrl !== 'string' || !/^https:\/\//.test(putUrl) || !/^https:\/\//.test(publicUrl)) throw new Error('PROFILE_AVATAR_UPLOAD_FAILED');
    const headers: Record<string, string> = {}, raw = signed['headers'] as Record<string, Object>;
    if (raw) Object.keys(raw).forEach((key: string): void => { if (typeof raw[key] === 'string') headers[key] = raw[key] as string; });
    try { const status = await new HarmonyHttp().uploadBytes(putUrl, 'PUT', headers, bytes); if (status >= 300) throw new Error('PROFILE_AVATAR_UPLOAD_FAILED'); }
    catch (_) { throw new Error('PROFILE_AVATAR_UPLOAD_FAILED'); }
    check(); return publicUrl;
  } finally { await packer?.release(); await pixel?.release(); await source.release(); }
}
