/**
 * Tool result compaction marker compatibility.
 *
 * The host keeps the full result out of the message payload after compaction
 * and sends this small marker instead.  Harmony must render that marker as a
 * useful status row rather than exposing raw JSON or treating it as an error.
 */

export class ToolResultCompactionMarker {
  type: string = 'tool_result_compacted';
  version: number = 1;
  originalBytes: number = 0;
  compactedAt: number = 0;
}

export function parseToolResultCompactionMarker(
  content: Object | undefined,
): ToolResultCompactionMarker | null {
  let parsed: Object | undefined = content;
  if (typeof parsed === 'string') {
    if (!(parsed as string).includes('tool_result_compacted')) return null;
    try {
      parsed = JSON.parse(parsed as string) as Object;
    } catch (e) {
      return null;
    }
  }
  if (parsed === undefined || parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return null;
  }
  const record = parsed as Record<string, Object>;
  if (record['type'] !== 'tool_result_compacted'
    || record['version'] !== 1
    || typeof record['originalBytes'] !== 'number'
    || !Number.isFinite(record['originalBytes'] as number)
    || (record['originalBytes'] as number) < 0
    || typeof record['compactedAt'] !== 'number'
    || !Number.isFinite(record['compactedAt'] as number)
    || (record['compactedAt'] as number) < 0) {
    return null;
  }
  const marker = new ToolResultCompactionMarker();
  marker.originalBytes = record['originalBytes'] as number;
  marker.compactedAt = record['compactedAt'] as number;
  return marker;
}

export function formatToolResultCompactionBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '0 B';
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${kb < 10 ? kb.toFixed(1) : Math.round(kb)} KB`;
  const mb = kb / 1024;
  if (mb < 1024) return `${mb.toFixed(1)} MB`;
  return `${(mb / 1024).toFixed(1)} GB`;
}

export function toolResultCompactionPreview(content: Object | undefined): string {
  const marker = parseToolResultCompactionMarker(content);
  return marker === null
    ? ''
    : `工具输出已压缩（原始大小 ${formatToolResultCompactionBytes(marker.originalBytes)}）`;
}
