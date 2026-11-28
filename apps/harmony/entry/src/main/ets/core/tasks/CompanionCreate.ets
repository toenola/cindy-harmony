import { readObj, readStr, recordOrEmpty } from './TaskModels';
import { resourceText } from '../resources/ResourceModels';

/**
 * 新建伙伴：电脑端 `teammates/bot/create` 资源的解析与提交结果判定。
 *
 * 语义对齐 Mobile：
 * - `apps/mobile/src/session/companionProfileData.ts`：只认 `form` 块与它指向的 action；
 * - `apps/mobile/src/session/CompanionProfileSheet.tsx`（CompanionCreateSheet）：名字规范化、
 *   失败分类与 requestId 复用规则；
 * - 电脑端契约 `apps/desktop/src/main/localDb/ipc/botRemoteEditors.ts`（id === 'create'）。
 *
 * 本期不做模型选择器：提交不带 modelChain，由电脑端按默认模型创建；
 * 电脑端报告没有可用默认模型（creationModelChain 为空数组）时禁止提交。
 */
export class CompanionCreateForm {
  /** 电脑端 action id；为空表示这台电脑不能新建伙伴（旧版或已禁用）。 */
  actionId: string = '';
  nameLabel: string = '';
  avatarLabel: string = '';
  /** 电脑端声明了创建用模型、但默认模型为空。 */
  modelMissing: boolean = false;
}

/** 提交失败的含义：重名 / 电脑端明确拒绝（未创建）/ 结果未确认（可能已创建）。 */
export type CompanionCreateFailure = 'taken' | 'rejected' | 'unconfirmed';

export const COMPANION_CREATE_REF_ID = 'create';
export const COMPANION_NAME_MAX = 200;
/** 电脑端接受 60000 字符以内；本机生成的上传头像控制在 55000 以内（与 Mobile 一致）。 */
export const COMPANION_AVATAR_MAX = 55000;

/**
 * 电脑端文案的语言标签与 Mobile i18n 一致（zh-CN / zh-TW / ja / ko / en …），
 * 系统语言如 `zh-Hans-CN`、`zh-Hant-TW` 先换成这套标签再随请求发送。
 */
export function companionLocale(system: string): string {
  const tag = system.replace(/_/g, '-');
  const parts = tag.split('-');
  const language = (parts[0] || 'en').toLowerCase();
  if (language !== 'zh') return language;
  const rest = parts.slice(1).map((part: string): string => part.toLowerCase());
  return rest.includes('hant') || rest.includes('tw') || rest.includes('hk') || rest.includes('mo') ? 'zh-TW' : 'zh-CN';
}

/** 与 Desktop BotRosterView / Mobile 相同：NFKC、去首尾空白、不区分大小写。 */
export function normalizeTeammateName(name: string): string {
  return name.normalize('NFKC').trim().toLowerCase();
}

function fieldsOf(action: Record<string, Object>): string[] {
  const raw = action['fields'];
  if (!Array.isArray(raw)) return [];
  const ids: string[] = [];
  for (const item of raw as Object[]) {
    const id = readStr(recordOrEmpty(item), 'id');
    if (id) ids.push(id);
  }
  return ids;
}

function fieldLabel(action: Record<string, Object>, id: string, locale: string): string {
  const raw = action['fields'];
  if (!Array.isArray(raw)) return '';
  for (const item of raw as Object[]) {
    const field = recordOrEmpty(item);
    if (readStr(field, 'id') === id) return resourceText(field['label'], locale);
  }
  return '';
}

/** 解析 `maker:remote-resources:get` 返回的新建表单；资源本身不对时抛错，能力缺失时返回空 actionId。 */
export function parseCompanionCreateForm(value: Object | undefined, locale: string): CompanionCreateForm {
  const raw = recordOrEmpty(value);
  const ref = readObj(raw, 'ref');
  if (readStr(ref, 'collectionId') !== 'teammates' || readStr(ref, 'kind') !== 'bot'
    || readStr(ref, 'id') !== COMPANION_CREATE_REF_ID) {
    throw new Error('Invalid companion resource');
  }
  const form = new CompanionCreateForm();
  const blocks = raw['blocks'];
  const actions = raw['actions'];
  if (!Array.isArray(blocks) || !Array.isArray(actions)) return form;
  for (const item of blocks as Object[]) {
    const block = recordOrEmpty(item);
    if (readStr(block, 'id') !== 'create' || readStr(block, 'primitive') !== 'form') continue;
    const data = readObj(block, 'data');
    const actionId = readStr(data, 'actionId');
    let action: Record<string, Object> | null = null;
    for (const candidate of actions as Object[]) {
      const row = recordOrEmpty(candidate);
      if (readStr(row, 'id') === actionId) { action = row; break; }
    }
    if (!actionId || action === null) return form;
    const fields = fieldsOf(action);
    // 本表单只会提交名字与头像；电脑端若要求更多字段，就按旧版/不支持处理，不半填提交。
    if (fields.length !== 2 || !fields.includes('name') || !fields.includes('avatarImageBase64')) return form;
    form.nameLabel = fieldLabel(action, 'name', locale);
    form.avatarLabel = fieldLabel(action, 'avatarImageBase64', locale);
    const chain = data['creationModelChain'];
    if (typeof chain === 'string') {
      try {
        const parsed = JSON.parse(chain) as Object;
        form.modelMissing = !Array.isArray(parsed) || (parsed as Object[]).length === 0;
      } catch (_error) {
        form.modelMissing = true;
      }
    }
    if (action['disabled'] !== true) form.actionId = actionId;
    return form;
  }
  return form;
}

/** 从提交回执里取电脑端确认的新伙伴 id；没有导航回执视为未确认。 */
export function companionCreatedId(value: Object | undefined): string {
  const effects = recordOrEmpty(value)['effects'];
  if (!Array.isArray(effects)) return '';
  for (const item of effects as Object[]) {
    const effect = recordOrEmpty(item);
    const target = readObj(effect, 'target');
    const ref = readObj(target, 'ref');
    if (readStr(effect, 'kind') === 'navigate' && readStr(target, 'kind') === 'resource'
      && readStr(ref, 'collectionId') === 'teammates' && readStr(ref, 'kind') === 'bot') {
      return readStr(ref, 'id');
    }
  }
  return '';
}

/**
 * 只有电脑端明确拒绝（重名或参数无效）才能证明没有创建；其余错误（超时、断线）可能已经建好，
 * 重试必须带同一个 requestId，电脑端据此找回同一个伙伴而不是再建一个。
 */
export function classifyCompanionCreateFailure(error: Object): CompanionCreateFailure {
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes('ALREADY_EXISTS')) return 'taken';
  if (message.includes('INVALID_PARAMS')) return 'rejected';
  return 'unconfirmed';
}
