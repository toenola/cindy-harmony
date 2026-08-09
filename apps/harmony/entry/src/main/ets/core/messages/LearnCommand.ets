/** `/learn` 属于 Desktop command；显式同名 Agent Skill 时必须让行。 */

export class LearnCommandMatch {
  matched: boolean = false;
  input: string = '';
  sourceKind: string = 'session';
  hubSlug: string = '';
}

export function parseLearnCommand(text: string, selectedAgentSkill: boolean): LearnCommandMatch {
  const out = new LearnCommandMatch();
  if (selectedAgentSkill) return out;
  const match = text.trim().match(/^\/learn(?:\s+([\s\S]*))?$/);
  if (match === null) return out;
  out.matched = true;
  const args = (match[1] ?? '').trim();
  const hub = args.match(/^hub:([^\s]+)(?:\s+([\s\S]*))?$/);
  if (hub !== null) {
    out.sourceKind = 'hub';
    out.hubSlug = hub[1];
    out.input = (hub[2] ?? '').trim();
  } else {
    out.input = args;
    out.sourceKind = args.length > 0 ? 'freetext' : 'session';
  }
  return out;
}

export function buildLearnStartRequest(
  command: LearnCommandMatch,
  sessionId: string,
): Record<string, Object> {
  const request: Record<string, Object> = {};
  request['input'] = command.input;
  request['sourceKind'] = command.sourceKind;
  request['originSessionId'] = sessionId;
  if (command.hubSlug.length > 0) request['hubSlug'] = command.hubSlug;
  return request;
}
