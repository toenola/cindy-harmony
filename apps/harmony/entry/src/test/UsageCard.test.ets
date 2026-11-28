import { describe, expect, it } from '@ohos/hypium';
import { UsageSnapshot, UsageSource, UsageDay } from '../main/ets/core/usage/UsageDashboard';
import { UsageCardStore, UsageCardStorage, UsageCardData } from '../main/ets/core/usage-card/UsageCardStore';
// Unit value: real card Store protects owner isolation, per-instance computer scope, snapshot-only
// background refresh and logout publication ordering (v1.3.9 F2). UsageDashboard tests cannot
// exercise persisted native form instances. Minimal inputs: two form IDs/one snapshot or logout
// behind a deferred publish. Memory storage/publisher, no vendor, socket, wall-time waits.
// Runtime measurement pending Lead's serial Hvigor pass.
class CardStorage implements UsageCardStorage {
  json: string = ''; failWrite: boolean = false; read(): string { return this.json; } write(json: string): void { if (this.failWrite) throw new Error('DISK_FAILURE'); this.json = json; }
}
class CardPublisher {
  data: UsageCardData[] = [];
  async publish(_id: string, data: UsageCardData): Promise<void> { this.data.push(data); }
}
function snapshot(): UsageSnapshot {
  const snapshot = new UsageSnapshot(); snapshot.updatedAtMs = 1000; snapshot.moneySymbol = '$';
  const source = new UsageSource(); source.kind = 'subscription'; source.name = 'Subscription'; source.value = '70'; source.unit = '%'; source.fill = 0.7; source.when = 'Tomorrow';
  snapshot.sources = [source]; const day = new UsageDay(); day.tokens = [1000, 2000, 3000]; day.paid = 0.5; snapshot.days = [day]; return snapshot;
}
export default function usageCardTests(): void {
  describe('UsageCard', () => {
    it('real_snapshot_projects_quota_reset_and_today_usage_without_credentials', 0, async () => {
      const publisher = new CardPublisher(), store = new UsageCardStore(new CardStorage(), (id: string, data: UsageCardData): Promise<void> => publisher.publish(id, data), (): number => 2000);
      await store.setOwner('owner', 1); store.register('form'); await store.sync('owner', 1, snapshot(), 'computer', 'My Computer');
      const data = store.data('form'); expect(data.source1).assertEqual('Subscription'); expect(data.value1).assertEqual('70%');
      expect(data.reset1).assertEqual('Tomorrow'); expect(data.tokens).assertEqual('6K'); expect(data.paid).assertEqual('$0.50'); expect(data.stale).assertFalse();
    });
    it('separate_form_scopes_survive_restart_and_unavailable_computer_never_borrows_another', 0, async () => {
      const storage = new CardStorage(), publisher = new CardPublisher();
      const publish = (id: string, data: UsageCardData): Promise<void> => publisher.publish(id, data);
      const store = new UsageCardStore(storage, publish); await store.setOwner('owner', 1); store.register('a', 'a'); store.register('b', 'b');
      await store.sync('owner', 1, snapshot(), 'a', 'Computer A');
      const restored = new UsageCardStore(storage, publish); expect(restored.data('a').deviceName).assertEqual('Computer A');
      expect(restored.data('b').status).assertEqual('unavailable'); expect(restored.target('b', 'owner')).assertEqual('b');
    });
    it('same_owner_restart_resets_generation_fence_without_losing_pinned_computer_or_snapshot', 0, async () => {
      const storage = new CardStorage(), publisher = new CardPublisher();
      const publish = (id: string, data: UsageCardData): Promise<void> => publisher.publish(id, data);
      const first = new UsageCardStore(storage, publish, (): number => 2000);
      await first.setOwner('owner', 99); first.register('pinned', 'computer');
      await first.sync('owner', 99, snapshot(), 'computer', 'My Computer');
      const restarted = new UsageCardStore(storage, publish, (): number => 2000);
      await restarted.setOwner('owner', 1);
      expect(restarted.target('pinned', 'owner')).assertEqual('computer');
      expect(restarted.data('pinned').source1).assertEqual('Subscription');
      let rejected = false;
      try { await first.sync('owner', 99, snapshot(), 'other', 'Old request'); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(restarted.target('pinned', 'owner')).assertEqual('computer');
      await restarted.setOwner('', 2); await restarted.setOwner('owner', 3);
      expect(restarted.target('pinned', 'owner')).assertEqual(''); expect(restarted.data('pinned').source1).assertEqual('');
    });
    it('logout_and_old_owner_sync_cannot_restore_previous_quota', 0, async () => {
      const publisher = new CardPublisher(), store = new UsageCardStore(new CardStorage(), (id: string, data: UsageCardData): Promise<void> => publisher.publish(id, data));
      await store.setOwner('a', 1); store.register('form'); await store.sync('a', 1, snapshot(), 'computer', 'Private Computer');
      await store.setOwner('', 2); let stale = false;
      try { await store.sync('a', 1, snapshot(), 'computer', 'Private Computer'); } catch { stale = true; }
      expect(stale).assertTrue(); expect(store.data('form').status).assertEqual('signed-out'); expect(store.data('form').source1).assertEqual('');
      expect(publisher.data[publisher.data.length - 1].source1).assertEqual(''); expect(store.target('form', 'a') === null).assertTrue();
    });
    it('system_refresh_recomputes_age_from_cache_and_removal_cleans_form_reference', 0, async () => {
      let now = 1000; const publisher = new CardPublisher();
      const store = new UsageCardStore(new CardStorage(), (id: string, data: UsageCardData): Promise<void> => publisher.publish(id, data), (): number => now);
      await store.setOwner('owner', 1); store.register('form'); await store.sync('owner', 1, snapshot(), 'computer', 'Computer');
      now += 16 * 60 * 1000; await store.publishAll(); expect(store.data('form').stale).assertTrue();
      store.remove('form'); expect(store.target('form', 'owner') === null).assertTrue(); expect(store.data('form').source1).assertEqual('');
    });
    it('logout_publication_follows_an_inflight_old_snapshot_and_finishes_blank', 0, async () => {
      const published: UsageCardData[] = []; let resume: () => void = (): void => {};
      const store = new UsageCardStore(new CardStorage(), async (_id: string, data: UsageCardData): Promise<void> => {
        if (data.status === 'snapshot') await new Promise<void>((resolve) => { resume = resolve; });
        published.push(data);
      });
      await store.setOwner('owner', 1); store.register('form');
      const syncing = store.sync('owner', 1, snapshot(), 'computer', 'Private');
      await Promise.resolve(); const logout = store.setOwner('', 2); resume(); await Promise.all([syncing, logout]);
      expect(published[published.length - 1].status).assertEqual('signed-out');
      expect(published[published.length - 1].source1).assertEqual('');
    });
    it('one_unavailable_form_does_not_block_other_forms_or_logout_publication', 0, async () => {
      const published: string[] = [];
      const store = new UsageCardStore(new CardStorage(), async (id: string, data: UsageCardData): Promise<void> => {
        if (id === 'deleted') throw new Error('FORM_REMOVED'); published.push(data.status);
      });
      await store.setOwner('owner', 1); store.register('deleted'); store.register('visible');
      await store.sync('owner', 1, snapshot(), 'computer', 'Computer');
      expect(published[published.length - 1]).assertEqual('snapshot');
      expect(store.failedPublications()[0]).assertEqual('deleted');
      await store.setOwner('', 2); expect(published[published.length - 1]).assertEqual('signed-out');
      expect(store.data('visible').source1).assertEqual('');
    });
    it('owner_ledger_write_failure_is_not_swallowed_as_a_form_publication_error', 0, async () => {
      const storage = new CardStorage(), publisher = new CardPublisher();
      const store = new UsageCardStore(storage, (id: string, data: UsageCardData): Promise<void> => publisher.publish(id, data));
      await store.setOwner('owner', 1); storage.failWrite = true; let failure = '';
      try { await store.setOwner('', 2); } catch (error) { failure = String(error); }
      expect(failure.includes('DISK_FAILURE')).assertTrue();
    });
    // Unit: the real ledger distinguishes widget publications with two forms on one computer.
    it('automatic_snapshot_and_unsupported_do_not_publish_pinned_forms', 0, async () => {
      const publisher = new CardPublisher();
      const store = new UsageCardStore(new CardStorage(),
        (id: string, data: UsageCardData): Promise<void> => publisher.publish(id, data));
      await store.setOwner('owner', 1);
      store.register('auto'); store.register('pinned', 'a');
      await store.sync('owner', 1, snapshot(), 'a', 'A', 'pinned');
      expect(store.automaticDevice('owner', 1)).assertEqual('');
      expect(publisher.data.length).assertEqual(1);
      expect(publisher.data[0].formId).assertEqual('pinned');
      await store.sync('owner', 1, snapshot(), 'a', 'A', 'auto');
      expect(publisher.data.length).assertEqual(2);
      expect(publisher.data[1].formId).assertEqual('auto');
      expect(store.automaticDevice('owner', 1)).assertEqual('a');
      await store.markAutomaticUnsupported('owner', 1, 'a');
      expect(publisher.data.length).assertEqual(3);
      expect(publisher.data[2].status).assertEqual('unsupported');
      expect(store.data('pinned').status).assertEqual('snapshot');
    });
    it('revoked_computer_projection_is_removed_without_affecting_other_form', 0, async () => {
      const publisher = new CardPublisher(), store = new UsageCardStore(new CardStorage(), (id: string, data: UsageCardData): Promise<void> => publisher.publish(id, data));
      await store.setOwner('owner', 1); store.register('a', 'a'); store.register('b', 'b');
      await store.sync('owner', 1, snapshot(), 'a', 'A'); await store.sync('owner', 1, snapshot(), 'b', 'B');
      await store.invalidateDevice('a'); expect(store.data('a').status).assertEqual('unavailable'); expect(store.data('b').deviceName).assertEqual('B');
    });
  });
}
