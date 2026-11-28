import { uiConfirm, uiConfirmCopy, uiSheetOptions, UiSheetExtras } from './common/UiOverlay';
import { ChatHomePanel } from './chat/ChatHomePanel';
import { pasteboard } from '@kit.BasicServicesKit';
import { SharedTasksStore } from '../core/shared-tasks/SharedTasksStore';
import { SharedTasksPanel } from './shared-tasks/SharedTasksPanel';
import { SharedTaskAccess } from '../core/shared-tasks/SharedTaskAccess';
import { createSharedTaskLabels } from './shared-tasks/SharedTaskStrings';
import { fileIo } from '@kit.CoreFileKit';
import { readStr, recordOrEmpty } from '../core/tasks/TaskModels';
import { common } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { AppServices } from '../core/AppServices';
import { harmonyV12String } from '../core/HarmonyStrings';
import { ProjectStore } from '../core/projects/ProjectStore';
import { ResourceStore } from '../core/resources/ResourceStore';
import { ResourceLink } from '../core/resources/ResourceModels';
import { ChatStore } from '../core/chat/ChatStore';
import { ChatAttachmentPicker } from '../core/chat/ChatAttachmentPicker';
import { createChatAuthenticatedRequest } from '../core/chat/ChatAuthenticatedRequest';
import { AppConfig } from '../AppConfig';
import { ChatOwnedTaskTarget } from '../core/chat/ChatCards';
import { ChatWorkspace } from '../pages/chat/ChatWorkspace';
import { ChatSettingsPanel } from './chat/ChatSettingsPanel';
import { ProjectSettingsPanel } from './projects/ProjectSettingsPanel';
import { ResourcesPanel } from './resources/ResourcesPanel';
import { createProjectLabels } from './projects/ProjectStrings';
import { createResourceLabels } from './resources/ResourceStrings';
import { pickImageUris } from '../core/attachments/ImagePicker';
import { readFileBytes } from '../core/attachments/ImagePreprocess';
import { OwnedHostMedia } from '../core/attachments/OwnedHostMedia';
import { TeammateRosterEntry } from '../core/tasks/TeammateRoster';

export class HomeModuleRequest {
  kind: string = ''; // chat/resources/project
  deviceId: string = '';
  sessionId: string = '';
  invitation: string = '';
  projectKey: string = '';
  title: string = '';
  create: boolean = false;
  /** chat：首页「+ → 新建群聊」的一次性进入令牌，0 表示不自动进入新建群聊。 */
  createToken: number = 0;
}

/** Native detail content; parent owns the same single node across folding changes. */
@Component
export struct HomeModulePanel {
  @Prop @Watch('configure') request: HomeModuleRequest = new HomeModuleRequest();
  onClose: () => void = (): void => {};
  onOpenTask: (device: string, session: string, message?: string) => void = (): void => {};
  onProjectSaved: (device: string, projectKey: string) => void = (): void => {};
  @Prop localCompanions: TeammateRosterEntry[] = [];
  onChooseComputer: () => void = (): void => {};
  onLocalCompanion: (entry: TeammateRosterEntry) => void = (): void => {};
  @State private revision: number = 0;
  @State private error: string = '';
  @State private chatReady: boolean = false;
  @State private sharedReady: boolean = false;
  private shared: SharedTasksStore | null = null;
  @State private settings: boolean = false;
  @State private mediaUrl: string = '';
  @State private mediaOwner: string = '';
  private hostMedia: OwnedHostMedia | null = null;
  @State private choosingDirectory: boolean = false;
  @State private directoryPath: string = '~';
  @State private directoryParent: string = '';
  @State private directoryEntries: string[] = [];
  @State private directoryLoading: boolean = false;
  private directoryResolve: ((path: string) => void) | null = null;
  private directoryGeneration: number = 0;
  @State private mediaImage: boolean = true;
  private cloud: ChatStore | null = null;
  private picker: ChatAttachmentPicker | null = null;
  private generation: number = 0;
  private alive: boolean = false;
  private foreground: boolean = true;
  private configuration: string = '';
  private off: Array<() => void> = [];
  private locale: string = i18n.System.getSystemLanguage();
  private projects: ProjectStore = new ProjectStore((device: string, channel: string, args: Object[], timeout?: number): Promise<Object | undefined> =>
    AppServices.instance.invokeOwnedModule(device, channel, args, timeout));
  private resources: ResourceStore = new ResourceStore((device: string, channel: string, args: Object[], timeout?: number): Promise<Object | undefined> =>
    AppServices.instance.invokeOwnedModule(device, channel, args, timeout));
  private copy(key: string): string { return harmonyV12String(this.getUIContext().getHostContext(), 'v139_home_' + key); }
  aboutToAppear(): void {
    this.alive = true;
    const services = AppServices.instance;
    this.off.push(services.auth.onChanged((): void => this.configure()));
    this.off.push(services.onStatus((): void => this.configure()));
    this.off.push(services.tasks.onChanged((): void => this.configure()));
    this.off.push(services.cloudChat.onChanged((): void => {
      if (this.alive) { this.cloud = services.cloudChat.store; this.chatReady = this.cloud !== null; this.revision++; }
    }));
    this.off.push(services.onModulePush((device: string, channel: string, payload: Object | undefined): void => {
      if (channel === 'app-foreground') { this.foreground = payload === true; this.configuration = ''; this.configure(); return; }
      if (device !== this.request.deviceId) return;
      if (channel === 'link-closed') {
        this.projects.revoke(); this.resources.revoke(); this.configuration = ''; return;
      }
      this.projects.handlePush(device, channel);
      if (payload !== undefined) this.resources.handlePush(device, channel, payload);
    }));
    this.configure();
  }
  aboutToDisappear(): void {
    this.alive = false; this.generation++;
    this.hostMedia?.dispose(); this.hostMedia = null; this.mediaUrl = ''; this.mediaOwner = '';
    this.finishDirectory('');
    for (const off of this.off) off(); this.off = [];
    this.picker?.dispose(); this.picker = null;
    this.projects.dispose(); this.resources.dispose();
    AppServices.instance.cloudChat.setVisible(false);
  }
  private configure(): void {
    if (!this.alive) return;
    const services = AppServices.instance;
    const device = services.tasks.deviceList.find((row): boolean => row.deviceId === this.request.deviceId);
    const online = this.foreground && services.client.getStatus() === 'online'
      && device?.online === true && device.remoteControlEnabled;
    const key = JSON.stringify([services.moduleScope, this.request.kind, this.request.deviceId,
      this.request.projectKey, online, this.foreground]);
    if (this.configuration === key) return;
    this.configuration = key; this.generation++;
    this.mediaUrl = ''; this.mediaOwner = ''; this.error = '';
    this.hostMedia?.dispose(); this.hostMedia = services.createOwnedHostMedia();
    this.projects.configure(services.moduleScope, this.request.deviceId, online);
    this.resources.configure(services.moduleScope, this.request.deviceId, this.locale, online);
    this.projects.setVisible(this.request.kind === 'project' && this.foreground);
    this.resources.setVisible(this.request.kind === 'resources' && this.foreground);
    if (this.request.kind !== 'chat') services.cloudChat.setVisible(false);
    if (this.request.kind === 'chat' && services.auth.isLoggedIn && this.foreground) void this.prepareChat();
    if (this.request.kind === 'shared' && services.auth.isLoggedIn && this.foreground) void this.prepareShared();
    this.revision++;
  }
  private async prepareShared(): Promise<void> {
    const generation = this.generation;
    try {
      const store = await AppServices.instance.prepareSharedTasks();
      if (!this.alive || generation !== this.generation) return;
      this.shared = store; this.sharedReady = true; this.revision++;
    } catch (_error) { if (this.alive && generation === this.generation) this.error = this.copy('unavailable'); }
  }
  private async prepareChat(): Promise<void> {
    const generation = this.generation;
    const services = AppServices.instance;
    const epoch = services.auth.sessionEpoch;
    const current = (): boolean => this.alive && generation === this.generation && epoch === services.auth.sessionEpoch;
    this.error = '';
    try {
      const store = await services.cloudChat.prepare(); if (!current()) return;
      this.cloud = store; this.chatReady = true;
      await store.loadConversations(); if (current()) this.revision++;
    } catch (_error) { if (current()) this.error = this.copy('unavailable'); }
  }
  private async preview(room: string, id: string): Promise<void> {
    const generation = this.generation;
    try {
      const media = await AppServices.instance.cloudChat.api?.media(room, id);
      if (!this.alive || generation !== this.generation || media === undefined) return;
      this.mediaImage = media.type.startsWith('image/'); this.mediaOwner = this.mediaScope(); this.mediaUrl = media.url;
      if (!this.mediaImage) {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        await context.startAbility({ action: 'ohos.want.action.viewData', uri: media.url, type: media.type });
        this.mediaUrl = '';
      }
    } catch (_error) { if (this.alive && generation === this.generation) this.error = this.copy('unavailable'); }
  }
  private mediaScope(): string {
    const auth = AppServices.instance.auth;
    return auth.isLoggedIn ? JSON.stringify([auth.cacheAccountId, auth.sessionEpoch]) : '';
  }
  private async previewHost(device: string, reference: string, _name: string, mime: string): Promise<void> {
    const generation = this.generation, owner = this.mediaScope(), resolver = this.hostMedia;
    if (!owner || !resolver) return;
    const current = (): boolean => this.alive && generation === this.generation && owner === this.mediaScope();
    try {
      const source = await resolver.resolve(device, reference, false); if (!current()) return;
      if (mime.startsWith('image/')) { this.mediaImage = true; this.mediaOwner = owner; this.mediaUrl = source; }
      else {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        await context.startAbility({ action: 'ohos.want.action.viewData', uri: source, type: mime || 'application/octet-stream' });
      }
    } catch (_error) { if (current()) this.error = this.copy('unavailable'); }
  }
  private chooseDirectory(): Promise<string> {
    if (this.directoryResolve) return Promise.resolve('');
    this.choosingDirectory = true;
    void this.loadDirectory('~');
    return new Promise<string>((resolve) => { this.directoryResolve = resolve; });
  }
  private finishDirectory(path: string): void {
    this.directoryGeneration++; this.choosingDirectory = false;
    const resolve = this.directoryResolve; this.directoryResolve = null; resolve?.(path);
  }
  private async loadDirectory(path: string): Promise<void> {
    const generation = ++this.directoryGeneration, scope = AppServices.instance.moduleScope;
    const device = this.request.deviceId;
    this.directoryLoading = true; this.error = '';
    try {
      const request: Record<string, Object> = {}; request['path'] = path;
      const row = recordOrEmpty(await AppServices.instance.invokeOwnedModule(device, 'fs:list-dir', [request]));
      if (!this.alive || generation !== this.directoryGeneration || scope !== AppServices.instance.moduleScope) return;
      this.directoryPath = readStr(row, 'resolvedPath'); this.directoryParent = readStr(row, 'parent');
      const entries = row['entries']; this.directoryEntries = [];
      if (Array.isArray(entries)) this.directoryEntries = (entries as Object[]).filter((entry: Object): boolean => {
        const item = recordOrEmpty(entry); return (readStr(item, 'kind') || 'dir') === 'dir';
      }).map((entry: Object): string => readStr(recordOrEmpty(entry), 'path')).filter((value: string): boolean => value.length > 0);
    } catch (_error) { if (this.alive && generation === this.directoryGeneration) this.error = this.copy('unavailable'); }
    finally { if (this.alive && generation === this.directoryGeneration) this.directoryLoading = false; }
  }
  @Builder
  private directoryPicker() {
    Column({ space: 12 }) {
      Text(this.directoryPath).fontSize(14).fontColor($r('app.color.text_primary')).maxLines(2).width('100%')
      if (this.directoryLoading) { LoadingProgress().width(28).height(28) }
      if (this.directoryParent) {
        Button('..').height(44).onClick((): void => { void this.loadDirectory(this.directoryParent); })
      }
      Scroll() {
        Column() {
          ForEach(this.directoryEntries, (path: string) => {
            Button(path.slice(path.lastIndexOf('/') + 1) || path).height(44).width('100%')
              .fontColor($r('app.color.text_primary')).backgroundColor(Color.Transparent)
              .onClick((): void => { void this.loadDirectory(path); })
          }, (path: string): string => path)
        }.width('100%')
      }.width('100%').constraintSize({ maxHeight: 360 })
      if (this.error) { Text(this.error).fontColor($r('app.color.text_secondary')).fontSize(13) }
      Row({ space: 12 }) {
        Button(this.copy('cancel')).height(44).layoutWeight(1).onClick((): void => this.finishDirectory(''))
        Button(this.copy('confirm')).height(44).layoutWeight(1).enabled(!this.directoryLoading && !!this.directoryPath)
          .onClick((): void => this.finishDirectory(this.directoryPath))
      }.width('100%')
    }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 20 })
  }
  /** 目录选择：底部表单；系统关闭按钮 / 下滑等同于取消，沿用 finishDirectory('') 结算挂起的选择。 */
  private directorySheetOptions(): SheetOptions {
    const extras = new UiSheetExtras();
    extras.onWillDismiss = (_action: DismissSheetAction): void => { this.finishDirectory(''); };
    return uiSheetOptions(createProjectLabels(this.locale).directory, (): void => {}, SheetSize.FIT_CONTENT, extras);
  }
  private async pickProjectImage(): Promise<string> {
    const generation = this.generation;
    const uris = await pickImageUris(1); if (!uris.length) return '';
    const stat = await fileIo.stat(uris[0]);
    if (stat.size <= 0 || stat.size > 20 * 1024 * 1024) throw new Error('IMAGE_TOO_LARGE');
    const bytes = await readFileBytes(uris[0]);
    if (bytes.byteLength > 20 * 1024 * 1024) throw new Error('IMAGE_TOO_LARGE');
    const source = image.createImageSource(bytes);
    const packer = image.createImagePacker();
    let bitmap: image.PixelMap | undefined;
    try {
      const info = await source.getImageInfo();
      const scale = Math.min(1, 512 / Math.max(info.size.width, info.size.height));
      bitmap = await source.createPixelMap({ desiredSize: {
        width: Math.max(1, Math.round(info.size.width * scale)),
        height: Math.max(1, Math.round(info.size.height * scale)),
      } });
      const packed = await packer.packing(bitmap, { format: 'image/jpeg', quality: 75 });
      if (!this.alive || generation !== this.generation) return '';
      if (packed.byteLength > 220000) throw new Error('IMAGE_TOO_LARGE');
      return 'data:image/jpeg;base64,' + new util.Base64Helper().encodeToStringSync(new Uint8Array(packed));
    } finally { bitmap?.release(); packer.release(); source.release(); }
  }
  private async confirm(title: string, message: string): Promise<boolean> {
    return uiConfirm(this.getUIContext(), uiConfirmCopy(title, message, this.copy('confirm'), this.copy('cancel')));
  }
  @Builder
  private content() {
    if (this.request.kind === 'shared' && this.sharedReady) {
      SharedTasksPanel({ store: this.shared ?? undefined, labels: createSharedTaskLabels(this.locale),
        ownerDeviceId: this.request.deviceId, ownerSessionId: this.request.sessionId,
        initialInvitation: this.request.invitation,
        onOpenGuest: (access: SharedTaskAccess): void => { AppServices.instance.openSharedTask(access.target); this.onClose(); },
        onCopy: async (text: string): Promise<void> => {
          await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
        } })
    } else if (this.request.kind === 'chat' && this.chatReady) {
      ChatHomePanel({ cloudStore: this.cloud, cloudApi: AppServices.instance.cloudChat.api,
        auth: AppServices.instance.auth, secureStore: AppServices.instance.privateClientStorage,
        scopeKey: AppServices.instance.moduleScope, selectedDevice: this.request.deviceId,
        current: (): boolean => this.alive && this.cloud === AppServices.instance.cloudChat.store && AppServices.instance.auth.isLoggedIn,
        resourceInvoke: (device: string, channel: string, args: Object[]): Promise<Object | undefined> =>
          AppServices.instance.invokeOwnedModule(device, channel, args),
        subscribePush: (listener) => AppServices.instance.onModulePush(listener),
        foreground: this.foreground, locale: this.locale, region: AppConfig.region, realm: AppConfig.region,
        chatBaseUrl: AppConfig.chatApiBaseUrl, shareBaseUrl: AppConfig.shareBaseUrl, ossBaseUrl: AppConfig.ossApiBaseUrl,
        initialInvitation: this.request.invitation, title: this.request.title || this.copy('chat'),
        initialCreate: this.request.createToken,
        localCompanions: this.localCompanions, onLocalCompanion: this.onLocalCompanion,
        deviceName: (device: string): string => AppServices.instance.tasks.getDeviceName(device),
        canControlDevice: (device: string): boolean => AppServices.instance.tasks.deviceList.some((row): boolean => row.deviceId === device && row.remoteControlEnabled),
        onOwnedTask: (target: ChatOwnedTaskTarget): void => this.onOpenTask(target.deviceId, target.sessionId, target.clientId),
        onMedia: (room: string, media: string): void => { void this.preview(room, media); }, onClose: this.onClose,
        resolveHostMedia: (device: string, reference: string, thumbnail: boolean): Promise<string> =>
          this.hostMedia?.resolve(device, reference, thumbnail) ?? Promise.reject(new Error('OWNER_CHANGED')),
        onHostMedia: (device: string, reference: string, name: string, mime: string): void => { void this.previewHost(device, reference, name, mime); },
        onSelectDevice: this.onChooseComputer,
        onCloudVisibility: (visible: boolean, list: boolean): void => AppServices.instance.cloudChat.setVisible(visible, list),
      })
    } else if (this.request.kind === 'project') {
      ProjectSettingsPanel({ store: this.projects, projectKey: this.request.projectKey, title: this.request.title,
        create: this.request.create, deviceName: AppServices.instance.tasks.getDeviceName(this.request.deviceId),
        labels: createProjectLabels(this.locale),
        onChooseDirectory: this.request.projectKey.startsWith('remote:') ? undefined : (): Promise<string> => this.chooseDirectory(),
        onPickImage: (): Promise<string> => this.pickProjectImage(),
        onSaved: (key: string): void => this.onProjectSaved(this.request.deviceId, key), onClose: this.onClose })
    } else if (this.request.kind === 'resources') {
      ResourcesPanel({ store: this.resources, labels: createResourceLabels(this.locale), onOpen: (link: ResourceLink): void => {
        if (link.kind === 'session') this.onOpenTask(this.request.deviceId, link.sessionId);
      } })
    } else {
      Text(this.copy('loading')).fontColor($r('app.color.text_secondary')).padding(20)
    }
  }
  build() {
    Stack() {
      Column() {
        // Chat owns its own title bar once ready (one bar, one back); every other state keeps the module bar.
        if (!(this.request.kind === 'chat' && this.chatReady && !this.choosingDirectory)) {
          Row({ space: 4 }) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([$r('app.color.text_primary')])
            }.width(44).height(44).padding(0).backgroundColor(Color.Transparent)
              .accessibilityText(this.copy('back')).onClick(this.onClose)
            Text(this.request.title || this.copy(this.request.kind)).fontSize(17).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.height(56).width('100%').padding({ left: 4, right: 16 }).alignItems(VerticalAlign.Center)
        }
        if (this.error) {
          Row({ space: 8 }) {
            Text(this.error).fontSize(13).fontColor($r('app.color.danger')).layoutWeight(1)
            if (this.request.kind === 'chat') {
              Button(this.copy('refresh'), { type: ButtonType.Normal }).height(44).padding({ left: 8, right: 8 })
                .fontSize(14).fontColor($r('app.color.accent')).backgroundColor(Color.Transparent)
                .onClick((): void => { void this.prepareChat(); })
            }
          }.width('100%').padding({ left: 16, right: 8 }).alignItems(VerticalAlign.Center)
        }
        Column() { if (this.revision >= 0) this.content() }.width('100%').layoutWeight(1)
      }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
      if (this.mediaUrl && this.mediaImage && this.mediaOwner && this.mediaOwner === this.mediaScope()) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Image(this.mediaUrl).width('100%').height('100%').objectFit(ImageFit.Contain)
          Button(this.copy('back')).height(44).margin(16).onClick((): void => { this.mediaUrl = ''; })
        }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
      }
    }.width('100%').height('100%')
    .bindSheet(this.choosingDirectory, this.directoryPicker(), this.directorySheetOptions())
  }
}
