import { describe, expect, it } from '@ohos/hypium';
import { IncomingShareStorage, IncomingShareStaging, IncomingShareFile, IncomingShareItem, IncomingShareStore,
  IncomingShareDestination, IncomingShareDraftPort } from '../main/ets/core/incoming-share/IncomingShareStore';
// Unit value: real durable-inbox API preserves duplicate receipt identity, account ownership,
// attachment order and failed adoption; plan v1.3.9 F1. Existing attachments tests do not exercise
// external ingress. Minimal inputs: one native receipt, two ordered files or a failed draft claim.
// Tier unit: memory ports only, no native file/WS/timers. Runtime: Lead serial Hvigor pending.
class ShareStorage implements IncomingShareStorage {
  json: string = '';
  async read(): Promise<string> { return this.json; }
  async write(json: string): Promise<void> { this.json = json; }
}
class ShareStaging implements IncomingShareStaging {
  staged: string[] = []; removed: string[] = [];
  async stage(uri: string, name: string, mime: string): Promise<IncomingShareFile> {
    this.staged.push(uri); const file = new IncomingShareFile(); file.uri = 'owned:' + uri; file.name = name; file.mime = mime; file.size = 1; return file;
  }
  async remove(uri: string): Promise<void> { this.removed.push(uri); }
}
class ShareDraft implements IncomingShareDraftPort {
  ids: string[] = []; text: string = ''; files: IncomingShareFile[] = []; success: boolean = true; owner: string = '';
  async adopt(id: string, destination: IncomingShareDestination, text: string, files: IncomingShareFile[]): Promise<boolean> {
    if (!this.success) return false;
    this.owner = destination.ownerKey;
    if (!this.ids.includes(id)) { this.ids.push(id); this.text = text; this.files = files; } return true;
  }
}
function shareText(text: string): IncomingShareItem { const item = new IncomingShareItem(); item.kind = 'text'; item.text = text; return item; }
function shareFile(uri: string): IncomingShareItem { const item = new IncomingShareItem(); item.kind = 'file'; item.uri = uri; item.name = uri; return item; }
export default function incomingShareTests(): void {
  describe('IncomingShare', () => {
    it('prelogin_inbox_survives_restart_and_first_login_without_sending', 0, async () => {
      const storage = new ShareStorage(), staging = new ShareStaging();
      const cold = new IncomingShareStore(storage, staging); await cold.receive('batch', 'native-event', [shareText('hello')]);
      expect(cold.pending() === null).assertTrue();
      const restored = new IncomingShareStore(storage, staging); await restored.setOwner('owner');
      expect(restored.pending()?.items[0].text).assertEqual('hello');
    });
    it('duplicate_callbacks_are_coalesced_before_copy_and_after_adoption', 0, async () => {
      const staging = new ShareStaging(), store = new IncomingShareStore(new ShareStorage(), staging);
      await store.setOwner('owner'); await Promise.all([store.receive('one', 'receipt', [shareFile('a')]), store.receive('two', 'receipt', [shareFile('a')])]);
      expect(staging.staged.length).assertEqual(1);
      const destination = new IncomingShareDestination(); destination.deviceId = 'computer'; const draft = new ShareDraft();
      await store.adopt('one', destination, draft); await store.receive('three', 'receipt', [shareFile('a')]);
      expect(store.pending() === null).assertTrue(); expect(draft.ids.length).assertEqual(1); expect(staging.staged.length).assertEqual(1);
      expect(staging.removed.length).assertEqual(1); expect(draft.owner).assertEqual('owner');
    });
    it('draft_failure_keeps_all_content_and_order_for_explicit_retry', 0, async () => {
      const store = new IncomingShareStore(new ShareStorage(), new ShareStaging()); await store.setOwner('owner');
      await store.receive('batch', 'receipt', [shareText('first'), shareFile('b'), shareText('last'), shareFile('a')]);
      const target = new IncomingShareDestination(); target.deviceId = 'computer'; const draft = new ShareDraft(); draft.success = false;
      let failed = false; try { await store.adopt('batch', target, draft); } catch { failed = true; }
      expect(failed).assertTrue(); expect(store.pending()?.items.length).assertEqual(4);
      draft.success = true; await store.adopt('batch', target, draft);
      expect(draft.text).assertEqual('first\n\nlast'); expect(draft.files[0].name).assertEqual('b'); expect(draft.files[1].name).assertEqual('a');
    });
    it('account_switch_discards_only_unclaimed_old_account_files', 0, async () => {
      const staging = new ShareStaging(), store = new IncomingShareStore(new ShareStorage(), staging);
      await store.setOwner('a'); await store.receive('batch', 'receipt', [shareFile('private')]); await store.setOwner('b');
      expect(store.pending() === null).assertTrue(); expect(staging.removed[0]).assertEqual('owned:private');
    });
    it('cancel_and_expiration_release_owned_files_without_repeating_native_receipt', 0, async () => {
      const staging = new ShareStaging(), store = new IncomingShareStore(new ShareStorage(), staging); await store.setOwner('owner');
      await store.receive('cancel', 'cancel-receipt', [shareFile('a')], 1); await store.cancel('cancel');
      await store.receive('again', 'cancel-receipt', [shareFile('a')], 2); expect(store.pending() === null).assertTrue();
      await store.receive('expire', 'expire-receipt', [shareFile('b')], 1); await store.expire(86400002);
      expect(store.pending() === null).assertTrue(); expect(staging.removed.length).assertEqual(2);
    });
  });
}
