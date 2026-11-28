import { describe, expect, it } from '@ohos/hypium';
import { SharedTaskScopeCodec, SharedTaskSocketIdentity, withoutSharedTaskField, parseSharedTaskPeerKey, sharedTaskGuestPeerKey } from '../main/ets/core/shared-tasks/SharedTaskScope';
import { sharedTaskHostPeerKey } from '../main/ets/core/shared-tasks/SharedTaskModels';
import { recordOrEmpty } from '../main/ets/core/tasks/TaskModels';

// Unit tier: exact production socket codec protects the cross-account trust boundary; management
// Store fakes cannot prove wire identity. Minimum is a single forged/old scoped frame. No I/O/waits.
const identity: SharedTaskSocketIdentity = { sharedTaskId: 'share', hostDeviceId: 'host', memberId: 'member' };
function codec(): SharedTaskScopeCodec {
  const value = new SharedTaskScopeCodec(identity, 'guest');
  value.decode('{"v":1,"kind":"hello-ack","payload":{"serverProtocolVersion":1,"deviceId":"phone","userId":"guest","capabilities":["shared-task-v2"]}}');
  return value;
}
function frame(): Record<string, Object> {
  return JSON.parse('{"v":1,"kind":"invoke-result","id":"req","src":"host","dst":"phone","sharedTask":{"sharedTaskId":"share","source":{"role":"host"},"target":{"role":"guest","memberId":"member"}},"payload":{"ok":true,"result":"task-data"}}') as Record<string, Object>;
}
export default function sharedTaskScopeTests(): void {
  describe('SharedTaskScope', () => {
    it('outgoing_scoped_peer_becomes_physical_destination_with_relay_authored_source', 0, () => {
      const wire = JSON.parse('{"v":1,"kind":"invoke","src":"fabricated","dst":"","payload":{"channel":"local-db:sessions:get","args":["task"]}}') as Record<string, Object>;
      wire['dst'] = sharedTaskHostPeerKey('share', 'host');
      const result = recordOrEmpty(JSON.parse(codec().encode(JSON.stringify(wire))) as Object);
      expect(result['dst']).assertEqual('host'); expect(result['src'] === undefined).assertTrue();
      expect(recordOrEmpty(result['sharedTask'])['source'] === undefined).assertTrue();
    });
    it('verified_host_frame_maps_only_to_canonical_shared_task_keys', 0, () => {
      const text = codec().decode(JSON.stringify(frame()));
      const result = recordOrEmpty(JSON.parse(text ?? '{}') as Object);
      expect(result['src']).assertEqual(sharedTaskHostPeerKey('share', 'host'));
      expect(result['dst']).assertEqual(sharedTaskGuestPeerKey('share', 'member', 'phone'));
    });
    it('unscoped_owner_frame_never_completes_guest_request', 0, () => {
      const raw = withoutSharedTaskField(frame(), 'sharedTask'); expect(codec().decode(JSON.stringify(raw)) === null).assertTrue();
    });
    it('wrong_task_member_or_physical_source_are_rejected', 0, () => {
      const wrongTask = frame(); recordOrEmpty(wrongTask['sharedTask'])['sharedTaskId'] = 'other';
      const wrongMember = frame(); recordOrEmpty(recordOrEmpty(wrongMember['sharedTask'])['target'])['memberId'] = 'other';
      const wrongHost = frame(); wrongHost['src'] = 'other-host';
      expect(codec().decode(JSON.stringify(wrongTask)) === null).assertTrue();
      expect(codec().decode(JSON.stringify(wrongMember)) === null).assertTrue(); expect(codec().decode(JSON.stringify(wrongHost)) === null).assertTrue();
    });
    it('missing_relay_scope_capability_fails_closed_before_any_routed_send', 0, () => {
      const value = new SharedTaskScopeCodec(identity, 'guest'); let rejected = false;
      try { value.decode('{"v":1,"kind":"hello-ack","payload":{"serverProtocolVersion":1,"deviceId":"phone","userId":"guest","capabilities":[]}}'); }
      catch { rejected = true; }
      expect(rejected).assertTrue(); expect(value.supported).assertFalse();
    });
    it('noncanonical_local_peer_and_unauthenticated_source_roles_do_not_downgrade', 0, () => {
      expect(parseSharedTaskPeerKey('["share","host",null,"host"]') === null).assertTrue();
      expect(parseSharedTaskPeerKey(sharedTaskHostPeerKey('share', 'host'))?.role).assertEqual('host');
      const raw = frame(); recordOrEmpty(recordOrEmpty(raw['sharedTask'])['source'])['memberId'] = 'forged';
      expect(codec().decode(JSON.stringify(raw)) === null).assertTrue();
    });
  });
}
