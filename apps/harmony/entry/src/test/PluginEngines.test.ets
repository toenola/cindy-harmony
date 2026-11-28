import { describe, expect, it } from '@ohos/hypium';
import {
  findPluginEngine, isPluginEngineSession, normalizePluginEngines, normalizePluginUsage, pluginEngineKey,
} from '../main/ets/core/plugin-engines/PluginEngines';
import { PluginEngineStore } from '../main/ets/core/plugin-engines/PluginEngineStore';

const provider = 'acp-plugin:com.example:agy';

// Unit: actual catalogue/usage inputs exercise namespace matching, placeholder classification,
// and the account-scoped read cache. Existing usage snapshots do not contain plugin identity.
// Minimum regressions: same engine suffix under two plugins, no icon, a real zero vs. absent
// usage, and a repeated same-device read vs. switching devices/accounts. No network or waits.
export default function pluginEnginesTests(): void {
  describe('PluginEngines', () => {
    // Unit: picker-visible catalog keeps wire IDs and the host reason, unlike the icon-only projection.
    it('retains valid model IDs, display names, effort levels and unavailable reason', 0, (): void => {
      const raw = JSON.parse('[{"providerId":"acp-plugin:plugin:engine","name":"Engine",'
        + '"availability":{"state":"unavailable","message":"CLI not found"},'
        + '"models":[{"id":"wire/model","displayName":"Model","efforts":["high","bad","low"]},'
        + '{"id":"alt","label":"Alternative"}]}]') as Object;
      const engine = normalizePluginEngines(raw)[0];
      expect(engine.availabilityMessage).assertEqual('CLI not found');
      expect(engine.models.length).assertEqual(2);
      expect(engine.models[0].id).assertEqual('wire/model');
      expect(engine.models[0].efforts.join(',')).assertEqual('low,high');
      expect(engine.models[1].label).assertEqual('Alternative');
    });

    it('matches_acp_using_the_full_provider_identity_and_never_relabels_builtins', 0, () => {
      const raw = JSON.parse('[{"providerId":"acp-plugin:other:agy","name":"Other"},'
        + '{"providerId":"acp-plugin:com.example:agy","name":" Antigravity ","iconDataUrl":"data:image/png;base64,AA==",'
        + '"availability":{"state":"available"},"reportsUsage":true},'
        + '{"providerId":"acp-plugin:com.example:agy","name":"Duplicate"},'
        + '{"providerId":"acp-plugin:agy","name":"Invalid"}]') as Object;
      const engines = normalizePluginEngines(raw);
      expect(engines.length).assertEqual(2);
      expect(findPluginEngine(engines, provider)?.name).assertEqual('Antigravity');
      expect(findPluginEngine(engines, provider)?.reportsUsage).assertTrue();
      expect(findPluginEngine(engines, provider)?.availability).assertEqual('available');
      expect(findPluginEngine(engines, provider)?.iconDataUrl).assertEqual('data:image/png;base64,AA==');
      expect(findPluginEngine(engines, 'acp-plugin:other:agy')?.iconDataUrl).assertEqual('');
      expect(pluginEngineKey(provider)).assertEqual('com.example:agy');
      expect(isPluginEngineSession('acp', '')).assertTrue();
      expect(isPluginEngineSession('codex', provider)).assertFalse();
      expect(isPluginEngineSession('unknown', '')).assertFalse();
    });

    it('only_projects_reported_quota_and_keeps_measured_zero', 0, () => {
      const zero = normalizePluginUsage(JSON.parse('{"updatedAt":1,"windows":[{"label":"Daily",'
        + '"remainingPercent":0,"resetsAt":5000}],"balances":[{"currency":"USD","amount":"0.00"}]}') as Object);
      expect(zero?.windows[0].remainingPercent).assertEqual(0);
      expect(zero?.windows[0].resetsAt).assertEqual(5000);
      expect(zero?.balances[0].amount).assertEqual('0.00');
      expect(normalizePluginUsage(JSON.parse('{"updatedAt":1}') as Object) === null).assertTrue();
      const invalid = JSON.parse('{"updatedAt":1,"windows":[{"label":"Daily","remainingPercent":101}]}') as Object;
      expect(normalizePluginUsage(invalid) === null).assertTrue();
    });

    it('shares_reads_by_account_device_and_engine_and_sends_the_unprefixed_key', 0, async () => {
      let owner = 'a';
      const calls: string[] = [];
      const store = new PluginEngineStore((): string => owner,
        async (device: string, channel: string, args: Object[], _current: () => boolean): Promise<Object> => {
          calls.push(device + '/' + channel + '/' + args.join(','));
          if (channel === 'maker:list-plugin-engines') {
            return JSON.parse('[{"providerId":"acp-plugin:com.example:agy","name":"Antigravity","reportsUsage":true}]') as Object;
          }
          return JSON.parse('{"updatedAt":1,"balances":[{"currency":"USD","amount":"1"}]}') as Object;
        });
      await Promise.all([store.load('desk'), store.load('desk')]);
      await store.load('desk');
      await Promise.all([store.readUsage('desk', provider), store.readUsage('desk', provider)]);
      await store.readUsage('other', provider);
      expect(calls.length).assertEqual(3);
      expect(calls[1]).assertEqual('desk/maker:get-plugin-engine-usage/com.example:agy');
      expect(calls[2]).assertEqual('other/maker:get-plugin-engine-usage/com.example:agy');
      owner = 'b';
      expect(store.listCached('desk').length).assertEqual(0);
      await store.readUsage('desk', provider);
      expect(calls.length).assertEqual(4);
    });
  });
}
