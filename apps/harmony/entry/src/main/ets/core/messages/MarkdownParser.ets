/**
 * 轻量 Markdown 解析器（ArkTS）。
 *
 * 覆盖一期消息流需要的子集：
 * - 块级：标题、段落、有序/无序列表、引用、代码块（``` 围栏）、表格、分隔线
 * - 行内：`code`、**strong**、[text](url)
 *
 * 不做：嵌套列表、转义完整语义、执行型 HTML。渲染端按 MdBlock 结构逐块渲染。
 */

// ─── 行内 token ──────────────────────────────────────────────────────────────

/** 全局 token 序号：保证嵌套 ForEach（Text 内 Span）的 key 全局唯一。 */
let inlineSeq = 0;

export class InlineToken {
  seq: number = 0;
  kind: string = ''; // 'text' | 'code' | 'strong' | 'link' | 'image'
  value: string = '';
  url: string = '';
  width: number = 0;
  height: number = 0;
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

function findCodeClose(value: string, contentStart: number, runLength: number): number {
  const delimiter = '`'.repeat(runLength);
  let cursor = contentStart;
  while (cursor < value.length) {
    const close = value.indexOf(delimiter, cursor);
    if (close < 0) {
      return -1;
    }
    if (!isEscapedAt(value, close) && value[close - 1] !== '`' && value[close + runLength] !== '`') {
      return close;
    }
    cursor = close + runLength;
  }
  return -1;
}

function isBlockedImageScheme(url: string): boolean {
  return /^\s*(?:javascript|vbscript):/i.test(url);
}

/** 图片只能使用可被 Harmony 消费的协议，或绑定当前任务工作目录的路径。 */
function isSupportedImageSource(url: string): boolean {
  const value = url.trim();
  if (value.length === 0 || isBlockedImageScheme(value)) return false;
  if (/^data:image\//i.test(value)) return true;
  if (/^(?:https?|xdt-image|cindy-media|xdt-file|file|cindy-oss-attach|xdt-oss-attach):\/\//i.test(value)) {
    return true;
  }
  if (/^[A-Za-z]:[\\/]/.test(value) || value.startsWith('\\\\')) return true;
  return !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(value);
}

function normalizeImageScheme(url: string): string {
  return url.replace(
    /^(https?|data|xdt-image|cindy-media|xdt-file|file|cindy-oss-attach|xdt-oss-attach):/i,
    (scheme: string) => scheme.toLowerCase(),
  );
}

function findStrongClose(value: string, contentStart: number): number {
  let cursor = contentStart;
  while (cursor < value.length - 1) {
    const close = value.indexOf('**', cursor);
    if (close < 0) {
      return -1;
    }
    if (!isEscapedAt(value, close) && value[close - 1] !== '*' && value[close + 2] !== '*') {
      return close;
    }
    cursor = close + 2;
  }
  return -1;
}

/** 解析行内 token：`code`、**strong**、![image](url)、安全的 <img>、[text](url)。 */
export function tokenizeInline(text: string): InlineToken[] {
  const tokens: InlineToken[] = [];
  let plainStart = 0;
  let cursor = 0;

  const pushToken = (kind: string, value: string, url: string): void => {
    const token = new InlineToken();
    token.seq = inlineSeq;
    inlineSeq += 1;
    token.kind = kind;
    token.value = value;
    token.url = url;
    tokens.push(token);
  };

  const flushPlain = (end: number): void => {
    if (end > plainStart) {
      pushToken('text', text.slice(plainStart, end), '');
    }
  };

  while (cursor < text.length) {
    const ch = text[cursor];
    // 图片必须先于普通链接识别，否则 ![alt](url) 的 [alt](url) 子串会被吞成链接。
    if (ch === '!' && text[cursor + 1] === '[' && !isEscapedAt(text, cursor)) {
      const labelEnd = text.indexOf(']', cursor + 2);
      if (labelEnd > cursor + 2 && text[labelEnd + 1] === '(') {
        const urlEnd = text.indexOf(')', labelEnd + 2);
        if (urlEnd > labelEnd + 2) {
          const url = text.slice(labelEnd + 2, urlEnd).trim();
          if (url.length > 0 && isSupportedImageSource(url)) {
            flushPlain(cursor);
            pushToken('image', text.slice(cursor + 2, labelEnd), normalizeImageScheme(url));
            cursor = urlEnd + 1;
            plainStart = cursor;
            continue;
          }
        }
      }
    }
    // 只把单个 img 标签转换成图片 token；其它 HTML 保持字面文本，避免把任意
    // HTML 当成可执行/可交互内容。地址的实际可用性由详情页的媒体解析器校验。
    if (ch === '<' && !isEscapedAt(text, cursor)) {
      const tagMatch = /^<img(?=[\s/>])[^<>]*\/?>/i.exec(text.slice(cursor));
      if (tagMatch !== null) {
        const tag = tagMatch[0];
        const attrs = /([A-Za-z_:][A-Za-z0-9:._-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/g;
        let src = '';
        let alt = '';
        let width = 0;
        let height = 0;
        let attr = attrs.exec(tag);
        while (attr !== null) {
          const name = attr[1].toLowerCase();
          const value = attr[2] ?? attr[3] ?? attr[4] ?? '';
          if (name === 'src') src = value;
          else if (name === 'alt') alt = value;
          else if (name === 'width' && /^\d{1,4}$/.test(value)) width = Number(value);
          else if (name === 'height' && /^\d{1,4}$/.test(value)) height = Number(value);
          attr = attrs.exec(tag);
        }
        if (src.length > 0 && isSupportedImageSource(src)) {
          flushPlain(cursor);
          const token = new InlineToken();
          token.seq = inlineSeq;
          inlineSeq += 1;
          token.kind = 'image';
          token.value = alt;
          token.url = normalizeImageScheme(src);
          token.width = width;
          token.height = height;
          tokens.push(token);
          cursor += tag.length;
          plainStart = cursor;
          continue;
        }
      }
    }
    if (ch === '`' && !isEscapedAt(text, cursor)) {
      let runLength = 1;
      while (text[cursor + runLength] === '`') {
        runLength += 1;
      }
      const close = findCodeClose(text, cursor + runLength, runLength);
      if (close >= 0) {
        flushPlain(cursor);
        pushToken('code', text.slice(cursor + runLength, close).replace(/[\r\n]+/g, ' '), '');
        cursor = close + runLength;
        plainStart = cursor;
        continue;
      }
      cursor += runLength;
      continue;
    }
    if (ch === '*' && text[cursor + 1] === '*' && !isEscapedAt(text, cursor)) {
      const close = findStrongClose(text, cursor + 2);
      if (close >= 0) {
        flushPlain(cursor);
        pushToken('strong', text.slice(cursor + 2, close), '');
        cursor = close + 2;
        plainStart = cursor;
        continue;
      }
    }
    if (ch === '[' && !(cursor > 0 && text[cursor - 1] === '!' && !isEscapedAt(text, cursor - 1))) {
      const linkEnd = text.indexOf(']', cursor + 1);
      if (linkEnd > cursor + 1 && text[linkEnd + 1] === '(') {
        const parenEnd = text.indexOf(')', linkEnd + 2);
        if (parenEnd > linkEnd + 2) {
          const label = text.slice(cursor + 1, linkEnd);
          const url = text.slice(linkEnd + 2, parenEnd).trim();
          if (label.length > 0 && url.length > 0) {
            flushPlain(cursor);
            pushToken('link', label, url);
            cursor = parenEnd + 1;
            plainStart = cursor;
            continue;
          }
        }
      }
    }
    cursor += 1;
  }
  flushPlain(text.length);
  return tokens;
}

// ─── 块级解析 ────────────────────────────────────────────────────────────────

/** 全局块序号：保证不同消息的 mdBlocks 在嵌套 ForEach 里 key 全局唯一
 *  （否则每个消息的第一块都是 `${type}-0`，ArkUI ForEach key 冲突会跳过渲染）。 */
let mdSeq = 0;

export class MdBlock {
  type: string = ''; // heading | paragraph | list | quote | code | math | table | divider
  /** 块序号（ForEach key 用，避免同型同文块 key 重复）。 */
  seq: number = 0;
  level: number = 0;
  text: string = '';
  /** 文本块的行内结构；包含图片时由渲染端走富内容路径。 */
  inlineTokens: InlineToken[] = [];
  items: string[] = [];
  itemTokens: InlineToken[][] = [];
  ordered: boolean = false;
  lang: string = '';
  code: string = '';
  headers: string[] = [];
  headerTokens: InlineToken[][] = [];
  rows: string[][] = [];
  rowTokens: InlineToken[][][] = [];
}

function isTableSeparator(line: string): boolean {
  const trimmed = line.trim();
  if (trimmed.length === 0) {
    return false;
  }
  // 兼容带/不带首尾管道两种形态。
  let body = trimmed;
  if (body.startsWith('|')) body = body.slice(1);
  if (body.endsWith('|')) body = body.slice(0, -1);
  const cells = body.split('|');
  if (cells.length === 0) {
    return false;
  }
  for (let i = 0; i < cells.length; i++) {
    if (!/^:?-{1,}:?$/.test(cells[i].trim())) {
      return false;
    }
  }
  return true;
}

function splitTableRow(line: string): string[] {
  const trimmed = line.trim();
  let body = trimmed;
  if (body.startsWith('|')) body = body.slice(1);
  if (body.endsWith('|')) body = body.slice(0, -1);
  const cells = body.split('|');
  const out: string[] = [];
  for (let i = 0; i < cells.length; i++) {
    out.push(cells[i].trim());
  }
  return out;
}

/** 把 markdown 文本解析为块列表。 */
export function parseMarkdown(text: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  const lines = text.split('\n');

  const makeBlock = (): MdBlock => {
    const b = new MdBlock();
    b.seq = mdSeq;
    mdSeq += 1;
    return b;
  };

  let i = 0;
  while (i < lines.length) {
    const line = lines[i];

    // 只识别明确闭合的 display math；未闭合 $$ 保持普通正文。
    if (line.trim() === '$$') {
      let close = i + 1;
      while (close < lines.length && lines[close].trim() !== '$$') close += 1;
      if (close < lines.length) {
        const block = makeBlock();
        block.type = 'math';
        block.code = lines.slice(i + 1, close).join('\n');
        blocks.push(block);
        i = close + 1;
        continue;
      }
    }

    // 代码块
    const fence = /^```(\S*)\s*$/.exec(line);
    if (fence !== null) {
      const block = makeBlock();
      block.type = 'code';
      block.lang = fence[1];
      i += 1;
      const codeLines: string[] = [];
      while (i < lines.length && !/^```\s*$/.test(lines[i])) {
        codeLines.push(lines[i]);
        i += 1;
      }
      i += 1; // 跳过结束围栏
      block.code = codeLines.join('\n');
      blocks.push(block);
      continue;
    }

    // 表格：当前行含 |，下一行是分隔行
    if (line.includes('|') && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
      const block = makeBlock();
      block.type = 'table';
      block.headers = splitTableRow(line);
      for (let h = 0; h < block.headers.length; h++) {
        block.headerTokens.push(tokenizeInline(block.headers[h]));
      }
      i += 2;
      while (i < lines.length && lines[i].includes('|') && !isTableSeparator(lines[i])) {
        const row = splitTableRow(lines[i]);
        block.rows.push(row);
        const tokens: InlineToken[][] = [];
        for (let c = 0; c < row.length; c++) tokens.push(tokenizeInline(row[c]));
        block.rowTokens.push(tokens);
        i += 1;
      }
      blocks.push(block);
      continue;
    }

    // 标题
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading !== null) {
      const block = makeBlock();
      block.type = 'heading';
      block.level = heading[1].length;
      block.text = heading[2];
      block.inlineTokens = tokenizeInline(block.text);
      blocks.push(block);
      i += 1;
      continue;
    }

    // 引用
    if (line.trim().startsWith('>')) {
      const block = makeBlock();
      block.type = 'quote';
      const quoteLines: string[] = [];
      while (i < lines.length) {
        const t = lines[i].trim();
        if (t.startsWith('>')) {
          quoteLines.push(t.slice(1).trim());
          i += 1;
        } else {
          break;
        }
      }
      block.text = quoteLines.join(' ');
      block.inlineTokens = tokenizeInline(block.text);
      blocks.push(block);
      continue;
    }

    // 列表
    const ul = /^(\s*)[-*+]\s+(.*)$/.exec(line);
    const ol = /^(\s*)\d+[.)]\s+(.*)$/.exec(line);
    if (ul !== null || ol !== null) {
      const ordered = ol !== null;
      const block = makeBlock();
      block.type = 'list';
      block.ordered = ordered;
      while (i < lines.length) {
        const t = lines[i];
        const m = ordered ? /^(\s*)\d+[.)]\s+(.*)$/.exec(t) : /^(\s*)[-*+]\s+(.*)$/.exec(t);
        if (m !== null) {
          block.items.push(m[2]);
          block.itemTokens.push(tokenizeInline(m[2]));
          i += 1;
        } else if (t.trim().length === 0) {
          // 列表结束（空行分隔）；简单起见空行即止
          break;
        } else {
          break;
        }
      }
      blocks.push(block);
      continue;
    }

    // 分隔线
    if (/^\s*([-*_])\1{2,}\s*$/.test(line)) {
      const block = makeBlock();
      block.type = 'divider';
      blocks.push(block);
      i += 1;
      continue;
    }

    // 空行
    if (line.trim().length === 0) {
      i += 1;
      continue;
    }

    // 段落（连续非空行合并）
    const block = makeBlock();
    block.type = 'paragraph';
    const paraLines: string[] = [line.trim()];
    i += 1;
    while (i < lines.length) {
      const t = lines[i].trim();
      if (t.length === 0
        || /^(#{1,6})\s/.test(t)
        || /^```/.test(t)
        || t === '$$'
        || /^(\s*)[-*+]\s/.test(t)
        || /^(\s*)\d+[.)]\s/.test(t)
        || t.startsWith('>')
        || t.includes('|')
        || /^\s*([-*_])\1{2,}\s*$/.test(t)) {
        break;
      }
      paraLines.push(t);
      i += 1;
    }
    block.text = paraLines.join(' ');
    block.inlineTokens = tokenizeInline(block.text);
    blocks.push(block);
  }

  return blocks;
}
