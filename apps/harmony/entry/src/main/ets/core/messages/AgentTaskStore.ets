/** Live-only 子 Agent 任务状态；语义与 maker-shared/agentTask 保持一致。 */

const MAX_WORKFLOW_ENTRIES = 2000;

export class AgentTaskUsage {
  totalTokens: number = 0;
  toolUses: number = 0;
  durationMs: number = 0;
}

export class WorkflowProgressEntry {
  type: string = '';
  index: number = 0;
  title: string = '';
  label: string = '';
  phaseTitle: string = '';
  agentId: string = '';
  model: string = '';
  state: string = '';
  lastToolName: string = '';
  lastToolSummary: string = '';
  resultPreview: string = '';
  promptPreview: string = '';
  error: string = '';
  agentType: string = '';
  phaseIndex: number = 0;
  queuedAt: number = 0;
  startedAt: number = 0;
  lastProgressAt: number = 0;
  attempt: number = 0;
  cached: boolean = false;
}

export class AgentTaskUpdate {
  provider: string = 'claude-code';
  taskId: string = '';
  parentToolUseId: string = '';
  status: string = 'running';
  title: string = '';
  description: string = '';
  summary: string = '';
  outputFile: string = '';
  usage: AgentTaskUsage | null = null;
  lastToolName: string = '';
  taskType: string = '';
  workflowName: string = '';
  model: string = '';
  hasModel: boolean = false;
  reasoningEffort: string = '';
  receiverThreadIds: string[] = [];
  workflowProgress: WorkflowProgressEntry[] = [];
  hasWorkflowProgress: boolean = false;
  createdAt: string = '';
  updatedAt: string = '';
}

function recordOf(value: Object | undefined): Record<string, Object> | null {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, Object>
    : null;
}

function stringOf(record: Record<string, Object>, key: string, max: number = 1000): string {
  const value = record[key];
  if (typeof value !== 'string' || value.length === 0) return '';
  return value.length <= max ? value : `${value.slice(0, Math.max(0, max - 1))}…`;
}

function finiteOf(record: Record<string, Object>, key: string): number {
  const value = record[key];
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

function copyUpdate(value: AgentTaskUpdate): AgentTaskUpdate {
  const out = new AgentTaskUpdate();
  out.provider = value.provider;
  out.taskId = value.taskId;
  out.parentToolUseId = value.parentToolUseId;
  out.status = value.status;
  out.title = value.title;
  out.description = value.description;
  out.summary = value.summary;
  out.outputFile = value.outputFile;
  out.usage = value.usage;
  out.lastToolName = value.lastToolName;
  out.taskType = value.taskType;
  out.workflowName = value.workflowName;
  out.model = value.model;
  out.hasModel = value.hasModel;
  out.reasoningEffort = value.reasoningEffort;
  out.receiverThreadIds = value.receiverThreadIds.slice();
  out.workflowProgress = value.workflowProgress.slice();
  out.hasWorkflowProgress = value.hasWorkflowProgress;
  out.createdAt = value.createdAt;
  out.updatedAt = value.updatedAt;
  return out;
}

export function isAgentTaskToolName(toolName: string): boolean {
  return toolName === 'Agent' || toolName === 'Task' || toolName === 'subagent'
    || toolName.startsWith('collab:');
}

export function normalizeWorkflowProgress(value: Object | undefined): WorkflowProgressEntry[] | null {
  if (!Array.isArray(value)) return null;
  const list = value as Object[];
  const out: WorkflowProgressEntry[] = [];
  for (let i = 0; i < list.length && out.length < MAX_WORKFLOW_ENTRIES; i++) {
    const raw = recordOf(list[i]);
    if (raw === null) continue;
    const type = stringOf(raw, 'type', 200);
    const rawIndex = raw['index'];
    if ((type !== 'workflow_phase' && type !== 'workflow_agent')
      || typeof rawIndex !== 'number' || !Number.isFinite(rawIndex)) continue;
    const item = new WorkflowProgressEntry();
    item.type = type;
    item.index = rawIndex;
    item.title = stringOf(raw, 'title', 200);
    item.label = stringOf(raw, 'label', 200);
    item.phaseTitle = stringOf(raw, 'phaseTitle', 200);
    item.agentId = stringOf(raw, 'agentId', 200);
    item.model = stringOf(raw, 'model', 200);
    item.state = stringOf(raw, 'state', 200);
    item.lastToolName = stringOf(raw, 'lastToolName', 200);
    item.agentType = stringOf(raw, 'agentType', 200);
    item.lastToolSummary = stringOf(raw, 'lastToolSummary', 160);
    item.resultPreview = stringOf(raw, 'resultPreview', 300);
    item.promptPreview = stringOf(raw, 'promptPreview', 300);
    item.error = stringOf(raw, 'error', 300);
    item.phaseIndex = finiteOf(raw, 'phaseIndex');
    item.queuedAt = finiteOf(raw, 'queuedAt');
    item.startedAt = finiteOf(raw, 'startedAt');
    item.lastProgressAt = finiteOf(raw, 'lastProgressAt');
    item.attempt = finiteOf(raw, 'attempt');
    item.cached = raw['cached'] === true;
    out.push(item);
  }
  return out.length > 0 ? out : null;
}

export function normalizeAgentTaskUpdate(
  value: Object | undefined,
  source: string = '',
): AgentTaskUpdate | null {
  const raw = recordOf(value);
  if (raw === null) return null;
  const taskId = stringOf(raw, 'taskId');
  const parentToolUseId = stringOf(raw, 'parentToolUseId');
  if (taskId.length === 0 && parentToolUseId.length === 0) return null;
  const out = new AgentTaskUpdate();
  const provider = stringOf(raw, 'provider');
  out.provider = provider === 'codex' || provider === 'pi' || provider === 'claude-code'
    ? provider : (source === 'codex' || source === 'pi' ? source : 'claude-code');
  out.taskId = taskId.length > 0 ? taskId : parentToolUseId;
  out.parentToolUseId = parentToolUseId;
  const status = stringOf(raw, 'status');
  out.status = status === 'completed' || status === 'failed' || status === 'stopped'
    ? status : 'running';
  out.title = stringOf(raw, 'title');
  out.description = stringOf(raw, 'description');
  out.summary = stringOf(raw, 'summary', 4000);
  out.outputFile = stringOf(raw, 'outputFile', 4000);
  out.lastToolName = stringOf(raw, 'lastToolName');
  out.taskType = stringOf(raw, 'taskType');
  out.workflowName = stringOf(raw, 'workflowName');
  if (raw['model'] === null) {
    out.hasModel = true;
    out.model = '';
  } else if (typeof raw['model'] === 'string' && (raw['model'] as string).length > 0) {
    out.hasModel = true;
    out.model = raw['model'] as string;
  }
  out.reasoningEffort = stringOf(raw, 'reasoningEffort');
  const usageRaw = recordOf(raw['usage']);
  if (usageRaw !== null) {
    const usage = new AgentTaskUsage();
    usage.totalTokens = finiteOf(usageRaw, 'totalTokens');
    usage.toolUses = finiteOf(usageRaw, 'toolUses');
    usage.durationMs = finiteOf(usageRaw, 'durationMs');
    out.usage = usage;
  }
  if (Array.isArray(raw['receiverThreadIds'])) {
    const ids = raw['receiverThreadIds'] as Object[];
    for (let i = 0; i < ids.length; i++) if (typeof ids[i] === 'string') out.receiverThreadIds.push(ids[i] as string);
  }
  const progress = normalizeWorkflowProgress(raw['workflowProgress']);
  if (progress !== null) {
    out.hasWorkflowProgress = true;
    out.workflowProgress = progress;
  }
  out.createdAt = stringOf(raw, 'createdAt');
  out.updatedAt = stringOf(raw, 'updatedAt');
  return out;
}

export function mergeAgentTaskUpdate(prev: AgentTaskUpdate | undefined, next: AgentTaskUpdate): AgentTaskUpdate {
  if (prev === undefined) return copyUpdate(next);
  const out = copyUpdate(prev);
  out.provider = next.provider;
  out.taskId = next.taskId;
  if (next.parentToolUseId.length > 0) out.parentToolUseId = next.parentToolUseId;
  out.status = next.status;
  if (next.title.length > 0) out.title = next.title;
  if (next.description.length > 0) out.description = next.description;
  if (next.summary.length > 0) out.summary = next.summary;
  if (next.outputFile.length > 0) out.outputFile = next.outputFile;
  if (next.usage !== null) out.usage = next.usage;
  if (next.lastToolName.length > 0) out.lastToolName = next.lastToolName;
  if (next.taskType.length > 0) out.taskType = next.taskType;
  if (next.workflowName.length > 0) out.workflowName = next.workflowName;
  if (next.hasModel) {
    out.hasModel = true;
    out.model = next.model;
  }
  if (next.reasoningEffort.length > 0) out.reasoningEffort = next.reasoningEffort;
  if (next.receiverThreadIds.length > 0) out.receiverThreadIds = next.receiverThreadIds.slice();
  if (next.hasWorkflowProgress) {
    out.hasWorkflowProgress = true;
    out.workflowProgress = next.workflowProgress.slice();
  }
  if (out.createdAt.length === 0) out.createdAt = next.createdAt;
  if (next.updatedAt.length > 0) out.updatedAt = next.updatedAt;
  return out;
}

export function isSameAgentTaskAlias(left: AgentTaskUpdate, right: AgentTaskUpdate): boolean {
  return left.taskId === right.taskId
    || (left.parentToolUseId.length > 0 && left.parentToolUseId === right.taskId)
    || (right.parentToolUseId.length > 0 && right.parentToolUseId === left.taskId)
    || (left.parentToolUseId.length > 0 && left.parentToolUseId === right.parentToolUseId);
}

export function applyAgentTaskUpdateEvent(
  previous: Map<string, AgentTaskUpdate> | undefined,
  value: Object | undefined,
  source: string,
  nowIso: string,
): Map<string, AgentTaskUpdate> | null {
  const update = normalizeAgentTaskUpdate(value, source);
  if (update === null) return null;
  const next = new Map<string, AgentTaskUpdate>(previous ?? new Map<string, AgentTaskUpdate>());
  const keys = new Set<string>();
  keys.add(update.taskId);
  if (update.parentToolUseId.length > 0) keys.add(update.parentToolUseId);
  next.forEach((stored: AgentTaskUpdate, key: string) => {
    if (!isSameAgentTaskAlias(stored, update)) return;
    keys.add(key);
    keys.add(stored.taskId);
    if (stored.parentToolUseId.length > 0) keys.add(stored.parentToolUseId);
  });
  let existing: AgentTaskUpdate | undefined = undefined;
  const keyList: string[] = [];
  keys.forEach((key: string) => keyList.push(key));
  for (let i = 0; i < keyList.length; i++) {
    if (existing === undefined && next.has(keyList[i])) existing = next.get(keyList[i]);
  }
  if (update.createdAt.length === 0) {
    update.createdAt = existing === undefined ? nowIso : existing.createdAt;
    if (update.createdAt.length === 0) update.createdAt = nowIso;
  }
  if (update.updatedAt.length === 0) update.updatedAt = nowIso;
  let merged = mergeAgentTaskUpdate(existing, update);
  for (let i = 0; i < keyList.length; i++) {
    merged = mergeAgentTaskUpdate(next.get(keyList[i]), merged);
  }
  for (let i = 0; i < keyList.length; i++) next.set(keyList[i], merged);
  return next;
}

export function findAgentTaskUpdate(
  updates: Map<string, AgentTaskUpdate> | undefined,
  toolUseId: string,
  clientId: string,
): AgentTaskUpdate | undefined {
  if (updates === undefined) return undefined;
  if (toolUseId.length > 0 && updates.has(toolUseId)) return updates.get(toolUseId);
  return clientId.length > 0 ? updates.get(clientId) : undefined;
}
