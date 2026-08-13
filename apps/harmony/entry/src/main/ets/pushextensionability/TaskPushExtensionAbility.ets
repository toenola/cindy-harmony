import { PushExtensionAbility, pushCommon } from '@kit.PushKit';

/**
 * Push Kit data-message entry point. The Desktop plugin currently sends a notification message,
 * which HarmonyOS displays directly; declaring this extension also keeps the client compatible
 * with Push Kit data delivery without relying on Android HMS components.
 */
export default class TaskPushExtensionAbility extends PushExtensionAbility {
  onReceiveMessage(payload: pushCommon.PushPayload): void {
    // Notification messages are rendered by Push Kit. Never log payload.data because it can
    // contain a task identifier. A future data-message sender may publish its own notification here.
    void payload;
  }
}
