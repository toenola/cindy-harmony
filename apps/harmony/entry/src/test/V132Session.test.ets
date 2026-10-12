import { describe, expect, it } from '@ohos/hypium';
import { RemoteSession, parseSession } from '../main/ets/core/tasks/TaskModels';
import { agentLocationLabel, effectiveAgentDeviceId, parseSessionAgentSwitchIntent, runtimeRouteNeedsRemoteCatalog, sessionAgentSwitchIntentApplied, sessionSendNeedsModelReselection, supportsSessionAgentSwitch } from '../main/ets/core/tasks/SessionAgentSwitch';

function wireRecord(value: string): Record<string, Object> {
  return JSON.parse(value) as Record<string, Object>;
}

export default function v132SessionTests() {
  describe('V132Session', () => {
    it('keeps_same_model_relocation_pending_until_location_really_changes', 0, () => {
      const session = parseSession(wireRecord('{"id":"task","agentKind":"codex","model":"model"}'));
      const intent = parseSessionAgentSwitchIntent(wireRecord('{"targetAgentKind":"codex","model":"model","agentDeviceId":"remote"}'));
      expect(sessionAgentSwitchIntentApplied(session, intent!)).assertFalse();
      expect(runtimeRouteNeedsRemoteCatalog(session, intent)).assertTrue();
      session.agentDeviceId = 'remote';
      expect(sessionAgentSwitchIntentApplied(session, intent!)).assertTrue();
      const local = parseSessionAgentSwitchIntent(wireRecord('{"targetAgentKind":"codex","model":"model","agentDeviceId":null}'));
      expect(sessionAgentSwitchIntentApplied(session, local!)).assertFalse();
      session.agentDeviceId = '';
      expect(sessionAgentSwitchIntentApplied(session, local!)).assertTrue();
    });
    it('does_not_clear_pending_explicit_provider_effort_or_fast_mode_early', 0, () => {
      const session = parseSession(wireRecord('{"id":"task","agentKind":"cc","model":"model","providerId":"old","effort":"low","fastMode":false}'));
      const intent = parseSessionAgentSwitchIntent(wireRecord('{"targetAgentKind":"claude-code","model":"model","providerId":"new","effort":"high","fastMode":true}'));
      expect(sessionAgentSwitchIntentApplied(session, intent!)).assertFalse();
      session.providerId = 'new';
      session.effort = 'high';
      expect(sessionAgentSwitchIntentApplied(session, intent!)).assertFalse();
      session.fastMode = true;
      expect(sessionAgentSwitchIntentApplied(session, intent!)).assertTrue();
    });
    it('validates_saved_and_pending_send_models_without_using_remote_host_catalog', 0, () => {
      const visibility = new Map<string, boolean>();
      visibility.set('codex:source:hidden', false);
      visibility.set('pi:other:target', false);
      const session = parseSession(wireRecord('{"id":"task","agentKind":"codex","model":"hidden","providerId":"source"}'));
      expect(sessionSendNeedsModelReselection(visibility, session, null)).assertTrue();
      session.model = 'open';
      expect(sessionSendNeedsModelReselection(visibility, session, null)).assertFalse();
      const intent = parseSessionAgentSwitchIntent(wireRecord('{"targetAgentKind":"pi","model":"target","providerId":"other"}'));
      expect(sessionSendNeedsModelReselection(visibility, session, intent)).assertTrue();
      session.agentDeviceId = 'remote';
      expect(sessionSendNeedsModelReselection(visibility, session, intent)).assertFalse();
      session.agentDeviceId = '';
      session.agentKind = '';
      session.model = 'legacy';
      session.providerId = '';
      visibility.set('claude-code:source:legacy', false);
      expect(sessionSendNeedsModelReselection(visibility, session, null)).assertTrue();
    });
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
