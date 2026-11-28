import { recordOrEmpty } from '../tasks/TaskModels';
import { ModelRoute, ModelRoutingBinding, ModelRoutingCatalog, ModelRoutingOffer, ModelRoutingResult,
  modelRouteWire, parseModelRoutingBinding, parseModelRoutingCatalog, parseModelRoutingOffer,
  parseModelRoutingResult } from './ModelRoutingModels';

/** Adapter must use the current owner-authorized Device Link peer and unwrap its invoke result. */
export interface ModelRoutingPort {
  invoke(deviceId: string, channel: string, args: Object[]): Promise<Object | undefined>;
  isOwner(deviceId: string): boolean;
}
export class ModelRoutingSnapshot {
  status: string = 'idle'; // idle/loading/ready/unsupported/error
  catalog: ModelRoutingCatalog | null = null;
  error: string = '';
  readAt: number = 0;
}
export class ModelRoutingSession {
  binding: ModelRoutingBinding | null = null;
  offer: ModelRoutingOffer | null = null;
  error: string = '';
}
export class ModelRoutingContext {
  hasImages: boolean = false;
  effort: string = '';
  fastMode: boolean | string = false;
  /** undefined = new task; null = task runs on the controlled computer. */
  agentDeviceId: string | null | undefined = undefined;
  sshHostId: string = '';
}
/** Opaque handle; only this Store's exact object is accepted. No ticket/decision is persisted. */
export class ModelRoutingTicket {
  id: number = 0;
  deviceId: string = '';
  routeId: string = '';
  result: ModelRoutingResult = new ModelRoutingResult();
}
class ModelRoutingLocation {
  agentDeviceId: string | null = null;
}
class TicketState {
  ticket: ModelRoutingTicket = new ModelRoutingTicket();
  scope: string = '';
  epoch: number = 0;
  sessionId: string = '';
  writeVersion: number = 0;
  bound: boolean = false;
  binding: Promise<void> | null = null;
  accepted: Promise<void> | null = null;
}
export function modelRoutingUnsupported(error: string): boolean {
  return /CHANNEL_NOT_ALLOWED|UNSUPPORTED_CAPABILITY|not registered|No handler/i.test(error);
}
function selectionWire(id: string): Record<string, Object> {
  const selection: Record<string, Object> = {};
  selection['type'] = 'route'; selection['id'] = id; return selection;
}
function sessionWire(sessionId: string): Record<string, Object> {
  const request: Record<string, Object> = {}; request['sessionId'] = sessionId; return request;
}
function bindingWire(sessionId: string, routeId: string, route: ModelRoute): Record<string, Object> {
  const request = sessionWire(sessionId); request['selection'] = selectionWire(routeId);
  request['route'] = modelRouteWire(route); return request;
}
export class ModelRoutingStore {
  private port: ModelRoutingPort;
  private now: () => number;
  private owner: string = '';
  private generation: number = 0;
  private revision: number = 0;
  private epochs: Map<string, number> = new Map();
  private snapshots: Map<string, ModelRoutingSnapshot> = new Map();
  private pending: Map<string, Promise<ModelRoutingSnapshot>> = new Map();
  private sessions: Map<string, ModelRoutingSession> = new Map();
  private sessionPending: Map<string, Promise<ModelRoutingSession>> = new Map();
  private sessionOffersPending: Set<string> = new Set();
  private mutationErrors: Map<string, string> = new Map();
  private writeVersions: Map<string, number> = new Map();
  private sessionVersions: Map<string, number> = new Map();
  private tickets: Map<number, TicketState> = new Map();
  private nextId: number = 0;
  private listeners: Set<() => void> = new Set();
  constructor(port: ModelRoutingPort, now: () => number = Date.now) { this.port = port; this.now = now; }
  setScope(owner: string, generation: number): void {
    if (this.owner === owner && this.generation === generation) return;
    this.owner = owner; this.generation = generation; this.revision++;
    this.epochs.clear(); this.snapshots.clear(); this.pending.clear(); this.sessions.clear();
    this.sessionPending.clear(); this.sessionOffersPending.clear(); this.sessionVersions.clear(); this.mutationErrors.clear(); this.writeVersions.clear(); this.tickets.clear(); this.emit();
  }
  /** Final owner lifecycle cleanup; late requests fail their captured scope check. */
  dispose(): void {
    this.setScope('', this.generation + 1);
    this.listeners.clear();
  }
  invalidateDevice(device: string): void {
    this.epochs.set(device, this.epoch(device) + 1);
    this.snapshots.delete(device); this.pending.delete(device);
    const prefix = JSON.stringify(device) + ':';
    this.sessions.forEach((_value: ModelRoutingSession, key: string): void => {
      if (key.startsWith(prefix)) this.sessions.delete(key);
    });
    this.sessionPending.forEach((_value: Promise<ModelRoutingSession>, key: string): void => {
      if (key.startsWith(prefix)) { this.sessionPending.delete(key); this.sessionOffersPending.delete(key); }
    });
    this.mutationErrors.forEach((_error: string, key: string): void => {
      if (key.startsWith(prefix)) this.mutationErrors.delete(key);
    });
    this.tickets.forEach((state: TicketState, id: number): void => {
      if (state.ticket.deviceId === device) this.tickets.delete(id);
    });
    this.emit();
  }
  onChanged(listener: () => void): () => void { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; }
  private emit(): void { this.listeners.forEach((listener: () => void): void => listener()); }
  private scope(): string { return JSON.stringify([this.owner, this.generation, this.revision]); }
  private epoch(device: string): number { return this.epochs.get(device) ?? 0; }
  private assertOwner(device: string): void {
    if (!this.owner || !device || !this.port.isOwner(device)) throw new Error('MODEL_ROUTING_OWNER_REQUIRED');
  }
  private current(device: string, scope: string, epoch: number): boolean {
    return !!this.owner && this.scope() === scope && this.epoch(device) === epoch && this.port.isOwner(device);
  }
  snapshot(device: string): ModelRoutingSnapshot {
    // Even before the public scope-reset callback arrives, revoked peers cannot expose cached data.
    return this.owner && this.port.isOwner(device) ? this.snapshots.get(device) ?? new ModelRoutingSnapshot() : new ModelRoutingSnapshot();
  }
  load(device: string, force: boolean = false): Promise<ModelRoutingSnapshot> {
    this.assertOwner(device);
    const pending = this.pending.get(device);
    if (pending) return pending;
    const previous = this.snapshots.get(device);
    if (!force && previous && previous.status !== 'loading' && this.now() - previous.readAt <
      (previous.status === 'unsupported' ? 300000 : 15000)) return Promise.resolve(previous);
    const scope = this.scope(), epoch = this.epoch(device);
    const loading = new ModelRoutingSnapshot(); loading.status = 'loading'; loading.catalog = previous?.catalog ?? null;
    this.snapshots.set(device, loading); this.emit();
    const run: Promise<ModelRoutingSnapshot> = this.readCatalog(device, scope, epoch, previous).finally(() => {
      if (this.pending.get(device) === run) this.pending.delete(device);
    });
    this.pending.set(device, run); return run;
  }
  private async readCatalog(device: string, scope: string, epoch: number,
    previous: ModelRoutingSnapshot | undefined): Promise<ModelRoutingSnapshot> {
    const next = new ModelRoutingSnapshot(); next.readAt = this.now();
    try {
      const request: Record<string, Object> = {}; request['includeSourceRoutes'] = true;
      const raw = await this.port.invoke(device, 'model-groups:get', [request]);
      if (raw === null) next.status = 'unsupported';
      else {
        next.catalog = parseModelRoutingCatalog(raw);
        if (!next.catalog) throw new Error('MODEL_ROUTING_INVALID_CATALOG');
        next.status = 'ready';
      }
    } catch (error) {
      next.error = String(error);
      next.status = modelRoutingUnsupported(next.error) ? 'unsupported' : 'error';
      next.catalog = next.status === 'error' ? previous?.catalog ?? null : null;
    }
    if (!this.current(device, scope, epoch)) throw new Error('MODEL_ROUTING_STALE');
    this.snapshots.set(device, next); this.emit(); return next;
  }
  /** Resolve does not commit or mutate a draft. ACP is blocked before any creation/switch call. */
  async prepare(device: string, routeId: string, context: ModelRoutingContext = new ModelRoutingContext()): Promise<ModelRoutingTicket> {
    this.assertOwner(device);
    if (!routeId || routeId.length > 128) throw new Error('MODEL_ROUTING_INVALID_SELECTION');
    const scope = this.scope(), epoch = this.epoch(device);
    const wireContext: Record<string, Object> = {}; wireContext['hasImages'] = context.hasImages;
    if (context.effort) wireContext['effort'] = context.effort;
    if (context.fastMode === true || context.fastMode === 'ultrafast') wireContext['fastMode'] = context.fastMode;
    const request: Record<string, Object> = {};
    request['selection'] = selectionWire(routeId); request['context'] = wireContext;
    if (context.sshHostId) request['sshHostId'] = context.sshHostId;
    if (context.agentDeviceId !== undefined) {
      const location = new ModelRoutingLocation(); location.agentDeviceId = context.agentDeviceId; request['location'] = location;
    }
    const result = parseModelRoutingResult(await this.port.invoke(device, 'model-groups:resolve', [request]));
    if (!this.current(device, scope, epoch)) throw new Error('MODEL_ROUTING_STALE');
    if (!result) throw new Error('MODEL_ROUTING_INVALID_RESULT');
    if (result.route?.agentKind === 'acp') throw new Error('MODEL_ROUTING_ENGINE_UNSUPPORTED');
    if (result.route && context.agentDeviceId !== undefined && (result.route.agentDeviceId || null) !== context.agentDeviceId) {
      throw new Error('MODEL_ROUTING_LOCATION_MISMATCH');
    }
    if (this.tickets.size >= 128) throw new Error('MODEL_ROUTING_TOO_MANY_PENDING');
    const ticket = new ModelRoutingTicket(); ticket.id = ++this.nextId; ticket.deviceId = device;
    ticket.routeId = routeId; ticket.result = result;
    const state = new TicketState(); state.ticket = ticket; state.scope = scope; state.epoch = epoch;
    this.tickets.set(ticket.id, state); return ticket;
  }
  private ticket(ticket: ModelRoutingTicket): TicketState {
    const state = this.tickets.get(ticket.id);
    if (!state || state.ticket !== ticket || !this.current(ticket.deviceId, state.scope, state.epoch)) {
      throw new Error('MODEL_ROUTING_STALE');
    }
    return state;
  }
  /** Revalidate immediately before using the resolved route in the existing create/switch pipeline. */
  routeFor(ticket: ModelRoutingTicket): ModelRoute | null { return this.ticket(ticket).ticket.result.route; }
  private session(state: TicketState, sessionId: string): void {
    if (!sessionId || sessionId.length > 256 || (state.sessionId && state.sessionId !== sessionId)) {
      throw new Error('MODEL_ROUTING_SESSION_MISMATCH');
    }
    if (!state.sessionId) {
      const key = this.sessionKey(state.ticket.deviceId, sessionId);
      state.writeVersion = (this.writeVersions.get(key) ?? 0) + 1;
      this.writeVersions.set(key, state.writeVersion);
    }
    state.sessionId = sessionId;
  }
  /** An accepted input is already delivered. Failed bookkeeping is an independent task status,
   * preserved across binding refreshes; never ask the composer to repeat its input. */
  private projectWriteError(state: TicketState, stage: string): void {
    const device = state.ticket.deviceId, key = this.sessionKey(device, state.sessionId);
    if (!this.current(device, state.scope, state.epoch) || this.writeVersions.get(key) !== state.writeVersion) return;
    const error = stage ? 'MODEL_ROUTING_' + stage.toUpperCase().replace('-', '_') + '_INCOMPLETE' : '';
    if ((this.mutationErrors.get(key) ?? '') === error) return;
    if (error) this.mutationErrors.set(key, error); else this.mutationErrors.delete(key);
    const previous = this.sessions.get(key), snapshot = new ModelRoutingSession();
    snapshot.binding = previous?.binding ?? null; snapshot.offer = previous?.offer ?? null; snapshot.error = error;
    this.sessions.set(key, snapshot); this.emit();
  }
  /** Await before first dispatch so the host's first-round fault recovery knows the route. Never commits. */
  bindBeforeFirstInput(ticket: ModelRoutingTicket, sessionId: string): Promise<void> {
    const state = this.ticket(ticket); this.session(state, sessionId);
    if (state.bound) return Promise.resolve();
    if (state.binding) return state.binding;
    const run: Promise<void> = this.bind(state).finally(() => { state.binding = null; });
    state.binding = run; return run;
  }
  private async bind(state: TicketState): Promise<void> {
    const ticket = state.ticket, route = ticket.result.route;
    if (ticket.result.outcome !== 'routed' || !route) return;
    try {
      await this.port.invoke(ticket.deviceId, 'model-groups:bind-session', [bindingWire(state.sessionId, ticket.routeId, route)]);
      this.ticket(ticket); state.bound = true;
    } catch (error) { this.projectWriteError(state, 'bind');
      if (error instanceof Error) throw error;
      throw new Error('MODEL_ROUTING_BIND_INCOMPLETE'); }
  }
  /** Call only on confirmed first-input acceptance / successful model switch, never on create alone.
   * A failed commit has unknown receipt: repeated calls reuse the same promise, not a new decision. */
  accepted(ticket: ModelRoutingTicket, sessionId: string, note: Record<string, Object> | null = null): Promise<void> {
    const state = this.ticket(ticket); this.session(state, sessionId);
    if (state.accepted) return state.accepted;
    state.accepted = this.finish(state, note); return state.accepted;
  }
  private async finish(state: TicketState, note: Record<string, Object> | null): Promise<void> {
    const ticket = state.ticket; let stage = 'bind';
    try {
      await this.bindBeforeFirstInput(ticket, state.sessionId); this.ticket(ticket);
      if (ticket.result.decisionId) {
        stage = 'commit';
        await this.port.invoke(ticket.deviceId, 'model-groups:commit', [ticket.result.decisionId]);
        this.ticket(ticket);
      }
      if (note) {
        stage = 'route-note';
        const request = sessionWire(state.sessionId); request['note'] = note;
        await this.port.invoke(ticket.deviceId, 'model-groups:route-note', [request]);
        this.ticket(ticket);
      }
      this.projectWriteError(state, '');
    } catch (error) { this.projectWriteError(state, stage);
      if (error instanceof Error) throw error;
      throw new Error('MODEL_ROUTING_FINISH_INCOMPLETE'); }
  }
  cancel(ticket: ModelRoutingTicket): void {
    const state = this.tickets.get(ticket.id);
    if (state?.ticket === ticket && !state.accepted) this.tickets.delete(ticket.id);
  }
  /** Release only after the caller no longer needs duplicate-acceptance protection. */
  release(ticket: ModelRoutingTicket): void {
    if (this.tickets.get(ticket.id)?.ticket === ticket) this.tickets.delete(ticket.id);
  }
  private sessionKey(device: string, sessionId: string): string { return JSON.stringify(device) + ':' + JSON.stringify(sessionId); }
  sessionSnapshot(device: string, sessionId: string): ModelRoutingSession {
    return this.owner && this.port.isOwner(device)
      ? this.sessions.get(this.sessionKey(device, sessionId)) ?? new ModelRoutingSession() : new ModelRoutingSession();
  }
  refreshSession(device: string, sessionId: string, includeOffer: boolean = false): Promise<ModelRoutingSession> {
    this.assertOwner(device);
    if (!sessionId || sessionId.length > 256) throw new Error('MODEL_ROUTING_SESSION_MISMATCH');
    const key = this.sessionKey(device, sessionId), pending = this.sessionPending.get(key);
    if (pending) {
      // A concurrent catalogue-only detail read must not swallow a newly-visible error offer.
      if (includeOffer && !this.sessionOffersPending.has(key)) {
        const scopeAtJoin = this.scope(), epochAtJoin = this.epoch(device);
        return pending.then(() => {
          if (!this.current(device, scopeAtJoin, epochAtJoin)) throw new Error('MODEL_ROUTING_STALE');
          return this.refreshSession(device, sessionId, true);
        });
      }
      return pending;
    }
    const scope = this.scope(), epoch = this.epoch(device), version = this.sessionVersions.get(key) ?? 0;
    const run: Promise<ModelRoutingSession> = this.readSession(device, sessionId, scope, epoch, key, version, includeOffer).finally(() => {
      if (this.sessionPending.get(key) === run) { this.sessionPending.delete(key); this.sessionOffersPending.delete(key); }
    });
    if (includeOffer) this.sessionOffersPending.add(key);
    this.sessionPending.set(key, run); return run;
  }
  private async readSession(device: string, sessionId: string, scope: string, epoch: number, key: string,
    version: number, includeOffer: boolean): Promise<ModelRoutingSession> {
    const state = new ModelRoutingSession();
    try {
      state.binding = parseModelRoutingBinding(await this.port.invoke(device, 'model-groups:get-session-binding', [sessionWire(sessionId)]));
      if (!this.current(device, scope, epoch)) throw new Error('MODEL_ROUTING_STALE');
      if (includeOffer) {
        state.offer = parseModelRoutingOffer(await this.port.invoke(device, 'model-groups:switch-offer', [sessionWire(sessionId)]));
        // Retain a visible failure instead of offering an unsupported fallback action.
        if (state.offer?.route.agentKind === 'acp') { state.offer = null; state.error = 'MODEL_ROUTING_ENGINE_UNSUPPORTED'; }
      }
    } catch (error) { state.error = String(error); }
    if (!this.current(device, scope, epoch) || (this.sessionVersions.get(key) ?? 0) !== version) {
      throw new Error('MODEL_ROUTING_STALE');
    }
    state.error = this.mutationErrors.get(key) || state.error;
    this.sessions.set(key, state); this.emit(); return state;
  }
  /** A switch offer already specifies the host's candidate; do not resolve its group again.
   * Call after the existing model-switch operation succeeds, then invoke the existing retry action.
   * There is no decisionId in this wire response, hence no new-task commit. */
  async bindOfferAfterSwitch(device: string, sessionId: string, offer: ModelRoutingOffer): Promise<void> {
    this.assertOwner(device);
    const key = this.sessionKey(device, sessionId);
    if (this.sessions.get(key)?.offer !== offer) throw new Error('MODEL_ROUTING_STALE');
    if (offer.route.agentKind === 'acp') throw new Error('MODEL_ROUTING_ENGINE_UNSUPPORTED');
    const scope = this.scope(), epoch = this.epoch(device);
    await this.port.invoke(device, 'model-groups:bind-session', [bindingWire(sessionId, offer.routeId, offer.route)]);
    if (!this.current(device, scope, epoch)) throw new Error('MODEL_ROUTING_STALE');
  }
  async unbind(device: string, sessionId: string): Promise<void> {
    this.assertOwner(device);
    if (!sessionId || sessionId.length > 256) throw new Error('MODEL_ROUTING_SESSION_MISMATCH');
    const scope = this.scope(), epoch = this.epoch(device), key = this.sessionKey(device, sessionId);
    this.writeVersions.set(key, (this.writeVersions.get(key) ?? 0) + 1);
    // A read begun before this write must not resurrect the removed binding.
    this.sessionVersions.set(key, (this.sessionVersions.get(key) ?? 0) + 1); this.sessionPending.delete(key); this.sessionOffersPending.delete(key);
    const response = await this.port.invoke(device, 'model-groups:unbind-session', [sessionWire(sessionId)]);
    if (recordOrEmpty(response)['unbound'] !== true) throw new Error('MODEL_ROUTING_NOT_UNBOUND');
    if (!this.current(device, scope, epoch)) throw new Error('MODEL_ROUTING_STALE');
    this.sessionVersions.set(key, (this.sessionVersions.get(key) ?? 0) + 1); this.sessionPending.delete(key); this.sessionOffersPending.delete(key);
    this.mutationErrors.delete(key);
    this.sessions.set(key, new ModelRoutingSession()); this.emit();
  }
}
