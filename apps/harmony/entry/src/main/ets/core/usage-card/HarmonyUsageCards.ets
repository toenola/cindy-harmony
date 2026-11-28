import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { UsageCardData, UsageCardStorage, UsageCardStore } from './UsageCardStore';
/** FormExtensionAbility is in the provider app process. Only this synchronous transaction adapter
 * writes the shared ledger; there are no asynchronous read-modify-write windows. */
export class HarmonyUsageCardStorage implements UsageCardStorage {
  private path: string;
  constructor(context: common.Context) { this.path = context.filesDir + '/usage-cards-v1.json'; }
  read(): string { return fileIo.accessSync(this.path) ? fileIo.readTextSync(this.path) : ''; }
  write(json: string): void {
    const temp = this.path + '.tmp', file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, json); fileIo.fsyncSync(file.fd); } finally { fileIo.closeSync(file); }
    fileIo.renameSync(temp, this.path);
  }
}
export function createHarmonyUsageCardStore(context: common.Context): UsageCardStore {
  return new UsageCardStore(new HarmonyUsageCardStorage(context), async (id: string, data: UsageCardData): Promise<void> => {
    await formProvider.updateForm(id, formBindingData.createFormBindingData(JSON.stringify(data)));
  });
}
