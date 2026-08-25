/** 会话正文里的本地文件引用；语义对齐 Mobile splitChatPathLineSuffix。 */

export class FileReferenceLocation {
  path: string = '';
  line: number = 0;
  column: number = 0;
}

function isPositiveLocationPart(value: string): boolean {
  if (!/^[1-9]\d{0,6}$/.test(value)) return false;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0;
}

/**
 * 拆除 `path:line`、`path:line:column`、`path:start-end` 后缀。
 * 行列仅用于定位展示，读取与分享必须使用真实 path。
 */
export function splitFileReferenceLocation(raw: string): FileReferenceLocation {
  const out = new FileReferenceLocation();
  out.path = raw.trim();
  if (out.path.length === 0) return out;

  const lowered = out.path.toLowerCase();
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(out.path)
    && !lowered.startsWith('file://')) return out;

  const lastColon = out.path.lastIndexOf(':');
  if (lastColon <= 0) return out;
  const lastPart = out.path.slice(lastColon + 1);
  const beforeLast = out.path.slice(0, lastColon);

  const range = lastPart.match(/^([1-9]\d{0,6})-([1-9]\d{0,6})$/);
  if (range !== null) {
    const start = Number(range[1]);
    const end = Number(range[2]);
    if (Number.isSafeInteger(start) && Number.isSafeInteger(end) && end >= start) {
      out.path = beforeLast;
      out.line = start;
    }
    return out;
  }

  if (!isPositiveLocationPart(lastPart)) return out;
  const previousColon = beforeLast.lastIndexOf(':');
  const previousPart = previousColon >= 0 ? beforeLast.slice(previousColon + 1) : '';
  if (isPositiveLocationPart(previousPart)) {
    const base = beforeLast.slice(0, previousColon);
    if (base.length === 0) return out;
    out.path = base;
    out.line = Number(previousPart);
    out.column = Number(lastPart);
    return out;
  }

  out.path = beforeLast;
  out.line = Number(lastPart);
  return out;
}

/** 行列定位后缀不参与扩展名判断。 */
export function isTextFileReference(value: string): boolean {
  const normalized = splitFileReferenceLocation(value).path.replace(/\\/g, '/');
  const slash = normalized.lastIndexOf('/');
  const name = (slash >= 0 ? normalized.slice(slash + 1) : normalized).toLowerCase();
  if (['makefile', 'dockerfile', 'gemfile', 'rakefile', 'procfile', 'jenkinsfile'].includes(name)) {
    return true;
  }
  return /\.(?:txt|text|md|markdown|mdx|rst|log|diff|patch|csv|tsv|json|json5|jsonc|jsonl|ya?ml|toml|xml|ini|conf|cfg|properties|html?|css|scss|sass|less|svg|js|jsx|mjs|cjs|ts|tsx|ets|py|go|rs|java|kt|kts|swift|c|cc|cpp|cxx|h|hpp|cs|rb|php|sh|bash|zsh|fish|ps1|bat|cmd|sql|graphql|proto|gradle|cmake|mk|env)$/i.test(name);
}
