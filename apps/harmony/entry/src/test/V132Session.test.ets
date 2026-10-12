import { describe, expect, it } from '@ohos/hypium';
import { RemoteSession, parseSession } from '../main/ets/core/tasks/TaskModels';
import { agentLocationLabel, effectiveAgentDeviceId, parseSessionAgentSwitchIntent, runtimeRouteNeedsRemoteCatalog, supportsSessionAgentSwitch } from '../main/ets/core/tasks/SessionAgentSwitch';

function wireRecord(value: string): Record<string, Object> {
  return JSON.parse(value) as Record<string, Object>;
}

export default function v132SessionTests() {
  describe('V132Session', () => {
    it('parses_remote_agent_location_and_legacy_missing_location', 0, () => {
      const remote = parseSession(wireRecord('{"id":"task","agentDeviceId":"agent-computer"}'));
      expect(remote.agentDeviceId).assertEqual('agent-computer');
      expect(parseSession(wireRecord('{"id":"legacy"}')).agentDeviceId).assertEqual('');
      expect(runtimeRouteNeedsRemoteCatalog(remote, null)).assertTrue();
    });
    it('distinguishes_missing_null_and_explicit_pending_location', 0, () => {
      const session = new RemoteSession();
      session.agentDeviceId = 'current';
      const unchanged = parseSessionAgentSwitchIntent(wireRecord('{"targetAgentKind":"codex","model":"model"}'));
      const local = parseSessionAgentSwitchIntent(wireRecord('{"targetAgentKind":"codex","model":"model","agentDeviceId":null}'));
      const moved = parseSessionAgentSwitchIntent(wireRecord('{"targetAgentKind":"codex","model":"model","agentDeviceId":"next"}'));
      expect(effectiveAgentDeviceId(session, unchanged)).assertEqual('current');
      expect(effectiveAgentDeviceId(session, local)).assertEqual(null);
      expect(effectiveAgentDeviceId(session, moved)).assertEqual('next');
      expect(runtimeRouteNeedsRemoteCatalog(session, local)).assertTrue();
      expect(parseSessionAgentSwitchIntent(wireRecord('{"targetAgentKind":"codex","model":"model","agentDeviceId":""}'))).assertEqual(null);
    });
    it('guards_pending_relocation_and_preserves_ssh_orca_switch_rules', 0, () => {
      const session = new RemoteSession();
      const pending = parseSessionAgentSwitchIntent(wireRecord('{"targetAgentKind":"codex","model":"model","agentDeviceId":"remote"}'));
      expect(runtimeRouteNeedsRemoteCatalog(session, pending)).assertTrue();
      expect(agentLocationLabel(session, pending, new Map<string, string>([['remote', 'Office']]))).assertEqual('Office');
      session.orcaRole = 'worker';
      expect(supportsSessionAgentSwitch(session, true)).assertFalse();
      session.orcaRole = '';
      session.remoteHostId = 'ssh';
      expect(supportsSessionAgentSwitch(session, true)).assertFalse();
    });
  });
}
