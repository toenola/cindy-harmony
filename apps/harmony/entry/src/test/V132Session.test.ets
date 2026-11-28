import { describe, expect, it } from '@ohos/hypium';
import { RemoteSession, parseSession } from '../main/ets/core/tasks/TaskModels';
import { agentLocationLabel, effectiveAgentDeviceId, parseSessionAgentSwitchIntent, runtimeRouteNeedsRemoteCatalog, sessionAgentSwitchIntentApplied, sessionSendNeedsModelReselection, supportsSessionAgentSwitch, supportsAgentRelocation, isOrcaAgentSession, sendSessionAgentIntent, usesSessionModelIntent, pendingSessionModelLabel } from '../main/ets/core/tasks/SessionAgentSwitch';
import {
  RemoteAgentCatalog, RemoteAgentDevice, remoteAgentLocationSupported, remoteAgentModelOptions, remoteAgentProviderList,
  resolveAgentLocationPick, selectRemoteAgentDevices,
} from '../main/ets/core/tasks/RemoteAgentCatalogs';
import { ComposerModelGroup, ComposerModelOption, composerModelKey, groupComposerModelOptions, pickerVisibleGroups, pickerFavorites, recommendedPickerEffort, modelFavoriteMutation, modelFavoriteSource, pickerRecommendedOption } from '../main/ets/core/ComposerCatalog';
import { PresenceSnapshot } from '../main/ets/core/device-link/DlProtocol';

function wireRecord(value: string): Record<string, Object> {
  return JSON.parse(value) as Record<string, Object>;
}

function presence(deviceId: string, name: string, online: boolean, remoteControlEnabled: boolean = true): PresenceSnapshot {
  const device = new PresenceSnapshot();
  device.deviceId = deviceId;
  device.deviceName = name;
  device.online = online;
  device.remoteControlEnabled = remoteControlEnabled;
  return device;
}

// 同一份供应商目录：remote 开放远程调用并只允许 m1；local 未开放；legacy 没有标记（旧数据按未开放）。
const REMOTE_CATALOG = '{"providers":['
  + '{"id":"anthropic","name":"Anthropic","connected":true,"agents":["claude-code"],"remoteInvocationEnabled":true,'
  + '"remoteModelIds":["m1"],"models":{"claude-code":[{"id":"m1","name":"Model 1"},{"id":"m2","name":"Model 2"}]}},'
  + '{"id":"local","name":"Local","connected":true,"agents":["claude-code"],"remoteInvocationEnabled":false,'
  + '"models":{"claude-code":[{"id":"m3"}]}},'
  + '{"id":"legacy","name":"Legacy","connected":true,"agents":["claude-code"],"models":{"claude-code":[{"id":"m4"}]}}'
  + '],"modelVisibilityOverrides":{}}';

export default function v132SessionTests() {
  describe('V132Session', () => {
    // Unit: the production reset resolves a target before resolving effort and turns off Fast.
    it('prefers a matching protocol or family without requiring an explicit recommendation', 0, (): void => {
      const claude = new ComposerModelOption();
      claude.pickerHarness = 'claude-code';
      claude.id = 'vendor/model';
      claude.pickerNativeApi = 'openai-responses';
      claude.pickerOutboundApi = 'openai-responses';
      const codex = new ComposerModelOption();
      codex.pickerHarness = 'codex';
      codex.pickerOutboundApi = 'openai-responses';
      codex.efforts = ['low', 'high'];
      codex.defaultEffort = 'high';
      const pi = new ComposerModelOption();
      pi.pickerHarness = 'pi';
      const inferred = pickerRecommendedOption(claude, [pi, codex]);
      expect(inferred.pickerHarness).assertEqual('codex');
      expect(inferred.pickerEffort).assertEqual('high');
      expect(inferred.pickerFast).assertFalse();
      claude.pickerModelFamily = 'grok';
      expect(pickerRecommendedOption(claude, [codex, pi]).pickerHarness).assertEqual('pi');
    });

    // Unit: production favorite projection, recommendation and plugin intent wire shape.
    it('retains multiple combinations and resets to the declared compatible harness', 0, (): void => {
      const codex = new ComposerModelOption();
      codex.pickerHarness = 'codex';
      codex.id = 'gpt';
      codex.providerId = 'p';
      codex.efforts = ['low', 'high'];
      codex.defaultEffort = 'low';
      codex.supportsFastMode = true;
      codex.pickerRecommendedHarness = 'pi';
      const pi = new ComposerModelOption();
      pi.pickerHarness = 'pi';
      pi.efforts = ['medium'];
      const favorites = pickerFavorites(groupComposerModelOptions([codex]), [
        wireRecord('{"uid":"one","providerId":"p","modelId":"gpt","agent":"codex","effort":"low"}'),
        wireRecord('{"uid":"two","providerId":"p","modelId":"gpt","agent":"codex","effort":"high","fast":true}'),
      ]);
      expect(favorites[0].options.length).assertEqual(2);
      expect(favorites[0].options[0].pickerFast).assertFalse();
      expect(favorites[0].options[1].pickerEffort).assertEqual('high');
      expect(favorites[0].options[1].pickerFast).assertTrue();
      expect(pickerRecommendedOption(codex, [pi]).pickerHarness).assertEqual('pi');
      expect(pickerRecommendedOption(codex, [pi]).pickerEffort).assertEqual('medium');
      expect(pickerRecommendedOption(codex, [pi], 'codex').pickerHarness).assertEqual('codex');
    });

    it('uses six arguments for a same-location ACP switch with the full provider ID', 0, async (): Promise<void> => {
      await sendSessionAgentIntent(async (_host: string, channel: string, args: Object[]): Promise<Object | undefined> => {
        expect(channel).assertEqual('maker:switch-session-agent');
        expect(args.length).assertEqual(6);
        expect(args[1]).assertEqual('acp');
        expect(args[3]).assertEqual('acp-plugin:plugin:harness');
        return undefined;
      }, 'host', 'session', 'acp', 'default', 'acp-plugin:plugin:harness', '', false, undefined);
    });

    // Unit: production picker projection and host mutation contract. Previous directory tests
    // do not exercise current-only visibility or remote favorites whose provider IDs overlap.
    it('filters the focused source and ranks favorites ahead of local and remote matches', 0, (): void => {
      const local = new ComposerModelOption();
      local.id = 'model';
      local.label = 'Local model';
      local.providerId = 'shared';
      const remote = new ComposerModelOption();
      remote.id = 'model';
      remote.label = 'Remote model';
      remote.providerId = 'shared';
      remote.agentDeviceId = 'computer';
      remote.pickerHarness = 'codex';
      remote.efforts = ['low', 'high'];
      remote.defaultEffort = 'high';
      const rows = groupComposerModelOptions([remote, local]);
      expect(pickerVisibleGroups(rows, rows[0].key, false, '')[0].options[0].label).assertEqual('Remote model');
      expect(pickerVisibleGroups(rows, '', true, 'remote').length).assertEqual(1);
      const all = pickerVisibleGroups(rows, '', true, '');
      expect(all[0].options[0].label).assertEqual('Local model');
      const stored = wireRecord('{"uid":"u","providerId":"unused","modelId":"model","agent":"codex","effort":"high"}');
      stored['providerId'] = modelFavoriteSource(remote);
      expect(pickerFavorites(all, [stored])[0].key).assertEqual('picker:favorites');
      expect(recommendedPickerEffort(remote)).assertEqual('high');
      const add = modelFavoriteMutation(remote, 'codex', 'high', false, []);
      expect(add['kind']).assertEqual('add');
      const item = add['item'] as Record<string, Object>;
      expect(item['providerId']).assertEqual(stored['providerId']);
      expect(item['fast'] === undefined).assertTrue();
      const remove = modelFavoriteMutation(remote, 'codex', 'high', false, [stored]);
      expect(remove['kind']).assertEqual('remove');
      expect(remove['expected'] === stored).assertTrue();
    });

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
    // v1.3.5 D2：对齐 Mobile remoteAgentCatalogs.ts / model-providers remoteInvocationModels。
    // 其他电脑只列开了「允许被远程调用」的供应商与 remoteModelIds 允许的模型；旧数据按未开放处理。
    it('lists_only_remote_invocable_providers_and_models_from_other_computers', 0, () => {
      const raw = JSON.parse(REMOTE_CATALOG) as Object;
      expect(remoteAgentLocationSupported(raw)).assertTrue();
      expect(remoteAgentLocationSupported(JSON.parse('{"providers":[{"id":"x"}]}') as Object)).assertFalse();
      expect(remoteAgentProviderList(JSON.parse('{"error":"x"}') as Object) === undefined).assertTrue();

      const catalog = new RemoteAgentCatalog();
      catalog.deviceId = 'laptop';
      catalog.name = 'Laptop';
      catalog.status = 'ready';
      catalog.payload = remoteAgentProviderList(raw);
      const options = remoteAgentModelOptions([catalog], 'claude-code', undefined, null);
      expect(JSON.stringify(options.map((option: ComposerModelOption) => composerModelKey(option))))
        .assertEqual('["device:laptop::anthropic::m1"]');

      // 被控电脑上同名供应商、同名模型的行与远程行分属两段，键也不同。
      const host = new ComposerModelOption();
      host.id = 'm1';
      host.providerId = 'anthropic';
      host.providerName = 'Anthropic';
      const groups = groupComposerModelOptions([host].concat(options));
      expect(JSON.stringify(groups.map((group: ComposerModelGroup) => group.name)))
        .assertEqual('["Anthropic","Anthropic · Laptop"]');

      // 离线电脑的缓存目录只用来显示 Agent 在哪台，行不可选；当前所在的那一行保留可见。
      catalog.offline = true;
      const offline = remoteAgentModelOptions([catalog], 'claude-code', undefined, null);
      expect(offline[0].suspended).assertTrue();
      const current = remoteAgentModelOptions([catalog], 'claude-code', { model: 'm1', providerId: 'anthropic' }, 'laptop');
      expect(current[0].selectedRoute).assertTrue();
      expect(current[0].suspended).assertFalse();
    });

    it('selects_other_open_computers_and_keeps_the_current_agent_computer_when_offline', 0, () => {
      const devices = [
        presence('host', 'Studio', true),
        presence('b', 'Mini', true),
        presence('a', 'Air', false),
        presence('c', 'Office', true, false),
        presence('d', 'Mini', true),
      ];
      const listed = selectRemoteAgentDevices(devices, 'host', [], 'Unnamed');
      expect(listed.map((device: RemoteAgentDevice): string => `${device.deviceId}:${device.name}:${device.canOpen}`)
        .join('|')).assertEqual('b:Mini (1):true|d:Mini (2):true');
      const kept = selectRemoteAgentDevices(devices, 'host', ['a'], 'Unnamed');
      expect(kept.map((device: RemoteAgentDevice): string => `${device.deviceId}:${device.canOpen}`).join('|'))
        .assertEqual('b:true|d:true|a:false');
    });

    it('relocates_only_when_the_picked_catalog_is_another_computer', 0, () => {
      const pickOf = (current: string | null, effective: string | null, picked: string | null): string => {
        const pick = resolveAgentLocationPick(current, effective, picked);
        const target = !pick.relocates ? 'same' : pick.relocateTo === null ? 'host' : pick.relocateTo;
        return `${pick.relocates}:${target}:${pick.needsConfirm}`;
      };
      // 本机任务内换模型：位置不变。
      expect(pickOf(null, null, null)).assertEqual('false:same:false');
      // 本机 → 其他电脑：先确认。
      expect(pickOf(null, null, 'laptop')).assertEqual('true:laptop:true');
      // 已确认过同一目标的挂起意图：不重复确认。
      expect(pickOf(null, 'laptop', 'laptop')).assertEqual('true:laptop:false');
      // 选回任务当前所在电脑 = 撤销挂着的换位置，不带位置、不确认。
      expect(pickOf(null, 'laptop', null)).assertEqual('false:same:false');
      // Agent 在其他电脑，改回被控电脑：带 null 并确认。
      expect(pickOf('laptop', 'laptop', null)).assertEqual('true:host:true');
      // Agent 在其他电脑，同一台内换模型：直接切。
      expect(pickOf('laptop', 'laptop', 'laptop')).assertEqual('false:same:false');
    });

    it('guards_pending_relocation_and_preserves_ssh_orca_switch_rules', 0, () => {
      const session = new RemoteSession();
      const pending = parseSessionAgentSwitchIntent(wireRecord('{"targetAgentKind":"codex","model":"model","agentDeviceId":"remote"}'));
      expect(runtimeRouteNeedsRemoteCatalog(session, pending)).assertTrue();
      expect(agentLocationLabel(session, pending, new Map<string, string>([['remote', 'Office']]))).assertEqual('Office');
      session.agentDeviceId = 'remote';
      for (const role of ['lead', 'worker']) {
        session.orcaRole = role;
        expect(supportsSessionAgentSwitch(session, true)).assertTrue();
        expect(isOrcaAgentSession(session)).assertTrue();
        expect(supportsAgentRelocation(session, true, true, false, true)).assertFalse();
        expect(supportsAgentRelocation(session, true, true, true, false)).assertTrue();
      }
      session.orcaRole = '';
      session.orcaRemoteLead = true;
      expect(supportsSessionAgentSwitch(session, true)).assertTrue();
      expect(supportsAgentRelocation(session, true, true, true, false)).assertFalse();
      expect(supportsAgentRelocation(session, true, true, false, true)).assertTrue();
      session.orcaRemoteLead = false;
      session.remoteHostId = 'ssh';
      expect(supportsSessionAgentSwitch(session, true)).assertFalse();
    });
    // Unit: pass distinct pane hosts to the production sender and observe destination and wire args.
    it('writes_to_each_orca_task_host_and_only_adds_location_when_moving', 0, async () => {
      const requests: string[] = [];
      const send = async (host: string, channel: string, args: Object[]): Promise<Object | undefined> => {
        requests.push(JSON.stringify([host, channel, args]));
        return undefined;
      };
      await sendSessionAgentIntent(send, 'lead-host', 'lead', 'claude-code', 'model', 'provider', 'high', false, undefined);
      await sendSessionAgentIntent(send, 'worker-host', 'worker', 'codex', 'model', 'provider', 'medium', false, null);
      expect(requests[0]).assertEqual('["lead-host","maker:switch-session-agent",["lead","claude-code","model","provider","high",false]]');
      expect(requests[1]).assertEqual('["worker-host","maker:switch-session-agent",["worker","codex","model","provider","medium",false,{"agentDeviceId":null}]]');
    });
    // Unit: same-engine ordinary selection uses the intent only when both host capabilities are present.
    it('stages_ordinary_model_selection_on_supported_hosts_and_keeps_legacy_fallback', 0, () => {
      const session = new RemoteSession();
      session.agentKind = 'codex';
      expect(usesSessionModelIntent(session, true, true, false)).assertTrue();
      expect(usesSessionModelIntent(session, true, false, false)).assertFalse();
      expect(usesSessionModelIntent(session, false, true, false)).assertFalse();
      expect(usesSessionModelIntent(session, true, true, true)).assertFalse();
      session.agentKind = 'pi'; session.agentDeviceId = 'peer';
      expect(usesSessionModelIntent(session, true, true, false)).assertFalse();
      session.agentKind = 'codex'; session.agentDeviceId = 'share:one';
      expect(usesSessionModelIntent(session, true, true, false)).assertFalse();
      session.orcaRole = 'lead'; session.agentDeviceId = 'peer';
      expect(usesSessionModelIntent(session, true, false, false)).assertTrue();
    });

    it('labels_only_an_authoritative_pending_model_as_effective_on_next_send', 0, () => {
      expect(pendingSessionModelLabel('Current', null, 'On next send')).assertEqual('Current');
      const intent = parseSessionAgentSwitchIntent(wireRecord('{"targetAgentKind":"codex","model":"Next"}'));
      expect(pendingSessionModelLabel('Current', intent, 'On next send')).assertEqual('On next send · Next');
    });
  });
}
