import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { unwrapInvokeResult } from '../tasks/TaskStore';
import { recordOrEmpty, readStr } from '../tasks/TaskModels';
/** Port of Mobile usePromptRecommendation: a historical view never starts a paid prediction. */
export class PromptRecommendationInput {
  owner: string = '';
  deviceId: string = '';
  sessionId: string = '';
  agentKind: string = '';
  revision: number = 0;
  running: boolean = false;
  available: boolean = false;
  connectionEpoch: string = '';
  ready: boolean = false;
  enabled: boolean = false;
  hasDraft: boolean = false;
  displayBlocked: boolean = false;
  terminalError: boolean = false;
}
class PredictionAttempt {
  scope: string = '';
  revision: number = 0;
  cacheOnly: boolean = true;
  requestCacheOnly: boolean = true;
  connectionEpoch: string = '';
  failed: boolean = false;
  started: boolean = false;
  retry: number = 0;
}
// Runtime-only dismissal survives remounts. No prompt or private task text is persisted here.
const consumed = new Map<string, number>();
function rememberConsumed(scope: string, revision: number): void {
  if (consumed.size >= 512 && !consumed.has(scope)) consumed.delete(consumed.keys().next().value);
  consumed.set(scope, revision);
}
export function recommendationScope(input: PromptRecommendationInput): string {
  return JSON.stringify([input.owner, input.deviceId, input.sessionId]);
}
export class PromptRecommendationController {
  private input: PromptRecommendationInput = new PromptRecommendationInput();
  private scope: string = '';
  private running: boolean = false;
  private sawRunning: boolean = false;
  private revisionAtStart: number = 0;
  private liveRevision: number = 0;
  private paidRevision: number = 0;
  private attempt: PredictionAttempt | null = null;
  private timer: number = -1;
  private result: string = '';
  private resultRevision: number = 0;
  private disposed: boolean = false;
  private predict: (input: PromptRecommendationInput, cacheOnly: boolean) => Promise<string>;
  private changed: () => void;
  private schedule: (callback: () => void, delay: number) => number;
  private cancel: (timer: number) => void;
  constructor(
    predict: (input: PromptRecommendationInput, cacheOnly: boolean) => Promise<string>,
    changed: () => void,
    schedule: (callback: () => void, delay: number) => number =
      (callback: () => void, delay: number): number => setTimeout(callback, delay),
    cancel: (timer: number) => void = (timer: number): void => clearTimeout(timer),
  ) { this.predict = predict; this.changed = changed; this.schedule = schedule; this.cancel = cancel; }
  private clearTimer(): void { if (this.timer >= 0) this.cancel(this.timer); this.timer = -1; }
  private clearResult(): void { this.result = ''; this.resultRevision = 0; }
  update(input: PromptRecommendationInput): void {
    if (this.disposed) return;
    const scope = recommendationScope(input);
    if (scope !== this.scope) {
      this.clearTimer(); this.scope = scope; this.running = false; this.sawRunning = false;
      this.revisionAtStart = 0; this.liveRevision = 0; this.paidRevision = 0;
      this.attempt = null; this.clearResult();
    }
    this.input = input;
    if (input.ready && !input.enabled) {
      this.clearTimer(); this.running = false; this.sawRunning = false; this.liveRevision = 0;
      this.attempt = null; this.clearResult(); this.changed(); return;
    }
    if (input.running) {
      if (!this.running) {
        consumed.delete(scope); this.sawRunning = true; this.revisionAtStart = input.revision;
        this.liveRevision = 0; this.paidRevision = 0; this.attempt = null;
        this.clearTimer(); this.clearResult();
      }
      this.running = true; this.changed(); return;
    }
    this.running = false;
    if (this.sawRunning && input.revision > this.revisionAtStart) this.liveRevision = input.revision;
    const revision = input.revision;
    if (!input.deviceId || !input.sessionId || !input.agentKind || !revision || consumed.get(scope) === revision) {
      this.changed(); return;
    }
    if (input.terminalError) {
      this.sawRunning = false; this.liveRevision = 0; rememberConsumed(scope, revision);
      this.clearTimer(); this.attempt = null; this.clearResult(); this.changed(); return;
    }
    const blocked = input.hasDraft || input.displayBlocked;
    if (blocked && this.attempt !== null && !this.attempt.started) {
      this.clearTimer(); this.attempt = null;
    }
    if (!input.ready || !input.enabled || !input.available || blocked
      || (this.resultRevision === revision && this.result.length > 0)) { this.changed(); return; }
    const cacheOnly = this.liveRevision !== revision;
    const previous = this.attempt;
    if (previous !== null && previous.scope === scope && previous.revision === revision
      && previous.cacheOnly === cacheOnly
      && (!previous.failed || previous.connectionEpoch === input.connectionEpoch)) { this.changed(); return; }
    this.clearTimer();
    const attempt = new PredictionAttempt();
    attempt.scope = scope; attempt.revision = revision; attempt.cacheOnly = cacheOnly;
    attempt.requestCacheOnly = cacheOnly || this.paidRevision === revision;
    attempt.connectionEpoch = input.connectionEpoch;
    this.attempt = attempt;
    this.timer = this.schedule(() => this.dispatch(attempt), 500);
    this.changed();
  }
  private current(attempt: PredictionAttempt): boolean {
    const input = this.input;
    return !this.disposed && this.attempt === attempt && recommendationScope(input) === attempt.scope
      && input.revision === attempt.revision && input.ready && input.enabled && !input.running
      && !input.terminalError && consumed.get(this.scope) !== attempt.revision;
  }
  private dispatch(attempt: PredictionAttempt): void {
    this.timer = -1;
    if (!this.current(attempt) || (!attempt.started && (this.input.hasDraft || this.input.displayBlocked))) return;
    if (!this.input.available) { attempt.failed = true; return; }
    attempt.started = true;
    if (!attempt.requestCacheOnly) { this.sawRunning = false; this.paidRevision = attempt.revision; }
    const request = this.input;
    this.predict(request, attempt.requestCacheOnly).then((prompt: string): void => {
      if (!this.current(attempt)) return;
      if (prompt.length > 0) { this.result = prompt; this.resultRevision = attempt.revision; this.changed(); }
      else if (attempt.requestCacheOnly && attempt.retry < 3) {
        const delays = [1000, 3000, 5000];
        this.timer = this.schedule(() => this.dispatch(attempt), delays[attempt.retry++]);
      }
    }).catch((): void => {
      if (!this.current(attempt)) return;
      attempt.failed = true;
      // Recovery may already have happened while the old request was in flight.
      this.update(this.input);
    });
  }
  prompt(): string {
    const input = this.input;
    return input.ready && input.enabled && !input.running && !input.displayBlocked
      && !input.terminalError && this.resultRevision === input.revision
      && consumed.get(this.scope) !== input.revision ? this.result : '';
  }
  dismiss(): void {
    if (this.input.revision) rememberConsumed(this.scope, this.input.revision);
    this.sawRunning = false; this.liveRevision = 0;
    this.clearTimer(); this.attempt = null; this.clearResult(); this.changed();
  }
  dispose(): void { this.disposed = true; this.attempt = null; this.clearTimer(); }
}

/** Mobile visibility is separate from consuming a suggestion; typing does not dismiss it. */
export class PromptRecommendationVisibility {
  private scope: string = '';
  private draft: string = '';
  private active: boolean = false;
  hidden: boolean = true;
  update(scope: string, draft: string, active: boolean): void {
    if (this.scope !== scope) this.hidden = active || draft.length > 0;
    else if (this.active !== active) this.hidden = active;
    else if (this.draft !== draft) this.hidden = draft.length > 0;
    this.scope = scope; this.draft = draft; this.active = active;
  }
  hide(): void { this.hidden = true; }
}

/** Existing Mobile business channel. The controlled computer owns generation and model access. */
export async function requestPromptRecommendation(client: DlClient, input: PromptRecommendationInput,
  cacheOnly: boolean): Promise<string> {
  const request: Record<string, Object> = {};
  request['sessionId'] = input.sessionId; request['agentKind'] = input.agentKind;
  request['turnGen'] = 0; request['completionRevision'] = input.revision; request['cacheOnly'] = cacheOnly;
  const options = new DlInvokeOptions(); options.channel = 'maker:predict-prompt'; options.args = [request];
  return readStr(recordOrEmpty(unwrapInvokeResult(await client.invoke(input.deviceId, options))), 'prompt');
}
