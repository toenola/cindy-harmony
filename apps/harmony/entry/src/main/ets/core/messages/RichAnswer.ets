/**
 * `cindy-ui` 富组件回答协议（ArkTS 移植）。
 *
 * 行为事实源：`packages/maker-shared/src/richAnswer.ts`、`richAnswerVisual.ts`、`youtubeVideo.ts`。
 * 只做声明式解析：不执行代码、不发起 I/O；数量、深度与体积上限与共享实现一致。
 * 偏离点：JSON `null` 属性值按缺省处理（ArkTS 记录不承载 null）；数字刻度不加千分位。
 */

export const RICH_ANSWER_LANGUAGE = 'cindy-ui';
export const RICH_ANSWER_KINDS: string[] = [
  'text', 'markdown', 'heading', 'icon', 'stack', 'row', 'grid', 'group', 'divider',
  'image', 'video', 'audio', 'code', 'math', 'diagram', 'stat', 'chart', 'svg',
  'range', 'input', 'check', 'select', 'button', 'form', 'details', 'tabs',
];
export const RICH_CONTAINER_KINDS: string[] = ['stack', 'row', 'grid', 'group', 'form', 'details', 'tabs'];
const APPENDABLE_KINDS: string[] = ['text', 'markdown', 'heading', 'code', 'math', 'diagram'];
const CONTROL_KINDS: string[] = ['input', 'range', 'select', 'check', 'tabs', 'details'];
export const RICH_COLOR_ROLES: string[] = ['primary', 'secondary', 'tertiary', 'success', 'warning', 'danger'];

export type RichValue = string | number | boolean;
/** 绑定值与计算节点值；`undefined` 表示「不可用」，绝不当作 0。 */
export type RichValues = Map<string, RichValue | undefined>;

const ID = /^[a-zA-Z0-9_-]{1,80}$/;
const MAX_SOURCE = 2000000;
const MAX_NODES = 2048;
export const RICH_MAX_DEPTH = 32;
const MAX_PROPS = 65536;

export class RichNode {
  id: string = '';
  kind: string = '';
  props: Record<string, Object> = {};
  children: string[] = [];
}

export class RichDocument {
  nodes: Map<string, RichNode> = new Map();
  roots: string[] = [];
  /** 子节点 → 父节点；渲染端继承文字样式与判断排布方向用。 */
  parents: Map<string, string> = new Map();
  revision: number = 0;
  issues: number = 0;
}

export class RichPart {
  kind: string = 'markdown'; // markdown | rich
  key: number = 0;
  source: string = '';
  complete: boolean = false;
}

export function richIsRecord(value: Object | undefined | null): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function asRecord(value: Object | undefined | null): Record<string, Object> {
  return richIsRecord(value) ? value as Record<string, Object> : {};
}

export function richIsValue(value: Object | undefined | null): boolean {
  return typeof value === 'string' || typeof value === 'boolean'
    || (typeof value === 'number' && Number.isFinite(value));
}

function hasKey(record: Record<string, Object>, key: string): boolean {
  return Object.keys(record).includes(key);
}

// ─── 围栏切分 ────────────────────────────────────────────────────────────────

class FenceState {
  char: string = '';
  count: number = 0;
  rich: boolean = false;
}

function makePart(kind: string, key: number, source: string, complete: boolean): RichPart {
  const part = new RichPart();
  part.kind = kind;
  part.key = key;
  part.source = source;
  part.complete = complete;
  return part;
}

/** 只切分显式的回答围栏；其它围栏内的 `cindy-ui` 示例保持原样。 */
export function splitRichAnswer(source: string): RichPart[] {
  const parts: RichPart[] = [];
  let cursor = 0;
  let start = 0;
  let richStart = -1;
  let fence: FenceState | null = null;
  while (cursor < source.length) {
    const newline = source.indexOf('\n', cursor);
    const lineEnd = newline === -1 ? source.length : newline + 1;
    const line = source.slice(cursor, lineEnd);
    const body = line.replace(/\r?\n$/, '');
    if (fence === null) {
      const open = body.match(/^ {0,3}(`{3,}|~{3,})([^\r\n]*)$/);
      if (open !== null) {
        const next = new FenceState();
        next.char = open[1].charAt(0);
        next.count = open[1].length;
        next.rich = open[2].trim() === RICH_ANSWER_LANGUAGE;
        fence = next;
        if (next.rich) {
          if (cursor > start) parts.push(makePart('markdown', start, source.slice(start, cursor), true));
          richStart = cursor;
          start = cursor + line.length;
        }
      }
    } else if (new RegExp(`^ {0,3}${fence.char}{${fence.count},}\\s*$`).test(body)) {
      if (fence.rich && richStart >= 0) {
        parts.push(makePart('rich', richStart, source.slice(start, cursor), true));
        start = cursor + line.length;
        richStart = -1;
      }
      fence = null;
    }
    cursor = lineEnd;
  }
  if (richStart >= 0) {
    parts.push(makePart('rich', richStart, source.slice(start), false));
  } else if (start < source.length) {
    parts.push(makePart('markdown', start, source.slice(start), false));
  }
  return parts;
}

export function hasRichAnswer(source: string): boolean {
  if (source.indexOf(RICH_ANSWER_LANGUAGE) === -1) return false;
  const parts = splitRichAnswer(source);
  for (let i = 0; i < parts.length; i++) {
    if (parts[i].kind === 'rich') return true;
  }
  return false;
}

// ─── 增量解析 ────────────────────────────────────────────────────────────────

function cloneNode(node: RichNode): RichNode {
  const copy = new RichNode();
  copy.id = node.id;
  copy.kind = node.kind;
  copy.props = node.props;
  copy.children = node.children;
  return copy;
}

function mergeProps(base: Record<string, Object>, patch: Record<string, Object>): Record<string, Object> {
  const merged: Record<string, Object> = {};
  Object.keys(base).forEach((key: string) => { merged[key] = base[key]; });
  Object.keys(patch).forEach((key: string) => { merged[key] = patch[key]; });
  return merged;
}

/** 每个回答片段一个实例；快照修正时重建，只追加的增量只解析一次。 */
export class RichAnswerStream {
  private source: string = '';
  private offset: number = 0;
  private seq: number = 0;
  private nodes: Map<string, RichNode> = new Map();
  private roots: string[] = [];
  private revision: number = 0;
  private issues: number = 0;

  update(source: string, complete: boolean = false): RichDocument {
    if (!source.startsWith(this.source)) {
      this.source = '';
      this.offset = 0;
      this.seq = 0;
      this.nodes = new Map();
      this.roots = [];
      this.issues = 0;
      this.revision++;
    }
    if (source.length > MAX_SOURCE) {
      this.issues = Math.max(1, this.issues);
      return this.snapshot();
    }
    this.source = source;
    let end = source.indexOf('\n', this.offset);
    while (end !== -1) {
      this.line(source.slice(this.offset, end));
      this.offset = end + 1;
      end = source.indexOf('\n', this.offset);
    }
    if (complete && this.offset < source.length) {
      this.line(source.slice(this.offset));
      this.offset = source.length;
    }
    return this.snapshot();
  }

  private snapshot(): RichDocument {
    const doc = new RichDocument();
    doc.nodes = new Map(this.nodes);
    doc.roots = this.roots.slice();
    this.nodes.forEach((node: RichNode) => {
      node.children.forEach((child: string) => { doc.parents.set(child, node.id); });
    });
    doc.revision = this.revision;
    doc.issues = this.issues;
    return doc;
  }

  private line(line: string): void {
    if (line.trim().length === 0) return;
    try {
      if (this.apply(JSON.parse(line) as Object)) this.revision++;
    } catch (_error) {
      this.issues++;
    }
  }

  /** 返回 false 表示已应用过的重放行（静默跳过，不计入问题）。 */
  private apply(raw: Object): boolean {
    if (!richIsRecord(raw)) throw new Error('sequence');
    const op = raw as Record<string, Object>;
    const seqValue = op['seq'];
    if (typeof seqValue !== 'number' || !Number.isSafeInteger(seqValue) || seqValue < 1) {
      throw new Error('sequence');
    }
    const seq = seqValue as number;
    if (seq <= this.seq) return false;
    if (seq !== this.seq + 1) throw new Error('gap');
    this.seq = seq;
    if (hasKey(op, 'version') && op['version'] !== 1) throw new Error('version');
    const idValue = op['id'];
    if (typeof idValue !== 'string' || !ID.test(idValue)) throw new Error('id');
    const id = idValue as string;
    const current = this.nodes.get(id);
    const props = this.props(op['props']);
    // 部分真实输出把 style 放在 props 旁边，这里统一归一一次。
    if (richIsRecord(op['style']) && !hasKey(props, 'style')) props['style'] = this.props(op['style']);
    const kind = op['op'];
    if (kind === 'create') this.create(op, id, current, props);
    else if (kind === 'append') this.append(op, current);
    else if (kind === 'patch') {
      if (current === undefined) throw new Error('target');
      const next = cloneNode(current);
      next.props = mergeProps(current.props, props);
      this.nodes.set(id, next);
    } else if (kind === 'remove') this.remove(current);
    else if (kind === 'move') this.move(op, current);
    else throw new Error('operation');
    return true;
  }

  private create(op: Record<string, Object>, id: string, current: RichNode | undefined,
    props: Record<string, Object>): void {
    const kindValue = op['kind'];
    if (current !== undefined || this.nodes.size >= MAX_NODES
      || typeof kindValue !== 'string' || !RICH_ANSWER_KINDS.includes(kindValue as string)) {
      throw new Error('component');
    }
    const parentRef = op['parent'];
    const rootParent = parentRef === undefined || parentRef === 'root';
    const parent = rootParent ? undefined : this.nodes.get(String(parentRef));
    if (!rootParent && parent === undefined) throw new Error('parent');
    if (parent !== undefined && !RICH_CONTAINER_KINDS.includes(parent.kind)) throw new Error('leaf');
    if (parent !== undefined && this.depth(parent.id) >= RICH_MAX_DEPTH) throw new Error('depth');
    const node = new RichNode();
    node.id = id;
    node.kind = kindValue as string;
    node.props = props;
    this.nodes.set(id, node);
    const index = this.insertIndex(op['index']);
    if (parent !== undefined) {
      const next = cloneNode(parent);
      next.children = parent.children.slice();
      next.children.splice(index, 0, id);
      this.nodes.set(parent.id, next);
    } else {
      this.roots = this.roots.slice();
      this.roots.splice(index, 0, id);
    }
  }

  private append(op: Record<string, Object>, current: RichNode | undefined): void {
    const text = op['text'];
    if (current === undefined || !APPENDABLE_KINDS.includes(current.kind) || typeof text !== 'string') {
      throw new Error('text');
    }
    const next = cloneNode(current);
    const patch: Record<string, Object> = {};
    patch['text'] = richString(current, 'text') + (text as string);
    next.props = mergeProps(current.props, patch);
    this.nodes.set(current.id, next);
  }

  private remove(current: RichNode | undefined): void {
    if (current === undefined) throw new Error('target');
    const removeTree = (nodeId: string): void => {
      const node = this.nodes.get(nodeId);
      if (node !== undefined) node.children.forEach((child: string) => removeTree(child));
      this.nodes.delete(nodeId);
    };
    removeTree(current.id);
    this.detach(current.id);
  }

  private move(op: Record<string, Object>, current: RichNode | undefined): void {
    if (current === undefined) throw new Error('target');
    const parentRef = op['parent'];
    const parent = parentRef === 'root' ? undefined : this.nodes.get(String(parentRef));
    if (parentRef !== 'root' && parent === undefined) throw new Error('parent');
    if (parent !== undefined
      && (!RICH_CONTAINER_KINDS.includes(parent.kind) || this.descendant(current.id, parent.id))) {
      throw new Error('cycle');
    }
    if ((parent !== undefined ? this.depth(parent.id) : 0) + this.height(current.id) > RICH_MAX_DEPTH) {
      throw new Error('depth');
    }
    this.detach(current.id);
    const index = this.insertIndex(op['index']);
    if (parent !== undefined) {
      const latest = this.nodes.get(parent.id) as RichNode;
      const next = cloneNode(latest);
      next.children = latest.children.slice();
      next.children.splice(index, 0, current.id);
      this.nodes.set(latest.id, next);
    } else {
      this.roots = this.roots.slice();
      this.roots.splice(index, 0, current.id);
    }
  }

  private detach(id: string): void {
    this.roots = this.roots.filter((root: string) => root !== id);
    const owners: RichNode[] = [];
    this.nodes.forEach((node: RichNode) => {
      if (node.children.includes(id)) owners.push(node);
    });
    owners.forEach((node: RichNode) => {
      const next = cloneNode(node);
      next.children = node.children.filter((child: string) => child !== id);
      this.nodes.set(node.id, next);
    });
  }

  private insertIndex(value: Object | undefined): number {
    return typeof value === 'number' && Number.isInteger(value)
      ? Math.max(0, value as number) : Number.MAX_SAFE_INTEGER;
  }

  private props(value: Object | undefined): Record<string, Object> {
    if (value === undefined) return {};
    if (!richIsRecord(value) || JSON.stringify(value).length > MAX_PROPS) throw new Error('props');
    const source = value as Record<string, Object>;
    const out: Record<string, Object> = {};
    Object.keys(source).forEach((key: string) => {
      if (key === '__proto__' || key === 'constructor' || key === 'prototype') return;
      const item = source[key];
      if (item !== undefined && item !== null) out[key] = item;
    });
    return out;
  }

  private descendant(root: string, id: string): boolean {
    if (root === id) return true;
    const node = this.nodes.get(root);
    if (node === undefined) return false;
    for (let i = 0; i < node.children.length; i++) {
      if (this.descendant(node.children[i], id)) return true;
    }
    return false;
  }

  private height(id: string): number {
    const node = this.nodes.get(id);
    let tallest = 0;
    if (node !== undefined) {
      for (let i = 0; i < node.children.length; i++) tallest = Math.max(tallest, this.height(node.children[i]));
    }
    return 1 + tallest;
  }

  private depth(id: string): number {
    let owner: RichNode | undefined = undefined;
    this.nodes.forEach((node: RichNode) => {
      if (owner === undefined && node.children.includes(id)) owner = node;
    });
    return owner === undefined ? 1 : 1 + this.depth((owner as RichNode).id);
  }
}

// ─── 属性读取 ────────────────────────────────────────────────────────────────

export function richString(node: RichNode, key: string, fallback: string = ''): string {
  const value = node.props[key];
  return typeof value === 'string' ? value as string : fallback;
}

export function richNumber(node: RichNode, key: string, fallback: number): number {
  const value = node.props[key];
  return typeof value === 'number' && Number.isFinite(value) ? value as number : fallback;
}

export class RichOption {
  label: string = '';
  value: string = '';
}

export function richOptions(node: RichNode): RichOption[] {
  const raw = node.props['options'];
  if (!Array.isArray(raw)) return [];
  const out: RichOption[] = [];
  const list = raw as Object[];
  for (let i = 0; i < list.length && i < 100; i++) {
    if (!richIsRecord(list[i])) continue;
    const item = list[i] as Record<string, Object>;
    if (typeof item['label'] !== 'string' || typeof item['value'] !== 'string') continue;
    const option = new RichOption();
    option.label = item['label'] as string;
    option.value = item['value'] as string;
    out.push(option);
  }
  return out;
}

export function richBind(node: RichNode): string {
  return richString(node, 'bind', node.id);
}

export function richDefaults(doc: RichDocument): Map<string, RichValue> {
  const out: Map<string, RichValue> = new Map();
  doc.nodes.forEach((node: RichNode) => {
    if (!CONTROL_KINDS.includes(node.kind)) return;
    const preset = node.props['default'];
    let value: RichValue = '';
    if (richIsValue(preset)) value = preset as RichValue;
    else if (node.kind === 'check' || node.kind === 'details') value = false;
    else if (node.kind === 'range') value = richNumber(node, 'min', 0);
    out.set(richBind(node), value);
  });
  return out;
}

/** 从同一份文档快照解析输入与计算节点；支持前向引用，循环与缺失值保持不可用。 */
export function richResolvedValues(doc: RichDocument, edited?: Map<string, RichValue>): RichValues {
  const values: RichValues = new Map();
  richDefaults(doc).forEach((value: RichValue, key: string) => { values.set(key, value); });
  if (edited !== undefined) edited.forEach((value: RichValue, key: string) => { values.set(key, value); });
  const visiting: Set<string> = new Set();
  const resolve = (id: string): RichValue | undefined => {
    if (values.has(id)) return values.get(id);
    if (visiting.has(id) || visiting.size >= RICH_MAX_DEPTH) return undefined;
    const node = doc.nodes.get(id);
    if (node === undefined || (node.kind !== 'stat' && node.kind !== 'text' && node.kind !== 'heading')) {
      return undefined;
    }
    visiting.add(id);
    const expr = node.props['value'] !== undefined ? node.props['value'] : node.props['text'];
    const result = richEvaluate(expr, values, 0, resolve);
    visiting.delete(id);
    values.set(id, result);
    return result;
  };
  doc.nodes.forEach((node: RichNode) => { resolve(node.id); });
  return values;
}

/** 白名单算术，绝不执行 JavaScript；不可用的值不会被强转成 0。 */
export function richEvaluate(expr: Object | undefined | null, values: RichValues, depth: number = 0,
  resolve?: (id: string) => RichValue | undefined): RichValue | undefined {
  if (expr === undefined || expr === null) return undefined;
  if (richIsValue(expr)) return expr as RichValue;
  if (!richIsRecord(expr) || depth > 16) return undefined;
  const record = expr as Record<string, Object>;
  const ref = record['ref'];
  if (typeof ref === 'string') {
    const key = ref as string;
    if (values.has(key)) return values.get(key);
    return resolve !== undefined ? resolve(key) : undefined;
  }
  const rawArgs = record['args'];
  if (!Array.isArray(rawArgs) || (rawArgs as Object[]).length > 32) return undefined;
  const argList = rawArgs as Object[];
  const op = String(record['op']);
  const evaluate = (item: Object): RichValue | undefined => richEvaluate(item, values, depth + 1, resolve);
  // 只计算被选中的分支：未使用的前向引用无害。
  if (op === 'if') {
    if (argList.length !== 3) return undefined;
    const condition = evaluate(argList[0]);
    if (condition === undefined) return undefined;
    return evaluate(condition ? argList[1] : argList[2]);
  }
  const args: RichValue[] = [];
  for (let i = 0; i < argList.length; i++) {
    const result = evaluate(argList[i]);
    if (result === undefined) return undefined;
    args.push(result);
  }
  if (op === 'concat') {
    let size = 0;
    for (let i = 0; i < args.length; i++) size += String(args[i]).length;
    if (size > MAX_PROPS) return undefined;
    return args.map((arg: RichValue) => String(arg)).join('');
  }
  if (['eq', 'lt', 'gt', 'sub', 'div'].includes(op) && args.length !== 2) return undefined;
  if (op === 'eq') return args[0] === args[1];
  if (args.length === 0) return undefined;
  for (let i = 0; i < args.length; i++) {
    if (typeof args[i] === 'string' && (args[i] as string).trim().length === 0) return undefined;
  }
  const nums = args.map((arg: RichValue) => Number(arg));
  for (let i = 0; i < nums.length; i++) {
    if (!Number.isFinite(nums[i])) return undefined;
  }
  let result = 0;
  if (op === 'add') result = nums.reduce((a: number, b: number) => a + b, 0);
  else if (op === 'mul') result = nums.reduce((a: number, b: number) => a * b, 1);
  else if (op === 'sub') result = nums[0] - nums[1];
  else if (op === 'div') result = nums[0] / nums[1];
  else if (op === 'min') result = Math.min(...nums);
  else if (op === 'max') result = Math.max(...nums);
  else if (op === 'lt') return nums[0] < nums[1];
  else if (op === 'gt') return nums[0] > nums[1];
  else return undefined;
  return Number.isFinite(result) ? result : undefined;
}

function nodeExpression(node: RichNode): Object {
  if (node.props['value'] !== undefined) return node.props['value'];
  if (node.props['text'] !== undefined) return node.props['text'];
  return '';
}

export function richValue(node: RichNode, values: RichValues): RichValue | undefined {
  return richEvaluate(nodeExpression(node), values);
}

export function richLabel(node: RichNode, values: RichValues): string {
  const result = richValue(node, values);
  return result === undefined
    ? '—' : richString(node, 'prefix') + String(result) + richString(node, 'suffix');
}

/** 组件内的计算不可用提示；不影响其它正文与控件。 */
export function richCalculationUnavailable(node: RichNode, values: RichValues): boolean {
  if (node.kind === 'stat' || node.kind === 'text' || node.kind === 'heading') {
    return richValue(node, values) === undefined;
  }
  const data = node.props['data'];
  if (node.kind !== 'chart' || !Array.isArray(data)) return false;
  const items = data as Object[];
  for (let i = 0; i < items.length; i++) {
    if (!richIsRecord(items[i])) return true;
    const result = richEvaluate((items[i] as Record<string, Object>)['value'], values);
    if (result === undefined) return true;
    if (typeof result === 'string' && (result as string).trim().length === 0) return true;
    if (!Number.isFinite(Number(result))) return true;
  }
  return false;
}

/** 按钮 / 表单只改本地视图值；任一表达式无效则整体不生效。 */
export function richAction(node: RichNode, values: RichValues): Map<string, RichValue> {
  const changes: Map<string, RichValue> = new Map();
  const action = node.props['set'];
  if (!richIsRecord(action)) return changes;
  const record = action as Record<string, Object>;
  const keys = Object.keys(record).filter((key: string) => ID.test(key)).slice(0, 100);
  for (let i = 0; i < keys.length; i++) {
    const result = richEvaluate(record[keys[i]], values);
    if (result === undefined) return new Map();
    changes.set(keys[i], result);
  }
  return changes;
}

/** 媒体与链接走现有 Markdown 的信任与来源路径。返回 null 表示不是 Markdown 类节点。 */
export function richMarkdown(node: RichNode): string | null {
  const text = richString(node, 'text');
  const fenced = (language: string): string => {
    let longest = 2;
    const runs = text.match(/`+/g);
    if (runs !== null) runs.forEach((run: string) => { longest = Math.max(longest, run.length); });
    const fence = '`'.repeat(longest + 1);
    return `${fence}${language}\n${text}\n${fence}`;
  };
  if (node.kind === 'markdown') return text;
  if (node.kind === 'code') return fenced(richString(node, 'language').replace(/[^\w+-]/g, ''));
  if (node.kind === 'diagram') return fenced('mermaid');
  if (node.kind === 'math') return `$$\n${text}\n$$`;
  if (node.kind === 'image' || node.kind === 'video' || node.kind === 'audio') {
    const src = richString(node, 'src').replace(/[\n\r<>]/g, '');
    const alt = richString(node, 'alt').replace(/[\[\]\\\n\r]/g, '');
    return src.length > 0 ? `![${alt}](<${src}>)` : '';
  }
  return null;
}

export function richMediaSource(node: RichNode): string | null {
  const src = richString(node, 'src').trim();
  if (src.length === 0 || /[\r\n]/.test(src)) return null;
  if (/^[a-zA-Z][\w+.-]*:/.test(src) && !/^[a-zA-Z]:[\\/]/.test(src)
    && !/^(https?:\/\/|file:\/\/|xdt-(?:file|image|video|audio):\/\/|cindy-(?:remote-)?media:\/\/)/.test(src)) {
    return null;
  }
  return src;
}

export class RichChartPoint {
  label: string = '';
  value: number = 0;
}

export function richChart(node: RichNode, values: RichValues): RichChartPoint[] {
  const data = node.props['data'];
  if (!Array.isArray(data)) return [];
  const out: RichChartPoint[] = [];
  const items = data as Object[];
  for (let i = 0; i < items.length && i < 100; i++) {
    if (!richIsRecord(items[i])) continue;
    const item = items[i] as Record<string, Object>;
    const result = richEvaluate(item['value'], values);
    const value = result === undefined ? NaN : Number(result);
    if (!Number.isFinite(value)) continue;
    const point = new RichChartPoint();
    point.label = typeof item['label'] === 'string' ? item['label'] as string : '';
    point.value = value;
    out.push(point);
  }
  return out;
}

export class RichRangeState {
  min: number = 0;
  max: number = 100;
  step: number = 1;
  value: number = 0;
}

export function richRange(node: RichNode, current: RichValue | undefined): RichRangeState {
  const state = new RichRangeState();
  state.min = richNumber(node, 'min', 0);
  state.max = Math.max(state.min + 1, richNumber(node, 'max', 100));
  state.step = Math.max(Number.EPSILON, richNumber(node, 'step', 1));
  const n = current === undefined ? NaN : Number(current);
  state.value = Math.min(state.max, Math.max(state.min, Number.isFinite(n) ? n : state.min));
  return state;
}

// ─── 折线图坐标（与 Desktop / Mobile 同源） ──────────────────────────────────

export class RichPlotTick {
  value: number = 0;
  y: number = 0;
  label: string = '';
}

export class RichPlotLabel {
  label: string = '';
  x: number = 0;
}

export class RichPlotPoint {
  label: string = '';
  value: number = 0;
  x: number = 0;
  y: number = 0;
}

export class RichLinePlot {
  width: number = 0;
  height: number = 0;
  labelY: number = 0;
  labels: RichPlotLabel[] = [];
  left: number = 0;
  right: number = 0;
  min: number = 0;
  max: number = 1;
  ticks: RichPlotTick[] = [];
  points: RichPlotPoint[] = [];
  showValues: boolean = false;
}

function optionNumber(options: Record<string, Object>, key: string, fallback: number): number {
  const value = options[key];
  return typeof value === 'number' && Number.isFinite(value) ? value as number : fallback;
}

function tickLabel(value: number, decimals: number): string {
  const rounded = Number(value.toFixed(decimals));
  return rounded === 0 ? '0' : String(rounded);
}

function plotLabelWidth(label: string): number {
  let width = 0;
  for (let i = 0; i < label.length; i++) width += label.charCodeAt(i) > 255 ? 12 : 7;
  return width;
}

export function richLinePlot(data: RichChartPoint[], width: number,
  options: Record<string, Object>): RichLinePlot {
  const plot = new RichLinePlot();
  plot.width = Math.max(180, width);
  plot.height = Math.max(80, optionNumber(options, 'height', 220));
  const top = Math.max(0, optionNumber(options, 'top', 28));
  const bottom = plot.height - Math.max(0, optionNumber(options, 'bottom', 28));
  const valuesList = data.map((item: RichChartPoint) => item.value);
  let min = data.length > 0 ? Math.min(...valuesList) : 0;
  let max = data.length > 0 ? Math.max(...valuesList) : 1;
  if (options['includeZero'] === true) {
    min = Math.min(0, min);
    max = Math.max(0, max);
  }
  const spread = max - min;
  const pad = (spread !== 0 ? spread : (Math.abs(max) * 0.05 !== 0 ? Math.abs(max) * 0.05 : 1)) * 0.1;
  min = optionNumber(options, 'yMin', min - pad);
  max = optionNumber(options, 'yMax', max + pad);
  if (max <= min) max = min + 1;
  const scale = Math.max(Math.abs(min), Math.abs(max), 1);
  const span = max / scale - min / scale;
  const y = (v: number): number => bottom - ((v / scale - min / scale) / span) * (bottom - top);
  const tickCount = Math.max(2, Math.min(50, Math.round(optionNumber(options, 'ticks', 4))));
  const tickStep = (max - min) / (tickCount - 1);
  const decimals = Math.max(0, Math.min(12, optionNumber(options, 'decimals', Math.ceil(-Math.log10(tickStep)) + 1)));
  let widestTick = 0;
  for (let i = 0; i < tickCount; i++) {
    const tick = new RichPlotTick();
    tick.value = min + tickStep * i;
    tick.y = y(tick.value);
    tick.label = tickLabel(tick.value, decimals);
    widestTick = Math.max(widestTick, tick.label.length * 7);
    plot.ticks.push(tick);
  }
  plot.left = Math.max(0, optionNumber(options, 'left', widestTick + 12));
  plot.right = Math.max(0, optionNumber(options, 'right', 20));
  const pointSpace = (plot.width - plot.left - plot.right) / Math.max(1, data.length);
  let longest = 1;
  let labelWidth = 1;
  data.forEach((item: RichChartPoint) => {
    longest = Math.max(longest, String(item.value).length);
    labelWidth = Math.max(labelWidth, plotLabelWidth(item.label));
  });
  const labelStep = Math.max(1, Math.ceil((labelWidth + 12) / Math.max(1, pointSpace)));
  plot.labelY = plot.height - 6;
  plot.min = min;
  plot.max = max;
  data.forEach((item: RichChartPoint, i: number) => {
    const x = plot.left + (i + 0.5) * pointSpace;
    if (options['showLabels'] !== false && i % labelStep === 0) {
      const label = new RichPlotLabel();
      label.label = item.label;
      label.x = x;
      plot.labels.push(label);
    }
    const point = new RichPlotPoint();
    point.label = item.label;
    point.value = item.value;
    point.x = x;
    point.y = y(item.value);
    plot.points.push(point);
  });
  const showValues = options['showValues'];
  plot.showValues = typeof showValues === 'boolean' ? showValues as boolean : longest * 8 + 16 <= pointSpace;
  return plot;
}

// ─── 视觉白名单（颜色只接受语义角色，背景与边框颜色归 Cindy） ─────────────────

export type RichStyleValue = string | number;
export type RichVisualStyle = Map<string, RichStyleValue>;

const LENGTH_KEYS: string[] = [
  'width', 'maxWidth', 'minWidth', 'height', 'minHeight', 'maxHeight', 'padding', 'paddingTop',
  'paddingRight', 'paddingBottom', 'paddingLeft', 'marginTop', 'marginBottom', 'gap', 'borderRadius',
  'borderWidth', 'fontSize', 'lineHeight', 'letterSpacing', 'flexGrow', 'flexShrink',
];
const DIMENSION_KEYS: string[] = ['width', 'maxWidth', 'minWidth', 'height', 'minHeight', 'maxHeight'];

function styleEnum(key: string): string[] {
  if (key === 'textAlign') return ['left', 'center', 'right', 'justify'];
  if (key === 'fontStyle') return ['normal', 'italic'];
  if (key === 'alignItems') return ['flex-start', 'center', 'flex-end', 'stretch'];
  if (key === 'justifyContent') {
    return ['flex-start', 'center', 'flex-end', 'space-between', 'space-around', 'space-evenly'];
  }
  if (key === 'flexDirection') return ['row', 'column', 'row-reverse', 'column-reverse'];
  if (key === 'flexWrap') return ['wrap', 'nowrap'];
  if (key === 'textDecorationLine') return ['none', 'underline', 'line-through'];
  if (key === 'borderStyle') return ['solid', 'dashed', 'dotted'];
  return [];
}

export function richColorRole(value: Object | undefined | null): string {
  return typeof value === 'string' && RICH_COLOR_ROLES.includes(value as string) ? value as string : '';
}

/** 宿主声明式样式；`color` 保留角色名，由渲染端映射到主题 token。 */
export function richVisualStyle(node: RichNode): RichVisualStyle {
  const out: RichVisualStyle = new Map();
  const raw = node.props['style'];
  if (!richIsRecord(raw)) return out;
  const style = raw as Record<string, Object>;
  Object.keys(style).forEach((key: string) => {
    const value = style[key];
    if (key === 'color') {
      const role = richColorRole(value);
      if (role.length > 0) out.set(key, role);
    } else if (key === 'borderWidth' && typeof value === 'number') {
      if ((value as number) > 0) out.set(key, 1);
    } else if (LENGTH_KEYS.includes(key) && typeof value === 'number' && Number.isFinite(value)) {
      out.set(key, value as number);
    } else if (DIMENSION_KEYS.includes(key) && typeof value === 'string'
      && /^(?:\d+(?:\.\d+)?%|auto)$/.test(value as string)) {
      out.set(key, value as string);
    } else if (key === 'fontWeight' && /^(?:[1-9]00|normal|bold)$/.test(String(value))) {
      out.set(key, String(value));
    } else if (key === 'fontFamily' && typeof value === 'string' && /^[\w ,'-]{1,120}$/.test(value as string)) {
      out.set(key, value as string);
    } else if (key === 'opacity' && typeof value === 'number' && Number.isFinite(value)) {
      out.set(key, Math.max(0, Math.min(1, value as number)));
    } else if (styleEnum(key).includes(String(value))) {
      out.set(key, String(value));
    }
  });
  if (out.has('borderWidth') || out.has('borderStyle')) {
    if (!out.has('borderWidth')) out.set('borderWidth', 1);
    if (!out.has('borderStyle')) out.set('borderStyle', 'solid');
  }
  return out;
}

// ─── 矢量白名单 ──────────────────────────────────────────────────────────────

const SHAPE_TYPES: string[] = ['path', 'rect', 'circle', 'ellipse', 'line', 'polyline', 'polygon', 'text'];
const SHAPE_NUMBERS: string[] = [
  'x', 'y', 'x1', 'y1', 'x2', 'y2', 'width', 'height', 'rx', 'ry', 'cx', 'cy', 'r', 'strokeWidth',
  'opacity', 'fillOpacity', 'strokeOpacity', 'fontSize', 'letterSpacing',
];

export class RichVectorShape {
  type: string = '';
  /** 数字与已校验字符串；fill / stroke 为颜色角色名或 `none`。 */
  props: Map<string, RichStyleValue> = new Map();
  text: string = '';
}

export class RichVector {
  viewBox: number[] = [0, 0, 640, 360];
  shapes: RichVectorShape[] = [];
}

function vectorString(key: string, value: string): boolean {
  if (key === 'd') return /^[MmZzLlHhVvCcSsQqTtAa\d.,+eE\s-]+$/.test(value);
  if (key === 'points' || key === 'strokeDasharray') return /^[\d.,+eE\s-]+$/.test(value);
  if (key === 'transform') {
    return /^(?:(?:translate|scale|rotate|matrix|skewX|skewY)\([\d.,+eE\s-]+\)\s*)+$/.test(value);
  }
  if (key === 'textAnchor') return ['start', 'middle', 'end'].includes(value);
  if (key === 'fontWeight') return /^(?:[1-9]00|normal|bold)$/.test(value);
  if (key === 'strokeLinecap') return ['butt', 'round', 'square'].includes(value);
  if (key === 'strokeLinejoin') return ['miter', 'round', 'bevel'].includes(value);
  return false;
}

export function richVector(node: RichNode): RichVector {
  const vector = new RichVector();
  const raw = node.props['viewBox'];
  let box: number[] = [];
  if (Array.isArray(raw)) {
    box = (raw as Object[]).map((item: Object) => typeof item === 'number' ? item as number : NaN);
  } else if (raw !== undefined) {
    box = String(raw).split(/[ ,]+/).map((item: string) => item.length > 0 ? Number(item) : NaN);
  }
  if (box.length === 4 && box.every((v: number) => Number.isFinite(v)) && box[2] > 0 && box[3] > 0) {
    vector.viewBox = box;
  }
  const shapes = node.props['shapes'];
  if (!Array.isArray(shapes)) return vector;
  const list = shapes as Object[];
  for (let i = 0; i < list.length && i < 2048; i++) {
    if (!richIsRecord(list[i])) continue;
    const source = list[i] as Record<string, Object>;
    const type = source['type'];
    if (typeof type !== 'string' || !SHAPE_TYPES.includes(type as string)) continue;
    const shape = new RichVectorShape();
    shape.type = type as string;
    Object.keys(source).forEach((key: string) => {
      const value = source[key];
      if (SHAPE_NUMBERS.includes(key) && typeof value === 'number' && Number.isFinite(value)) {
        shape.props.set(key, value as number);
      } else if (key === 'fill' || key === 'stroke') {
        const color = value === 'none' ? 'none' : richColorRole(value);
        if (color.length > 0) shape.props.set(key, color);
      } else if (typeof value === 'string' && vectorString(key, value as string)) {
        shape.props.set(key, value as string);
      } else if (key === 'fontWeight' && typeof value === 'number' && vectorString(key, String(value))) {
        shape.props.set(key, String(value));
      }
    });
    if (shape.type === 'text') shape.text = source['text'] !== undefined ? String(source['text']) : '';
    vector.shapes.push(shape);
  }
  return vector;
}

// ─── 视频站链接 ──────────────────────────────────────────────────────────────

/** 公开观看页不是媒体字节；只有已知 YouTube 主机返回规范链接（Harmony 降级为外链）。 */
export function richYoutubeWatchUrl(source: string): string {
  const match = source.match(/^https?:\/\/([^/?#]+)([^?#]*)(\?[^#]*)?/i);
  if (match === null) return '';
  const host = match[1].toLowerCase();
  if (host.includes('@') || host.includes(':')) return '';
  const path = match[2];
  const query = match[3] !== undefined ? match[3] : '';
  const param = (name: string): string => {
    const found = query.match(new RegExp(`[?&]${name}=([^&]*)`));
    if (found === null) return '';
    try {
      return decodeURIComponent(found[1].replace(/\+/g, ' '));
    } catch (_error) {
      return found[1];
    }
  };
  let id = '';
  if (host === 'youtu.be') {
    const short = path.match(/^\/([\w-]{11})\/?$/);
    id = short !== null ? short[1] : '';
  } else if (['youtube.com', 'www.youtube.com', 'm.youtube.com', 'www.youtube-nocookie.com'].includes(host)) {
    if (path === '/watch') id = param('v');
    else {
      const embed = path.match(/^\/(?:embed|shorts|live)\/([\w-]{11})\/?$/);
      id = embed !== null ? embed[1] : '';
    }
  }
  if (!/^[\w-]{11}$/.test(id)) return '';
  const startValue = param('start').length > 0 ? param('start') : param('t');
  const time = startValue.match(/^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?$/);
  let seconds = 0;
  if (time !== null) {
    seconds = Number(time[1] !== undefined ? time[1] : 0) * 3600
      + Number(time[2] !== undefined ? time[2] : 0) * 60 + Number(time[3] !== undefined ? time[3] : 0);
  }
  const start = Number.isSafeInteger(seconds) && seconds > 0 ? seconds : 0;
  return `https://www.youtube.com/watch?v=${id}${start > 0 ? `&t=${start}` : ''}`;
}

/** 图片走现有 Markdown 图片链路；视频 / 音频与站点视频降级为可点链接。 */
export function richMediaMarkdown(node: RichNode, openVideo: string, openMedia: string): string {
  const src = richMediaSource(node);
  if (src === null) return '';
  const alt = richString(node, 'alt').replace(/[\[\]\\\n\r]/g, '');
  if (node.kind === 'image') {
    return /[\s()<>]/.test(src) ? alt : `![${alt}](${src})`;
  }
  const watch = node.kind === 'video' ? richYoutubeWatchUrl(src) : '';
  if (watch.length > 0) return `[${alt.length > 0 ? alt : openVideo}](${watch})`;
  if (/^https?:\/\//i.test(src) && !/[\s()<>]/.test(src)) {
    return `[${alt.length > 0 ? alt : openMedia}](${src})`;
  }
  return alt.length > 0 ? alt : src;
}

// ─── 可读文本（复制 / 无组件渲染器时的兜底） ─────────────────────────────────

export class RichTextSnapshot {
  text: string = '';
  omittedCollapsedContent: boolean = false;
}

function richTextNode(doc: RichDocument, values: RichValues, id: string,
  visible?: RichTextSnapshot): string {
  const node = doc.nodes.get(id);
  if (node === undefined) return '';
  const md = richMarkdown(node);
  if (md !== null) {
    const caption = richString(node, 'caption');
    return md + (caption.length > 0 ? `\n${caption}` : '');
  }
  if (node.children.length > 0 || (visible !== undefined && ['details', 'tabs'].includes(node.kind))) {
    let children = node.children;
    if (visible !== undefined && node.kind === 'details' && !values.get(richBind(node))) {
      visible.omittedCollapsedContent = visible.omittedCollapsedContent || children.length > 0;
      children = [];
    } else if (visible !== undefined && node.kind === 'tabs') {
      const selected = String(values.get(richBind(node)));
      const active = children.includes(selected) ? selected : children[0];
      visible.omittedCollapsedContent = visible.omittedCollapsedContent || children.length > 1;
      children = active !== undefined ? [active] : [];
    }
    const lines: string[] = [richString(node, 'label')];
    children.forEach((child: string) => lines.push(richTextNode(doc, values, child, visible)));
    return lines.filter((line: string) => line.length > 0).join('\n\n');
  }
  if (node.kind === 'svg') return richString(node, 'label', richString(node, 'alt'));
  if (node.kind === 'heading') return `### ${richLabel(node, values)}`;
  if (node.kind === 'icon') {
    return [richString(node, 'label'), richString(node, 'text')]
      .filter((line: string) => line.length > 0).join('\n');
  }
  if (node.kind === 'text') return richLabel(node, values);
  if (node.kind === 'divider') return '---';
  if (node.kind === 'stat') return `${richString(node, 'label')}: ${richLabel(node, values)}`;
  if (node.kind === 'chart') {
    const lines: string[] = [richString(node, 'label')];
    richChart(node, values).forEach((item: RichChartPoint) => lines.push(`${item.label}: ${item.value}`));
    return lines.join('\n');
  }
  const current = values.get(richBind(node));
  if (node.kind === 'check') {
    return `${current ? '☑' : '☐'} ${richString(node, 'label', richString(node, 'text'))}`;
  }
  return richString(node, 'label') + (current === undefined ? '' : `: ${current}`);
}

/** 无组件渲染器渠道的可读复制 / 导出。 */
export function richAnswerText(source: string): string {
  if (source.indexOf(RICH_ANSWER_LANGUAGE) === -1) return source;
  return splitRichAnswer(source).map((part: RichPart) => {
    if (part.kind === 'markdown') return part.source;
    const doc = new RichAnswerStream().update(part.source, true);
    const values = richResolvedValues(doc);
    return doc.roots.map((id: string) => richTextNode(doc, values, id))
      .filter((text: string) => text.length > 0).join('\n\n');
  }).join('\n\n');
}

export function richAnswerVisibleText(source: string,
  readEdited?: (partKey: number) => Map<string, RichValue>, complete: boolean = true): RichTextSnapshot {
  const snapshot = new RichTextSnapshot();
  snapshot.text = splitRichAnswer(source).map((part: RichPart) => {
    if (part.kind === 'markdown') return part.source;
    const doc = new RichAnswerStream().update(part.source, part.complete || complete);
    const values = richResolvedValues(doc, readEdited !== undefined ? readEdited(part.key) : undefined);
    return doc.roots.map((id: string) => richTextNode(doc, values, id, snapshot))
      .filter((text: string) => text.length > 0).join('\n\n');
  }).join('\n\n');
  return snapshot;
}
