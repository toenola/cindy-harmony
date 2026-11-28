import { ChatBlock, ChatRequest, chatId } from './ChatModels';
export interface ChatUploadCandidate { name: string; type: string; size: number; uri: string }
export type ChatUploadPut = (url: string, uri: string, mime: string) => Promise<void>;
/** Signed PUT URLs receive no Cindy token. URI read/copy belongs to the system picker owner. */
export async function uploadChatAttachment(request: ChatRequest, room: string, candidate: ChatUploadCandidate,
  operationId: string, put: ChatUploadPut, current: () => boolean): Promise<ChatBlock> {
  const check = (): void => { if (!current()) throw new Error('OWNER_CHANGED'); };
  check();
  if (!Number.isSafeInteger(candidate.size) || candidate.size <= 0) throw new Error('ATTACHMENT_UNAVAILABLE');
  if (candidate.size > 100 * 1024 * 1024) throw new Error('ATTACHMENT_TOO_LARGE');
  const base = `/v1/conversations/${chatId(room)}/media`;
  const body: Record<string, Object> = {}; body['operationId'] = `media:${operationId}`; body['name'] = candidate.name;
  body['type'] = candidate.type || 'application/octet-stream'; body['size'] = candidate.size;
  const upload = await request(base, 'POST', body) as Record<string, Object>;
  check(); const id = chatId(upload['id'] as string), url = upload['uploadUrl'] as string;
  if (!/^https:\/\//i.test(url) || /^https:\/\/[^/]*@/.test(url)) throw new Error('INVALID_CHAT_URL');
  await put(url, candidate.uri, candidate.type || 'application/octet-stream'); check();
  const seal: Record<string, Object> = {}; seal['operationId'] = `seal:${id}`;
  await request(`${base}/${id}/complete`, 'POST', seal); check();
  return { type: 'media', mediaId: id, caption: candidate.name };
}
