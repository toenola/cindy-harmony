import { describe, expect, it } from '@ohos/hypium';
import { ProjectStore, PROJECT_INFO_GET, PROJECT_INFO_SET, projectLocation, projectIdentity } from '../main/ets/core/projects/ProjectStore';
import { recordOrEmpty } from '../main/ets/core/tasks/TaskModels';

// Unit tier: real ProjectStore entry points, not source-string assertions. Minimal fixture is
// one host snapshot plus one write. Existing alias tests do not cover owner stamps, host versions,
// uncertain clone receipts or account races. No I/O or real-time waits; budget <5s, not run by worker.
function snapshot(version: number = 7): Object {
  const value = JSON.parse('{"aliases":[],"platform":"linux","settingsSupported":true,"settingsVersion":7,"creationRoot":"/projects","ownerStamp":{"dataOwnerId":"host-account","ownerGeneration":8},"directories":{"local:/projects/one":[{"path":"/readonly","access":"read"}]}}') as Record<string, Object>;
  value['settingsVersion'] = version;
  return value;
}
export default function projectsStoreTests(): void {
  describe('ProjectsStore', () => {
    it('forwards_host_owner_and_uses_allocated_directory_without_granting_mobile_paths', 0, async () => {
      let write: Record<string, Object> = {};
      const store = new ProjectStore(async (_device: string, channel: string, args: Object[]): Promise<Object> => {
        if (channel === PROJECT_INFO_GET) return snapshot();
        write = recordOrEmpty(args[0]);
        return JSON.parse('{"createdProjectKey":"local:/projects/one-2"}') as Object;
      });
      store.configure('account:1:route:1', 'computer-a', true); store.setVisible(true); await store.refresh();
      const saved = await store.save('local:', { name: 'one' }, true, 'https://github.com/org/one');
      expect(saved).assertTrue(); expect(write['dataOwnerId']).assertEqual('host-account');
      expect(write['ownerGeneration']).assertEqual(8); expect(store.createdProjectKey).assertEqual('local:/projects/one-2');
      store.dispose();
    });
    it('v6_rejects_clone_and_automatic_location_without_sending_write', 0, async () => {
      let writes = 0;
      const store = new ProjectStore(async (_device: string, channel: string): Promise<Object> => {
        if (channel === PROJECT_INFO_SET) writes++;
        return snapshot(6);
      });
      store.configure('a', 'computer', true); store.setVisible(true); await store.refresh();
      expect(await store.save('local:', { name: 'one' }, true)).assertFalse();
      expect(await store.save('local:/chosen', {}, true, 'git@example:org/repo')).assertFalse();
      expect(writes).assertEqual(0); expect(store.issue).assertEqual('unsupported'); store.dispose();
    });
    it('unknown_clone_result_survives_readback_and_never_replays_write', 0, async () => {
      let writes = 0;
      const store = new ProjectStore(async (_device: string, channel: string): Promise<Object> => {
        if (channel === PROJECT_INFO_SET) { writes++; throw new Error('response lost'); }
        return snapshot();
      });
      store.configure('a', 'computer', true); store.setVisible(true); await store.refresh();
      await store.save('local:', { name: 'one' }, true, 'https://github.com/org/one');
      await store.refresh(); await store.save('local:', { name: 'one' }, true);
      expect(store.uncertain).assertTrue(); expect(writes).assertEqual(1);
      expect(store.pendingRepository).assertEqual('https://github.com/org/one'); store.dispose();
    });
    it('late_previous_account_read_cannot_restore_snapshot', 0, async () => {
      let complete: (value: Object) => void = (_value: Object): void => {};
      const store = new ProjectStore((_device: string, _channel: string): Promise<Object> => new Promise<Object>((resolve) => { complete = resolve; }));
      store.configure('account-a', 'computer', true); store.setVisible(true);
      const read = store.refresh(); store.configure('account-b', 'computer', false);
      complete(snapshot()); await read;
      expect(store.snapshot === null).assertTrue(); expect(store.createdProjectKey).assertEqual(''); store.dispose();
    });
    it('ssh_and_same_named_projects_retain_physical_computer_identity_and_readonly_access', 0, async () => {
      const store = new ProjectStore(async (): Promise<Object> => snapshot());
      store.configure('a', 'computer', true); store.setVisible(true); await store.refresh();
      expect(store.snapshot?.directories['local:/projects/one'][0].access).assertEqual('read');
      expect(projectLocation('computer', 'remote:ssh%3Aone:/srv/project')?.remoteHostId).assertEqual('ssh:one');
      expect(projectIdentity('one', 'local:/p') === projectIdentity('two', 'local:/p')).assertFalse(); store.dispose();
    });
    it('automatic_icon_requests_merge_and_keep_host_source_without_exposing_files', 0, async () => {
      let reads = 0;
      let finish: (value: Object) => void = (_value: Object): void => {};
      const store = new ProjectStore(async (_device: string, channel: string): Promise<Object> => {
        if (channel === PROJECT_INFO_GET) return snapshot();
        reads++; return new Promise<Object>((resolve) => { finish = resolve; });
      });
      store.configure('a', 'computer', true); store.setVisible(true); await store.refresh();
      const first = store.automaticIcon('local:/projects/one'), second = store.automaticIcon('local:/projects/one');
      finish(JSON.parse('{"image":null,"source":"README","kind":"none","candidate":false}') as Object);
      expect((await first)?.source).assertEqual('README'); expect((await second)?.image).assertEqual('');
      expect(reads).assertEqual(1); store.dispose();
    });
  });
}
