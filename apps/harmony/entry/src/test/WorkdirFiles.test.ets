import { localModelDependencies } from '../main/ets/core/files/WorkdirModel';
import { describe, expect, it } from '@ohos/hypium';
import { WorkdirReadFence, WorkdirWatchDebounce, WorkdirWatchListener, workdirParent,
  workdirListRequest, workdirRelative } from '../main/ets/core/files/WorkdirFiles';

/**
 * Unit, no real clock or peer. Exercises the production path/navigation, reply,
 * and watch guards. Existing task subscription coverage doesn't drive workdir
 * paths or two devices watching the same directory name. Minimal failures are
 * traversal across a sibling prefix, one old directory reply, or two watch events
 * with a stale account/peer. See decision-log “鸿蒙工作目录浏览入口与同步”.
 */
export default function workdirFilesTests(): void {
  describe('WorkdirFiles', (): void => {
    // Unit. The production request builder must not accidentally reveal ignored
    // directories for default/old-host views. Existing scope tests do not exercise
    // the capability gate; the minimal input is one root, path and preference.
    it('adds the reveal flag only for an enabled preference on a supporting host', 0, (): void => {
      expect(workdirListRequest('/repo', 'apps', true, true).showIgnoredDirs === true).assertTrue();
      expect(workdirListRequest('/repo', 'apps', false, true).showIgnoredDirs === undefined).assertTrue();
      expect(workdirListRequest('/repo', 'apps', true, false).showIgnoredDirs === undefined).assertTrue();
      expect(workdirListRequest('/repo', 'apps', true, undefined).showIgnoredDirs === undefined).assertTrue();
    });
    it('navigates logical parents without accepting sibling or escaping paths', 0, (): void => {
      const relative = workdirRelative('/project', '/project/docs/specs/');
      expect(relative).assertEqual('docs/specs');
      expect(workdirParent(relative ?? '')).assertEqual('docs');
      expect(workdirParent('docs')).assertEqual('');
      expect(workdirRelative('/project', '/project-old/docs') === null).assertTrue();
      expect(workdirRelative('/project', '/project/docs/../../secret') === null).assertTrue();
    });
    it('rejects a late reply after navigation or ownership change', 0, (): void => {
      let path = 'docs';
      let owned = true;
      const fence = new WorkdirReadFence();
      const first = fence.capture(path, (): string => path, (): boolean => owned);
      path = 'notes';
      expect(first()).assertFalse();
      const second = fence.capture(path, (): string => path, (): boolean => owned);
      expect(second()).assertTrue();
      owned = false;
      expect(second()).assertFalse();
    });
    it('coalesces changes and cancels stale watch work without real timers', 0, (): void => {
      let updates = 0;
      const debounce = new WorkdirWatchDebounce();
      const first = debounce.next((): boolean => true, (): void => { ++updates; });
      const last = debounce.next((): boolean => true, (): void => { ++updates; });
      first();
      last();
      const stopped = debounce.next((): boolean => true, (): void => { ++updates; });
      debounce.cancel();
      stopped();
      expect(updates).assertEqual(1);
    });
    it('rejects external model dependencies before reaching the native renderer', 0, (): void => {
      const safe = JSON.parse('{"buffers":[{"uri":"scene.bin"}],"images":[{"uri":"color.png"}]}') as Object;
      expect(localModelDependencies(safe).join(',')).assertContain('color.png');
      let refused = false;
      try {
        localModelDependencies(JSON.parse('{"images":[{"uri":"../other.png"}]}') as Object);
      } catch (_error) { refused = true; }
      expect(refused).assertTrue();
    });
    it('keeps same-named directories on different peers isolated', 0, (): void => {
      let a = 0;
      let b = 0;
      const first = new WorkdirWatchListener('A', '/work', (): void => { ++a; }, (): boolean => false);
      const second = new WorkdirWatchListener('B', '/work', (): void => { ++b; }, (): boolean => true);
      first.dispatch('A', '/work');
      second.dispatch('A', '/work');
      second.dispatch('B', '/work-elsewhere');
      second.dispatch('B', '/work');
      expect(a).assertEqual(0);
      expect(b).assertEqual(1);
    });
  });
}
