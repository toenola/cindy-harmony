import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export class WorkdirPreferences {
  private writes: Promise<void> = Promise.resolve();

  async restoreShowIgnored(context: common.Context): Promise<boolean> {
    await this.writes;
    const pref = await preferences.getPreferences(context, { name: 'cindy_workdir_view_preferences' });
    return await pref.get('showIgnoredDirs', false) === true;
  }

  saveShowIgnored(context: common.Context, value: boolean): void {
    this.writes = this.writes.then(async (): Promise<void> => {
      const pref = await preferences.getPreferences(context, { name: 'cindy_workdir_view_preferences' });
      if (value) await pref.put('showIgnoredDirs', true);
      else await pref.delete('showIgnoredDirs');
      await pref.flush();
    }).catch((): void => {});
  }

  private key(owner: string, device: string, workdir: string): string {
    const bytes = util.TextEncoder.create('utf-8').encodeInto(JSON.stringify([owner, device, workdir]));
    const hash = cryptoFramework.createMd('SHA256');
    hash.updateSync({ data: bytes });
    return new util.Base64Helper().encodeToStringSync(hash.digestSync().data);
  }

  async restore(context: common.Context, owner: string, device: string, workdir: string): Promise<string> {
    await this.writes;
    const pref = await preferences.getPreferences(context, { name: 'cindy_workdir_view_preferences' });
    const value = await pref.get(this.key(owner, device, workdir), '');
    return typeof value === 'string' ? value : '';
  }

  save(context: common.Context, owner: string, device: string, workdir: string,
    value: string, current: () => boolean): void {
    this.writes = this.writes.then(async (): Promise<void> => {
      if (!current()) return;
      const pref = await preferences.getPreferences(context, { name: 'cindy_workdir_view_preferences' });
      if (!current()) return;
      await pref.put(this.key(owner, device, workdir), value);
      await pref.flush();
    }).catch((): void => {});
  }
}

export const workdirPreferences: WorkdirPreferences = new WorkdirPreferences();
