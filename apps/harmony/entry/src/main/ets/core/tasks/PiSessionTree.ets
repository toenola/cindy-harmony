/** Pi 任务分支树的受限远程模型。 */
const MAX_DEPTH = 64;
const MAX_NODES = 2000;

export class PiSessionTreeNode {
  id: string = '';
  role: string = '';
  preview: string = '';
  label: string = '';
  children: PiSessionTreeNode[] = [];
}

export class PiSessionTreeSnapshot {
  roots: PiSessionTreeNode[] = [];
  leafId: string = '';
  activePathIds: string[] = [];
}

export class PiSessionTreeNavigateResult {
  tree: PiSessionTreeSnapshot | null = null;
  draftText: string = '';
  cancelled: boolean = false;
}

class ParseBudget {
  count: number = 0;
  failed: boolean = false;
}

function readString(record: Record<string, Object>, key: string, max: number = 1000): string {
  const value = record[key];
  return typeof value === 'string' ? value.slice(0, max) : '';
}

function parseNode(value: Object, depth: number, budget: ParseBudget): PiSessionTreeNode | null {
  if (depth > MAX_DEPTH || budget.count >= MAX_NODES) {
    budget.failed = true;
    return null;
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return null;
  const record = value as Record<string, Object>;
  const id = readString(record, 'id', 512);
  if (id.length === 0) return null;
  budget.count += 1;
  const node = new PiSessionTreeNode();
  node.id = id;
  node.role = readString(record, 'role', 40);
  node.preview = readString(record, 'preview', 2000);
  node.label = readString(record, 'label', 256);
  const children = record['children'];
  if (Array.isArray(children)) {
    const list = children as Object[];
    for (let i = 0; i < list.length; i++) {
      const child = parseNode(list[i], depth + 1, budget);
      if (budget.failed) return null;
      if (child !== null) node.children.push(child);
    }
  }
  return node;
}

export function parsePiSessionTree(value: Object | undefined): PiSessionTreeSnapshot | null {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) return null;
  const record = value as Record<string, Object>;
  const rawRoots = record['roots'];
  if (!Array.isArray(rawRoots)) return null;
  const budget = new ParseBudget();
  const out = new PiSessionTreeSnapshot();
  const roots = rawRoots as Object[];
  for (let i = 0; i < roots.length; i++) {
    const root = parseNode(roots[i], 0, budget);
    if (budget.failed) return null;
    if (root !== null) out.roots.push(root);
  }
  out.leafId = readString(record, 'leafId', 512);
  const path = record['activePathIds'];
  if (Array.isArray(path)) {
    const list = path as Object[];
    for (let i = 0; i < list.length && i < MAX_DEPTH + 1; i++) {
      if (typeof list[i] === 'string') out.activePathIds.push((list[i] as string).slice(0, 512));
    }
  }
  return out;
}

export function parsePiNavigateResult(value: Object | undefined): PiSessionTreeNavigateResult | null {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) return null;
  const record = value as Record<string, Object>;
  const out = new PiSessionTreeNavigateResult();
  out.cancelled = record['cancelled'] === true;
  out.draftText = readString(record, 'draftText', 2_000_000);
  if (record['tree'] !== undefined) out.tree = parsePiSessionTree(record['tree']);
  return out;
}
