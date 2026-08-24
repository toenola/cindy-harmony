/**
 * 交互请求的纯展示与决策语义。
 *
 * 行为以 packages/maker-shared/src/interaction.ts 为准；这里只做 ArkTS 适配，
 * 不在页面里重新发明风险判定或 Permission payload 契约。
 */

import { PendingInteraction } from './InteractionStore';

export class AskOptionPresentation {
  label: string = '';
  description: string = '';
}

export class PlanOutlinePresentation {
  id: string = '';
  title: string = '';
  level: number = 1;
  line: number = 0;
}

export class PlanReviewEvidencePresentation {
  filePath: string = '';
  fileName: string = '';
  compactPath: string = '';
  outlineItems: PlanOutlinePresentation[] = [];
  outlineOverflowCount: number = 0;
  outlineTotalCount: number = 0;
}

function readString(record: Record<string, Object>, key: string): string {
  const value = record[key];
  return typeof value === 'string' ? value : '';
}

function readRecord(record: Record<string, Object>, key: string): Record<string, Object> {
  const value = record[key];
  if (value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, Object>;
  }
  return {};
}

/** AskUserQuestion 选项的副标题是用户判断依据，不能在 ArkTS 归一化时丢弃。 */
export function askOptionPresentations(question: Record<string, Object>): AskOptionPresentation[] {
  const raw = question['options'];
  const out: AskOptionPresentation[] = [];
  if (!Array.isArray(raw)) return out;
  const rows = raw as Object[];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i] === null || typeof rows[i] !== 'object' || Array.isArray(rows[i])) continue;
    const record = rows[i] as Record<string, Object>;
    const label = readString(record, 'label').trim();
    if (label.length === 0) continue;
    const option = new AskOptionPresentation();
    option.label = label;
    option.description = readString(record, 'description').trim();
    out.push(option);
  }
  return out;
}

export function interactionPriority(kind: string): number {
  if (kind === 'plan_review') return 0;
  if (kind === 'permission') return 1;
  if (kind === 'ask_user_question') return 2;
  if (kind === 'issue_confirm') return 3;
  if (kind === 'plugin_setup') return 4;
  return 100;
}

/** 插入排序显式保留同优先级的到达顺序。 */
export function sortPendingInteractions(items: PendingInteraction[]): PendingInteraction[] {
  const out = items.slice();
  for (let i = 1; i < out.length; i++) {
    const value = out[i];
    let cursor = i - 1;
    while (cursor >= 0 && interactionPriority(out[cursor].kind) > interactionPriority(value.kind)) {
      out[cursor + 1] = out[cursor];
      cursor -= 1;
    }
    out[cursor + 1] = value;
  }
  return out;
}

export function interactionKindLabel(kind: string): string {
  if (kind === 'plan_review') return '计划';
  if (kind === 'permission') return '授权';
  if (kind === 'ask_user_question') return '问题';
  if (kind === 'issue_confirm') return 'Issue';
  if (kind === 'plugin_setup') return '插件';
  return '请求';
}

/**
 * 只有控制端能直接终结的交互才接管输入框。
 * issue_confirm / plugin_setup / unknown 仍展示状态卡，但不能让会话永久失去 Composer。
 */
export function interactionBlocksRemoteComposer(kind: string): boolean {
  return kind === 'permission' || kind === 'ask_user_question' || kind === 'plan_review';
}

/** 必须检查整个 pending 集合，切到只读卡不能绕过另一张真正阻塞的请求。 */
export function pendingInteractionsBlockRemoteComposer(items: PendingInteraction[]): boolean {
  for (let i = 0; i < items.length; i++) {
    if (interactionBlocksRemoteComposer(items[i].kind)) return true;
  }
  return false;
}

function basename(path: string): string {
  const normalized = path.replace(/\\/g, '/').replace(/\/+$/, '');
  const slash = normalized.lastIndexOf('/');
  return slash >= 0 ? normalized.slice(slash + 1) : normalized;
}

function compactPath(path: string): string {
  if (path.length <= 64) return path;
  const normalized = path.replace(/\\/g, '/');
  const parts = normalized.split('/');
  const tail = parts.length >= 2 ? `${parts[parts.length - 2]}/${parts[parts.length - 1]}` : basename(path);
  return `…/${tail}`;
}

function stripHeadingClosing(value: string): string {
  let end = value.length;
  while (end > 0 && /\s/.test(value[end - 1])) end -= 1;
  const hashEnd = end;
  while (end > 0 && value[end - 1] === '#') end -= 1;
  if (end === hashEnd || end === 0 || !/\s/.test(value[end - 1])) return value.trim();
  while (end > 0 && /\s/.test(value[end - 1])) end -= 1;
  return value.slice(0, end).trim();
}

export function buildPlanReviewEvidence(
  plan: string,
  filePath: string,
  maxOutlineItems: number = 3,
): PlanReviewEvidencePresentation {
  const out = new PlanReviewEvidencePresentation();
  out.filePath = filePath.trim();
  if (out.filePath.length > 0) {
    out.fileName = basename(out.filePath);
    out.compactPath = compactPath(out.filePath);
  }
  const headings: PlanOutlinePresentation[] = [];
  const lines = plan.replace(/\r\n/g, '\n').split('\n');
  let fence = '';
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    const marker = trimmed.startsWith('```') ? '```' : (trimmed.startsWith('~~~') ? '~~~' : '');
    if (marker.length > 0) {
      if (fence.length === 0) fence = marker;
      else if (marker === fence) fence = '';
      continue;
    }
    if (fence.length > 0) continue;
    const match = /^(#{1,3})\s+(\S.*)$/.exec(lines[i]);
    if (match === null) continue;
    const title = stripHeadingClosing(match[2]);
    if (title.length === 0) continue;
    const heading = new PlanOutlinePresentation();
    heading.id = `plan-heading-${i + 1}`;
    heading.title = title;
    heading.level = match[1].length;
    heading.line = i + 1;
    headings.push(heading);
  }
  out.outlineTotalCount = headings.length;
  const limit = Math.max(0, Math.floor(maxOutlineItems));
  out.outlineItems = limit === 0 ? [] : headings.slice(0, limit);
  out.outlineOverflowCount = Math.max(0, headings.length - out.outlineItems.length);
  return out;
}

/** 与 maker-shared isHighRiskShellCommand 保持同一组危险动作。 */
export function isHighRiskShellCommand(command: string): boolean {
  return /(^|[;&|]\s*)(sudo|rm\s+-[^\n;|&]*r|git\s+reset\s+--hard|git\s+push|curl\b[^\n|]*\|\s*(sh|bash)|wget\b[^\n|]*\|\s*(sh|bash)|chmod\s+-R|chown\s+-R|pkill|killall)\b/i
    .test(command);
}

/** 高风险 Permission 的用户提示；空串表示普通风险。 */
export function permissionRiskSummary(request: Record<string, Object>): string {
  const toolName = readString(request, 'toolName') || 'tool';
  if (toolName !== 'Bash') return '';
  const command = readString(readRecord(request, 'input'), 'command').trim();
  if (command.length === 0 || !isHighRiskShellCommand(command)) return '';
  return '这个命令可能修改系统、仓库或外部服务状态。允许前请确认你信任当前任务和命令内容。';
}

/**
 * Auto-review 故障降级说明；空串表示普通确认卡。
 *
 * 语义对齐 packages/maker-core/src/agents/shared/auto-review-decision.ts 的
 * AUTO_REVIEW_UNAVAILABLE_METADATA_KEY，文案与 Desktop zh-CN 确认卡同句
 * （apps/desktop/src/main/im/shared/autoReviewUnavailablePrompt.ts）：这张卡是
 * 自动审批没跑完的降级结果，不是普通 Ask，也不代表用户拒绝过。
 */
export function permissionAutoReviewUnavailableNotice(request: Record<string, Object>): string {
  if (readString(request, 'kind') !== 'permission') return '';
  if (readRecord(request, 'metadata')['autoReviewUnavailable'] !== true) return '';
  return '自动审批没完成，请确认要不要允许这次操作。';
}

export function permissionRequestFingerprint(  request: Record<string, Object>,
  action: string,
): string {
  return `${readString(request, 'requestId')}\u0000${action}\u0000${readString(request, 'toolName')}`
    + `\u0000${JSON.stringify(request['input'])}`;
}

/** 只接受共享契约 request.suggestions 中 destination=session 的更新。 */
export function sessionScopedPermissionSuggestions(request: Record<string, Object>): Object[] {
  const raw = request['suggestions'];
  const result: Object[] = [];
  if (!Array.isArray(raw)) return result;
  const rows = raw as Object[];
  for (let i = 0; i < rows.length; i++) {
    const suggestion = rows[i];
    if (suggestion === undefined || suggestion === null
      || typeof suggestion !== 'object' || Array.isArray(suggestion)) continue;
    const record = suggestion as Record<string, Object>;
    if (record['destination'] === 'session') result.push(suggestion);
  }
  return result;
}

/** 高风险操作永不提供“始终允许”；普通操作必须有 session 级建议才显示。 */
export function permissionCanAlwaysAllow(request: Record<string, Object>): boolean {
  return permissionRiskSummary(request).length === 0
    && sessionScopedPermissionSuggestions(request).length > 0;
}

export function buildPermissionDecision(
  request: Record<string, Object>,
  action: string,
): Record<string, Object> {
  const decision: Record<string, Object> = {};
  decision['kind'] = 'permission';
  if (action === 'deny') {
    decision['behavior'] = 'deny';
    decision['reason'] = 'User denied';
    return decision;
  }
  decision['behavior'] = 'allow';
  if (action === 'always-allow') {
    const suggestions = sessionScopedPermissionSuggestions(request);
    if (suggestions.length > 0) decision['permissionUpdates'] = suggestions;
  }
  return decision;
}
