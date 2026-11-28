import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetrics } from '@kit.ArkUI';
import { uiConfirm, uiConfirmCopy } from '../common/UiOverlay';
import { resourceIssueText } from '../../core/resources/ResourceIssueStrings';
import { isExplicitProjectRepositoryAddress, parseProjectRepository, projectCreationFolderName } from '../../core/projects/ProjectCreation';
import { PROJECT_SYMBOL_NAMES } from '../../core/projects/ProjectSymbolPaths';
import { ProjectSymbol } from './ProjectSymbol';
import { ProjectStore, ProjectProfile, ProjectDirectory, ProjectAutomaticIcon, projectLocation } from '../../core/projects/ProjectStore';
import { UI_RADIUS_CONTAINER, UI_RADIUS_CONTROL } from '../UiKit';

// The module forwards onClose unchanged, so its stable callback identifies this owner.
const projectCloseHandlers: Map<() => void, () => void> = new Map();

export function requestProjectSettingsClose(owner: () => void): boolean {
  const close = projectCloseHandlers.get(owner);
  if (close === undefined) return false;
  close();
  return true;
}

export class ProjectLabels {
  name: string = 'Name'; directory: string = 'Project directories'; repository: string = 'Repository';
  local: string = 'Local folder'; computer: string = 'Computer'; save: string = 'Save'; create: string = 'Create project';
  cancel: string = 'Cancel'; refresh: string = 'Check again'; addDirectory: string = 'Add directory'; remove: string = 'Remove';
  main: string = 'Main directory'; icon: string = 'Icon'; reset: string = 'Reset'; upload: string = 'Upload image';
  letters: string = '1–2 letters'; discard: string = 'Discard changes?'; keepEditing: string = 'Keep editing';
  automatic: string = 'Automatic project icon'; checkingIcon: string = 'Looking for project icon'; noIcon: string = 'No project icon found';
  checked: string = 'I checked the result on the computer'; status: (issue: string) => string = (issue: string): string => resourceIssueText(issue, 'en');
}
@Component
export struct ProjectSettingsPanel {
  store: ProjectStore = new ProjectStore(async (): Promise<Object | undefined> => undefined);
  projectKey: string = '';
  deviceName: string = '';
  title: string = '';
  create: boolean = false;
  labels: ProjectLabels = new ProjectLabels();
  // Must browse the selected same-account computer. SSH paths are entered separately.
  onChooseDirectory: (() => Promise<string>) | undefined = undefined;
  // Native picker returns a resized PNG/JPEG/WebP data URL <= 300 KB; cancel returns ''.
  onPickImage: (() => Promise<string>) | undefined = undefined;
  onSaved: (projectKey: string) => void = (): void => {};
  onClose: () => void = (): void => {};
  @State private revision: number = 0;
  @State private initial: string = '';
  @State private settingsVersion: number = 0;
  @State private hasOwnerStamp: boolean = false;
  @State private loadingProfile: boolean = false;
  @State private savingProfile: boolean = false;
  @State private saveUncertain: boolean = false;
  @State private storeIssue: string = '';
  private lastSaveDiagnostic: string = '';
  @State @Watch('logSaveState') private name: string = '';
  @State @Watch('logSaveState') private directory: string = '';
  @State @Watch('logSaveState') private repository: string = '';
  @State @Watch('logSaveState') private repositoryMode: boolean = false;
  @State @Watch('logSaveState') private icon: string | null = null;
  @State private image: string = '';
  @State private letters: string = '';
  @State private symbolsOpen: boolean = false;
  @State private automaticSource: string = '';
  @State private checkingIcon: boolean = false;
  @State private sshDirectory: string = '';
  @State @Watch('logSaveState') private directories: ProjectDirectory[] = [];
  @State private localIssue: string = '';
  @State @Watch('logSaveState') private picking: boolean = false;
  private initialized: boolean = false;
  private ownerIdentity: string = '';
  private alive: boolean = false;
  private closeOwner: (() => void) | null = null;
  private readonly closeHandler: () => void = (): void => this.close();
  private discardPending: boolean = false;
  private unsubscribe: (() => void) | null = null;
  private draft(): string { return JSON.stringify([this.name.trim(), this.directory, this.repository.trim(), this.icon, this.directories]); }
  aboutToAppear(): void {
    this.alive = true;
    this.closeOwner = this.onClose;
    projectCloseHandlers.set(this.onClose, this.closeHandler);
    this.name = this.title;
    this.directory = projectLocation('', this.projectKey)?.directory ?? '';
    this.initial = this.draft();
    this.unsubscribe = this.store.onChanged((): void => { this.syncProfileState(); });
    this.syncProfileState(); this.store.setVisible(true);
  }
  aboutToDisappear(): void {
    this.alive = false;
    const owner = this.closeOwner;
    if (owner !== null && projectCloseHandlers.get(owner) === this.closeHandler) {
      projectCloseHandlers.delete(owner);
    }
    this.closeOwner = null;
    this.unsubscribe?.();
    this.unsubscribe = null;
    this.store.setVisible(false);
  }
  private syncProfileState(): void {
    this.initialize();
    this.loadingProfile = this.store.busy;
    this.savingProfile = this.store.saving;
    this.saveUncertain = this.store.uncertain;
    this.settingsVersion = this.store.snapshot?.settingsVersion ?? 0;
    this.hasOwnerStamp = this.store.snapshot?.ownerStamp != null;
    this.storeIssue = this.store.issue;
    this.revision++;
    this.logSaveState();
  }

  private initialize(): void {
    const identity = this.store.identity();
    if (this.ownerIdentity && this.ownerIdentity !== identity) {
      this.name = ''; this.directory = ''; this.repository = ''; this.icon = null; this.image = ''; this.directories = [];
      this.letters = ''; this.sshDirectory = ''; this.initialized = false; this.ownerIdentity = identity; this.onClose(); return;
    }
    this.ownerIdentity = identity;
    const snapshot = this.store.snapshot;
    if (!snapshot || this.initialized) return;
    this.initialized = true;
    this.name = snapshot.aliases[this.projectKey] ?? this.title;
    this.icon = snapshot.icons[this.projectKey] ?? null;
    this.directories = (snapshot.directories[this.projectKey] ?? []).slice();
    this.initial = this.draft();
    if (this.icon?.startsWith('cindy-media:')) {
      void this.store.iconImage(this.projectKey).then((value: string): void => { if (this.alive && identity === this.store.identity() && this.icon?.startsWith('cindy-media:')) this.image = value; }).catch((): void => {});
    } else if (!this.icon && !this.create && snapshot.settingsVersion >= 4) {
      this.checkingIcon = true;
      void this.store.automaticIcon(this.projectKey).then((value: ProjectAutomaticIcon | null): void => {
        if (!this.alive || identity !== this.store.identity()) return;
        this.checkingIcon = false;
        if (this.icon !== null) return;
        this.image = value?.image ?? ''; this.automaticSource = value?.source ?? '';
      }).catch((): void => { if (this.alive && identity === this.store.identity()) this.checkingIcon = false; });
    }
  }
  private close(): void {
    if (!this.alive || this.store.saving || this.picking || this.discardPending) return;
    if (this.draft() === this.initial) { this.onClose(); return; }
    this.discardPending = true;
    const owner = this.closeOwner;
    void uiConfirm(this.getUIContext(), uiConfirmCopy(this.labels.discard, '', this.labels.cancel, this.labels.keepEditing, true))
      .then((confirmed: boolean): void => {
        if (confirmed && this.alive && owner !== null && projectCloseHandlers.get(owner) === this.closeHandler) this.onClose();
      }).finally((): void => { this.discardPending = false; });
  }
  private async choose(): Promise<void> {
    if (!this.onChooseDirectory || this.picking || this.store.saving) return;
    const identity = this.store.identity();
    this.picking = true;
    try {
      const path = await this.onChooseDirectory();
      if (!this.alive || identity !== this.store.identity() || !path) return;
      if (!this.directory && this.create) {
        this.directory = path;
        if (!this.name.trim()) this.name = path.replace(/\\/g, '/').split('/').filter((part: string): boolean => !!part).pop() ?? '';
      } else if (path !== this.directory && this.directories.length < 10 && !this.directories.some((entry: ProjectDirectory): boolean => entry.path === path)) {
        this.directories = this.directories.concat([{ path, access: 'write' }]);
      }
    } catch { if (this.alive) this.localIssue = 'failed'; }
    finally { if (this.alive) this.picking = false; }
  }
  private async pickImage(): Promise<void> {
    if (!this.onPickImage || this.picking || this.store.saving) return;
    const identity = this.store.identity();
    this.picking = true;
    try {
      const image = await this.onPickImage();
      if (!this.alive || identity !== this.store.identity() || !image) return;
      if (image.length > 300000 || !/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$/.test(image)) { this.localIssue = 'invalid'; return; }
      this.icon = image; this.image = image;
    } catch { if (this.alive) this.localIssue = 'failed'; }
    finally { if (this.alive) this.picking = false; }
  }
  private addSshDirectory(): void {
    const path = this.sshDirectory.trim();
    if (!path.startsWith('/') || path.length > 4096 || path.includes('\0') || this.directories.length >= 10
      || path === this.directory || this.directories.some((entry: ProjectDirectory): boolean => entry.path === path)) {
      this.localIssue = 'invalid'; return;
    }
    // The target SSH host validates physical paths and authorization during save.
    this.directories = this.directories.concat([{ path, access: 'write' }]); this.sshDirectory = ''; this.localIssue = '';
  }
  private async resetIcon(): Promise<void> {
    this.icon = null; this.image = ''; this.automaticSource = '';
    if (this.create || (this.store.snapshot?.settingsVersion ?? 0) < 4) return;
    const identity = this.store.identity(); this.checkingIcon = true;
    try {
      const value = await this.store.automaticIcon(this.projectKey);
      if (!this.alive || identity !== this.store.identity() || this.icon !== null) return;
      this.image = value?.image ?? ''; this.automaticSource = value?.source ?? '';
    } catch { /* The generated identity remains available when host lookup fails. */ }
    finally { if (this.alive && identity === this.store.identity()) this.checkingIcon = false; }
  }
  private async save(): Promise<void> {
    if (!this.canSave()) return;
    const profile: ProjectProfile = { name: this.name.trim(), icon: this.icon };
    if ((this.store.snapshot?.settingsVersion ?? 0) >= 6) profile.directories = this.directories;
    if (this.repositoryMode && !parseProjectRepository(this.repository)) { this.localIssue = 'invalid'; return; }
    const key = this.create ? 'local:' + this.directory : this.projectKey;
    if (await this.store.save(key, profile, this.create, this.repositoryMode ? this.repository : '')) {
      if (this.alive) this.onSaved(this.create ? this.store.createdProjectKey : key);
    }
  }
  private validDraft(): boolean {
    return this.name.trim().length <= 80 && this.directories.length <= 10 &&
      (!this.repositoryMode || parseProjectRepository(this.repository) !== null) &&
      (!this.create || this.settingsVersion >= 7 || !!this.directory.trim());
  }

  private dirty(): boolean {
    return this.initial.length > 0 && this.draft() !== this.initial;
  }

  private canSave(): boolean {
    return this.initialized && this.dirty() && this.validDraft() && this.hasOwnerStamp &&
      !this.savingProfile && !this.saveUncertain && !this.picking &&
      this.settingsVersion >= (this.create ? 6 : 2);
  }

  private logSaveState(): void {
    if (!this.alive) return;
    const state = `${this.canSave()}/${this.dirty()}/${this.validDraft()}/${this.hasOwnerStamp}/` +
      `${this.loadingProfile}/${this.savingProfile}/${this.saveUncertain}/${this.picking}/${this.settingsVersion}`;
    if (this.lastSaveDiagnostic === state) return;
    this.lastSaveDiagnostic = state;
    hilog.info(0x0000, 'CindyProjectSettings',
      'save_gate enabled/dirty/valid/owner_stamp/loading/saving/uncertain/picking/version=%{public}s', state);
  }

  private iconText(): string {
    if (this.icon?.startsWith('text:')) return this.icon.split(':')[1];
    return this.icon?.startsWith('data:') || this.icon?.startsWith('cindy-media:') ? '' : this.icon ?? '';
  }

  @Builder
  sectionDivider() {
    Divider().color($r('app.color.border')).width('100%')
  }

  @Builder
  iconOption(value: string, symbol: boolean, collapse: boolean) {
    Button({ type: ButtonType.Normal }) {
      if (symbol) {
        ProjectSymbol({ name: value })
      } else {
        Text(value).fontSize(20).fontColor($r('app.color.text_primary'))
      }
    }
    .width(44).height(44).padding(0)
    .backgroundColor($r('app.color.bg_chip')).borderRadius(UI_RADIUS_CONTROL)
    .border({
      width: this.icon === (symbol ? 'symbol:' + value : value) ? 2 : 0,
      color: $r('app.color.text_primary'),
    })
    .accessibilityText(value)
    .enabled(!this.store.saving)
    .onClick((): void => {
      this.icon = symbol ? 'symbol:' + value : value;
      this.image = '';
      if (collapse) this.symbolsOpen = false;
    })
  }

  build() {
    Column() {
      if (this.revision >= 0) {
        Row({ space: 6 }) {
          Button(this.labels.cancel, { type: ButtonType.Normal })
            .constraintSize({ minWidth: 44, minHeight: 44, maxWidth: 88 }).padding({ left: 8, right: 8 })
            .backgroundColor(Color.Transparent).fontColor($r('app.color.text_primary')).fontSize(14)
            .enabled(!this.store.saving && !this.picking).onClick((): void => this.close())
          Text(this.create ? this.labels.create : this.title)
            .layoutWeight(1).fontSize(17).fontWeight(FontWeight.Medium).textAlign(TextAlign.Center)
            .fontColor($r('app.color.text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.loadingProfile || this.savingProfile || this.picking) {
            LoadingProgress().width(16).height(16).color($r('app.color.text_secondary'))
          }
          Button(this.create ? this.labels.create : this.labels.save, { type: ButtonType.Normal })
            .constraintSize({ minWidth: 44, minHeight: 44, maxWidth: 112 }).padding({ left: 8, right: 8 })
            .backgroundColor(Color.Transparent).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(this.canSave() ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
            .enabled(this.canSave()).onClick((): void => { void this.save(); })
        }.width('100%').height(56).padding({ left: 8, right: 8 })

        Scroll() {
          Column({ space: 16 }) {
            if (this.storeIssue || this.localIssue ||
              (!this.loadingProfile && this.initialized && (!this.hasOwnerStamp || this.settingsVersion < (this.create ? 6 : 2)))) {
              Text(this.labels.status(this.storeIssue || this.localIssue ||
                (this.settingsVersion < (this.create ? 6 : 2) ? 'unsupported' : 'unavailable')))
                .fontColor($r('app.color.text_secondary')).fontSize(14).width('100%')
            }
            if (this.saveUncertain) {
              Column({ space: 6 }) {
                Text(this.store.pendingProjectKey).fontColor($r('app.color.text_secondary')).fontSize(12)
                  .width('100%').wordBreak(WordBreak.BREAK_ALL)
                Button(this.labels.refresh, { type: ButtonType.Normal }).height(44).width('100%')
                  .backgroundColor($r('app.color.bg_chip')).fontColor($r('app.color.text_primary'))
                  .onClick((): void => { void this.store.refresh(); })
                Button(this.labels.checked, { type: ButtonType.Normal }).constraintSize({ minHeight: 44 }).width('100%')
                  .backgroundColor($r('app.color.bg_chip')).fontColor($r('app.color.text_primary'))
                  .onClick((): void => this.store.acknowledgeCheckedResult())
              }.width('100%').padding(12).backgroundColor($r('app.color.bg_card')).borderRadius(UI_RADIUS_CONTAINER)
            }
            Column({ space: 10 }) {
              Row({ space: 12 }) {
                Text(this.labels.computer).fontSize(14).fontColor($r('app.color.text_primary'))
                Text(this.deviceName).layoutWeight(1).textAlign(TextAlign.End).fontSize(14)
                  .fontColor($r('app.color.text_secondary')).wordBreak(WordBreak.BREAK_ALL)
              }.width('100%').constraintSize({ minHeight: 44 })
              this.sectionDivider()
              Text(this.labels.name).fontColor($r('app.color.text_primary')).fontSize(14)
              TextInput({ text: this.name }).height(44).width('100%').fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_chip')).borderRadius(UI_RADIUS_CONTROL).maxLength(80).enabled(!this.store.saving).onChange((value: string): void => {
                  const repo = this.create && (this.store.snapshot?.settingsVersion ?? 0) >= 7 && isExplicitProjectRepositoryAddress(value) ? parseProjectRepository(value) : null;
                  if (repo) { this.name = repo.name.slice(0, 80); this.repositoryMode = true; this.repository = repo.url; this.directory = ''; this.directories = []; }
                  else this.name = value;
                })
              if (this.create && (this.store.snapshot?.settingsVersion ?? 0) >= 7) {
                Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8) } }) {
                  Button(this.labels.local, { type: ButtonType.Normal }).constraintSize({ minWidth: 44, minHeight: 44 })
                    .backgroundColor($r('app.color.bg_chip')).fontColor($r('app.color.text_primary')).borderRadius(UI_RADIUS_CONTROL).enabled(!this.store.saving).onClick((): void => { this.repositoryMode = false; this.repository = ''; this.directory = ''; this.directories = []; })
                  Button(this.labels.repository, { type: ButtonType.Normal }).constraintSize({ minWidth: 44, minHeight: 44 })
                    .backgroundColor($r('app.color.bg_chip')).fontColor($r('app.color.text_primary')).borderRadius(UI_RADIUS_CONTROL).enabled(!this.store.saving).onClick((): void => { this.repositoryMode = true; this.directory = ''; this.directories = []; })
                }
                if (this.repositoryMode) {
                  TextInput({ text: this.repository, placeholder: this.labels.repository }).height(44).width('100%')
                    .backgroundColor($r('app.color.bg_chip')).fontColor($r('app.color.text_primary')).enabled(!this.store.saving)
                    .onChange((value: string): void => {
                      const previous = parseProjectRepository(this.repository), next = parseProjectRepository(value);
                      this.repository = value;
                      if (next && (!this.name.trim() || this.name === previous?.name)) this.name = next.name.slice(0, 80);
                    })
                }
              }
              this.sectionDivider()
              Text(this.labels.directory).fontColor($r('app.color.text_primary')).fontSize(14)
              Text(this.directory || (this.create && this.store.snapshot?.creationRoot ? this.store.snapshot.creationRoot + '/' + projectCreationFolderName(this.name || parseProjectRepository(this.repository)?.name || 'Project') : '')).fontSize(14).fontColor($r('app.color.text_secondary')).width('100%').wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
              ForEach(this.directories, (entry: ProjectDirectory, index: number) => {
                Row({ space: 8 }) {
                  Text(entry.path).wordBreak(WordBreak.BREAK_ALL).fontSize(14).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                  Button(this.labels.remove, { type: ButtonType.Normal }).constraintSize({ minWidth: 44, minHeight: 44 })
                    .backgroundColor($r('app.color.bg_chip')).fontColor($r('app.color.text_primary')).borderRadius(UI_RADIUS_CONTROL).enabled(!this.store.saving).onClick((): void => { this.directories = this.directories.filter((_entry: ProjectDirectory, position: number): boolean => position !== index); })
                }.width('100%')
              }, (entry: ProjectDirectory): string => entry.path)
              if ((this.store.snapshot?.settingsVersion ?? 0) >= 6 && !this.projectKey.startsWith('remote:')) {
                Button(this.labels.addDirectory, { type: ButtonType.Normal }).constraintSize({ minWidth: 44, minHeight: 44 })
                    .backgroundColor($r('app.color.bg_chip')).fontColor($r('app.color.text_primary')).borderRadius(UI_RADIUS_CONTROL).enabled(!!this.onChooseDirectory && !this.store.saving && !this.picking && this.directories.length < 10).onClick((): void => { void this.choose(); })
              }
              if ((this.store.snapshot?.settingsVersion ?? 0) >= 6 && this.projectKey.startsWith('remote:')) {
                TextInput({ text: this.sshDirectory, placeholder: this.labels.directory }).height(44).width('100%')
                  .backgroundColor($r('app.color.bg_chip')).fontColor($r('app.color.text_primary')).enabled(!this.store.saving)
                  .onChange((value: string): void => { this.sshDirectory = value; })
                Button(this.labels.addDirectory, { type: ButtonType.Normal }).constraintSize({ minWidth: 44, minHeight: 44 })
                    .backgroundColor($r('app.color.bg_chip')).fontColor($r('app.color.text_primary')).borderRadius(UI_RADIUS_CONTROL).enabled(!this.store.saving && this.directories.length < 10)
                  .onClick((): void => this.addSshDirectory())
              }
            }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
              .backgroundColor($r('app.color.bg_card')).borderRadius(UI_RADIUS_CONTAINER)
              .border({ width: 1, color: $r('app.color.border') })

            Column({ space: 8 }) {
              Text(this.labels.icon).fontSize(15).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary')).padding({ left: 4 })
              Column({ space: 12 }) {
                Row({ space: 12 }) {
                  Button({ type: ButtonType.Normal }) {
                    if (this.image) {
                      Image(this.image).width(56).height(56).objectFit(ImageFit.Cover).borderRadius(UI_RADIUS_CONTROL)
                    } else if (this.icon?.startsWith('symbol:')) {
                      ProjectSymbol({ name: this.icon.split(':')[1] })
                    } else if (this.iconText()) {
                      Text(this.iconText()).fontSize(24).fontColor($r('app.color.text_primary'))
                    } else {
                      ProjectSymbol({ name: 'Folder' })
                    }
                  }.width(56).height(56).padding(0).backgroundColor($r('app.color.bg_chip'))
                    .borderRadius(UI_RADIUS_CONTROL).accessibilityText(this.labels.icon)
                    .onClick((): void => { this.symbolsOpen = !this.symbolsOpen; })
                  if (!this.icon && !this.create && (this.store.snapshot?.settingsVersion ?? 0) >= 4) {
                    Text(this.checkingIcon ? this.labels.checkingIcon :
                      this.automaticSource ? this.labels.automatic + ' · ' + this.automaticSource : this.labels.noIcon)
                      .layoutWeight(1).fontSize(12).fontColor($r('app.color.text_secondary'))
                  }
                }.width('100%')
                Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
                  ForEach(this.symbolsOpen ? PROJECT_SYMBOL_NAMES : ['Folder', 'Code', 'Monitor'], (value: string) => {
                    this.iconOption(value, true, this.symbolsOpen)
                  }, (value: string): string => value)
                }.width('100%')
                Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
                  ForEach(['📁', '💻', '🚀', '🎨', '📚'], (value: string) => {
                    this.iconOption(value, false, false)
                  }, (value: string): string => value)
                }.width('100%')
                TextInput({ text: this.letters, placeholder: this.labels.letters }).maxLength(2).enabled(!this.store.saving)
                  .height(44).width('100%').backgroundColor($r('app.color.bg_chip'))
                  .fontColor($r('app.color.text_primary')).borderRadius(UI_RADIUS_CONTROL)
                  .onChange((value: string): void => { this.letters = value; if (/^[\p{L}\p{N}]{1,2}$/u.test(value)) { this.icon = 'text:' + value; this.image = ''; } })
                this.sectionDivider()
                Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
                  Button(this.labels.upload, { type: ButtonType.Normal }).constraintSize({ minWidth: 44, minHeight: 44 })
                    .backgroundColor($r('app.color.bg_chip')).fontColor($r('app.color.text_primary')).borderRadius(UI_RADIUS_CONTROL)
                    .enabled(!!this.onPickImage && !this.store.saving && !this.picking).onClick((): void => { void this.pickImage(); })
                  Button(this.labels.reset, { type: ButtonType.Normal }).constraintSize({ minWidth: 44, minHeight: 44 })
                    .backgroundColor($r('app.color.bg_chip')).fontColor($r('app.color.text_primary')).borderRadius(UI_RADIUS_CONTROL)
                    .enabled(!this.store.saving).onClick((): void => { void this.resetIcon(); })
                }.width('100%')
              }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
                .backgroundColor($r('app.color.bg_card')).borderRadius(UI_RADIUS_CONTAINER)
                .border({ width: 1, color: $r('app.color.border') })
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.width('100%').constraintSize({ maxWidth: 640 }).alignItems(HorizontalAlign.Start)
            .padding({ left: 16, right: 16, top: 8, bottom: 24 })
        }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto)
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
