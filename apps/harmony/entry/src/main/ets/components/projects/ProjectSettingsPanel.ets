import { resourceIssueText } from '../../core/resources/ResourceIssueStrings';
import { isExplicitProjectRepositoryAddress, parseProjectRepository, projectCreationFolderName } from '../../core/projects/ProjectCreation';
import { PROJECT_SYMBOL_NAMES } from '../../core/projects/ProjectSymbolPaths';
import { ProjectSymbol } from './ProjectSymbol';
import { ProjectStore, ProjectProfile, ProjectDirectory, ProjectAutomaticIcon, projectLocation } from '../../core/projects/ProjectStore';
import { UI_RADIUS_CONTAINER } from '../UiKit';

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
  @State private name: string = '';
  @State private directory: string = '';
  @State private repository: string = '';
  @State private repositoryMode: boolean = false;
  @State private icon: string | null = null;
  @State private image: string = '';
  @State private letters: string = '';
  @State private symbolsOpen: boolean = false;
  @State private automaticSource: string = '';
  @State private checkingIcon: boolean = false;
  @State private sshDirectory: string = '';
  @State private directories: ProjectDirectory[] = [];
  @State private localIssue: string = '';
  @State private picking: boolean = false;
  private initial: string = '';
  private initialized: boolean = false;
  private ownerIdentity: string = '';
  private alive: boolean = false;
  private unsubscribe: (() => void) | null = null;
  private draft(): string { return JSON.stringify([this.name, this.directory, this.repository, this.icon, this.directories]); }
  aboutToAppear(): void {
    this.alive = true;
    this.name = this.title;
    this.directory = projectLocation('', this.projectKey)?.directory ?? '';
    this.unsubscribe = this.store.onChanged((): void => { this.initialize(); this.revision++; });
    this.initialize(); this.store.setVisible(true);
  }
  aboutToDisappear(): void { this.alive = false; this.unsubscribe?.(); this.unsubscribe = null; this.store.setVisible(false); }
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
      void this.store.iconImage(this.projectKey).then((value: string): void => { if (this.alive && identity === this.store.identity()) this.image = value; }).catch((): void => {});
    } else if (!this.icon && !this.create && snapshot.settingsVersion >= 4) {
      this.checkingIcon = true;
      void this.store.automaticIcon(this.projectKey).then((value: ProjectAutomaticIcon | null): void => {
        if (!this.alive || identity !== this.store.identity()) return;
        this.checkingIcon = false; this.image = value?.image ?? ''; this.automaticSource = value?.source ?? '';
      }).catch((): void => { if (this.alive && identity === this.store.identity()) this.checkingIcon = false; });
    }
  }
  private close(): void {
    if (this.store.saving || this.picking) return;
    if (this.draft() === this.initial) { this.onClose(); return; }
    this.getUIContext().showAlertDialog({ title: this.labels.discard, message: '',
      primaryButton: { value: this.labels.keepEditing, action: (): void => {} },
      secondaryButton: { value: this.labels.cancel, action: (): void => this.onClose() } });
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
    const profile: ProjectProfile = { name: this.name.trim(), icon: this.icon };
    if ((this.store.snapshot?.settingsVersion ?? 0) >= 6) profile.directories = this.directories;
    if (this.repositoryMode && !parseProjectRepository(this.repository)) { this.localIssue = 'invalid'; return; }
    const key = this.create ? 'local:' + this.directory : this.projectKey;
    if (await this.store.save(key, profile, this.create, this.repositoryMode ? this.repository : '')) {
      if (this.alive) this.onSaved(this.create ? this.store.createdProjectKey : key);
    }
  }
  build() {
    Column({ space: 12 }) {
      if (this.revision >= 0) {
        Row({ space: 8 }) {
          Button(this.labels.cancel).height(44).enabled(!this.store.saving && !this.picking).onClick((): void => this.close())
          Blank()
          Button(this.create ? this.labels.create : this.labels.save).height(44)
            .enabled(this.initialized && !this.store.saving && !this.store.uncertain && !this.picking && (this.store.snapshot?.settingsVersion ?? 0) >= (this.create ? 6 : 2))
            .onClick((): void => { void this.save(); })
        }.width('100%')
        if (this.store.busy || this.store.saving || this.picking) { LoadingProgress().width(28).height(28) }
        if (this.store.issue || this.localIssue) { Text(this.labels.status(this.store.issue || this.localIssue)).fontColor($r('app.color.text_secondary')).fontSize(14) }
        if (this.store.uncertain) {
          Text(this.store.pendingProjectKey).fontColor($r('app.color.text_secondary')).fontSize(12)
          Button(this.labels.refresh).height(44).onClick((): void => { void this.store.refresh(); })
          Button(this.labels.checked).height(44).onClick((): void => this.store.acknowledgeCheckedResult())
        }
        Scroll() {
          Column({ space: 12 }) {
            Text(this.labels.computer + ' · ' + this.deviceName).fontColor($r('app.color.text_secondary')).fontSize(14)
            Text(this.labels.name).fontColor($r('app.color.text_primary')).fontSize(14)
            TextInput({ text: this.name }).maxLength(80).enabled(!this.store.saving).onChange((value: string): void => {
                const repo = this.create && (this.store.snapshot?.settingsVersion ?? 0) >= 7 && isExplicitProjectRepositoryAddress(value) ? parseProjectRepository(value) : null;
                if (repo) { this.name = repo.name.slice(0, 80); this.repositoryMode = true; this.repository = repo.url; this.directory = ''; this.directories = []; }
                else this.name = value;
              })
            if (this.create && (this.store.snapshot?.settingsVersion ?? 0) >= 7) {
              Row({ space: 8 }) {
                Button(this.labels.local).height(44).enabled(!this.store.saving).onClick((): void => { this.repositoryMode = false; this.repository = ''; this.directory = ''; this.directories = []; })
                Button(this.labels.repository).height(44).enabled(!this.store.saving).onClick((): void => { this.repositoryMode = true; this.directory = ''; this.directories = []; })
              }
              if (this.repositoryMode) {
                TextInput({ text: this.repository, placeholder: this.labels.repository }).enabled(!this.store.saving)
                  .onChange((value: string): void => {
                    const previous = parseProjectRepository(this.repository), next = parseProjectRepository(value);
                    this.repository = value;
                    if (next && (!this.name.trim() || this.name === previous?.name)) this.name = next.name.slice(0, 80);
                  })
              }
            }
            Text(this.labels.directory).fontColor($r('app.color.text_primary')).fontSize(14)
            Text(this.directory || (this.create && this.store.snapshot?.creationRoot ? this.store.snapshot.creationRoot + '/' + projectCreationFolderName(this.name || parseProjectRepository(this.repository)?.name || 'Project') : '')).fontSize(14).fontColor($r('app.color.text_secondary')).copyOption(CopyOptions.LocalDevice)
            ForEach(this.directories, (entry: ProjectDirectory, index: number) => {
              Row({ space: 8 }) {
                Text(entry.path).fontSize(14).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                Button(this.labels.remove).height(44).enabled(!this.store.saving).onClick((): void => { this.directories = this.directories.filter((_entry: ProjectDirectory, position: number): boolean => position !== index); })
              }.width('100%')
            }, (entry: ProjectDirectory): string => entry.path)
            if ((this.store.snapshot?.settingsVersion ?? 0) >= 6 && !this.projectKey.startsWith('remote:')) {
              Button(this.labels.addDirectory).height(44).enabled(!!this.onChooseDirectory && !this.store.saving && !this.picking && this.directories.length < 10).onClick((): void => { void this.choose(); })
            }
            if ((this.store.snapshot?.settingsVersion ?? 0) >= 6 && this.projectKey.startsWith('remote:')) {
              TextInput({ text: this.sshDirectory, placeholder: this.labels.directory }).enabled(!this.store.saving)
                .onChange((value: string): void => { this.sshDirectory = value; })
              Button(this.labels.addDirectory).height(44).enabled(!this.store.saving && this.directories.length < 10)
                .onClick((): void => this.addSshDirectory())
            }
            Text(this.labels.icon).fontColor($r('app.color.text_primary')).fontSize(14)
            if (!this.icon && !this.create && (this.store.snapshot?.settingsVersion ?? 0) >= 4) {
              Text(this.checkingIcon ? this.labels.checkingIcon : this.automaticSource ? this.labels.automatic + ' · ' + this.automaticSource : this.labels.noIcon)
                .fontSize(12).fontColor($r('app.color.text_secondary'))
            }
            if (this.image) { Image(this.image).width(64).height(64).objectFit(ImageFit.Cover).borderRadius(UI_RADIUS_CONTAINER) }
            if (this.icon?.startsWith('symbol:')) {
              ProjectSymbol({ name: this.icon.split(':')[1] })
            } else {
              Text(this.icon?.startsWith('data:') || this.icon?.startsWith('cindy-media:') ? '' : this.icon?.startsWith('text:') ? this.icon.split(':')[1] : this.icon ?? '').fontSize(24).fontColor($r('app.color.text_primary'))
            }
            Button(this.labels.icon).height(44).onClick((): void => { this.symbolsOpen = !this.symbolsOpen; })
            if (this.symbolsOpen) {
              Grid() {
                ForEach(PROJECT_SYMBOL_NAMES, (value: string) => {
                  GridItem() {
                    Button() { ProjectSymbol({ name: value }) }.width(44).height(44).accessibilityText(value)
                      .enabled(!this.store.saving).onClick((): void => { this.icon = 'symbol:' + value; this.image = ''; this.symbolsOpen = false; })
                  }
                })
              }.columnsTemplate('1fr 1fr 1fr 1fr 1fr').rowsGap(8).height(320).width('100%')
            }
            Row({ space: 8 }) {
              ForEach(['Folder', 'Code', 'Monitor'], (value: string) => {
                Button() { ProjectSymbol({ name: value }) }.width(44).height(44).accessibilityText(value)
                  .enabled(!this.store.saving).onClick((): void => { this.icon = 'symbol:' + value; this.image = ''; })
              })
            }
            Row({ space: 8 }) {
              ForEach(['📁', '💻', '🚀', '🎨', '📚'], (value: string) => {
                Button(value).width(44).height(44).enabled(!this.store.saving).onClick((): void => { this.icon = value; this.image = ''; })
              })
            }
            TextInput({ text: this.letters, placeholder: this.labels.letters }).maxLength(2).enabled(!this.store.saving)
              .onChange((value: string): void => { this.letters = value; if (/^[\p{L}\p{N}]{1,2}$/u.test(value)) { this.icon = 'text:' + value; this.image = ''; } })
            Row({ space: 8 }) {
              Button(this.labels.reset).height(44).enabled(!this.store.saving).onClick((): void => { void this.resetIcon(); })
              Button(this.labels.upload).height(44).enabled(!!this.onPickImage && !this.store.saving && !this.picking).onClick((): void => { void this.pickImage(); })
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%')
      }
    }.width('100%').height('100%').padding(16).backgroundColor($r('app.color.bg_page'))
  }
}
