/**
 * Removes model-internal transport markers at the Harmony presentation
 * boundary.  This mirrors maker-shared/internalCitation.ts without coupling
 * the ArkTS target to the TypeScript workspace package.
 */

const MODEL_STOP_TOKENS: string[] = ['<|endoftext|>', '<|eot_id|>', '<|im_end|>', '<|eos|>'];
const LONGEST_MODEL_STOP_TOKEN: number = 13;
const WEB_CITATION_OPEN: string = '\uE200cite\uE202';
const WEB_CITATION_CLOSE: string = '\uE201';

class ConsumedStopControl {
  remainder: string = '';
  consumedToken: boolean = false;
}

function matchStopTokenAt(text: string, index: number): string {
  for (let i = 0; i < MODEL_STOP_TOKENS.length; i++) {
    const token = MODEL_STOP_TOKENS[i];
    if (text.slice(index, index + token.length) === token) return token;
  }
  return '';
}

function consumeLeadingStopControl(text: string): ConsumedStopControl {
  let index = 0;
  let consumedToken = false;
  while (index < text.length) {
    if (text[index].trim().length === 0) {
      index += 1;
      continue;
    }
    const token = matchStopTokenAt(text, index);
    if (token.length === 0) break;
    consumedToken = true;
    index += token.length;
  }
  const result = new ConsumedStopControl();
  result.remainder = text.slice(index);
  result.consumedToken = consumedToken;
  return result;
}

function isIncompleteStopTokenPrefix(text: string): boolean {
  if (text.length === 0 || text.length > LONGEST_MODEL_STOP_TOKEN) return false;
  for (let i = 0; i < MODEL_STOP_TOKENS.length; i++) {
    if (MODEL_STOP_TOKENS[i].slice(0, text.length) === text) return true;
  }
  return false;
}

function isPossibleStandaloneStopPrefix(text: string): boolean {
  const consumed = consumeLeadingStopControl(text);
  return consumed.remainder.length === 0 || isIncompleteStopTokenPrefix(consumed.remainder);
}

function partialWebCitationPrefixStart(text: string): number {
  const maxProbe = Math.min(text.length, WEB_CITATION_OPEN.length - 1);
  for (let length = maxProbe; length > 0; length -= 1) {
    if (text.slice(text.length - length) === WEB_CITATION_OPEN.slice(0, length)) {
      return text.length - length;
    }
  }
  return text.length;
}

function stableCitationBoundary(text: string): number {
  let from = 0;
  while (true) {
    const open = text.indexOf(WEB_CITATION_OPEN, from);
    if (open < 0) return partialWebCitationPrefixStart(text);
    const close = text.indexOf(WEB_CITATION_CLOSE, open + WEB_CITATION_OPEN.length);
    if (close < 0) return open;
    from = close + WEB_CITATION_CLOSE.length;
  }
}

function stripInternalWebCitationMarkers(text: string): string {
  if (text.indexOf('\uE200') < 0) return text;
  const stableEnd = stableCitationBoundary(text);
  const stable = text.slice(0, stableEnd);
  let output = '';
  let from = 0;
  while (true) {
    const open = stable.indexOf(WEB_CITATION_OPEN, from);
    if (open < 0) return output + stable.slice(from);
    const close = stable.indexOf(WEB_CITATION_CLOSE, open + WEB_CITATION_OPEN.length);
    if (close < 0) return output + stable.slice(from, open);
    output += stable.slice(from, open);
    from = close + WEB_CITATION_CLOSE.length;
  }
}

/** Completed snapshots only drop a stop-token run when no prose remains. */
export function stripStandaloneModelStopToken(text: string): string {
  const consumed = consumeLeadingStopControl(text);
  return consumed.consumedToken && consumed.remainder.length === 0 ? '' : text;
}

/**
 * Clean a complete or currently rendered streaming snapshot.  The raw stream
 * remains untouched in MessageStore so a split marker can still be resolved;
 * only the user-facing projection is sanitized here.
 */
export function sanitizeInternalOutput(text: string): string {
  return stripStandaloneModelStopToken(stripInternalWebCitationMarkers(text));
}

/** Streaming projection variant: hold a split, control-only stop prefix. */
export function sanitizeStreamingOutput(text: string): string {
  if (isPossibleStandaloneStopPrefix(text)) return '';
  return sanitizeInternalOutput(text);
}
