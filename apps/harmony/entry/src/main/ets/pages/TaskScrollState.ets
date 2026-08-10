/** TaskPage 消息列表索引与贴底重试的纯逻辑。 */

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
 * presentationState 用于子 Agent 这类会把活动节点嵌套在普通对象里的容器。
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
  if (itemType === 'work_group') {
    return `${identity}:work:${isStreaming ? 'live' : 'done'}`;
  }
  if (presentationState.length > 0) {
    return `${identity}:state:${presentationState.length}:${presentationState}`;
  }
  return identity;
}
