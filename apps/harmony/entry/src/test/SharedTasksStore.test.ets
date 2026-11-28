import { describe, expect, it } from '@ohos/hypium';
import { SharedTasksStore } from '../main/ets/core/shared-tasks/SharedTasksStore';
import { SharedTaskAccess } from '../main/ets/core/shared-tasks/SharedTaskAccess';
import { SharedTasksHost, SharedTaskRequest, SharedTaskHostCommand, SharedTaskInvitation, SharedTaskDetail,
  SharedTaskGuestTransport, SharedTaskSessionTarget, sharedTaskHostPeerKey, sharedTaskCan, SharedTaskFault } from '../main/ets/core/shared-tasks/SharedTaskModels';
import { recordOrEmpty } from '../main/ets/core/tasks/TaskModels';

// Unit tier: production management and scoped access lifetimes. Existing content-export tests do
// not cover membership or guest transport. Minimal failure: one admission + one late result/revoke.
// In-memory ports; no real waits/I/O. Runtime budget <5s, awaiting Lead's serial verification.
function detail(): Object {
  return JSON.parse('{"sharedTaskId":"share","sessionId":"task","ownerAccountId":"owner","hostDeviceId":"host","title":"Shared task","revision":1,"status":"active","guests":[{"memberId":"member","accountId":"guest","version":1,"deviceIds":["phone"],"displayName":"Guest","joinedAt":1}]}') as Object;
}
function listing(): Object { const raw = JSON.parse('{"sharedTasks":[]}') as Record<string, Object>; const items: Object[] = [detail()]; raw['sharedTasks'] = items; return raw; }
class GuestTransport implements SharedTaskGuestTransport {
  target: SharedTaskSessionTarget = { sharedTaskId: 'share', sessionId: 'task', peer: sharedTaskHostPeerKey('share', 'host'),
    hostDeviceId: 'host', ownerAccountId: 'owner', title: 'Shared task', guest: true, transport: 'official-scoped' };
  closed: boolean = false;
  unsubscriptions: number = 0;
  notifyRevoked: () => void = (): void => {};
  finish: (value: Object) => void = (_value: Object): void => {};
  async invoke(_channel: string, _args: Object[]): Promise<Object | undefined> { return detail(); }
  subscribe(_listener: (channel: string, payload: Object) => void): () => void { return (): void => { this.unsubscriptions++; }; }
  async upload(_localUri: string, _name: string, _mime: string): Promise<string> { return 'shared-reference'; }
  fetch(_reference: string): Promise<Object | undefined> { return new Promise<Object>((resolve) => { this.finish = resolve; }); }
  onRevoked(listener: () => void): () => void { this.notifyRevoked = listener; return (): void => { this.notifyRevoked = (): void => {}; }; }
  close(): void { this.closed = true; }
}
class SharingHost implements SharedTasksHost {
  transport: GuestTransport = new GuestTransport();
  nextList: Object = listing();
  ownerCalls: number = 0;
  joinCalls: number = 0;
  revoked: string = '';
  async request(path: string, _options: SharedTaskRequest): Promise<Object | undefined> {
    if (this.revoked && path.endsWith('/' + this.revoked)) throw new SharedTaskFault('NOT_FOUND', 404);
    if (path.endsWith('/leave')) return JSON.parse('{"status":"left","memberId":"member"}') as Object;
    return path.endsWith('/share') ? detail() : this.nextList;
  }
  async ownerInvoke(_device: string, _command: SharedTaskHostCommand): Promise<Object | undefined> { this.ownerCalls++; return detail(); }
  parseInvitation(input: string): SharedTaskInvitation | null {
    if (input !== 'valid') return null;
    const result: SharedTaskInvitation = { kind: 'official', invitation: 'token', server: 'official', sharedTaskId: '' }; return result;
  }
  async join(_invitation: SharedTaskInvitation, _name: string, _current: () => boolean): Promise<Object | undefined> {
    this.joinCalls++; return JSON.parse('{"sharedTaskId":"share","memberId":"member","status":"joined","created":true}') as Object;
  }
  async openGuest(_detail: SharedTaskDetail): Promise<SharedTaskGuestTransport> { return this.transport; }
  async openOwner(_detail: SharedTaskDetail): Promise<void> { this.ownerCalls++; }
  invitationLink(_invitation: string, _detail: SharedTaskDetail): string { return 'invitation'; }
}
export default function sharedTasksStoreTests(): void {
  describe('SharedTasksStore', () => {
    it('joining_opens_authenticated_scoped_task_and_never_an_owner_link', 0, async () => {
      const host = new SharingHost(), store = new SharedTasksStore(host);
      store.configure('guest:1', 'guest', 'Guest', true); store.setVisible(true); await store.join('valid');
      expect(store.access?.target.peer).assertEqual(sharedTaskHostPeerKey('share', 'host'));
      expect(host.ownerCalls).assertEqual(0); expect(host.joinCalls).assertEqual(1); store.dispose();
    });
    it('invalid_invitation_does_not_call_any_join_endpoint', 0, async () => {
      const host = new SharingHost(), store = new SharedTasksStore(host);
      store.configure('guest:1', 'guest', 'Guest', true); await store.join('foreign');
      expect(host.joinCalls).assertEqual(0); expect(store.issue).assertEqual('invitation'); store.dispose();
    });
    it('guest_cannot_invite_remove_members_or_close_host_sharing', 0, async () => {
      const host = new SharingHost(), store = new SharedTasksStore(host);
      store.configure('guest:1', 'guest', 'Guest', true); await store.join('valid');
      await store.invite(); await store.remove('member'); await store.closeSharing();
      expect(host.ownerCalls).assertEqual(0); expect(store.issue).assertEqual('forbidden'); store.dispose();
    });
    it('leaving_closes_scoped_transport_and_clears_task_access', 0, async () => {
      const host = new SharingHost(), store = new SharedTasksStore(host);
      store.configure('guest:1', 'guest', 'Guest', true); await store.join('valid'); await store.leave();
      expect(host.transport.closed).assertTrue(); expect(store.access === null).assertTrue(); expect(store.ended).assertTrue(); store.dispose();
    });
    it('revocation_invalidates_inflight_media_and_releases_subscriptions', 0, async () => {
      const transport = new GuestTransport();
      const access = new SharedTaskAccess(transport, (): boolean => true, (): void => {});
      access.subscribe((_channel: string, _payload: Object): void => {});
      const read = access.fetch('/task/file'); let rejected = false;
      const checked = read.catch((): void => { rejected = true; });
      transport.notifyRevoked(); transport.finish(detail()); await checked;
      expect(rejected).assertTrue(); expect(transport.closed).assertTrue(); expect(transport.unsubscriptions).assertEqual(1);
    });
    it('unavailable_other_management_task_does_not_revoke_current_guest_task', 0, async () => {
      const host = new SharingHost(), store = new SharedTasksStore(host);
      store.configure('guest:1', 'guest', 'Guest', true); store.setVisible(true); await store.refresh(); await store.join('valid');
      store.setTaskVisible(true); await store.refresh(); host.revoked = 'other'; store.select('other'); await store.refresh();
      expect(host.transport.closed).assertFalse(); expect(store.access?.active).assertTrue(); store.dispose();
    });
    it('active_guest_revocation_is_still_watched_when_management_shows_the_directory', 0, async () => {
      const host = new SharingHost(), store = new SharedTasksStore(host);
      store.configure('guest:1', 'guest', 'Guest', true); store.setVisible(true); await store.refresh(); await store.join('valid');
      store.setTaskVisible(true); await store.refresh(); host.revoked = 'share'; store.showList(); await store.refresh();
      expect(host.transport.closed).assertTrue(); expect(store.access === null).assertTrue(); store.dispose();
    });
    it('partial_authority_list_retains_membership_while_guest_controls_stay_owner_only', 0, async () => {
      const host = new SharingHost(), store = new SharedTasksStore(host);
      store.configure('guest:1', 'guest', 'Guest', true); store.setVisible(true); await store.refresh();
      host.nextList = JSON.parse('{"sharedTasks":[],"unavailableSharedTaskIds":["share"]}') as Object; await store.refresh();
      expect(store.items.length).assertEqual(1);
      expect(sharedTaskCan(true, 'agent.configure')).assertFalse(); expect(sharedTaskCan(true, 'approval.resolve', false, true)).assertFalse();
      expect(sharedTaskCan(true, 'input.edit', true)).assertTrue(); expect(sharedTaskCan(true, 'file.write')).assertTrue(); store.dispose();
    });
  });
}
