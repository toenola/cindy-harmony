/**
 * 工作过程收起态的纯展示投影。
 *
 * 页面只负责渲染这里产出的行；嵌套工作组展开、探索工具归类、重复读取收敛
 * 和摘要文案都集中在这里，避免继续堆进 TaskPage。
 */

import {
  RenderItem,
  RenderThinkingItem,
  RenderToolGroupItem,
  RenderToolItem,
  RenderWorkGroupItem,
  summarizeText,
} from './MessageRender';
import { ToolActionPresentation, projectToolUseActions } from './ToolUsePresentation';

export class WorkPreviewRow {
  key: string = '';
  kind: string = '';
  text: string = '';
  done: boolean = false;
  error: boolean = false;
  explorationKind: string = 'other';
  readKey: string = '';
  /** 活动收起态也要保留真实工具行，才能与完整工作组共享展开命令/结果状态。 */
  tool: RenderToolItem | null = null;
  action: ToolActionPresentation | null = null;
}

class WorkExplorationCount {
  reads: number = 0;
  searches: number = 0;
  lists: number = 0;
  unsupported: boolean = false;
}

function appendWorkPreviewRows(children: RenderItem[], rows: WorkPreviewRow[]): void {
  for (let i = 0; i < children.length; i++) {
    const child = children[i];
    if (child.type === 'work_group') {
      appendWorkPreviewRows((child as RenderWorkGroupItem).children, rows);
    } else if (child.type === 'thinking') {
      const thinking = child as RenderThinkingItem;
      const row = new WorkPreviewRow();
      row.key = child.key;
      row.kind = 'thinking';
      row.text = thinking.body.trim().length > 0
        ? summarizeText(thinking.body, 120)
        : '思考中…';
      rows.push(row);
    } else if (child.type === 'tool_group') {
      const tools = (child as RenderToolGroupItem).tools;
      for (let j = 0; j < tools.length; j++) {
        const tool = tools[j];
        const actions = projectToolUseActions(tool.toolName, tool.inputRaw, tool.inputText);
        for (let k = 0; k < actions.length; k++) {
          const action = actions[k];
          const row = new WorkPreviewRow();
          row.key = `${child.key}-${tool.seq}-action-${action.actionIndex}`;
          row.kind = 'tool';
          row.done = tool.hasResult;
          row.error = tool.hasError;
          row.text = action.label;
          row.explorationKind = action.explorationKind;
          row.readKey = action.readKey;
          row.tool = tool;
          row.action = action;
          rows.push(row);
        }
      }
    }
  }
}

/** limit <= 0 表示全部保留；同一探索段的重复读取只保留最后一次。 */
function dedupeWorkRowsFromTail(rawRows: WorkPreviewRow[], limit: number): WorkPreviewRow[] {
  const keptReversed: WorkPreviewRow[] = [];
  const seenReads = new Set<string>();
  // 与 shared recent projection 一致：从尾部保留同一探索段里最后一次读取。
  for (let i = rawRows.length - 1; i >= 0; i--) {
    const row = rawRows[i];
    if (row.kind === 'tool' && row.explorationKind === 'other') seenReads.clear();
    if (row.kind === 'tool' && row.explorationKind === 'read' && row.readKey.length > 0) {
      if (seenReads.has(row.readKey)) continue;
      seenReads.add(row.readKey);
    }
    keptReversed.push(row);
    if (limit > 0 && keptReversed.length === limit) break;
  }
  return keptReversed.reverse();
}

/** 活动态收起面板显示最近 5 条步骤，与 Mobile MAX_LIVE_WORK_ACTIVITIES 对齐。 */
export function workPreviewRows(item: RenderWorkGroupItem, limit: number = 5): WorkPreviewRow[] {
  const rawRows: WorkPreviewRow[] = [];
  appendWorkPreviewRows(item.children, rawRows);
  return dedupeWorkRowsFromTail(rawRows, limit);
}

/** 活动预览已经覆盖全部步骤时，展开不会增加信息，不再展示无效入口。 */
export function workGroupHasHiddenRows(item: RenderWorkGroupItem, limit: number = 5): boolean {
  if (!item.isStreaming) return true;
  const allRows = workPreviewRows(item, 0);
  return allRows.length > workPreviewRows(item, limit).length;
}

export function workExplorationSummary(item: RenderWorkGroupItem): string {
  const count = new WorkExplorationCount();
  const rows = workPreviewRows(item, 0);
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    if (row.kind !== 'tool') continue;
    if (row.explorationKind === 'read') count.reads += 1;
    else if (row.explorationKind === 'search') count.searches += 1;
    else if (row.explorationKind === 'list') count.lists += 1;
    else count.unsupported = true;
  }
  if (count.unsupported || count.reads + count.searches + count.lists === 0) return '';
  const parts: string[] = [];
  if (count.reads > 0) parts.push(`读取 ${count.reads} 个文件`);
  if (count.searches > 0) parts.push(`搜索 ${count.searches} 次`);
  if (count.lists > 0) parts.push(`列出 ${count.lists} 次`);
  return parts.join(' · ');
}
