/**
 * 消息渲染模型构建器（ArkTS 精简版）。
 *
 * 语义对齐 packages/maker-shared/src/messageNormalize.ts 与 messageRender.ts：
 * - tool_use / tool_result 按 toolUseId 配对（缺失时走紧邻下一跳兜底）；
 * - 连续 tool_use 聚合成 tool_group，result 到达后并入；
 * - todo 卡从 TodoWrite / update_plan / Task* 工具的 input 提取；
 * - thinking 独立折叠块；user/assistant/system/error 为消息块。
 *
 * work_group 按 shared 的 turn 规则聚合；agent_task 子代理卡、tool_media
 * 独立媒体项按托管引用抽取。原始 RemoteMessage 引用保留在渲染项里，
 * 供消息动作（复制/Fork/Rewind）与媒体识别使用。
 */

import {
  RemoteMessage, readStr, readObj, readAny,
} from '../tasks/TaskModels';
import { parseMarkdown, MdBlock } from './MarkdownParser';
import { RemoteImageRef, RemoteSerializedAttachment } from '../attachments/AttachmentModels';
import {
  RenderDiffPayload,
  RenderMediaPayload,
  buildToolDiff,
  extractToolResultMedia,
  parseMessageFiles,
} from './MessagePayload';
import {
  AgentTaskUpdate,
  deriveAgentTaskStatus,
  findAgentTaskUpdate,
  isAgentTaskToolName,
} from './AgentTaskStore';
import { isAutoResumeRowInFlight } from './AutoResumePresentation';
import { findErrorTailClientId } from './SessionTailPresentation';

// ─── 渲染项类型 ──────────────────────────────────────────────────────────────

export class RenderItem {
  type: string = '';
  key: string = '';
}

class GroupedTurnResult {
  items: RenderItem[] = [];
  handled: boolean = false;
}

/** 粘贴区间（user 消息 content.pastedTextRanges，桌面端落库保留的结构）。 */
export class RenderPasteRange {
  start: number = 0;
  end: number = 0;
  display: string = '';
}

/** 用户消息按内容特征切出的文本段（长文本折叠 / 正常渲染）。 */
export class RenderTextSegment {
  seq: number = 0;
  text: string = '';
  isPasted: boolean = false;
  /** 粘贴段的 display 摘要（chip 显示用，对齐 iOS InlineReferenceChip）。 */
  display: string = '';
  mdBlocks: MdBlock[] = [];
}

/** 普通消息块（user / assistant / system / error / agent_switch …）。 */
export class RenderMessageItem extends RenderItem {
  kind: string = '';
  label: string = '';
  body: string = '';
  /** 预解析的 Markdown 块（渲染直接消费，避免 @Builder 内做逻辑）。 */
  mdBlocks: MdBlock[] = [];
  /** user 消息按内容特征切出的渲染段（长文本折叠 / 正常）。 */
  segments: RenderTextSegment[] = [];
  /** user 消息携带的图片引用（content.images，URL 为 cindy-oss-attach 或 OSS 直链）。 */
  images: RemoteImageRef[] = [];
  /** user 消息携带的普通文件；与 Mobile 一致放在正文气泡外。 */
  files: RemoteSerializedAttachment[] = [];
  message: RemoteMessage | undefined = undefined;
  /** 自动续跑活动态由 projection owner 判定，不能仅靠 maker running 猜测。 */
  autoResumeInFlight: boolean = false;
  /** 合成输入仍作为 turn boundary，但不进入最终 UI。 */
  hidden: boolean = false;
  /** 旧历史缺 turn seal 时，由用户轮次边界推导出的最终 assistant。 */
  isTurnFinalAssistant: boolean = false;
}

/** thinking 折叠块。 */
export class RenderThinkingItem extends RenderItem {
  body: string = '';
  mdBlocks: MdBlock[] = [];
  /** 思考时长 ms（落库 content.durationMs）。 */
  /** -1 = 上游没有提供时长（0 仍代表极短思考）。 */
  durationMs: number = -1;
  /** 已隐藏（redacted，无明文）。 */
  redacted: boolean = false;
  /** 落库时间 ISO（work_group 时长计算用）。 */
  createdAt: string = '';
}

export class ThinkingPresentation {
  body: string = '';
  durationMs: number = -1;
  redacted: boolean = false;
  startedAt: string = '';
}

export function parseThinkingPresentation(message: RemoteMessage): ThinkingPresentation | null {
  const out = new ThinkingPresentation();
  out.startedAt = message.createdAt;
  if (typeof message.content === 'string') {
    out.body = message.content;
    return out.body.trim().length > 0 ? out : null;
  }
  if (message.content === undefined || message.content === null
    || typeof message.content !== 'object' || Array.isArray(message.content)) return null;
  const record = message.content as Record<string, Object>;
  const text = record['text'];
  const thinking = record['thinking'];
  out.body = typeof text === 'string' ? text as string
    : typeof thinking === 'string' ? thinking as string : '';
  const duration = record['durationMs'];
  if (typeof duration === 'number' && Number.isFinite(duration)) out.durationMs = Math.max(0, duration);
  out.redacted = record['isRedacted'] === true;
  if (!out.redacted && out.body.trim().length === 0 && out.durationMs <= 0) return null;
  let finishedAtMs = 0;
  const finishedAt = record['finishedAt'];
  if (typeof finishedAt === 'number' && Number.isFinite(finishedAt)) finishedAtMs = finishedAt;
  else if (typeof finishedAt === 'string') finishedAtMs = Date.parse(finishedAt as string);
  if (!Number.isFinite(finishedAtMs) || finishedAtMs <= 0) finishedAtMs = Date.parse(message.createdAt);
  if (out.durationMs >= 0 && Number.isFinite(finishedAtMs) && finishedAtMs > 0) {
    out.startedAt = new Date(Math.max(0, finishedAtMs - out.durationMs)).toISOString();
  }
  return out;
}

export function turnFinalAssistantIds(
  messages: RemoteMessage[],
  isSessionStreaming: boolean,
): Set<string> {
  const result = new Set<string>();
  const suppressTailFinalAssistant = isSessionStreaming && hasActiveLoadedTail(messages);
  let candidate = '';
  let sealedAnswerFound = false;
  for (let i = 0; i < messages.length; i++) {
    const message = messages[i];
    if (isTurnUserBoundary(message)) {
      if (!sealedAnswerFound && candidate.length > 0) result.add(candidate);
      candidate = '';
      sealedAnswerFound = false;
      continue;
    }
    if (message.role !== 'assistant' || message.systemCardType.length > 0
      || readStr(message.agentMeta, 'parentUuid').length > 0
      || contentPreview(message.content).trim().length === 0) continue;
    candidate = message.id.length > 0 ? message.id : message.clientId;
    if (message.turnCompleted && candidate.length > 0) {
      result.add(candidate);
      sealedAnswerFound = true;
    }
  }
  if (!sealedAnswerFound && !suppressTailFinalAssistant && candidate.length > 0) result.add(candidate);
  return result;
}

/**
 * maker/session 的 running 可能先于新 user 行到达；必须看“已加载尾部”是否真的活动，
 * 否则上一轮已完成回答的操作行会在发送瞬间闪退。
 */
function hasActiveLoadedTail(messages: RemoteMessage[]): boolean {
  let lastUserIndex = -1;
  for (let i = messages.length - 1; i >= 0; i--) {
    if (isTurnUserBoundary(messages[i])) {
      lastUserIndex = i;
      break;
    }
  }
  const tailStart = lastUserIndex + 1;
  if (tailStart >= messages.length) return lastUserIndex >= 0;
  for (let i = tailStart; i < messages.length; i++) {
    if (messages[i].isStreaming) return true;
  }

  const settledUseIds = new Set<string>();
  for (let i = tailStart; i < messages.length; i++) {
    if (messages[i].role !== 'tool_result') continue;
    const useId = toolResultUseId(messages[i]);
    if (useId.length > 0) settledUseIds.add(useId);
  }
  for (let i = tailStart; i < messages.length; i++) {
    if (messages[i].role !== 'tool_use') continue;
    const useId = rawToolUseId(messages[i]);
    let settled = useId.length > 0 && settledUseIds.has(useId);
    if (!settled && i + 1 < messages.length && messages[i + 1].role === 'tool_result') {
      const adjacentUseId = toolResultUseId(messages[i + 1]);
      settled = useId.length === 0 || adjacentUseId.length === 0 || adjacentUseId === useId;
    }
    if (settled) continue;
    let answeredAfter = false;
    for (let j = i + 1; j < messages.length; j++) {
      if (messages[j].role === 'assistant' && !messages[j].isStreaming
        && contentPreview(messages[j].content).trim().length > 0) {
        answeredAfter = true;
        break;
      }
    }
    if (!answeredAfter) return true;
  }

  // 本地 system card 可能追加在已完成回答之后；跳过它再判断真正的内容尾部。
  for (let i = messages.length - 1; i >= tailStart; i--) {
    const message = messages[i];
    if (message.role === 'system' || message.systemCardType.length > 0) continue;
    return message.role !== 'assistant' || contentPreview(message.content).trim().length === 0;
  }
  return false;
}

function isTurnUserBoundary(message: RemoteMessage): boolean {
  return message.role === 'user' && message.systemCardType.length === 0
    && !message.isSyntheticTrigger && !message.presentedAsAgent;
}

/** 计划归属只把用户真正开启的新一轮视作边界；续跑、Hook、steer 与子代理行都属于原轮。 */
function isPlanUserBoundary(message: RemoteMessage): boolean {
  return message.role === 'user' && !isSyntheticPlanRow(message);
}

function isSyntheticPlanRow(message: RemoteMessage): boolean {
  return message.isSyntheticTrigger || message.presentedAsAgent || message.automationOrigin
    || readStr(message.agentMeta, 'delivery') === 'steer'
    || Object.keys(readObj(message.agentMeta, 'hookSource')).length > 0
    || hasSubagentPlanOwner(message);
}

/** 旧转录也把普通链边放进 parentUuid；只认 SDK/tool-use id 形态，避免误伤历史顶层计划。 */
function hasSubagentPlanOwner(message: RemoteMessage): boolean {
  const explicit = readStr(message.agentMeta, 'parentToolUseId')
    || readStr(message.agentMeta, 'parent_tool_use_id');
  if (explicit.length > 0) {
    return !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(explicit.trim());
  }
  const parent = readStr(message.agentMeta, 'parentUuid').trim();
  return /^(?:toolu|call)[_-]/iu.test(parent)
    || /^[A-Za-z][A-Za-z0-9_-]*_x*\d+(?:_dup\d+)?$/u.test(parent);
}

/** 单个工具调用（含配对结果）。 */
export class RenderToolItem {
  seq: number = 0;
  toolUseId: string = '';
  toolName: string = '';
  /** 完整 input JSON（todo/plan 解析用）。 */
  inputRaw: string = '';
  /** input 摘要（JSON 或文本）。 */
  inputText: string = '';
  /** 配对 result 的预览文本；空 = 未到达（running）。 */
  resultText: string = '';
  hasResult: boolean = false;
  /** result 明确表示失败；settled 不等于成功。 */
  hasError: boolean = false;
  /** 精确 tool_result 的落库时间；邻接兜底不伪造结束时间。 */
  settledAt: string = '';
  /** 配对 tool_result 中可直接展示的托管图片。 */
  media: RemoteImageRef[] = [];
  /** 视频、音频和图片的统一媒体描述；images 字段继续保留兼容旧视图。 */
  richMedia: RenderMediaPayload[] = [];
  /** Edit / MultiEdit / Write 的结构化变更预览。 */
  diff: RenderDiffPayload | null = null;
  /** 调用发起时间 ISO（work_group 时长计算用）。 */
  createdAt: string = '';
}

/** 连续工具调用聚合块。 */
export class RenderToolGroupItem extends RenderItem {
  tools: RenderToolItem[] = [];
}

/** 工具产出的独立图片媒体项；与 tool_group 分离，避免生成结果被折叠。 */
export class RenderToolMediaItem extends RenderItem {
  tools: RenderToolItem[] = [];
  images: RemoteImageRef[] = [];
  media: RenderMediaPayload[] = [];
}

/** Task / Agent / subagent / collab:* 的独立任务卡。 */
export class RenderAgentTaskItem extends RenderItem {
  tool: RenderToolItem | null = null;
  update: AgentTaskUpdate | null = null;
  createdAt: string = '';
}

/** Claude Agent parentUuid 递归组；最大五层，异常桶回退平铺。 */
export class RenderSubagentGroupItem extends RenderItem {
  children: RenderItem[] = [];
  description: string = '';
  subagentType: string = '';
  summary: string = '';
  status: string = 'completed';
  durationMs: number = -1;
  update: AgentTaskUpdate | null = null;
}

export class RenderTodoItem {
  seq: number = 0;
  content: string = '';
  status: string = 'pending'; // 'pending' | 'in_progress' | 'completed'
}

/** 计划/待办卡。 */
export class RenderTodoCardItem extends RenderItem {
  todos: RenderTodoItem[] = [];
  /** 仅当前活动 turn 的计划为 true；历史遗留 in_progress 不应持续旋转。 */
  isStreaming: boolean = false;
}

/** 状态变化不进入签名；计划正文相同的快照可复用同一交互状态。 */
export function todoCardContentSignature(item: RenderTodoCardItem): string {
  const parts: string[] = [`${item.todos.length}`];
  for (let i = 0; i < item.todos.length; i++) parts.push(item.todos[i].content.trim());
  return parts.join('\u001f');
}

/** 同签名卡片从列表尾部数的相对序号；prepend 更早轮次后保持不变。 */
export function todoCardRankFromTail(
  cards: RenderTodoCardItem[],
  targetKey: string,
): number {
  let signature = '';
  for (let i = 0; i < cards.length; i++) {
    if (cards[i].key === targetKey) {
      signature = todoCardContentSignature(cards[i]);
      break;
    }
  }
  if (signature.length === 0) return 0;
  let rank = 0;
  for (let i = cards.length - 1; i >= 0; i--) {
    if (todoCardContentSignature(cards[i]) !== signature) continue;
    if (cards[i].key === targetKey) return rank;
    rank += 1;
  }
  return 0;
}

/** 在新列表中找到相同签名、相同尾部相对序号的卡片。 */
export function todoCardIndexAtRankFromTail(
  cards: RenderTodoCardItem[],
  signature: string,
  rank: number,
): number {
  let currentRank = 0;
  for (let i = cards.length - 1; i >= 0; i--) {
    if (todoCardContentSignature(cards[i]) !== signature) continue;
    if (currentRank === rank) return i;
    currentRank += 1;
  }
  return -1;
}

/** 工作过程聚合块（thinking / tool_group / todo 收进折叠面板，对齐 iOS work_group）。 */
export class RenderWorkGroupItem extends RenderItem {
  children: RenderItem[] = [];
  /** 工作过程时长 ms；-1 表示无法从历史时间戳计算。 */
  durationMs: number = -1;
  /** 首条真实活动的 Epoch ms；活动中的工作组用它驱动实时计时。 */
  startedAtMs: number = -1;
  /** 是否属于流式中的活动段（决定收起态是否显示活动预览）。 */
  isStreaming: boolean = false;
}

// ─── 工具函数 ────────────────────────────────────────────────────────────────

/** content → 预览文本（对齐 messageContentToPreview）。 */
export function contentPreview(content: Object | undefined): string {
  if (content === undefined) {
    return '';
  }
  if (typeof content === 'string') {
    return content;
  }
  if (Array.isArray(content)) {
    const parts: string[] = [];
    const list: Object[] = content as Object[];
    for (let i = 0; i < list.length; i++) {
      const p = contentPreview(list[i]);
      if (p.length > 0) {
        parts.push(p);
      }
    }
    return parts.join('\n');
  }
  if (typeof content === 'object') {
    const record = content as Record<string, Object>;
    const kind = readStr(record, 'kind');
    const type = readStr(record, 'type');
    if (kind === 'thinking' || type === 'thinking') {
      // 落库格式 { kind:'thinking', text, durationMs } 或 SDK 格式 { type:'thinking', thinking }。
      const text = readStr(record, 'text');
      if (text.length > 0) return text;
      const thinking = readStr(record, 'thinking');
      if (thinking.length > 0) return thinking;
      return '';
    }
    if (type === 'text') {
      const text = readStr(record, 'text');
      if (text.length > 0) return text;
    }
    const text = readStr(record, 'text');
    if (text.length > 0) return text;
    const inner = readStr(record, 'content');
    if (inner.length > 0) return inner;
    return JSON.stringify(content);
  }
  return '';
}

/** 解析结果：tool_use 消息的结构化提取。 */
export class ToolUseInfo {
  toolUseId: string = '';
  toolName: string = '';
  /** 完整 input JSON（todo/plan 解析用，不截断）。 */
  inputRaw: string = '';
  /** 摘要（仅显示用）。 */
  inputText: string = '';
}

/** 解析 tool_use 消息。 */
export function parseToolUse(message: RemoteMessage): ToolUseInfo {
  const content = message.content;
  const info = new ToolUseInfo();
  info.toolUseId = message.toolUseId;
  let input: Object | undefined = undefined;
  if (content !== undefined && typeof content === 'object' && !Array.isArray(content)) {
    const record = content as Record<string, Object>;
    if (info.toolUseId.length === 0) {
      info.toolUseId = readStr(record, 'toolUseId');
    }
    info.toolName = readStr(record, 'toolName');
    input = readAny(record, 'input');
  }
  // 兼容旧 Harmony live projection 把 input 预先 JSON.stringify 后再塞回 content
  // 的双重编码。结构化字段恢复后，人话摘要才能读取 description/commandActions。
  if (typeof input === 'string') {
    const encoded = (input as string).trim();
    if (encoded.length > 0) {
      try {
        input = JSON.parse(encoded) as Object;
      } catch (e) {
        // 第三方工具确实可能使用字符串 input；保持原值走通用回退。
      }
    }
  }
  if (input !== undefined) {
    info.inputRaw = JSON.stringify(input);
  }
  info.inputText = input === undefined ? '' : summarizeJson(input);
  return info;
}

/** 解析 tool_result 消息，返回其归属的 toolUseId（无则空）。 */
export function toolResultUseId(message: RemoteMessage): string {
  if (message.toolUseId.length > 0) {
    return message.toolUseId;
  }
  const content = message.content;
  if (content !== undefined && typeof content === 'object' && !Array.isArray(content)) {
    const record = content as Record<string, Object>;
    const inner = readStr(record, 'toolUseId');
    if (inner.length > 0) {
      return inner;
    }
  }
  return '';
}

function isContentOutputToolName(toolName: string): boolean {
  const normalized = toolName.toLowerCase();
  return normalized === 'read' || normalized === 'glob' || normalized === 'grep'
    || normalized === 'search' || normalized === 'webfetch' || normalized === 'websearch'
    || normalized === 'file_read' || normalized === 'read_file' || normalized === 'list_files';
}

export function toolResultHasError(message: RemoteMessage, toolName: string = ''): boolean {
  const content = message.content;
  if (content !== undefined && typeof content === 'object' && !Array.isArray(content)) {
    const record = content as Record<string, Object>;
    if (record['isError'] === true || record['is_error'] === true) return true;
  }
  const text = contentPreview(content).trim();
  if (text.length === 0) return false;
  if (text.includes('<tool_use_error>')) return true;
  if (isContentOutputToolName(toolName)) {
    const firstLine = text.split('\n')[0].trim();
    return /^(error\b|request failed\b|failed to \S|enoent\b|eacces\b|permission denied\b|错误[：:]|(读取|搜索|请求|抓取)失败|无法(读取|访问|打开|获取))/i
      .test(firstLine);
  }
  const firstLine = text.split('\n')[0].trim();
  return /^(error\b|failed\b|failure\b|exception\b|traceback\b|stderr\b|request failed\b|permission denied\b|错误[：:]|失败[：:]|异常[：:]|拒绝[：:]|超时[：:])/i
    .test(firstLine)
    || /\b(exit code [1-9]|non-zero exit|traceback \(most recent call last\)|permission denied|timed out)\b/i
      .test(text);
}

/** 连续工具内部也要按历史空洞切组，不能等到遇到非工具消息才 flush。 */
export function shouldSplitToolGroup(previousEndAt: string, nextCreatedAt: string): boolean {
  const previous = Date.parse(previousEndAt);
  const next = Date.parse(nextCreatedAt);
  return Number.isFinite(previous) && Number.isFinite(next)
    && next - previous > 30 * 60 * 1000;
}

/** 从 tool_result JSON 提取生成图片；只接受 Desktop 媒体托管 scheme。 */
function extractToolResultImages(content: string): RemoteImageRef[] {
  if (content.length === 0
    || (!content.includes('xdt_image_url') && !content.includes('xdt_media_produced'))) {
    return [];
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(content) as Object;
  } catch (e) {
    return [];
  }
  if (parsed === undefined || parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return [];
  }
  const record = parsed as Record<string, Object>;
  if (record['_xdt_render_image'] === false) return [];
  const out: RemoteImageRef[] = [];
  const seen = new Set<string>();
  const push = (url: string, title: string = ''): void => {
    if ((!url.startsWith('xdt-image://') && !url.startsWith('cindy-media://'))
      || seen.has(url)) return;
    seen.add(url);
    const ref = new RemoteImageRef();
    ref.url = url;
    ref.originalName = title;
    out.push(ref);
  };
  const single = record['xdt_image_url'];
  if (typeof single === 'string') push(single);
  const many = record['xdt_image_urls'];
  if (Array.isArray(many)) {
    const list: Object[] = many as Object[];
    for (let i = 0; i < list.length; i++) {
      if (typeof list[i] === 'string') push(list[i] as string);
    }
  }
  const produced = record['xdt_media_produced'];
  if (Array.isArray(produced)) {
    const list: Object[] = produced as Object[];
    for (let i = 0; i < list.length; i++) {
      const raw = list[i];
      if (typeof raw === 'string') {
        push(raw as string);
      } else if (raw !== undefined && typeof raw === 'object' && !Array.isArray(raw)) {
        const media = raw as Record<string, Object>;
        const url = readStr(media, 'url').length > 0
          ? readStr(media, 'url')
          : readStr(media, 'xdt_image_url');
        push(url, readStr(media, 'title'));
      }
    }
  }
  return out;
}

/** 判断工具调用是否是 todo 载体（TodoWrite / update_plan / Task*）。 */
export function isPlanTool(toolName: string): boolean {
  return toolName === 'TodoWrite'
    || toolName === 'update_plan'
    || toolName === 'TaskCreate'
    || toolName === 'TaskUpdate'
    || toolName === 'TaskList'
    || toolName === 'TaskGet';
}

/** 从 tool input 提取 todos（对齐 extractTodos / extractPlanTodos 的语义子集）。 */
export function extractTodos(toolName: string, inputText: string): RenderTodoItem[] | null {
  let parsed: Object | undefined;
  try {
    parsed = JSON.parse(inputText) as Object;
  } catch (e) {
    return null;
  }
  if (parsed === undefined || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return null;
  }
  const input = parsed as Record<string, Object>;
  const todos = input['todos'];
  if (Array.isArray(todos)) {
    return parseStructuredTodos(todos as Object[]);
  }
  // Codex update_plan 的结构化形态：新版本使用 plan，部分版本使用 items。
  // 之前 Harmony 只认 TodoWrite.todos / update_plan.text，导致 iOS/Desktop
  // 能看到的“2/3 · …”步骤卡在这里被静默丢掉。
  const structured = input['items'];
  if (Array.isArray(structured)) {
    return parseStructuredTodos(structured as Object[]);
  }
  const plan = input['plan'];
  if (Array.isArray(plan)) {
    return parseStructuredTodos(plan as Object[]);
  }
  // update_plan 的 text 形态（按行拆 pending 列表）。
  if (toolName === 'update_plan') {
    const text = readStr(input, 'text');
    if (text.trim().length === 0) {
      return null;
    }
    const lines = text.split('\n');
    const out: RenderTodoItem[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const todo = new RenderTodoItem();
      todo.content = line
        .replace(/^\s*[-*•\d.)\s]+/, '')
        .replace(/^\s*\[[ xX-]\]\s+/, '');
      todo.status = i === 0 ? 'in_progress' : 'pending';
      out.push(todo);
    }
    return out.length > 0 ? out : null;
  }
  return null;
}

/** 解析 update_plan.items / update_plan.plan 的结构化步骤。 */
function parseStructuredTodos(list: Object[]): RenderTodoItem[] | null {
  const out: RenderTodoItem[] = [];
  for (let i = 0; i < list.length; i++) {
    const item = list[i];
    if (item === undefined || item === null || typeof item !== 'object' || Array.isArray(item)) {
      continue;
    }
    const record = item as Record<string, Object>;
    const todo = new RenderTodoItem();
    const rawStatus = readStr(record, 'status');
    if (rawStatus === 'completed' || rawStatus === 'pending') {
      todo.status = rawStatus;
    } else if (rawStatus === 'in_progress' || rawStatus === 'inProgress' || rawStatus === 'running') {
      todo.status = 'in_progress';
    } else {
      todo.status = 'pending';
    }
    todo.content = firstTodoText(record, 'content');
    if (todo.content.length === 0) todo.content = firstTodoText(record, 'text');
    if (todo.content.length === 0) todo.content = firstTodoText(record, 'step');
    if (todo.content.length === 0) todo.content = firstTodoText(record, 'title');
    if (todo.content.length > 0) out.push(todo);
  }
  return out.length > 0 ? out : null;
}

function firstTodoText(record: Record<string, Object>, key: string): string {
  const value = record[key];
  return typeof value === 'string' ? value.trim() : '';
}

export class TodoPlanInsertion {
  key: string = '';
  todos: RenderTodoItem[] = [];
}

class TodoPlanSession {
  todos: RenderTodoItem[] = [];
  firstIndex: number = -1;
  lastIndex: number = -1;
  source: string = '';
}

function planSource(toolName: string): string {
  if (toolName === 'TodoWrite') return 'todo';
  if (toolName === 'update_plan') return 'codex';
  if (toolName === 'TaskCreate' || toolName === 'TaskUpdate'
    || toolName === 'TaskList' || toolName === 'TaskGet') return 'task';
  return '';
}

function planMessageKey(message: RemoteMessage, index: number): string {
  if (message.clientId.length > 0) return message.clientId;
  if (message.id.length > 0) return message.id;
  if (message.toolUseId.length > 0) return message.toolUseId;
  return `${message.createdAt}-${index}`;
}

export function planRowSealed(message: RemoteMessage | undefined): boolean {
  if (message === undefined) return false;
  if (message.terminalPlanSnapshot) return true;
  let content: Record<string, Object> = {};
  if (message.content !== undefined && typeof message.content === 'object'
    && !Array.isArray(message.content)) content = message.content as Record<string, Object>;
  return content['terminalPlanSnapshot'] === true;
}

export function planRowTurnFailed(message: RemoteMessage | undefined): boolean {
  if (message === undefined) return false;
  if (message.hasTurnCompleted && !message.turnCompleted) return true;
  let content: Record<string, Object> = {};
  if (message.content !== undefined && typeof message.content === 'object'
    && !Array.isArray(message.content)) content = message.content as Record<string, Object>;
  return content['turnCompleted'] === false;
}

/** Codex done 的权威计划快照与终态印记；取消优先于 completed。 */
export function applyCodexPlanSnapshotOnDone(
  messages: RemoteMessage[],
  snapshot: Object | undefined,
  turnId: string,
  terminalStatus: string,
  planUpdatedAtMs: number,
  cancelled: boolean,
): boolean {
  const authoritative = Array.isArray(snapshot) ? snapshot as Object[] : null;
  const success = terminalStatus === 'completed' && !cancelled;
  const expectedUseId = turnId.length > 0 ? `plan:${turnId}` : '';
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    if (message.role !== 'tool_use') continue;
    const tool = parseToolUse(message);
    if (tool.toolName !== 'update_plan') continue;
    if (expectedUseId.length > 0 && tool.toolUseId !== expectedUseId) continue;
    if (message.content === undefined || typeof message.content !== 'object'
      || Array.isArray(message.content)) continue;
    const content = message.content as Record<string, Object>;
    const input = readObj(content, 'input');
    if (!Array.isArray(input['plan'])) continue;
    if (authoritative !== null) input['plan'] = authoritative;
    content['input'] = input;
    if (turnId.length > 0 && success) {
      message.terminalPlanSnapshot = true;
      content['terminalPlanSnapshot'] = true;
      if (planUpdatedAtMs > 0) {
        message.terminalPlanAtMs = planUpdatedAtMs;
        content['terminalPlanAtMs'] = planUpdatedAtMs;
      }
    } else if (turnId.length > 0) {
      message.hasTurnCompleted = true;
      message.turnCompleted = false;
      content['turnCompleted'] = false;
    }
    message.content = content;
    return true;
  }
  return false;
}

/** terminal error 无 done 时，只给当前 turn 内最近的 Codex 计划写失败印记。 */
export function markCodexPlanTurnFailed(messages: RemoteMessage[]): boolean {
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    if (isPlanUserBoundary(message)) return false;
    if (message.role !== 'tool_use') continue;
    const tool = parseToolUse(message);
    if (tool.toolName !== 'update_plan') continue;
    if (planRowSealed(message) || planRowTurnFailed(message)) return false;
    message.hasTurnCompleted = true;
    message.turnCompleted = false;
    if (message.content !== undefined && typeof message.content === 'object'
      && !Array.isArray(message.content)) {
      const content = message.content as Record<string, Object>;
      content['turnCompleted'] = false;
      message.content = content;
    }
    return true;
  }
  return false;
}

function taskRecord(value: Object | undefined): Record<string, Object> | null {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) return null;
  return value as Record<string, Object>;
}

function firstTaskString(record: Record<string, Object> | null, keys: string[]): string {
  if (record === null) return '';
  for (let i = 0; i < keys.length; i++) {
    const value = record[keys[i]];
    if (typeof value === 'string' && (value as string).trim().length > 0) return (value as string).trim();
  }
  return '';
}

function taskId(record: Record<string, Object> | null): string {
  return firstTaskString(record, ['taskId', 'task_id', 'id']);
}

function taskContent(record: Record<string, Object> | null): string {
  return firstTaskString(record,
    ['subject', 'content', 'description', 'activeForm', 'active_form', 'title', 'text']);
}

function normalizedTaskStatus(value: Object | undefined): string {
  if (typeof value !== 'string') return '';
  const status = (value as string).trim().toLowerCase();
  if (status === 'completed' || status === 'done' || status === 'success') return 'completed';
  if (status === 'in_progress' || status === 'inprogress' || status === 'running' || status === 'active') {
    return 'in_progress';
  }
  if (status === 'pending' || status === 'queued' || status === 'todo') return 'pending';
  if (status === 'deleted' || status === 'removed') return 'deleted';
  return '';
}

function parseTaskCreatedLine(line: string): Record<string, Object> | null {
  const match = /^Task\s+#([^\s]+)\s+created successfully:\s*(.+)$/i.exec(line.trim());
  if (match === null || match.length < 3) return null;
  const out: Record<string, Object> = {};
  out['id'] = match[1];
  out['status'] = 'pending';
  out['subject'] = match[2].trim();
  return out;
}

function parseTaskSnapshotLine(line: string): Record<string, Object> | null {
  const match = /^#([^\s]+)\s+\[([^\]]+)\]\s+(.+)$/.exec(line.trim());
  if (match === null || match.length < 4) return null;
  let subject = match[3].trim();
  const trailingMeta = subject.lastIndexOf(' [');
  if (trailingMeta > 0 && subject.endsWith(']')) subject = subject.slice(0, trailingMeta).trim();
  if (subject.length === 0) return null;
  const out: Record<string, Object> = {};
  out['id'] = match[1];
  out['status'] = match[2];
  out['subject'] = subject;
  return out;
}

function taskRecordsFromResult(resultText: string): Array<Record<string, Object>> {
  const out: Array<Record<string, Object>> = [];
  if (resultText.trim().length === 0) return out;
  try {
    const parsed = JSON.parse(resultText) as Object;
    const record = taskRecord(parsed);
    if (record !== null) {
      const tasks = record['tasks'];
      if (Array.isArray(tasks)) {
        const list = tasks as Object[];
        for (let i = 0; i < list.length; i++) {
          const task = taskRecord(list[i]);
          if (task !== null) out.push(task);
        }
        return out;
      }
      const one = taskRecord(record['task']);
      if (one !== null) return [one];
      if (taskId(record).length > 0 || taskContent(record).length > 0) return [record];
    }
  } catch (e) {
    // Claude Task 工具的旧结果是人类可读文本，继续按行解析。
  }
  const lines = resultText.replace(/\r\n/g, '\n').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const created = parseTaskCreatedLine(lines[i]);
    if (created !== null) {
      out.push(created);
      continue;
    }
    const snapshot = parseTaskSnapshotLine(lines[i]);
    if (snapshot !== null) out.push(snapshot);
  }
  return out;
}

function taskListResultIsAuthoritative(resultText: string): boolean {
  if (resultText.trim().length === 0) return false;
  try {
    const record = taskRecord(JSON.parse(resultText) as Object);
    return record !== null && Array.isArray(record['tasks']);
  } catch (e) {
    return false;
  }
}

function currentTaskTodos(taskState: Map<string, RenderTodoItem>): RenderTodoItem[] | null {
  const out: RenderTodoItem[] = [];
  taskState.forEach((todo: RenderTodoItem) => {
    if (todo.content.trim().length > 0) out.push(todo);
  });
  return out.length > 0 ? out : null;
}

function taskToolTargetsExistingTask(
  toolName: string,
  input: Record<string, Object> | null,
  resultText: string,
  taskState: Map<string, RenderTodoItem>,
): boolean {
  if (toolName === 'TaskCreate') return false;
  const resultTasks = taskRecordsFromResult(resultText);
  const directId = taskId(input);
  if (directId.length > 0 && taskState.has(directId)) return true;
  for (let i = 0; i < resultTasks.length; i++) {
    const id = taskId(resultTasks[i]);
    if (id.length > 0 && taskState.has(id)) return true;
  }
  return false;
}

function applyTaskPlanTool(
  taskState: Map<string, RenderTodoItem>,
  message: RemoteMessage,
  toolName: string,
  input: Record<string, Object> | null,
  resultText: string,
): RenderTodoItem[] | null {
  const resultTasks = taskRecordsFromResult(resultText);
  if (toolName === 'TaskList') {
    if (resultTasks.length === 0) {
      if (taskListResultIsAuthoritative(resultText)) {
        taskState.clear();
        return null;
      }
      return currentTaskTodos(taskState);
    }
    const previous = new Map<string, RenderTodoItem>(taskState);
    taskState.clear();
    for (let i = 0; i < resultTasks.length; i++) {
      const record = resultTasks[i];
      const id = taskId(record);
      if (id.length === 0) continue;
      const status = normalizedTaskStatus(record['status']);
      if (status === 'deleted') continue;
      const existing = previous.get(id);
      const content = taskContent(record) || existing?.content || '';
      if (content.length === 0) continue;
      const todo = new RenderTodoItem();
      todo.content = content;
      todo.status = status.length > 0 ? status : (existing?.status ?? 'pending');
      taskState.set(id, todo);
    }
    return currentTaskTodos(taskState);
  }

  const resultTask = resultTasks.length > 0 ? resultTasks[0] : null;
  if (toolName === 'TaskCreate') {
    const id = taskId(resultTask) || taskId(input)
      || `task-create:${message.toolUseId.length > 0 ? message.toolUseId : message.id}`;
    const content = taskContent(input) || taskContent(resultTask);
    if (content.length === 0) return currentTaskTodos(taskState);
    const status = resultTask === null ? '' : normalizedTaskStatus(resultTask['status']);
    const todo = new RenderTodoItem();
    todo.content = content;
    todo.status = status.length > 0 && status !== 'deleted' ? status : 'pending';
    taskState.set(id, todo);
    return currentTaskTodos(taskState);
  }

  const id = taskId(input) || taskId(resultTask);
  if (id.length === 0) return currentTaskTodos(taskState);
  const existing = taskState.get(id);
  const suppliedContent = taskContent(input) || taskContent(resultTask);
  // 分页窗口若缺少 TaskCreate，不能用 id-only 状态行伪造一张不完整计划卡。
  if (existing === undefined && suppliedContent.length === 0) return null;
  const rawStatus = input !== null && input['status'] !== undefined
    ? input['status'] : (resultTask === null ? undefined : resultTask['status']);
  const status = normalizedTaskStatus(rawStatus) || existing?.status || 'pending';
  if (status === 'deleted') {
    taskState.delete(id);
    return currentTaskTodos(taskState);
  }
  const todo = new RenderTodoItem();
  todo.content = suppliedContent || existing?.content || '';
  todo.status = status;
  if (todo.content.length > 0) taskState.set(id, todo);
  return currentTaskTodos(taskState);
}

/**
 * 按来源 + 完成态划分计划会话，并把卡片插到该会话最后一次更新的位置。
 * key 固定取首次 plan 调用，历史 prepend / 流式状态更新不会重置折叠态。
 */
export function findTodoPlanInsertions(messages: RemoteMessage[]): Map<number, TodoPlanInsertion> {
  const resultByUseId = new Map<string, string>();
  for (let i = 0; i < messages.length; i++) {
    const message = messages[i];
    if (message.role !== 'tool_result') continue;
    const useId = toolResultUseId(message);
    if (useId.length > 0) resultByUseId.set(useId, contentPreview(message.content));
  }

  const sessions: TodoPlanSession[] = [];
  const lastBySource = new Map<string, TodoPlanSession>();
  const taskState = new Map<string, RenderTodoItem>();
  let lastUserBoundaryIndex = -1;
  for (let i = 0; i < messages.length; i++) {
    const message = messages[i];
    if (message.role === 'user') {
      if (isPlanUserBoundary(message)) lastUserBoundaryIndex = i;
      continue;
    }
    if (hasSubagentPlanOwner(message)) continue;
    if (message.role !== 'tool_use') continue;
    const tool = parseToolUse(message);
    const source = planSource(tool.toolName);
    if (source.length === 0) continue;
    const resultText = resultByUseId.get(tool.toolUseId) ?? '';
    const previous = lastBySource.get(source);
    let previousAllDone = false;
    if (previous !== undefined && previous.todos.length > 0) {
      previousAllDone = true;
      for (let j = 0; j < previous.todos.length; j++) {
        if (previous.todos[j].status !== 'completed') {
          previousAllDone = false;
          break;
        }
      }
    }
    let input: Record<string, Object> | null = null;
    try {
      input = taskRecord(JSON.parse(tool.inputRaw) as Object);
    } catch (e) {
      input = null;
    }
    const continuesCompletedTask = source === 'task' && previousAllDone
      && taskToolTargetsExistingTask(tool.toolName, input, resultText, taskState);
    const previousSealed = previous !== undefined && planRowSealed(messages[previous.lastIndex]);
    const crossesUserBoundary = previous !== undefined
      && lastUserBoundaryIndex > previous.lastIndex
      && !(source === 'task'
        && taskToolTargetsExistingTask(tool.toolName, input, resultText, taskState));
    const startsNew = previous === undefined || previousSealed
      || crossesUserBoundary
      || (previousAllDone && !continuesCompletedTask);
    if (source === 'task' && startsNew) taskState.clear();
    const parsed = extractTodos(tool.toolName, tool.inputRaw)
      ?? (source === 'task'
        ? applyTaskPlanTool(taskState, message, tool.toolName, input, resultText) : null);
    if (parsed === null) continue;
    for (let j = 0; j < parsed.length; j++) parsed[j].seq = j;
    if (!startsNew && previous !== undefined) {
      previous.todos = parsed;
      previous.lastIndex = i;
    } else {
      const session = new TodoPlanSession();
      session.todos = parsed;
      session.firstIndex = i;
      session.lastIndex = i;
      session.source = source;
      sessions.push(session);
      lastBySource.set(source, session);
    }
  }

  const out = new Map<number, TodoPlanInsertion>();
  for (let i = 0; i < sessions.length; i++) {
    const session = sessions[i];
    const insertion = new TodoPlanInsertion();
    insertion.key = `todo-${planMessageKey(messages[session.firstIndex], session.firstIndex)}`;
    insertion.todos = session.todos;
    out.set(session.lastIndex, insertion);
  }
  return out;
}

/**
 * 当前分页窗口能否完整重建最新 Task* 计划。未看到真实用户边界、权威 TaskList，
 * 或出现找不到 TaskCreate 的状态更新时，先继续回填历史，避免显示残缺的“1/1”。
 */
export function latestTaskPlanWindowResolved(
  messages: RemoteMessage[],
  hasEarlierMessages: boolean,
): boolean {
  let latestTaskIndex = -1;
  let lastUserBoundaryIndex = -1;
  for (let i = 0; i < messages.length; i++) {
    if (isPlanUserBoundary(messages[i])) lastUserBoundaryIndex = i;
    if (messages[i].role !== 'tool_use' || hasSubagentPlanOwner(messages[i])) continue;
    if (planSource(parseToolUse(messages[i]).toolName) === 'task') latestTaskIndex = i;
  }
  if (latestTaskIndex < 0 || !hasEarlierMessages) return true;

  const resultByUseId = new Map<string, string>();
  for (let i = 0; i < messages.length; i++) {
    if (messages[i].role !== 'tool_result') continue;
    const useId = toolResultUseId(messages[i]);
    if (useId.length > 0) resultByUseId.set(useId, contentPreview(messages[i].content));
  }
  const knownTaskIds = new Set<string>();
  const unresolvedTaskIds = new Set<string>();
  let boundaryKnown = lastUserBoundaryIndex >= 0 && lastUserBoundaryIndex < latestTaskIndex;
  const start = boundaryKnown ? lastUserBoundaryIndex + 1 : 0;
  for (let i = start; i <= latestTaskIndex; i++) {
    const message = messages[i];
    if (message.role !== 'tool_use' || hasSubagentPlanOwner(message)) continue;
    const tool = parseToolUse(message);
    if (planSource(tool.toolName) !== 'task') continue;
    let input: Record<string, Object> | null = null;
    try {
      input = taskRecord(JSON.parse(tool.inputRaw) as Object);
    } catch (_err) {
      input = null;
    }
    const resultText = resultByUseId.get(tool.toolUseId) ?? '';
    const resultTasks = taskRecordsFromResult(resultText);
    if (tool.toolName === 'TaskList' && taskListResultIsAuthoritative(resultText)) {
      boundaryKnown = true;
      knownTaskIds.clear();
      unresolvedTaskIds.clear();
      for (let j = 0; j < resultTasks.length; j++) {
        const id = taskId(resultTasks[j]);
        if (id.length > 0) knownTaskIds.add(id);
      }
      continue;
    }
    const id = taskId(input) || (resultTasks.length > 0 ? taskId(resultTasks[0]) : '');
    if (tool.toolName === 'TaskCreate') {
      if (id.length > 0) {
        knownTaskIds.add(id);
        unresolvedTaskIds.delete(id);
      }
    } else if (id.length > 0 && !knownTaskIds.has(id)) {
      unresolvedTaskIds.add(id);
    }
  }
  return boundaryKnown && unresolvedTaskIds.size === 0;
}

function visibleTodoPlanInsertions(
  messages: RemoteMessage[],
  taskHistoryMayBeIncomplete: boolean,
): Map<number, TodoPlanInsertion> {
  const insertions = findTodoPlanInsertions(messages);
  if (latestTaskPlanWindowResolved(messages, taskHistoryMayBeIncomplete)) return insertions;
  // 只压住最新的残缺 Task 卡；Codex/TodoWrite 与更早已完整计划仍正常显示。
  let latestTaskInsertionIndex = -1;
  insertions.forEach((_insertion: TodoPlanInsertion, index: number) => {
    if (index < 0 || index >= messages.length || messages[index].role !== 'tool_use') return;
    if (planSource(parseToolUse(messages[index]).toolName) === 'task') {
      latestTaskInsertionIndex = Math.max(latestTaskInsertionIndex, index);
    }
  });
  if (latestTaskInsertionIndex >= 0) insertions.delete(latestTaskInsertionIndex);
  return insertions;
}

/** JSON 摘要（截断避免大 input 撑爆 UI）。 */
export function summarizeJson(value: Object | undefined, maxLen: number = 160): string {
  if (value === undefined) {
    return '';
  }
  let s: string;
  if (typeof value === 'string') {
    s = value;
  } else {
    s = JSON.stringify(value);
  }
  const single = s.replace(/[\r\n]+/g, ' ');
  return single.length > maxLen ? `${single.slice(0, maxLen)}…` : single;
}

/** 摘要文本（换行折叠 + 截断）。 */
export function summarizeText(text: string, maxLen: number = 200): string {
  const single = text.replace(/[\r\n]+/g, ' ');
  return single.length > maxLen ? `${single.slice(0, maxLen)}…` : single;
}

/** user 消息 content 解析结果。 */
export class ParsedUserContent {
  text: string = '';
  ranges: RenderPasteRange[] = [];
  images: RemoteImageRef[] = [];
  files: RemoteSerializedAttachment[] = [];
}

/**
 * 解析 user 消息 content：text + pastedTextRanges 粘贴区间。
 * 桌面端对含 pastedTextRanges 的 content 保留结构（capReferenceMessageRows
 * 的 contentHasOmittedData 分支），粘贴的消息一定是对象形态。
 */
function parseUserContent(content: Object | undefined): ParsedUserContent {
  const out = new ParsedUserContent();
  if (content === undefined) {
    return out;
  }
  if (typeof content === 'string') {
    out.text = content;
    return out;
  }
  if (typeof content === 'object' && !Array.isArray(content)) {
    const record = content as Record<string, Object>;
    out.text = readStr(record, 'text');
    if (out.text.length === 0) {
      out.text = readStr(record, 'content');
    }
    const rawRanges = record['pastedTextRanges'];
    if (Array.isArray(rawRanges)) {
      const list: Object[] = rawRanges as Object[];
      for (let i = 0; i < list.length; i++) {
        const r = list[i];
        if (r === undefined || typeof r !== 'object' || Array.isArray(r)) {
          continue;
        }
        const rr = r as Record<string, Object>;
        const range = new RenderPasteRange();
        const start = rr['start'];
        const end = rr['end'];
        range.start = typeof start === 'number' ? start : 0;
        range.end = typeof end === 'number' ? end : 0;
        range.display = readStr(rr, 'display');
        out.ranges.push(range);
      }
    }
    const rawImages = record['images'];
    if (Array.isArray(rawImages)) {
      const list: Object[] = rawImages as Object[];
      for (let i = 0; i < list.length; i++) {
        const raw = list[i];
        if (raw === undefined || typeof raw !== 'object' || Array.isArray(raw)) {
          continue;
        }
        const rr = raw as Record<string, Object>;
        const ref = new RemoteImageRef();
        ref.url = readStr(rr, 'url');
        ref.base64 = readStr(rr, 'base64');
        ref.originalName = readStr(rr, 'originalName');
        ref.name = readStr(rr, 'name');
        if (ref.originalName.length === 0) ref.originalName = ref.name;
        ref.mimeType = readStr(rr, 'mimeType');
        if (ref.mimeType.length === 0) ref.mimeType = readStr(rr, 'type');
        const size = rr['size'];
        ref.size = typeof size === 'number' ? size : 0;
        ref.sha256 = readStr(rr, 'sha256');
        if (ref.url.length === 0 && ref.base64.length > 0) {
          const mimeType = ref.mimeType.length > 0 ? ref.mimeType : 'image/png';
          if (mimeType.toLowerCase().startsWith('image/')) {
            ref.url = `data:${mimeType};base64,${ref.base64}`;
          }
        }
        if (ref.url.length > 0) {
          out.images.push(ref);
        }
      }
    }
    out.files = parseMessageFiles(content);
  }
  return out;
}

/** 手打消息收起后保留的正文行数，对齐 mobile userMessageCollapse.ts。 */
export const LONG_USER_MESSAGE_COLLAPSED_LINES = 10;
/** 自动化消息收起后保留的正文行数。 */
export const AUTOMATION_USER_MESSAGE_COLLAPSED_LINES = 3;

export function collapsedUserMessageLineLimit(isAutomation: boolean): number {
  return isAutomation
    ? AUTOMATION_USER_MESSAGE_COLLAPSED_LINES
    : LONG_USER_MESSAGE_COLLAPSED_LINES;
}

/** 手打消息收起阈值（视觉行），对齐 mobile userMessageCollapse.ts。 */
const LONG_USER_MESSAGE_VISUAL_LINE_THRESHOLD = 14;
/** 自动化注入消息收起阈值。 */
const AUTOMATION_USER_MESSAGE_VISUAL_LINE_THRESHOLD = 4;
/** 每个视觉行约可容纳的半宽字符单位数（对齐 mobile 常量）。 */
const HALF_WIDTH_UNITS_PER_VISUAL_LINE = 34;

/** 全宽字符（CJK/假名/谚文/全宽标点），估算行宽用。 */
const WIDE_CHAR_RE = /[\u1100-\u115f\u2e80-\u303e\u3041-\u33ff\u3400-\u4dbf\u4e00-\u9fff\ua000-\ua4cf\uac00-\ud7a3\uf900-\ufaff\ufe30-\ufe4f\uff00-\uff60\uffe0-\uffe6]/g;

/** 估算单个逻辑行的视觉行数（全宽字符算 2 单位）。 */
function estimateVisualLineCount(line: string): number {
  if (line.length === 0) {
    return 1;
  }
  const matches = line.match(WIDE_CHAR_RE);
  const wideCount = matches === null ? 0 : matches.length;
  const units = line.length + wideCount;
  return Math.max(1, Math.ceil(units / HALF_WIDTH_UNITS_PER_VISUAL_LINE));
}

/**
 * 判断 user 消息正文是否超长需要折叠（对齐 mobile shouldAutoCollapseUserMessageContent）。
 * 视觉行数按纯文本估算（宽字符 + 换行），超过阈值即折叠成文本块。
 */
export function shouldAutoCollapseUserMessage(
  content: string,
  isAutomation: boolean,
): boolean {
  const trimmed = content.trim();
  if (trimmed.length === 0) {
    return false;
  }
  const threshold = isAutomation ? AUTOMATION_USER_MESSAGE_VISUAL_LINE_THRESHOLD : LONG_USER_MESSAGE_VISUAL_LINE_THRESHOLD;
  const lines = trimmed.split('\n');
  let visualLines = 0;
  for (let i = 0; i < lines.length; i++) {
    visualLines += estimateVisualLineCount(lines[i]);
    if (visualLines > threshold) {
      return true;
    }
  }
  return false;
}

/**
 * 把 user 消息正文切成渲染段：
 * - 有 pastedTextRanges：按区间切（手打段正常 / 粘贴段 chip）；
 * - 无粘贴标记但超长（14/4 视觉行）：整段折叠块；
 * - 否则：整段正常渲染。
 */
function buildSegments(text: string, ranges: RenderPasteRange[], isAutomation: boolean): RenderTextSegment[] {
  const out: RenderTextSegment[] = [];
  let seq = 0;
  const push = (segText: string, isPasted: boolean, display: string): void => {
    const seg = new RenderTextSegment();
    seg.seq = seq;
    seq += 1;
    seg.text = segText;
    seg.isPasted = isPasted;
    seg.display = display;
    seg.mdBlocks = parseMarkdown(segText);
    out.push(seg);
  };
  if (ranges.length > 0) {
    // 按 start 排序后切分
    const sorted = ranges.slice().sort((a: RenderPasteRange, b: RenderPasteRange) => a.start - b.start);
    let cursor = 0;
    for (let i = 0; i < sorted.length; i++) {
      const r = sorted[i];
      if (r.start > cursor) {
        push(text.slice(cursor, r.start), false, '');
      }
      const pasteEnd = Math.min(r.end, text.length);
      if (pasteEnd > r.start) {
        push(text.slice(r.start, pasteEnd), true, r.display);
      }
      cursor = Math.max(cursor, pasteEnd);
    }
    if (cursor < text.length) {
      push(text.slice(cursor), false, '');
    }
    return out;
  }
  push(text, shouldAutoCollapseUserMessage(text, isAutomation), '');
  return out;
}

// ─── 渲染项构建 ──────────────────────────────────────────────────────────────

function hasVisibleAutoResumeBoundary(message: RemoteMessage): boolean {
  if (message.systemCardType.length > 0) return true;
  if (message.isSyntheticTrigger || message.role === 'thinking') return false;
  if (message.role === 'tool_use' || message.role === 'tool_result') return true;
  let body = contentPreview(message.content);
  if (message.role === 'user') {
    const parsed = parseUserContent(message.content);
    if (parsed.images.length > 0 || parsed.files.length > 0) return true;
    body = parsed.text;
  }
  return body.replace(/[\s\u0000-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]/g, '')
    .length > 0;
}

/** 同一次中断只展示最新状态；旧行仍留在输入序列中作为 turn boundary。 */
export function collapseConsecutiveAutoResumeCards(messages: RemoteMessage[]): void {
  let hasNewerCard = false;
  for (let i = messages.length - 1; i >= 0; i--) {
    const message = messages[i];
    message.autoResumeHidden = false;
    if (message.systemCardType === 'auto-resume') {
      message.autoResumeHidden = hasNewerCard;
      hasNewerCard = true;
    } else if (hasVisibleAutoResumeBoundary(message)) {
      hasNewerCard = false;
    }
  }
}

/**
 * 把升序消息数组构建成渲染项列表。
 * 消息流结构：
 *   user/assistant → message 块
 *   thinking      → thinking 折叠块
 *   tool_use      → 进入 tool_group（pending，等 result）
 *   tool_result   → 配对到所属 tool_use（byId 优先，邻接兜底）
 *   TodoWrite/update_plan/Task* → 额外产出 todo 卡
 *   system/error/agent_switch → 系统消息块
 */
function buildLinearRenderItems(
  messages: RemoteMessage[],
  isSessionStreaming: boolean = false,
  taskUpdates: Map<string, AgentTaskUpdate> | undefined = undefined,
  renderOrphanTaskUpdates: boolean = false,
  continuationTurnClientId: string = '',
  continuationCapability: string = 'unknown',
  makerTurnRunning: boolean = false,
  lastUserInputClientId: string = '',
  taskHistoryMayBeIncomplete: boolean = false,
): RenderItem[] {
  const items: RenderItem[] = [];
  const errorTailClientId = findErrorTailClientId(messages);
  const finalAssistantIds = turnFinalAssistantIds(messages, isSessionStreaming);
  const todoInsertAt = visibleTodoPlanInsertions(messages, taskHistoryMayBeIncomplete);
  const renderedTaskKeys = new Set<string>();

  // 结果必须只作为 tool_use 的 secondary body 消费。之前把 tool_result 再建成一个
  // tool_group，导致同一条 Bash 在鸿蒙端出现两次，正是截图里“重复调用 bash”的来源。
  const toolNameByUseId = new Map<string, string>();
  const resultByUseId = new Map<string, string>();
  const resultAtByUseId = new Map<string, string>();
  const resultErrorByUseId = new Map<string, boolean>();
  const mediaByUseId = new Map<string, RemoteImageRef[]>();
  const richMediaByUseId = new Map<string, RenderMediaPayload[]>();
  const settledUseIds = new Set<string>();
  const adjacentResultByMessageId = new Map<string, string>();
  const adjacentMediaByMessageId = new Map<string, RemoteImageRef[]>();
  const adjacentRichMediaByMessageId = new Map<string, RenderMediaPayload[]>();
  const adjacentErrorMessageIds = new Set<string>();
  const adjacentSettledMessageIds = new Set<string>();
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    if (m.role === 'tool_use') {
      const tool = parseToolUse(m);
      if (tool.toolUseId.length > 0) {
        toolNameByUseId.set(tool.toolUseId, tool.toolName);
      }
    }
  }
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    if (m.role !== 'tool_result') continue;
    const useId = toolResultUseId(m);
    if (useId.length === 0) continue;
    settledUseIds.add(useId);
    resultAtByUseId.set(useId, m.createdAt);
    const fullResult = contentPreview(m.content);
    if (toolResultHasError(m, toolNameByUseId.get(useId) ?? '')) resultErrorByUseId.set(useId, true);
    const media = extractToolResultImages(fullResult);
    const richMedia = extractToolResultMedia(fullResult);
    if (media.length > 0) mediaByUseId.set(useId, media);
    if (richMedia.length > 0) richMediaByUseId.set(useId, richMedia);
    if (!shouldHideToolResult(toolNameByUseId.get(useId) ?? '', fullResult)) {
      resultByUseId.set(useId, fullResult);
    }
  }
  // 旧历史里仍有“tool_use 紧邻 tool_result、但 useId 没落在 result 行”的数据，
  // 只把正文做邻接兜底，不拿邻接时间冒充精确 settle 时间。
  for (let i = 0; i + 1 < messages.length; i++) {
    const use = messages[i];
    const result = messages[i + 1];
    if (use.role !== 'tool_use' || result.role !== 'tool_result') continue;
    const useInfo = parseToolUse(use);
    adjacentSettledMessageIds.add(use.id);
    if (toolResultHasError(result, useInfo.toolName)) adjacentErrorMessageIds.add(use.id);
    const fullResult = contentPreview(result.content);
    const media = extractToolResultImages(fullResult);
    const richMedia = extractToolResultMedia(fullResult);
    if (media.length > 0) adjacentMediaByMessageId.set(use.id, media);
    if (richMedia.length > 0) adjacentRichMediaByMessageId.set(use.id, richMedia);
    if (!shouldHideToolResult(useInfo.toolName, fullResult)) {
      adjacentResultByMessageId.set(use.id, fullResult);
    }
  }

  let pendingTools: RenderToolItem[] = [];
  let pendingToolEndAt = '';
  // 工具仍在流式追加时，必须保持 tool_group 的 key 不变，否则 ArkUI
  // 会把整组已有步骤当成新节点重建，表现为工作内容跳变/闪烁。
  let pendingFirstKey = '';
  const flushTools = (): void => {
    if (pendingTools.length === 0) return;
    const group = new RenderToolGroupItem();
    group.type = 'tool_group';
    group.key = pendingFirstKey.length > 0 ? pendingFirstKey : pendingTools[0].toolUseId;
    group.tools = pendingTools;
    items.push(group);
    const mediaTools: RenderToolItem[] = [];
    for (let i = 0; i < pendingTools.length; i++) {
      if (pendingTools[i].richMedia.length > 0 || pendingTools[i].media.length > 0) mediaTools.push(pendingTools[i]);
    }
    if (mediaTools.length > 0) {
      const media = new RenderToolMediaItem();
      media.type = 'tool_media';
      media.key = `media-${group.key}`;
      media.tools = mediaTools;
      const seenMedia = new Set<string>();
      for (let i = 0; i < mediaTools.length; i++) {
        for (let j = 0; j < mediaTools[i].media.length; j++) {
          const ref = mediaTools[i].media[j];
          if (seenMedia.has(ref.url)) continue;
          seenMedia.add(ref.url);
          media.images.push(ref);
        }
        for (let j = 0; j < mediaTools[i].richMedia.length; j++) {
          const payload = mediaTools[i].richMedia[j];
          if (seenMedia.has(payload.url)) continue;
          seenMedia.add(payload.url);
          media.media.push(payload);
        }
      }
      items.push(media);
    }
    pendingTools = [];
    pendingFirstKey = '';
    pendingToolEndAt = '';
  };

  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    const role = m.role;

    if (role === 'tool_use') {
      const tool = parseToolUse(m);
      if (isAgentTaskToolName(tool.toolName)) {
        flushTools();
        const task = new RenderToolItem();
        task.toolUseId = tool.toolUseId;
        task.toolName = tool.toolName;
        task.inputRaw = tool.inputRaw;
        task.inputText = tool.inputText;
        task.createdAt = m.createdAt;
        if (task.toolUseId.length > 0 && settledUseIds.has(task.toolUseId)) {
          task.resultText = resultByUseId.get(task.toolUseId) ?? '';
          task.hasResult = true;
          task.hasError = resultErrorByUseId.get(task.toolUseId) ?? false;
          task.settledAt = resultAtByUseId.get(task.toolUseId) ?? '';
        } else if (adjacentSettledMessageIds.has(m.id)) {
          task.resultText = adjacentResultByMessageId.get(m.id) ?? '';
          task.hasResult = true;
          task.hasError = adjacentErrorMessageIds.has(m.id);
        }
        const clientKey = m.clientId.length > 0 ? m.clientId : m.id;
        const update = findAgentTaskUpdate(taskUpdates, task.toolUseId, clientKey);
        const card = new RenderAgentTaskItem();
        card.type = 'agent_task';
        const linkKey = task.toolUseId.length > 0 ? task.toolUseId : clientKey;
        card.key = `task-${linkKey}`;
        card.tool = task;
        card.update = update ?? null;
        card.createdAt = m.createdAt;
        renderedTaskKeys.add(linkKey);
        if (update !== undefined) {
          renderedTaskKeys.add(update.taskId);
          if (update.parentToolUseId.length > 0) renderedTaskKeys.add(update.parentToolUseId);
        }
        items.push(card);
        continue;
      }
      if (isPlanTool(tool.toolName)) {
        const insertion = todoInsertAt.get(i);
        if (insertion !== undefined) {
          flushTools();
          const card = new RenderTodoCardItem();
          card.type = 'todo';
          card.key = insertion.key;
          card.todos = insertion.todos;
          // 活动态必须在 turn 分组完成后按最后一个已完成边界计算；这里只保留
          // 协议内容，避免旧历史里的 in_progress 计划被误判为当前执行中。
          card.isStreaming = false;
          items.push(card);
        }
        continue;
      }
      const item = new RenderToolItem();
      item.seq = pendingTools.length;
      item.toolUseId = tool.toolUseId;
      item.toolName = tool.toolName;
      item.inputRaw = tool.inputRaw;
      item.inputText = tool.inputText.length > 0 ? summarizeText(tool.inputText) : '';
      item.diff = buildToolDiff(tool.toolName, tool.inputRaw);
      if (item.toolUseId.length > 0 && settledUseIds.has(item.toolUseId)) {
        item.resultText = resultByUseId.get(item.toolUseId) ?? '';
        item.hasResult = true;
        item.hasError = resultErrorByUseId.get(item.toolUseId) ?? false;
        item.settledAt = resultAtByUseId.get(item.toolUseId) ?? '';
        item.media = mediaByUseId.get(item.toolUseId) ?? [];
        item.richMedia = richMediaByUseId.get(item.toolUseId) ?? [];
      } else if (adjacentSettledMessageIds.has(m.id)) {
        item.resultText = adjacentResultByMessageId.get(m.id) ?? '';
        item.hasResult = true;
        item.hasError = adjacentErrorMessageIds.has(m.id);
        item.media = adjacentMediaByMessageId.get(m.id) ?? [];
        item.richMedia = adjacentRichMediaByMessageId.get(m.id) ?? [];
      }
      item.createdAt = m.createdAt;
      if (pendingTools.length > 0 && shouldSplitToolGroup(pendingToolEndAt, item.createdAt)) {
        flushTools();
      }
      if (pendingTools.length === 0) pendingFirstKey = m.id;
      pendingTools.push(item);
      const itemEndAt = item.settledAt.length > 0 ? item.settledAt : item.createdAt;
      if (pendingToolEndAt.length === 0
        || Date.parse(itemEndAt) > Date.parse(pendingToolEndAt)) pendingToolEndAt = itemEndAt;
      continue;
    }

    if (pendingTools.length > 0) flushTools();
    // tool_result 已在上面的预扫描中配对，绝不能再单独产出一个可见工具行。
    if (role === 'tool_result') continue;

    if (role === 'thinking') {
      const presentation = parseThinkingPresentation(m);
      if (presentation === null) continue;
      const item = new RenderThinkingItem();
      item.type = 'thinking';
      item.key = m.id;
      item.body = presentation.body;
      item.durationMs = presentation.durationMs;
      item.redacted = presentation.redacted;
      item.createdAt = presentation.startedAt;
      item.mdBlocks = parseMarkdown(item.body);
      items.push(item);
      continue;
    }

    // systemCardType 是消息协议上的渲染边界，不是普通 user/assistant 正文。
    // 尤其 compact 在桌面端表现为“自动压缩”分隔条；如果按 role=user 走下去，
    // 鸿蒙会把它渲染成一条用户气泡，且会破坏前后 work_group 的边界。
    if (m.systemCardType.length > 0) {
      const item = new RenderMessageItem();
      item.type = 'message';
      item.key = m.id;
      item.kind = m.systemCardType === 'auto-resume' ? 'user' : 'system';
      item.label = `system:${m.systemCardType}`;
      item.body = '';
      item.mdBlocks = [];
      item.message = m;
      item.hidden = m.autoResumeHidden;
      if (m.systemCardType === 'auto-resume') {
        const clientId = m.clientId.length > 0 ? m.clientId : m.id;
        item.autoResumeInFlight = isAutoResumeRowInFlight(
          clientId,
          continuationTurnClientId,
          continuationCapability,
          makerTurnRunning,
          clientId.length > 0 && clientId === lastUserInputClientId,
        );
      }
      items.push(item);
      continue;
    }

    if (role === 'user') {
      const item = new RenderMessageItem();
      item.type = 'message';
      item.key = m.id;
      if (m.isSyntheticTrigger) {
        item.kind = 'user';
        item.label = '你';
        item.body = '';
        item.message = m;
        item.hidden = true;
        items.push(item);
        continue;
      }
      if (m.presentedAsAgent) {
        item.kind = 'system';
        item.label = m.originLabel.length > 0 ? m.originLabel : 'Cindy';
        item.body = m.originBody;
        item.mdBlocks = parseMarkdown(item.body);
        item.message = m;
        items.push(item);
        continue;
      }
      item.kind = 'user';
      item.label = '你';
      const parsed = parseUserContent(m.content);
      item.body = parsed.text;
      item.segments = buildSegments(parsed.text, parsed.ranges, m.automationOrigin);
      item.mdBlocks = item.segments.length > 0 ? item.segments[0].mdBlocks : parseMarkdown(item.body);
      item.images = parsed.images;
      item.files = parsed.files;
      item.message = m;
      items.push(item);
      continue;
    }

    const item = new RenderMessageItem();
    item.type = 'message';
    item.key = m.id;
    item.kind = normalizeKind(role);
    item.label = labelOf(role);
    item.body = contentPreview(m.content);
    // 空的 assistant 是协议占位，不应在真实答复下方制造一条空消息。
    if (item.kind === 'assistant' && item.body.trim().length === 0) continue;
    item.mdBlocks = parseMarkdown(item.body);
    item.message = m;
    if (item.kind === 'assistant') {
      const identity = m.id.length > 0 ? m.id : m.clientId;
      item.isTurnFinalAssistant = identity.length > 0 && finalAssistantIds.has(identity);
    }
    if (item.kind === 'error' && errorTailClientId.length > 0
      && (m.clientId === errorTailClientId || m.id === errorTailClientId)) item.hidden = true;
    items.push(item);
  }
  flushTools();
  if (renderOrphanTaskUpdates && taskUpdates !== undefined) {
    const seen = new Set<string>();
    taskUpdates.forEach((update: AgentTaskUpdate) => {
      const primaryKey = update.parentToolUseId.length > 0 ? update.parentToolUseId : update.taskId;
      if (seen.has(update.taskId) || renderedTaskKeys.has(primaryKey) || renderedTaskKeys.has(update.taskId)) return;
      seen.add(update.taskId);
      const card = new RenderAgentTaskItem();
      card.type = 'agent_task';
      card.key = `task-update-${primaryKey}`;
      card.update = update;
      card.createdAt = update.updatedAt.length > 0 ? update.updatedAt : update.createdAt;
      items.push(card);
    });
  }
  scopeUnsettledToolsToActiveTail(items);
  return groupMessageWorkRuns(items, isSessionStreaming);
}

const MAX_SUBAGENT_NEST_DEPTH = 5;

class SubagentResultMeta {
  createdAtMs: number = 0;
  summary: string = '';
}

/**
 * 五层 parentUuid 递归分组。父 Agent 不在当前分页窗口、超深、环和未消费桶
 * 一律回退平铺；每条原始消息只进入一个线性构建窗口。
 */
export function buildRenderItems(
  messages: RemoteMessage[],
  isSessionStreaming: boolean = false,
  taskUpdates: Map<string, AgentTaskUpdate> | undefined = undefined,
  renderOrphanTaskUpdates: boolean = false,
  continuationTurnClientId: string = '',
  continuationCapability: string = 'unknown',
  makerTurnRunning: boolean = false,
  taskHistoryMayBeIncomplete: boolean = false,
): RenderItem[] {
  collapseConsecutiveAutoResumeCards(messages);
  let lastUserInputClientId = '';
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role !== 'user' || readStr(messages[i].agentMeta, 'delivery') === 'steer') continue;
    lastUserInputClientId = messages[i].clientId.length > 0 ? messages[i].clientId : messages[i].id;
    break;
  }
  const presentAgentIds = new Set<string>();
  let hasAgent = false;
  for (let i = 0; i < messages.length; i++) {
    if (!isRawAgentToolUse(messages[i])) continue;
    hasAgent = true;
    const id = rawToolUseId(messages[i]);
    if (id.length > 0) presentAgentIds.add(id);
  }
  if (!hasAgent) {
    return buildLinearRenderItems(
      messages, isSessionStreaming, taskUpdates, renderOrphanTaskUpdates,
      continuationTurnClientId, continuationCapability, makerTurnRunning, lastUserInputClientId,
      taskHistoryMayBeIncomplete);
  }

  const byParent = new Map<string, RemoteMessage[]>();
  const topLevel: RemoteMessage[] = [];
  for (let i = 0; i < messages.length; i++) {
    const parent = readStr(messages[i].agentMeta, 'parentUuid');
    if (parent.length > 0 && presentAgentIds.has(parent)) {
      const bucket = byParent.get(parent) ?? [];
      bucket.push(messages[i]);
      byParent.set(parent, bucket);
    } else {
      topLevel.push(messages[i]);
    }
  }
  byParent.forEach((bucket: RemoteMessage[]) => bucket.sort(compareRemoteMessages));
  const resultMeta = buildSubagentResultMeta(messages);
  const consumed = new Set<string>();
  const out = buildSubagentLevel(
    topLevel, byParent, resultMeta, isSessionStreaming, taskUpdates, 0, consumed,
    continuationTurnClientId, continuationCapability, makerTurnRunning, lastUserInputClientId,
    taskHistoryMayBeIncomplete);

  const leftover: RemoteMessage[] = [];
  byParent.forEach((bucket: RemoteMessage[], parent: string) => {
    if (!consumed.has(parent)) for (let i = 0; i < bucket.length; i++) leftover.push(bucket[i]);
  });
  if (leftover.length > 0) {
    leftover.sort(compareRemoteMessages);
    const flat = buildLinearRenderItems(
      leftover, isSessionStreaming, taskUpdates, false,
      continuationTurnClientId, continuationCapability, makerTurnRunning, lastUserInputClientId,
      false);
    for (let i = 0; i < flat.length; i++) out.push(flat[i]);
  }
  if (renderOrphanTaskUpdates && taskUpdates !== undefined) {
    appendUnrenderedTaskUpdates(out, taskUpdates);
  }
  return out;
}

function rawToolUseId(message: RemoteMessage): string {
  const direct = message.toolUseId;
  if (direct.length > 0) return direct;
  if (message.content !== undefined && typeof message.content === 'object' && !Array.isArray(message.content)) {
    return readStr(message.content as Record<string, Object>, 'toolUseId');
  }
  return '';
}

function isRawAgentToolUse(message: RemoteMessage): boolean {
  return message.role === 'tool_use' && parseToolUse(message).toolName === 'Agent';
}

function compareRemoteMessages(left: RemoteMessage, right: RemoteMessage): number {
  const byTime = left.createdAt.localeCompare(right.createdAt);
  if (byTime !== 0) return byTime;
  const leftKey = left.id.length > 0 ? left.id : left.clientId;
  const rightKey = right.id.length > 0 ? right.id : right.clientId;
  return leftKey.localeCompare(rightKey);
}

function buildSubagentResultMeta(messages: RemoteMessage[]): Map<string, SubagentResultMeta> {
  const out = new Map<string, SubagentResultMeta>();
  for (let i = 0; i < messages.length; i++) {
    if (messages[i].role !== 'tool_result') continue;
    const id = toolResultUseId(messages[i]);
    if (id.length === 0) continue;
    const item = new SubagentResultMeta();
    const timestamp = Date.parse(messages[i].createdAt);
    item.createdAtMs = Number.isFinite(timestamp) ? timestamp : 0;
    item.summary = contentPreview(messages[i].content);
    out.set(id, item);
  }
  return out;
}

function buildSubagentLevel(
  level: RemoteMessage[],
  byParent: Map<string, RemoteMessage[]>,
  resultMeta: Map<string, SubagentResultMeta>,
  streaming: boolean,
  taskUpdates: Map<string, AgentTaskUpdate> | undefined,
  depth: number,
  consumed: Set<string>,
  continuationTurnClientId: string,
  continuationCapability: string,
  makerTurnRunning: boolean,
  lastUserInputClientId: string,
  taskHistoryMayBeIncomplete: boolean,
): RenderItem[] {
  const out: RenderItem[] = [];
  let run: RemoteMessage[] = [];
  const flushRun = (): void => {
    if (run.length === 0) return;
    const built = buildLinearRenderItems(
      run, streaming, taskUpdates, false,
      continuationTurnClientId, continuationCapability, makerTurnRunning, lastUserInputClientId,
      taskHistoryMayBeIncomplete);
    for (let i = 0; i < built.length; i++) out.push(built[i]);
    run = [];
  };
  for (let i = 0; i < level.length; i++) {
    const message = level[i];
    if (isRawAgentToolUse(message) && depth < MAX_SUBAGENT_NEST_DEPTH) {
      flushRun();
      out.push(buildSubagentGroup(
        message, byParent, resultMeta, streaming, taskUpdates, depth, consumed,
        continuationTurnClientId, continuationCapability, makerTurnRunning, lastUserInputClientId,
        taskHistoryMayBeIncomplete));
    } else {
      run.push(message);
    }
  }
  flushRun();
  return out;
}

function buildSubagentGroup(
  message: RemoteMessage,
  byParent: Map<string, RemoteMessage[]>,
  resultMeta: Map<string, SubagentResultMeta>,
  streaming: boolean,
  taskUpdates: Map<string, AgentTaskUpdate> | undefined,
  depth: number,
  consumed: Set<string>,
  continuationTurnClientId: string,
  continuationCapability: string,
  makerTurnRunning: boolean,
  lastUserInputClientId: string,
  taskHistoryMayBeIncomplete: boolean,
): RenderSubagentGroupItem {
  const id = rawToolUseId(message);
  if (id.length > 0) consumed.add(id);
  const childMessages = id.length > 0 ? (byParent.get(id) ?? []) : [];
  const group = new RenderSubagentGroupItem();
  group.type = 'subagent_group';
  group.key = `subagent-${id.length > 0 ? id : message.id}`;
  group.children = buildSubagentLevel(
    childMessages, byParent, resultMeta, streaming, taskUpdates, depth + 1, consumed,
    continuationTurnClientId, continuationCapability, makerTurnRunning, lastUserInputClientId, false);
  const tool = parseToolUse(message);
  try {
    const input = JSON.parse(tool.inputRaw) as Object;
    if (input !== undefined && input !== null && typeof input === 'object' && !Array.isArray(input)) {
      group.description = readStr(input as Record<string, Object>, 'description');
      group.subagentType = readStr(input as Record<string, Object>, 'subagent_type');
    }
  } catch (e) {
    // 损坏的历史 input 不影响 children 展示。
  }
  const result = id.length > 0 ? resultMeta.get(id) : undefined;
  if (result !== undefined) group.summary = result.summary;
  group.update = findAgentTaskUpdate(
    taskUpdates, id, message.clientId.length > 0 ? message.clientId : message.id) ?? null;
  group.status = deriveAgentTaskStatus(
    group.update?.status ?? '', tool.toolName, tool.inputRaw, result?.summary ?? '');
  const start = Date.parse(message.createdAt);
  if (result !== undefined && Number.isFinite(start) && result.createdAtMs >= start) {
    group.durationMs = result.createdAtMs - start;
  }
  return group;
}

function appendUnrenderedTaskUpdates(
  items: RenderItem[],
  updates: Map<string, AgentTaskUpdate>,
): void {
  const rendered = new Set<string>();
  collectRenderedTaskKeys(items, rendered);
  const seen = new Set<string>();
  updates.forEach((update: AgentTaskUpdate) => {
    const primary = update.parentToolUseId.length > 0 ? update.parentToolUseId : update.taskId;
    if (seen.has(update.taskId) || rendered.has(primary) || rendered.has(update.taskId)) return;
    seen.add(update.taskId);
    const card = new RenderAgentTaskItem();
    card.type = 'agent_task';
    card.key = `task-update-${primary}`;
    card.update = update;
    card.createdAt = update.updatedAt.length > 0 ? update.updatedAt : update.createdAt;
    items.push(card);
  });
}

function collectRenderedTaskKeys(items: RenderItem[], out: Set<string>): void {
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (item.type === 'agent_task') {
      const task = item as RenderAgentTaskItem;
      if (task.tool !== null && task.tool.toolUseId.length > 0) out.add(task.tool.toolUseId);
      if (task.update !== null) {
        out.add(task.update.taskId);
        if (task.update.parentToolUseId.length > 0) out.add(task.update.parentToolUseId);
      }
    } else if (item.type === 'subagent_group') {
      const group = item as RenderSubagentGroupItem;
      out.add(item.key.replace(/^subagent-/, ''));
      collectRenderedTaskKeys(group.children, out);
    } else if (item.type === 'work_group') {
      collectRenderedTaskKeys((item as RenderWorkGroupItem).children, out);
    }
  }
}

/**
 * 对齐 Mobile scopeUnsettledToolsToActiveTail：被中断的旧轮次可能永久缺少
 * tool_result，只有最后一条真实用户消息后的 active tail 可以保持运行态。
 */
function scopeUnsettledToolsToActiveTail(items: RenderItem[]): void {
  let lastUserIndex = -1;
  for (let i = items.length - 1; i >= 0; i--) {
    if (items[i].type === 'message' && (items[i] as RenderMessageItem).kind === 'user') {
      lastUserIndex = i;
      break;
    }
  }
  if (lastUserIndex < 0) return;

  let settleBeforeIndex = lastUserIndex;
  for (let i = items.length - 1; i > lastUserIndex; i--) {
    if (items[i].type !== 'message') continue;
    const messageItem = items[i] as RenderMessageItem;
    if (messageItem.kind === 'assistant'
      && messageItem.body.trim().length > 0
      && messageItem.message !== undefined
      && !messageItem.message.isStreaming) {
      settleBeforeIndex = i;
      break;
    }
  }
  for (let i = 0; i < settleBeforeIndex; i++) {
    if (items[i].type !== 'tool_group') continue;
    const tools = (items[i] as RenderToolGroupItem).tools;
    for (let j = 0; j < tools.length; j++) {
      if (!tools[j].hasResult) tools[j].hasResult = true;
    }
  }
}

const HISTORY_GAP_SPLIT_MS = 30 * 60 * 1000;
const DELIVERY_PROSE_MIN_LENGTH = 600;
const MARKDOWN_HEADING_RE = /^[ \t]{0,3}#{1,6}[ \t]+\S/m;
const MARKDOWN_TABLE_DIVIDER_RE = /^[ \t]{0,3}\|?[ \t]*:?-{3,}:?[ \t]*\|[-:| \t]*$/m;
const MARKDOWN_LIST_ITEM_RE = /^[ \t]{0,3}(?:[-*+][ \t]+|\d{1,3}[.)][ \t]+)\S/gm;

/** 与 packages/maker-shared/src/messageRender.ts 同口径：user / 空洞是 turn 边界。 */
function groupMessageWorkRuns(items: RenderItem[], isSessionStreaming: boolean): RenderItem[] {
  const out: RenderItem[] = [];
  let currentTurn: RenderItem[] = [];
  let prevEndMs = 0;
  let hasPrevEnd = false;
  const flushTurn = (activeTail: boolean): void => {
    if (currentTurn.length === 0) return;
    if (activeTail && isSessionStreaming) {
      const active = groupActiveWorkRuns(currentTurn);
      for (let i = 0; i < active.length; i++) out.push(active[i]);
    } else {
      const answered = groupAnsweredTurnItems(currentTurn);
      const grouped = answered.handled ? answered.items : groupLegacyWorkRuns(currentTurn);
      for (let i = 0; i < grouped.length; i++) out.push(grouped[i]);
    }
    currentTurn = [];
  };
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (item.type === 'message' && (item as RenderMessageItem).hidden
      && (item as RenderMessageItem).kind !== 'user') continue;
    if (item.type === 'message' && ((item as RenderMessageItem).kind === 'user'
      || (item as RenderMessageItem).message?.role === 'user')) {
      flushTurn(false);
      if (!(item as RenderMessageItem).hidden) out.push(item);
      const userEnd = itemEndTimestamp(item);
      if (userEnd > 0) {
        prevEndMs = hasPrevEnd ? Math.max(prevEndMs, userEnd) : userEnd;
        hasPrevEnd = true;
      }
      continue;
    }
    const start = itemStartTimestamp(item);
    if (hasPrevEnd && start > 0 && start - prevEndMs > HISTORY_GAP_SPLIT_MS) {
      flushTurn(false);
    }
    currentTurn.push(item);
    const end = itemEndTimestamp(item);
    if (end > 0) {
      prevEndMs = hasPrevEnd ? Math.max(prevEndMs, end) : end;
      hasPrevEnd = true;
    }
  }
  flushTurn(true);
  return out;
}

function groupAnsweredTurnItems(items: RenderItem[]): GroupedTurnResult {
  const result = new GroupedTurnResult();
  const sealed: boolean[] = [];
  let sealedCount = 0;
  let lastAnswerIndex = -1;
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (isAssistantAnswerCandidate(item)) {
      lastAnswerIndex = i;
      const message = (item as RenderMessageItem).message;
      if (message !== undefined && message.turnCompleted) {
        sealed[i] = true;
        sealedCount += 1;
      }
    }
  }
  if (lastAnswerIndex < 0) {
    result.items = items.slice();
    result.handled = false;
    return result;
  }

  if (sealedCount > 0) {
    let segmentStart = 0;
    for (let i = 0; i < items.length; i++) {
      if (!sealed[i]) continue;
      let lastWork = -1;
      for (let j = i - 1; j >= segmentStart; j--) {
        if (isWorkActivityItem(items[j])) {
          lastWork = j;
          break;
        }
      }
      let answerStart = i;
      while (answerStart > lastWork + 1
        && answerStart > segmentStart
        && isAssistantAnswerCandidate(items[answerStart - 1])) {
        answerStart -= 1;
      }
      for (let j = answerStart; j <= i; j++) {
        if (isAssistantAnswerCandidate(items[j])) sealed[j] = true;
      }
      segmentStart = i + 1;
    }
  } else {
    let hasWorkAfter = false;
    for (let i = lastAnswerIndex + 1; i < items.length; i++) {
      if (isWorkActivityItem(items[i])) hasWorkAfter = true;
    }
    // 旧数据没有 turn seal 且最后一条正文后还有工具：无法安全判断终稿，保留旧兼容路径。
    if (hasWorkAfter) {
      result.items = items.slice();
      result.handled = false;
      return result;
    }
    let lastWork = -1;
    for (let i = lastAnswerIndex - 1; i >= 0; i--) {
      if (isWorkActivityItem(items[i])) {
        lastWork = i;
        break;
      }
    }
    let answerStart = lastAnswerIndex;
    while (answerStart > lastWork + 1 && isAssistantAnswerCandidate(items[answerStart - 1])) {
      answerStart -= 1;
    }
    for (let i = answerStart; i <= lastAnswerIndex; i++) {
      if (isAssistantAnswerCandidate(items[i])) sealed[i] = true;
    }
  }

  const out: RenderItem[] = [];
  let run: RenderItem[] = [];
  const flushRun = (nextItem?: RenderItem): void => {
    if (run.length === 0) return;
    out.push(createCompletedWorkGroup(run, nextItem));
    run = [];
  };
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (!sealed[i] && !isDeliveryProseItem(item) && isWorkChild(item)) {
      run.push(item);
    } else {
      flushRun(item);
      out.push(item);
    }
  }
  flushRun();
  result.items = out;
  result.handled = true;
  return result;
}

function groupLegacyWorkRuns(items: RenderItem[]): RenderItem[] {
  const out: RenderItem[] = [];
  let run: RenderItem[] = [];
  const flushRun = (nextItem?: RenderItem): void => {
    if (run.length === 0) return;
    out.push(createWorkGroup(run, nextItem));
    run = [];
  };
  for (let i = 0; i < items.length; i++) {
    if (isWorkActivityItem(items[i])) run.push(items[i]);
    else {
      flushRun(items[i]);
      out.push(items[i]);
    }
  }
  flushRun();
  return out;
}

/** 流式尾部保留 assistant 正文，动作按连续段折叠，避免生成过程中跳动整屏。 */
function groupActiveWorkRuns(items: RenderItem[]): RenderItem[] {
  let lastCompletedBoundaryIndex = -1;
  for (let i = 0; i < items.length; i++) {
    if (isAssistantAnswerCandidate(items[i]) || isCompactBoundaryItem(items[i])) {
      lastCompletedBoundaryIndex = i;
    }
  }
  for (let i = 0; i < items.length; i++) {
    if (items[i].type === 'todo') {
      (items[i] as RenderTodoCardItem).isStreaming = i > lastCompletedBoundaryIndex;
    }
  }

  const out: RenderItem[] = [];
  let run: RenderItem[] = [];
  let runLastIndex = -1;
  const flushRun = (nextItem?: RenderItem): void => {
    if (run.length === 0) return;
    out.push(createWorkGroup(run, nextItem, runLastIndex > lastCompletedBoundaryIndex));
    run = [];
    runLastIndex = -1;
  };
  for (let i = 0; i < items.length; i++) {
    if (isWorkActivityItem(items[i])) {
      run.push(items[i]);
      runLastIndex = i;
    }
    else {
      flushRun(items[i]);
      out.push(items[i]);
    }
  }
  flushRun();
  return out;
}

function isAssistantAnswerCandidate(item: RenderItem): boolean {
  if (item.type !== 'message') return false;
  const message = (item as RenderMessageItem).message;
  return (item as RenderMessageItem).kind === 'assistant'
    && message !== undefined
    && (item as RenderMessageItem).body.trim().length > 0;
}

function isCompactBoundaryItem(item: RenderItem): boolean {
  if (item.type !== 'message') return false;
  const message = (item as RenderMessageItem).message;
  return (item as RenderMessageItem).kind === 'system'
    && message !== undefined
    && message.systemCardType === 'compact';
}

function isWorkActivityItem(item: RenderItem): boolean {
  if (item.type === 'agent_task') {
    const task = item as RenderAgentTaskItem;
    const tool = task.tool;
    return deriveAgentTaskStatus(
      task.update?.status ?? '',
      tool?.toolName ?? '',
      tool?.inputRaw ?? '',
      tool?.resultText ?? '',
    ) !== 'running';
  }
  return item.type === 'thinking' || item.type === 'tool_group';
}

function isWorkChild(item: RenderItem): boolean {
  return isWorkActivityItem(item) || isAssistantAnswerCandidate(item);
}

function isDeliveryProseItem(item: RenderItem): boolean {
  if (!isAssistantAnswerCandidate(item)) return false;
  const body = ((item as RenderMessageItem).body).trim();
  if (body.length >= DELIVERY_PROSE_MIN_LENGTH) return true;
  if (MARKDOWN_HEADING_RE.test(body) || MARKDOWN_TABLE_DIVIDER_RE.test(body)) return true;
  const listItems = body.match(MARKDOWN_LIST_ITEM_RE);
  return listItems !== null && listItems.length >= 3;
}

function createWorkGroup(children: RenderItem[], nextItem?: RenderItem, isStreaming: boolean = false): RenderWorkGroupItem {
  const group = new RenderWorkGroupItem();
  group.type = 'work_group';
  group.key = `work-${workChildKey(children[0])}`;
  group.children = children.slice();
  group.isStreaming = isStreaming;
  const start = itemStartTimestamp(children[0]);
  if (start > 0) group.startedAtMs = start;
  const nextStart = nextItem === undefined ? 0 : itemStartTimestamp(nextItem);
  const end = nextStart > 0 ? nextStart : workRunFallbackEnd(children);
  if (start > 0 && end >= start) group.durationMs = end - start;
  return group;
}

function createCompletedWorkGroup(run: RenderItem[], nextItem?: RenderItem): RenderWorkGroupItem {
  let hasAssistantText = false;
  for (let i = 0; i < run.length; i++) {
    if (isAssistantAnswerCandidate(run[i])) hasAssistantText = true;
  }
  if (!hasAssistantText) return createWorkGroup(run, nextItem);

  const children: RenderItem[] = [];
  let activityRun: RenderItem[] = [];
  const flushActivityRun = (nextActivity?: RenderItem): void => {
    if (activityRun.length === 0) return;
    children.push(createWorkGroup(activityRun, nextActivity));
    activityRun = [];
  };
  for (let i = 0; i < run.length; i++) {
    const item = run[i];
    if (isWorkActivityItem(item)) {
      activityRun.push(item);
    } else {
      flushActivityRun(item);
      children.push(item);
    }
  }
  flushActivityRun(nextItem);
  const outer = createWorkGroup(run, nextItem);
  outer.key = `work-summary-${workChildKey(run[0])}`;
  outer.children = children;
  outer.isStreaming = false;
  return outer;
}

function workRunFallbackEnd(run: RenderItem[]): number {
  let latest = 0;
  for (let i = 0; i < run.length; i++) {
    latest = Math.max(latest, itemEndTimestamp(run[i]));
  }
  return latest;
}

function workChildKey(item: RenderItem): string {
  return item.key.length > 0 ? item.key : 'activity';
}

function itemStartTimestamp(item: RenderItem): number {
  if (item.type === 'thinking') return parseIsoMs((item as RenderThinkingItem).createdAt);
  if (item.type === 'tool_group') {
    const tools = (item as RenderToolGroupItem).tools;
    return tools.length > 0 ? parseIsoMs(tools[0].createdAt) : 0;
  }
  if (item.type === 'message') {
    const message = (item as RenderMessageItem).message;
    return message === undefined ? 0 : parseIsoMs(message.createdAt);
  }
  if (item.type === 'agent_task') return parseIsoMs((item as RenderAgentTaskItem).createdAt);
  if (item.type === 'work_group') {
    const children = (item as RenderWorkGroupItem).children;
    return children.length > 0 ? itemStartTimestamp(children[0]) : 0;
  }
  return 0;
}

function itemEndTimestamp(item: RenderItem): number {
  if (item.type === 'thinking') {
    const thinking = item as RenderThinkingItem;
    const start = parseIsoMs(thinking.createdAt);
    return start > 0 ? start + Math.max(0, thinking.durationMs) : 0;
  }
  if (item.type === 'tool_group') {
    const tools = (item as RenderToolGroupItem).tools;
    let latest = 0;
    for (let i = 0; i < tools.length; i++) {
      latest = Math.max(latest, parseIsoMs(tools[i].createdAt), parseIsoMs(tools[i].settledAt));
    }
    return latest;
  }
  if (item.type === 'work_group') {
    const children = (item as RenderWorkGroupItem).children;
    let latest = 0;
    for (let i = 0; i < children.length; i++) latest = Math.max(latest, itemEndTimestamp(children[i]));
    return latest;
  }
  if (item.type === 'agent_task') {
    const task = item as RenderAgentTaskItem;
    let latest = parseIsoMs(task.createdAt);
    if (task.update !== null) latest = Math.max(latest, parseIsoMs(task.update.updatedAt));
    if (task.tool !== null) latest = Math.max(latest, parseIsoMs(task.tool.settledAt));
    return latest;
  }
  return itemStartTimestamp(item);
}

function parseIsoMs(iso: string): number {
  if (iso.length === 0) {
    return 0;
  }
  const ts = Date.parse(iso);
  return Number.isFinite(ts) ? ts : 0;
}

function normalizeKind(role: string): string {
  if (role === 'user') return 'user';
  if (role === 'assistant') return 'assistant';
  if (role === 'error') return 'error';
  if (role === 'agent_switch') return 'agent_switch';
  return 'system';
}

function labelOf(role: string): string {
  switch (role) {
    case 'user':
      return '你';
    case 'assistant':
      return '助手';
    case 'error':
      return '错误';
    case 'agent_switch':
      return '切换';
    case 'ask_user':
      return '询问';
    case 'plan_review':
      return '计划';
    default:
      return role;
  }
}

/** orca 通讯工具的空结果隐藏（对齐 shouldHideToolResult）。 */
function shouldHideToolResult(toolName: string, content: string): boolean {
  const normalized = toolName.replace(/^mcp__/, 'mcp:').replace(/__/g, ':');
  const isOrca = normalized === 'mcp:orca_worker_bridge:send_to_lead'
    || normalized === 'mcp:orca_worker_bridge:read_lead'
    || normalized === 'mcp:orca_worker_bridge:lead_status'
    || toolName === 'send_to_lead'
    || toolName === 'read_lead'
    || toolName === 'lead_status';
  if (!isOrca) {
    return false;
  }
  if (content.trim().length === 0) {
    return true;
  }
  return false;
}
