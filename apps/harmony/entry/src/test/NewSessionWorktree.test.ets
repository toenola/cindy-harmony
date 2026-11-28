import { describe, expect, it } from '@ohos/hypium';
import { NewSessionWorktreeInvoke, WorktreeReservation, cancelWorktreeReservation,
  parseWorktreeTarget, requestWorktreePath, worktreeCreateOptions } from '../main/ets/core/tasks/NewSessionWorktree';

export default function newSessionWorktreeTests(): void {
  describe('newSessionWorktree', (): void => {
    // Unit: production wire projection, absent from ordinary creation tests.
    // Minimal gap: a precreated path must not replace the original project or leak into dialogue.
    it('projects a confirmed worktree path only for project creation', 0, (): void => {
      const options: Record<string, Object> = {};
      options['workspaceKind'] = 'project';
      options['workingDir'] = '/repo/sub';
      options['id'] = 'session';
      expect(worktreeCreateOptions(options, '') === options).assertTrue();
      const next = worktreeCreateOptions(options, '/managed/task');
      expect(next['id']).assertEqual('session');
      expect(next['projectDir']).assertEqual('/repo/sub');
      expect(next['workingDir']).assertEqual('/managed/task');
      options['workspaceKind'] = 'dialogue';
      expect(worktreeCreateOptions(options, '/managed/task') === options).assertTrue();
    });

    // Unit: host capability guard. Minimum old-host failure is the missing cleanup capability bit.
    it('never enables precreation for non-Git or a host without keyed cleanup', 0, (): void => {
      const row: Record<string, Object> = {};
      row['isGitRepo'] = true;
      row['gitInstalled'] = true;
      row['isInsideWorktree'] = false;
      row['repoRoot'] = '/repo';
      expect(parseWorktreeTarget(row).supported).assertFalse();
      row['supportsRecoveryKeyDiscard'] = true;
      expect(parseWorktreeTarget(row).supported).assertTrue();
      row['isGitRepo'] = false;
      expect(parseWorktreeTarget(row).supported).assertFalse();
    });

    // Unit: host reply validation and keyed cleanup contract. A mismatched key must not produce a usable path.
    it('rejects mismatched create receipts and requires explicit keyed cancellation', 0, async (): Promise<void> => {
      const record: WorktreeReservation = {
        sessionId: 's1', recoveryKey: 'r1', name: 'auto-a', sourceBranch: 'HEAD', baseRepo: '/repo',
      };
      const channels: string[] = [];
      const invoke: NewSessionWorktreeInvoke = async (channel, args): Promise<Object | undefined> => {
        channels.push(channel);
        const result: Record<string, Object> = {};
        if (channel === 'worktree:create') {
          const meta: Record<string, Object> = {};
          meta['sessionId'] = 's1';
          meta['baseRepo'] = '/repo';
          meta['sourceBranch'] = 'HEAD';
          meta['recoveryKey'] = 'mismatch';
          meta['path'] = '/managed/task';
          result['ok'] = true;
          result['meta'] = meta;
        } else {
          expect((args[0] as Record<string, Object>)['recoveryKey']).assertEqual('r1');
          result['discarded'] = true;
        }
        return result;
      };
      let rejected = false;
      try { await requestWorktreePath(invoke, record); } catch (_) { rejected = true; }
      expect(rejected).assertTrue();
      await cancelWorktreeReservation(invoke, record, false);
      expect(channels.join(',')).assertEqual('worktree:create,worktree:cancel-precreated');
    });
  });
}
