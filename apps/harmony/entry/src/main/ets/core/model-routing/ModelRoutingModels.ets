/** Host-owned routing projection. Wire semantics: upstream 91179cedad hostModelGroups/sourceRouteProviders. */
import { readObj, readStr, recordOrEmpty } from '../tasks/TaskModels';

export class ModelRoute {
  agentKind: string = '';
  providerId: string = '';
  model: string = '';
  agentDeviceId: string = '';
  effort: string = '';
  fastMode: boolean | string = false;
}
export class ModelRouteRow {
  id: string = '';
  name: string = '';
  strategy: string = '';
  effort: string = '';
  sources: number = 0;
  parentId: string = '';
  parentName: string = '';
  candidates: ModelRoute[] = [];
}
export class ModelRouteSource {
  providerId: string = '';
  agentDeviceId: string = '';
  off: boolean = false;
}
export class ModelSourceGroup {
  id: string = '';
  name: string = '';
  sources: ModelRouteSource[] = [];
}
export class ModelRoutingCatalog {
  routes: ModelRouteRow[] = [];
  sourceRoutes: ModelSourceGroup[] = [];
  expandedRoutes: ModelRouteRow[] = [];
}
export class ModelRoutingResult {
  outcome: string = '';
  decisionId: string = '';
  groupName: string = '';
  route: ModelRoute | null = null;
  modelName: string = '';
  sourceName: string = '';
  why: string = '';
  usedPercent: number | null = null;
  resetAtMs: number | null = null;
  limitedUntilMs: number | null = null;
  exceptions: string[] = [];
  viaRouteNames: string[] = [];
}
export class ModelRoutingBinding {
  routeId: string = '';
  routeName: string = '';
  parentId: string = '';
  parentName: string = '';
  autoSwitch: boolean = true;
  pendingSwitch: boolean = false;
  isSourceRoute: boolean = false;
}
export class ModelRoutingOffer {
  routeId: string = '';
  groupName: string = '';
  route: ModelRoute = new ModelRoute();
  modelName: string = '';
  sourceName: string = '';
  crossEngine: boolean = false;
  crossLocation: boolean = false;
}
function text(raw: Record<string, Object>, key: string, max: number = 256): string {
  return readStr(raw, key).trim().slice(0, max);
}
function finite(value: Object | undefined): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}
export function parseModelRoute(value: Object | undefined): ModelRoute | null {
  const raw = recordOrEmpty(value), route = new ModelRoute();
  route.agentKind = text(raw, 'agentKind');
  route.providerId = text(raw, 'providerId'); route.model = text(raw, 'model');
  if (['cc', 'codex', 'pi', 'acp'].indexOf(route.agentKind) < 0 || !route.providerId || !route.model
    || (route.agentKind === 'acp' && !route.providerId.startsWith('acp-plugin:'))) return null;
  route.agentDeviceId = text(raw, 'agentDeviceId'); route.effort = text(raw, 'effort', 32);
  route.fastMode = raw['fastMode'] === 'ultrafast' ? 'ultrafast' : raw['fastMode'] === true;
  return route;
}
function rows(value: Object | undefined, expanded: boolean): ModelRouteRow[] {
  if (!Array.isArray(value)) return [];
  const result: ModelRouteRow[] = [];
  for (const item of (value as Object[]).slice(0, expanded ? 128 : 32)) {
    const raw = recordOrEmpty(item), row = new ModelRouteRow();
    row.id = text(raw, 'id', expanded ? 128 : 64); row.name = text(raw, 'name', expanded ? 80 : 40);
    if (!row.id || !row.name || raw['hidden'] === true) continue;
    row.strategy = text(raw, 'pick', 32) || text(raw, 'strategy', 32);
    row.effort = text(raw, 'effort', 32);
    const candidates = raw['candidates'];
    if (Array.isArray(candidates)) {
      for (const candidate of (candidates as Object[]).slice(0, 16)) {
        if (recordOrEmpty(candidate)['off'] === true) continue;
        row.sources++;
        const route = parseModelRoute(candidate);
        if (route) row.candidates.push(route);
      }
    }
    if (expanded) {
      const parent = readObj(raw, 'parent');
      row.parentId = text(parent, 'id', 64); row.parentName = text(parent, 'name', 40);
      if (!row.parentId || !row.parentName || row.candidates.length === 0) continue;
    }
    result.push(row);
  }
  return result;
}
export function parseModelRoutingCatalog(value: Object | undefined): ModelRoutingCatalog | null {
  const raw = recordOrEmpty(value);
  if (!Array.isArray(raw['routes'])) return null;
  const catalog = new ModelRoutingCatalog();
  catalog.routes = rows(raw['routes'], false); catalog.expandedRoutes = rows(raw['expandedRoutes'], true);
  const sources = raw['sourceRoutes'];
  if (Array.isArray(sources)) {
    for (const item of (sources as Object[]).slice(0, 32)) {
      const data = recordOrEmpty(item), group = new ModelSourceGroup();
      group.id = text(data, 'id', 64); group.name = text(data, 'name', 40);
      if (!group.id || !group.name || data['hidden'] === true) continue;
      const members = data['sources'];
      if (!Array.isArray(members)) continue;
      for (const member of (members as Object[]).slice(0, 16)) {
        const m = recordOrEmpty(member), source = new ModelRouteSource();
        source.providerId = text(m, 'providerId'); source.agentDeviceId = text(m, 'agentDeviceId');
        source.off = m['off'] === true;
        if (source.providerId) group.sources.push(source);
      }
      if (group.sources.length > 0) catalog.sourceRoutes.push(group);
    }
  }
  return catalog;
}
export function parseModelRoutingResult(value: Object | undefined): ModelRoutingResult | null {
  const raw = recordOrEmpty(value), result = new ModelRoutingResult();
  result.outcome = text(raw, 'outcome'); result.groupName = text(raw, 'groupName', 40);
  result.decisionId = text(raw, 'decisionId', 64);
  if (result.outcome === 'missing' || result.outcome === 'unavailable') return result;
  if (result.outcome !== 'routed') return null;
  result.route = parseModelRoute(raw['route']);
  if (!result.route) return null;
  result.modelName = text(raw, 'modelName') || result.route.model;
  result.sourceName = text(raw, 'sourceName') || result.route.providerId;
  result.why = text(raw, 'pickWhy', 32) || text(raw, 'why', 32);
  const quota = readObj(raw, 'quota');
  result.usedPercent = finite(quota['usedPercent']); result.resetAtMs = finite(quota['resetAtMs']);
  const trace = raw['trace'];
  if (Array.isArray(trace)) {
    for (const entry of (trace as Object[]).slice(0, 256)) {
      const picked = recordOrEmpty(entry);
      if (picked['state'] === 'picked') { result.limitedUntilMs = finite(picked['limitedUntilMs']); break; }
    }
  }
  const exceptions = raw['exceptions'];
  if (Array.isArray(exceptions)) {
    for (const entry of (exceptions as Object[]).slice(0, 8)) {
      const ex = recordOrEmpty(entry), type = text(ex, 'type');
      if (['image', 'imageFallback', 'hours'].indexOf(type) < 0) continue;
      result.exceptions.push(type); result.viaRouteNames.push(text(ex, 'viaRouteName', 40));
    }
  }
  return result;
}
export function parseModelRoutingBinding(value: Object | undefined): ModelRoutingBinding | null {
  const raw = recordOrEmpty(value), selection = readObj(raw, 'selection');
  const binding = new ModelRoutingBinding();
  binding.routeId = text(selection, 'id', 128); binding.routeName = text(raw, 'routeName', 80);
  if (selection['type'] !== 'route' || !binding.routeId || !binding.routeName) return null;
  binding.parentId = text(raw, 'parentId', 64); binding.parentName = text(raw, 'parentName', 40);
  binding.autoSwitch = raw['autoSwitch'] !== false; binding.pendingSwitch = raw['pendingSwitch'] === true;
  binding.isSourceRoute = raw['isSourceRoute'] === true;
  return binding;
}
export function parseModelRoutingOffer(value: Object | undefined): ModelRoutingOffer | null {
  const raw = recordOrEmpty(value), selection = readObj(raw, 'selection');
  const route = parseModelRoute(value), offer = new ModelRoutingOffer();
  offer.routeId = text(selection, 'id', 128); offer.groupName = text(raw, 'groupName', 80);
  if (!route || selection['type'] !== 'route' || !offer.routeId || !offer.groupName) return null;
  offer.route = route; offer.modelName = text(raw, 'modelName') || route.model;
  offer.sourceName = text(raw, 'sourceName') || route.providerId;
  offer.crossEngine = raw['crossEngine'] === true; offer.crossLocation = raw['crossLocation'] === true;
  return offer;
}
/** Identity includes execution location: never merge same-name provider/model across computers. */
export function modelRouteKey(route: ModelRoute): string {
  return JSON.stringify([route.agentDeviceId, route.agentKind, route.providerId, route.model]);
}
export function modelRouteWire(route: ModelRoute): Record<string, Object> {
  const value: Record<string, Object> = {};
  value['agentKind'] = route.agentKind; value['providerId'] = route.providerId; value['model'] = route.model;
  if (route.agentDeviceId) value['agentDeviceId'] = route.agentDeviceId;
  return value;
}
/** Old drafts can inherit a merged source route, but disabled/hidden members remain ordinary choices. */
export function implicitModelRoute(catalog: ModelRoutingCatalog, current: ModelRoute): string {
  for (const row of catalog.expandedRoutes) {
    if (row.candidates.some((candidate: ModelRoute): boolean => modelRouteKey(candidate) === modelRouteKey(current))) return row.id;
  }
  return '';
}
/** Uses the existing model-group note schema; reason must be localized by the presentation owner. */
export function buildModelRoutingNote(result: ModelRoutingResult, keptModelName: string,
  reason: string, deviceName: (deviceId: string) => string): Record<string, Object> | null {
  if (result.outcome === 'missing') return null;
  if (result.outcome !== 'routed' || !result.route) {
    const kept: Record<string, Object> = {};
    kept['pluginName'] = result.groupName; kept['outcome'] = 'kept'; kept['modelName'] = keptModelName;
    kept['why'] = 'unavailable-route'; kept['source'] = 'model-group'; return kept;
  }
  const route = result.route;
  const source = result.sourceName + (route.agentDeviceId ? ' · ' + deviceName(route.agentDeviceId) : '');
  const note: Record<string, Object> = {};
  note['pluginName'] = result.groupName; note['outcome'] = 'routed';
  note['modelName'] = result.modelName + ' · ' + source; note['source'] = 'model-group';
  if (route.effort) note['effort'] = route.effort;
  if (reason) note['reason'] = reason;
  return note;
}
