import { Want } from '@kit.AbilityKit';
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { createHarmonyUsageCardStore } from '../core/usage-card/HarmonyUsageCards';
import { UsageCardData } from '../core/usage-card/UsageCardStore';

/** API26 verified lifecycle. It reads cached authorized summaries, never starts AppServices or WS. */
export default class UsageFormExtensionAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const rawId = want.parameters?.[formInfo.FormParam.IDENTITY_KEY];
    const id = typeof rawId === 'string' ? rawId : '';
    const rawDevice = want.parameters?.['usageDeviceId'];
    const device = typeof rawDevice === 'string' ? rawDevice : '';
    const rawDimension = want.parameters?.[formInfo.FormParam.DIMENSION_KEY];
    const dimension = typeof rawDimension === 'number' ? rawDimension : 2;
    const store = createHarmonyUsageCardStore(this.context);
    try { return formBindingData.createFormBindingData(JSON.stringify(store.register(id, device, dimension))); }
    catch { return formBindingData.createFormBindingData(JSON.stringify(new UsageCardData())); }
  }
  onUpdateForm(_formId: string): void {
    // System-controlled refresh budget; age is recomputed even when the app cannot get new data.
    void createHarmonyUsageCardStore(this.context).publishAll().catch(() => {});
  }
  onSizeChanged(formId: string, dimension: formInfo.FormDimension, _rect: formInfo.Rect): void {
    void createHarmonyUsageCardStore(this.context).resize(formId, dimension).catch(() => {});
  }
  onRemoveForm(formId: string): void { createHarmonyUsageCardStore(this.context).remove(formId); }
  onAcquireFormState(_want: Want): formInfo.FormState { return formInfo.FormState.READY; }
}
