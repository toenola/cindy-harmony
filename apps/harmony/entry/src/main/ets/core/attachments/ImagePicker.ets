/**
 * 图片选择（PhotoViewPicker）+ 候选构建（读取尺寸 / 大小 / 真实 mime）。
 */

import { common } from '@kit.AbilityKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { ImageAttachmentCandidate } from './AttachmentModels';

function pickerError(error: Object): Error {
  return error instanceof Error ? error : new Error('image picker failed');
}

/** 从相册选图（多选），返回 photo uri 列表。 */
export async function pickImageUris(maxCount: number): Promise<string[]> {
  if (maxCount <= 0) {
    return [];
  }
  const picker = new photoAccessHelper.PhotoViewPicker();
  const options: photoAccessHelper.PhotoSelectOptions = {
    MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
    maxSelectNumber: maxCount,
  };
  try {
    const result = await picker.select(options);
    return result.photoUris;
  } catch (e) {
    throw pickerError(e);
  }
}

/** 从系统截图目录选图；无法定位截图目录时显式失败，不退化为普通照片。 */
export async function pickScreenshotUris(context: common.Context, maxCount: number): Promise<string[]> {
  if (maxCount <= 0) {
    return [];
  }
  try {
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    const albumId = await helper.getAlbumIdByLpath('/Pictures/Screenshots');
    const filter = new photoAccessHelper.OperationItem();
    filter.operationType = photoAccessHelper.OperationType.EQUAL_TO;
    filter.field = photoAccessHelper.PhotoKeys.OWNER_ALBUM_ID;
    filter.value = [albumId];
    const picker = new photoAccessHelper.PhotoViewPicker();
    const options: photoAccessHelper.PhotoSelectOptions = {
      MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: maxCount,
      assetFilter: [filter],
    };
    const result = await picker.select(options);
    return result.photoUris;
  } catch (e) {
    throw pickerError(e);
  }
}

/** 拉起系统相机 picker 拍照；取消或失败返回空串。 */
export async function takePhotoUri(context: common.Context): Promise<string> {
  const profile: cameraPicker.PickerProfile = {
    cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK,
  };
  const result = await cameraPicker.pick(
    context,
    [cameraPicker.PickerMediaType.PHOTO],
    profile,
  );
  return result.resultCode === 0 ? result.resultUri : '';
}

/** 读文件前 N 字节，嗅探真实图片 mime（photoAccessHelper 不直接给 mime）。 */
function sniffImageMime(bytes: Uint8Array): string {
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8) {
    return 'image/jpeg';
  }
  if (bytes.length >= 4 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46) {
    return 'image/webp';
  }
  return 'image/jpeg';
}

function extForMime(mimeType: string): string {
  if (mimeType === 'image/png') return 'png';
  if (mimeType === 'image/gif') return 'gif';
  if (mimeType === 'image/webp') return 'webp';
  return 'jpg';
}

/** 构建上传候选：uri → 大小 / 宽高 / 真实 mime / 默认名。 */
export async function buildImageCandidate(uri: string, index: number): Promise<ImageAttachmentCandidate> {
  const candidate = new ImageAttachmentCandidate();
  candidate.uri = uri;
  candidate.mimeType = 'image/jpeg';
  candidate.size = 0;
  // 大小 + 文件头嗅探 mime
  try {
    const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = fileIo.statSync(file.fd);
      candidate.size = stat.size;
      const headLen = Math.min(stat.size, 16);
      if (headLen > 0) {
        const head = new ArrayBuffer(headLen);
        fileIo.readSync(file.fd, head);
        candidate.mimeType = sniffImageMime(new Uint8Array(head));
      }
    } finally {
      fileIo.closeSync(file);
    }
  } catch (e) {
    candidate.size = 0;
  }
  // 宽高
  let source: image.ImageSource | null = null;
  try {
    source = image.createImageSource(uri);
    const info = await source.getImageInfo();
    candidate.width = info.size.width;
    candidate.height = info.size.height;
  } catch (e) {
    candidate.width = 0;
    candidate.height = 0;
  } finally {
    if (source !== null) {
      try {
        await source.release();
      } catch (e) {
        // 候选构建已完成；释放失败不能阻断附件选择。
      }
    }
  }
  candidate.name = `image-${index + 1}.${extForMime(candidate.mimeType)}`;
  return candidate;
}
