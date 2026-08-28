/**
 * Conservative bare HTTP(S) URL boundary handling for Markdown text.
 *
 * The shared TypeScript parser owns the full Unicode boundary contract.  This
 * ArkTS copy keeps the same user-visible rules needed by the native renderer:
 * punctuation and unmatched closing delimiters stay in surrounding prose,
 * while valid query/path punctuation remains part of the URL.
 */

const BARE_HTTP_URL_RE: RegExp = /^https?:\/\/[^\s<>"\u2013-\u2015\u2018-\u201F\u2022\u2026\u3000-\u3001\u3003\u3008-\u3011\u3014-\u301F\u3030\u303D\u30FB\uFE10-\uFE19\uFF01-\uFF0D\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF60\uFF62-\uFF65]+/i;

const PROSE_TRAILING_PUNCT: string[] = ['?', '!', '.', ',', ':', ';', '。', '，', '！', '？', '：', '；', '、', '…', '。'];
const MARKDOWN_TRAILING_PUNCT: string[] = ['*', '_', '~'];

function includesChar(chars: string[], value: string): boolean {
  for (let i = 0; i < chars.length; i++) {
    if (chars[i] === value) return true;
  }
  return false;
}
function isUnmatchedClosingParen(value: string, end: number): boolean {
  let open = 0;
  let close = 0;
  for (let i = 0; i < end; i++) {
    if (value[i] === '(') open += 1;
    else if (value[i] === ')') close += 1;
  }
  return close > open;
}

function isBoundaryBefore(value: string, index: number): boolean {
  if (index <= 0) return true;
  return !/[A-Za-z0-9_]/.test(value[index - 1]);
}

/** Return the URL prefix that should become a link token. */
export function clipBareHttpAutolinkText(raw: string): string {
  let end = raw.length;
  while (end > 0) {
    const last = raw[end - 1];
    if (includesChar(PROSE_TRAILING_PUNCT, last)
      || includesChar(MARKDOWN_TRAILING_PUNCT, last)) {
      end -= 1;
      continue;
    }
    if (last === ')' && isUnmatchedClosingParen(raw, end)) {
      end -= 1;
      continue;
    }
    if (last === '）' || last === '】' || last === '》' || last === '」' || last === '』') {
      end -= 1;
      continue;
    }
    break;
  }
  return raw.slice(0, end);
}

/**
 * Finds a bare URL only at the current parser cursor.  Returning the clipped
 * end lets the caller leave punctuation for the following plain-text token.
 */
export function findBareHttpAutolinkAt(
  text: string,
  cursor: number,
): string {
  if (cursor < 0 || cursor >= text.length || !isBoundaryBefore(text, cursor)) return '';
  const match = BARE_HTTP_URL_RE.exec(text.slice(cursor));
  if (match === null || match[0].length === 0) return '';
  return clipBareHttpAutolinkText(match[0]);
}
