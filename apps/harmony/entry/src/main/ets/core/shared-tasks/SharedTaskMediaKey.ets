/**
 * Cleanup routing guard from agent-net-protocol@91179cedad, not media authorization.
 * All task-owned OSS keys (including an3-hex receipts) require task-scoped cleanup.
 * A raw agent-net-v3 receipt is also used by ordinary owner media: segment 3 is "-"
 * for owner, and a delegation grant id for scoped sharing. Never blanket-skip that prefix.
 * Malformed delegated-looking inputs are kept away from the owner cleanup path;
 * actual byte access/deletion must still use the current authority's full key parser.
 */
export function requiresScopedMediaCleanup(key: string): boolean {
  if (key.startsWith('cindy/device-link/shared-task/')) return true;
  if (!key.startsWith('agent-net-v3/')) return false;
  const parts = key.split('/');
  return parts.length > 3 && !!parts[3] && parts[3] !== '-';
}
