/**
 * 工作过程里的紧凑思考文本只支持 Mobile 已公开的两个行内标记：
 * `**strong**` 与匹配反引号数量的 code span。
 *
 * 这不是普通消息正文的完整 Markdown；未知、转义或未闭合的标记保持原文。
 */

let thinkingTokenSeq = 0;

export class ThinkingTextToken {
  seq: number = 0;
  kind: string = ''; // text | strong | code
  value: string = '';
}

function isEscapedAt(value: string, index: number): boolean {
  let backslashes = 0;
  let cursor = index - 1;
  while (cursor >= 0 && value[cursor] === '\\') {
    backslashes += 1;
    cursor -= 1;
  }
  return backslashes % 2 === 1;
}

function findStrongClose(value: string, contentStart: number): number {
  let cursor = contentStart;
  while (cursor < value.length - 1) {
    const close = value.indexOf('**', cursor);
    if (close < 0) return -1;
    const previous = value[close - 1];
    const after = value[close + 2];
    if (close > contentStart && !isEscapedAt(value, close)
      && previous !== '*' && !/\s/.test(previous) && after !== '*') return close;
    cursor = close + 2;
  }
  return -1;
}

function findCodeClose(value: string, contentStart: number, runLength: number): number {
  const delimiter = '`'.repeat(runLength);
  let cursor = contentStart;
  while (cursor < value.length) {
    const close = value.indexOf(delimiter, cursor);
    if (close < 0) return -1;
    if (!isEscapedAt(value, close) && value[close - 1] !== '`'
      && value[close + runLength] !== '`') return close;
    cursor = close + runLength;
  }
  return -1;
}

function normalizeCodeSpan(value: string): string {
  const singleLine = value.replace(/[\r\n]+/g, ' ');
  if (singleLine.length >= 2 && singleLine.startsWith(' ') && singleLine.endsWith(' ')
    && /\S/.test(singleLine)) return singleLine.slice(1, -1);
  return singleLine;
}

/** 解析紧凑思考文本；语义与 Mobile 的 tokenizeThinkingText 保持一致。 */
export function tokenizeThinkingText(value: string): ThinkingTextToken[] {
  const tokens: ThinkingTextToken[] = [];
  let plainStart = 0;
  let cursor = 0;

  const pushToken = (kind: string, tokenValue: string): void => {
    const token = new ThinkingTextToken();
    token.seq = thinkingTokenSeq;
    thinkingTokenSeq += 1;
    token.kind = kind;
    token.value = tokenValue;
    tokens.push(token);
  };
  const flushPlain = (end: number): void => {
    if (end > plainStart) pushToken('text', value.slice(plainStart, end));
  };

  while (cursor < value.length) {
    if (value[cursor] === '`' && !isEscapedAt(value, cursor)) {
      let runLength = 1;
      while (value[cursor + runLength] === '`') runLength += 1;
      const contentStart = cursor + runLength;
      const close = findCodeClose(value, contentStart, runLength);
      if (close >= 0) {
        flushPlain(cursor);
        pushToken('code', normalizeCodeSpan(value.slice(contentStart, close)));
        cursor = close + runLength;
        plainStart = cursor;
        continue;
      }
      cursor += runLength;
      continue;
    }

    if (value.startsWith('**', cursor) && !isEscapedAt(value, cursor)
      && value[cursor - 1] !== '*' && value[cursor + 2] !== '*'
      && value[cursor + 2] !== undefined && !/\s/.test(value[cursor + 2])) {
      const contentStart = cursor + 2;
      const close = findStrongClose(value, contentStart);
      if (close >= 0) {
        flushPlain(cursor);
        pushToken('strong', value.slice(contentStart, close));
        cursor = close + 2;
        plainStart = cursor;
        continue;
      }
      cursor += 2;
      continue;
    }
    cursor += 1;
  }

  flushPlain(value.length);
  return tokens;
}
