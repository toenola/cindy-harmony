import { describe, expect, it } from '@ohos/hypium';
import { ResourceStore } from '../main/ets/core/resources/ResourceStore';
import { recordOrEmpty } from '../main/ets/core/tasks/TaskModels';
import { ResourceRef, parseResourceActions, parseResourceItem, resourceUnread } from '../main/ets/core/resources/ResourceModels';

// Unit tier: actual Store navigation/read/action flows. Protects stale authorization, unsafe
// confirmation parsing and cursor deduplication absent in the task stores. One resource plus
// one late result is the minimum failure input; no sockets or wall-clock waits. Not run by worker.
const ref: ResourceRef = { collectionId: 'notes', kind: 'note', id: 'one' };
function item(id: string = 'one'): Object {
  const value = JSON.parse('{"ref":{"collectionId":"notes","kind":"note","id":"one"},"revision":"1","display":{"title":"one","lastReplyAt":8,"lastReadAt":2},"links":[],"actions":[{"id":"remove","label":"Remove","confirmation":{"title":"Remove?"}}],"blocks":[{"id":"unknown","primitive":"custom-html","fallbackMarkdown":"Safe fallback","data":{"html":"<script/>"}}]}') as Record<string, Object>;
  recordOrEmpty(value['ref'])['id'] = id; recordOrEmpty(value['display'])['title'] = id;
  return value;
}
function list(id: string = 'one', cursor: string = ''): Object {
  const value = JSON.parse('{"collectionId":"notes","revision":"1","items":[],"nextCursor":""}') as Record<string, Object>;
  const items: Object[] = [item(id)]; value['items'] = items; value['nextCursor'] = cursor; return value;
}
export default function resourcesStoreTests(): void {
  describe('ResourcesStore', () => {
    it('paged_list_deduplicates_and_stops_repeated_cursor', 0, async () => {
      let count = 0;
      const store = new ResourceStore(async (_device: string, channel: string): Promise<Object> => {
        if (channel.endsWith(':manifest')) return JSON.parse('{"collections":[]}') as Object;
        count++; return list('one', 'cursor');
      });
      store.configure('a', 'computer', 'en', true); store.selectCollection('notes'); store.setVisible(true);
      await store.refresh(); await store.loadMore();
      expect(store.items.length).assertEqual(1); expect(store.nextCursor).assertEqual(''); expect(count >= 2).assertTrue(); store.dispose();
    });
    it('revocation_discards_inflight_result_and_prevents_actions', 0, async () => {
      let complete: (value: Object) => void = (_value: Object): void => {};
      let writes = 0;
      const store = new ResourceStore((_device: string, channel: string): Promise<Object> => {
        if (channel.endsWith(':invoke')) writes++;
        return new Promise<Object>((resolve) => { complete = resolve; });
      });
      store.configure('a', 'computer', 'en', true); store.selectCollection('notes'); store.setVisible(true);
      const read = store.refresh(); store.revoke(); complete(list()); await read; await store.runAction('remove', true);
      expect(store.items.length).assertEqual(0); expect(store.verified).assertFalse(); expect(writes).assertEqual(0); store.dispose();
    });
    it('confirmation_is_required_before_authorized_action_and_host_effects_refresh', 0, async () => {
      let writes = 0;
      const store = new ResourceStore(async (_device: string, channel: string): Promise<Object> => {
        if (channel.endsWith(':get')) return item();
        if (channel.endsWith(':invoke')) { writes++; return JSON.parse('{"effects":[{"kind":"toast","message":"Removed"}]}') as Object; }
        return list();
      });
      store.configure('a', 'computer', 'en', true); store.selectCollection('notes'); store.setVisible(true); await store.refresh();
      store.selectResource(ref); await store.refresh();
      await store.runAction('remove'); expect(writes).assertEqual(0);
      await store.runAction('remove', true); expect(writes).assertEqual(1); expect(store.notice).assertEqual('Removed'); store.dispose();
    });
    it('malformed_confirmation_and_forms_cannot_turn_into_unconfirmed_actions', 0, () => {
      const actions = parseResourceActions(JSON.parse('[{"id":"bad","label":"Bad","confirmation":{}},{"id":"form","label":"Form","fields":[]}]') as Object, 'en');
      expect(actions[0].supported).assertFalse(); expect(actions[1].supported).assertFalse();
      const parsed = parseResourceItem(item(), 'notes', 'en');
      expect(parsed?.blocks[0].markdown).assertEqual('Safe fallback'); expect(parsed ? resourceUnread(parsed) : false).assertTrue();
    });
    it('host_permission_failure_removes_cached_resource_instead_of_offering_stale_actions', 0, async () => {
      let denied = false;
      const store = new ResourceStore(async (): Promise<Object> => { if (denied) throw new Error('[ACCESS_REVOKED]'); return list(); });
      store.configure('a', 'computer', 'en', true); store.selectCollection('notes'); store.setVisible(true); await store.refresh();
      denied = true; await store.refresh();
      expect(store.items.length).assertEqual(0); expect(store.issue).assertEqual('unavailable'); expect(store.verified).assertFalse(); store.dispose();
    });
    it('change_push_during_action_preserves_effects_without_unlocking_duplicate_write', 0, async () => {
      let finish: (value: Object) => void = (_value: Object): void => {};
      let writes = 0;
      const store = new ResourceStore(async (_device: string, channel: string): Promise<Object> => {
        if (channel.endsWith(':get')) return item();
        if (channel.endsWith(':invoke')) { writes++; return new Promise<Object>((resolve) => { finish = resolve; }); }
        return list();
      });
      store.configure('a', 'computer', 'en', true); store.selectCollection('notes'); store.setVisible(true); await store.refresh();
      store.selectResource(ref); await store.refresh();
      const write = store.runAction('remove', true);
      store.handlePush('computer', 'maker:remote-resources:changed', JSON.parse('{"collectionId":"notes"}') as Object);
      await store.refresh(); await store.runAction('remove', true);
      expect(writes).assertEqual(1);
      finish(JSON.parse('{"effects":[{"kind":"toast","message":"Done"}]}') as Object); await write;
      expect(store.notice).assertEqual('Done'); store.dispose();
    });
  });
}
