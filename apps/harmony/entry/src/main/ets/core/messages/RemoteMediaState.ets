/**
 * 历史媒体缩略图状态机。
 *
 * sourceKey 和 generation 共同隔离旧回调；原生 Image 在拿到 URL 后加载失败时
 * 只允许一次自动强刷，手动重试不受次数限制且总是强刷。
 */

export class RemoteMediaViewState {
  sourceKey: string = '';
  status: string = 'idle'; // idle | loading | ready | error
  resolvedUrl: string = '';
  generation: number = 0;
  autoForceRefreshUsed: boolean = false;
  error: string = '';
}

export class RemoteMediaResolveIntent {
  state: RemoteMediaViewState = new RemoteMediaViewState();
  generation: number = 0;
  forceRefresh: boolean = false;
  skipCache: boolean = false;
}

function copyState(value: RemoteMediaViewState | undefined): RemoteMediaViewState {
  const out = new RemoteMediaViewState();
  if (value === undefined) return out;
  out.sourceKey = value.sourceKey;
  out.status = value.status;
  out.resolvedUrl = value.resolvedUrl;
  out.generation = value.generation;
  out.autoForceRefreshUsed = value.autoForceRefreshUsed;
  out.error = value.error;
  return out;
}

export function beginRemoteMediaResolve(
  current: RemoteMediaViewState | undefined,
  sourceKey: string,
  forceRefresh: boolean = false,
  skipCache: boolean = false,
): RemoteMediaResolveIntent {
  const sourceChanged = current === undefined || current.sourceKey !== sourceKey;
  const next = sourceChanged ? new RemoteMediaViewState() : copyState(current);
  next.sourceKey = sourceKey;
  next.status = 'loading';
  next.resolvedUrl = '';
  next.error = '';
  next.generation = (current === undefined ? 0 : current.generation) + 1;
  if (sourceChanged) next.autoForceRefreshUsed = false;
  const intent = new RemoteMediaResolveIntent();
  intent.state = next;
  intent.generation = next.generation;
  intent.forceRefresh = forceRefresh;
  intent.skipCache = skipCache;
  return intent;
}

export function remoteMediaResolveReady(
  current: RemoteMediaViewState,
  generation: number,
  resolvedUrl: string,
): RemoteMediaViewState {
  if (current.generation !== generation || current.status !== 'loading') return current;
  const next = copyState(current);
  if (resolvedUrl.length === 0) {
    next.status = 'error';
    next.error = '媒体地址不可用';
    return next;
  }
  next.status = 'ready';
  next.resolvedUrl = resolvedUrl;
  next.error = '';
  return next;
}

export function remoteMediaResolveFailed(
  current: RemoteMediaViewState,
  generation: number,
  message: string,
): RemoteMediaViewState {
  if (current.generation !== generation || current.status !== 'loading') return current;
  const next = copyState(current);
  next.status = 'error';
  next.resolvedUrl = '';
  next.error = message.length > 0 ? message : '媒体加载失败';
  return next;
}

/** ready 后的原生 Image 错误：首次要求强刷，后续落入终态。 */
export function beginNativeMediaRecovery(current: RemoteMediaViewState): RemoteMediaResolveIntent | null {
  if (current.status !== 'ready' || current.autoForceRefreshUsed) return null;
  const intent = beginRemoteMediaResolve(current, current.sourceKey, true, true);
  intent.state.autoForceRefreshUsed = true;
  return intent;
}

export function failNativeMediaLoad(current: RemoteMediaViewState): RemoteMediaViewState {
  const next = copyState(current);
  next.status = 'error';
  next.resolvedUrl = '';
  next.error = '媒体加载失败';
  return next;
}

export function beginManualMediaRetry(current: RemoteMediaViewState): RemoteMediaResolveIntent {
  const intent = beginRemoteMediaResolve(current, current.sourceKey, true, true);
  intent.state.autoForceRefreshUsed = true;
  return intent;
}
