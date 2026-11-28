import { common } from '@kit.AbilityKit';
import { harmonyV12String } from '../core/HarmonyStrings';
import { ModelRoutingLabels } from './model-routing/ModelRoutingPanel';

export function modelRoutingLabels(context: common.Context | undefined): ModelRoutingLabels {
  const labels = new ModelRoutingLabels();
  labels.title = harmonyV12String(context, 'v139_route_title');
  labels.empty = harmonyV12String(context, 'v139_route_empty');
  labels.unsupported = harmonyV12String(context, 'v139_route_unsupported');
  labels.loading = harmonyV12String(context, 'v139_route_loading');
  labels.unavailable = harmonyV12String(context, 'v139_route_unavailable');
  labels.refresh = harmonyV12String(context, 'v139_route_refresh');
  labels.unbind = harmonyV12String(context, 'v139_route_unbind');
  labels.managed = harmonyV12String(context, 'v139_route_managed');
  labels.fixed = harmonyV12String(context, 'v139_route_fixed');
  labels.pending = harmonyV12String(context, 'v139_route_pending');
  labels.fallback = harmonyV12String(context, 'v139_route_fallback');
  labels.kept = harmonyV12String(context, 'v139_route_kept');
  labels.unsupportedEngine = harmonyV12String(context, 'v139_route_engine');
  labels.selected = harmonyV12String(context, 'v139_route_selected');
  labels.ordinary = harmonyV12String(context, 'v139_route_ordinary');
  return labels;
}
