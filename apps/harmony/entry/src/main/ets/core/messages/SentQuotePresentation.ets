import { InlineToken, parseMarkdown, tokenizeInline } from './MarkdownParser';

const SENT_MESSAGE_CHIP_MAX_CHARS = 24;
const SENT_MESSAGE_CHIP_SOURCE_MAX = 2000;
const MAX_EMPHASIS_REPARSE_DEPTH = 4;
const RESIDUAL_IMAGE_MARKDOWN = /!\[([^\]\n]*)\]\([^)\n]*\)/g;
const RESIDUAL_MARKUP = /<img\b[^>\n]*>?|\b(?:cindy-media|cindy-oss-attach|xdt-[a-z0-9-]+):\/\/\S*|!\[/gi;
const CLUSTER_EXTEND = /^[\p{M}\u200D\uFE0E\uFE0F\u{1F3FB}-\u{1F3FF}\u{E0020}-\u{E007F}]$/u;
const REGIONAL_INDICATOR = /^[\u{1F1E6}-\u{1F1FF}]$/u;

function inlinesPlainText(tokens: InlineToken[], depth: number = 0): string {
  return tokens.map((token: InlineToken): string => {
    const nestedText = token.kind === 'strong' || token.kind === 'emphasis'
      || token.kind === 'strikethrough' || token.kind === 'link';
    return nestedText && depth < MAX_EMPHASIS_REPARSE_DEPTH
      ? inlinesPlainText(tokenizeInline(token.value), depth + 1) : token.value;
  }).join('');
}

function markdownPlainText(text: string): string {
  const parts: string[] = [];
  const blocks = parseMarkdown(text);
  for (let blockIndex = 0; blockIndex < blocks.length; blockIndex++) {
    const block = blocks[blockIndex];
    if (block.type === 'table') {
      for (let columnIndex = 0; columnIndex < block.headerTokens.length; columnIndex++) {
        parts.push(inlinesPlainText(block.headerTokens[columnIndex]));
      }
      for (let rowIndex = 0; rowIndex < block.rowTokens.length; rowIndex++) {
        const row = block.rowTokens[rowIndex];
        for (let columnIndex = 0; columnIndex < row.length; columnIndex++) {
          parts.push(inlinesPlainText(row[columnIndex]));
        }
      }
    } else if (block.type === 'list') {
      for (let itemIndex = 0; itemIndex < block.itemTokens.length; itemIndex++) {
        parts.push(inlinesPlainText(block.itemTokens[itemIndex]));
      }
    } else if (block.type === 'code' || block.type === 'math') {
      parts.push(block.code);
    } else {
      parts.push(inlinesPlainText(block.inlineTokens));
    }
  }
  return parts.join(' ');
}

function displayCharacters(text: string): string[] {
  const clusters: string[] = [];
  let joinNext = false;
  let regionalRun = 0;
  for (const codePoint of text) {
    const lastIndex = clusters.length - 1;
    const regional = REGIONAL_INDICATOR.test(codePoint);
    if (lastIndex >= 0 && (joinNext || CLUSTER_EXTEND.test(codePoint) || (regional && regionalRun % 2 === 1))) {
      clusters[lastIndex] += codePoint;
    } else {
      clusters.push(codePoint);
    }
    regionalRun = regional ? regionalRun + 1 : 0;
    joinNext = codePoint === '\u200D';
  }
  return clusters;
}

function chipSourcePrefix(text: string): string {
  if (text.length <= SENT_MESSAGE_CHIP_SOURCE_MAX) return text;
  const lineEnd = text.indexOf('\n', SENT_MESSAGE_CHIP_SOURCE_MAX);
  return lineEnd < 0 ? text : text.slice(0, lineEnd);
}

export function sentSessionMessageChipLabel(text: string): string {
  const compact = markdownPlainText(chipSourcePrefix(text))
    .replace(RESIDUAL_IMAGE_MARKDOWN, '$1').replace(RESIDUAL_MARKUP, '')
    .replace(/\s+/g, ' ').trim();
  const characters = displayCharacters(compact);
  return characters.length <= SENT_MESSAGE_CHIP_MAX_CHARS ? compact
    : characters.slice(0, SENT_MESSAGE_CHIP_MAX_CHARS - 1).join('').trimEnd() + '…';
}
