import { readObj, readStr, recordOrEmpty } from '../tasks/TaskModels';

function shortHistoryTarget(target: string): string {
  const normalized = target.trim();
  return normalized.length > 60 ? normalized.slice(0, 57).trimEnd() + '...' : normalized;
}

function historyActionLabel(action: string, target: string, text: (key: string, args: string[]) => string): string {
  return text('v132_history_action_' + action, [target]).trim();
}

function formatHistoryDescriptor(descriptor: Record<string, Object>, toolName: string,
  text: (key: string, args: string[]) => string): string {
  const kind = readStr(descriptor, 'kind');
  if (kind === 'command') {
    const description = readStr(descriptor, 'description');
    if (description) return description;
    const intent = readObj(descriptor, 'intent');
    const action = readStr(intent, 'action');
    if (action === 'read' || action === 'list' || action === 'search' || action === 'fetch') {
      return historyActionLabel(action, shortHistoryTarget(readStr(intent, 'target')), text);
    }
    return readStr(descriptor, 'command') || action
      ? text('v132_history_action_run_command', []) : toolName;
  }
  if (kind === 'file') {
    const action = readStr(descriptor, 'action');
    return historyActionLabel(action === 'read' ? 'read' : action === 'edit' ? 'edit' : 'create',
      readStr(descriptor, 'fileName'), text);
  }
  if (kind === 'fileChange') {
    const changes = descriptor['changes'];
    if (!Array.isArray(changes) || changes.length === 0) return toolName;
    if (changes.length > 1) return text('v132_history_updated_files', [String(changes.length)]);
    const change = recordOrEmpty((changes as Object[])[0]);
    const action = readStr(change, 'action');
    const verb = action === 'add' ? 'create' : action === 'delete' ? 'delete'
      : action === 'move' ? 'rename' : action === 'update' ? 'edit' : 'update';
    const name = readStr(change, 'fileName');
    const destination = readStr(change, 'moveFileName');
    return historyActionLabel(verb, action === 'move' && destination ? name + ' → ' + destination : name, text);
  }
  if (kind === 'search') {
    return historyActionLabel('search', shortHistoryTarget(readStr(descriptor, 'pattern')), text);
  }
  if (kind === 'web') {
    return historyActionLabel(readStr(descriptor, 'mode') === 'fetch' ? 'fetch' : 'search',
      shortHistoryTarget(readStr(descriptor, 'target')), text);
  }
  if (kind === 'todo') return text('v132_history_action_update_todos', []);
  if (kind === 'task') return readStr(descriptor, 'description') || toolName;
  if (kind === 'mcp') {
    const server = readStr(descriptor, 'serverLabel');
    const tool = readStr(descriptor, 'toolLabel');
    const target = server && tool ? server + ' · ' + tool : server || tool || toolName;
    return historyActionLabel('use', target, text);
  }
  if (kind === 'dynamic') {
    const namespace = readStr(descriptor, 'namespace');
    const tool = readStr(descriptor, 'toolLabel');
    const target = namespace && tool ? namespace + ' · ' + tool : tool || toolName;
    return historyActionLabel('use', target, text);
  }
  if (kind === 'collab') return historyActionLabel('use', readStr(descriptor, 'toolLabel') || toolName, text);
  if (kind === 'generic') return historyActionLabel('use', toolName, text);
  return toolName;
}

export function formatHistoryWorkLine(line: Record<string, Object>,
  text: (key: string, args: string[]) => string): string {
  const kind = readStr(line, 'kind');
  if (kind === 'thinking') return readStr(line, 'text');
  if (kind !== 'tool') return '';
  const descriptor = readObj(line, 'descriptor');
  const toolName = readStr(descriptor, 'toolName') || readStr(line, 'toolName');
  return formatHistoryDescriptor(descriptor, toolName, text) || toolName;
}
