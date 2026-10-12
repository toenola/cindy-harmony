import { describe, expect, it } from '@ohos/hypium';
import { DlClient, DlClientOptions, DlError, DlInvokeOptions } from '../main/ets/core/device-link/DlClient';
import { Envelope } from '../main/ets/core/device-link/DlProtocol';
import { MessageStore } from '../main/ets/core/messages/MessageStore';
import { RemoteMessage } from '../main/ets/core/tasks/TaskModels';

class DeletionDeferred {
  promise: Promise<Envelope>;
  resolve: (value: Envelope) => void = (_value: Envelope): void => {};
  reject: (error: Error) => void = (_error: Error): void => {};
  constructor() {
    this.promise = new Promise<Envelope>((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
  }
}

class DeletionOutcome {
  deleted: string[] = [];
  error: Error | undefined = undefined;
}

class QueuedDeletion {
  options: DlInvokeOptions;
  reply: DeletionDeferred;
  constructor(options: DlInvokeOptions, reply: DeletionDeferred) {
    this.options = options;
    this.reply = reply;
  }
}

function deletionSuccess(result: Object): Envelope {
  const payload: Record<string, Object> = {};
  payload['ok'] = true;
  payload['result'] = result;
  const envelope = new Envelope();
  envelope.payload = payload;
  return envelope;
}

function deletionSessionRunning(): Envelope {
  const error: Record<string, Object> = {};
  error['code'] = 'SESSION_RUNNING';
  error['message'] = 'Host session is running';
  const payload: Record<string, Object> = {};
  payload['ok'] = false;
  payload['error'] = error;
  const envelope = new Envelope();
  envelope.payload = payload;
  return envelope;
}

function deletionRows(prefix: string): Object[] {
  const rows = JSON.parse('[{"id":"answer-db","clientId":"answer-client","sessionId":"session","role":"assistant",'
    + '"content":"answer","createdAt":"2026-10-12T01:00:00Z"},'
    + '{"id":"child-db","clientId":"child-client","sessionId":"session","role":"thinking",'
    + '"content":"work","createdAt":"2026-10-12T01:00:01Z"},'
    + '{"id":"keep-db","clientId":"keep-client","sessionId":"session","role":"user",'
    + '"content":"keep","createdAt":"2026-10-12T01:00:02Z"},'
    + '{"id":"other-db","clientId":"other-client","sessionId":"session","role":"assistant",'
    + '"content":"other","createdAt":"2026-10-12T01:00:03Z"}]') as Record<string, Object>[];
  for (const row of rows) row['content'] = prefix + ' ' + String(row['content']);
  return rows;
}

function deletionReceipt(): Object {
  const result: Record<string, Object> = {};
  const clientIds: string[] = ['answer-client', 'child-client'];
  result['clientIds'] = clientIds;
  return result;
}

class DeletionMockDlClient extends DlClient {
  epoch: number = 1;
  messages: Object[] = deletionRows('original');
  deleteCalls: DlInvokeOptions[] = [];
  queuedDeletes: QueuedDeletion[] = [];
  actualDeleteWrites: number = 0;
  queueDeletes: boolean = false;
  rejectRunning: boolean = false;
  sentReply: DeletionDeferred | undefined = undefined;
  constructor() { super(new DlClientOptions()); }
  connectionIdentity(_deviceId: string): string { return String(this.epoch); }
  supportsHistoryView(_deviceId: string): boolean { return false; }
  async subscribe(_deviceId: string, _topics: string[], _timeout: number = 0): Promise<Envelope> {
    return deletionSuccess(true);
  }
  async unsubscribe(_deviceId: string, _topics: string[], _timeout: number = 0): Promise<Envelope> {
    return deletionSuccess(true);
  }
  invoke(_deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    if (options.channel === 'local-db:messages:list') return Promise.resolve(deletionSuccess(this.messages));
    if (options.channel !== 'maker:message:delete') return Promise.resolve(deletionSuccess(false));
    this.deleteCalls.push(options);
    if (options.preSend === undefined) return Promise.reject(new Error('Deletion must provide a preSend guard'));
    options.preSend();
    if (this.queueDeletes) {
      const reply = new DeletionDeferred();
      this.queuedDeletes.push(new QueuedDeletion(options, reply));
      return reply.promise;
    }
    this.actualDeleteWrites += 1;
    return this.sentReply?.promise ?? Promise.resolve(this.rejectRunning
      ? deletionSessionRunning() : deletionSuccess(deletionReceipt()));
  }
  flushQueuedDelete(): void {
    const queued = this.queuedDeletes.shift();
    if (queued === undefined) throw new Error('Expected a queued deletion');
    try {
      if (queued.options.preSend === undefined) throw new Error('Queued deletion lost its preSend guard');
      queued.options.preSend();
      this.actualDeleteWrites += 1;
      queued.reply.resolve(deletionSuccess(deletionReceipt()));
    } catch (error) {
      if (error instanceof Error) queued.reply.reject(error);
      else queued.reply.reject(new Error('Unexpected non-Error preSend failure'));
    }
  }
}

async function captureDeletion(promise: Promise<string[]>): Promise<DeletionOutcome> {
  const outcome = new DeletionOutcome();
  try { outcome.deleted = await promise; }
  catch (error) {
    if (error instanceof Error) outcome.error = error;
    else outcome.error = new Error('Unexpected non-Error deletion failure');
  }
  return outcome;
}

async function settleDeletionFixture(): Promise<void> {
  for (let attempt = 0; attempt < 40; attempt++) await Promise.resolve();
}

async function openDeletionFixture(store: MessageStore, client: DeletionMockDlClient): Promise<void> {
  store.attach(client);
  store.setCacheAccountScope('account-a');
  expect(await store.openSession('device', 'session')).assertTrue();
  await settleDeletionFixture();
  expect(store.getMessages('session', 'device').length).assertEqual(4);
}

function deletionSnapshot(store: MessageStore): string {
  return JSON.stringify(store.getMessages('session', 'device'));
}

async function changeDeletionScope(change: string, store: MessageStore, client: DeletionMockDlClient): Promise<void> {
  const previousLease = store.historyReadLease('device', 'session');
  client.messages = deletionRows('new window');
  if (change === 'account') {
    store.setCacheAccountScope('account-b');
  } else if (change === 'connection') {
    client.epoch += 1;
  } else if (change === 'close-reopen') {
    await store.closeSession('session', 'device');
    expect(await store.openSession('device', 'session')).assertTrue();
  } else {
    throw new Error('Unknown deletion scope fixture');
  }
  const lease = store.historyReadLease('device', 'session');
  expect(lease.length > 0).assertTrue();
  expect(lease === previousLease).assertFalse();
  if (change !== 'close-reopen') expect(await store.refreshHistoryView('device', 'session', lease)).assertTrue();
  await settleDeletionFixture();
  expect(store.getMessages('session', 'device').length).assertEqual(4);
  expect(store.getMessages('session', 'device').find((row: RemoteMessage) => row.clientId === 'answer-client')?.content)
    .assertEqual('new window answer');
}

export default function v132DeletionTests(): void {
  describe('v132Deletion', () => {
    describe('hostDeletionAuthority', () => {
      it('calls_host_while_local_running_and_deletes_exact_returned_client_ids', 0, async () => {
        const client = new DeletionMockDlClient();
        const store = new MessageStore();
        await openDeletionFixture(store, client);
        const activity: Record<string, Object> = {};
        activity['sessionId'] = 'session';
        activity['phase'] = 'running';
        store.handleSessionActivity(activity, 'device');
        expect(store.isSessionRunning('session', 'device')).assertTrue();
        const retained = store.getMessages('session', 'device').filter((row: RemoteMessage) =>
          row.clientId === 'keep-client' || row.clientId === 'other-client');
        const outcome = await captureDeletion(store.deleteMessage('device', 'session', 'answer-client'));
        expect(outcome.error).assertEqual(undefined);
        expect(JSON.stringify(outcome.deleted)).assertEqual('["answer-client","child-client"]');
        expect(client.deleteCalls.length).assertEqual(1);
        expect(JSON.stringify(client.deleteCalls[0].args)).assertEqual('["session","answer-client"]');
        expect(client.actualDeleteWrites).assertEqual(1);
        expect(JSON.stringify(store.getMessages('session', 'device'))).assertEqual(JSON.stringify(retained));
        expect(store.isSessionRunning('session', 'device')).assertTrue();
        await store.closeSession('session', 'device');
      });
    });
    describe('hostRunningRejection', () => {
      it('throws_session_running_and_preserves_every_original_message', 0, async () => {
        const client = new DeletionMockDlClient();
        client.rejectRunning = true;
        const store = new MessageStore();
        await openDeletionFixture(store, client);
        const before = deletionSnapshot(store);
        const outcome = await captureDeletion(store.deleteMessage('device', 'session', 'answer-client'));
        expect(outcome.error instanceof Error).assertTrue();
        expect(outcome.error?.message).assertEqual('[SESSION_RUNNING] Host session is running');
        expect(outcome.deleted.length).assertEqual(0);
        expect(client.deleteCalls.length).assertEqual(1);
        expect(client.actualDeleteWrites).assertEqual(1);
        expect(deletionSnapshot(store)).assertEqual(before);
        await store.closeSession('session', 'device');
      });
    });
    describe('queuedDeletionScope', () => {
      const changes: string[] = ['account', 'connection', 'close-reopen'];
      for (const change of changes) {
        it('cancels_before_write_after_' + change, 0, async () => {
          const client = new DeletionMockDlClient();
          client.queueDeletes = true;
          const store = new MessageStore();
          await openDeletionFixture(store, client);
          const pending = captureDeletion(store.deleteMessage('device', 'session', 'answer-client'));
          expect(client.deleteCalls.length).assertEqual(1);
          expect(client.queuedDeletes.length).assertEqual(1);
          expect(client.actualDeleteWrites).assertEqual(0);
          await changeDeletionScope(change, store, client);
          const before = deletionSnapshot(store);
          client.flushQueuedDelete();
          const outcome = await pending;
          expect(outcome.error instanceof DlError).assertTrue();
          const error = outcome.error as DlError;
          expect(error.code).assertEqual('CANCELLED');
          expect(error.inFlight).assertFalse();
          expect(outcome.deleted.length).assertEqual(0);
          expect(client.actualDeleteWrites).assertEqual(0);
          expect(client.queuedDeletes.length).assertEqual(0);
          expect(deletionSnapshot(store)).assertEqual(before);
          await store.closeSession('session', 'device');
        });
      }
    });
    describe('sentDeletionScope', () => {
      const changes: string[] = ['account', 'connection', 'close-reopen'];
      for (const change of changes) {
        it('ignores_late_reply_after_' + change, 0, async () => {
          const client = new DeletionMockDlClient();
          const reply = new DeletionDeferred();
          client.sentReply = reply;
          const store = new MessageStore();
          await openDeletionFixture(store, client);
          const pending = captureDeletion(store.deleteMessage('device', 'session', 'answer-client'));
          expect(client.deleteCalls.length).assertEqual(1);
          expect(client.actualDeleteWrites).assertEqual(1);
          await changeDeletionScope(change, store, client);
          const before = deletionSnapshot(store);
          reply.resolve(deletionSuccess(deletionReceipt()));
          const outcome = await pending;
          expect(outcome.error).assertEqual(undefined);
          expect(outcome.deleted.length).assertEqual(0);
          expect(client.deleteCalls.length).assertEqual(1);
          expect(client.actualDeleteWrites).assertEqual(1);
          expect(deletionSnapshot(store)).assertEqual(before);
          await store.closeSession('session', 'device');
        });
      }
    });
  });
}
