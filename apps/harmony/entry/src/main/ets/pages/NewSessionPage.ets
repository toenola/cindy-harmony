/**
 * 新建任务页：选择 Agent、对话类型和项目目录，然后用同款 Composer 发送首条消息。
 *
 * 创建与目录浏览都复用 Device Link 已有远程 channel；Harmony 只负责原生呈现，
 * 任务和消息真相仍由被控端桌面维护。
 */

import { KeyboardAvoidMode, router, promptAction, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import {
  photoAccessHelper, PhotoPickerComponent, PickerController, PickerOptions,
  SelectMode, PickerOrientation, SingleLineConfig, DataType,
} from '@kit.MediaLibraryKit';
import { AppServices } from '../core/AppServices';
import {
  ComposerChoiceOption as RuntimeChoiceOption,
  ComposerModelOption as RuntimeModelOption,
  ProviderListOptions,
  composerModelKey,
  effortLevelLabel,
  parseModelOptions,
  parseModelVisibilityOverrides,
  parseProviderModelOptions as parseComposerProviderModelOptions,
  permissionModeDescription,
  permissionModeLabel,
  reconcileModelEffort,
  selectedPermissionModeLabel,
} from '../core/ComposerCatalog';
import { pickImageUris, pickScreenshotUris, takePhotoUri, buildImageCandidate } from '../core/attachments/ImagePicker';
import {
  uploadImage, deleteUpload, presignGet, isUploadRevisionCurrent,
} from '../core/attachments/AttachmentUpload';
import { RemoteImageRef, RemoteSerializedAttachment } from '../core/attachments/AttachmentModels';
import { ComposerFile } from '../core/attachments/ComposerFileQueue';
import { parseAttachmentOssRef } from '../core/attachments/AttachmentOssRef';
import { DlInvokeOptions } from '../core/device-link/DlClient';
import { DlChannels, PresenceSnapshot } from '../core/device-link/DlProtocol';
import { unwrapInvokeResult } from '../core/tasks/TaskStore';
import { RemoteSession, readBool, readObj, readStr } from '../core/tasks/TaskModels';
import {
  NewSessionCreationParams,
  NewSessionEditDraft,
} from '../core/tasks/NewSessionCreationStore';
import { normalizeAutoTitle } from './TaskListPresentation';
import { ComposerImage, ConversationComposer } from '../components/ConversationComposer';
import {
  ComposerDocument,
  composerDocumentProjectedText,
  textComposerDocument,
} from '../core/messages/ComposerDocument';
import {
  UI_ICON_CLICK_EFFECT,
  UI_LIST_CLICK_EFFECT,
  UI_RADIUS_CONTROL,
  uiAnimateFastState,
  uiFontSize,
  uiLineHeight,
  uiOverlayTransition,
} from '../components/UiKit';

type NewAgentKind = 'claude-code' | 'codex' | 'pi';
type WorkspaceKind = 'dialogue' | 'project';

class RecentProject {
  path: string = '';
  title: string = '';
  lastActivityAt: string = '';
}

class RemoteDirectory {
  name: string = '';
  kind: string = 'dir';
  path: string = '';
}

const NEW_AGENT_OPTIONS: NewAgentKind[] = ['claude-code', 'codex', 'pi'];
const MAX_COMPOSER_IMAGES = 20;
/** 新建任务尚无 sessionId，使用保留键复用会话 Composer 的防抖持久化。 */
const NEW_SESSION_COMPOSER_DRAFT_ID = '__new-session__';
const NEW_SESSION_DRAFT_CHECKPOINT_MS = 1500;
function createRecentPickerOptions(): PickerOptions {
  const options = new PickerOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  options.maxSelectNumber = MAX_COMPOSER_IMAGES;
  options.maxPhotoSelectNumber = MAX_COMPOSER_IMAGES;
  options.selectMode = SelectMode.MULTI_SELECT;
  options.orientation = PickerOrientation.HORIZONTAL;
  options.isPhotoTakingSupported = false;
  const singleLine = new SingleLineConfig();
  singleLine.itemBorderRadius = 6;
  singleLine.itemGap = 6;
  options.singleLineConfig = singleLine;
  return options;
}

function agentLabel(kind: NewAgentKind): string {
  if (kind === 'codex') return 'Codex';
  if (kind === 'pi') return 'Pi';
  return 'Claude';
}

function agentMark(kind: NewAgentKind): string {
  if (kind === 'codex') return 'CX';
  if (kind === 'pi') return 'π';
  return 'CC';
}

function fallbackModel(kind: NewAgentKind): string {
  if (kind === 'codex' || kind === 'pi') return 'gpt-5.4';
  return 'claude-sonnet-4-6';
}

function directoryTitle(path: string): string {
  const normalized = path.trim().replace(/\\/g, '/').replace(/\/+$/, '');
  if (normalized.length === 0) return '项目目录';
  const parts = normalized.split('/');
  return parts[parts.length - 1] || normalized;
}

function newAgentKindFromSession(session: RemoteSession): NewAgentKind {
  if (session.agentKind === 'codex') return 'codex';
  if (session.agentKind === 'pi') return 'pi';
  return 'claude-code';
}

@Entry
@Component
struct NewSessionPage {
  @State devices: PresenceSnapshot[] = [];
  @State selectedDeviceId: string = '';
  @State selectedAgentKind: NewAgentKind = 'claude-code';
  @State workspaceKind: WorkspaceKind = 'dialogue';
  @State workingDir: string = '';
  @State input: string = '';
  @State composerFocused: boolean = false;
  /** 模型选择等临时清焦期间仍保留与任务详情一致的完整输入卡片。 */
  @State composerSurfaceVisible: boolean = false;
  private composerBlurGeneration: number = 0;
  @State composerImages: ComposerImage[] = [];
  @State composerFiles: ComposerFile[] = [];
  @State pickingImages: boolean = false;
  /** 新建页待发送图片的全屏预览 URL（空 = 无预览）。 */
  @State previewImageUrl: string = '';
  @State contextSheetOpen: boolean = false;
  @State composerPermissionPopupOpen: boolean = false;
  @State composerModelPopupOpen: boolean = false;
  /** 仅恢复打开模型 Popup 前已经存在的输入焦点。 */
  private composerPopupRestoreFocus: boolean = false;
  @State contextSheetPage: string = 'main';
  private restoreComposerFocusOnSheetDisappear: boolean = false;
  /** 每个模型行自己的思考强度和 Fast 选择；非当前行在选中模型时一并应用。 */
  @State modelEffortMemory: Map<string, string> = new Map();
  @State modelFastMemory: Map<string, boolean> = new Map();
  @State modelEffortPickerKey: string = '';
  @State contextSelectedUris: string[] = [];
  @State selectorOpen: string = '';
  @State browseOpen: boolean = false;
  @State browsePath: string = '';
  @State browseParent: string = '';
  @State browseEntries: RemoteDirectory[] = [];
  @State browseLoading: boolean = false;
  @State browseError: string = '';
  @State showHiddenDirectories: boolean = false;
  @State model: string = '';
  @State providerId: string = '';
  @State effort: string = '';
  @State permissionMode: string = '';
  @State permissionModeBeforePlan: string = 'auto';
  @State planModeSupported: boolean = false;
  @State planModeNative: boolean = false;
  @State planModeEnabled: boolean = false;
  @State fastMode: boolean = false;
  @State modelOptions: RuntimeModelOption[] = [];
  @State providerModelOptions: RuntimeModelOption[] = [];
  @State providerModelAgent: string = '';
  @State modelVisibilityOverrides: Map<string, boolean> = new Map();
  @State effortOptions: RuntimeChoiceOption[] = [];
  @State permissionOptions: RuntimeChoiceOption[] = [];
  @State fastModeCapability: boolean = false;
  @State composerToolbarReady: boolean = false;
  @State creating: boolean = false;
  @State error: string = '';
  @State taskRevision: number = 0;
  /** 页面显式消费软键盘高度，保证 Hds 容器内的完整 Composer 不被盖住。 */
  @State keyboardHeight: number = 0;
  private recentPickerOptions: PickerOptions = createRecentPickerOptions();
  @State recentPickerController: PickerController = new PickerController();

  private unsubs: Array<() => void> = [];
  private routeDeviceId: string = '';
  private runtimeLoadGeneration: number = 0;
  /** 防止设备列表推送在同一轮能力加载期间重复发起相同请求。 */
  private runtimeToolbarLoadActive: boolean = false;
  /** 异步能力目录返回后，不得覆盖用户在加载窗口内已经选定的运行参数。 */
  private runtimeModelTouchedGeneration: number = -1;
  private runtimeEffortTouchedGeneration: number = -1;
  private runtimePermissionTouchedGeneration: number = -1;
  private runtimePlanTouchedGeneration: number = -1;
  private runtimeFastTouchedGeneration: number = -1;
  private agentTouched: boolean = false;
  /** create-failed 返回编辑后，等待 capabilities 回包再恢复一次运行参数。 */
  private pendingEditDraft: NewSessionEditDraft | null = null;
  /** 首条消息附件一旦交给 creation store，页面销毁时不得再回收。 */
  private attachmentsHandedOff: boolean = false;
  private attachmentsDisposed: boolean = false;
  private pageActive: boolean = false;
  private keyboardWindow: window.Window | null = null;
  private keyboardHeightListening: boolean = false;
  private newSessionDraftGeneration: number = 0;
  private newSessionInputRevision: number = 0;
  private newSessionDraftCheckpointTimer: number = -1;
  private keyboardHeightListener: (height: number) => void = (height: number): void => {
    this.keyboardHeight = Math.max(0, this.getUIContext().px2vp(height));
  };

  aboutToAppear(): void {
    this.pageActive = true;
    this.keyboardHeight = 0;
    // 同 Mobile 的 KeyboardAvoidingView 语义：可用高度由页面直接缩小。
    // 不能只依赖全局 OFFSET，否则横屏 Hds 容器可能仍按全高摆放 Composer。
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
    void this.observeKeyboardHeight();
    const params = (router.getParams() ?? {}) as Record<string, Object>;
    this.routeDeviceId = readStr(params, 'deviceId');
    const editDraft = AppServices.instance.newSessionCreations.consumeEditDraft();
    if (editDraft !== null) {
      this.pendingEditDraft = editDraft;
      this.routeDeviceId = editDraft.deviceId;
      this.agentTouched = true;
      this.selectedAgentKind = this.editDraftAgentKind(editDraft.agentKind);
      this.workspaceKind = editDraft.workspaceKind === 'project' ? 'project' : 'dialogue';
      this.workingDir = editDraft.workingDir;
      this.applyNewSessionInput(editDraft.text);
      this.composerImages = this.editDraftImages(editDraft.images);
      this.composerFiles = this.editDraftFiles(editDraft.files);
      const missingAttachments = editDraft.images.length - this.composerImages.length
        + editDraft.files.length - this.composerFiles.length;
      if (missingAttachments > 0) {
        this.error = `有 ${missingAttachments} 个附件因数量上限未恢复`;
      }
      this.resolveEditDraftImagePreviews();
    } else {
      this.restoreNewSessionDraft();
    }
    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      this.refreshDevices();
    }));
    this.refreshDevices();
    this.applyPendingEditRuntime(this.routeDeviceId, this.selectedAgentKind, false);
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.getUIContext().getFocusController().clearFocus();
    this.composerBlurGeneration += 1;
    this.composerFocused = false;
    this.composerSurfaceVisible = false;
    this.contextSheetOpen = false;
    this.restoreComposerFocusOnSheetDisappear = false;
    this.newSessionDraftGeneration += 1;
    this.cancelNewSessionDraftCheckpoint();
    void AppServices.instance.composerDrafts.flush(NEW_SESSION_COMPOSER_DRAFT_ID).catch(() => {});
    this.stopKeyboardHeightObservation();
    this.keyboardHeight = 0;
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    this.runtimeLoadGeneration += 1;
    this.runtimeToolbarLoadActive = false;
    this.composerToolbarReady = false;
    if (!this.attachmentsHandedOff) this.disposeUnsentAttachments();
    for (const unsubscribe of this.unsubs) {
      unsubscribe();
    }
    this.unsubs = [];
  }

  private async observeKeyboardHeight(): Promise<void> {
    if (this.keyboardHeightListening) return;
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext === undefined) return;
    try {
      const hostWindow = await window.getLastWindow(hostContext);
      if (!this.pageActive || this.keyboardHeightListening) return;
      this.keyboardWindow = hostWindow;
      hostWindow.on('keyboardHeightChange', this.keyboardHeightListener);
      this.keyboardHeightListening = true;
    } catch (_err) {
      // 无法获得高度通知时交还给系统，避免极端设备上完全失去输入法避让。
      if (this.pageActive) this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    }
  }

  private stopKeyboardHeightObservation(): void {
    if (!this.keyboardHeightListening || this.keyboardWindow === null) return;
    try {
      this.keyboardWindow.off('keyboardHeightChange', this.keyboardHeightListener);
    } catch (_err) {
      // 页面退出时窗口可能已由系统回收。
    }
    this.keyboardWindow = null;
    this.keyboardHeightListening = false;
  }

  private restoreNewSessionDraft(): void {
    const generation = ++this.newSessionDraftGeneration;
    const inputRevision = this.newSessionInputRevision;
    void AppServices.instance.composerDrafts.read(NEW_SESSION_COMPOSER_DRAFT_ID)
      .then((document: ComposerDocument | null) => {
        if (!this.pageActive || generation !== this.newSessionDraftGeneration
          || inputRevision !== this.newSessionInputRevision || document === null) return;
        this.input = composerDocumentProjectedText(document);
      });
  }

  private applyNewSessionInput(value: string): void {
    this.input = value;
    this.newSessionInputRevision += 1;
    AppServices.instance.composerDrafts.save(
      NEW_SESSION_COMPOSER_DRAFT_ID,
      textComposerDocument(value),
    );
    this.scheduleNewSessionDraftCheckpoint();
  }

  /** trailing debounce 之外再做固定间隔检查点，持续输入时也不会一直没有落盘版本。 */
  private scheduleNewSessionDraftCheckpoint(): void {
    if (this.newSessionDraftCheckpointTimer >= 0) return;
    this.newSessionDraftCheckpointTimer = setTimeout(() => {
      this.newSessionDraftCheckpointTimer = -1;
      if (!this.pageActive) return;
      void AppServices.instance.composerDrafts.flush(NEW_SESSION_COMPOSER_DRAFT_ID).catch(() => {});
    }, NEW_SESSION_DRAFT_CHECKPOINT_MS);
  }

  private cancelNewSessionDraftCheckpoint(): void {
    if (this.newSessionDraftCheckpointTimer < 0) return;
    clearTimeout(this.newSessionDraftCheckpointTimer);
    this.newSessionDraftCheckpointTimer = -1;
  }

  /** 直接返回时使在途上传失效，并回收所有仍由新建页持有的 OSS 引用。 */
  private disposeUnsentAttachments(): void {
    if (this.attachmentsDisposed) return;
    this.attachmentsDisposed = true;
    const images = this.composerImages.slice();
    const files = this.composerFiles.slice();
    this.composerImages = [];
    this.composerFiles = [];
    for (let i = 0; i < images.length; i++) {
      images[i].uploadRevision += 1;
      images[i].removed = true;
      this.recycleComposerImage(images[i]);
    }
    for (let i = 0; i < files.length; i++) {
      files[i].uploadRevision += 1;
      files[i].removed = true;
      if (files[i].ref !== null) this.recycleComposerFileRef(files[i].ref as RemoteSerializedAttachment);
    }
  }

  private editDraftAgentKind(value: string): NewAgentKind {
    if (value === 'codex') return 'codex';
    if (value === 'pi') return 'pi';
    return 'claude-code';
  }

  private editDraftImages(refs: RemoteImageRef[]): ComposerImage[] {
    const images: ComposerImage[] = [];
    for (let i = 0; i < refs.length && images.length < MAX_COMPOSER_IMAGES; i++) {
      const image = new ComposerImage();
      image.uri = refs[i].base64.length > 0
        ? `data:${refs[i].mimeType.length > 0 ? refs[i].mimeType : 'image/png'};base64,${refs[i].base64}`
        : refs[i].url;
      image.name = refs[i].originalName.length > 0 ? refs[i].originalName : `image-${i + 1}`;
      image.status = 'ready';
      image.ref = refs[i];
      images.push(image);
    }
    return images;
  }

  private editDraftFiles(refs: RemoteSerializedAttachment[]): ComposerFile[] {
    const files: ComposerFile[] = [];
    const available = Math.max(0, MAX_COMPOSER_IMAGES - this.composerImages.length);
    for (let i = 0; i < refs.length && files.length < available; i++) {
      const file = new ComposerFile();
      file.uri = refs[i].path;
      file.name = refs[i].name.length > 0 ? refs[i].name : `attachment-${i + 1}`;
      file.size = refs[i].size;
      file.status = 'ready';
      file.ref = refs[i];
      files.push(file);
    }
    return files;
  }

  private resolveEditDraftImagePreviews(): void {
    for (let i = 0; i < this.composerImages.length; i++) {
      const image = this.composerImages[i];
      if (image.ref === null || image.ref.base64.length > 0) continue;
      const parsed = parseAttachmentOssRef(image.ref.url);
      if (parsed === null || parsed.ossKey.length === 0) continue;
      void AppServices.instance.auth.getAccessToken().then((token: string | null) => {
        if (token === null || token.length === 0) return Promise.reject(new Error('未登录'));
        return presignGet(parsed.ossKey, token);
      }).then((url: string) => {
        if (image.removed || this.composerImages.indexOf(image) < 0) return;
        image.uri = url;
        this.syncComposerImages();
      }).catch(() => {
        // 预览失败不影响引用再次发送。
      });
    }
  }

  private applyPendingEditRuntime(deviceId: string, agent: NewAgentKind, consume: boolean): void {
    const draft = this.pendingEditDraft;
    if (draft === null || draft.deviceId !== deviceId
      || this.editDraftAgentKind(draft.agentKind) !== agent) return;
    this.model = draft.model;
    this.providerId = draft.providerId;
    this.effort = draft.effort;
    this.permissionMode = draft.permissionMode;
    this.permissionModeBeforePlan = draft.permissionMode;
    this.planModeEnabled = draft.planModeEnabled;
    this.fastMode = draft.fastMode;
    if (consume) this.pendingEditDraft = null;
  }

  private refreshDevices(): void {
    this.devices = AppServices.instance.tasks.deviceList;
    this.taskRevision += 1;
    let nextDeviceId = this.selectedDeviceId;
    if (nextDeviceId.length === 0 && this.routeDeviceId.length > 0) {
      nextDeviceId = this.routeDeviceId;
    }
    if (!this.canCreateOnDevice(nextDeviceId)) {
      nextDeviceId = '';
      for (let i = 0; i < this.devices.length; i++) {
        if (this.canCreateOnDevice(this.devices[i].deviceId)) {
          nextDeviceId = this.devices[i].deviceId;
          break;
        }
      }
    }
    if (nextDeviceId !== this.selectedDeviceId) {
      this.selectedDeviceId = nextDeviceId;
      if (!this.agentTouched) {
        const sessions = AppServices.instance.tasks.getSessions(nextDeviceId);
        if (sessions.length > 0) {
          this.selectedAgentKind = newAgentKindFromSession(sessions[0]);
        }
      }
      void this.loadRuntimeDefaults(nextDeviceId, this.selectedAgentKind);
    } else if (nextDeviceId.length > 0
      && !this.composerToolbarReady && !this.runtimeToolbarLoadActive) {
      // 返回栈可能复用页面实例；离页时已失效旧请求，再进入后需要为同一设备重新加载。
      void this.loadRuntimeDefaults(nextDeviceId, this.selectedAgentKind);
    }
  }

  private canCreateOnDevice(deviceId: string): boolean {
    if (deviceId.length === 0) return false;
    for (let i = 0; i < this.devices.length; i++) {
      const device = this.devices[i];
      if (device.deviceId === deviceId) return device.online && device.remoteControlEnabled;
    }
    return false;
  }

  private recentProjects(): RecentProject[] {
    // 与 Mobile 新建页一致：项目目录来自当前被控电脑最近使用过的任务。
    const sessions = AppServices.instance.tasks.getSessions(this.selectedDeviceId);
    const out: RecentProject[] = [];
    for (let i = 0; i < sessions.length; i++) {
      const session = sessions[i];
      const path = session.workingDir.trim();
      if (session.status === 'deleted' || session.workspaceKind === 'dialogue' || path.length === 0) continue;
      let found = false;
      for (let j = 0; j < out.length; j++) {
        if (out[j].path === path) {
          found = true;
          if (session.updatedAt > out[j].lastActivityAt) out[j].lastActivityAt = session.updatedAt;
          break;
        }
      }
      if (!found) {
        const project = new RecentProject();
        project.path = path;
        project.title = directoryTitle(path);
        project.lastActivityAt = session.updatedAt;
        out.push(project);
      }
    }
    out.sort((a: RecentProject, b: RecentProject) => {
      if (a.lastActivityAt === b.lastActivityAt) return a.path < b.path ? -1 : 1;
      return a.lastActivityAt > b.lastActivityAt ? -1 : 1;
    });
    return out.slice(0, 8);
  }

  private selectAgent(kind: NewAgentKind): void {
    if (this.creating) return;
    this.agentTouched = true;
    this.selectedAgentKind = kind;
    this.selectorOpen = '';
    this.error = '';
    void this.loadRuntimeDefaults(this.selectedDeviceId, kind);
  }

  private selectModel(option: RuntimeModelOption): void {
    if (this.creating) return;
    this.runtimeModelTouchedGeneration = this.runtimeLoadGeneration;
    // 选模型时会一起 reconcile effort / Fast，后续异步目录回包也不能把它们改回默认值。
    this.runtimeEffortTouchedGeneration = this.runtimeLoadGeneration;
    this.runtimeFastTouchedGeneration = this.runtimeLoadGeneration;
    const nextEffort = reconcileModelEffort(option, this.modelEffortForRow(option));
    const nextFastMode = this.modelFastForRow(option);
    this.model = option.id;
    this.providerId = option.providerId;
    this.effort = nextEffort;
    this.fastMode = nextFastMode;
    this.selectorOpen = '';
    this.error = '';
  }

  private togglePlanMode(): void {
    if (this.creating || !this.planModeSupported) return;
    this.runtimePlanTouchedGeneration = this.runtimeLoadGeneration;
    if (!this.planModeEnabled) {
      this.permissionModeBeforePlan = this.permissionMode;
    }
    this.planModeEnabled = !this.planModeEnabled;
  }

  private toggleFastMode(): void {
    const model = this.findModelOption(this.model, this.providerId);
    if (!this.fastModeCapability || model === undefined || !model.supportsFastMode || this.creating) return;
    this.runtimeFastTouchedGeneration = this.runtimeLoadGeneration;
    this.fastMode = !this.fastMode;
  }

  private selectDialogue(): void {
    this.workspaceKind = 'dialogue';
    this.workingDir = '';
    this.selectorOpen = '';
    this.browseOpen = false;
    this.showHiddenDirectories = false;
  }

  private selectProject(path: string): void {
    const value = path.trim();
    if (value.length === 0) return;
    this.workspaceKind = 'project';
    this.workingDir = value;
    this.selectorOpen = '';
    this.browseOpen = false;
    this.browseError = '';
    this.showHiddenDirectories = false;
  }

  private toggleSelector(name: string): void {
    if (this.creating) return;
    this.browseOpen = false;
    this.browseError = '';
    this.selectorOpen = this.selectorOpen === name ? '' : name;
  }

  /** Composer 的上下文 Sheet 与详情页同层级：图片、计划和运行时设置都从这里进入。 */
  private openContextSheet(page: string = 'main'): void {
    if (this.creating || this.pickingImages) return;
    this.selectorOpen = '';
    this.contextSheetPage = page;
    this.contextSelectedUris = [];
    try {
      this.recentPickerController.setData(DataType.SET_SELECTED_URIS, []);
    } catch (e) {
      // Picker 尚未挂载时无需清理；下一次打开仍从空选择开始。
    }
    if (page === 'model') this.composerSurfaceVisible = true;
    this.getUIContext().getFocusController().clearFocus();
    this.contextSheetOpen = true;
  }

  private openComposerControlPopup(page: string): void {
    if (this.creating || this.pickingImages) return;
    this.selectorOpen = '';
    this.contextSheetPage = page;
    this.composerBlurGeneration += 1;
    this.composerSurfaceVisible = true;
    this.modelEffortPickerKey = '';
    this.composerPopupRestoreFocus = this.composerFocused || this.keyboardHeight > 0;
    this.getUIContext().getFocusController().clearFocus();
    this.composerPermissionPopupOpen = page === 'permission';
    this.composerModelPopupOpen = page === 'model';
  }

  private dismissComposerControlPopup(page: string): void {
    if (page === 'permission') this.composerPermissionPopupOpen = false;
    if (page === 'model') {
      this.composerModelPopupOpen = false;
      this.modelEffortPickerKey = '';
    }
    if (!this.composerPopupRestoreFocus || !this.pageActive) return;
    this.composerPopupRestoreFocus = false;
    this.composerBlurGeneration += 1;
    this.composerSurfaceVisible = true;
    this.composerFocused = true;
    setTimeout(() => {
      if (!this.pageActive || this.composerPermissionPopupOpen
        || this.composerModelPopupOpen) return;
      try {
        this.getUIContext().getFocusController().requestFocus('new-session-composer-input');
      } catch (_err) {
        // 页面退场时保持状态收口，不向已销毁的输入节点请求焦点。
      }
    }, 0);
  }

  private handleComposerFocusChange(focused: boolean): void {
    this.composerFocused = focused;
    if (focused) {
      this.composerBlurGeneration += 1;
      this.composerSurfaceVisible = true;
      return;
    }
    const generation = ++this.composerBlurGeneration;
    setTimeout(() => {
      if (generation !== this.composerBlurGeneration || this.composerFocused
        || this.contextSheetOpen || this.composerPermissionPopupOpen
        || this.composerModelPopupOpen) return;
      if (this.composerImages.length > 0 || this.composerFiles.length > 0) return;
      this.composerSurfaceVisible = false;
    }, 0);
  }

  private returnToComposerAfterModelSheet(): void {
    const popupWasOpen = this.composerPermissionPopupOpen || this.composerModelPopupOpen;
    this.restoreComposerFocusOnSheetDisappear = !popupWasOpen;
    this.contextSheetOpen = false;
    this.composerPermissionPopupOpen = false;
    this.composerModelPopupOpen = false;
    this.modelEffortPickerKey = '';
    this.composerBlurGeneration += 1;
    this.composerSurfaceVisible = true;
    this.composerFocused = false;
  }

  private restoreComposerFocusAfterSheetDisappear(): void {
    if (!this.restoreComposerFocusOnSheetDisappear || !this.pageActive) return;
    this.restoreComposerFocusOnSheetDisappear = false;
    this.composerBlurGeneration += 1;
    this.composerSurfaceVisible = true;
    this.composerFocused = true;
    try {
      this.getUIContext().getFocusController().requestFocus('new-session-composer-input');
    } catch (e) {
      // 页面退场或输入节点尚未恢复时保持展开态，用户仍可直接点击继续输入。
    }
  }

  private remainingImageSlots(): number {
    return Math.max(0, MAX_COMPOSER_IMAGES - this.composerImages.length);
  }

  private selectRecentImage(uri: string): void {
    if (uri.length === 0 || this.contextSelectedUris.includes(uri)) return;
    if (this.contextSelectedUris.length >= this.remainingImageSlots()) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
      return;
    }
    this.contextSelectedUris = this.contextSelectedUris.concat([uri]);
  }

  private deselectRecentImage(uri: string): void {
    this.contextSelectedUris = this.contextSelectedUris.filter((value: string) => value !== uri);
  }

  private addRecentSelection(): void {
    const uris = this.contextSelectedUris.slice();
    this.contextSheetOpen = false;
    this.contextSelectedUris = [];
    this.enqueueImageUris(uris);
  }

  private pickImages(): void {
    if (this.pickingImages || this.creating) return;
    const remaining = this.remainingImageSlots();
    if (remaining <= 0) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
      return;
    }
    this.contextSheetOpen = false;
    this.pickingImages = true;
    setTimeout(() => {
      pickImageUris(remaining).then((uris: string[]) => {
        this.pickingImages = false;
        this.enqueueImageUris(uris);
      }).catch(() => {
        this.pickingImages = false;
      });
    }, 160);
  }

  private pickScreenshots(): void {
    if (this.pickingImages || this.creating) return;
    const remaining = this.remainingImageSlots();
    if (remaining <= 0) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
      return;
    }
    this.contextSheetOpen = false;
    this.pickingImages = true;
    const context = getContext(this) as common.UIAbilityContext;
    setTimeout(() => {
      pickScreenshotUris(context, remaining).then((uris: string[]) => {
        this.pickingImages = false;
        this.enqueueImageUris(uris);
      }).catch(() => {
        this.pickingImages = false;
        promptAction.showToast({ message: '无法打开截图选择器' });
      });
    }, 160);
  }

  private takePhoto(): void {
    if (this.pickingImages || this.creating || this.remainingImageSlots() <= 0) {
      if (this.remainingImageSlots() <= 0) {
        promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
      }
      return;
    }
    this.contextSheetOpen = false;
    this.pickingImages = true;
    const context = getContext(this) as common.UIAbilityContext;
    setTimeout(() => {
      takePhotoUri(context).then((uri: string) => {
        this.pickingImages = false;
        if (uri.length > 0) this.enqueueImageUris([uri]);
      }).catch(() => {
        this.pickingImages = false;
        promptAction.showToast({ message: '无法打开相机' });
      });
    }, 160);
  }

  private enqueueImageUris(uris: string[]): void {
    let remaining = this.remainingImageSlots();
    let accepted = 0;
    for (let i = 0; i < uris.length && remaining > 0; i++) {
      const uri = uris[i];
      let duplicate = false;
      for (let j = 0; j < this.composerImages.length; j++) {
        if (this.composerImages[j].uri === uri) {
          duplicate = true;
          break;
        }
      }
      if (duplicate) continue;
      this.uploadComposerImage(uri, this.composerImages.length + accepted);
      accepted += 1;
      remaining -= 1;
    }
    if (uris.length > accepted && remaining <= 0) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
    }
  }

  private uploadComposerImage(uri: string, index: number): void {
    const image = new ComposerImage();
    image.uri = uri;
    image.name = `image-${index + 1}`;
    this.composerImages = this.composerImages.concat([image]);
    this.startComposerImageUpload(image, index);
  }

  private isCurrentComposerImageUpload(image: ComposerImage, revision: number): boolean {
    return isUploadRevisionCurrent(
      image.uploadRevision, revision, image.removed, this.composerImages.indexOf(image) >= 0);
  }

  private startComposerImageUpload(
    image: ComposerImage,
    index: number,
    preserveName: boolean = false,
  ): void {
    const previousName = preserveName ? image.name : '';
    image.removed = false;
    image.status = 'uploading';
    image.ref = null;
    image.uploadRevision += 1;
    const revision = image.uploadRevision;
    this.syncComposerImages();
    buildImageCandidate(image.uri, index).then((candidate) => {
      if (!this.isCurrentComposerImageUpload(image, revision)) {
        throw new Error('stale image upload');
      }
      if (previousName.length > 0) candidate.name = previousName;
      image.name = candidate.name;
      return AppServices.instance.auth.getAccessToken().then((token: string | null) => {
        if (!this.isCurrentComposerImageUpload(image, revision)) {
          throw new Error('stale image upload');
        }
        if (token === null || token.length === 0) throw new Error('未登录');
        return uploadImage(candidate, token);
      });
    }).then((ref: RemoteImageRef) => {
      if (!this.isCurrentComposerImageUpload(image, revision)) {
        this.recycleComposerImageRef(ref);
        return;
      }
      image.ref = ref;
      if (ref.originalName.length > 0) image.name = ref.originalName;
      image.status = 'ready';
      this.syncComposerImages();
    }).catch(() => {
      if (this.isCurrentComposerImageUpload(image, revision)) {
        image.status = 'failed';
        this.syncComposerImages();
      }
    });
  }

  private syncComposerImages(): void {
    this.composerImages = this.composerImages.slice();
  }

  private removeComposerImage(localId: string): void {
    if (this.creating) return;
    const image = this.composerImages.find((item: ComposerImage) => item.localId === localId);
    if (image === undefined) return;
    image.uploadRevision += 1;
    image.removed = true;
    this.composerImages = this.composerImages.filter(
      (item: ComposerImage) => item.localId !== localId);
    this.recycleComposerImage(image);
  }

  private recycleComposerImage(image: ComposerImage): void {
    if (image.ref !== null) this.recycleComposerImageRef(image.ref);
  }

  private recycleComposerImageRef(ref: RemoteImageRef): void {
    const parsed = parseAttachmentOssRef(ref.url);
    if (parsed === null || parsed.ossKey.length === 0) return;
    void AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token !== null && token.length > 0) return deleteUpload(parsed.ossKey, token);
      return Promise.resolve();
    }).catch(() => {
      // 删除中转对象是 best-effort，不阻断 Composer 操作。
    });
  }

  private retryComposerImage(localId: string): void {
    if (this.creating) return;
    const index = this.composerImages.findIndex(
      (item: ComposerImage) => item.localId === localId);
    if (index < 0) return;
    const image = this.composerImages[index];
    if (image.removed || image.status !== 'failed') return;
    this.startComposerImageUpload(image, index, true);
  }

  private hasComposerContent(): boolean {
    return this.input.trim().length > 0
      || this.composerImages.length > 0 || this.composerFiles.length > 0;
  }

  private readyComposerImages(): RemoteImageRef[] {
    const ready: RemoteImageRef[] = [];
    for (let i = 0; i < this.composerImages.length; i++) {
      const image = this.composerImages[i];
      if (image.status === 'ready' && image.ref !== null) ready.push(image.ref);
    }
    return ready;
  }

  private readyComposerFiles(): RemoteSerializedAttachment[] {
    const ready: RemoteSerializedAttachment[] = [];
    for (let i = 0; i < this.composerFiles.length; i++) {
      const file = this.composerFiles[i];
      if (file.status === 'ready' && file.ref !== null) ready.push(file.ref);
    }
    return ready;
  }

  private canSend(): boolean {
    if (this.creating) return false;
    let readyCount = 0;
    for (let i = 0; i < this.composerImages.length; i++) {
      const image = this.composerImages[i];
      if (image.status !== 'ready' || image.ref === null) return false;
      readyCount += 1;
    }
    for (let i = 0; i < this.composerFiles.length; i++) {
      const file = this.composerFiles[i];
      if (file.status !== 'ready' || file.ref === null) return false;
      readyCount += 1;
    }
    return this.input.trim().length > 0 || readyCount > 0;
  }

  private removeComposerFile(localId: string): void {
    if (this.creating) return;
    const file = this.composerFiles.find((item: ComposerFile) => item.localId === localId);
    if (file === undefined) return;
    file.uploadRevision += 1;
    file.removed = true;
    this.composerFiles = this.composerFiles.filter(
      (item: ComposerFile) => item.localId !== localId);
    if (file.ref === null) return;
    this.recycleComposerFileRef(file.ref);
  }

  private recycleComposerFileRef(ref: RemoteSerializedAttachment): void {
    const parsed = parseAttachmentOssRef(ref.path);
    if (parsed === null || parsed.ossKey.length === 0) return;
    void AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token !== null && token.length > 0) return deleteUpload(parsed.ossKey, token);
      return Promise.resolve();
    }).catch(() => {});
  }

  private resetRuntimeDefaults(agent: NewAgentKind): void {
    this.model = fallbackModel(agent);
    this.providerId = '';
    this.effort = 'medium';
    this.permissionMode = 'auto';
    this.permissionModeBeforePlan = 'auto';
    this.planModeSupported = false;
    this.planModeNative = false;
    this.planModeEnabled = false;
    this.fastMode = false;
    this.modelOptions = [];
    this.providerModelOptions = [];
    this.providerModelAgent = '';
    this.modelVisibilityOverrides = new Map();
    this.effortOptions = [];
    this.permissionOptions = [];
    this.fastModeCapability = false;
  }

  private parseRuntimeChoices(value: Object | undefined, permission: boolean): RuntimeChoiceOption[] {
    const out: RuntimeChoiceOption[] = [];
    if (!Array.isArray(value)) return out;
    const rows = value as Object[];
    for (let i = 0; i < rows.length; i++) {
      const raw = rows[i];
      let id = '';
      let label = '';
      let description = '';
      if (typeof raw === 'string') {
        id = raw as string;
      } else if (raw !== null && typeof raw === 'object' && !Array.isArray(raw)) {
        const record = raw as Record<string, Object>;
        id = readStr(record, 'id');
        label = readStr(record, 'displayName') || readStr(record, 'name');
        description = readStr(record, 'description');
      }
      if (id.length === 0 || (permission && id === 'plan')) continue;
      const option = new RuntimeChoiceOption();
      option.id = id;
      option.label = permission ? permissionModeLabel(id, label) : effortLevelLabel(id, label);
      option.description = permission ? permissionModeDescription(id, description) : description;
      out.push(option);
    }
    return out;
  }

  /**
   * 新会话也使用正常会话的 provider:list 模型目录；availableModels 仅作为旧桌面回退。
   * 同名模型必须保留 providerId，否则新任务可能被路由到错误的凭证来源。
   */
  private parseProviderModelOptions(value: Object | undefined, agent: NewAgentKind): RuntimeModelOption[] {
    const selected = this.latestSessionForAgent(agent);
    return parseComposerProviderModelOptions(value, agent, this.modelVisibilityOverrides,
      selected === undefined ? undefined : { model: selected.model, providerId: selected.providerId });
  }

  private latestSessionForAgent(agent: NewAgentKind): RemoteSession | undefined {
    const sessions = AppServices.instance.tasks.getSessions(this.selectedDeviceId);
    let latest: RemoteSession | undefined = undefined;
    for (let i = 0; i < sessions.length; i++) {
      const session = sessions[i];
      if (session.status === 'deleted' || newAgentKindFromSession(session) !== agent) continue;
      if (latest === undefined || session.updatedAt > latest.updatedAt) latest = session;
    }
    return latest;
  }

  private async loadProviderModelOptions(
    agent: NewAgentKind,
    deviceId: string,
    generation: number,
  ): Promise<void> {
    try {
      await AppServices.instance.openLink(deviceId);
      if (generation !== this.runtimeLoadGeneration || deviceId !== this.selectedDeviceId) return;
      const options = new DlInvokeOptions();
      options.channel = 'maker:provider:list';
      const request = new ProviderListOptions();
      request.capabilities = ['provider-logo-kinds-v2'];
      options.args = [request];
      const envelope = await AppServices.instance.client.invoke(deviceId, options);
      if (generation !== this.runtimeLoadGeneration || deviceId !== this.selectedDeviceId) return;
      const result = unwrapInvokeResult(envelope);
      const providerOptions = this.parseProviderModelOptions(result, agent);
      this.providerModelOptions = providerOptions;
      this.providerModelAgent = providerOptions.length > 0 ? agent : '';
      if (result !== undefined && result !== null && typeof result === 'object' && !Array.isArray(result)) {
        this.modelVisibilityOverrides = parseModelVisibilityOverrides(result);
        // Visibility overrides are part of the provider response. Reparse once so a
        // hidden model cannot remain in the list produced before the map was loaded.
        this.providerModelOptions = this.parseProviderModelOptions(result, agent);
        this.providerModelAgent = this.providerModelOptions.length > 0 ? agent : '';
      }
    } catch (e) {
      if (generation !== this.runtimeLoadGeneration || deviceId !== this.selectedDeviceId) return;
      this.providerModelOptions = [];
      this.providerModelAgent = '';
      this.modelVisibilityOverrides = new Map();
    }
  }

  private capabilityHasNativePlan(capabilities: Record<string, Object>): boolean {
    return readBool(readObj(capabilities, 'planMode'), 'supported', false);
  }

  private capabilityHasLegacyPlan(capabilities: Record<string, Object>): boolean {
    const modes = capabilities['permissionModes'];
    if (!Array.isArray(modes)) return false;
    const rows = modes as Object[];
    for (let i = 0; i < rows.length; i++) {
      if (rows[i] === 'plan') return true;
      if (rows[i] !== null && typeof rows[i] === 'object' && !Array.isArray(rows[i])
        && readStr(rows[i] as Record<string, Object>, 'id') === 'plan') return true;
    }
    return false;
  }

  private findModelOption(modelId: string, preferredProviderId: string = ''): RuntimeModelOption | undefined {
    const source = this.visibleModelOptions();
    if (preferredProviderId.length > 0) {
      for (let i = 0; i < source.length; i++) {
        if (source[i].id === modelId && source[i].providerId === preferredProviderId) return source[i];
      }
    }
    for (let i = 0; i < source.length; i++) {
      if (source[i].id === modelId) return source[i];
    }
    return undefined;
  }

  private visibleModelOptions(): RuntimeModelOption[] {
    if (this.providerModelOptions.length > 0 && this.providerModelAgent === this.selectedAgentKind) {
      return this.providerModelOptions;
    }
    return this.modelOptions;
  }

  private modelOptionKey(option: RuntimeModelOption): string {
    return composerModelKey(option);
  }

  private modelRuntimeKey(option: RuntimeModelOption): string {
    return `${this.selectedAgentKind}:${this.modelOptionKey(option)}`;
  }

  private modelOptionIsCurrent(option: RuntimeModelOption): boolean {
    return option.id === this.model && option.providerId === this.providerId;
  }

  private modelEffortForRow(option: RuntimeModelOption): string {
    if (this.modelOptionIsCurrent(option) && this.effort.length > 0) return this.effort;
    const remembered = this.modelEffortMemory.get(this.modelRuntimeKey(option));
    if (remembered !== undefined && this.modelSupportsEffort(option, remembered)) return remembered;
    if (option.defaultEffort.length > 0) return option.defaultEffort;
    return option.efforts.length > 0 ? option.efforts[0] : '';
  }

  private modelFastForRow(option: RuntimeModelOption): boolean {
    if (!this.fastModeCapability || !option.supportsFastMode) return false;
    if (this.modelOptionIsCurrent(option)) return this.fastMode;
    return this.modelFastMemory.get(this.modelRuntimeKey(option)) ?? false;
  }

  private modelEffortMenuItems(option: RuntimeModelOption): MenuElement[] {
    const items: MenuElement[] = [];
    for (let i = 0; i < option.efforts.length; i++) {
      const effort = option.efforts[i];
      items.push({
        value: this.modelEffortLabel(option, effort),
        action: (): void => this.selectModelRowEffort(option, effort),
      });
    }
    return items;
  }

  private selectModelRowEffort(option: RuntimeModelOption, effort: string): void {
    if (this.creating) return;
    const next = new Map(this.modelEffortMemory);
    next.set(this.modelRuntimeKey(option), effort);
    this.modelEffortMemory = next;
    if (this.modelOptionIsCurrent(option)) {
      this.runtimeEffortTouchedGeneration = this.runtimeLoadGeneration;
      this.effort = effort;
    }
    this.error = '';
  }

  private setModelRowFast(option: RuntimeModelOption, enabled: boolean): void {
    if (this.creating || !this.fastModeCapability || !option.supportsFastMode) return;
    const next = new Map(this.modelFastMemory);
    next.set(this.modelRuntimeKey(option), enabled);
    this.modelFastMemory = next;
    if (this.modelOptionIsCurrent(option)) {
      this.runtimeFastTouchedGeneration = this.runtimeLoadGeneration;
      this.fastMode = enabled;
    }
    this.error = '';
  }

  private choiceExists(options: RuntimeChoiceOption[], id: string): boolean {
    for (let i = 0; i < options.length; i++) {
      if (options[i].id === id) return true;
    }
    return false;
  }

  private modelSupportsEffort(option: RuntimeModelOption, effort: string): boolean {
    if (option.efforts.length === 0) return true;
    for (let i = 0; i < option.efforts.length; i++) {
      if (option.efforts[i] === effort) return true;
    }
    return false;
  }

  private modelEffortLabel(option: RuntimeModelOption, effort: string): string {
    const custom = option.effortDisplayNames[effort];
    return custom !== undefined && custom.length > 0 ? custom : effortLevelLabel(effort, effort);
  }

  private currentEffortOptions(): RuntimeChoiceOption[] {
    const model = this.findModelOption(this.model, this.providerId);
    if (model === undefined || model.efforts.length === 0) return this.effortOptions;
    const out: RuntimeChoiceOption[] = [];
    for (let i = 0; i < model.efforts.length; i++) {
      const id = model.efforts[i];
      let matched: RuntimeChoiceOption | undefined;
      for (let j = 0; j < this.effortOptions.length; j++) {
        if (this.effortOptions[j].id === id) {
          matched = this.effortOptions[j];
          break;
        }
      }
      const option = new RuntimeChoiceOption();
      option.id = id;
      option.label = matched === undefined ? this.modelEffortLabel(model, id) : this.modelEffortLabel(model, matched.id);
      option.description = matched?.description ?? '';
      out.push(option);
    }
    return out;
  }

  private currentModelLabel(): string {
    const model = this.findModelOption(this.model, this.providerId);
    return model === undefined ? (this.model || '选择模型') : model.label;
  }

  private currentEffortLabel(): string {
    const model = this.findModelOption(this.model, this.providerId);
    if (model !== undefined) return this.modelEffortLabel(model, this.effort);
    return this.effort.length > 0 ? effortLevelLabel(this.effort, this.effort) : '选择推理强度';
  }

  private currentPermissionModeLabel(): string {
    return selectedPermissionModeLabel(this.permissionOptions, this.permissionMode);
  }

  private currentModelSupportsFastMode(): boolean {
    const model = this.findModelOption(this.model, this.providerId);
    return this.fastModeCapability && model !== undefined && model.supportsFastMode;
  }

  private async loadRuntimeDefaults(deviceId: string, agent: NewAgentKind): Promise<void> {
    const generation = ++this.runtimeLoadGeneration;
    this.runtimeToolbarLoadActive = true;
    this.composerToolbarReady = false;
    if (deviceId.length === 0) {
      this.runtimeToolbarLoadActive = false;
      this.composerToolbarReady = true;
      return;
    }
    this.resetRuntimeDefaults(agent);
    // 编辑失败返回的新建草稿在能力目录加载期间也应保持可见，避免用户看到并操作到临时默认值。
    this.applyPendingEditRuntime(deviceId, agent, false);
    try {
      await AppServices.instance.openLink(deviceId);
      const options = new DlInvokeOptions();
      options.channel = 'maker:get-capabilities';
      options.args = [agent];
      const envelope = await AppServices.instance.client.invoke(deviceId, options);
      const result = unwrapInvokeResult(envelope);
      if (generation !== this.runtimeLoadGeneration
        || result === undefined || typeof result !== 'object' || Array.isArray(result)) return;
      const capabilities = result as Record<string, Object>;
      this.modelOptions = parseModelOptions(capabilities['availableModels']);
      this.effortOptions = this.parseRuntimeChoices(capabilities['effortLevels'], false);
      this.permissionOptions = this.parseRuntimeChoices(capabilities['permissionModes'], true);
      this.fastModeCapability = readBool(capabilities, 'hasFastMode', false);

      this.planModeNative = this.capabilityHasNativePlan(capabilities);
      this.planModeSupported = this.planModeNative || this.capabilityHasLegacyPlan(capabilities);
      await this.loadProviderModelOptions(agent, deviceId, generation);
      if (generation !== this.runtimeLoadGeneration) return;

      const recent = this.latestSessionForAgent(agent);
      const modelTouched = this.runtimeModelTouchedGeneration === generation;
      const effortTouched = this.runtimeEffortTouchedGeneration === generation;
      const permissionTouched = this.runtimePermissionTouchedGeneration === generation;
      const planTouched = this.runtimePlanTouchedGeneration === generation;
      const fastTouched = this.runtimeFastTouchedGeneration === generation;
      if (!planTouched) {
        this.planModeEnabled = recent?.planModeEnabled === true || recent?.permissionMode === 'plan';
      }
      if (!permissionTouched
        && recent !== undefined && recent.permissionMode.length > 0 && recent.permissionMode !== 'plan') {
        this.permissionMode = recent.permissionMode;
        this.permissionModeBeforePlan = recent.permissionMode;
      }
      const source = this.visibleModelOptions();
      let selectedModel: RuntimeModelOption | undefined = undefined;
      if (!modelTouched) {
        if (recent !== undefined && recent.model.length > 0) {
          selectedModel = this.findModelOption(recent.model, recent.providerId);
        }
        if (selectedModel === undefined) {
          const fallback = fallbackModel(agent);
          selectedModel = this.findModelOption(fallback);
        }
        if (selectedModel === undefined && source.length > 0) selectedModel = source[0];
        if (selectedModel !== undefined) {
          this.model = selectedModel.id;
          this.providerId = selectedModel.providerId;
        }
      }
      if (!effortTouched) {
        if (selectedModel !== undefined) {
          this.effort = reconcileModelEffort(selectedModel, this.effort);
        }
        const currentModel = this.findModelOption(this.model, this.providerId);
        const effortValid = currentModel === undefined
          ? this.choiceExists(this.effortOptions, this.effort)
          : this.modelSupportsEffort(currentModel, this.effort)
            && (this.effortOptions.length === 0 || this.choiceExists(this.effortOptions, this.effort));
        if (this.effortOptions.length > 0 && !effortValid) {
          this.effort = this.effortOptions[0].id;
        }
      }
      if (!permissionTouched && this.permissionOptions.length > 0
        && !this.choiceExists(this.permissionOptions, this.permissionMode)) {
        this.permissionMode = this.choiceExists(this.permissionOptions, 'auto')
          ? 'auto' : this.permissionOptions[0].id;
        this.permissionModeBeforePlan = this.permissionMode;
      }
      if (!fastTouched) this.fastMode = false;
    } catch (e) {
      // 旧版本被控端可能没有 capabilities；内置默认仍可被 create-session 校验。
    } finally {
      if (generation === this.runtimeLoadGeneration) {
        const runtimeTouched = this.runtimeModelTouchedGeneration === generation
          || this.runtimeEffortTouchedGeneration === generation
          || this.runtimePermissionTouchedGeneration === generation
          || this.runtimePlanTouchedGeneration === generation
          || this.runtimeFastTouchedGeneration === generation;
        if (runtimeTouched) {
          // 用户已在加载窗口内编辑草稿，旧的失败编辑草稿不能在下一次加载时回写覆盖它。
          this.pendingEditDraft = null;
        } else {
          this.applyPendingEditRuntime(deviceId, agent, true);
        }
        this.runtimeToolbarLoadActive = false;
        this.composerToolbarReady = true;
      }
    }
  }

  private async loadBrowsePath(targetPath: string): Promise<void> {
    if (this.selectedDeviceId.length === 0 || this.creating) return;
    this.browseLoading = true;
    this.browseError = '';
    try {
      await AppServices.instance.openLink(this.selectedDeviceId);
      const options = new DlInvokeOptions();
      options.channel = DlChannels.FS_LIST_DIR;
      const request: Record<string, Object> = {};
      request['path'] = targetPath.trim().length > 0 ? targetPath.trim() : '~';
      options.args = [request];
      const envelope = await AppServices.instance.client.invoke(this.selectedDeviceId, options);
      const result = unwrapInvokeResult(envelope);
      if (result === undefined || typeof result !== 'object' || Array.isArray(result)) {
        throw new Error('目录返回格式无效');
      }
      const record = result as Record<string, Object>;
      this.browsePath = readStr(record, 'resolvedPath');
      this.browseParent = readStr(record, 'parent');
      this.browseEntries = this.parseDirectories(record['entries']);
    } catch (e) {
      this.browseEntries = [];
      this.browseError = e instanceof Error ? e.message : '无法读取远端目录';
    } finally {
      this.browseLoading = false;
    }
  }

  private parseDirectories(value: Object | undefined): RemoteDirectory[] {
    const out: RemoteDirectory[] = [];
    if (!Array.isArray(value)) return out;
    const rows = value as Object[];
    for (let i = 0; i < rows.length; i++) {
      const raw = rows[i];
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) continue;
      const record = raw as Record<string, Object>;
      const path = readStr(record, 'path');
      const name = readStr(record, 'name');
      if (path.length === 0 || name.length === 0) continue;
      const entry = new RemoteDirectory();
      entry.path = path;
      entry.name = name;
      entry.kind = readStr(record, 'kind') || 'dir';
      out.push(entry);
    }
    return out;
  }

  private visibleBrowseEntries(): RemoteDirectory[] {
    if (this.showHiddenDirectories) return this.browseEntries;
    return this.browseEntries.filter((entry: RemoteDirectory) => !entry.name.startsWith('.'));
  }

  private openProjectBrowse(): void {
    if (this.selectedDeviceId.length === 0) {
      promptAction.showToast({ message: '请先选择一台在线电脑' });
      return;
    }
    this.workspaceKind = 'project';
    this.selectorOpen = '';
    this.browseOpen = true;
    this.showHiddenDirectories = false;
    void this.loadBrowsePath(this.workingDir.trim() || '~');
  }

  private selectCurrentBrowsePath(): void {
    if (this.browsePath.length > 0) this.selectProject(this.browsePath);
  }

  private createOptions(sessionId: string = ''): Record<string, Object> {
    const options: Record<string, Object> = {};
    options['agentKind'] = this.selectedAgentKind;
    options['workspaceKind'] = this.workspaceKind;
    options['model'] = this.model.trim() || fallbackModel(this.selectedAgentKind);
    options['permissionMode'] = !this.planModeNative && this.planModeEnabled
      ? 'plan' : this.permissionMode;
    options['planMode'] = this.planModeNative && this.planModeEnabled;
    options['fastMode'] = this.fastMode;
    if (this.providerId.trim().length > 0) options['providerId'] = this.providerId.trim();
    if (this.effort.trim().length > 0) options['effort'] = this.effort.trim();
    if (this.workspaceKind === 'project') options['workingDir'] = this.workingDir.trim();
    if (sessionId.length > 0) options['id'] = sessionId;
    return options;
  }

  private buildOptimisticSession(sessionId: string, text: string): RemoteSession {
    const session = new RemoteSession();
    session.id = sessionId;
    session.workspaceKind = this.workspaceKind;
    session.workingDir = this.workspaceKind === 'project' ? this.workingDir.trim() : '';
    session.model = this.model.trim() || fallbackModel(this.selectedAgentKind);
    session.providerId = this.providerId.trim();
    session.effort = this.effort.trim();
    session.permissionMode = !this.planModeNative && this.planModeEnabled ? 'plan' : this.permissionMode;
    session.planModeEnabled = this.planModeEnabled;
    session.fastMode = this.fastMode;
    session.agentKind = this.selectedAgentKind === 'claude-code' ? 'cc' : this.selectedAgentKind;
    session.status = 'active';
    session.pendingLocalCreation = true;
    if (text.length > 0) {
      session.title = normalizeAutoTitle(text);
      session.preview = text;
    }
    const now = new Date().toISOString();
    session.createdAt = now;
    session.updatedAt = now;
    session.userSendAt = now;
    return session;
  }

  private async send(): Promise<void> {
    const text = this.input.trim();
    if (this.creating) return;
    let uploading = false;
    let failed = false;
    for (let i = 0; i < this.composerImages.length; i++) {
      if (this.composerImages[i].status === 'uploading') uploading = true;
      if (this.composerImages[i].status === 'failed') failed = true;
    }
    if (uploading) {
      promptAction.showToast({ message: '图片上传中，请稍候' });
      return;
    }
    if (failed) {
      promptAction.showToast({ message: '请重试或移除上传失败的图片' });
      return;
    }
    const readyImages = this.readyComposerImages();
    const readyFiles = this.readyComposerFiles();
    if (text.length === 0 && readyImages.length === 0 && readyFiles.length === 0) return;
    if (!this.canCreateOnDevice(this.selectedDeviceId)) {
      this.error = '请选择一台在线且允许远程控制的电脑';
      return;
    }
    if (this.workspaceKind === 'project' && this.workingDir.trim().length === 0) {
      this.error = '请选择项目目录';
      this.selectorOpen = 'workspace';
      return;
    }
    this.creating = true;
    this.error = '';
    const sessionId = util.generateRandomUUID();
    const firstMessageClientId = util.generateRandomUUID();
    const params = new NewSessionCreationParams();
    params.deviceId = this.selectedDeviceId;
    params.session = this.buildOptimisticSession(sessionId, text);
    params.createOptions = this.createOptions(sessionId);
    params.firstMessageClientId = firstMessageClientId;
    params.firstMessageText = text;
    params.firstMessageImages = readyImages.slice();
    params.firstMessageFiles = readyFiles.slice();
    params.planModeArm = this.planModeNative && this.planModeEnabled;
    params.legacyPlanRestore = !this.planModeNative && this.planModeEnabled
      ? (this.permissionModeBeforePlan || this.permissionMode) : '';
    AppServices.instance.newSessionCreations.start(params);
    this.cancelNewSessionDraftCheckpoint();
    AppServices.instance.composerDrafts.clear(NEW_SESSION_COMPOSER_DRAFT_ID);
    this.attachmentsHandedOff = true;
    router.replaceUrl({
      url: 'pages/TaskPage',
      params: { deviceId: params.deviceId, sessionId: sessionId },
    });
  }

  private closeImagePreview(): void {
    uiAnimateFastState(this.getUIContext(), () => {
      this.previewImageUrl = '';
    });
  }

  build() {
    Column() {
      this.topBar()
      Column() {
        Column() {
          if (this.selectorOpen === 'agent') this.agentPanel()
          this.agentSelector()
          if (this.selectorOpen === 'workspace') this.workspacePanel()
          this.workspaceSelector()
          if (this.browseOpen) this.browsePanel()
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 8 })
        .layoutWeight(1)
        .justifyContent(FlexAlign.End)

        this.composer()
      }
      .width('100%')
      .layoutWeight(1)

      // 与任务详情 Composer 共用同一交互：ready 图片点击后进入全屏预览。
      if (this.previewImageUrl.length > 0) {
        Stack() {
          Image(this.previewImageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
          Button() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(uiFontSize(16))
              .fontColor([$r('app.color.chat_overlay_text')])
          }
          .type(ButtonType.Circle)
          .width(40)
          .height(40)
          .padding(0)
          .backgroundColor($r('app.color.overlay'))
          .clickEffect(UI_ICON_CLICK_EFFECT)
          .position({ x: 16, y: 48 })
          .onClick(() => this.closeImagePreview())
        }
        .width('100%')
        .height('100%')
        .position({ x: 0, y: 0 })
        .zIndex(99)
        .backgroundColor($r('app.color.chat_overlay_surface'))
        .transition(uiOverlayTransition())
        .onClick(() => this.closeImagePreview())
      }
    }
      .width('100%')
    .height('100%')
    .padding({ bottom: this.keyboardHeight })
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .bindSheet($$this.contextSheetOpen, this.contextSheet(), {
      detents: this.contextSheetPage === 'model'
        ? [420] : [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: this.contextSheetPage !== 'model',
      showClose: false,
      preferType: this.contextSheetPage === 'model' ? SheetType.CENTER : SheetType.BOTTOM,
      backgroundColor: $r('app.color.bg_card'),
      maskColor: $r('app.color.overlay'),
      onDisappear: (): void => this.restoreComposerFocusAfterSheetDisappear(),
    })
  }

  @Builder
  topBar() {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor([$r('app.color.text_primary')])
      }
      .type(ButtonType.Normal)
      .width(44)
      .height(44)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .onClick(() => router.back())
      if (this.creating) {
        LoadingProgress()
          .width(16)
          .height(16)
          .color($r('app.color.text_secondary'))
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
  }

  @Builder
  selectorIcon(mark: string) {
    Stack({ alignContent: Alignment.Center }) {
      Text(mark)
        .fontSize(mark === 'π' ? 18 : 9)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
    }
    .width(24)
    .height(24)
  }

  @Builder
  agentSelector() {
    Button() {
      Row({ space: 10 }) {
        this.selectorIcon(agentMark(this.selectedAgentKind))
        Text(agentLabel(this.selectedAgentKind))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(15)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width('100%')
    }
    .type(ButtonType.Normal)
    .width('100%')
    .height(42)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .enabled(!this.creating)
    .onClick(() => this.toggleSelector('agent'))
  }






  @Builder
  workspaceSelector() {
    Button() {
      Row({ space: 10 }) {
        Text(this.workspaceKind === 'dialogue' ? '◯' : '□')
          .fontSize(18)
          .fontColor($r('app.color.text_secondary'))
          .width(24)
        Text(this.workspaceKind === 'dialogue' ? '对话' : directoryTitle(this.workingDir))
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(15)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width('100%')
    }
    .type(ButtonType.Normal)
    .width('100%')
    .height(42)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .enabled(!this.creating)
    .onClick(() => this.toggleSelector('workspace'))
  }


  @Builder
  agentPanel() {
    Column() {
      ForEach(NEW_AGENT_OPTIONS, (kind: NewAgentKind) => {
        Row({ space: 10 }) {
          this.selectorIcon(agentMark(kind))
          Text(agentLabel(kind))
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          if (kind === this.selectedAgentKind) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(18)
              .fontColor([$r('app.color.text_primary')])
          }
        }
        .width('100%')
        .height(44)
        .padding({ left: 10, right: 10 })
        .onClick(() => this.selectAgent(kind))
      }, (kind: NewAgentKind) => `new-agent:${kind}`)
    }
    .width('100%')
    .padding(6)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(14)
  }

  @Builder
  workspacePanel() {
    Column() {
      Row({ space: 10 }) {
        Text('◯')
          .fontSize(18)
          .fontColor($r('app.color.text_secondary'))
          .width(24)
        Text('对话')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        if (this.workspaceKind === 'dialogue') {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(18)
            .fontColor([$r('app.color.text_primary')])
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: 10, right: 10 })
      .onClick(() => this.selectDialogue())
      Divider()
        .color($r('app.color.border'))
        .strokeWidth(1)
        .margin({ left: 10, right: 10 })
      Scroll() {
        Column() {
          ForEach(this.recentProjects(), (project: RecentProject) => {
            this.recentProjectOption(project)
          }, (project: RecentProject) => `recent-project:${project.path}`)
          if (this.recentProjects().length === 0) {
            Text('还没有最近项目')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 10, right: 10, top: 10, bottom: 10 })
          }
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 260 })
      .scrollBar(BarState.Off)
      Divider()
        .color($r('app.color.border'))
        .strokeWidth(1)
        .margin({ left: 10, right: 10 })
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(19)
          .fontColor([$r('app.color.text_secondary')])
          .width(24)
        Text('选择其他项目文件夹')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)
      .padding({ left: 10, right: 10 })
      .onClick(() => this.openProjectBrowse())
    }
    .width('100%')
    .padding(6)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(14)
  }

  @Builder
  recentProjectOption(project: RecentProject) {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize(19)
        .fontColor([$r('app.color.text_secondary')])
        .width(24)
      Column({ space: 2 }) {
        Text(project.title)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(project.path)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      if (this.workspaceKind === 'project' && this.workingDir === project.path) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(18)
          .fontColor([$r('app.color.text_primary')])
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 10, right: 10 })
    .onClick(() => this.selectProject(project.path))
  }

  @Builder
  browsePanel() {
    Column() {
      Row({ space: 8 }) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(15)
            .fontColor([$r('app.color.text_secondary')])
        }
        .type(ButtonType.Normal)
        .width(32)
        .height(32)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .enabled(this.browseParent.length > 0 && !this.browseLoading)
        .onClick(() => void this.loadBrowsePath(this.browseParent))
        Text(this.browseLoading ? '读取目录…' : (this.browsePath || '远端项目目录'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.browseLoading) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color($r('app.color.text_secondary'))
        }
      }
      .width('100%')
      .height(36)
      Scroll() {
        Column() {
          ForEach(this.visibleBrowseEntries(), (entry: RemoteDirectory) => {
            this.browseEntry(entry)
          }, (entry: RemoteDirectory) => `browse:${entry.path}`)
          if (!this.browseLoading && this.browseError.length === 0 && this.visibleBrowseEntries().length === 0) {
            Text('这个目录下没有可显示的文件夹')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 10, right: 10, top: 12, bottom: 12 })
          }
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 220 })
      .scrollBar(BarState.Off)
      if (this.browseError.length > 0) {
        Text(this.browseError)
          .fontSize(12)
          .fontColor($r('app.color.danger'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      }
      Row({ space: 8 }) {
        Row({ space: 8 }) {
          Stack({ alignContent: Alignment.Center }) {
            if (this.showHiddenDirectories) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(12)
                .fontColor([$r('app.color.text_primary')])
            }
          }
          .width(18)
          .height(18)
          .border({ width: 1, color: $r('app.color.border') })
          .borderRadius(5)
          Text('显示隐藏文件夹')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .onClick(() => {
          this.showHiddenDirectories = !this.showHiddenDirectories;
        })
        Button('使用当前目录')
          .type(ButtonType.Normal)
          .height(30)
          .padding({ left: 10, right: 10 })
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.bg_chip'))
          .borderRadius(17)
          .enabled(this.browsePath.length > 0 && !this.browseLoading)
          .onClick(() => this.selectCurrentBrowsePath())
      }
      .width('100%')
      .height(38)
    }
    .width('100%')
    .padding(6)
    .backgroundColor($r('app.color.bg_card'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(14)
  }

  @Builder
  browseEntry(entry: RemoteDirectory) {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize(18)
        .fontColor([$r('app.color.text_secondary')])
        .width(24)
      Column({ space: 2 }) {
        Text(entry.name)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(entry.path)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(15)
          .fontColor([$r('app.color.text_secondary')])
      }
      .type(ButtonType.Normal)
      .width(30)
      .height(30)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .onClick(() => void this.loadBrowsePath(entry.path))
    }
    .width('100%')
    .height(46)
    .padding({ left: 10, right: 4 })
    .onClick(() => this.selectProject(entry.path))
  }

  @Builder
  contextRowIcon(symbol: Resource) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(symbol)
        .fontSize(uiFontSize(22))
        .fontColor([$r('app.color.text_primary')])
    }
    .width(36)
    .height(36)
    .borderRadius(8)
    .backgroundColor($r('app.color.bg_chip'))
  }

  @Builder
  contextActionRow(symbol: Resource, title: string, action: () => void) {
    Row({ space: 12 }) {
      this.contextRowIcon(symbol)
      Text(title)
        .fontSize(uiFontSize(16))
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(uiFontSize(14))
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .onClick(action)
  }

  private selectContextPermission(option: RuntimeChoiceOption): void {
    if (this.creating) return;
    if (option.id === 'bypassPermissions') {
      this.getUIContext().showAlertDialog({
        title: '确认完全访问',
        message: 'Cindy 将不再逐项询问工具操作。请仅在信任当前任务和项目时使用。',
        primaryButton: {
          value: '取消',
          action: () => {
          },
        },
        secondaryButton: {
          value: '继续',
          action: () => {
            this.runtimePermissionTouchedGeneration = this.runtimeLoadGeneration;
            this.permissionMode = option.id;
            this.permissionModeBeforePlan = option.id;
            this.contextSheetOpen = false;
            this.composerPermissionPopupOpen = false;
          },
        },
      });
      return;
    }
    this.runtimePermissionTouchedGeneration = this.runtimeLoadGeneration;
    this.permissionMode = option.id;
    this.permissionModeBeforePlan = option.id;
    this.contextSheetOpen = false;
    this.composerPermissionPopupOpen = false;
    this.error = '';
  }

  private selectContextModel(option: RuntimeModelOption): void {
    this.selectModel(option);
    this.returnToComposerAfterModelSheet();
  }

  @Builder
  contextMainView() {
    Scroll() {
      Column() {
        Column({ space: 6 }) {
          PhotoPickerComponent({
            pickerOptions: this.recentPickerOptions,
            pickerController: this.recentPickerController,
            onSelect: (uri: string): void => this.selectRecentImage(uri),
            onDeselect: (uri: string): void => this.deselectRecentImage(uri),
          })
            .width('100%')
            .height(104)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })

        if (this.contextSelectedUris.length > 0) {
          Button(`加入对话 (${this.contextSelectedUris.length})`)
            .width('calc(100% - 32vp)')
            .height(42)
            .fontSize(uiFontSize(15))
            .fontColor($r('app.color.chat_cta_text'))
            .backgroundColor($r('app.color.chat_cta'))
            .borderRadius(8)
            .margin({ left: 16, right: 16, bottom: 10 })
            .onClick(() => this.addRecentSelection())
        }

        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })

        if (this.planModeSupported) {
          Row({ space: 12 }) {
            this.contextRowIcon($r('sys.symbol.list_bullet'))
            Column({ space: 2 }) {
              Text('计划模式')
                .fontSize(uiFontSize(16))
                .fontColor($r('app.color.text_primary'))
              Text('先生成计划，确认后再执行')
                .fontSize(uiFontSize(12))
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.planModeEnabled })
              .enabled(!this.creating)
              .onChange(() => this.togglePlanMode())
          }
          .width('100%')
          .constraintSize({ minHeight: 64 })
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

          Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        }

        this.contextActionRow($r('sys.symbol.picture'), '照片', () => this.pickImages())
        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        this.contextActionRow($r('sys.symbol.snapshot'), '截图', () => this.pickScreenshots())
        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        this.contextActionRow($r('sys.symbol.camera'), '拍照', () => this.takePhoto())
      }
      .width('100%')
      .padding({ bottom: 24 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  permissionContextView() {
    Scroll() {
      Column({ space: 2 }) {
        ForEach(this.permissionOptions, (option: RuntimeChoiceOption) => {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.lock'))
              .fontSize(uiFontSize(16))
              .fontColor([$r('app.color.text_secondary')])
              .width(24)
            Column({ space: 2 }) {
              Text(option.label)
                .fontSize(uiFontSize(14))
                .fontWeight(option.id === this.permissionMode
                  ? FontWeight.Medium : FontWeight.Normal)
                .fontColor($r('app.color.text_primary'))
              if (option.description.length > 0) {
                Text(option.description)
                  .fontSize(uiFontSize(11))
                  .lineHeight(uiLineHeight(16))
                  .fontColor($r('app.color.text_tertiary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .layoutWeight(1)
            if (option.id === this.permissionMode) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(uiFontSize(18))
                .fontColor([$r('app.color.chat_cta')])
            }
          }
          .width('100%')
          .constraintSize({ minHeight: 52 })
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(option.id === this.permissionMode
            ? $r('app.color.bg_chip') : Color.Transparent)
          .borderRadius(UI_RADIUS_CONTROL)
          .opacity(this.creating ? 0.55 : 1)
          .clickEffect(UI_LIST_CLICK_EFFECT)
          .onClick(() => this.selectContextPermission(option))
        }, (option: RuntimeChoiceOption) => option.id)
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 14 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  contextModelRow(option: RuntimeModelOption) {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        Stack() {
          this.selectorIcon(agentMark(this.selectedAgentKind))
        }
        .onClick(() => this.selectContextModel(option))

        Column({ space: 1 }) {
          Row({ space: 2 }) {
            Text(option.label)
              .fontSize(uiFontSize(14))
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({
                maxWidth: this.fastModeCapability && option.supportsFastMode
                  ? (option.efforts.length > 0 ? '48%' : '70%')
                  : (option.efforts.length > 0 ? '70%' : '100%'),
              })
              .onClick(() => this.selectContextModel(option))
            Blank().layoutWeight(1)
          }
          .width('100%')
          if (option.providerName.length > 0 || option.description.length > 0) {
            Text(option.providerName.length > 0 ? option.providerName : option.description)
              .fontSize(uiFontSize(10))
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick(() => this.selectContextModel(option))
          }
        }
        .layoutWeight(1)
        .onClick(() => this.selectContextModel(option))

        if (option.efforts.length > 0) {
          Button() {
            Row({ space: 3 }) {
              Text(this.modelEffortLabel(option, this.modelEffortForRow(option)))
                .fontSize(uiFontSize(12))
                .fontColor($r('app.color.text_secondary'))
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(uiFontSize(9))
                .fontColor([$r('app.color.text_tertiary')])
            }
          }
          .height(28)
          .padding({ left: 5, right: 5 })
          .backgroundColor(Color.Transparent)
          .enabled(!this.creating)
          .accessibilityText(`${option.label}思考强度`)
          .onClick(() => {
            const key = this.modelOptionKey(option);
            this.modelEffortPickerKey = this.modelEffortPickerKey === key ? '' : key;
          })
        }
        if (this.fastModeCapability && option.supportsFastMode) {
          Toggle({ type: ToggleType.Switch, isOn: this.modelFastForRow(option) })
            .selectedColor($r('app.color.accent'))
            .enabled(!this.creating)
            .accessibilityText(`${option.label}快速模式`)
            .onChange((enabled: boolean) => this.setModelRowFast(option, enabled))
        }
        if (this.modelOptionIsCurrent(option)) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(uiFontSize(17))
            .fontColor([$r('app.color.chat_cta')])
            .width(20)
            .onClick(() => this.selectContextModel(option))
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 40 })

      if (this.modelEffortPickerKey === this.modelOptionKey(option)) {
        Row({ space: 4 }) {
          ForEach(option.efforts, (effort: string) => {
            Button(this.modelEffortLabel(option, effort))
              .height(26)
              .fontSize(uiFontSize(11))
              .fontColor(effort === this.modelEffortForRow(option)
                ? $r('app.color.chat_cta_text') : $r('app.color.text_secondary'))
              .padding({ left: 9, right: 9 })
              .backgroundColor(effort === this.modelEffortForRow(option)
                ? $r('app.color.chat_cta') : $r('app.color.bg_chip'))
              .borderRadius(13)
              .onClick(() => {
                this.selectModelRowEffort(option, effort);
                this.modelEffortPickerKey = '';
              })
          }, (effort: string) => effort)
        }
        .width('100%')
        .padding({ left: 28, right: 4, bottom: 4 })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 8, top: 3, bottom: 3 })
    .backgroundColor(this.modelOptionIsCurrent(option) ? $r('app.color.bg_chip') : Color.Transparent)
    .borderRadius(12)
  }

  @Builder
  modelContextView() {
    Column() {
      Scroll() {
        Column({ space: 8 }) {
          if (this.visibleModelOptions().length === 0) {
            Text('当前电脑未提供模型列表')
              .fontSize(uiFontSize(14))
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 28, bottom: 28 })
          } else {
            ForEach(this.visibleModelOptions(), (option: RuntimeModelOption) => {
              this.contextModelRow(option)
            }, (option: RuntimeModelOption) => this.modelOptionKey(option))
          }
        }
        .width('100%')
        .padding({ top: 8, bottom: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  contextSheet() {
    Column() {
      Row() {
        if (this.contextSheetPage !== 'main') {
          Button() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(uiFontSize(20))
              .fontColor([$r('app.color.text_primary')])
          }
          .width(36)
          .height(36)
          .padding(0)
          .borderRadius(18)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (this.contextSheetPage === 'model') {
              this.returnToComposerAfterModelSheet();
            } else {
              this.contextSheetOpen = false;
            }
          })
        } else {
          Row().width(36).height(36)
        }
        Text(this.contextSheetPage === 'permission'
          ? '权限模式'
          : this.contextSheetPage === 'model'
            ? '模型'
            : '上下文')
          .fontSize(uiFontSize(17))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
        Row().width(36).height(36)
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })

      Divider()
        .strokeWidth(0.5)
        .color($r('app.color.border'))

      if (this.contextSheetPage === 'permission') {
        this.permissionContextView()
      } else if (this.contextSheetPage === 'model') {
        this.modelContextView()
      } else {
        this.contextMainView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
  }

  @Builder
  composer() {
    Column({ space: 6 }) {
      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(12)
          .fontColor($r('app.color.danger'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 12, right: 12 })
      }
      ConversationComposer({
        input: this.input,
        focused: this.composerFocused,
        surfaceExpanded: this.composerSurfaceVisible,
        images: this.composerImages,
        files: this.composerFiles,
        pickingImages: this.pickingImages,
        sending: this.creating,
        streaming: false,
        hasContent: this.hasComposerContent(),
        canSend: this.canSend(),
        composerEnabled: true,
        contextBusy: this.creating,
        toolbarReady: this.composerToolbarReady,
        hasPermissionOptions: this.permissionOptions.length > 0,
        hasModelOptions: this.visibleModelOptions().length > 0 && this.currentModelLabel().length > 0,
        permissionMode: this.permissionMode,
        permissionLabel: this.currentPermissionModeLabel(),
        planModeEnabled: this.planModeEnabled,
        modelLabel: this.currentModelLabel(),
        effortLabel: this.currentEffortLabel(),
        permissionPopupVisible: this.composerPermissionPopupOpen,
        modelPopupVisible: this.composerModelPopupOpen,
        showAddButton: true,
        showStreamingStatus: false,
        floatingGlass: true,
        floatingBottomInset: 16,
        inputId: 'new-session-composer-input',
        onInputChange: (value: string): void => {
          this.applyNewSessionInput(value);
          this.error = '';
        },
        onFocusChange: (focused: boolean): void => {
          this.handleComposerFocusChange(focused);
        },
        onAdd: (): void => this.openContextSheet(),
        onPermission: (): void => this.openComposerControlPopup('permission'),
        onModel: (): void => this.openComposerControlPopup('model'),
        onPermissionPopupDismiss: (): void => {
          this.dismissComposerControlPopup('permission');
        },
        onModelPopupDismiss: (): void => {
          this.dismissComposerControlPopup('model');
        },
        permissionPopupContent: (): void => {
          this.permissionContextView();
        },
        modelPopupContent: (): void => {
          this.modelContextView();
        },
        onPlanToggle: (): void => this.togglePlanMode(),
        onSend: (): void => {
          void this.send();
        },
        onPreviewImage: (image: ComposerImage): void => {
          if (image.status === 'ready' && image.uri.length > 0) {
            this.previewImageUrl = image.uri;
          }
        },
        onRemoveImage: (localId: string): void => this.removeComposerImage(localId),
        onRetryImage: (localId: string): void => this.retryComposerImage(localId),
        onRemoveFile: (localId: string): void => this.removeComposerFile(localId),
        onRetryFile: (_localId: string): void => {},
      })
    }
    .width('100%')
    .padding({ top: 4, bottom: 0 })
  }
}
