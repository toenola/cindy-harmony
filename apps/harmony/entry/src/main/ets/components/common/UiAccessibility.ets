import { common } from '@kit.AbilityKit';

/** Resolve the same localized string used by visible Text before composing a single accessible name. */
export function uiAccessibleString(context: UIContext, value: ResourceStr | undefined): string {
  if (value === undefined) return '';
  if (typeof value === 'string') return value;
  const host = context.getHostContext() as common.UIAbilityContext | undefined;
  try {
    return host?.resourceManager.getStringSync(value) ?? '';
  } catch (_error) {
    return '';
  }
}
