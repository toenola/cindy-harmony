/** 任务完成推送的本机用户 override；系统默认关闭，关闭时不落默认值。 */
import { common } from '@kit.AbilityKit';
import { SecureStore } from '../storage/SecureStore';

const KEY = 'notifications.taskCompletionPush.enabled.v1';

export function parseTaskCompletionPushEnabled(raw: string): boolean {
  return raw === 'true';
}

export function serializeTaskCompletionPushEnabled(enabled: boolean): string {
  return enabled ? 'true' : '';
}

export class TaskCompletionPushPreferenceStore {
  private readonly store: SecureStore = new SecureStore();
  private enabled: boolean = false;

  async init(context: common.Context): Promise<void> {
    await this.store.init(context);
    this.enabled = parseTaskCompletionPushEnabled(await this.store.get(KEY, ''));
  }

  readEnabled(): boolean {
    return this.enabled;
  }

  async setEnabled(enabled: boolean): Promise<void> {
    if (enabled === this.enabled) return;
    if (enabled) await this.store.set(KEY, serializeTaskCompletionPushEnabled(true));
    else await this.store.remove(KEY);
    this.enabled = enabled;
  }
}
