/** 仅帧体过大时降页；连接、权限等错误必须立即交给 UI。 */
export function isPayloadTooLargeError(error: Object): boolean {
  if (error !== null && typeof error === 'object') {
    const record = error as Record<string, Object>;
    if (record['code'] === 'PAYLOAD_TOO_LARGE') return true;
  }
  const message = error instanceof Error ? error.message : JSON.stringify(error);
  return message.indexOf('PAYLOAD_TOO_LARGE') >= 0 || /frame exceeds \d+ bytes/i.test(message);
}

export function historyRetryLimits(initial: number): number[] {
  const start = Math.max(1, Math.floor(initial));
  const out: number[] = [start];
  let current = start;
  while (current > 1) {
    if (current > 25) current = Math.floor(current / 2);
    else if (current > 10) current = 10;
    else if (current > 5) current = 5;
    else current = 1;
    if (out[out.length - 1] !== current) out.push(current);
  }
  return out;
}
