/**
 * Harmony 工具步骤的人话投影。
 *
 * 对齐 maker-shared 的 describeToolUse -> formatToolRowText 语义：主行只描述
 * “正在做什么”，完整路径 / 命令留在 detail。复杂 shell 无法安全归类时必须
 * 回退“运行命令”，不能把可能有副作用的调用伪装成读取或搜索。
 */

import { readAny, readStr } from '../tasks/TaskModels';

const LABEL_TEXT_LIMIT = 60;
const DETAIL_TEXT_LIMIT = 200;
const GENERIC_DETAIL_LIMIT = 80;

export class ToolActionPresentation {
  /** 多 action exec 的稳定子序号。 */
  actionIndex: number = 0;
  label: string = '';
  detail: string = '';
  /** read / search / list / other，供探索摘要和重复读取去重使用。 */
  explorationKind: string = 'other';
  readKey: string = '';
}

class CommandActionIntent {
  action: string = '';
  target: string = '';
  path: string = '';
}

class PosixShellToken {
  text: string = '';
  end: number = 0;
  quoted: boolean = false;
  hasUnquotedLiteral: boolean = false;
}

function parseRecord(value: Object | undefined): Record<string, Object> | null {
  let current = value;
  // 兼容旧 Harmony live input 的双重 JSON 字符串；最多解两层，避免畸形递归。
  for (let i = 0; i < 2; i++) {
    if (typeof current !== 'string') break;
    const text = (current as string).trim();
    if (text.length === 0) return null;
    try {
      current = JSON.parse(text) as Object;
    } catch (e) {
      return null;
    }
  }
  if (current === undefined || current === null || typeof current !== 'object' || Array.isArray(current)) {
    return null;
  }
  return current as Record<string, Object>;
}

function toolInput(inputRaw: string, inputText: string): Record<string, Object> | null {
  if (inputRaw.trim().length > 0) {
    const parsed = parseRecord(inputRaw);
    if (parsed !== null) return parsed;
  }
  if (inputText.trim().length > 0) return parseRecord(inputText);
  return null;
}

function truncate(value: string, max: number): string {
  const normalized = value.trim();
  if (normalized.length <= max) return normalized;
  return `${normalized.slice(0, Math.max(0, max - 3)).trim()}...`;
}

function basename(path: string): string {
  const normalized = path.replace(/\\/g, '/').replace(/\/+$/, '');
  const parts = normalized.split('/');
  return parts.length > 0 && parts[parts.length - 1].length > 0
    ? parts[parts.length - 1] : path;
}

function normalizedReadKey(path: string): string {
  return path.replace(/\\/g, '/').replace(/\/\.\//g, '/').replace(/\/+$/, '').toLowerCase();
}

function humanizeToolToken(value: string): string {
  return value.replace(/_+/g, ' ').replace(/\s+/g, ' ').trim();
}

function makePresentation(
  label: string,
  detail: string = '',
  explorationKind: string = 'other',
  readKey: string = '',
): ToolActionPresentation {
  const out = new ToolActionPresentation();
  out.label = label;
  out.detail = detail;
  out.explorationKind = explorationKind;
  out.readKey = readKey;
  return out;
}

function filePresentation(
  verb: string,
  path: string,
  explorationKind: string = 'other',
): ToolActionPresentation {
  const name = basename(path);
  const detail = path !== name ? path : '';
  return makePresentation(
    `${verb} ${name}`,
    detail,
    explorationKind,
    explorationKind === 'read' ? normalizedReadKey(path) : '',
  );
}

function firstDetail(input: Record<string, Object> | null): string {
  if (input === null) return '';
  const keys: string[] = ['description', 'url', 'query', 'path', 'file_path', 'title', 'name', 'prompt'];
  for (let i = 0; i < keys.length; i++) {
    const value = readStr(input, keys[i]).trim();
    if (value.length > 0) return truncate(value, GENERIC_DETAIL_LIMIT);
  }
  return '';
}

function readPosixShellToken(input: string, start: number): PosixShellToken | null {
  let index = start;
  while (index < input.length && /\s/.test(input.charAt(index))) index += 1;
  if (index >= input.length) return null;
  const token = new PosixShellToken();
  let text = '';
  while (index < input.length && !/\s/.test(input.charAt(index))) {
    const char = input.charAt(index);
    if (char === "'") {
      token.quoted = true;
      index += 1;
      while (index < input.length && input.charAt(index) !== "'") {
        text += input.charAt(index);
        index += 1;
      }
      if (index >= input.length) return null;
      index += 1;
      continue;
    }
    if (char === '"') {
      token.quoted = true;
      index += 1;
      while (index < input.length && input.charAt(index) !== '"') {
        if (input.charAt(index) === '\\') {
          const next = input.charAt(index + 1);
          if (next.length === 0) return null;
          if (next === '$' || next === '`' || next === '"' || next === '\\' || next === '\n') {
            if (next !== '\n') text += next;
            index += 2;
            continue;
          }
        }
        text += input.charAt(index);
        index += 1;
      }
      if (index >= input.length) return null;
      index += 1;
      continue;
    }
    if (char === '\\') {
      const next = input.charAt(index + 1);
      if (next.length === 0) return null;
      if (next !== '\n') text += next;
      index += 2;
      continue;
    }
    token.hasUnquotedLiteral = true;
    text += char;
    index += 1;
  }
  token.text = text;
  token.end = index;
  return token;
}

function isPosixShellWrapper(binary: string): boolean {
  return /^(?:(?:\/bin|\/usr\/bin|\/usr\/local\/bin)\/)?(?:zsh|bash|sh)$/.test(binary);
}

function normalizePosixDisplayCommand(command: string): string {
  let executable = readPosixShellToken(command, 0);
  if (executable === null) return '';
  if (/^(?:(?:\/bin|\/usr\/bin)\/)?env$/.test(executable.text)) {
    executable = readPosixShellToken(command, executable.end);
    if (executable === null) return '';
  }
  if (!isPosixShellWrapper(executable.text)) return '';
  const option = readPosixShellToken(command, executable.end);
  if (option === null || (option.text !== '-lc' && option.text !== '-c')) return '';
  const script = readPosixShellToken(command, option.end);
  if (script === null || script.text.length === 0 || command.slice(script.end).trim().length > 0) return '';
  if (script.quoted && script.hasUnquotedLiteral) return '';
  if (!script.quoted && !/^[A-Za-z0-9_./:@%+=,-]+$/.test(script.text)) return '';
  return script.text;
}

function commandText(input: Record<string, Object> | null): string {
  if (input === null) return '';
  const display = readStr(input, 'displayCommand').trim();
  if (display.length > 0) return display;
  const raw = readStr(input, 'command').trim();
  const normalized = normalizePosixDisplayCommand(raw);
  return normalized.length > 0 ? normalized : raw;
}

function shellWords(command: string): string[] {
  const words: string[] = [];
  let current = '';
  let quote = '';
  let escaped = false;
  for (let i = 0; i < command.length; i++) {
    const char = command.charAt(i);
    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }
    if (char === '\\' && quote !== "'") {
      escaped = true;
      continue;
    }
    if (quote.length > 0) {
      if (char === quote) quote = '';
      else current += char;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      continue;
    }
    if (/\s/.test(char)) {
      if (current.length > 0) {
        words.push(current);
        current = '';
      }
      continue;
    }
    current += char;
  }
  if (current.length > 0) words.push(current);
  return words;
}

function commandHasUnsafeShape(command: string, allowSequentialAnd: boolean): boolean {
  const lower = command.toLowerCase();
  if (lower.includes('$(') || lower.includes('<(') || lower.includes('>(')
    || lower.includes('`') || lower.includes('<<')) return true;
  // 不猜测管道、OR、分号或换行的最终副作用；只有经逐段验证的 && 可放行。
  if (lower.includes('|') || lower.includes(';') || lower.includes('\n') || lower.includes('\r')) return true;
  if (!allowSequentialAnd && lower.includes('&&')) return true;
  const withoutSequential = allowSequentialAnd ? lower.replace(/&&/g, '') : lower;
  if (withoutSequential.includes('&')) return true;
  if (/(^|\s)(rm|mv|cp|dd|chmod|chown|truncate|touch)(\s|$)/.test(lower)) return true;
  if (/\bsed\s+[^\n]*(-i|--in-place)\b/.test(lower)) return true;
  if (/\bfind\s+[^\n]*(-delete|-exec|-execdir|-ok|-okdir|-fprint|-fprintf|-fls)\b/.test(lower)) {
    return true;
  }
  if (/(^|[^>])>(?!&)/.test(lower)) return true;
  return false;
}

/** 单条探索命令不允许任何顶层复合操作。 */
function commandAllowsExploration(command: string): boolean {
  return !commandHasUnsafeShape(command, false);
}

/** 多 action exec 只额外放行 &&，随后还会逐段核对动作数量和语义。 */
function commandAllowsStructuredComposite(command: string): boolean {
  return !commandHasUnsafeShape(command, true);
}

function firstCommandTarget(words: string[], start: number): string {
  const flagsWithValue: string[] = [
    '-A', '-B', '-C', '-g', '--glob', '-t', '--type', '-m', '--max-count',
    '-e', '--regexp', '-f', '--file', '--encoding', '--sort', '--sortr',
  ];
  for (let i = start; i < words.length; i++) {
    const word = words[i];
    if (flagsWithValue.includes(word)) {
      i += 1;
      continue;
    }
    if (word.startsWith('-')) continue;
    return word;
  }
  return '';
}

function simpleCommandIntent(command: string): CommandActionIntent | null {
  if (!commandAllowsExploration(command)) return null;
  const words = shellWords(command);
  if (words.length === 0) return null;
  let binIndex = 0;
  while (binIndex < words.length && /^[A-Za-z_][A-Za-z0-9_]*=.*/.test(words[binIndex])) binIndex += 1;
  if (binIndex >= words.length) return null;
  const bin = basename(words[binIndex]).toLowerCase();
  const out = new CommandActionIntent();

  if (bin === 'cat' || bin === 'head' || bin === 'tail' || bin === 'less'
    || bin === 'more' || bin === 'bat' || bin === 'nl') {
    // less / more 的 +cmd 参数可以在打开文件后执行内部命令，不能当作普通读取。
    if ((bin === 'less' || bin === 'more')
      && words.slice(binIndex + 1).some((word) => word.startsWith('+'))) return null;
    const path = firstCommandTarget(words, binIndex + 1);
    if (path.length === 0) return null;
    out.action = 'read';
    out.target = basename(path);
    out.path = path;
    return out;
  }
  if (bin === 'sed') {
    // sed 的脚本本身也能通过 w / e 等命令产生副作用。只识别项目中用于分页查看的
    // `sed -n '<line>[,<line>]p' FILE` 形态，其余全部回退为“运行命令”。
    const args = words.slice(binIndex + 1);
    if (args.length === 4 && args[0] === '-n' && args[2] === '--') args.splice(2, 1);
    if (args.length !== 3 || args[0] !== '-n'
      || !/^(?:\d+|\$)(?:,(?:\d+|\$))?p$/.test(args[1])) return null;
    const path = args[2];
    if (path.length === 0 || path.startsWith('-') || path.startsWith('+')) return null;
    out.action = 'read';
    out.target = basename(path);
    out.path = path;
    return out;
  }
  if (bin === 'rg' || bin === 'grep' || bin === 'egrep' || bin === 'fgrep') {
    // ripgrep 的 --pre / --pre-glob 会先执行外部预处理程序，不能按纯搜索展示。
    if (bin === 'rg' && words.slice(binIndex + 1).some((word) => word.startsWith('--pre'))) return null;
    if (words.includes('--files')) {
      out.action = 'list';
      return out;
    }
    const query = firstCommandTarget(words, binIndex + 1);
    if (query.length === 0) return null;
    out.action = 'search';
    out.target = query;
    return out;
  }
  if (bin === 'ls') {
    out.action = 'list';
    out.target = firstCommandTarget(words, binIndex + 1);
    return out;
  }
  if (bin === 'find') {
    const marker = words.indexOf('-name');
    const markerInsensitive = words.indexOf('-iname');
    const patternIndex = marker >= 0 ? marker + 1 : (markerInsensitive >= 0 ? markerInsensitive + 1 : -1);
    if (patternIndex <= 0 || patternIndex >= words.length) return null;
    out.action = 'search';
    out.target = words[patternIndex];
    return out;
  }
  return null;
}

function actionLabel(intent: CommandActionIntent): string {
  const target = truncate(intent.target, LABEL_TEXT_LIMIT);
  if (intent.action === 'read') return target.length > 0 ? `读取 ${target}` : '读取';
  if (intent.action === 'search') return target.length > 0 ? `搜索 ${target}` : '搜索';
  if (intent.action === 'list') return target.length > 0 ? `列出 ${target}` : '列出';
  return '运行命令';
}

function intentPresentation(intent: CommandActionIntent, command: string): ToolActionPresentation {
  return makePresentation(
    actionLabel(intent),
    truncate(command, DETAIL_TEXT_LIMIT),
    intent.action,
    intent.action === 'read' ? normalizedReadKey(intent.path.length > 0 ? intent.path : intent.target) : '',
  );
}

function structuredCommandActions(
  input: Record<string, Object> | null,
  command: string,
): ToolActionPresentation[] {
  if (input === null || !commandAllowsStructuredComposite(command)) return [];
  const raw = readAny(input, 'commandActions');
  if (!Array.isArray(raw) || raw.length === 0) return [];
  const actions = raw as Object[];
  const out: ToolActionPresentation[] = [];
  for (let i = 0; i < actions.length; i++) {
    const value = actions[i];
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return [];
    const record = value as Record<string, Object>;
    const type = readStr(record, 'type');
    const actionCommand = readStr(record, 'command');
    if (actionCommand.length === 0 || !commandAllowsExploration(actionCommand)) return [];
    const intent = new CommandActionIntent();
    if (type === 'read') {
      const path = readStr(record, 'path');
      const name = readStr(record, 'name');
      const parsed = simpleCommandIntent(actionCommand);
      if (path.length === 0 || parsed === null || parsed.action !== 'read') return [];
      intent.action = 'read';
      intent.path = path;
      intent.target = name.length > 0 ? name : basename(path);
    } else if (type === 'search') {
      const query = readStr(record, 'query');
      const path = readStr(record, 'path');
      const parsed = simpleCommandIntent(actionCommand);
      if ((query.length === 0 && path.length === 0) || parsed === null || parsed.action !== 'search') return [];
      intent.action = 'search';
      intent.target = query.length > 0 ? query : path;
      intent.path = path;
    } else if (type === 'listFiles') {
      const parsed = simpleCommandIntent(actionCommand);
      if (parsed === null || parsed.action !== 'list') return [];
      intent.action = 'list';
      intent.target = readStr(record, 'path');
    } else {
      return [];
    }
    const row = intentPresentation(intent, command);
    row.actionIndex = i;
    out.push(row);
  }
  if (command.length > 0) {
    const parts = command.split('&&');
    if (parts.length !== out.length) return [];
    for (let i = 0; i < parts.length; i++) {
      const parsed = simpleCommandIntent(parts[i].trim());
      if (parsed === null || parsed.action !== out[i].explorationKind) return [];
    }
  }
  return out;
}

function knownCommandLabel(command: string): string {
  const lower = command.trim().toLowerCase();
  if (lower.length === 0) return '';
  // 安全顺序组合中混合测试 / 类型 / lint / 构建时，shared 归纳为“运行验证”。
  if (lower.includes('&&') && commandAllowsStructuredComposite(command)) {
    const parts = lower.split('&&');
    let verificationCount = 0;
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i];
      if (part.includes('test') || part.includes('typecheck') || part.includes('tsc')
        || part.includes('lint') || part.includes('check') || part.includes('build')
        || part.includes('assemblehap')) verificationCount += 1;
    }
    if (verificationCount === parts.length && verificationCount > 1) return '运行验证';
  }
  if (!commandAllowsExploration(command)) return '';
  if (/\bgit\s+status\b/.test(lower)) return '查看工作区状态';
  if (/\bgit\s+diff\b/.test(lower)) return '查看代码变更';
  if (/\bgit\s+log\b/.test(lower)) return '查看提交记录';
  if (/\bgit\s+show\b/.test(lower)) return '查看提交内容';
  if (/\bgit\s+fetch\b/.test(lower)) return '获取远端更新';
  if (/\bgit\s+pull\b/.test(lower)) return '拉取远端更新';
  if (/\bgit\s+push\b/.test(lower)) return '推送代码变更';
  if (/\bgit\s+branch\b/.test(lower)) return '查看分支';
  if (/\bgit\s+rev-parse\b/.test(lower)) return '解析 Git 引用';
  if (/\bgit\s+grep\b/.test(lower)) return '搜索仓库内容';
  if (/\b(pnpm|npm|yarn|bun|gradle|gradlew|hvigorw?)\b[^\n]*(typecheck|tsc\s+--noemit)/.test(lower)) {
    return '类型检查';
  }
  if (/\b(pnpm|npm|yarn|bun|gradle|gradlew|hvigorw?)\b[^\n]*(lint|checkstyle)/.test(lower)) {
    return '代码检查';
  }
  if (/\b(pnpm|npm|yarn|bun|gradle|gradlew|hvigorw?)\b[^\n]*(test|jest|vitest)/.test(lower)) {
    return '运行测试';
  }
  if (/\b(pnpm|npm|yarn|bun|gradle|gradlew|hvigorw?)\b[^\n]*(build|assemblehap|assemble)/.test(lower)) {
    return '构建';
  }
  if (/^(pwd|\/bin\/pwd)(\s|$)/.test(lower)) return '查看当前目录';
  if (/^(node|bun)\s+/.test(lower)) return '运行 Node.js 脚本';
  if (/^(python|python3)\s+/.test(lower)) return '运行 Python 脚本';
  return '';
}

function commandPresentation(
  toolName: string,
  input: Record<string, Object> | null,
): ToolActionPresentation[] {
  const command = commandText(input);
  const description = input === null ? '' : readStr(input, 'description').trim();
  if (description.length > 0) {
    return [makePresentation(truncate(description, LABEL_TEXT_LIMIT), truncate(command, DETAIL_TEXT_LIMIT))];
  }
  if (toolName === 'exec') {
    const actions = structuredCommandActions(input, command);
    if (actions.length > 0) return actions;
  }
  const simple = simpleCommandIntent(command);
  if (simple !== null) return [intentPresentation(simple, command)];
  const known = knownCommandLabel(command);
  if (known.length > 0) return [makePresentation(known, truncate(command, DETAIL_TEXT_LIMIT))];
  if (command.length === 0) return [makePresentation(toolName.length > 0 ? toolName : 'tool')];
  return [makePresentation('运行命令', truncate(command, DETAIL_TEXT_LIMIT))];
}

function namespacedPresentation(toolName: string, input: Record<string, Object> | null): ToolActionPresentation | null {
  if (toolName.startsWith('mcp__')) {
    const parts = toolName.slice('mcp__'.length).split('__');
    if (parts.length >= 2 && parts[0].length > 0) {
      const tool = parts.slice(1).join('__');
      if (tool.length > 0) {
        return makePresentation(`调用 ${parts[0]} · ${humanizeToolToken(tool)}`, firstDetail(input));
      }
    }
  }
  if (toolName.startsWith('mcp:')) {
    const parts = toolName.split(':');
    if (parts.length >= 3 && parts[1].length > 0) {
      return makePresentation(`调用 ${parts[1]} · ${humanizeToolToken(parts.slice(2).join(':'))}`, firstDetail(input));
    }
  }
  if (toolName.startsWith('dynamic:')) {
    const parts = toolName.split(':');
    if (parts.length >= 3) {
      return makePresentation(`调用 ${parts[1]} · ${humanizeToolToken(parts.slice(2).join(':'))}`, firstDetail(input));
    }
    if (parts.length === 2) return makePresentation(`调用 ${humanizeToolToken(parts[1])}`, firstDetail(input));
  }
  if (toolName.startsWith('collab:')) {
    return makePresentation(`调用 ${humanizeToolToken(toolName.slice('collab:'.length))}`, firstDetail(input));
  }
  return null;
}

function fileChangePresentation(input: Record<string, Object> | null): ToolActionPresentation | null {
  if (input === null || !Array.isArray(input['changes'])) return null;
  const changes = input['changes'] as Object[];
  if (changes.length === 0) return null;
  if (changes.length > 1) return makePresentation(`更新 ${changes.length} 个文件`);
  const change = changes[0];
  if (change === null || typeof change !== 'object' || Array.isArray(change)) return null;
  const record = change as Record<string, Object>;
  const kindValue = record['kind'];
  if (kindValue === null || typeof kindValue !== 'object' || Array.isArray(kindValue)) return null;
  const kind = kindValue as Record<string, Object>;
  const type = readStr(kind, 'type');
  const path = readStr(record, 'path');
  if (type.length === 0 || path.length === 0) return null;
  const movePath = readStr(kind, 'move_path') || readStr(kind, 'movePath')
    || readStr(record, 'move_path') || readStr(record, 'movePath');
  if (movePath.length > 0) {
    return makePresentation(
      `重命名 ${basename(path)} → ${basename(movePath)}`,
      `${path} → ${movePath}`,
    );
  }
  if (type === 'add') return filePresentation('创建', path);
  if (type === 'delete') return filePresentation('删除', path);
  if (type === 'update') return filePresentation('编辑', path);
  return filePresentation('更新', path);
}

/** 返回一个工具在工作列表中的 1..N 条动作；所有消费面必须复用此函数。 */
export function projectToolUseActions(
  toolName: string,
  inputRaw: string,
  inputText: string,
): ToolActionPresentation[] {
  const input = toolInput(inputRaw, inputText);
  const namespaced = namespacedPresentation(toolName, input);
  if (namespaced !== null) return [namespaced];

  if (toolName === 'Bash' || toolName === 'bash' || toolName === 'exec') {
    return commandPresentation(toolName, input);
  }

  if (toolName === 'file_change') {
    const fileChange = fileChangePresentation(input);
    if (fileChange !== null) return [fileChange];
  }

  if (toolName === 'Read' || toolName === 'read' || toolName === 'ls') {
    const path = input === null ? '' : (readStr(input, 'file_path') || readStr(input, 'path'));
    if (path.length > 0) return [filePresentation('读取', path, 'read')];
  }
  if (toolName === 'Edit' || toolName === 'MultiEdit' || toolName === 'edit') {
    const path = input === null ? '' : (readStr(input, 'file_path') || readStr(input, 'path'));
    if (path.length > 0) return [filePresentation('编辑', path)];
  }
  if (toolName === 'Write' || toolName === 'write') {
    const path = input === null ? '' : (readStr(input, 'file_path') || readStr(input, 'path'));
    if (path.length > 0) return [filePresentation('创建', path)];
  }
  if (toolName === 'Grep' || toolName === 'grep' || toolName === 'Glob' || toolName === 'find') {
    const pattern = input === null ? '' : readStr(input, 'pattern');
    const path = input === null ? '' : readStr(input, 'path');
    if (pattern.length > 0) {
      return [makePresentation(`搜索 ${truncate(pattern, LABEL_TEXT_LIMIT)}`, path, 'search')];
    }
  }
  if (toolName === 'WebFetch') {
    const url = input === null ? '' : readStr(input, 'url');
    if (url.length > 0) return [makePresentation(`访问 ${truncate(url, LABEL_TEXT_LIMIT)}`)];
  }
  if (toolName === 'WebSearch' || toolName === 'web_search') {
    const query = input === null ? '' : readStr(input, 'query');
    if (query.length > 0) return [makePresentation(`搜索 ${truncate(query, LABEL_TEXT_LIMIT)}`, '', 'search')];
  }
  if (toolName === 'TodoWrite' || toolName === 'update_plan') return [makePresentation('更新待办')];
  if (toolName === 'Task' || toolName === 'Agent') {
    const description = input === null ? '' : readStr(input, 'description');
    const subagentType = input === null ? '' : readStr(input, 'subagent_type');
    return [makePresentation(description.length > 0 ? description : toolName, subagentType)];
  }
  return [makePresentation(`调用 ${toolName.length > 0 ? toolName : 'tool'}`, firstDetail(input))];
}
