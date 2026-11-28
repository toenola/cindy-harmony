import { describe, expect, it } from '@ohos/hypium';
import { ModelRoutingContext, ModelRoutingPort, ModelRoutingStore } from '../main/ets/core/model-routing/ModelRoutingStore';
import { routedCreationRuntime } from '../main/ets/core/model-routing/ModelRoutingCreation';
import { ComposerModelOption } from '../main/ets/core/ComposerCatalog';
import { ModelRoute, implicitModelRoute, modelRouteKey, parseModelRoutingCatalog,
  parseModelRoutingResult, buildModelRoutingNote } from '../main/ets/core/model-routing/ModelRoutingModels';

// Test value: public Store prevents advancing a host decision before first-input acceptance,
// rejects revoked/stale owner data and ACP routes, and exposes supported-empty vs unsupported.
// Rule basis: model-groups.md §3/§6.3, v1.3.9 plan A. Existing LocalUnit has no routing Store.
// Minimal failures: one deferred reply across setScope/invalidateDevice, one ACP resolve,
// one acceptance repeated, or one binding read racing unbind. Unit tier: injected in-memory
// transport/clock, no network/disk/real waits. Runtime not measured: Lead owns serial Hvigor.
// Creation-runtime cases cover the actual new-page target projection: switching cc/codex/pi
// must preserve safe permissions/plan intent and must not carry unsupported effort or speed.
// Minimal failure: an underlying draft's plan or ultrafast value on a different target engine.
function wire(json: string): Object { return JSON.parse(json) as Object; }
class RoutingCall {
  channel: string = '';
  args: Object[] = [];
}
class RoutingPort implements ModelRoutingPort {
  calls: RoutingCall[] = [];
  owner: boolean = true;
  engine: string = 'codex';
  empty: boolean = false;
  unsupported: boolean = false;
  deferredChannel: string = '';
  failedChannel: string = '';
  unbound: boolean = true;
  complete: (value: Object | undefined) => void = (_value: Object | undefined): void => {};
  isOwner(_device: string): boolean { return this.owner; }
  invoke(_device: string, channel: string, args: Object[]): Promise<Object | undefined> {
    const call = new RoutingCall(); call.channel = channel; call.args = args; this.calls.push(call);
    if (this.failedChannel === channel) return Promise.reject(new Error('TIMEOUT_RECEIPT_UNKNOWN'));
    if (this.deferredChannel === channel) {
      return new Promise<Object | undefined>((resolve) => { this.complete = resolve; });
    }
    if (channel === 'model-groups:get') {
      if (this.unsupported) return Promise.reject(new Error('CHANNEL_NOT_ALLOWED'));
      return Promise.resolve(wire(this.empty ? '{"routes":[]}' : '{"routes":[{"id":"route","name":"Balanced","candidates":[]}]}'));
    }
    if (channel === 'model-groups:resolve') {
      return Promise.resolve(wire('{"outcome":"routed","decisionId":"decision","groupName":"Balanced","route":'
        + '{"agentKind":' + JSON.stringify(this.engine) + ',"providerId":'
        + JSON.stringify(this.engine === 'acp' ? 'acp-plugin:x' : 'provider') + ',"model":"model"}}'));
    }
    if (channel === 'model-groups:get-session-binding') {
      return Promise.resolve(wire('{"selection":{"type":"route","id":"route"},"routeName":"Balanced","pendingSwitch":true}'));
    }
    return Promise.resolve(wire('{"ok":true,"unbound":' + JSON.stringify(this.unbound) + '}'));
  }
  count(channel: string): number { return this.calls.filter((call: RoutingCall): boolean => call.channel === channel).length; }
}
async function rejected(run: Promise<Object | void | undefined>): Promise<string> {
  try { await run; return ''; } catch (error) { return String(error); }
}
export default function modelRoutingTests(): void {
  describe('ModelRouting', () => {
    it('routed_creation_uses_target_permission_alias_and_does_not_promote_to_full_access', 0, () => {
      const route = new ModelRoute(); route.agentKind = 'codex';
      const caps = wire('{"permissionModes":[{"id":"default"},{"id":"bypassPermissions"}]}') as Record<string, Object>;
      expect(routedCreationRuntime(route, caps, undefined, 'ask', false).permissionMode).assertEqual('default');
      expect(routedCreationRuntime(route, caps, undefined, 'unavailable', false).permissionMode).assertEqual('default');
      expect(routedCreationRuntime(route, caps, undefined, 'bypassPermissions', false).permissionMode).assertEqual('bypassPermissions');
      const unsafeOnly = wire('{"permissionModes":[{"id":"bypassPermissions"}]}') as Record<string, Object>;
      expect(routedCreationRuntime(route, unsafeOnly, undefined, 'ask', false).permissionMode).assertEqual('ask');
    });
    it('routed_creation_preserves_plan_intent_using_the_final_engine_capabilities', 0, () => {
      const route = new ModelRoute(); route.agentKind = 'cc';
      const native = wire('{"permissionModes":[{"id":"ask"}],"planMode":{"supported":true}}') as Record<string, Object>;
      const nativeRuntime = routedCreationRuntime(route, native, undefined, 'default', true);
      expect(nativeRuntime.permissionMode).assertEqual('ask'); expect(nativeRuntime.planModeArm).assertTrue();
      expect(nativeRuntime.planMode).assertTrue(); expect(nativeRuntime.legacyPlanRestore).assertEqual('');
      const legacy = wire('{"permissionModes":[{"id":"ask"},{"id":"plan"}]}') as Record<string, Object>;
      const legacyRuntime = routedCreationRuntime(route, legacy, undefined, 'ask', true);
      expect(legacyRuntime.permissionMode).assertEqual('plan'); expect(legacyRuntime.legacyPlanRestore).assertEqual('ask');
      expect(legacyRuntime.planModeArm).assertFalse(); expect(legacyRuntime.planModeEnabled).assertTrue();
      let rejected = false;
      try { routedCreationRuntime(route, wire('{"permissionModes":[{"id":"ask"}]}') as Record<string, Object>, undefined, 'ask', true); }
      catch { rejected = true; }
      expect(rejected).assertTrue();
    });
    it('routed_creation_omits_unsupported_effort_and_gates_speed_on_the_target_model_and_engine', 0, () => {
      const route = new ModelRoute(); route.agentKind = 'codex'; route.effort = 'high'; route.fastMode = 'ultrafast';
      const caps = wire('{"permissionModes":["ask"],"hasFastMode":true}') as Record<string, Object>;
      const model = new ComposerModelOption(); model.efforts = ['low']; model.defaultEffort = 'low';
      model.supportsFastMode = true; model.supportsUltrafastMode = true;
      expect(routedCreationRuntime(route, caps, model, 'ask', false).effort).assertEqual('');
      expect(routedCreationRuntime(route, caps, model, 'ask', false).fastMode).assertEqual('ultrafast');
      route.agentKind = 'pi'; expect(routedCreationRuntime(route, caps, model, 'ask', false).fastMode).assertEqual(false);
      route.fastMode = true; model.supportsFastMode = false;
      expect(routedCreationRuntime(route, caps, model, 'ask', false).fastMode).assertEqual(false);
      route.agentKind = 'acp'; let rejected = false;
      try { routedCreationRuntime(route, caps, undefined, 'ask', false); } catch { rejected = true; }
      expect(rejected).assertTrue();
    });
    it('resolve_bind_and_duplicate_accept_advance_once_only_after_acceptance', 0, async () => {
      const port = new RoutingPort(), store = new ModelRoutingStore(port); store.setScope('owner', 1);
      const context = new ModelRoutingContext(); context.agentDeviceId = null;
      const ticket = await store.prepare('computer', 'route', context);
      expect(JSON.stringify(port.calls[0].args).includes('\"location\":{\"agentDeviceId\":null}')).assertTrue();
      await store.bindBeforeFirstInput(ticket, 'session');
      expect(port.count('model-groups:commit')).assertEqual(0);
      expect(port.count('model-groups:bind-session')).assertEqual(1);
      await Promise.all([store.accepted(ticket, 'session'), store.accepted(ticket, 'session')]);
      expect(port.count('model-groups:commit')).assertEqual(1);
      expect(port.count('model-groups:bind-session')).assertEqual(1);
      expect(JSON.stringify(port.calls[2].args)).assertEqual('["decision"]');
    });
    it('cancelled_or_unsupported_engine_never_commits_or_switches', 0, async () => {
      const port = new RoutingPort(), store = new ModelRoutingStore(port); store.setScope('owner', 1);
      const ticket = await store.prepare('computer', 'route'); store.cancel(ticket);
      let cancellation = '';
      try { await store.accepted(ticket, 'session'); } catch (error) { cancellation = String(error); }
      expect(cancellation.includes('STALE')).assertTrue();
      port.engine = 'acp';
      expect((await rejected(store.prepare('computer', 'route'))).includes('ENGINE_UNSUPPORTED')).assertTrue();
      expect(port.count('model-groups:commit')).assertEqual(0);
      expect(port.count('model-groups:bind-session')).assertEqual(0);
    });
    it('deduplicates_reads_and_distinguishes_empty_and_old_host_with_bounded_retry', 0, async () => {
      const port = new RoutingPort(); port.empty = true;
      let now = 100;
      const store = new ModelRoutingStore(port, (): number => now); store.setScope('owner', 1);
      const states = await Promise.all([store.load('computer'), store.load('computer')]);
      expect(states[0].status).assertEqual('ready'); expect(states[0].catalog?.routes.length).assertEqual(0);
      expect(port.count('model-groups:get')).assertEqual(1);
      now += 15001; port.unsupported = true;
      expect((await store.load('computer')).status).assertEqual('unsupported');
      now += 15001; await store.load('computer'); expect(port.count('model-groups:get')).assertEqual(2);
      now += 300001; port.unsupported = false;
      expect((await store.load('computer')).status).assertEqual('ready');
      expect(port.count('model-groups:get')).assertEqual(3);
    });
    it('late_catalog_cannot_cross_account_or_connection_epoch', 0, async () => {
      const port = new RoutingPort(); port.deferredChannel = 'model-groups:get';
      const store = new ModelRoutingStore(port); store.setScope('owner', 1);
      const first = store.load('computer'); store.setScope('other', 2);
      port.complete(wire('{"routes":[{"id":"secret","name":"Old owner"}]}'));
      expect((await rejected(first)).includes('STALE')).assertTrue();
      expect(store.snapshot('computer').catalog === null).assertTrue();
      const second = store.load('computer'); store.invalidateDevice('computer');
      port.complete(wire('{"routes":[]}'));
      expect((await rejected(second)).includes('STALE')).assertTrue();
      expect(store.snapshot('computer').status).assertEqual('idle');
    });
    it('revocation_hides_cached_data_and_invalidates_resolved_ticket_before_writes', 0, async () => {
      const port = new RoutingPort(), store = new ModelRoutingStore(port); store.setScope('owner', 1);
      await store.load('computer'); const ticket = await store.prepare('computer', 'route'); port.owner = false;
      expect(store.snapshot('computer').catalog === null).assertTrue();
      let error = '';
      try { await store.accepted(ticket, 'session'); } catch (caught) { error = String(caught); }
      expect(error.includes('STALE')).assertTrue(); expect(port.count('model-groups:commit')).assertEqual(0);
    });
    it('unbind_cannot_be_undone_by_an_older_binding_read', 0, async () => {
      const port = new RoutingPort(), store = new ModelRoutingStore(port); store.setScope('owner', 1);
      port.deferredChannel = 'model-groups:get-session-binding';
      const read = store.refreshSession('computer', 'session'); await store.unbind('computer', 'session');
      port.complete(wire('{"selection":{"type":"route","id":"route"},"routeName":"Balanced"}'));
      expect((await rejected(read)).includes('STALE')).assertTrue();
      expect(store.sessionSnapshot('computer', 'session').binding === null).assertTrue();
    });
    it('fixed_task_location_rejects_cross_computer_resolution_without_commit', 0, async () => {
      const port = new RoutingPort(), store = new ModelRoutingStore(port); store.setScope('owner', 1);
      const context = new ModelRoutingContext(); context.agentDeviceId = 'different-computer';
      expect((await rejected(store.prepare('computer', 'route', context))).includes('LOCATION_MISMATCH')).assertTrue();
      expect(port.count('model-groups:commit')).assertEqual(0);
    });
    it('unknown_commit_receipt_does_not_replay_the_write', 0, async () => {
      const port = new RoutingPort(), store = new ModelRoutingStore(port); store.setScope('owner', 1);
      const ticket = await store.prepare('computer', 'route'); port.failedChannel = 'model-groups:commit';
      expect((await rejected(store.accepted(ticket, 'session'))).includes('TIMEOUT_RECEIPT_UNKNOWN')).assertTrue();
      expect(store.sessionSnapshot('computer', 'session').error).assertEqual('MODEL_ROUTING_COMMIT_INCOMPLETE');
      await store.refreshSession('computer', 'session');
      expect(store.sessionSnapshot('computer', 'session').binding?.routeName).assertEqual('Balanced');
      expect(store.sessionSnapshot('computer', 'session').error).assertEqual('MODEL_ROUTING_COMMIT_INCOMPLETE');
      port.failedChannel = '';
      expect((await rejected(store.accepted(ticket, 'session'))).includes('TIMEOUT_RECEIPT_UNKNOWN')).assertTrue();
      expect(port.count('model-groups:commit')).assertEqual(1);
    });
    it('bind_and_note_failures_are_visible_on_the_task_without_resending_input', 0, async () => {
      const channels: string[] = ['model-groups:bind-session', 'model-groups:route-note'];
      const errors: string[] = ['MODEL_ROUTING_BIND_INCOMPLETE', 'MODEL_ROUTING_ROUTE_NOTE_INCOMPLETE'];
      for (let i = 0; i < channels.length; i++) {
        const port = new RoutingPort(), store = new ModelRoutingStore(port); store.setScope('owner', 1);
        const ticket = await store.prepare('computer', 'route'); port.failedChannel = channels[i];
        const note = buildModelRoutingNote(ticket.result, '', '', (device: string): string => device);
        expect((await rejected(store.accepted(ticket, 'session', note))).includes('TIMEOUT_RECEIPT_UNKNOWN')).assertTrue();
        expect(store.sessionSnapshot('computer', 'session').error).assertEqual(errors[i]);
        expect(port.count(channels[i])).assertEqual(1);
      }
    });
    it('late_finish_failure_cannot_publish_into_a_new_account', 0, async () => {
      const port = new RoutingPort(), store = new ModelRoutingStore(port); store.setScope('owner', 1);
      const ticket = await store.prepare('computer', 'route'); await store.bindBeforeFirstInput(ticket, 'session');
      port.deferredChannel = 'model-groups:commit'; const accepting = store.accepted(ticket, 'session');
      await Promise.resolve(); store.setScope('other', 2); port.complete(wire('{"ok":true}'));
      expect((await rejected(accepting)).includes('STALE')).assertTrue();
      expect(store.sessionSnapshot('computer', 'session').error).assertEqual('');
    });
    it('unsuccessful_unbind_preserves_host_binding_and_dispose_invalidates_late_reads', 0, async () => {
      const port = new RoutingPort(), store = new ModelRoutingStore(port); store.setScope('owner', 1);
      await store.refreshSession('computer', 'session'); port.unbound = false;
      expect((await rejected(store.unbind('computer', 'session'))).includes('NOT_UNBOUND')).assertTrue();
      expect(store.sessionSnapshot('computer', 'session').binding?.routeName).assertEqual('Balanced');
      port.deferredChannel = 'model-groups:get'; const pending = store.load('computer'); store.dispose();
      port.complete(wire('{"routes":[]}')); expect((await rejected(pending)).includes('STALE')).assertTrue();
      expect(store.snapshot('computer').catalog === null).assertTrue();
    });
    it('merged_sources_keep_execution_identity_and_new_reason_precedence_in_notes', 0, () => {
      const catalog = parseModelRoutingCatalog(wire('{"routes":[],"sourceRoutes":[{"id":"merged","name":"Merged","sources":['
        + '{"providerId":"same","agentDeviceId":"a"},{"providerId":"same","agentDeviceId":"b"}]}],'
        + '"expandedRoutes":[{"id":"child","name":"Model","parent":{"id":"merged","name":"Merged"},"candidates":['
        + '{"agentKind":"pi","providerId":"same","model":"same","agentDeviceId":"a"},'
        + '{"agentKind":"pi","providerId":"same","model":"same","agentDeviceId":"b","off":true}]}]}'));
      expect(catalog?.sourceRoutes[0].sources.length).assertEqual(2);
      const a = new ModelRoute(); a.agentKind = 'pi'; a.providerId = 'same'; a.model = 'same'; a.agentDeviceId = 'a';
      const b = new ModelRoute(); b.agentKind = 'pi'; b.providerId = 'same'; b.model = 'same'; b.agentDeviceId = 'b';
      expect(modelRouteKey(a) === modelRouteKey(b)).assertFalse();
      if (catalog) { expect(implicitModelRoute(catalog, a)).assertEqual('child'); expect(implicitModelRoute(catalog, b)).assertEqual(''); }
      const result = parseModelRoutingResult(wire('{"outcome":"routed","groupName":"Group","route":'
        + JSON.stringify(a) + ',"why":"order","pickWhy":"drain"}'));
      expect(result?.why).assertEqual('drain');
      if (result) {
        const note = buildModelRoutingNote(result, '', 'Reason', (_id: string): string => 'Computer A');
        expect(note?.['modelName']).assertEqual('same · same · Computer A');
        expect(note?.['source']).assertEqual('model-group');
      }
    });
  });
}
