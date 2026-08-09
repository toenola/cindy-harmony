import { RemoteMessage, readStr } from '../tasks/TaskModels';

/** 一次历史上翻可以安全揭示的最近完整轮次。 */
export class HistoryTurnReveal {
  /** 本次应一次性 prepend 到可见消息窗的行。 */
  reveal: RemoteMessage[] = [];
  /** 已取回但属于更早轮次的行，留给下一次用户触发。 */
  buffered: RemoteMessage[] = [];
  /** 还没遇到顶层 user 边界，需要继续向前请求。 */
  needsOlderPage: boolean = false;
}

/**
 * shared render 的正常 turn 边界是 user。子 Agent 内层消息带 parentUuid，
 * 不能拿它提前截断顶层会话的历史分页。
 */
export function isTopLevelHistoryTurnBoundary(message: RemoteMessage): boolean {
  return message.role === 'user' && readStr(message.agentMeta, 'parentUuid').length === 0;
}

/**
 * buffer 为升序（旧 → 新）。只揭示离当前窗口最近的一轮：最后一个顶层 user
 * 到 buffer 末尾；更早的完整轮次继续留在 buffer。若权威历史已耗尽且始终没有
 * user，则把孤儿前导行作为兼容兜底一次性揭示，避免永久隐藏旧数据。
 */
export function revealNearestCompleteHistoryTurn(
  buffer: RemoteMessage[],
  sourceHasMore: boolean,
): HistoryTurnReveal {
  const result = new HistoryTurnReveal();
  let boundary = -1;
  for (let i = buffer.length - 1; i >= 0; i--) {
    if (isTopLevelHistoryTurnBoundary(buffer[i])) {
      boundary = i;
      break;
    }
  }
  if (boundary >= 0) {
    result.buffered = buffer.slice(0, boundary);
    result.reveal = buffer.slice(boundary);
    return result;
  }
  if (!sourceHasMore) {
    result.reveal = buffer.slice();
    return result;
  }
  result.buffered = buffer.slice();
  result.needsOlderPage = true;
  return result;
}
