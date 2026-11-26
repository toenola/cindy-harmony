// Minimal Web APIs used by the shared portable transport on Harmony's JS runtime.
if (typeof globalThis.TextEncoder !== 'function') globalThis.TextEncoder = class {
  encode(value = '') {
    const text = String(value), bytes = [];
    for (let i = 0; i < text.length; i++) {
      let cp = text.codePointAt(i);
      if (cp > 0xffff) i++;
      else if (cp >= 0xd800 && cp <= 0xdfff) cp = 0xfffd;
      if (cp <= 0x7f) bytes.push(cp);
      else if (cp <= 0x7ff) bytes.push(0xc0 | cp >> 6, 0x80 | cp & 63);
      else if (cp <= 0xffff) bytes.push(0xe0 | cp >> 12, 0x80 | cp >> 6 & 63, 0x80 | cp & 63);
      else bytes.push(0xf0 | cp >> 18, 0x80 | cp >> 12 & 63, 0x80 | cp >> 6 & 63, 0x80 | cp & 63);
    }
    return new Uint8Array(bytes);
  }
};
if (typeof globalThis.TextDecoder !== 'function') globalThis.TextDecoder = class {
  decode(input = new Uint8Array()) {
    const bytes = input instanceof ArrayBuffer ? new Uint8Array(input) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    return decodeURIComponent(Array.from(bytes, c => '%' + c.toString(16).padStart(2, '0')).join(''));
  }
};
if (typeof globalThis.performance === 'undefined') globalThis.performance = { now: () => Date.now() };
if (typeof globalThis.AbortController !== 'function') globalThis.AbortController = class {
  signal = { aborted: false, listeners: new Set(),
    addEventListener(name, fn) { if (name === 'abort') this.listeners.add(fn); },
    removeEventListener(name, fn) { this.listeners.delete(fn); } };
  abort() {
    if (this.signal.aborted) return;
    this.signal.aborted = true;
    this.signal.listeners.forEach(fn => fn());
    this.signal.listeners.clear();
  }
};
