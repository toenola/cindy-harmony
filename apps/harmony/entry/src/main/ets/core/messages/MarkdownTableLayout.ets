import { InlineToken } from './MarkdownParser';

const DEFAULT_MAX_COLUMN_WIDTH = 220;
const CELL_HORIZONTAL_PADDING = 20;
const TEXT_UNIT_WIDTH = 7.4;
const DEFAULT_IMAGE_INLINE_WIDTH = 150;

function isWideGlyph(value: string): boolean {
  return /[\u1100-\u11ff\u2e80-\u9fff\uf900-\ufaff\uff00-\uffef]/.test(value);
}

function estimateTextWidth(value: string): number {
  let units = 0;
  const chars = Array.from(value);
  for (let i = 0; i < chars.length; i++) {
    if (/\s/.test(chars[i])) units += 0.5;
    else if (isWideGlyph(chars[i])) units += 1.9;
    else units += 1;
  }
  return units * TEXT_UNIT_WIDTH;
}

function estimateInlineWidth(tokens: InlineToken[]): number {
  let total = 0;
  for (let i = 0; i < tokens.length; i++) {
    total += tokens[i].kind === 'image'
      ? (tokens[i].width > 0 ? tokens[i].width : DEFAULT_IMAGE_INLINE_WIDTH)
      : estimateTextWidth(tokens[i].value);
  }
  return total;
}

/** 短表填满正文，宽表保持内容宽度交给横向 Scroll，绝不压窄可读列。 */
export function buildMarkdownTableColumnWidths(
  header: InlineToken[][],
  rows: InlineToken[][][],
  minWidth: number,
  maxWidth: number = DEFAULT_MAX_COLUMN_WIDTH,
  availableWidth: number = 0,
): number[] {
  let columnCount = header.length;
  for (let i = 0; i < rows.length; i++) columnCount = Math.max(columnCount, rows[i].length);
  if (columnCount <= 0) return [];
  const normalizedMax = Math.max(minWidth, maxWidth);
  const widths: number[] = [];
  for (let column = 0; column < columnCount; column++) {
    let contentWidth = estimateInlineWidth(header[column] ?? []);
    for (let row = 0; row < rows.length; row++) {
      contentWidth = Math.max(contentWidth, estimateInlineWidth(rows[row][column] ?? []));
    }
    widths.push(Math.max(minWidth, Math.min(normalizedMax,
      Math.ceil(contentWidth + CELL_HORIZONTAL_PADDING))));
  }
  if (!Number.isFinite(availableWidth) || availableWidth <= 0) return widths.slice();
  let sum = 0;
  for (let i = 0; i < widths.length; i++) sum += widths[i];
  const remaining = Math.max(0, Math.floor(availableWidth) - sum);
  if (remaining <= 0) return widths.slice();
  const share = Math.floor(remaining / widths.length);
  const remainder = remaining % widths.length;
  const expanded: number[] = [];
  for (let i = 0; i < widths.length; i++) {
    expanded.push(widths[i] + share + (i < remainder ? 1 : 0));
  }
  return expanded;
}
