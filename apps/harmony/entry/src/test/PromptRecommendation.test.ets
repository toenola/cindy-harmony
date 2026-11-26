import { describe, expect, it } from '@ohos/hypium';
import {
  PromptRecommendationController, PromptRecommendationInput, PromptRecommendationVisibility,
} from '../main/ets/core/messages/PromptRecommendation';
import { PromptRecommendationPreference, PromptPreferenceStorage } from '../main/ets/core/messages/PromptRecommendationPreference';

// Unit tier; real controller / preference entry points, no socket, model, disk or wall-clock waits.
// New fake-clock fixture protects paid-generation authorization, cache-only recovery and local
// opt-out races, which message-presentation tests cannot exercise. Minimal inputs are one
// completed revision, one running edge, or one deferred storage response.
class RecommendationClock {
  private id: number = 0;
  pending: Map<number, () => void> = new Map();
  delays: number[] = [];
  schedule(callback: () => void, delay: number): number {
    const id = ++this.id; this.delays.push(delay); this.pending.set(id, callback); return id;
  }
  cancel(id: number): void { this.pending.delete(id); }
  next(): void {
    const id: number = this.pending.keys().next().value as number;
    const callback = this.pending.get(id);
    this.pending.delete(id); callback?.();
  }
}
function input(session: string, revision: number = 10): PromptRecommendationInput {
  const state = new PromptRecommendationInput();
  state.owner = 'test-owner'; state.deviceId = 'test-computer'; state.sessionId = session;
  state.agentKind = 'codex'; state.revision = revision; state.available = true;
  state.ready = true; state.enabled = true; state.connectionEpoch = '1'; return state;
}
async function settle(): Promise<void> { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); }
class RecommendationStorage implements PromptPreferenceStorage {
  value: string = '';
  readFails: boolean = false;
  writeFails: boolean = false;
  async get(_key: string, _fallback: string): Promise<string> {
    if (this.readFails) throw new Error('test read failure'); return this.value;
  }
  async set(_key: string, value: string): Promise<void> {
    if (this.writeFails) throw new Error('test write failure'); this.value = value;
  }
  async remove(_key: string): Promise<void> {
    if (this.writeFails) throw new Error('test delete failure'); this.value = '';
  }
}
class DeferredRecommendationStorage extends RecommendationStorage {
  completeRead: (value: string) => void = (_value: string): void => {};
  get(_key: string, _fallback: string): Promise<string> {
    return new Promise<string>((resolve) => { this.completeRead = resolve; });
  }
}
export default function promptRecommendationTests(): void {
  describe('PromptRecommendation', () => {
    it('historical_navigation_only_reads_cache_with_three_bounded_cache_miss_retries', 0, async () => {
      const clock = new RecommendationClock(), modes: boolean[] = [];
      const controller = new PromptRecommendationController(async (_state: PromptRecommendationInput, cacheOnly: boolean): Promise<string> => {
        modes.push(cacheOnly); return '';
      }, (): void => {}, (fn: () => void, delay: number): number => clock.schedule(fn, delay),
      (id: number): void => clock.cancel(id));
      controller.update(input('history'));
      for (let i = 0; i < 4; i++) { clock.next(); await settle(); }
      expect(JSON.stringify(modes)).assertEqual('[true,true,true,true]');
      expect(JSON.stringify(clock.delays)).assertEqual('[500,1000,3000,5000]');
      controller.update(input('history')); expect(clock.pending.size).assertEqual(0); controller.dispose();
    });
    it('observed_completion_waits_for_revision_and_empty_draft_then_generates_only_once', 0, async () => {
      const clock = new RecommendationClock(), modes: boolean[] = [];
      const controller = new PromptRecommendationController(async (_state: PromptRecommendationInput, cacheOnly: boolean): Promise<string> => {
        modes.push(cacheOnly); return 'Check the result';
      }, (): void => {}, (fn: () => void, delay: number): number => clock.schedule(fn, delay),
      (id: number): void => clock.cancel(id));
      const running = input('live'); running.running = true; controller.update(running);
      const stopped = input('live'); stopped.hasDraft = true; controller.update(stopped);
      const complete = input('live', 11); complete.hasDraft = true; controller.update(complete);
      expect(clock.pending.size).assertEqual(0);
      controller.update(input('live', 11));
      const beforeDispatch = input('live', 11); beforeDispatch.hasDraft = true; controller.update(beforeDispatch);
      expect(clock.pending.size).assertEqual(0);
      controller.update(input('live', 11)); clock.next(); await settle();
      expect(JSON.stringify(modes)).assertEqual('[false]');
      expect(controller.prompt()).assertEqual('Check the result');
      const typing = input('live', 11); typing.hasDraft = true; controller.update(typing);
      controller.update(input('live', 11)); expect(clock.pending.size).assertEqual(0);
      const attachment = input('live', 11); attachment.displayBlocked = true; controller.update(attachment);
      expect(controller.prompt()).assertEqual('');
      controller.update(input('live', 11)); expect(controller.prompt()).assertEqual('Check the result'); controller.dispose();
    });
    it('recovery_reads_cache_after_lost_paid_response_and_rejects_old_task_response', 0, async () => {
      const clock = new RecommendationClock(), modes: boolean[] = [];
      let complete: (value: string) => void = (_value: string): void => {};
      const controller = new PromptRecommendationController(async (_state: PromptRecommendationInput, cacheOnly: boolean): Promise<string> => {
        modes.push(cacheOnly);
        if (!cacheOnly) throw new Error('link lost');
        return new Promise<string>((resolve) => { complete = resolve; });
      }, (): void => {}, (fn: () => void, delay: number): number => clock.schedule(fn, delay),
      (id: number): void => clock.cancel(id));
      const running = input('recover'); running.running = true; controller.update(running);
      controller.update(input('recover', 11)); clock.next(); await settle();
      controller.update(input('recover', 11)); expect(clock.pending.size).assertEqual(0);
      const restored = input('recover', 11); restored.connectionEpoch = '2'; controller.update(restored);
      clock.next(); await settle(); expect(JSON.stringify(modes)).assertEqual('[false,true]');
      controller.update(input('other-task', 20)); complete('Old result'); await settle();
      expect(controller.prompt()).assertEqual(''); controller.dispose(); expect(clock.pending.size).assertEqual(0);
    });
    it('opt_out_cancels_pending_prediction_and_dismissal_survives_remount', 0, async () => {
      const clock = new RecommendationClock(); let calls = 0;
      const make = (): PromptRecommendationController => new PromptRecommendationController(
        async (_state: PromptRecommendationInput, _cacheOnly: boolean): Promise<string> => { calls++; return 'Next'; },
        (): void => {}, (fn: () => void, delay: number): number => clock.schedule(fn, delay),
        (id: number): void => clock.cancel(id));
      const controller = make(); controller.update(input('dismiss'));
      const off = input('dismiss'); off.enabled = false; controller.update(off); expect(clock.pending.size).assertEqual(0);
      controller.update(input('dismiss')); clock.next(); await settle(); controller.dismiss(); controller.dispose();
      const remount = make(); remount.update(input('dismiss')); expect(clock.pending.size).assertEqual(0);
      expect(remount.prompt()).assertEqual(''); expect(calls).assertEqual(1); remount.dispose();
      const failed = make(); const error = input('failed'); error.terminalError = true; failed.update(error);
      expect(clock.pending.size).assertEqual(0); failed.dispose();
    });
    it('focus_and_typing_hide_without_consuming_and_collapse_or_empty_draft_restore', 0, () => {
      const visibility = new PromptRecommendationVisibility();
      visibility.update('a', '', false); expect(visibility.hidden).assertFalse();
      visibility.update('a', '', true); expect(visibility.hidden).assertTrue();
      visibility.update('a', 'text', true); expect(visibility.hidden).assertTrue();
      visibility.update('a', 'text', false); expect(visibility.hidden).assertFalse();
      visibility.hide(); expect(visibility.hidden).assertTrue();
      visibility.update('a', '', false); expect(visibility.hidden).assertFalse();
      visibility.update('b', 'restored draft', false); expect(visibility.hidden).assertTrue();
    });
    it('local_preference_defaults_on_but_failed_read_never_overrides_a_saved_opt_out', 0, async () => {
      const storage = new RecommendationStorage(); const preference = new PromptRecommendationPreference();
      expect(preference.ready).assertFalse(); await preference.load(storage); expect(preference.enabled).assertTrue();
      await preference.save(false); expect(storage.value).assertEqual('false');
      const next = new PromptRecommendationPreference(); await next.load(storage); expect(next.enabled).assertFalse();
      storage.readFails = true; const failed = new PromptRecommendationPreference(); await failed.load(storage);
      expect(failed.ready).assertTrue(); expect(failed.enabled).assertFalse();
      storage.readFails = false; await failed.load(storage); expect(failed.enabled).assertFalse();
      await preference.save(null); expect(preference.enabled).assertTrue(); expect(preference.customized).assertFalse();
    });
    it('late_preference_read_cannot_overwrite_a_new_opt_out', 0, async () => {
      const storage = new DeferredRecommendationStorage(); const preference = new PromptRecommendationPreference();
      const read = preference.load(storage); const write = preference.save(false);
      storage.completeRead('true'); await read; await write;
      expect(preference.ready).assertTrue(); expect(preference.enabled).assertFalse();
      expect(storage.value).assertEqual('false');
    });
    it('failed_save_keeps_live_choice_and_failed_reset_preserves_reset_action', 0, async () => {
      const storage = new RecommendationStorage(); const preference = new PromptRecommendationPreference();
      await preference.load(storage); await preference.save(false); storage.writeFails = true;
      let rejected = false;
      try { await preference.save(null); } catch (_error) { rejected = true; }
      expect(rejected).assertTrue(); expect(preference.enabled).assertTrue(); expect(preference.customized).assertTrue();
      expect(storage.value).assertEqual('false'); storage.writeFails = false;
      const first = preference.save(false), last = preference.save(true); await first; await last;
      expect(storage.value).assertEqual('true'); expect(preference.enabled).assertTrue();
    });
  });
}
