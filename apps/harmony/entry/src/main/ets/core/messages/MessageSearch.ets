/** 会话内搜索投影；每个顶层渲染项至多返回一个命中。 */

import {
  RenderAgentTaskItem,
  RenderItem,
  RenderMessageItem,
  RenderSubagentGroupItem,
  RenderThinkingItem,
  RenderTodoCardItem,
  RenderToolGroupItem,
  RenderToolItem,
  RenderWorkGroupItem,
} from './MessageRender';

export class MessageSearchHit {
  /** 可直接定位的顶层 List item key。 */
  itemKey: string = '';
  /** 实际命中的叶子 key；prepend 后靠它保持当前选择。 */
  sourceKey: string = '';
  label: string = '';
  preview: string = '';
}

export class MessageSearchPagingPresentation {
  visible: boolean = false;
  enabled: boolean = false;
  label: string = '';
}

export function normalizeMessageSearchText(value: string): string {
  return value.trim().replace(/\s+/g, ' ').toLocaleLowerCase();
}

function searchPreview(value: string, normalizedQuery: string): string {
  const compact = value.replace(/\s+/g, ' ').trim();
  if (compact.length === 0) return '';
  const index = normalizeMessageSearchText(compact).indexOf(normalizedQuery);
  if (index < 0) return compact.slice(0, 88);
  const start = Math.max(0, index - 32);
  const end = Math.min(compact.length, index + normalizedQuery.length + 48);
  return `${start > 0 ? '…' : ''}${compact.slice(start, end)}${end < compact.length ? '…' : ''}`;
}

function searchText(
  itemKey: string,
  sourceKey: string,
  label: string,
  text: string,
  normalizedQuery: string,
): MessageSearchHit | null {
  if (normalizeMessageSearchText(text).indexOf(normalizedQuery) < 0) return null;
  const hit = new MessageSearchHit();
  hit.itemKey = itemKey;
  hit.sourceKey = sourceKey;
  hit.label = label;
  hit.preview = searchPreview(text, normalizedQuery);
  return hit;
}

function appendToolText(tool: RenderToolItem, parts: string[]): void {
  parts.push(tool.toolName, tool.inputRaw, tool.inputText, tool.resultText);
  if (tool.diff !== null) {
    parts.push(tool.diff.filePath);
    for (let i = 0; i < tool.diff.segments.length; i++) {
      const segment = tool.diff.segments[i];
      parts.push(segment.label, segment.oldString, segment.newString);
    }
  }
  for (let i = 0; i < tool.media.length; i++) {
    parts.push(tool.media[i].originalName, tool.media[i].url);
  }
  for (let i = 0; i < tool.richMedia.length; i++) {
    parts.push(tool.richMedia[i].kind, tool.richMedia[i].title, tool.richMedia[i].url);
  }
}

function searchMessage(
  item: RenderMessageItem,
  itemKey: string,
  normalizedQuery: string,
): MessageSearchHit | null {
  const parts: string[] = [item.label, item.body];
  for (let i = 0; i < item.images.length; i++) {
    parts.push(item.images[i].originalName, item.images[i].url);
  }
  for (let i = 0; i < item.files.length; i++) {
    parts.push(item.files[i].name, item.files[i].originalName,
      item.files[i].path, item.files[i].url, item.files[i].mimeType);
  }
  if (item.message !== undefined && item.message.systemCardType.length > 0) {
    parts.push(item.message.systemCardType);
    try {
      parts.push(JSON.stringify(item.message.systemCardData));
    } catch (e) {
      // 损坏的系统卡数据不应让整个搜索失效。
    }
  }
  const identity = item.message === undefined
    ? item.key
    : (item.message.id.length > 0 ? item.message.id
      : (item.message.clientId.length > 0 ? item.message.clientId : item.key));
  return searchText(itemKey, identity, item.label, parts.join('\n'), normalizedQuery);
}

function searchToolGroup(
  item: RenderToolGroupItem,
  itemKey: string,
  normalizedQuery: string,
): MessageSearchHit | null {
  for (let i = 0; i < item.tools.length; i++) {
    const tool = item.tools[i];
    const parts: string[] = [];
    appendToolText(tool, parts);
    const sourceKey = tool.toolUseId.length > 0 ? tool.toolUseId : `${item.key}:${tool.seq}`;
    const hit = searchText(itemKey, sourceKey, tool.toolName, parts.join('\n'), normalizedQuery);
    if (hit !== null) return hit;
  }
  return null;
}

function searchAgentTask(
  item: RenderAgentTaskItem,
  itemKey: string,
  normalizedQuery: string,
): MessageSearchHit | null {
  const parts: string[] = [];
  if (item.tool !== null) appendToolText(item.tool, parts);
  if (item.update !== null) {
    const update = item.update;
    parts.push(update.title, update.description, update.summary, update.lastToolName,
      update.outputFile, update.taskType, update.workflowName, update.model);
    for (let i = 0; i < update.workflowProgress.length; i++) {
      const progress = update.workflowProgress[i];
      parts.push(progress.title, progress.label, progress.phaseTitle, progress.lastToolName,
        progress.lastToolSummary, progress.resultPreview, progress.promptPreview, progress.error);
    }
  }
  const sourceKey = item.update !== null && item.update.taskId.length > 0
    ? item.update.taskId
    : item.tool !== null && item.tool.toolUseId.length > 0 ? item.tool.toolUseId : item.key;
  return searchText(itemKey, sourceKey, 'agent_task', parts.join('\n'), normalizedQuery);
}

function searchItem(
  item: RenderItem,
  topLevelKey: string,
  normalizedQuery: string,
): MessageSearchHit | null {
  if (item.type === 'message') {
    return searchMessage(item as RenderMessageItem, topLevelKey, normalizedQuery);
  }
  if (item.type === 'thinking') {
    const thinking = item as RenderThinkingItem;
    return searchText(topLevelKey, item.key, 'thinking', `思考\n${thinking.body}`, normalizedQuery);
  }
  if (item.type === 'tool_group') {
    return searchToolGroup(item as RenderToolGroupItem, topLevelKey, normalizedQuery);
  }
  if (item.type === 'todo') {
    const todo = item as RenderTodoCardItem;
    const parts: string[] = [];
    for (let i = 0; i < todo.todos.length; i++) {
      parts.push(`${todo.todos[i].status} ${todo.todos[i].content}`);
    }
    return searchText(topLevelKey, item.key, 'todo', parts.join('\n'), normalizedQuery);
  }
  if (item.type === 'agent_task') {
    return searchAgentTask(item as RenderAgentTaskItem, topLevelKey, normalizedQuery);
  }
  // tool_media 是所属工具组的再呈现，重复索引会产生两条相同结果。
  if (item.type === 'tool_media') return null;
  if (item.type === 'work_group') {
    const children = (item as RenderWorkGroupItem).children;
    for (let i = 0; i < children.length; i++) {
      const hit = searchItem(children[i], topLevelKey, normalizedQuery);
      if (hit !== null) return hit;
    }
    return null;
  }
  if (item.type === 'subagent_group') {
    const group = item as RenderSubagentGroupItem;
    for (let i = 0; i < group.children.length; i++) {
      const hit = searchItem(group.children[i], topLevelKey, normalizedQuery);
      if (hit !== null) return hit;
    }
    const updateText = group.update === null ? ''
      : `${group.update.title}\n${group.update.description}\n${group.update.summary}`;
    return searchText(topLevelKey, item.key,
      group.subagentType.length > 0 ? group.subagentType : 'subagent',
      `${group.summary}\n${group.description}\n${updateText}`, normalizedQuery);
  }
  return null;
}

export function findMessageSearchHits(items: RenderItem[], query: string): MessageSearchHit[] {
  const normalizedQuery = normalizeMessageSearchText(query);
  if (normalizedQuery.length === 0) return [];
  const hits: MessageSearchHit[] = [];
  for (let i = 0; i < items.length; i++) {
    const hit = searchItem(items[i], items[i].key, normalizedQuery);
    if (hit !== null) hits.push(hit);
  }
  return hits;
}

export function messageSearchHitIndexBySource(
  hits: MessageSearchHit[], sourceKey: string,
): number {
  if (sourceKey.length === 0) return -1;
  for (let i = 0; i < hits.length; i++) {
    if (hits[i].sourceKey === sourceKey) return i;
  }
  return -1;
}

export function normalizeMessageSearchIndex(hitCount: number, currentIndex: number): number {
  if (hitCount <= 0) return -1;
  if (!Number.isFinite(currentIndex) || currentIndex < 0) return 0;
  return Math.min(currentIndex, hitCount - 1);
}

export function reconcileMessageSearchIndex(
  hits: MessageSearchHit[], currentIndex: number, sourceKey: string,
): number {
  const preserved = messageSearchHitIndexBySource(hits, sourceKey);
  return preserved >= 0 ? preserved : normalizeMessageSearchIndex(hits.length, currentIndex);
}

export function nextMessageSearchIndex(
  hitCount: number, currentIndex: number, delta: number,
): number {
  if (hitCount <= 0) return -1;
  const normalized = normalizeMessageSearchIndex(hitCount, currentIndex);
  let next = (normalized + delta) % hitCount;
  if (next < 0) next += hitCount;
  return next;
}

export function messageSearchPagingPresentation(
  query: string, hasMore: boolean, loading: boolean, hitCount: number,
): MessageSearchPagingPresentation {
  const out = new MessageSearchPagingPresentation();
  out.visible = normalizeMessageSearchText(query).length > 0 && hasMore;
  if (!out.visible) return out;
  out.enabled = !loading;
  out.label = loading ? '正在搜索更早消息…'
    : (hitCount > 0 ? '继续向前搜索' : '加载更早继续搜索');
  return out;
}
