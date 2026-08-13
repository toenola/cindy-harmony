import { common, UIAbility } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';
import { TaskCompletionPushPreferenceStore } from './TaskCompletionPushPreferenceStore';

export type TaskCompletionPushStatus = 'idle' | 'loading' | 'ready' | 'error';

/** Push Kit errors contain no token data; turn the stable business code into an actionable hint. */
export function taskCompletionPushErrorMessage(error: Object, notificationEnabled: boolean): string {
  if (!notificationEnabled) return '需要开启通知权限';
  const businessError = error as BusinessError;
  switch (businessError.code) {
    case 1000900008:
      return '无法连接华为 Push 服务（1000900008）';
    case 1000900009:
      return '华为 Push 服务内部错误（1000900009）';
    case 1000900010:
      return '应用身份与华为控制台配置不匹配（1000900010）';
    case 1000900011:
      return '当前网络不可用（1000900011）';
    case 1000900012:
      return '尚未在华为控制台开通 Push Kit（1000900012）';
    case 1000900013:
      return '应用与设备所在区域不匹配（1000900013）';
    case 1000900014:
      return '当前设备不支持获取 Push Token（1000900014）';
    default:
      return businessError.code > 0
        ? `Push Token 获取失败（${businessError.code}）`
        : 'Push Token 获取失败，请重试';
  }
}

export class TaskCompletionPushService {
  private readonly preference: TaskCompletionPushPreferenceStore;
  private listeners: Array<() => void> = [];
  private ability: UIAbility | null = null;
  private tokenUpdateAttached: boolean = false;
  private readonly tokenUpdateCallback: (token: string) => void;
  enabled: boolean = false;
  notificationEnabled: boolean = false;
  token: string = '';
  status: TaskCompletionPushStatus = 'idle';
  errorMessage: string = '';

  constructor(preference: TaskCompletionPushPreferenceStore) {
    this.preference = preference;
    this.tokenUpdateCallback = (token: string): void => {
      if (!this.enabled || token.length === 0) return;
      this.token = token;
      this.status = 'ready';
      this.errorMessage = '';
      this.emitChanged();
    };
  }

  async init(context: common.Context): Promise<void> {
    this.enabled = this.preference.readEnabled();
    await this.refreshNotificationStatus();
    if (this.enabled) await this.refreshToken();
  }

  attachAbility(ability: UIAbility): void {
    this.ability = ability;
    if (this.tokenUpdateAttached) return;
    pushService.on('tokenUpdate', ability, this.tokenUpdateCallback);
    this.tokenUpdateAttached = true;
  }

  detachAbility(): void {
    if (!this.tokenUpdateAttached) return;
    pushService.off('tokenUpdate', this.tokenUpdateCallback);
    this.tokenUpdateAttached = false;
    this.ability = null;
  }

  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return () => {
      const index = this.listeners.indexOf(listener);
      if (index >= 0) this.listeners.splice(index, 1);
    };
  }

  async enable(context: common.UIAbilityContext): Promise<boolean> {
    if (this.status === 'loading') return false;
    this.status = 'loading';
    this.errorMessage = '';
    this.emitChanged();
    try {
      let allowed = await notificationManager.isNotificationEnabled();
      if (!allowed) {
        await notificationManager.requestEnableNotification(context);
        allowed = await notificationManager.isNotificationEnabled();
      }
      this.notificationEnabled = allowed;
      if (!allowed) throw new Error('notification-disabled');
      const token = await pushService.getToken();
      if (token.length === 0) throw new Error('empty-token');
      await this.preference.setEnabled(true);
      this.enabled = true;
      this.token = token;
      this.status = 'ready';
      this.errorMessage = '';
      this.emitChanged();
      return true;
    } catch (error) {
      this.enabled = false;
      this.token = '';
      this.status = 'error';
      this.errorMessage = taskCompletionPushErrorMessage(error, this.notificationEnabled);
      await this.preference.setEnabled(false);
      this.emitChanged();
      return false;
    }
  }

  async disable(): Promise<boolean> {
    if (this.status === 'loading') return false;
    this.status = 'loading';
    this.errorMessage = '';
    this.emitChanged();
    try {
      if (this.enabled || this.token.length > 0) await pushService.deleteToken();
      await this.preference.setEnabled(false);
      this.enabled = false;
      this.token = '';
      this.status = 'idle';
      this.emitChanged();
      return true;
    } catch (error) {
      this.status = 'error';
      this.errorMessage = '关闭推送失败，请稍后重试';
      this.emitChanged();
      return false;
    }
  }

  async refreshToken(): Promise<boolean> {
    if (!this.enabled || this.status === 'loading') return false;
    this.status = 'loading';
    this.errorMessage = '';
    this.emitChanged();
    try {
      await this.refreshNotificationStatus();
      if (!this.notificationEnabled) throw new Error('notification-disabled');
      const token = await pushService.getToken();
      if (token.length === 0) throw new Error('empty-token');
      this.token = token;
      this.status = 'ready';
      this.emitChanged();
      return true;
    } catch (error) {
      this.token = '';
      this.status = 'error';
      this.errorMessage = taskCompletionPushErrorMessage(error, this.notificationEnabled);
      this.emitChanged();
      return false;
    }
  }

  async refreshNotificationStatus(): Promise<void> {
    try {
      this.notificationEnabled = await notificationManager.isNotificationEnabled();
    } catch (_) {
      this.notificationEnabled = false;
    }
    this.emitChanged();
  }

  private emitChanged(): void {
    for (let i = 0; i < this.listeners.length; i++) this.listeners[i]();
  }
}
