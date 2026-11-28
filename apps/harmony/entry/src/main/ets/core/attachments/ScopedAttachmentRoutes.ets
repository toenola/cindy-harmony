import { invokePhysicalPeerId } from '../device-link/InvokeScheduler';

export interface ScopedAttachmentRoute {
  current: () => boolean;
  upload: (uri: string, name: string, mime: string) => Promise<string>;
  fetch: (reference: string) => Promise<Object | undefined>;
  delete?: (key: string) => Promise<void>;
}
const routes: Map<string, ScopedAttachmentRoute> = new Map();
const uploads: Map<string, ScopedAttachmentRoute> = new Map();
export function registerScopedAttachments(peer: string, route: ScopedAttachmentRoute): () => void {
  if (invokePhysicalPeerId(peer) === peer || !route.current()) throw new Error('ACCESS_REVOKED');
  routes.set(peer, route);
  return (): void => {
    if (routes.get(peer) === route) routes.delete(peer);
    uploads.forEach((owner: ScopedAttachmentRoute, key: string): void => { if (owner === route) uploads.delete(key); });
  };
}
/** Only this process's successful upload receipt can nominate a cleanup authority. */
export function rememberScopedUpload(peer: string, key: string): void {
  const route = scopedAttachments(peer); if (!route) throw new Error('ACCESS_REVOKED');
  uploads.set(key, route);
  while (uploads.size > 512) { const first = uploads.keys().next(); if (first.done) break; uploads.delete(first.value); }
}
export async function deleteScopedUpload(key: string): Promise<void> {
  const route = uploads.get(key);
  if (!route?.current()) throw new Error('ACCESS_REVOKED');
  if (!route.delete) throw new Error('unsupported');
  await route.delete(key);
  if (uploads.get(key) !== route || !route.current()) throw new Error('ACCESS_REVOKED');
  uploads.delete(key);
}
/** Missing/revoked shared routes fail closed before ordinary same-account OSS can be used. */
export function scopedAttachments(peer: string): ScopedAttachmentRoute | null {
  if (invokePhysicalPeerId(peer) === peer) return null;
  const route = routes.get(peer);
  if (!route?.current()) throw new Error('ACCESS_REVOKED');
  return route;
}
