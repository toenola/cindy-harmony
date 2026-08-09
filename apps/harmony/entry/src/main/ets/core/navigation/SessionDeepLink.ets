export class SessionDeepLinkIntent {
  sessionId: string = '';
  messageClientId: string = '';
}

export function parseSessionDeepLink(uri: string): SessionDeepLinkIntent | null {
  const match = uri.match(/^cindy:\/\/session\/([^\/?#]+)(?:\?([^#]*))?$/i);
  if (match === null) return null;
  const intent = new SessionDeepLinkIntent();
  intent.sessionId = safeDecode(match[1]);
  if (intent.sessionId.length === 0) return null;
  const query = match[2] ?? '';
  const pairs = query.length > 0 ? query.split('&') : [];
  for (let i = 0; i < pairs.length; i++) {
    const equal = pairs[i].indexOf('=');
    const rawKey = equal >= 0 ? pairs[i].slice(0, equal) : pairs[i];
    if (safeDecode(rawKey) !== 'message') continue;
    intent.messageClientId = safeDecode(equal >= 0 ? pairs[i].slice(equal + 1) : '');
    break;
  }
  return intent;
}

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value.replace(/\+/g, '%20'));
  } catch (e) {
    return '';
  }
}
