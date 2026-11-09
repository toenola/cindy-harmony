/**
 * 编辑最后一条用户消息（v1.3.5 C3）。
 *
 * 行为事实源：`apps/mobile/src/session/messageEdit.ts` 与 `app/sessions/[sessionId].tsx`
 * （beginMessageEdit / submitMessageEdit / cancelMessageEdit）。语义：回退到这条消息
 * （对话截断 + 文件回滚，与「回退」同一条 rewind 链路），再用编辑后的内容立即重发。
 * 本模块只放与页面状态无关的纯逻辑。
 */

import { RemoteMessage } from '../tasks/TaskModels';
import {
  ComposerDocument,
  ComposerNode,
  composerDocumentHasContent,
  composerDocumentToStorage,
  normalizeComposerDocument,
  textNode,
} from './ComposerDocument';
import { RewindPreview } from './MessageStore';
import { RenderItem, RenderMessageItem } from './MessageRender';

/** 与桌面 RUNNING_RETRY_DEFAULTS 同预算（约 15 秒）：发送时才停止，这里等停止收尾。 */
export const MESSAGE_EDIT_RETRY_ATTEMPTS = 20;
export const MESSAGE_EDIT_RETRY_DELAY_MS = 750;

/** `maker:rewind:commit` 第 3 个参数。 */
export class MessageEditRewindOptions {
  /** 被控端在软删事务前权威核对目标仍是最新一条用户消息。 */
  requireLatestUser: boolean = true;
  /** 预览判定只能截断对话时为 false，提交不得意外恢复文件；其余情况不带这个键。 */
  allowFileRestore?: boolean;
}

export function errorHasCode(error: Object | undefined | null, code: string): boolean {
  if (error === undefined || error === null) return false;
  if (typeof error === 'object' && (error as Record<string, Object>)['code'] === code) return true;
  const message = error instanceof Error ? error.message : String(error);
  return message.indexOf(code) >= 0;
}

/**
 * 带重试的回退提交。被控端仍在运行时返回 SESSION_RUNNING：首次被拒时请求停止一次再等；
 * 点编辑不中断，只在发送时中断。每次重试前确认这次编辑仍有效，失效则放弃。
 */
export async function commitMessageEditRewind<T>(
  rewind: (options: MessageEditRewindOptions) => Promise<T>,
  conversationOnly: boolean,
  requestStop: () => void,
  stillCurrent: () => boolean,
  sleep: (ms: number) => Promise<void> = (ms: number): Promise<void> =>
    new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); }),
  attempts: number = MESSAGE_EDIT_RETRY_ATTEMPTS,
  delayMs: number = MESSAGE_EDIT_RETRY_DELAY_MS,
): Promise<T> {
  const options = new MessageEditRewindOptions();
  if (conversationOnly) options.allowFileRestore = false;
  for (let attempt = 0; ; attempt++) {
    try {
      return await rewind(options);
    } catch (error) {
      if (!errorHasCode(error as Object, 'SESSION_RUNNING') || attempt >= attempts) throw error as Error;
      // 迟到的 SESSION_RUNNING 若已遇上切换任务 / 放弃编辑，不得再停掉旧任务。
      if (!stillCurrent()) throw error as Error;
      if (attempt === 0) requestStop();
      await sleep(delayMs);
      if (!stillCurrent()) throw error as Error;
    }
  }
}

/** 编辑横幅上的文件回滚提示：files = 将撤销 count 个文件；conversation-only = 不恢复文件。 */
export class MessageEditRollbackHint {
  kind: string = '';
  count: number = 0;
}

export function messageEditRollbackHint(preview: RewindPreview | null): MessageEditRollbackHint {
  const hint = new MessageEditRollbackHint();
  if (preview === null || !preview.canRewind) return hint;
  if (preview.filesChanged.length > 0) {
    hint.kind = 'files';
    hint.count = preview.filesChanged.length;
  } else if (preview.conversationOnly) {
    hint.kind = 'conversation-only';
  }
  return hint;
}

/** 编辑重发失败的文案键；空串交给调用方的通用远程错误文案。 */
export function messageEditErrorKey(error: Object | undefined): string {
  if (errorHasCode(error, 'SESSION_RUNNING')) return 'v135_edit_stop_timeout';
  if (errorHasCode(error, 'REWIND_TARGET_NOT_LATEST') || errorHasCode(error, 'EDIT_NOT_LAST_MESSAGE')) {
    return 'v135_edit_not_last';
  }
  if (errorHasCode(error, 'NO_PRIOR_ASSISTANT')) return 'v135_edit_no_prior_assistant';
  return '';
}

function messageClientId(message: RemoteMessage): string {
  return message.clientId.length > 0 ? message.clientId : message.id;
}

/** 已加载窗口里最后一条可见的用户消息（只是入口门槛，被控端会权威核对）。 */
export function lastUserMessageClientId(items: RenderItem[]): string {
  for (let i = items.length - 1; i >= 0; i--) {
    const item = items[i];
    if (item.type !== 'message') continue;
    const row = item as RenderMessageItem;
    if (row.kind !== 'user' || row.hidden || row.message === undefined) continue;
    return messageClientId(row.message);
  }
  return '';
}

function sameDocument(a: ComposerDocument, b: ComposerDocument): boolean {
  return composerDocumentToStorage(a) === composerDocumentToStorage(b);
}

/**
 * 回退提交后页面已不在前台时，该任务草稿库的终态（幂等）：
 * 〔未入队的替代内容〕+〔库里本来就有的内容〕+〔暂存草稿〕，每份各一次。
 * 编辑期间输入框内容不写草稿库，所以库里要么仍是暂存草稿，要么是发送清空后的空草稿，要么是别的内容。
 */
export function mergeMessageEditDraft(stored: ComposerDocument | null, stash: ComposerDocument,
  replacement: ComposerDocument | null): ComposerDocument {
  const kept = stored !== null && !sameDocument(stored, stash) ? stored : null;
  const nodes: ComposerNode[] = [];
  const parts: (ComposerDocument | null)[] = [replacement, kept, stash];
  for (const part of parts) {
    if (part === null || !composerDocumentHasContent(part)) continue;
    if (nodes.length > 0) nodes.push(textNode('\n\n'));
    for (const node of part.nodes) nodes.push(node);
  }
  const merged = new ComposerDocument();
  merged.nodes = nodes;
  return normalizeComposerDocument(merged);
}
