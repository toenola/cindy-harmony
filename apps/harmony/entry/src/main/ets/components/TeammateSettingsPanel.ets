import { harmonyV12String } from '../core/HarmonyStrings';
import { AppServices } from '../core/AppServices';
import { TeammateSettingForm } from '../core/tasks/TeammateRoster';
import { readStr } from '../core/tasks/TaskModels';
import { UI_RADIUS_CONTROL, uiFontSize } from './UiKit';

@Component
export struct TeammateSettingsPanel {
  @Prop deviceId: string = '';
  @Prop sessionId: string = '';
  @Prop deviceDisabled: boolean = false;
  @State private page: string = '';
  @State private forms: Map<string, TeammateSettingForm> = new Map();
  @State private name: string = '';
  @State private description: string = '';
  @State private memory: boolean = false;
  @State private followsDefault: boolean = false;
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private saved: boolean = false;
  private loadedTeammateId: string = '';
  private generation: number = 0;
  private epoch: number = -1;

  aboutToAppear(): void {
    this.epoch = AppServices.instance.auth.sessionEpoch;
    void this.load();
  }

  aboutToDisappear(): void {
    this.generation += 1;
  }

  private label(name: string): string {
    return harmonyV12String(this.getUIContext().getHostContext(), name);
  }

  private current(generation: number): boolean {
    return generation === this.generation && this.epoch === AppServices.instance.auth.sessionEpoch;
  }

  private async load(): Promise<void> {
    const generation = ++this.generation;
    const roster = AppServices.instance.teammateRoster;
    this.busy = true;
    this.error = '';
    try {
      const row = roster.findConversation(this.deviceId, this.sessionId);
      if (this.deviceDisabled || row === undefined) throw new Error('Partner unavailable');
      const forms = await roster.settings(row);
      if (!this.current(generation)) return;
      this.loadedTeammateId = row.id;
      this.forms = forms;
      if (forms.size === 0) this.error = this.label('v138_no_settings');
      this.selectPage(forms.has(this.page) ? this.page : '');
    } catch (_error) {
      if (this.current(generation)) this.error = this.label('v138_load_failed');
    } finally {
      if (this.current(generation)) this.busy = false;
    }
  }

  private selectPage(page: string): void {
    this.page = page;
    const values = this.forms.get(page)?.values;
    this.name = readStr(values, 'name');
    this.description = readStr(values, 'description');
    this.memory = values?.['memory'] === true;
    this.followsDefault = values?.['followsDefault'] === true;
  }

  private changes(): Record<string, Object> {
    const input: Record<string, Object> = {};
    const values = this.forms.get(this.page)?.values;
    if (this.page === 'profile') {
      if (this.name.trim() !== readStr(values, 'name')) input['name'] = this.name.trim();
      if (this.description !== readStr(values, 'description')) input['description'] = this.description;
    } else if (this.page === 'memory' && this.memory !== values?.['memory']) {
      input['memory'] = this.memory;
    } else if (this.page === 'models' && this.followsDefault !== values?.['followsDefault']) {
      input['followsDefault'] = this.followsDefault;
    }
    return input;
  }

  private canSave(): boolean {
    return !this.busy && !this.deviceDisabled && !this.error && this.forms.has(this.page)
      && (this.page !== 'profile' || this.name.trim().length > 0) && Object.keys(this.changes()).length > 0;
  }

  private async save(): Promise<void> {
    if (!this.canSave()) return;
    const roster = AppServices.instance.teammateRoster;
    const row = roster.findConversation(this.deviceId, this.sessionId);
    const form = this.forms.get(this.page);
    if (row === undefined || row.id !== this.loadedTeammateId || form === undefined) {
      this.error = this.label('v138_profile_changed');
      return;
    }
    const changes = this.changes();
    const generation = ++this.generation;
    this.busy = true;
    this.saved = false;
    try {
      await roster.saveSettings(row, form.actionId, changes, () => {
        if (!this.current(generation) || this.deviceDisabled
          || roster.findConversation(this.deviceId, this.sessionId)?.id !== row.id) {
          throw new Error('Partner changed');
        }
      });
      if (!this.current(generation)) return;
      this.saved = true;
      if (changes['name'] !== undefined) void AppServices.instance.tasks.loadSession(row.deviceId, row.session.id, 'bot');
      await this.load();
    } catch (_error) {
      if (this.current(generation)) {
        this.error = this.label('v138_save_unconfirmed');
        this.busy = false;
      }
    }
  }

  @Builder
  menuItem(id: string, title: string) {
    if (this.forms.has(id)) {
      Button() {
        Row() {
          Text(title).fontSize(uiFontSize(14)).fontColor($r('app.color.text_primary')).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_secondary')])
        }.width('100%')
      }
      .type(ButtonType.Normal).height(44).width('100%')
      .backgroundColor($r('app.color.bg_chip')).borderRadius(UI_RADIUS_CONTROL)
      .enabled(!this.busy && !this.deviceDisabled && !this.error)
      .onClick(() => { this.saved = false; this.selectPage(id); })
    }
  }

  @Builder
  toggleRow(label: string, checked: boolean, update: (value: boolean) => void) {
    Row({ space: 8 }) {
      Text(label).fontSize(uiFontSize(14)).fontColor($r('app.color.text_primary')).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: checked })
        .accessibilityText(label).enabled(!this.busy && !this.deviceDisabled && !this.error)
        .onChange(update)
    }.width('100%').constraintSize({ minHeight: 44 })
  }

  build() {
    Scroll() {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          if (this.page) {
            Button() {
              SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(16).fontColor([$r('app.color.text_primary')])
            }.type(ButtonType.Circle).width(44).height(44).padding(0).backgroundColor(Color.Transparent)
              .accessibilityText(this.label('v138_settings_back')).enabled(!this.busy)
              .onClick(() => { this.saved = false; this.selectPage(''); })
          }
          Text(this.page === 'profile' ? this.label('v138_profile') : this.page === 'models' ? this.label('v138_models') : this.page === 'memory' ? this.label('v138_memory') : this.label('v138_settings'))
            .fontSize(uiFontSize(16)).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        }.width('100%')
        if (this.page === 'profile') {
          Text(this.label('v138_name')).fontSize(uiFontSize(13)).fontColor($r('app.color.text_secondary'))
          TextInput({ text: this.name }).height(44).maxLength(200).accessibilityText(this.label('v138_teammate_name'))
            .enabled(!this.busy && !this.deviceDisabled && !this.error)
            .onChange((value: string) => { this.name = value; this.saved = false; })
          Text(this.label('v138_description')).fontSize(uiFontSize(13)).fontColor($r('app.color.text_secondary'))
          TextArea({ text: this.description }).constraintSize({ minHeight: 76, maxHeight: 124 }).maxLength(12000)
            .accessibilityText(this.label('v138_teammate_description')).enabled(!this.busy && !this.deviceDisabled && !this.error)
            .onChange((value: string) => { this.description = value; this.saved = false; })
        } else if (this.page === 'memory') {
          this.toggleRow(this.label('v138_memory_enabled'), this.memory, (value: boolean) => { this.memory = value; this.saved = false; })
        } else if (this.page === 'models') {
          this.toggleRow(this.label('v138_follow_model'), this.followsDefault, (value: boolean) => {
            this.followsDefault = value;
            this.saved = false;
          })
          if ((this.forms.get('models')?.summary ?? '').length > 0) {
            Text(this.forms.get('models')?.summary ?? '').fontSize(uiFontSize(13))
              .fontColor($r('app.color.text_secondary')).width('100%')
          }
        } else {
          this.menuItem('profile', this.label('v138_profile'))
          this.menuItem('models', this.label('v138_models'))
          this.menuItem('memory', this.label('v138_memory'))
        }
        if (this.busy) {
          LoadingProgress().width(24).height(24).color($r('app.color.accent')).accessibilityText(this.label('v138_sync_settings'))
        } else if (this.error) {
          Text(this.error).fontSize(uiFontSize(13)).fontColor($r('app.color.text_secondary'))
          Button(this.label('v138_refresh_settings')).height(44).enabled(!this.deviceDisabled).onClick(() => void this.load())
        } else if (this.page) {
          Button(this.saved ? this.label('v138_saved') : this.label('v138_save')).height(44).enabled(this.canSave()).onClick(() => void this.save())
        }
      }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ maxHeight: 460 })
  }
}
