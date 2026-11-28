import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { pickImageUris, buildImageCandidate } from '../attachments/ImagePicker';
import { readFileBytes } from '../attachments/ImagePreprocess';
import { HarmonyHttp } from '../../network/HarmonyHttp';
import { ChatBlock, ChatRequest } from './ChatModels';
import { uploadChatAttachment, ChatUploadCandidate } from './ChatUpload';
export interface ChatAttachmentPickerPort {
  pick(room: string, images: boolean, remaining: number, uploaded: (block: ChatBlock) => void): Promise<void>;
}
/** Native pickers authorize URI access; only sealed cloud media IDs enter the durable outbox. */
export class ChatAttachmentPicker implements ChatAttachmentPickerPort {
  private context: common.UIAbilityContext;
  private request: ChatRequest;
  private current: () => boolean;
  private generation: number = 0;
  constructor(context: common.UIAbilityContext, request: ChatRequest, current: () => boolean) {
    this.context = context; this.request = request; this.current = current;
  }
  dispose(): void { this.generation++; }
  async pick(room: string, images: boolean, remaining: number, uploaded: (block: ChatBlock) => void): Promise<void> {
    if (remaining <= 0 || !this.current()) return;
    const g = this.generation;
    const live = (): boolean => this.current() && g === this.generation;
    let uris: string[];
    if (images) uris = await pickImageUris(Math.min(20, remaining));
    else {
      const view = new picker.DocumentViewPicker(this.context), options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = Math.min(20, remaining); options.selectMode = picker.DocumentSelectMode.FILE;
      uris = await view.select(options);
    }
    if (!live()) return;
    for (let i = 0; i < uris.length; i++) {
      if (!live()) return;
      let candidate: ChatUploadCandidate;
      if (images) {
        const image = await buildImageCandidate(uris[i], i);
        candidate = { name: image.name, uri: image.uri, size: image.size, type: image.mimeType };
      } else {
        const file = fileIo.openSync(uris[i], fileIo.OpenMode.READ_ONLY);
        let size = 0; try { size = fileIo.statSync(file.fd).size; } finally { fileIo.closeSync(file); }
        let name = uris[i].slice(uris[i].lastIndexOf('/') + 1);
        try { name = decodeURIComponent(name); } catch (_) {}
        candidate = { name: name || 'attachment', uri: uris[i], size, type: 'application/octet-stream' };
      }
      const block = await uploadChatAttachment(this.request, room, candidate, util.generateRandomUUID(),
        async (address: string, uri: string, mime: string): Promise<void> => {
          if (!live()) throw new Error('OWNER_CHANGED');
          const bytes = await readFileBytes(uri); if (!live()) throw new Error('OWNER_CHANGED');
          const headers: Record<string, string> = {}; headers['Content-Type'] = mime;
          try { const status = await new HarmonyHttp().uploadBytes(address, 'PUT', headers, bytes); if (status >= 300) throw new Error('MEDIA_UPLOAD_FAILED'); }
          catch (_) { throw new Error('MEDIA_UPLOAD_FAILED'); }
        }, live);
      if (live()) uploaded(block);
    }
  }
}
