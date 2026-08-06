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
 * 独立媒体项仍未接入。原始 RemoteMessage 引用保留在渲染项里，
 * 供消息动作（复制/Fork/Rewind）与媒体识别使用。
 */

import {
  RemoteMessage, readStr, readObj, readAny,
} from '../tasks/TaskModels';
import { parseMarkdown, MdBlock } from './MarkdownParser';
import { RemoteImageRef } from '../attachments/AttachmentModels';

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
  message: RemoteMessage | undefined = undefined;
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
  /** 调用发起时间 ISO（work_group 时长计算用）。 */
  createdAt: string = '';
}

/** 连续工具调用聚合块。 */
export class RenderToolGroupItem extends RenderItem {
  tools: RenderToolItem[] = [];
}

export class RenderTodoItem {
  seq: number = 0;
  content: string = '';
  status: string = 'pending'; // 'pending' | 'in_progress' | 'completed'
}

/** 计划/待办卡。 */
export class RenderTodoCardItem extends RenderItem {
  todos: RenderTodoItem[] = [];
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

export function toolResultHasError(message: RemoteMessage): boolean {
  const content = message.content;
  if (content !== undefined && typeof content === 'object' && !Array.isArray(content)) {
    const record = content as Record<string, Object>;
    return record['isError'] === true || record['is_error'] === true;
  }
  // 历史 tool_result 通常只有纯文本正文；正文可能本身就在讨论 error，
  // 没有结构化信号时宁可不标失败，避免假阳性。
  return false;
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
        ref.originalName = readStr(rr, 'originalName');
        ref.name = readStr(rr, 'name');
        ref.mimeType = readStr(rr, 'mimeType');
        const size = rr['size'];
        ref.size = typeof size === 'number' ? size : 0;
        ref.sha256 = readStr(rr, 'sha256');
        if (ref.url.length > 0) {
          out.images.push(ref);
        }
      }
    }
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
export function buildRenderItems(messages: RemoteMessage[], isSessionStreaming: boolean = false): RenderItem[] {
  const items: RenderItem[] = [];
  let todoSeq = 0;

  // 结果必须只作为 tool_use 的 secondary body 消费。之前把 tool_result 再建成一个
  // tool_group，导致同一条 Bash 在鸿蒙端出现两次，正是截图里“重复调用 bash”的来源。
  const toolNameByUseId = new Map<string, string>();
  const resultByUseId = new Map<string, string>();
  const resultAtByUseId = new Map<string, string>();
  const resultErrorByUseId = new Map<string, boolean>();
  const settledUseIds = new Set<string>();
  const adjacentResultByMessageId = new Map<string, string>();
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
    if (toolResultHasError(m)) resultErrorByUseId.set(useId, true);
    const preview = summarizeText(contentPreview(m.content));
    if (!shouldHideToolResult(toolNameByUseId.get(useId) ?? '', preview)) {
      resultByUseId.set(useId, preview);
    }
  }
  // 旧历史里仍有“tool_use 紧邻 tool_result、但 useId 没落在 result 行”的数据，
  // 只把正文做邻接兜底，不拿邻接时间冒充精确 settle 时间。
  for (let i = 0; i + 1 < messages.length; i++) {
    const use = messages[i];
    const result = messages[i + 1];
    if (use.role !== 'tool_use' || result.role !== 'tool_result') continue;
    const useInfo = parseToolUse(use);
    const resultUseId = toolResultUseId(result);
    if (resultUseId.length > 0 && resultUseId !== useInfo.toolUseId) continue;
    adjacentSettledMessageIds.add(use.id);
    if (toolResultHasError(result)) adjacentErrorMessageIds.add(use.id);
    const preview = summarizeText(contentPreview(result.content));
    if (!shouldHideToolResult(useInfo.toolName, preview)) {
      adjacentResultByMessageId.set(use.id, preview);
    }
  }

  let pendingTools: RenderToolItem[] = [];
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
    pendingTools = [];
    pendingFirstKey = '';
  };

  // 同一轮计划更新只保留最新一张 todo 卡；plan tool 本身不再作为普通工具行渲染。
  let latestTodoCard: RenderTodoCardItem | null = null;
  const appendTodoCard = (message: RemoteMessage, todos: RenderTodoItem[]): void => {
    for (let i = 0; i < todos.length; i++) {
      todos[i].seq = todoSeq;
      todoSeq += 1;
    }
    if (latestTodoCard !== null) {
      latestTodoCard.todos = todos;
      return;
    }
    const card = new RenderTodoCardItem();
    card.type = 'todo';
    card.key = `${message.id}-todo`;
    card.todos = todos;
    items.push(card);
    latestTodoCard = card;
  };

  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    const role = m.role;
    if (role === 'user') latestTodoCard = null;

    if (role === 'tool_use') {
      const tool = parseToolUse(m);
      if (isPlanTool(tool.toolName)) {
        flushTools();
        const todos = extractTodos(tool.toolName, tool.inputRaw);
        if (todos !== null) appendTodoCard(m, todos);
        continue;
      }
      const item = new RenderToolItem();
      item.seq = pendingTools.length;
      item.toolUseId = tool.toolUseId;
      item.toolName = tool.toolName;
      item.inputRaw = tool.inputRaw;
      item.inputText = tool.inputText.length > 0 ? summarizeText(tool.inputText) : '';
      if (item.toolUseId.length > 0 && settledUseIds.has(item.toolUseId)) {
        item.resultText = resultByUseId.get(item.toolUseId) ?? '';
        item.hasResult = true;
        item.hasError = resultErrorByUseId.get(item.toolUseId) ?? false;
        item.settledAt = resultAtByUseId.get(item.toolUseId) ?? '';
      } else if (adjacentSettledMessageIds.has(m.id)) {
        item.resultText = adjacentResultByMessageId.get(m.id) ?? '';
        item.hasResult = true;
        item.hasError = adjacentErrorMessageIds.has(m.id);
      }
      item.createdAt = m.createdAt;
      if (pendingTools.length === 0) pendingFirstKey = m.id;
      pendingTools.push(item);
      continue;
    }

    if (pendingTools.length > 0) flushTools();
    // tool_result 已在上面的预扫描中配对，绝不能再单独产出一个可见工具行。
    if (role === 'tool_result') continue;

    if (role === 'thinking') {
      const item = new RenderThinkingItem();
      item.type = 'thinking';
      item.key = m.id;
      item.body = contentPreview(m.content);
      if (m.content !== undefined && typeof m.content === 'object' && !Array.isArray(m.content)) {
        const record = m.content as Record<string, Object>;
        const dur = readAny(record, 'durationMs');
        if (typeof dur === 'number' && Number.isFinite(dur)) item.durationMs = Math.max(0, dur);
        item.redacted = record['isRedacted'] === true;
      }
      item.createdAt = m.createdAt;
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
      item.kind = 'system';
      item.label = `system:${m.systemCardType}`;
      item.body = m.systemCardType === 'compact' ? '' : contentPreview(m.content);
      item.mdBlocks = item.body.length > 0 ? parseMarkdown(item.body) : [];
      item.message = m;
      items.push(item);
      continue;
    }

    if (role === 'user') {
      const item = new RenderMessageItem();
      item.type = 'message';
      item.key = m.id;
      item.kind = 'user';
      item.label = '你';
      const parsed = parseUserContent(m.content);
      item.body = parsed.text;
      item.segments = buildSegments(parsed.text, parsed.ranges, m.automationOrigin);
      item.mdBlocks = item.segments.length > 0 ? item.segments[0].mdBlocks : parseMarkdown(item.body);
      item.images = parsed.images;
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
    items.push(item);
  }
  flushTools();
  scopeUnsettledToolsToActiveTail(items);
  return groupMessageWorkRuns(items, isSessionStreaming);
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
    if (item.type === 'message' && (item as RenderMessageItem).kind === 'user') {
      flushTurn(false);
      out.push(item);
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
