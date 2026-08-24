/**
 * Composer 运行时能力目录：权限模式 / 推理强度 / 模型选项的模型与解析。
 *
 * 任务详情页与新建任务页共用同一份 capabilities / provider:list 数据口径，
 * 解析规则集中在这里，避免两页各自维护一份漂移的拷贝。
 */

import { readBool, readObj, readStr } from './tasks/TaskModels';

export class ComposerChoiceOption {
  id: string = '';
  label: string = '';
  description: string = '';
}

export class ComposerModelOption {
  id: string = '';
  label: string = '';
  description: string = '';
  efforts: string[] = [];
  defaultEffort: string = '';
  supportsFastMode: boolean = false;
  effortDisplayNames: Record<string, string> = {};
  /** provider-aware 目录行；空值表示旧 capabilities 扁平回退。 */
  providerId: string = '';
  providerName: string = '';
  providerLogoKind: string = '';
  modelIcon: string = '';
  subscription: boolean = false;
  /**
   * 该模型被远端标记为哪些 agent 的新任务默认种子（model-access v3 `newSessionDefault`）。
   * 客户端不跨 agent 投影；缺省表示不作为默认。
   */
  newSessionDefaultAgents: string[] = [];
  /** 远端陈列顺序；缺省用一个大值排到已标记项之后，保留稳定回退。 */
  sortOrder: number = Number.MAX_SAFE_INTEGER;
}

export class ComposerModelGroup {
  key: string = '';
  name: string = '';
  options: ComposerModelOption[] = [];
}

export class ProviderListOptions {
  capabilities: string[] = [];
}

/** 会话内切换模型时的目标 provider；新建任务页按最近会话回读。 */
export interface ModelSelectionHint {
  model: string;
  providerId: string;
}

export function permissionModeLabel(id: string, fallback: string): string {
  if (id === 'default') return '默认';
  if (id === 'ask') return '每次询问';
  if (id === 'acceptEdits') return '自动接受编辑';
  if (id === 'bypassPermissions') return '完全访问';
  if (id === 'auto') return '自动';
  return fallback.length > 0 ? fallback : id;
}

export function permissionModeDescription(id: string, fallback: string): string {
  if (id === 'default') return '使用当前 Agent 的默认权限策略。';
  if (id === 'ask') return '只读工具直接运行；写文件、执行命令和 MCP 工具每次询问。';
  if (id === 'acceptEdits') return '自动允许文件编辑；其它敏感操作仍会询问。';
  if (id === 'auto') return '工作区内写入和安全命令自动运行；高风险操作仍会询问。';
  if (id === 'bypassPermissions') return '所有工具无需询问即可运行。风险最高，仅用于可信任务。';
  return fallback;
}

/** 工具栏始终展示能力目录中的当前模式名称；旧主机缺目录时使用稳定中文回退。 */
export function selectedPermissionModeLabel(
  options: ComposerChoiceOption[],
  selectedId: string,
): string {
  for (let i = 0; i < options.length; i++) {
    if (options[i].id === selectedId) return options[i].label;
  }
  return permissionModeLabel(selectedId, '权限模式');
}

export function effortLevelLabel(id: string, fallback: string): string {
  if (id === 'minimal') return '最小';
  if (id === 'low') return '低';
  if (id === 'medium') return '中';
  if (id === 'high') return '高';
  if (id === 'xhigh') return '超高';
  if (id === 'max') return '最高';
  if (id === 'ultra') return '极致';
  return fallback.length > 0 ? fallback : id;
}

export function composerModelKey(option: ComposerModelOption): string {
  return option.providerId.length > 0 ? `${option.providerId}::${option.id}` : option.id;
}

/** 新建任务与任务详情按同一供应商口径组织模型目录。 */
export function groupComposerModelOptions(source: ComposerModelOption[]): ComposerModelGroup[] {
  const groups: ComposerModelGroup[] = [];
  for (let i = 0; i < source.length; i++) {
    const option = source[i];
    const providerId = option.providerId.trim();
    const providerName = option.providerName.trim();
    const key = providerId.length > 0
      ? providerId : providerName.length > 0 ? providerName : 'default-provider';
    let group: ComposerModelGroup | undefined = undefined;
    for (let j = 0; j < groups.length; j++) {
      if (groups[j].key === key) {
        group = groups[j];
        break;
      }
    }
    if (group === undefined) {
      group = new ComposerModelGroup();
      group.key = key;
      group.name = providerName.length > 0
        ? providerName : providerId.length > 0 ? providerId : '默认供应商';
      groups.push(group);
    }
    group.options.push(option);
  }
  return groups;
}

/** 与 Mobile 新建页同口径：切换模型后保留仍受支持的档位，否则回落模型默认档。 */
export function reconcileModelEffort(option: ComposerModelOption, currentEffort: string): string {
  if (option.efforts.length === 0) return '';
  if (option.efforts.indexOf(currentEffort) >= 0) return currentEffort;
  if (option.defaultEffort.length > 0 && option.efforts.indexOf(option.defaultEffort) >= 0) {
    return option.defaultEffort;
  }
  return option.efforts[0];
}

export function stringArrayHas(value: Object | undefined, expected: string): boolean {
  if (!Array.isArray(value)) return false;
  const values = value as Object[];
  for (let i = 0; i < values.length; i++) {
    if (values[i] === expected) return true;
  }
  return false;
}

export function parseChoiceOptions(value: Object | undefined, permission: boolean): ComposerChoiceOption[] {
  const out: ComposerChoiceOption[] = [];
  if (!Array.isArray(value)) return out;
  const rows = value as Object[];
  let hasAsk = false;
  if (permission) {
    for (let i = 0; i < rows.length; i++) {
      const raw = rows[i];
      if (raw === 'ask') hasAsk = true;
      else if (raw !== null && typeof raw === 'object' && !Array.isArray(raw)
        && readStr(raw as Record<string, Object>, 'id') === 'ask') hasAsk = true;
    }
  }
  const seenIds = new Set<string>();
  for (let i = 0; i < rows.length; i++) {
    const raw = rows[i];
    let id = '';
    let displayName = '';
    let description = '';
    if (typeof raw === 'string') {
      id = raw as string;
    } else if (raw !== null && typeof raw === 'object' && !Array.isArray(raw)) {
      const record = raw as Record<string, Object>;
      id = readStr(record, 'id');
      displayName = readStr(record, 'displayName') || readStr(record, 'name');
      description = readStr(record, 'description');
    }
    if (id.length === 0 || (permission && (id === 'plan' || (id === 'default' && hasAsk)))) continue;
    if (seenIds.has(id)) continue;
    seenIds.add(id);
    const option = new ComposerChoiceOption();
    option.id = id;
    option.label = permission
      ? permissionModeLabel(id, displayName)
      : effortLevelLabel(id, displayName);
    option.description = permission
      ? permissionModeDescription(id, description)
      : description;
    out.push(option);
  }
  return out;
}

export function parseModelOptions(value: Object | undefined): ComposerModelOption[] {
  const out: ComposerModelOption[] = [];
  if (!Array.isArray(value)) return out;
  const rows = value as Object[];
  for (let i = 0; i < rows.length; i++) {
    const raw = rows[i];
    const option = new ComposerModelOption();
    if (typeof raw === 'string') {
      option.id = raw as string;
      option.label = option.id;
    } else if (raw !== null && typeof raw === 'object' && !Array.isArray(raw)) {
      const record = raw as Record<string, Object>;
      option.id = readStr(record, 'id');
      option.label = readStr(record, 'displayName') || readStr(record, 'name') || option.id;
      option.description = readStr(record, 'description');
      option.defaultEffort = readStr(record, 'defaultEffort');
      option.supportsFastMode = readBool(record, 'supportsFastMode', false);
      readNewSessionDefaults(record, option);
      readEffortDisplayNames(record, option);
      const rawEfforts = record['efforts'];
      if (Array.isArray(rawEfforts)) {
        const effortValues = rawEfforts as Object[];
        for (let j = 0; j < effortValues.length; j++) {
          if (typeof effortValues[j] === 'string') option.efforts.push(effortValues[j] as string);
        }
      }
    }
    if (option.id.length > 0) out.push(option);
  }
  return out;
}

/**
 * 读取远端默认标记与陈列顺序。
 *
 * 语义对齐 packages/model-providers/src/types.ts 的 `newSessionDefault`：v3 显式标记
 * 'claude-code' / 'codex' / 'pi'，客户端不跨 agent 投影，非法值整项忽略而不整表失败。
 */
function readNewSessionDefaults(record: Record<string, Object>, option: ComposerModelOption): void {
  const order = record['sortOrder'];
  if (typeof order === 'number' && Number.isFinite(order)) option.sortOrder = order as number;
  // 显式停用的模型不参与默认种子（对齐 desktop 的 defaultEnabled !== false 过滤）。
  if (!readBool(record, 'defaultEnabled', true)) return;
  const raw = record['newSessionDefault'];
  if (!Array.isArray(raw)) return;
  const rows = raw as Object[];
  for (let i = 0; i < rows.length; i++) {
    if (typeof rows[i] === 'string') {
      const agent = (rows[i] as string).trim();
      if (agent.length > 0) option.newSessionDefaultAgents.push(agent);
    }
  }
}

/**
 * 远端标记的新任务默认模型。
 *
 * 语义对齐 apps/desktop/src/renderer/features/cc-agent/deviceLinkDraftDefaults.ts：
 * 只取被**当前 agent** 标记的候选，按 `sortOrder` 再按目录顺序取第一个；
 * 保留候选原始 provider 身份，不按显示名跨 provider 合并。无标记时返回 null，
 * 由调用方回退到当前稳定默认值——用户手动选择始终优先，目录刷新不得改回默认。
 */
export function resolveNewSessionDefaultModel(
  options: ComposerModelOption[],
  agent: string,
): ComposerModelOption | null {
  if (agent.length === 0) return null;
  let best: ComposerModelOption | null = null;
  let bestOrder = 0;
  for (let i = 0; i < options.length; i++) {
    const option = options[i];
    if (!stringArrayHasAgent(option.newSessionDefaultAgents, agent)) continue;
    if (best === null || option.sortOrder < bestOrder) {
      best = option;
      bestOrder = option.sortOrder;
    }
  }
  return best;
}

function stringArrayHasAgent(values: string[], agent: string): boolean {
  for (let i = 0; i < values.length; i++) {
    if (values[i] === agent) return true;
  }
  return false;
}

function readEffortDisplayNames(record: Record<string, Object>, option: ComposerModelOption): void {  const displayNames = readObj(record, 'effortDisplayNames');
  const keys = Object.keys(displayNames);
  for (let i = 0; i < keys.length; i++) {
    const label = readStr(displayNames, keys[i]);
    if (label.length > 0) option.effortDisplayNames[keys[i]] = label;
  }
}

/**
 * 解析被控端 maker:provider:list 的 per-provider 模型目录。
 * capabilities.availableModels 是跨 provider 去重后的旧平面列表，只能作为旧主机回退；
 * 只要 provider:list 有 connected 来源，就必须以这里的用户配置为准，保留同名模型的
 * 不同 provider 行、订阅标记、模型图标和 per-provider Fast/effort 能力。
 *
 * 同名模型必须保留 providerId，否则新任务可能被路由到错误的凭证来源。
 */
export function parseProviderModelOptions(
  value: Object | undefined,
  agent: string,
  visibilityOverrides: Map<string, boolean>,
  selectionHint: ModelSelectionHint | undefined,
): ComposerModelOption[] {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return [];
  }
  const root = value as Record<string, Object>;
  const rawProvidersValue = root['providers'];
  if (!Array.isArray(rawProvidersValue)) return [];
  const rawProviders = rawProvidersValue as Object[];
  const out: ComposerModelOption[] = [];
  for (let i = 0; i < rawProviders.length; i++) {
    const rawProvider: Object = rawProviders[i];
    if (rawProvider === null || typeof rawProvider !== 'object' || Array.isArray(rawProvider)) continue;
    const provider = rawProvider as Record<string, Object>;
    if (!readBool(provider, 'connected', false) || readBool(provider, 'suspended', false)) continue;
    const providerId = readStr(provider, 'id');
    if (providerId.length === 0 || !stringArrayHas(provider['agents'], agent)) continue;
    const modelsByAgent = readObj(provider, 'models');
    const rawModelsValue = modelsByAgent[agent];
    if (!Array.isArray(rawModelsValue)) continue;
    const access = readObj(provider, 'access');
    const subscription = readStr(access, 'kind') === 'subscription';
    const providerName = readStr(provider, 'name') || providerId;
    const providerLogoKind = readStr(provider, 'logoKind');
    const rawModels = rawModelsValue as Object[];
    for (let j = 0; j < rawModels.length; j++) {
      const rawModel = rawModels[j];
      if (rawModel === null || typeof rawModel !== 'object' || Array.isArray(rawModel)) continue;
      const model = rawModel as Record<string, Object>;
      const id = readStr(model, 'id');
      if (id.length === 0 || readBool(model, 'disabled', false)) continue;
      const visibilityKey = `${agent}:${providerId}:${id}`;
      const visibility = visibilityOverrides.get(visibilityKey);
      const isSelected = selectionHint !== undefined
        && selectionHint.model === id && selectionHint.providerId === providerId;
      if (visibility === false && !isSelected) continue;
      if (visibility === undefined && !readBool(model, 'defaultEnabled', true) && !isSelected) continue;
      const option = new ComposerModelOption();
      option.id = id;
      option.label = readStr(model, 'name') || readStr(model, 'displayName') || id;
      option.description = readStr(model, 'description');
      option.defaultEffort = readStr(model, 'defaultEffort');
      option.supportsFastMode = readBool(model, 'supportsFastMode', false);
      readNewSessionDefaults(model, option);
      readEffortDisplayNames(model, option);
      option.providerId = providerId;
      option.providerName = providerName;
      option.providerLogoKind = providerLogoKind;
      option.modelIcon = readStr(model, 'icon');
      option.subscription = subscription;
      const rawEfforts = model['efforts'];
      if (Array.isArray(rawEfforts)) {
        const efforts = rawEfforts as Object[];
        for (let k = 0; k < efforts.length; k++) {
          if (typeof efforts[k] === 'string') option.efforts.push(efforts[k] as string);
        }
      }
      out.push(option);
    }
  }
  return out;
}

/** 从 provider:list 结果提取 modelVisibilityOverrides；无则返回空表。 */
export function parseModelVisibilityOverrides(value: Object | undefined): Map<string, boolean> {
  const out = new Map<string, boolean>();
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return out;
  }
  const raw = (value as Record<string, Object>)['modelVisibilityOverrides'];
  if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    return out;
  }
  const overrides = raw as Record<string, Object>;
  const keys = Object.keys(overrides);
  for (let i = 0; i < keys.length; i++) {
    if (typeof overrides[keys[i]] === 'boolean') out.set(keys[i], overrides[keys[i]] as boolean);
  }
  return out;
}

/** 模型/Agent 目录行首的提供方标识。 */
export function modelProviderKind(option: ComposerModelOption): string {
  const icon = option.modelIcon.toLowerCase();
  const logo = option.providerLogoKind.toLowerCase();
  const provider = option.providerId.toLowerCase();
  const id = option.id.toLowerCase();
  if (icon.includes('claude') || logo.includes('anthropic') || provider === 'anthropic') return 'claude';
  if (icon.includes('openai') || logo.includes('openai') || provider === 'openai') return 'openai';
  if (icon.includes('deepseek') || logo.includes('deepseek') || provider === 'deepseek'
    || id.includes('deepseek')) return 'deepseek';
  if (option.providerId.length === 0 && (id.includes('gpt') || id.includes('openai') || id.includes('codex'))) {
    return 'openai';
  }
  return 'other';
}
