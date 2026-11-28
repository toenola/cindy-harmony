import { ComposerModelOption } from '../ComposerCatalog';
import { readBool, readObj, readStr, recordOrEmpty } from '../tasks/TaskModels';
import { ModelRoute } from './ModelRoutingModels';
export class RoutedCreationRuntime {
  agentKind: string = ''; permissionMode: string = 'ask'; legacyPlanRestore: string = '';
  planMode: boolean = false; planModeArm: boolean = false; planModeEnabled: boolean = false;
  effort: string = ''; fastMode: boolean | string = false;
}
/** Target-engine capabilities, never the underlying draft's old engine, own runtime options.
 * Permission matching mirrors maker-shared permission-mode: ask/default aliases, safe fallback,
 * and no automatic promotion to Full access. Routing itself does not grant extra permissions. */
export function routedCreationRuntime(route: ModelRoute, capabilities: Record<string, Object>, model: ComposerModelOption | undefined,
  preferredPermission: string, planEnabled: boolean): RoutedCreationRuntime {
  if (['cc', 'codex', 'pi'].indexOf(route.agentKind) < 0) throw new Error('MODEL_ROUTING_ENGINE_UNSUPPORTED');
  const out = new RoutedCreationRuntime(); out.agentKind = route.agentKind === 'cc' ? 'claude-code' : route.agentKind;
  const modes = capabilities['permissionModes'], ids: string[] = [];
  if (Array.isArray(modes)) {
    for (const value of modes as Object[]) {
      const id = typeof value === 'string' ? value : readStr(recordOrEmpty(value), 'id');
      if (id && !ids.includes(id)) ids.push(id);
    }
  }
  const normal = ids.filter((id: string): boolean => id !== 'plan');
  const preferred = preferredPermission === 'default' && normal.includes('ask') ? 'ask'
    : preferredPermission === 'ask' && normal.includes('default') ? 'default' : preferredPermission;
  out.permissionMode = normal.includes(preferred) ? preferred : normal.includes('ask') ? 'ask'
    : normal.includes('default') ? 'default' : normal.find((id: string): boolean => id !== 'bypassPermissions') ?? 'ask';
  const nativePlan = readBool(readObj(capabilities, 'planMode'), 'supported', false);
  if (planEnabled && !nativePlan && !ids.includes('plan')) throw new Error('MODEL_ROUTING_PLAN_UNSUPPORTED');
  out.planModeEnabled = planEnabled; out.planMode = planEnabled && nativePlan; out.planModeArm = out.planMode;
  if (planEnabled && !nativePlan) { out.legacyPlanRestore = out.permissionMode; out.permissionMode = 'plan'; }
  // A mode's unsupported effort is omitted, rather than substituted with the old draft's
  // or the target catalog's default. The engine then owns its ordinary default.
  out.effort = model && !model.efforts.includes(route.effort) ? '' : route.effort;
  const fast = route.fastMode === true || route.fastMode === 'ultrafast';
  const hasFast = readBool(capabilities, 'hasFastMode', false) && (!model || model.supportsFastMode);
  const ultraSupported = out.agentKind === 'codex' && (!model || model.supportsUltrafastMode);
  out.fastMode = fast && hasFast && (route.fastMode !== 'ultrafast' || ultraSupported) ? route.fastMode : false;
  return out;
}
