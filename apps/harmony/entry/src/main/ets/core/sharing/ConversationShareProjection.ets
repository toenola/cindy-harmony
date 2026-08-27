/**
 * 会话分享投影（纯逻辑，不触碰系统 API）。
 *
 * 分享只消费**当前用户可见**的稳定内容：
 * - 保留用户消息、assistant 正文，以及用户当前已展开的工作内容；
 * - 折叠且不可见的正文不得偷偷出现在分享图里（用户以为没分享出去的东西不能泄漏）；
 * - 交互按钮、发送队列、内部错误详情、绝对路径和凭证一律不进入导出。
 *
 * 导出前必须冻结一次快照：分享开始后会话仍在流式更新，半新半旧会让预览与最终
 * 文件不一致。`freezeShareProjection` 就是那次冻结的唯一出口。
 *
 * 尺寸约束见 docs/version/v1.1.0/技术设计.md §6.3：截图受 GPU 纹理上限约束
 * （常见 8192×8192，超限报 100001），因此本模块只做"分几段、要不要多图、
 * 是否必须提示用户缩小范围"的判定，真正的绘制与合成由调用方用
 * componentSnapshot 完成。
 */

import {
  RenderItem,
  RenderMessageItem,
  RenderSubagentGroupItem,
  RenderThinkingItem,
  RenderWorkGroupItem,
} from '../messages/MessageRender';
import { readObj } from '../tasks/TaskModels';

/** 单张导出图任一边的保守像素上限（设备实际值可用 hidumper vktextureLimit 查询）。 */
export const SHARE_MAX_IMAGE_EDGE_PX = 8192;
/** 为缩放、边距和编码留出的安全余量。 */
export const SHARE_IMAGE_SAFETY_MARGIN_PX = 192;
/** 超过该张数就不再自动分图，改为提示用户缩小范围。 */
export const SHARE_MAX_SEGMENTS = 6;

/** 分享投影里的一条内容。 */
export class ShareProjectionItem {
  /** 对应渲染项的 key，便于调用方定位真实节点做截图。 */
  key: string = '';
  /** 'user' | 'assistant' | 'work' | 'thinking' | 'system' */
  kind: string = '';
  /** 已投影的可见正文（折叠内容已按可见语义裁掉）。 */
  text: string = '';
}

export class ShareProjection {
  items: ShareProjectionItem[] = [];
  /** 是否有内容因折叠而被排除；调用方可据此提示"仅分享当前可见内容"。 */
  omittedCollapsedContent: boolean = false;
}

/**
 * 该渲染项是否允许进入分享。
 *
 * 交互类卡片（权限、Ask User、Plan Review）、排队气泡和错误详情都不导出：
 * 它们是"当前待办"而不是对话内容，且常含内部路径与失败堆栈。
 */
export function isShareableRenderType(type: string): boolean {
  return type === 'message' || type === 'work_group' || type === 'thinking'
    || type === 'subagent_group';
}

/** 内部错误详情与敏感路径不进导出；这类消息 kind 直接排除。 */
export function isShareableMessageKind(kind: string): boolean {
  return kind === 'user' || kind === 'assistant';
}

class VisibleText {
  text: string = '';
  truncated: boolean = false;
}

/**
 * 冻结一次分享投影。
 *
 * `expandedKeys` 是用户当前展开的工作组 / thinking key 集合：未展开的工作内容
 * 不进导出，与屏幕所见一致。`collapsedUserTextLimit` 为长用户消息收起后可见的
 * 行数，超出部分同样按可见语义截断。
 */
export function freezeShareProjection(
  items: RenderItem[],
  expandedKeys: Set<string>,
  collapsedUserTextLimit: number,
  visibleUserTextOverrides: Map<string, string> | undefined = undefined,
): ShareProjection {
  const out = new ShareProjection();
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (!isShareableRenderType(item.type)) continue;

    if (item.type === 'message') {
      const message = item as RenderMessageItem;
      if (!isShareableMessage(message)) continue;
      const projected = new ShareProjectionItem();
      projected.key = item.key;
      projected.kind = message.kind;
      const overriddenText = visibleUserTextOverrides?.get(item.key);
      if (overriddenText !== undefined) {
        projected.text = overriddenText;
        if (overriddenText !== message.body) out.omittedCollapsedContent = true;
      } else {
        const visible = visibleUserText(message, collapsedUserTextLimit);
        projected.text = visible.text;
        if (visible.truncated) out.omittedCollapsedContent = true;
      }
      // 纯附件或空 systemCard 没有可见正文，不生成只有角色标签的空白分享卡。
      if (projected.text.trim().length === 0) continue;
      out.items.push(projected);
      continue;
    }

    // 工作过程与思考：只有用户当前展开的才导出，否则只记一次"有内容被折叠"。
    if (!expandedKeys.has(item.key)) {
      out.omittedCollapsedContent = true;
      continue;
    }
    const projected = new ShareProjectionItem();
    projected.key = item.key;
    if (item.type === 'thinking') {
      const thinking = item as RenderThinkingItem;
      if (thinking.redacted || thinking.body.trim().length === 0) continue;
      projected.kind = 'thinking';
      projected.text = thinking.body;
    } else if (item.type === 'work_group') {
      projected.kind = 'work';
      const work = workGroupShareText(
        item as RenderWorkGroupItem, expandedKeys, collapsedUserTextLimit,
        visibleUserTextOverrides,
      );
      projected.text = work.text;
      out.omittedCollapsedContent = out.omittedCollapsedContent || work.omitted;
    } else {
      // Subagent group 的展开态与 work_group 共用同一份可见子树；折叠时不应把
      // 摘要或子消息偷偷带入导出，展开后只保留实际可见的正文与思考内容。
      projected.kind = 'work';
      const subagent = item as RenderSubagentGroupItem;
      const work = subagentShareText(
        subagent, expandedKeys, collapsedUserTextLimit, visibleUserTextOverrides,
      );
      projected.text = work.text;
      out.omittedCollapsedContent = out.omittedCollapsedContent || work.omitted;
    }
    // 展开的工作组可能只有工具调用或被隐藏的内部行；不要生成空白工作卡。
    if (projected.text.trim().length === 0) continue;
    out.items.push(projected);
  }
  return out;
}

/** 工作组子树的可见文字；不把工具 input/result 原文带出设备。 */
class WorkShareText {
  text: string = '';
  omitted: boolean = false;
}

function appendWorkSharePart(result: WorkShareText, text: string): void {
  const trimmed = text.trim();
  if (trimmed.length === 0) return;
  result.text = result.text.length === 0 ? trimmed : `${result.text}\n${trimmed}`;
}

function workGroupShareText(
  group: RenderWorkGroupItem,
  expandedKeys: Set<string>,
  collapsedUserTextLimit: number,
  visibleUserTextOverrides: Map<string, string> | undefined,
): WorkShareText {
  const result = new WorkShareText();
  collectWorkShareText(
    group.children, expandedKeys, collapsedUserTextLimit, visibleUserTextOverrides, result,
  );
  return result;
}

function subagentShareText(
  group: RenderSubagentGroupItem,
  expandedKeys: Set<string>,
  collapsedUserTextLimit: number,
  visibleUserTextOverrides: Map<string, string> | undefined,
): WorkShareText {
  const result = new WorkShareText();
  collectWorkShareText(
    group.children, expandedKeys, collapsedUserTextLimit, visibleUserTextOverrides, result,
  );
  return result;
}

function collectWorkShareText(
  items: RenderItem[],
  expandedKeys: Set<string>,
  collapsedUserTextLimit: number,
  visibleUserTextOverrides: Map<string, string> | undefined,
  result: WorkShareText,
): void {
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (item.type === 'message') {
      const message = item as RenderMessageItem;
      if (!isShareableMessage(message)) continue;
      const overriddenText = visibleUserTextOverrides?.get(item.key);
      if (overriddenText !== undefined) {
        appendWorkSharePart(result, overriddenText);
        if (overriddenText !== message.body) result.omitted = true;
        continue;
      }
      const visible = visibleUserText(message, collapsedUserTextLimit);
      appendWorkSharePart(result, visible.text);
      if (visible.truncated) result.omitted = true;
      continue;
    }
    if (item.type === 'work_group') {
      // 当前 ArkUI 的 workGroupChild 会把嵌套 work_group 直接展开，不提供第二个
      // 折叠入口，因此父组打开后递归读取其子树即可。
      collectWorkShareText(
        (item as RenderWorkGroupItem).children, expandedKeys, collapsedUserTextLimit,
        visibleUserTextOverrides, result,
      );
      continue;
    }
    if (item.type === 'thinking') {
      const thinking = item as RenderThinkingItem;
      if (!expandedKeys.has(item.key)) {
        if (thinking.redacted || thinking.body.trim().length > 0) result.omitted = true;
        continue;
      }
      if (thinking.redacted) {
        result.omitted = true;
        continue;
      }
      appendWorkSharePart(result, thinking.body);
      continue;
    }
    if (item.type === 'subagent_group') {
      const subagent = item as RenderSubagentGroupItem;
      if (!expandedKeys.has(item.key)) {
        if (subagent.children.length > 0) {
          result.omitted = true;
        }
        continue;
      }
      collectWorkShareText(
        subagent.children, expandedKeys, collapsedUserTextLimit,
        visibleUserTextOverrides, result,
      );
    }
  }
}

/** 与页面选择态及 Mobile isShareableMessage 保持同一过滤边界。 */
function isShareableMessage(message: RenderMessageItem): boolean {
  if (message.hidden || !isShareableMessageKind(message.kind)) return false;
  const source = message.message;
  // 纯逻辑单测可构造没有原始消息的 RenderMessageItem；其 kind 已足够表达分享边界。
  if (source === undefined) return true;
  if (source.systemCardType.length > 0 || source.isSyntheticTrigger || source.presentedAsAgent) {
    return false;
  }
  return Object.keys(readObj(source.agentMeta, 'hookSource')).length === 0;
}

/** 长用户消息收起后只导出可见行，与屏幕一致。 */
function visibleUserText(message: RenderMessageItem, collapsedLimit: number): VisibleText {
  const result = new VisibleText();
  result.text = message.body;
  if (message.kind !== 'user' || collapsedLimit <= 0) return result;
  const lines = message.body.split('\n');
  if (lines.length <= collapsedLimit) return result;
  result.text = lines.slice(0, collapsedLimit).join('\n');
  result.truncated = true;
  return result;
}

/** 分段计划：一次导出需要几张图，以及是否必须让用户缩小范围。 */
export class ShareSegmentPlan {
  /** 需要导出的图片张数；0 表示无法导出。 */
  segments: number = 0;
  /** 每段用于内容装箱的安全高度（px），已扣除误差余量。 */
  segmentHeightPx: number = 0;
  /** builder 根节点允许的物理最大高度（px），不得超过设备截图上限。 */
  snapshotHeightLimitPx: number = 0;
  /** true = 内容超出自动分图能力，必须提示用户缩小范围。 */
  requiresNarrowing: boolean = false;
}

/**
 * 按内容总高度规划分段，禁止无上限画布。
 *
 * 单边上限扣掉安全余量后作为每段高度；段数超过 SHARE_MAX_SEGMENTS 时不再自动
 * 分图，返回 requiresNarrowing，由 UI 明确提示用户缩小范围。
 */
export function planShareSegments(
  contentHeightPx: number,
  contentWidthPx: number,
  maximumWidthPx: number = SHARE_MAX_IMAGE_EDGE_PX,
  maximumHeightPx: number = SHARE_MAX_IMAGE_EDGE_PX,
): ShareSegmentPlan {
  const plan = new ShareSegmentPlan();
  const snapshotWidthLimitPx = Math.min(SHARE_MAX_IMAGE_EDGE_PX, maximumWidthPx);
  const snapshotHeightLimitPx = Math.min(SHARE_MAX_IMAGE_EDGE_PX, maximumHeightPx);
  const usableWidth = snapshotWidthLimitPx -
    SHARE_IMAGE_SAFETY_MARGIN_PX;
  const usableHeight = snapshotHeightLimitPx -
    SHARE_IMAGE_SAFETY_MARGIN_PX;
  if (contentHeightPx <= 0 || contentWidthPx <= 0) return plan;
  if (usableWidth <= 0 || usableHeight <= 0) {
    plan.requiresNarrowing = true;
    return plan;
  }
  // 宽度本身就超限时无论怎么分段都画不出来，必须先缩小范围。
  if (contentWidthPx > usableWidth) {
    plan.requiresNarrowing = true;
    return plan;
  }
  plan.segmentHeightPx = usableHeight;
  plan.snapshotHeightLimitPx = snapshotHeightLimitPx;
  const segments = Math.ceil(contentHeightPx / usableHeight);
  if (segments > SHARE_MAX_SEGMENTS) {
    plan.requiresNarrowing = true;
    return plan;
  }
  plan.segments = segments;
  return plan;
}

/**
 * 按每个真实渲染项的测量高度做顺序装箱。
 *
 * 与按项数均分相比，这能避免长正文集中到同一段后越过截图上限。若单个渲染项
 * 自身已经放不进一张图，返回空数组，由 UI 明确提示缩小范围，禁止静默裁掉正文。
 */
export function shareSegmentStartIndicesByHeight(
  itemHeightsPx: number[],
  segmentHeightPx: number,
  verticalPaddingPx: number,
  itemGapPx: number,
  trailingReservePx: number = 0,
): number[] {
  if (itemHeightsPx.length === 0 || segmentHeightPx <= 0 ||
    verticalPaddingPx < 0 || itemGapPx < 0 || trailingReservePx < 0) return [];
  const starts: number[] = [0];
  let usedPx = verticalPaddingPx * 2 + trailingReservePx;
  let itemsInSegment = 0;
  for (let i = 0; i < itemHeightsPx.length; i++) {
    const itemHeightPx = itemHeightsPx[i];
    if (!Number.isFinite(itemHeightPx) || itemHeightPx <= 0 ||
      itemHeightPx + verticalPaddingPx * 2 + trailingReservePx > segmentHeightPx) return [];
    const nextHeightPx = itemHeightPx + (itemsInSegment > 0 ? itemGapPx : 0);
    if (itemsInSegment > 0 && usedPx + nextHeightPx > segmentHeightPx) {
      starts.push(i);
      usedPx = verticalPaddingPx * 2 + trailingReservePx + itemHeightPx;
      itemsInSegment = 1;
      continue;
    }
    usedPx += nextHeightPx;
    itemsInSegment += 1;
  }
  return starts;
}

/**
 * 把投影项按段切分，返回每段的起始下标。
 *
 * 段数由 planShareSegments 决定（受设备纹理上限约束）；这里只做均分，
 * 保证预览与最终导出使用**同一份**切分，不会出现预览 3 张、导出 4 张。
 */
export function shareSegmentStartIndices(itemCount: number, segments: number): number[] {
  if (itemCount <= 0 || segments <= 0) return [];
  const perSegment = Math.ceil(itemCount / segments);
  const starts: number[] = [];
  for (let start = 0; start < itemCount; start += perSegment) starts.push(start);
  return starts;
}

/**
 * 分享临时文件名。
 *
 * 只使用会话本地序号与时间戳，**不含**任务标题、工作目录、用户标识或设备号：
 * 文件名会随分享一起离开设备，标题里常带项目名和路径。
 */
export function shareImageFileName(sequence: number, timestampMs: number): string {
  const safeSequence = Number.isFinite(sequence) && sequence > 0 ? Math.floor(sequence) : 1;
  const safeStamp = Number.isFinite(timestampMs) && timestampMs > 0 ? Math.floor(timestampMs) : 0;
  return `cindy-conversation-${safeStamp}-${safeSequence}.png`;
}
