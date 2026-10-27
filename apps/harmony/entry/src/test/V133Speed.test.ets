import { describe, expect, it } from '@ohos/hypium';
import { DlClient, DlClientOptions, DlInvokeOptions } from '../main/ets/core/device-link/DlClient';
import { DlChannels, Envelope } from '../main/ets/core/device-link/DlProtocol';
import { InputQueueStore } from '../main/ets/core/messages/InputQueueStore';
import { ComposerModelOption } from '../main/ets/core/ComposerCatalog';
import { parseSession, RemoteSession } from '../main/ets/core/tasks/TaskModels';
import { TaskStore } from '../main/ets/core/tasks/TaskStore';
import {
  NewSessionRuntime, hostDraftRuntimeFromDefaults, newSessionDraftPref, pickNewSessionRuntime,
} from '../main/ets/core/tasks/NewSessionRuntimeDefaults';
import { parseSessionAgentSwitchIntent, sessionAgentSwitchIntentApplied } from '../main/ets/core/tasks/SessionAgentSwitch';

function speedRecord(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

function speedEnvelope(result: Object): Envelope {
  const payload: Record<string, Object> = {};
  payload['ok'] = true;
  payload['result'] = result;
  const envelope = new Envelope();
  envelope.payload = payload;
  return envelope;
}

class SpeedClient extends DlClient {
  enqueued: Record<string, Object>[] = [];

  constructor() {
    super(new DlClientOptions());
  }

  getStatus(): string {
    return 'online';
  }

  connectionIdentity(_deviceId: string): string {
    return '1';
  }

  invoke(_deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    if (options.preSend !== undefined) options.preSend();
    if (options.channel === 'maker:input:enqueue') this.enqueued.push(options.args[1] as Record<string, Object>);
    const projection: Record<string, Object> = {};
    projection['sessionId'] = 'speed-session';
    projection['pendingQueue'] = [];
    return Promise.resolve(speedEnvelope(projection));
  }
}

function codexModel(id: string, ultrafast: boolean): ComposerModelOption {
  const option = new ComposerModelOption();
  option.id = id;
  option.providerId = 'openai';
  option.supportsFastMode = true;
  option.supportsUltrafastMode = ultrafast;
  return option;
}

export default function v133SpeedTest(): void {
  describe('V133Speed', () => {
    it('reads_host_encoded_and_decoded_ultrafast_without_losing_fast', 0, () => {
      // 新 Host 的加法编码：旧字段仍是 true，tier 携带超快。
      const encoded = parseSession(speedRecord(
        '{"id":"a","fastMode":true,"fastModeTier":"ultrafast","runtimeEffective":{"agentKind":"codex","model":"m","fastMode":true,"fastModeTier":"ultrafast"}}'));
      expect(encoded.fastMode).assertTrue();
      expect(encoded.fastModeTier).assertEqual('ultrafast');
      expect(encoded.runtimeEffective?.fastModeTier).assertEqual('ultrafast');
      const decoded = parseSession(speedRecord('{"id":"b","fastMode":"ultrafast"}'));
      expect(decoded.fastMode).assertTrue();
      expect(decoded.fastModeTier).assertEqual('ultrafast');
      // tier 不能把关闭的快速打开；旧 Host 只有布尔。
      const off = parseSession(speedRecord('{"id":"c","fastMode":false,"fastModeTier":"ultrafast"}'));
      expect(off.fastMode).assertFalse();
      expect(off.fastModeTier).assertEqual('');
      expect(parseSession(speedRecord('{"id":"d","fastMode":true}')).fastModeTier).assertEqual('');
    });

    it('queued_send_echoes_ultrafast_instead_of_downgrading_to_fast', 0, async () => {
      const client = new SpeedClient();
      const store = new InputQueueStore();
      store.attach(client);
      const session = new RemoteSession();
      session.id = 'speed-session';
      session.agentKind = 'codex';
      session.model = 'gpt';
      session.fastMode = true;
      session.fastModeTier = 'ultrafast';
      await store.enqueueText('device', session, 'go', [], 'ultra-send');
      session.fastModeTier = '';
      await store.enqueueText('device', session, 'go', [], 'fast-send');
      expect(client.enqueued.length).assertEqual(2);
      expect((client.enqueued[0]['createOpts'] as Record<string, Object>)['fastMode'] as string).assertEqual('ultrafast');
      expect((client.enqueued[1]['createOpts'] as Record<string, Object>)['fastMode'] as boolean).assertTrue();
      store.clearAll();
    });

    it('new_session_defaults_restore_ultrafast_only_while_the_codex_model_supports_it', 0, () => {
      const preferred = hostDraftRuntimeFromDefaults(speedRecord(
        '{"model":"gpt","providerId":"openai","fastMode":true,"fastModeTier":"ultrafast"}')) as NewSessionRuntime;
      expect(preferred.fastModeTier).assertEqual('ultrafast');
      const supported = pickNewSessionRuntime('codex', preferred, [codexModel('gpt', true)], new Map());
      expect(supported.fastMode).assertTrue();
      expect(supported.fastModeTier).assertEqual('ultrafast');
      expect(newSessionDraftPref('codex', supported, true, false)['fast'] as string).assertEqual('ultrafast');
      // 能力被撤回时整体关闭，而不是降成快速（对齐 Mobile isFastRestorable）。
      const revoked = pickNewSessionRuntime('codex', preferred, [codexModel('gpt', false)], new Map());
      expect(revoked.fastMode).assertFalse();
      expect(newSessionDraftPref('codex', revoked, true, false)['fast'] as boolean).assertFalse();
    });

    it('session_speed_patches_replace_the_tier_before_the_next_send', 0, async () => {
      const tasks = new TaskStore();
      const client = new SpeedClient();
      const queue = new InputQueueStore();
      queue.attach(client);
      tasks.upsertSession('device', parseSession(speedRecord(
        '{"id":"speed-session","agentKind":"codex","fastMode":true,"fastModeTier":"ultrafast"}')));
      const patch = (fields: string): void => {
        const payload: Record<string, Object> = {};
        payload['sessionId'] = 'speed-session';
        payload['patch'] = speedRecord(fields);
        tasks.handleSessionsPush('device', DlChannels.SESSIONS_PATCHED, payload);
      };
      patch('{"title":"Renamed"}');
      expect(tasks.getSessions('device')[0].fastModeTier).assertEqual('ultrafast');
      patch('{"fastMode":true}');
      const fast = tasks.getSessions('device')[0];
      expect(fast.fastModeTier).assertEqual('');
      await queue.enqueueText('device', fast, 'go', [], 'patched-fast');
      expect((client.enqueued[0]['createOpts'] as Record<string, Object>)['fastMode'] as boolean).assertTrue();
      patch('{"fastMode":true,"fastModeTier":"ultrafast"}');
      expect(tasks.getSessions('device')[0].fastModeTier).assertEqual('ultrafast');
      patch('{"fastMode":false}');
      expect(tasks.getSessions('device')[0].fastMode).assertFalse();
      expect(tasks.getSessions('device')[0].fastModeTier).assertEqual('');
      queue.clearAll();
      tasks.clearAll();
    });

    it('agent_switch_intent_accepts_ultrafast_and_compares_the_exact_tier', 0, () => {
      const intent = parseSessionAgentSwitchIntent(speedRecord(
        '{"targetAgentKind":"codex","model":"gpt","fastMode":"ultrafast"}'));
      expect(intent !== null).assertTrue();
      const session = parseSession(speedRecord('{"id":"s","agentKind":"codex","model":"gpt","fastMode":true}'));
      expect(sessionAgentSwitchIntentApplied(session, intent!)).assertFalse();
      session.fastModeTier = 'ultrafast';
      expect(sessionAgentSwitchIntentApplied(session, intent!)).assertTrue();
      expect(parseSessionAgentSwitchIntent(speedRecord(
        '{"targetAgentKind":"codex","model":"gpt","fastMode":"turbo"}')) === null).assertTrue();
    });
  });
}
