import { util } from '@kit.ArkTS';
import { ChatCloudAuthSource, ChatCloudHttpSource } from './ChatAuthenticatedRequest';
import { ChatInviteShareClient, ChatInviteServiceScope, createOfficialChatInviteShares } from './ChatInviteShares';
import { ChatInvitationStore } from './ChatInvitationStore';
import { ChatServerApi } from './ChatServerApi';
import { HarmonyHttp } from '../../network/HarmonyHttp';
export class ChatInviteServices {
  shares: ChatInviteShareClient;
  invitation: ChatInvitationStore;
  constructor(shares: ChatInviteShareClient, invitation: ChatInvitationStore) { this.shares=shares; this.invitation=invitation; }
  dispose(): void { this.invitation.dispose(); }
}
/** Complete account-scoped share + preview/join bundle, using the caller's existing AuthStore. */
export function createOfficialChatInviteServices(owner: string, api: ChatServerApi, auth: ChatCloudAuthSource,
  scope: ChatInviteServiceScope, http: ChatCloudHttpSource = new HarmonyHttp()): ChatInviteServices {
  const shares=createOfficialChatInviteShares(auth,scope,http);
  const invitation=new ChatInvitationStore(owner,api,shares,(): string=>util.generateRandomUUID(),scope.current);
  return new ChatInviteServices(shares,invitation);
}
