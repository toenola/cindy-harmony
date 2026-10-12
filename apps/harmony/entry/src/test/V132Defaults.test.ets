import { describe, expect, it } from '@ohos/hypium';
import { ComposerModelOption, modelNeedsReselection } from '../main/ets/core/ComposerCatalog';
import {
  NewSessionDraftPrefWriter,
  NewSessionRuntime,
  NewSessionRuntimeChoices,
  hostDraftRuntimeFromDefaults,
  isHostDraftDefaultsReady,
  newSessionDraftPref,
  newSessionRuntimeCanCreate,
  normalizeRemoteDirectoryDrives,
  pickNewSessionRuntime,
  readNewSessionRuntimeDefaults,
  runtimeDefaultsScope,
  shouldRetryRemoteBrowseDrives,
} from '../main/ets/core/tasks/NewSessionRuntimeDefaults';

class DefaultsDeferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void = (_value: T): void => {};

  constructor() {
    this.promise = new Promise<T>((resolve) => { this.resolve = resolve; });
  }
}

function defaultsRecord(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

function modelOption(model: string, providerId: string = ''): ComposerModelOption {
  const option = new ComposerModelOption();
  option.id = model;
  option.providerId = providerId;
  option.efforts = ['low', 'high'];
  option.defaultEffort = 'high';
  option.supportsFastMode = true;
  return option;
}

export default function v132DefaultsTest(): void {
  describe('V132Defaults', () => {
    it('reads_explicit_host_model_effort_provider_and_fast', 0, () => {
      const runtime = hostDraftRuntimeFromDefaults(defaultsRecord(
        '{"model":" chosen ","providerId":"source","effort":" low ","fastMode":true,"modelChosenByUser":true}'));
      expect(runtime?.model).assertEqual('chosen');
      expect(runtime?.providerId).assertEqual('source');
      expect(runtime?.effort).assertEqual('low');
      expect(runtime?.fastMode).assertTrue();
    });
    it('rejects_missing_malformed_and_unselected_seeds', 0, () => {
      expect(hostDraftRuntimeFromDefaults(undefined) === null).assertTrue();
      expect(hostDraftRuntimeFromDefaults('wrong') === null).assertTrue();
      expect(hostDraftRuntimeFromDefaults([]) === null).assertTrue();
      expect(hostDraftRuntimeFromDefaults(defaultsRecord('{}')) === null).assertTrue();
      expect(hostDraftRuntimeFromDefaults(defaultsRecord('{"model":17}')) === null).assertTrue();
      expect(hostDraftRuntimeFromDefaults(defaultsRecord('{"model":"seed","modelChosenByUser":false}')) === null).assertTrue();
      expect(hostDraftRuntimeFromDefaults(defaultsRecord('{"model":"legacy"}'))?.model).assertEqual('legacy');
      expect(hostDraftRuntimeFromDefaults(defaultsRecord(
        '{"model":"source-choice","providerId":"source","modelChosenByUser":false}'))?.model).assertEqual('source-choice');
    });
    it('uses_field_presence_as_host_readiness', 0, () => {
      expect(isHostDraftDefaultsReady(undefined)).assertFalse();
      expect(isHostDraftDefaultsReady(defaultsRecord('{"model":"seed"}'))).assertFalse();
      expect(isHostDraftDefaultsReady(defaultsRecord('{"worktreeEnabled":false}'))).assertTrue();
      expect(isHostDraftDefaultsReady(defaultsRecord('{"worktreeEnabled":true}'))).assertTrue();
    });
    it('rereads_unready_host_until_its_draft_arrives', 0, async () => {
      let reads = 0;
      let waits = 0;
      const runtime = await readNewSessionRuntimeDefaults(
        async (): Promise<Object> => {
          reads += 1;
          return defaultsRecord(reads < 3 ? '{}' : '{"model":"ready","worktreeEnabled":false}');
        },
        (): boolean => true,
        async (): Promise<void> => { waits += 1; },
      );
      expect(runtime?.model).assertEqual('ready');
      expect(reads).assertEqual(3);
      expect(waits).assertEqual(2);
    });
    it('bounds_unready_legacy_reads_and_returns_catalog_fallback', 0, async () => {
      let reads = 0;
      const runtime = await readNewSessionRuntimeDefaults(
        async (): Promise<Object> => { reads += 1; return defaultsRecord('{}'); },
        (): boolean => true,
        async (): Promise<void> => {},
      );
      expect(runtime === null).assertTrue();
      expect(reads).assertEqual(3);
      expect(pickNewSessionRuntime('codex', runtime, [modelOption('legacy')], new Map<string, boolean>()).model).assertEqual('legacy');
    });
    it('falls_back_once_on_channel_not_allowed_and_transport_failure', 0, async () => {
      const errors = ['CHANNEL_NOT_ALLOWED', 'TIMEOUT'];
      for (const errorCode of errors) {
        let reads = 0;
        let waits = 0;
        const runtime = await readNewSessionRuntimeDefaults(
          async (): Promise<Object> => { reads += 1; throw new Error(errorCode); },
          (): boolean => true,
          async (): Promise<void> => { waits += 1; },
        );
        expect(runtime === null).assertTrue();
        expect(reads).assertEqual(1);
        expect(waits).assertEqual(0);
      }
    });
    it('does_not_retry_an_undefined_legacy_reply', 0, async () => {
      let reads = 0;
      const runtime = await readNewSessionRuntimeDefaults(
        async (): Promise<Object | undefined> => { reads += 1; return undefined; },
        (): boolean => true,
        async (): Promise<void> => {},
      );
      expect(runtime === null).assertTrue();
      expect(reads).assertEqual(1);
    });
    it('drops_late_reads_after_device_agent_or_account_change', 0, async () => {
      const originalScope = runtimeDefaultsScope('account', 'device', 'codex');
      const changedScopes = [
        runtimeDefaultsScope('other-account', 'device', 'codex'),
        runtimeDefaultsScope('account', 'other-device', 'codex'),
        runtimeDefaultsScope('account', 'device', 'pi'),
      ];
      for (const changedScope of changedScopes) {
        let scope = originalScope;
        const delayed = new DefaultsDeferred<Object>();
        const pending = readNewSessionRuntimeDefaults(
          (): Promise<Object> => delayed.promise,
          (): boolean => scope === originalScope,
          async (): Promise<void> => {},
        );
        scope = changedScope;
        delayed.resolve(defaultsRecord('{"model":"old","worktreeEnabled":false}'));
        expect(await pending === null).assertTrue();
      }
    });
    it('stops_retrying_when_scope_changes_during_wait', 0, async () => {
      let current = true;
      let reads = 0;
      const runtime = await readNewSessionRuntimeDefaults(
        async (): Promise<Object> => { reads += 1; return defaultsRecord('{}'); },
        (): boolean => current,
        async (): Promise<void> => { current = false; },
      );
      expect(runtime === null).assertTrue();
      expect(reads).assertEqual(1);
    });
    it('keeps_explicit_page_choice_over_a_late_host_read', 0, async () => {
      const choices = new NewSessionRuntimeChoices();
      const scope = runtimeDefaultsScope('account', 'device', 'codex');
      const delayed = new DefaultsDeferred<Object>();
      const pending = readNewSessionRuntimeDefaults(
        (): Promise<Object> => delayed.promise,
        (): boolean => true,
        async (): Promise<void> => {},
      );
      const chosen = new NewSessionRuntime();
      chosen.model = 'chosen';
      chosen.effort = 'low';
      choices.remember(scope, chosen);
      delayed.resolve(defaultsRecord('{"model":"old","worktreeEnabled":true}'));
      const resolved = choices.read(scope) ?? await pending;
      expect(resolved?.model).assertEqual('chosen');
      expect(resolved?.effort).assertEqual('low');
      await pending;
    });
    it('separates_page_choices_by_account_device_and_agent', 0, () => {
      const choices = new NewSessionRuntimeChoices();
      const scope = runtimeDefaultsScope('account', 'device', 'codex');
      const chosen = new NewSessionRuntime();
      chosen.model = 'chosen';
      choices.remember(scope, chosen);
      expect(choices.read(runtimeDefaultsScope('other', 'device', 'codex')) === null).assertTrue();
      expect(choices.read(runtimeDefaultsScope('account', 'other', 'codex')) === null).assertTrue();
      expect(choices.read(runtimeDefaultsScope('account', 'device', 'pi')) === null).assertTrue();
      expect(choices.read(scope)?.model).assertEqual('chosen');
    });
    it('uses_catalog_default_then_first_model_without_hardcoded_model', 0, () => {
      const first = modelOption('first', 'source-a');
      const marked = modelOption('marked', 'source-b');
      marked.newSessionDefaultAgents = ['codex'];
      const visibility = new Map<string, boolean>();
      expect(pickNewSessionRuntime('codex', null, [first, marked], visibility).model).assertEqual('marked');
      expect(pickNewSessionRuntime('pi', null, [first, marked], visibility).model).assertEqual('first');
      expect(pickNewSessionRuntime('codex', null, [], visibility).model).assertEqual('');
    });
    it('matches_host_source_exactly_and_reconciles_effort', 0, () => {
      const first = modelOption('same', 'source-a');
      first.efforts = ['low'];
      const second = modelOption('same', 'source-b');
      const preferred = hostDraftRuntimeFromDefaults(defaultsRecord(
        '{"model":"same","providerId":"source-b","effort":"unsupported","fastMode":true}'));
      const result = pickNewSessionRuntime('codex', preferred, [first, second], new Map<string, boolean>());
      expect(result.providerId).assertEqual('source-b');
      expect(result.effort).assertEqual('high');
      expect(result.fastMode).assertTrue();
    });
    it('replaces_removed_routes_without_sending_a_bare_missing_model', 0, () => {
      const preferred = hostDraftRuntimeFromDefaults(defaultsRecord('{"model":"gone","providerId":"removed"}'));
      const result = pickNewSessionRuntime('codex', preferred, [modelOption('available', 'source')], new Map<string, boolean>());
      expect(result.model).assertEqual('available');
      expect(result.providerId).assertEqual('source');
    });
    it('resolves_same_model_sources_using_agent_native_order_not_catalog_order', 0, () => {
      const preferred = hostDraftRuntimeFromDefaults(defaultsRecord('{"model":"same","providerId":"removed"}'));
      const custom = modelOption('same', 'custom');
      const gateway = modelOption('same', 'xd');
      const openAi = modelOption('same', 'openai');
      const models = [custom, gateway, openAi];
      expect(pickNewSessionRuntime('codex', preferred, models, new Map<string, boolean>()).providerId).assertEqual('openai');
      expect(pickNewSessionRuntime('claude-code', preferred, models, new Map<string, boolean>()).providerId).assertEqual('xd');
      custom.selectedRoute = true;
      expect(pickNewSessionRuntime('codex', preferred, models, new Map<string, boolean>()).providerId).assertEqual('custom');
    });
    it('disables_fast_when_fallback_changes_model_or_explicit_source', 0, () => {
      const preferred = hostDraftRuntimeFromDefaults(defaultsRecord(
        '{"model":"same","providerId":"removed","effort":"low","fastMode":true}'));
      const nextSource = pickNewSessionRuntime('codex', preferred, [modelOption('same', 'source')], new Map<string, boolean>());
      expect(nextSource.fastMode).assertFalse();
      expect(nextSource.effort).assertEqual('low');
      const nextModel = pickNewSessionRuntime('codex', preferred, [modelOption('different', 'source')], new Map<string, boolean>());
      expect(nextModel.fastMode).assertFalse();
    });
    it('resolves_default_source_while_another_source_remains_visible', 0, () => {
      const visibility = new Map<string, boolean>();
      visibility.set('codex:source-a:same', false);
      visibility.set('codex:source-b:same', true);
      const preferred = hostDraftRuntimeFromDefaults(defaultsRecord('{"model":"same"}'));
      const result = pickNewSessionRuntime('codex', preferred, [modelOption('same', 'source-b')], visibility);
      expect(result.providerId).assertEqual('source-b');
      expect(modelNeedsReselection(visibility, 'codex', 'same', '')).assertFalse();
      expect(modelNeedsReselection(visibility, 'codex', 'same', 'source-a')).assertTrue();
    });
    it('requires_reselection_only_when_all_default_sources_are_hidden', 0, () => {
      const visibility = new Map<string, boolean>();
      visibility.set('codex:source-a:same', false);
      visibility.set('codex:source-b:same', false);
      visibility.set('pi:source-a:same', true);
      expect(modelNeedsReselection(visibility, 'codex', 'same', '')).assertTrue();
      expect(modelNeedsReselection(visibility, 'pi', 'same', '')).assertFalse();
      expect(modelNeedsReselection(visibility, 'codex', 'absent', '')).assertFalse();
      expect(modelNeedsReselection(undefined, 'codex', 'same', '')).assertFalse();
      expect(modelNeedsReselection(visibility, 'codex', '', '')).assertFalse();
    });
    it('preserves_hidden_saved_selection_instead_of_silently_rerouting', 0, () => {
      const visibility = new Map<string, boolean>();
      visibility.set('codex:hidden:chosen', false);
      const preferred = hostDraftRuntimeFromDefaults(defaultsRecord('{"model":"chosen","providerId":"hidden"}'));
      const result = pickNewSessionRuntime('codex', preferred, [modelOption('fallback', 'visible')], visibility);
      expect(result.model).assertEqual('chosen');
      expect(result.providerId).assertEqual('hidden');
      expect(newSessionRuntimeCanCreate(true, true, 'codex', result, visibility)).assertFalse();
    });
    it('never_auto_selects_paid_suspended_or_hidden_catalog_defaults', 0, () => {
      const paid = modelOption('paid');
      paid.availability = 'requires_payment';
      const suspended = modelOption('suspended');
      suspended.suspended = true;
      const hidden = modelOption('hidden', 'source');
      hidden.newSessionDefaultAgents = ['codex'];
      const visibility = new Map<string, boolean>();
      visibility.set('codex:source:hidden', false);
      const result = pickNewSessionRuntime('codex', null, [paid, suspended, hidden, modelOption('usable')], visibility);
      expect(result.model).assertEqual('usable');
    });
    it('blocks_creation_until_defaults_and_catalog_are_settled', 0, () => {
      const runtime = new NewSessionRuntime();
      const visibility = new Map<string, boolean>();
      expect(newSessionRuntimeCanCreate(true, true, 'codex', runtime, visibility)).assertFalse();
      runtime.model = 'chosen';
      expect(newSessionRuntimeCanCreate(false, true, 'codex', runtime, visibility)).assertFalse();
      expect(newSessionRuntimeCanCreate(true, false, 'codex', runtime, visibility)).assertFalse();
      expect(newSessionRuntimeCanCreate(true, true, 'codex', runtime, visibility)).assertTrue();
    });
    it('writes_model_effort_and_fast_with_correct_active_choice_flags', 0, () => {
      const runtime = new NewSessionRuntime();
      runtime.model = 'chosen';
      runtime.effort = 'low';
      runtime.fastMode = true;
      const modelPref = newSessionDraftPref('codex', runtime, true, true);
      expect(modelPref['agent']).assertEqual('codex');
      expect(modelPref['modelId']).assertEqual('chosen');
      expect(modelPref['providerId']).assertEqual('');
      expect(modelPref['effort']).assertEqual('low');
      expect(modelPref['fast']).assertEqual(true);
      expect(modelPref['active']).assertEqual(true);
      expect(modelPref['markModelChoice']).assertEqual(true);
      expect(newSessionDraftPref('codex', runtime, true, false)['markModelChoice']).assertEqual(false);
      runtime.providerId = 'source';
      const rowPref = newSessionDraftPref('codex', runtime, false, false);
      expect(rowPref['active']).assertEqual(false);
      expect(rowPref['markModelChoice'] === undefined).assertTrue();
      runtime.effort = '';
      expect(newSessionDraftPref('pi', runtime, true, false)['effort'] === undefined).assertTrue();
    });
    it('serializes_same_scope_writes_and_recovers_from_legacy_rejection', 0, async () => {
      const writer = new NewSessionDraftPrefWriter();
      const delayed = new DefaultsDeferred<void>();
      const writes: string[] = [];
      const first = writer.enqueue('scope', async (): Promise<void> => {
        writes.push('model');
        await delayed.promise;
        throw new Error('CHANNEL_NOT_ALLOWED');
      });
      const second = writer.enqueue('scope', async (): Promise<void> => { writes.push('effort'); });
      await Promise.resolve();
      expect(writes.join(',')).assertEqual('model');
      delayed.resolve(undefined);
      await first;
      await second;
      expect(writes.join(',')).assertEqual('model,effort');
    });
    it('does_not_block_other_devices_behind_a_slow_write', 0, async () => {
      const writer = new NewSessionDraftPrefWriter();
      const delayed = new DefaultsDeferred<void>();
      let independentFinished = false;
      const pending = writer.enqueue('device-a', (): Promise<void> => delayed.promise);
      await writer.enqueue('device-b', async (): Promise<void> => { independentFinished = true; });
      expect(independentFinished).assertTrue();
      delayed.resolve(undefined);
      await pending;
    });
    it('normalizes_optional_drive_lists_and_hides_single_drive_hosts', 0, () => {
      expect(normalizeRemoteDirectoryDrives(undefined).length).assertEqual(0);
      expect(normalizeRemoteDirectoryDrives(defaultsRecord('{}')).length).assertEqual(0);
      const single: Object[] = [defaultsRecord('{"path":"C:/"}')];
      expect(normalizeRemoteDirectoryDrives(single).length).assertEqual(0);
      const source: Object[] = [
        defaultsRecord('{"path":"C:/","name":"System","current":true}'),
        defaultsRecord('{"path":"D:/"}'),
        defaultsRecord('{"path":"C:/","name":"duplicate"}'),
        defaultsRecord('{"name":"invalid"}'),
        'invalid',
      ];
      const drives = normalizeRemoteDirectoryDrives(source);
      expect(drives.length).assertEqual(2);
      expect(drives[0].name).assertEqual('System');
      expect(drives[0].current).assertTrue();
      expect(drives[1].name).assertEqual('D:/');
    });
    it('bounds_pending_drive_enumeration_to_three_followup_reads', 0, () => {
      expect(shouldRetryRemoteBrowseDrives(true, 0)).assertTrue();
      expect(shouldRetryRemoteBrowseDrives(true, 2)).assertTrue();
      expect(shouldRetryRemoteBrowseDrives(true, 3)).assertFalse();
      expect(shouldRetryRemoteBrowseDrives(true, -1)).assertFalse();
      expect(shouldRetryRemoteBrowseDrives(undefined, 0)).assertFalse();
      expect(shouldRetryRemoteBrowseDrives('true', 0)).assertFalse();
    });
  });
}
