import {
  RenderItem,
  RenderSubagentGroupItem,
  RenderWorkGroupItem,
} from './MessageRender';

/**
 * 在当前渲染树中按稳定 key 查找 Subagent 工作组。
 *
 * 详情层只保存 key，不保存渲染对象引用；消息流刷新后再次从最新树查找，
 * 因而历史回放、实时更新和返回父任务共用同一份投影。
 */
export function findSubagentGroupByKey(
  items: RenderItem[],
  key: string,
): RenderSubagentGroupItem | null {
  if (key.length === 0) return null;
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (item.type === 'subagent_group') {
      const group = item as RenderSubagentGroupItem;
      if (group.key === key) return group;
      const nested = findSubagentGroupByKey(group.children, key);
      if (nested !== null) return nested;
    } else if (item.type === 'work_group') {
      const work = item as RenderWorkGroupItem;
      const nested = findSubagentGroupByKey(work.children, key);
      if (nested !== null) return nested;
    }
  }
  return null;
}

/** Subagent 的持久终态与 live 状态共用的用户可见标签。 */
export function subagentStatusLabel(status: string): string {
  if (status === 'failed') return '失败';
  if (status === 'stopped') return '已停止';
  if (status === 'running') return '正在协作';
  return '已完成';
}
