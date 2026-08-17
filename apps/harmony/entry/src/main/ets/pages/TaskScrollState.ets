/** TaskPage 消息列表索引与贴底重试的纯逻辑。 */

import { deriveAgentTaskStatus, WorkflowProgressEntry } from '../core/messages/AgentTaskStore';
import {
  RenderAgentTaskItem,
  RenderItem,
  RenderSubagentGroupItem,
  RenderThinkingItem,
  RenderTodoCardItem,
  RenderToolGroupItem,
  RenderToolItem,
  RenderWorkGroupItem,
} from '../core/messages/MessageRender';

/** 等首轮布局、下一帧与较慢的复杂卡片测量分别收敛；新一轮更新会取消旧代次。 */
export const FOLLOW_LATEST_RETRY_DELAYS: number[] = [24, 80, 180];

/** 与 Mobile/iOS 一致：短首屏在没有用户手势时最多再补三页。 */
export const INITIAL_HISTORY_AUTOFILL_PAGES: number = 3;

/**
 * 历史自动预取的电平判定。用户已明确回看时不受首屏预算限制；冷开只使用
 * 有界预算。同一首项已经尝试过则必须停止，避免空页、重复页或失败请求自旋。
 */
export function shouldAutoLoadEarlier(
  userReviewIntent: boolean,
  initialAutofillRemaining: number,
  followingLatest: boolean,
  sessionOpenResolved: boolean,
  initialScrollSettling: boolean,
  loadingOlder: boolean,
  nearStart: boolean,
  hasMore: boolean,
  itemCount: number,
  firstItemKey: string,
  lastAttemptedFirstItemKey: string,
): boolean {
  if (!userReviewIntent && (!followingLatest || initialAutofillRemaining <= 0)) return false;
  if (!sessionOpenResolved || initialScrollSettling || loadingOlder || !nearStart || !hasMore) {
    return false;
  }
  if (itemCount <= 0 || firstItemKey.length === 0) return false;
  return firstItemKey !== lastAttemptedFirstItemKey;
}

/** List 顶部可能有“加载更早”入口；把可见 List index 换算成渲染项 index。 */
export function firstVisibleMessageRenderIndex(
  hasMore: boolean,
  visibleStartIndex: number,
  messageItemCount: number,
): number {
  if (messageItemCount <= 0) return -1;
  const historyHeaderCount = hasMore ? 1 : 0;
  return Math.max(0, Math.min(
    messageItemCount - 1,
    visibleStartIndex - historyHeaderCount,
  ));
}

export function messageListBottomIndex(
  hasMore: boolean,
  messageItemCount: number,
  hasQueueStateBanner: boolean,
  hasTailBanner: boolean,
  queueBubbleCount: number,
): number {
  return (hasMore ? 1 : 0)
    + Math.max(0, messageItemCount)
    + (hasQueueStateBanner ? 1 : 0)
    + (hasTailBanner ? 1 : 0)
    + Math.max(0, queueBubbleCount);
}

/**
 * ArkUI ForEach 会按 key 复用普通对象节点。工作组从 live 收口为 done 时业务 key
 * 必须保持稳定（展开态、搜索和滚动锚点都依赖它），但渲染节点 key 需要带状态位，
 * 才能让“正在工作”立即重建为“已工作”。所有节点统一加类型命名空间；可选的
 * presentationState 负责计划、Agent 和工作步骤等同业务 key 下的展示变化。
 */
export function messageListRenderNodeKey(
  baseKey: string,
  itemType: string,
  isStreaming: boolean,
  presentationState: string = '',
): string {
  // 所有渲染节点都进入同一套带长度的命名空间，避免远端消息 id 恰好与
  // work_group 派生 key 同名时产生跨类型碰撞；业务 key 本身不受影响。
  const identity = `render:${itemType.length}:${itemType}:${baseKey.length}:${baseKey}`;
  const lifecycle = itemType === 'work_group'
    ? `${identity}:work:${isStreaming ? 'live' : 'done'}`
    : identity;
  if (presentationState.length > 0) {
    return `${lifecycle}:state:${presentationState.length}:${presentationState}`;
  }
  return lifecycle;
}

function textRevision(value: string): string {
  let hash = 2166136261;
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return `${value.length}:${(hash >>> 0).toString(36)}`;
}

function toolPresentationState(tool: RenderToolItem): string {
  const mediaState: string[] = [];
  for (let i = 0; i < tool.media.length; i++) {
    mediaState.push(textRevision(tool.media[i].url));
  }
  for (let i = 0; i < tool.richMedia.length; i++) {
    mediaState.push(`${tool.richMedia[i].kind}:${textRevision(tool.richMedia[i].url)}`);
  }
  return [
    `id:${textRevision(tool.toolUseId)}`,
    `n:${textRevision(tool.toolName)}`,
    `i:${textRevision(tool.inputRaw)}`,
    `r:${tool.hasResult ? '1' : '0'}`,
    `e:${tool.hasError ? '1' : '0'}`,
    `o:${textRevision(tool.resultText)}`,
    `d:${tool.diff === null ? '0' : '1'}`,
    `m:${mediaState.join(',')}`,
  ].join('|');
}

function workflowPresentationState(entries: WorkflowProgressEntry[]): string {
  const states: string[] = [];
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    states.push([
      entry.index.toString(),
      textRevision(entry.type),
      textRevision(entry.state),
      textRevision(entry.label),
      textRevision(entry.title),
      textRevision(entry.lastToolName),
      textRevision(entry.resultPreview),
      textRevision(entry.error),
    ].join(':'));
  }
  return states.join(',');
}

function agentTaskPresentationState(item: RenderAgentTaskItem): string {
  const tool = item.tool;
  const update = item.update;
  const status = deriveAgentTaskStatus(
    update?.status ?? '',
    tool?.toolName ?? '',
    tool?.inputRaw ?? '',
    tool?.resultText ?? '',
  );
  const usage = update?.usage;
  return [
    `s:${status}`,
    `t:${tool === null ? '' : toolPresentationState(tool)}`,
    `u:${update === null ? '' : textRevision(update.updatedAt)}`,
    `p:${update === null ? '' : textRevision(update.provider)}`,
    `h:${update === null ? '' : textRevision(update.title)}`,
    `d:${update === null ? '' : textRevision(update.description)}`,
    `m:${update === null ? '' : textRevision(update.summary)}`,
    `f:${update === null ? '' : textRevision(update.outputFile)}`,
    `l:${update === null ? '' : textRevision(update.lastToolName)}`,
    `w:${update === null ? '' : workflowPresentationState(update.workflowProgress)}`,
    `g:${usage === null || usage === undefined
      ? '' : `${usage.totalTokens}:${usage.toolUses}:${usage.durationMs}`}`,
  ].join('|');
}

/**
 * 普通 RenderItem 不是 @Observed 对象；ForEach 业务 key 相同就会继续持有旧 Builder
 * 参数。这里只编码会改变卡片展示的状态/内容，业务 key 仍由消息、折叠态和滚动锚点持有。
 */
export function messageListItemPresentationState(item: RenderItem): string {
  if (item.type === 'todo') {
    const todo = item as RenderTodoCardItem;
    const states: string[] = [];
    for (let i = 0; i < todo.todos.length; i++) {
      states.push(`${todo.todos[i].seq}:${todo.todos[i].status}:${textRevision(todo.todos[i].content)}`);
    }
    return `todo:${todo.isStreaming ? 'live' : 'done'}:${states.join(',')}`;
  }
  if (item.type === 'agent_task') {
    return `agent:${agentTaskPresentationState(item as RenderAgentTaskItem)}`;
  }
  if (item.type === 'tool_group') {
    const group = item as RenderToolGroupItem;
    const states: string[] = [];
    for (let i = 0; i < group.tools.length; i++) {
      states.push(`${i}:${toolPresentationState(group.tools[i])}`);
    }
    return `tools:${states.join(',')}`;
  }
  if (item.type === 'thinking') {
    const thinking = item as RenderThinkingItem;
    return `thinking:${thinking.redacted ? '1' : '0'}:${thinking.durationMs}:${textRevision(thinking.body)}`;
  }
  if (item.type === 'work_group') {
    const work = item as RenderWorkGroupItem;
    const states: string[] = [];
    for (let i = 0; i < work.children.length; i++) {
      const child = work.children[i];
      const state = messageListItemPresentationState(child);
      states.push(`${i}:${textRevision(child.key)}:${state.length}:${state}`);
    }
    return `work:${work.isStreaming ? 'live' : 'done'}:${states.join(',')}`;
  }
  if (item.type === 'subagent_group') {
    const group = item as RenderSubagentGroupItem;
    const states: string[] = [];
    for (let i = 0; i < group.children.length; i++) {
      const child = group.children[i];
      const state = messageListItemPresentationState(child);
      states.push(`${i}:${textRevision(child.key)}:${state.length}:${state}`);
    }
    const updateState = group.update === null
      ? '' : `${textRevision(group.update.updatedAt)}:${workflowPresentationState(group.update.workflowProgress)}`;
    return [
      `subagent:${group.status}`,
      `d:${group.durationMs}`,
      `m:${textRevision(group.summary)}`,
      `u:${updateState}`,
      `c:${states.join(',')}`,
    ].join('|');
  }
  return '';
}
