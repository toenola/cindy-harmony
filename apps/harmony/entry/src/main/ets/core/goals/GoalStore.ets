/**
 * 目标模式 Store：拉取快照、处理 session topic 推送并转发真实 Device Link RPC。
 */

import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { readStr } from '../tasks/TaskModels';
import { unwrapInvokeResult } from '../tasks/TaskStore';
import { GoalModeState, parseGoalModeState } from './GoalModels';

export class GoalStartOptions {
  maxTurns: number = -1;
  budgetTokens: number = -1;
  noProgressLimit: number = 3;
}

class GoalLimitsPayload {
  maxTurns: number | null = null;
  budgetTokens: number | null = null;
  noProgressLimit: number | null = null;
}

export class GoalStore {
  private client: DlClient | undefined = undefined;
  private linkOpener: ((deviceId: string) => Promise<void>) | undefined = undefined;
  private listeners: Array<() => void> = [];
  private stateBySession: Map<string, GoalModeState | null> = new Map();

  attach(client: DlClient): void {
    this.client = client;
  }

  setLinkOpener(opener: (deviceId: string) => Promise<void>): void {
    this.linkOpener = opener;
  }

  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return () => {
      const index = this.listeners.indexOf(listener);
      if (index >= 0) {
        this.listeners.splice(index, 1);
      }
    };
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }

  getState(sessionId: string): GoalModeState | null {
    return this.stateBySession.get(sessionId) ?? null;
  }

  handleStatusChanged(payload: Object | undefined): void {
    if (payload === undefined || payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
      return;
    }
    const record = payload as Record<string, Object>;
    const sessionId = readStr(record, 'sessionId');
    if (sessionId.length === 0) {
      return;
    }
    this.stateBySession.set(sessionId, parseGoalModeState(record['goal']));
    this.notify();
  }

  async refresh(deviceId: string, sessionId: string): Promise<boolean> {
    try {
      const result = await this.invoke(deviceId, 'maker:goal:get-status', [sessionId]);
      this.stateBySession.set(sessionId, parseGoalModeState(result));
      this.notify();
      return true;
    } catch (e) {
      // 保留 push 已提供的状态；旧主机或临时断链不把现状错误清空。
      return false;
    }
  }

  async start(
    deviceId: string,
    sessionId: string,
    objective: string,
    limits: GoalStartOptions,
  ): Promise<void> {
    const args: Record<string, Object> = {};
    args['sessionId'] = sessionId;
    args['objective'] = objective;
    if (limits.maxTurns > 0 || limits.budgetTokens > 0 || limits.noProgressLimit !== 3) {
      const limitValues = new GoalLimitsPayload();
      limitValues.maxTurns = limits.maxTurns > 0 ? limits.maxTurns : null;
      limitValues.budgetTokens = limits.budgetTokens > 0 ? limits.budgetTokens : null;
      limitValues.noProgressLimit = limits.noProgressLimit > 0 ? limits.noProgressLimit : null;
      args['limits'] = limitValues;
    }
    await this.invoke(deviceId, 'maker:goal:set', [args]);
    await this.refresh(deviceId, sessionId);
  }

  async clear(deviceId: string, sessionId: string): Promise<void> {
    await this.invoke(deviceId, 'maker:goal:clear', [sessionId]);
    this.stateBySession.set(sessionId, null);
    this.notify();
  }

  async pause(deviceId: string, sessionId: string): Promise<void> {
    await this.invoke(deviceId, 'maker:goal:pause', [sessionId]);
    await this.refresh(deviceId, sessionId);
  }

  async resume(deviceId: string, sessionId: string): Promise<void> {
    await this.invoke(deviceId, 'maker:goal:resume', [sessionId]);
    await this.refresh(deviceId, sessionId);
  }

  private async invoke(deviceId: string, channel: string, args: Object[]): Promise<Object | undefined> {
    const client = this.client;
    if (client === undefined) {
      throw new Error('Device Link 未初始化');
    }
    if (this.linkOpener !== undefined) {
      await this.linkOpener(deviceId);
    }
    const options = new DlInvokeOptions();
    options.channel = channel;
    options.args = args;
    const envelope = await client.invoke(deviceId, options);
    return unwrapInvokeResult(envelope);
  }
}
