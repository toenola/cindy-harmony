import { UiCard, UiListGroup, UiListRow } from '../components/common/UiList';
import { UI_FONT_LIST_TITLE, UI_FONT_SECONDARY, UI_RADIUS_CARD } from '../components/UiKit';
import { ModelPickerListRow } from '../components/ModelPickerListRow';
import { PluginEngine, PluginEngineModel, pluginPickerModels } from '../core/plugin-engines/PluginEngines';
import { ComposerModelOption, pickerVisibleGroups, pickerFavorites, modelFavoriteMutation, recommendedPickerEffort, pickerRecommendedOption, pickerConfiguredOption } from '../core/ComposerCatalog';
import { NewSessionWorktreeTarget, WorktreePreparation, parseWorktreeTarget,
  worktreeReservation } from '../core/tasks/NewSessionWorktree';
import { restoreIncomingNewSessionDraft } from '../core/incoming-share/IncomingNewSessionDrafts';
import { harmonyV12String } from '../core/HarmonyStrings';
import { MODEL_SPEED_ULTRAFAST, fastModeWireValue, ultrafastRestorable } from '../core/tasks/ModelSpeed';
import { providerCatalogUnavailable } from '../core/ComposerCatalog';
/**
 * 新建任务页：选择 Agent、对话类型和项目目录，然后用同款 Composer 发送首条消息。
 *
 * 创建与目录浏览都复用 Device Link 已有远程 channel；Harmony 只负责原生呈现，
 * 任务和消息真相仍由被控端桌面维护。
 */

import {
  KeyboardAvoidMode,
  LengthMetrics,
  router,
  SymbolGlyphModifier,
  window,
} from '@kit.ArkUI';
import {
  BlurStrategy,
  HdsNavigation,
  HdsNavigationTitleMode,
  ScrollEffectType,
  hdsMaterial,
} from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import {
  photoAccessHelper, PhotoPickerComponent, PickerController, PickerOptions,
  SelectMode, PickerOrientation, SingleLineConfig, DataType,
} from '@kit.MediaLibraryKit';
import { IncomingComposerPagePort } from '../core/IncomingComposerPagePort';
import { IncomingShareDestination } from '../core/incoming-share/IncomingShareStore';
import { IncomingComposerDelivery, IncomingComposerFile, incomingComposerReceipts } from '../core/incoming-share/IncomingComposerDraftBridge';
import { ModelRoute, ModelRouteRow, buildModelRoutingNote } from '../core/model-routing/ModelRoutingModels';
import { routedCreationRuntime } from '../core/model-routing/ModelRoutingCreation';
import { AppServices } from '../core/AppServices';
import { ModelRoutingContext, ModelRoutingSnapshot, ModelRoutingTicket } from '../core/model-routing/ModelRoutingStore';
import { ModelRoutingPanel } from '../components/model-routing/ModelRoutingPanel';
import { modelRoutingLabels } from '../components/ModelRoutingCopy';
import { remoteModelPreferenceKey } from '../core/tasks/RemoteModelPreferenceStore';
import {
  ComposerChoiceOption as RuntimeChoiceOption,
  ComposerModelGroup,
  ComposerModelOption as RuntimeModelOption,
  ModelSelectionHint,
  ProviderListOptions,
  composerModelKey,
  effortLevelLabel,
  groupComposerModelOptions,
  hasProviderCatalog,
  modelProviderKind,
  modelNeedsReselection,
  parseModelOptions,
  parseModelVisibilityOverrides,
  parseProviderModelOptions as parseComposerProviderModelOptions,
  permissionModeDescription,
  permissionModeLabel,
  reconcileModelEffort,
  selectedPermissionModeLabel,
} from '../core/ComposerCatalog';
import {
  RemoteAgentCatalog,
  RemoteAgentDevice,
  remoteAgentLocationSupported,
  remoteAgentModelOptions,
  selectRemoteAgentDevices,
} from '../core/tasks/RemoteAgentCatalogs';
import { pickImageUris, pickScreenshotUris, takePhotoUri, buildImageCandidate } from '../core/attachments/ImagePicker';
import {
  uploadImage, deleteUpload, presignGet, isUploadRevisionCurrent,
} from '../core/attachments/AttachmentUpload';
import { RemoteImageRef, RemoteSerializedAttachment } from '../core/attachments/AttachmentModels';
import { ComposerFile, ComposerFileQueue } from '../core/attachments/ComposerFileQueue';
import { parseAttachmentOssRef } from '../core/attachments/AttachmentOssRef';
import { DlInvokeOptions } from '../core/device-link/DlClient';
import { ModelPickerQuota, modelQuotaKey, modelQuotaLine, readModelPickerQuotas } from '../core/messages/ModelPickerQuota';
import { DlChannels, PresenceSnapshot } from '../core/device-link/DlProtocol';
import { unwrapInvokeResult } from '../core/tasks/TaskStore';
import { RemoteSession, readBool, readObj, readStr, recordOrEmpty, sessionProjectDirectory } from '../core/tasks/TaskModels';
import { normalizeTaskProjectPath } from '../core/tasks/TaskProjectOrderStore';
import {
  NewSessionDirectoryDrive,
  NewSessionDraftPrefWriter,
  NewSessionRuntime,
  NewSessionRuntimeChoices,
  newSessionDraftPref,
  newSessionRuntimeCanCreate,
  normalizeRemoteDirectoryDrives,
  pickNewSessionRuntime,
  readNewSessionRuntimeDefaults,
  runtimeDefaultsScope,
  shouldRetryRemoteBrowseDrives,
} from '../core/tasks/NewSessionRuntimeDefaults';
import {
  NewSessionCreationParams,
  NewSessionEditDraft,
} from '../core/tasks/NewSessionCreationStore';
import { deriveOptimisticSessionTitle } from './TaskListPresentation';
import { ComposerImage, ConversationComposer, composerPermissionSymbol, composerPermissionTint } from '../components/ConversationComposer';
import {
  ComposerModelOptionRow,
} from '../components/ComposerModelOptionRow';
import {
  ComposerDocument,
  serializeComposerDocument,
  composerDocumentProjectedText,
  composerDocumentToStorage,
  reconcileComposerProjectedText,
  emptyComposerDocument,
} from '../core/messages/ComposerDocument';
import {
  UI_CLICK_EFFECT,
  UI_ICON_CLICK_EFFECT,
  UI_LIST_CLICK_EFFECT,
  UI_RADIUS_CONTROL,
  uiAnimateFastState,
  uiFontSize,
  uiLineHeight,
  uiOverlayTransition,
} from '../components/UiKit';
import {
  uiConfirm, uiConfirmCopy, uiToast,
} from '../components/common/UiOverlay';

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

@Component
export struct NewSessionPageContent {
  /** 宽屏详情栏直接传入目标设备；独立页面为空时读取路由参数。 */
  @Prop paneDeviceId: string = '';
  /** 键盘高度由实际页面承载者消费，宽屏时只缩小右侧详情栏。 */
  @Prop paneKeyboardInset: number = 0;
  @Prop paneComposerBottomInset: number = 16;
  @Prop embedded: boolean = false;
  onClose: () => void = () => router.back();
  onSessionStarted: (deviceId: string, sessionId: string) => void =
    (deviceId: string, sessionId: string): void => {
      router.replaceUrl({
        url: 'pages/TaskPage',
        params: { deviceId: deviceId, sessionId: sessionId },
      });
    };
  /** 首页承载时由 TaskListPage 在草稿上方打开现有「新建项目」面板；为空（独立页面）时退回目录浏览。 */
  onCreateProject: ((deviceId: string) => void) | null = null;
  /** 首页新建项目成功后回传「设备\n目录\n序号」，草稿保持不变并选中该项目。 */
  @Prop @Watch('applyCreatedProject') createdProject: string = '';
  @State devices: PresenceSnapshot[] = [];
  @State projectAliasRevision: number = 0;
  @State @Watch('scheduleWorktreeTarget') selectedDeviceId: string = '';
  @State private worktreeEnabled: boolean = false;
  @State private worktreeTarget: NewSessionWorktreeTarget = new NewSessionWorktreeTarget();
  @State private worktreeLoading: boolean = false;
  @State private worktreeBranches: string[] = [];
  @State private worktreeBranchOpen: boolean = false;
  @State private deviceMenuOpen: boolean = false;
  @State private worktreeBranchQuery: string = '';
  @State private worktreeBranch: string = 'HEAD';
  private worktreeGeneration: number = 0;
  private worktreeKey: string = '';
  private worktreeOwner: string = '';
  private worktreeBranchCache: Map<string, string[]> = new Map();
  private worktreeDeviceChoices: Map<string, boolean> = new Map();
  @State private selectedRouteId: string = '';
  @State private selectedRouteDevice: string = '';
  @State private routingSnapshot: ModelRoutingSnapshot = new ModelRoutingSnapshot();
  @State selectedAgentKind: NewAgentKind = 'claude-code';
  @State @Watch('scheduleWorktreeTarget') workspaceKind: WorkspaceKind = 'dialogue';
  @State @Watch('scheduleWorktreeTarget') workingDir: string = '';
  @State input: string = '';
  private newSessionDocument: ComposerDocument = new ComposerDocument();
  private newSessionDraftDevice: string = '';
  private newSessionDraftOwner: string = '';
  @State private incomingBusy: boolean = false;
  @State private incomingBlocked: boolean = false;
  @State private incomingRestored: boolean = false;
  private incomingGeneration: number = 0;
  private incomingDelivery: IncomingComposerDelivery | null = null;
  private incomingConsumedKey: string = '';
  @State composerFocused: boolean = false;
  /** 模型选择等临时清焦期间仍保留与任务详情一致的完整输入卡片。 */
  @State composerSurfaceVisible: boolean = false;
  private composerBlurGeneration: number = 0;
  @State composerImages: ComposerImage[] = [];
  @State composerFiles: ComposerFile[] = [];
  @State pickingImages: boolean = false;
  @State pickingFiles: boolean = false;
  /** 新建页与详情页共用同一套文件附件上传、重试和回收语义。 */
  private fileQueue: ComposerFileQueue = new ComposerFileQueue();
  /** 新建页待发送图片的全屏预览 URL（空 = 无预览）。 */
  @State previewImageUrl: string = '';
  @State private composerPickerViewport: number = 0;
  registerComposerBack: ((handler: (() => boolean) | undefined) => void) | undefined = undefined;
  @State contextSheetOpen: boolean = false;
  @State workspacePopupOpen: boolean = false;
  @State composerPermissionPopupOpen: boolean = false;
  @State composerAgentPopupOpen: boolean = false;
  @State composerModelPopupOpen: boolean = false;
  @State private modelQuotaValues: ModelPickerQuota[] = [];
  private modelQuotaGeneration: number = 0;
  private modelQuotaRequested: Set<string> = new Set();
  private modelPickerScroller: Scroller = new Scroller();
  private modelPickerTop: number = 0;
  private modelPickerHeight: number = 0;
  private modelPickerPositionPending: boolean = false;
  private modelPickerUserMoved: boolean = false;
  private selectedModelArea: Area | null = null;
  /** 仅恢复打开模型 Popup 前已经存在的输入焦点。 */
  /** 模型 Popup 关闭时暂存目标选项，由统一收口路径提交模型并销毁锚点。 */
  private pendingPopupModelSelection: RuntimeModelOption | null = null;
  @State contextSheetPage: string = 'main';
  private restoreComposerFocusOnSheetDisappear: boolean = false;
  /** 每个模型行自己的思考强度和 Fast 选择；非当前行在选中模型时一并应用。 */
  @State modelEffortMemory: Map<string, string> = new Map();
  @State modelFastMemory: Map<string, boolean> = new Map();
  @State modelFastTierMemory: Map<string, string> = new Map();
  @State modelEffortPickerKey: string = '';
  @State contextSelectedUris: string[] = [];
  @State browseOpen: boolean = false;
  @State browsePath: string = '';
  @State browseParent: string = '';
  @State browseEntries: RemoteDirectory[] = [];
  @State browseDrives: NewSessionDirectoryDrive[] = [];
  @State browseLoading: boolean = false;
  @State browseError: string = '';
  @State showHiddenDirectories: boolean = false;
  @State model: string = '';
  @State providerId: string = '';
  /** 远程 Agent：选中的模型来自哪台电脑的目录；空 = 被控电脑（v1.3.5 D2）。 */
  @State agentDeviceId: string = '';
  @State effort: string = '';
  @State permissionMode: string = '';
  @State permissionModeBeforePlan: string = 'auto';
  @State planModeSupported: boolean = false;
  @State planModeNative: boolean = false;
  @State planModeEnabled: boolean = false;
  @State fastMode: boolean = false;
  /** '' 或 'ultrafast'；仅在 fastMode 为 true 时有意义。 */
  @State fastModeTier: string = '';
  @State modelOptions: RuntimeModelOption[] = [];
  @State providerModelOptions: RuntimeModelOption[] = [];
  @State providerModelAgent: string = '';
  /** 被控电脑认得新建时的 agentDeviceId 才提供远程模型（目录带「允许被远程调用」标记）。 */
  @State remoteAgentLocationSupported: boolean = false;
  @State remoteAgentRevision: number = 0;
  private remoteAgentDevices: RemoteAgentDevice[] = [];
  private remoteAgentCatalogList: RemoteAgentCatalog[] = [];
  private remoteOptionsKey: string = '';
  private remoteOptionsCache: RuntimeModelOption[] = [];
  @State modelVisibilityOverrides: Map<string, boolean> = new Map();
  @State effortOptions: RuntimeChoiceOption[] = [];
  @State permissionOptions: RuntimeChoiceOption[] = [];
  @State fastModeCapability: boolean = false;
  @State composerToolbarReady: boolean = false;
  @State runtimeDefaultsSettled: boolean = false;
  @State creating: boolean = false;
  @State error: string = '';
  @State taskRevision: number = 0;
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
  private workspaceEditRevision: number = 0;
  private runtimeCatalogReady: boolean = false;
  private runtimeCatalogScope: string = '';
  private runtimeChoices: NewSessionRuntimeChoices = new NewSessionRuntimeChoices();
  private runtimePrefWriter: NewSessionDraftPrefWriter = new NewSessionDraftPrefWriter();
  private workspaceRestoreGeneration: number = 0;
  private preserveWorkspaceDraft: boolean = false;
  /** 使系统图片选择器的迟到回包不能写入已离开的新建任务页。 */
  private imagePickerGeneration: number = 0;
  /** 目录浏览切换路径、设备或页面后，旧目录回包不能覆盖当前浏览位置。 */
  private browseGeneration: number = 0;
  private newSessionDraftGeneration: number = 0;
  private newSessionInputRevision: number = 0;
  private newSessionDraftCheckpointTimer: number = -1;
  aboutToAppear(): void {
    this.pickerFavoriteUnsubscribe = AppServices.instance.onModulePush((device: string, channel: string): void => {
      if (channel === 'maker:model-favorites:changed' && this.composerModelPopupOpen && !this.pickerFavoritesBusy
        && device === this.selectedDeviceId) void this.refreshPickerFavorites();
    });
    this.registerComposerBack?.((): boolean => this.dismissActiveComposerPicker());
    this.unsubs.push(AppServices.instance.modelRouting.onChanged((): void => {
      this.routingSnapshot = AppServices.instance.modelRouting.snapshot(this.selectedDeviceId);
    }));
    this.pageActive = true;
    this.incomingRestored = false;
    this.newSessionDocument = emptyComposerDocument(); this.input = '';
    this.newSessionDraftDevice = '';
    this.newSessionDraftOwner = AppServices.instance.usageCardOwner;
    this.incomingGeneration++;
    this.incomingConsumedKey = '';
    this.incomingDelivery = null;
    this.incomingBlocked = false;
    const incoming = AppServices.instance.incomingComposer;
    if (incoming !== null) this.unsubs.push(incoming.onChanged((): void => { void this.consumeIncomingDraft(); }));
    // 页面实例可能被展开屏导航复用；上一轮已交接的附件不属于新草稿。
    this.attachmentsHandedOff = false;
    this.attachmentsDisposed = false;
    this.cancelImagePicking();
    this.pickingFiles = false;
    this.fileQueue.onChanged = (files: ComposerFile[]): void => {
      this.composerFiles = files;
    };
    this.fileQueue.onPickingChanged = (picking: boolean): void => {
      this.pickingFiles = picking;
    };
    this.fileQueue.targetDevice = () => this.selectedDeviceId;
    this.fileQueue.isBusy = (): boolean => this.creating || !this.pageActive || this.attachmentsDisposed;
    this.fileQueue.occupiedByOtherAttachments = (): number => this.composerImages.length;
    this.fileQueue.cancelPicking();
    const params = (router.getParams() ?? {}) as Record<string, Object>;
    this.routeDeviceId = this.paneDeviceId.length > 0
      ? this.paneDeviceId : readStr(params, 'deviceId');
    const editDraft = AppServices.instance.newSessionCreations.consumeEditDraft();
    this.preserveWorkspaceDraft = editDraft !== null;
    if (editDraft !== null) {
      this.pendingEditDraft = editDraft;
      this.routeDeviceId = editDraft.deviceId;
      this.agentTouched = true;
      this.selectedAgentKind = this.editDraftAgentKind(editDraft.agentKind);
      this.workspaceKind = editDraft.workspaceKind === 'project' ? 'project' : 'dialogue';
      this.workingDir = editDraft.workingDir;
      this.applyNewSessionInput(editDraft.text);
      this.composerImages = this.editDraftImages(editDraft.images);
      this.fileQueue.files = [];
      this.composerFiles = [];
      const restoredFiles = this.fileQueue.restoreReady(editDraft.files);
      const missingAttachments = editDraft.images.length - this.composerImages.length
        + editDraft.files.length - restoredFiles;
      if (missingAttachments > 0) {
        this.error = `有 ${missingAttachments} 个附件因数量上限未恢复`;
      }
      this.resolveEditDraftImagePreviews();
      this.incomingRestored = true;
    }
    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      this.refreshDevices();
    this.scheduleWorktreeTarget();
    }));
    this.unsubs.push(AppServices.instance.remoteAgentCatalogs.onChanged(() => this.syncRemoteAgentCatalogs()));
    this.unsubs.push(AppServices.instance.taskProjectAliases.onChanged(() => {
      this.projectAliasRevision += 1;
    }));
    this.unsubs.push(AppServices.instance.auth.onChanged(() => {
      this.incomingGeneration++; this.incomingConsumedKey = ''; this.incomingDelivery = null;
      void this.consumeIncomingDraft();
      if (this.runtimeCatalogScope !== this.currentRuntimeScope()) {
        void this.loadRuntimeDefaults(this.selectedDeviceId, this.selectedAgentKind);
      }
    }));
    this.refreshDevices();
    if (editDraft === null) {
      void this.restoreNewSessionDraft().catch((): void => { this.error = harmonyV12String(this.getUIContext().getHostContext(), 'incoming_share_failed'); });
    }
    void this.restoreWorkspacePreference();
    this.applyPendingEditRuntime(this.routeDeviceId, this.selectedAgentKind, false);
    if (this.incomingRestored) void this.consumeIncomingDraft();
  }

  aboutToDisappear(): void {
    this.pickerFavoriteUnsubscribe?.();
    this.pickerFavoriteUnsubscribe = undefined;
    this.pickerRefreshRevision += 1;
    this.registerComposerBack?.(undefined);
    this.worktreeKey = '';
    this.pageActive = false;
    this.incomingGeneration++;
    this.cancelImagePicking();
    this.fileQueue.cancelPicking();
    this.getUIContext().getFocusController().clearFocus();
    this.composerBlurGeneration += 1;
    this.composerFocused = false;
    this.composerSurfaceVisible = false;
    this.contextSheetOpen = false;
    this.restoreComposerFocusOnSheetDisappear = false;
    this.newSessionDraftGeneration += 1;
    this.cancelNewSessionDraftCheckpoint();
    void AppServices.instance.composerDrafts.flush(NEW_SESSION_COMPOSER_DRAFT_ID, this.newSessionDraftDevice).catch(() => {});
    this.runtimeLoadGeneration += 1;
    this.browseGeneration += 1;
    this.browseLoading = false;
    this.runtimeToolbarLoadActive = false;
    this.composerToolbarReady = false;
    if (!this.attachmentsHandedOff) this.disposeUnsentAttachments();
    for (const unsubscribe of this.unsubs) {
      unsubscribe();
    }
    this.unsubs = [];
  }

  /** 让尚未返回的系统图片选择器结果失效，并收口新建页选择状态。 */
  private cancelImagePicking(): void {
    this.imagePickerGeneration += 1;
    this.pickingImages = false;
  }

  private async restoreNewSessionDraft(): Promise<void> {
    const candidate = this.routeDeviceId || this.selectedDeviceId;
    const owner = AppServices.instance.usageCardOwner;
    this.newSessionDraftOwner = owner;
    const incoming = AppServices.instance.incomingComposer;
    const hasPending = incoming !== null && incoming.pendingTargets().some((pending: IncomingShareDestination): boolean =>
      pending.ownerKey === owner && pending.deviceId === candidate && pending.sessionId === '');
    const generation = ++this.newSessionDraftGeneration, inputRevision = this.newSessionInputRevision;
    const isCurrent = (): boolean => this.pageActive && generation === this.newSessionDraftGeneration
      && inputRevision === this.newSessionInputRevision && owner === AppServices.instance.usageCardOwner;
    try {
      const restored = await restoreIncomingNewSessionDraft(AppServices.instance.composerDrafts,
        NEW_SESSION_COMPOSER_DRAFT_ID, candidate, hasPending, isCurrent);
      if (!isCurrent()) return;
      this.newSessionDraftDevice = restored.deviceId;
      if (restored.document !== null) { this.newSessionDocument = restored.document; this.input = composerDocumentProjectedText(restored.document); }
      this.incomingRestored = true; void this.consumeIncomingDraft();
    } catch {
      if (isCurrent()) {
        this.incomingRestored = false; this.incomingBlocked = true;
        this.error = harmonyV12String(this.getUIContext().getHostContext(), 'incoming_share_failed');
      }
    }
  }

  private applyNewSessionInput(value: string): void {
    this.newSessionDocument = reconcileComposerProjectedText(this.newSessionDocument, value);
    this.input = composerDocumentProjectedText(this.newSessionDocument);
    this.newSessionInputRevision++;
    AppServices.instance.composerDrafts.save(NEW_SESSION_COMPOSER_DRAFT_ID, this.newSessionDocument, this.newSessionDraftDevice);
    this.scheduleNewSessionDraftCheckpoint();
  }

  private incomingTarget(): IncomingShareDestination {
    const target = new IncomingShareDestination(); target.ownerKey = AppServices.instance.usageCardOwner;
    target.deviceId = this.selectedDeviceId; target.sessionId = ''; return target;
  }
  private incomingUriSet(): string[] {
    return this.composerImages.map((image: ComposerImage): string => image.uri)
      .concat(this.fileQueue.files.map((file: ComposerFile): string => file.uri));
  }
  private incomingDraftMatchesTarget(): boolean {
    return incomingComposerReceipts(this.newSessionDocument).length === 0
      || (this.newSessionDraftDevice === this.selectedDeviceId && this.newSessionDraftOwner === AppServices.instance.usageCardOwner);
  }
  private async consumeIncomingDraft(): Promise<void> {
    const bridge = AppServices.instance.incomingComposer;
    if (bridge === null || !this.pageActive || !this.incomingRestored || this.incomingBusy || this.creating
      || !this.selectedDeviceId || !AppServices.instance.usageCardOwner) return;
    const target = this.incomingTarget();
    const committed = bridge.committedInputs(target, incomingComposerReceipts(this.newSessionDocument));
    if (!bridge.pendingTargets().some((pending: IncomingShareDestination): boolean => pending.ownerKey === target.ownerKey
      && pending.deviceId === target.deviceId && pending.sessionId === '') && committed.length === 0) return;
    const generation = this.incomingGeneration, ownerEpoch = AppServices.instance.auth.sessionEpoch;
    const isCurrent = (): boolean => this.pageActive && generation === this.incomingGeneration
      && target.ownerKey === AppServices.instance.usageCardOwner && target.deviceId === this.selectedDeviceId
      && ownerEpoch === AppServices.instance.auth.sessionEpoch;
    this.incomingBusy = true;
    try {
      if (committed.length > 0) {
        // Ownership was already durable before the crash. An absent/pruned outbox is not
        // permission to send again; the existing session/input recovery remains authoritative.
        const recovered = committed[0];
        if (!recovered.sessionId) throw new Error('INCOMING_COMPOSER_INPUT_UNRESOLVED');
        if (!recovered.documentStorage || recovered.documentStorage !== composerDocumentToStorage(this.newSessionDocument)) {
          this.incomingBlocked = true;
          this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v132_delivery_unknown'); return;
        }
        AppServices.instance.composerDrafts.clear(NEW_SESSION_COMPOSER_DRAFT_ID, this.newSessionDraftDevice);
        this.newSessionDocument = emptyComposerDocument(); this.input = '';
        this.onSessionStarted(target.deviceId, recovered.sessionId); return;
      }
      for (const pending of bridge.pendingInputs(target)) {
        if (!pending.sessionId) { this.incomingBlocked = true; this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v132_delivery_unknown'); return; }
        if (AppServices.instance.inputQueue.hasPersistedDocument(target.deviceId, pending.sessionId, pending.clientId)) {
          await bridge.reconcileInput(target, pending.clientId, 'owned');
          if (!isCurrent()) return;
          if (incomingComposerReceipts(this.newSessionDocument).some((id: string): boolean => pending.batchIds.includes(id))) {
            const owned = bridge.committedInputs(target, incomingComposerReceipts(this.newSessionDocument))
              .find((input): boolean => input.clientId === pending.clientId);
            if (!owned || !owned.documentStorage || owned.documentStorage !== composerDocumentToStorage(this.newSessionDocument)) {
              this.incomingBlocked = true;
              this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v132_delivery_unknown'); return;
            }
            AppServices.instance.composerDrafts.clear(NEW_SESSION_COMPOSER_DRAFT_ID, this.newSessionDraftDevice);
            this.newSessionDocument = emptyComposerDocument(); this.input = '';
          }
          this.onSessionStarted(target.deviceId, pending.sessionId); return;
        }
        // This new-task pipeline never dispatches before the owned ledger transition.
        // A still-queued bridge entry plus no exact reserved record is proven pre-dispatch absence.
        await bridge.reconcileInput(target, pending.clientId, 'absent');
        if (!isCurrent()) return;
      }
      this.incomingBlocked = false;
      if (this.newSessionDraftDevice !== target.deviceId) {
        if (!this.incomingDraftMatchesTarget()) throw new Error('INCOMING_COMPOSER_TARGET_MISMATCH');
        this.newSessionDraftDevice = target.deviceId;
        this.newSessionDraftOwner = target.ownerKey;
        AppServices.instance.composerDrafts.save(NEW_SESSION_COMPOSER_DRAFT_ID, this.newSessionDocument, this.newSessionDraftDevice);
        await AppServices.instance.composerDrafts.flush(NEW_SESSION_COMPOSER_DRAFT_ID, this.newSessionDraftDevice);
        if (!isCurrent()) return;
      }
      const port = new IncomingComposerPagePort(
        async (_target: IncomingShareDestination): Promise<ComposerDocument> => {
          if (!isCurrent()) throw new Error('INCOMING_COMPOSER_STALE'); return this.newSessionDocument;
        },
        async (_target: IncomingShareDestination, expected: string, document: ComposerDocument): Promise<boolean> => {
          if (!isCurrent() || composerDocumentToStorage(this.newSessionDocument) !== expected) return false;
          this.newSessionDocument = document; this.input = composerDocumentProjectedText(document); this.newSessionInputRevision++;
          AppServices.instance.composerDrafts.save(NEW_SESSION_COMPOSER_DRAFT_ID, document, this.newSessionDraftDevice);
          await AppServices.instance.composerDrafts.flush(NEW_SESSION_COMPOSER_DRAFT_ID, this.newSessionDraftDevice);
          if (!isCurrent()) throw new Error('INCOMING_COMPOSER_STALE'); return true;
        });
      const delivery = await bridge.consume(target, port);
      if (!isCurrent()) return;
      const key = JSON.stringify([target.ownerKey, target.deviceId, delivery.batchIds]);
      if (key === this.incomingConsumedKey) { this.incomingBlocked = false; return; }
      this.incomingDelivery = delivery;
      const existing = this.incomingUriSet(), missing = delivery.files.filter((file: IncomingComposerFile): boolean => !existing.includes(file.uri));
      if (missing.length > this.remainingImageSlots()) throw new Error('INCOMING_COMPOSER_QUEUE_FULL');
      for (const file of missing) {
        if (file.mime.startsWith('image/')) {
          const image = new ComposerImage(); image.uri = file.uri; image.name = file.name;
          this.composerImages = this.composerImages.concat([image]); this.startComposerImageUpload(image, this.composerImages.length - 1, true);
        } else this.fileQueue.enqueue([file.uri]);
      }
      bridge.ack(delivery, this.incomingUriSet()); this.incomingConsumedKey = key; this.incomingBlocked = false;
      this.composerSurfaceVisible = true;
    } catch (_error) {
      if (isCurrent()) { this.incomingBlocked = true; this.error = harmonyV12String(this.getUIContext().getHostContext(), 'incoming_share_failed'); }
    } finally {
      this.incomingBusy = false;
      if (this.pageActive && generation !== this.incomingGeneration) void this.consumeIncomingDraft();
    }
  }

  private forgetIncomingFile(uri: string): boolean {
    const bridge = AppServices.instance.incomingComposer, delivery = this.incomingDelivery;
    const file = delivery?.files.find((file: IncomingComposerFile): boolean => file.uri === uri);
    if (bridge === null || delivery === null || !file) return true;
    try {
      void bridge.removeFile(delivery.target, file.id); return true;
    } catch {
      if (this.pageActive) this.error = harmonyV12String(this.getUIContext().getHostContext(), 'incoming_share_failed');
      return false;
    }
  }

  /** trailing debounce 之外再做固定间隔检查点，持续输入时也不会一直没有落盘版本。 */
  private scheduleNewSessionDraftCheckpoint(): void {
    if (this.newSessionDraftCheckpointTimer >= 0) return;
    this.newSessionDraftCheckpointTimer = setTimeout(() => {
      this.newSessionDraftCheckpointTimer = -1;
      if (!this.pageActive) return;
      void AppServices.instance.composerDrafts.flush(NEW_SESSION_COMPOSER_DRAFT_ID, this.newSessionDraftDevice).catch(() => {});
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
    const files = this.fileQueue.files.slice();
    this.composerImages = [];
    this.composerFiles = [];
    this.fileQueue.files = [];
    this.fileQueue.cancelPicking();
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
    this.agentDeviceId = '';
    this.effort = draft.effort;
    this.permissionMode = draft.permissionMode;
    this.permissionModeBeforePlan = draft.permissionMode;
    this.planModeEnabled = draft.planModeEnabled;
    this.fastMode = draft.fastMode;
    this.fastModeTier = draft.fastMode ? draft.fastModeTier : '';
    if (consume) this.pendingEditDraft = null;
  }

  private async restoreWorkspacePreference(): Promise<void> {
    const generation = ++this.workspaceRestoreGeneration;
    const revision = this.workspaceEditRevision;
    const owner = AppServices.instance.auth.cacheAccountId;
    await AppServices.instance.newSessionPreferences.setAccountScope(owner);
    if (!this.pageActive || generation !== this.workspaceRestoreGeneration || revision !== this.workspaceEditRevision
      || this.preserveWorkspaceDraft || this.pendingEditDraft !== null
      || AppServices.instance.auth.cacheAccountId !== owner) return;
    const preferences = AppServices.instance.newSessionPreferences.read();
    if (preferences.workspaceKind.length === 0) return;
    this.workspaceKind = preferences.workspaceKind === 'project' ? 'project' : 'dialogue';
    this.workingDir = preferences.workingDirByDevice[this.selectedDeviceId] ?? '';
  }

  private refreshDevices(requested: string = this.selectedDeviceId): void {
    this.devices = AppServices.instance.tasks.deviceList;
    this.taskRevision += 1;
    let nextDeviceId = requested;
    if (this.routeDeviceId && AppServices.instance.incomingComposer?.pendingTargets().some((target: IncomingShareDestination): boolean =>
      target.ownerKey === AppServices.instance.usageCardOwner && target.deviceId === this.routeDeviceId && target.sessionId === '') === true) {
      nextDeviceId = this.routeDeviceId;
    }
    if (nextDeviceId.length === 0 && this.routeDeviceId.length > 0) {
      nextDeviceId = this.routeDeviceId;
    }
    const incomingPinned = AppServices.instance.incomingComposer?.pendingTargets().some((target: IncomingShareDestination): boolean =>
      target.ownerKey === AppServices.instance.usageCardOwner && target.deviceId === nextDeviceId && target.sessionId === '') === true;
    if (!this.canCreateOnDevice(nextDeviceId) && !incomingPinned) {
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
      this.incomingGeneration++; this.incomingConsumedKey = ''; this.incomingDelivery = null;
      if (this.pendingEditDraft === null && !this.preserveWorkspaceDraft) {
        const preferences = AppServices.instance.newSessionPreferences.read();
        if (preferences.workspaceKind.length > 0) {
          this.workspaceKind = preferences.workspaceKind === 'project' ? 'project' : 'dialogue';
          this.workingDir = preferences.workingDirByDevice[nextDeviceId] ?? '';
        }
      }
      if (!this.agentTouched) {
        const sessions = AppServices.instance.tasks.getSessions(nextDeviceId);
        if (sessions.length > 0) {
          this.selectedAgentKind = newAgentKindFromSession(sessions[0]);
        }
      }
      void this.loadRuntimeDefaults(nextDeviceId, this.selectedAgentKind);
      void this.loadRouting();
      void this.consumeIncomingDraft();
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
      const path = sessionProjectDirectory(session);
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
        project.title = this.projectDisplayTitle(path, this.projectAliasRevision);
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

  private projectDisplayTitle(path: string, _revision: number): string {
    const normalized = normalizeTaskProjectPath(path);
    const sessions = AppServices.instance.tasks.getSessions(this.selectedDeviceId)
      .filter((session: RemoteSession): boolean => session.status !== 'deleted'
        && session.workspaceKind !== 'dialogue' && normalizeTaskProjectPath(sessionProjectDirectory(session)) === normalized);
    return AppServices.instance.taskProjectAliases.resolve(this.selectedDeviceId, sessions) || directoryTitle(path);
  }

  private selectAgent(kind: NewAgentKind): void {
    if (this.creating) return;
    this.agentTouched = true;
    this.selectedAgentKind = kind;
    this.error = '';
    void this.loadRuntimeDefaults(this.selectedDeviceId, kind);
  }

  private selectModel(option: RuntimeModelOption): void {
    // 被控电脑的模型隐藏设置不适用于其他电脑的目录（那份目录已按它自己的设置过滤）。
    if (option.suspended || (option.agentDeviceId.length === 0 && modelNeedsReselection(
      this.modelVisibilityOverrides, this.selectedAgentKind, option.id, option.providerId))) {
      this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v132_model_reselection_required');
      return;
    }
    if (this.creating || option.availability === 'requires_payment') {
      if (option.availability === 'requires_payment') {
        uiToast(this.getUIContext(), '该模型需要付费后才能使用');
      }
      return;
    }
    this.pickerPluginProvider = '';
    this.runtimeModelTouchedGeneration = this.runtimeLoadGeneration;
    // 选模型时会一起 reconcile effort / Fast，后续异步目录回包也不能把它们改回默认值。
    this.runtimeEffortTouchedGeneration = this.runtimeLoadGeneration;
    this.runtimeFastTouchedGeneration = this.runtimeLoadGeneration;
    const nextEffort = reconcileModelEffort(option, this.modelEffortForRow(option));
    const nextFastMode = this.modelFastForRow(option);
    const nextFastTier = this.modelFastTierForRow(option);
    this.selectedRouteId = '';
    this.selectedRouteDevice = '';
    this.model = option.id;
    this.providerId = option.providerId;
    this.agentDeviceId = option.agentDeviceId;
    this.effort = nextEffort;
    this.fastMode = nextFastMode;
    this.fastModeTier = nextFastTier;
    this.error = '';
    this.writeRuntimeChoice(true);
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
    this.fastModeTier = '';
    this.writeRuntimeChoice(false);
  }

  private scheduleWorktreeTarget(): void {
    const generation = ++this.worktreeGeneration;
    Promise.resolve().then((): void => {
      if (generation === this.worktreeGeneration && this.pageActive) void this.loadWorktreeTarget();
    });
  }

  private async loadWorktreeTarget(): Promise<void> {
    const app = AppServices.instance;
    const device = this.selectedDeviceId;
    const cwd = this.workspaceKind === 'project' ? this.workingDir.trim() : '';
    const key = JSON.stringify([app.moduleScope, device, cwd]);
    if (key === this.worktreeKey) return;
    this.worktreeKey = key;
    if (this.worktreeOwner !== app.moduleScope) {
      this.worktreeOwner = app.moduleScope;
      this.worktreeBranchCache.clear();
      this.worktreeDeviceChoices.clear();
    }
    this.worktreeTarget = new NewSessionWorktreeTarget();
    this.worktreeBranch = 'HEAD';
    this.worktreeBranchOpen = false;
    this.worktreeEnabled = this.worktreeDeviceChoices.get(device) ?? false;
    this.worktreeLoading = cwd.length > 0 && device.length > 0;
    if (!this.worktreeLoading) return;
    const current = (): boolean => this.pageActive && this.worktreeKey === key
      && device === this.selectedDeviceId && this.workspaceKind === 'project'
      && cwd === this.workingDir.trim();
    const invoke = app.newSessionWorktree(device, current);
    try {
      const detectArgs: Record<string, Object> = {};
      detectArgs['cwd'] = cwd;
      const target = parseWorktreeTarget(await invoke('worktree:detect-cwd', [detectArgs]));
      if (!current()) return;
      this.worktreeTarget = target;
      this.worktreeBranch = target.sourceBranch;
      if (!target.supported) {
        this.worktreeEnabled = false;
        return;
      }
      try {
        const defaults = recordOrEmpty(await invoke('maker:get-new-maker-defaults', [this.selectedAgentKind]));
        if (current() && !this.worktreeDeviceChoices.has(device)) {
          this.worktreeEnabled = defaults['worktreeEnabled'] === true;
        }
      } catch (_) {}
      try {
        const prefArgs: Record<string, Object> = {};
        prefArgs['baseRepo'] = target.baseRepo;
        const pref = recordOrEmpty(await invoke('maker:get-new-maker-worktree-branch-pref', [prefArgs]));
        if (current()) this.worktreeBranch = readStr(pref, 'sourceBranch') || target.sourceBranch;
      } catch (_) {}
    } catch (_) {
      // 不支持通道或无法验证目标时不允许预创建。
      if (current()) this.worktreeEnabled = false;
    } finally {
      if (current()) this.worktreeLoading = false;
    }
  }

  private async openWorktreeBranches(): Promise<void> {
    if (!this.worktreeTarget.supported || this.creating || this.worktreeLoading) return;
    const key = this.worktreeKey;
    const generation = this.worktreeGeneration;
    const baseRepo = this.worktreeTarget.baseRepo;
    const cacheKey = JSON.stringify([key, baseRepo]);
    const current = (): boolean => this.pageActive && this.worktreeKey === key && this.worktreeGeneration === generation;
    this.worktreeBranchQuery = '';
    this.openLocalPicker('branch');
    this.worktreeBranches = this.worktreeBranchCache.get(cacheKey) ?? [];
    if (this.worktreeBranchCache.has(cacheKey)) return;
    try {
      const invoke = AppServices.instance.newSessionWorktree(this.selectedDeviceId, current);
      const branchesArgs: Record<string, Object> = {};
      branchesArgs['baseRepo'] = baseRepo;
      const rows = recordOrEmpty(await invoke('worktree:list-branches', [branchesArgs]))['branches'];
      if (!current() || !Array.isArray(rows)) return;
      const unique = (rows as Object[]).filter((row: Object): boolean => typeof row === 'string' && String(row).trim().length > 0)
        .map((row: Object): string => String(row).trim());
      this.worktreeBranches = Array.from(new Set(unique));
      this.worktreeBranchCache.set(cacheKey, this.worktreeBranches);
    } catch (_) {
      if (current()) uiToast(this.getUIContext(), '暂时无法读取分支，请重试');
    }
  }

  private toggleNewWorktree(): void {
    if (!this.worktreeTarget.supported || this.worktreeLoading || this.creating) return;
    this.worktreeEnabled = !this.worktreeEnabled;
    const device = this.selectedDeviceId;
    const key = this.worktreeKey;
    const enabled = this.worktreeEnabled;
    this.worktreeDeviceChoices.set(device, enabled);
    const invoke = AppServices.instance.newSessionWorktree(device,
      (): boolean => this.pageActive && key === this.worktreeKey);
    const toggleArgs: Record<string, Object> = {};
    toggleArgs['worktreeEnabled'] = enabled;
    void invoke('maker:apply-new-maker-worktree-pref', [toggleArgs]).catch((): void => {});
  }

  private selectWorktreeBranch(branch: string): void {
    const key = this.worktreeKey;
    const baseRepo = this.worktreeTarget.baseRepo;
    this.getUIContext().getFocusController().clearFocus();
    this.worktreeBranchOpen = false;
    if (this.worktreeBranch === branch) return;
    this.worktreeBranch = branch;
    const invoke = AppServices.instance.newSessionWorktree(this.selectedDeviceId,
      (): boolean => this.pageActive && key === this.worktreeKey);
    const branchArgs: Record<string, Object> = {};
    branchArgs['baseRepo'] = baseRepo;
    branchArgs['sourceBranch'] = branch;
    void invoke('maker:apply-new-maker-worktree-branch-pref', [branchArgs])
      .catch((): void => {});
  }

  private selectDialogue(): void {
    this.workspaceEditRevision += 1;
    this.browseGeneration += 1;
    this.browseLoading = false;
    this.workspaceKind = 'dialogue';
    this.workingDir = '';
    AppServices.instance.newSessionPreferences.save(this.selectedDeviceId, 'dialogue', '');
    this.workspacePopupOpen = false;
    this.browseOpen = false;
    this.showHiddenDirectories = false;
  }

  private selectProject(path: string): void {
    this.workspaceEditRevision += 1;
    const value = path;
    if (value.trim().length === 0) return;
    this.browseGeneration += 1;
    this.browseLoading = false;
    this.workspaceKind = 'project';
    this.workingDir = value;
    AppServices.instance.newSessionPreferences.save(this.selectedDeviceId, 'project', value);
    this.workspacePopupOpen = false;
    this.browseOpen = false;
    this.browseError = '';
    this.showHiddenDirectories = false;
  }

  private async loadRouting(force: boolean = false): Promise<void> {
    const device = this.selectedDeviceId;
    const store = AppServices.instance.modelRouting;
    this.routingSnapshot = store.snapshot(device);
    try {
      const snapshot = await store.load(device, force);
      if (this.pageActive && this.selectedDeviceId === device) this.routingSnapshot = snapshot;
    } catch (_error) {
      if (this.pageActive && this.selectedDeviceId === device) this.routingSnapshot = store.snapshot(device);
    }
  }

  /** Composer 的上下文 Sheet 与详情页同层级：图片、计划和运行时设置都从这里进入。 */
  private openContextSheet(page: string = 'main'): void {
    if (this.creating || this.incomingBusy || this.incomingBlocked || this.pickingImages || this.pickingFiles) return;
    this.contextSheetPage = page;
    this.contextSelectedUris = [];
    try {
      this.recentPickerController.setData(DataType.SET_SELECTED_URIS, []);
    } catch (e) {
      // Picker 尚未挂载时无需清理；下一次打开仍从空选择开始。
    }
    if (page === 'model') {
      this.composerSurfaceVisible = true;
      void this.loadRouting();
    }
    if (page === 'model') {
      this.modelPickerPositionPending = true;
      this.modelPickerUserMoved = false;
      this.modelPickerHeight = 0;
      this.modelQuotaRequested.clear();
      this.modelQuotaValues = [];
    }
    this.getUIContext().getFocusController().clearFocus();
    this.contextSheetOpen = true;
    if (page === 'model') void this.refreshModelQuotas();
  }

  private openComposerControlPopup(page: string): void {
    if (this.creating || this.pickingImages || this.pickingFiles) return;
    this.contextSheetPage = page;
    if (page === 'model') void this.loadRouting();
    this.composerBlurGeneration += 1;
    this.modelEffortPickerKey = '';
    if (page === 'model') this.pendingPopupModelSelection = null;
    if (page === 'model') {
      this.pickerAllProviders = false;
      this.pickerModelSearch = '';
      this.modelPickerPositionPending = true;
      this.modelPickerUserMoved = false;
      this.modelPickerHeight = 0;
      this.selectedModelArea = null;
      this.modelQuotaRequested.clear();
      this.modelQuotaValues = [];
    }
    this.composerFocused = false;
    this.composerSurfaceVisible = false;
    this.getUIContext().getFocusController().clearFocus();
    this.composerPermissionPopupOpen = page === 'permission';
    this.composerAgentPopupOpen = page === 'agent';
    this.composerModelPopupOpen = page === 'model';
    if (page === 'model') this.openPickerExtras();
    if (page === 'model') this.refreshRemoteAgentCatalogs(true);
    if (page === 'model') void this.refreshModelQuotas();
  }

  private async refreshModelQuotas(): Promise<void> {
    const generation = ++this.modelQuotaGeneration;
    const deviceId = this.selectedDeviceId;
    const accountId = AppServices.instance.auth.cacheAccountId;
    const options = this.visibleModelOptions().filter((option: RuntimeModelOption): boolean => {
      if (!option.subscription && !option.openAiSubscription) return false;
      const key = modelQuotaKey(deviceId, option);
      if (this.modelQuotaRequested.has(key)) return false;
      this.modelQuotaRequested.add(key);
      return true;
    });
    const values = await readModelPickerQuotas(deviceId, options,
      async (target: string, channel: string, args: Object[]): Promise<Object | undefined> => {
        if (!this.pageActive || generation !== this.modelQuotaGeneration
          || accountId !== AppServices.instance.auth.cacheAccountId
          || deviceId !== this.selectedDeviceId) return undefined;
        await AppServices.instance.openLink(target);
        if (!this.pageActive || generation !== this.modelQuotaGeneration
          || accountId !== AppServices.instance.auth.cacheAccountId
          || deviceId !== this.selectedDeviceId) return undefined;
        const rpc = new DlInvokeOptions();
        rpc.channel = channel;
        rpc.args = args;
        return unwrapInvokeResult(await AppServices.instance.client.invoke(target, rpc));
      });
    if (generation !== this.modelQuotaGeneration || !this.pageActive
      || deviceId !== this.selectedDeviceId || accountId !== AppServices.instance.auth.cacheAccountId) return;
    this.modelQuotaValues = this.modelQuotaValues.concat(values);
  }

  private positionSelectedModel(area: Area): void {
    this.selectedModelArea = area;
    if (!this.modelPickerPositionPending || this.modelPickerUserMoved || this.modelPickerHeight <= 0) return;
    const top = Number(area.globalPosition.y);
    if (!Number.isFinite(top)) return;
    const delta = top - this.modelPickerTop - (this.modelPickerHeight - Number(area.height)) / 2;
    if (!Number.isFinite(delta)) return;
    this.modelPickerPositionPending = false;
    this.modelPickerScroller.scrollTo({
      xOffset: 0,
      yOffset: Math.max(0, this.modelPickerScroller.currentOffset().yOffset + delta),
      animation: false,
    });
  }

  private composerPickerOpen(): boolean {
    return this.composerPermissionPopupOpen || this.composerAgentPopupOpen || this.composerModelPopupOpen
      || this.localPickerTitle().length > 0;
  }

  private dismissActiveComposerPicker(): boolean {
    if (this.composerModelPopupOpen && this.pickerDetails !== null) {
      this.pickerDetails = null;
      return true;
    }
    if (this.localPickerTitle()) {
      this.getUIContext().getFocusController().clearFocus();
      this.deviceMenuOpen = false;
      this.workspacePopupOpen = false;
      this.worktreeBranchOpen = false;
      return true;
    }
    if (!this.composerPickerOpen()) return false;
    this.dismissComposerControlPopup(this.composerPermissionPopupOpen ? 'permission'
      : this.composerModelPopupOpen ? 'model' : 'agent');
    return true;
  }

  private dismissComposerControlPopup(page: string): void {
    let pendingModelSelection: RuntimeModelOption | null = null;
    if (page === 'permission') this.composerPermissionPopupOpen = false;
    if (page === 'agent') this.composerAgentPopupOpen = false;
    if (page === 'model') {
      this.composerModelPopupOpen = false;
      this.modelEffortPickerKey = '';
      pendingModelSelection = this.pendingPopupModelSelection;
      this.pendingPopupModelSelection = null;
    }
    // Popup 自动退场与模型行主动关闭共用同一条模型提交、焦点恢复路径。
    if (pendingModelSelection !== null) this.selectModel(pendingModelSelection);
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
        || this.composerAgentPopupOpen || this.composerModelPopupOpen) return;
      if (this.composerImages.length > 0 || this.composerFiles.length > 0) return;
      this.composerSurfaceVisible = false;
    }, 0);
  }

  private expandComposerForEditing(): void {
    if (this.creating) return;
    this.composerBlurGeneration += 1;
    this.composerSurfaceVisible = true;
    this.composerFocused = true;
    setTimeout(() => {
      if (!this.pageActive) return;
      try {
        this.getUIContext().getFocusController().requestFocus('new-session-composer-input');
      } catch (_err) {
        // 页面正在切换时保持展开态，下一次点击仍可直接进入输入。
      }
    }, 0);
  }

  private returnToComposerAfterModelSheet(): void {
    const popupWasOpen = this.composerPermissionPopupOpen
      || this.composerAgentPopupOpen || this.composerModelPopupOpen;
    this.restoreComposerFocusOnSheetDisappear = !popupWasOpen;
    this.contextSheetOpen = false;
    this.composerPermissionPopupOpen = false;
    this.composerAgentPopupOpen = false;
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
    // 图片与普通文件共享每条消息的 20 个附件上限，和详情页 Composer 保持一致。
    return Math.max(0, MAX_COMPOSER_IMAGES
      - this.composerImages.length - this.fileQueue.files.length);
  }

  private selectRecentImage(uri: string): void {
    if (uri.length === 0 || this.contextSelectedUris.includes(uri)) return;
    if (this.contextSelectedUris.length >= this.remainingImageSlots()) {
      uiToast(this.getUIContext(), `最多添加 ${MAX_COMPOSER_IMAGES} 张图片`);
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
      uiToast(this.getUIContext(), `最多添加 ${MAX_COMPOSER_IMAGES} 张图片`);
      return;
    }
    this.contextSheetOpen = false;
    this.pickingImages = true;
    const generation = ++this.imagePickerGeneration;
    setTimeout(() => {
      if (generation !== this.imagePickerGeneration) return;
      if (!this.pageActive || this.creating || this.attachmentsDisposed) {
        this.pickingImages = false;
        return;
      }
      pickImageUris(remaining).then((uris: string[]) => {
        if (generation !== this.imagePickerGeneration) return;
        this.pickingImages = false;
        if (this.pageActive && !this.creating && !this.attachmentsDisposed) {
          this.enqueueImageUris(uris);
        }
      }).catch(() => {
        if (generation !== this.imagePickerGeneration) return;
        this.pickingImages = false;
      });
    }, 160);
  }

  private pickScreenshots(): void {
    if (this.pickingImages || this.creating) return;
    const remaining = this.remainingImageSlots();
    if (remaining <= 0) {
      uiToast(this.getUIContext(), `最多添加 ${MAX_COMPOSER_IMAGES} 张图片`);
      return;
    }
    this.contextSheetOpen = false;
    this.pickingImages = true;
    const context = getContext(this) as common.UIAbilityContext;
    const generation = ++this.imagePickerGeneration;
    setTimeout(() => {
      if (generation !== this.imagePickerGeneration) return;
      if (!this.pageActive || this.creating || this.attachmentsDisposed) {
        this.pickingImages = false;
        return;
      }
      pickScreenshotUris(context, remaining).then((uris: string[]) => {
        if (generation !== this.imagePickerGeneration) return;
        this.pickingImages = false;
        if (this.pageActive && !this.creating && !this.attachmentsDisposed) {
          this.enqueueImageUris(uris);
        }
      }).catch(() => {
        if (generation !== this.imagePickerGeneration) return;
        this.pickingImages = false;
        if (this.pageActive && !this.creating && !this.attachmentsDisposed) {
          uiToast(this.getUIContext(), '无法打开截图选择器');
        }
      });
    }, 160);
  }

  private takePhoto(): void {
    if (this.pickingImages || this.creating || this.remainingImageSlots() <= 0) {
      if (this.remainingImageSlots() <= 0) {
        uiToast(this.getUIContext(), `最多添加 ${MAX_COMPOSER_IMAGES} 张图片`);
      }
      return;
    }
    this.contextSheetOpen = false;
    this.pickingImages = true;
    const context = getContext(this) as common.UIAbilityContext;
    const generation = ++this.imagePickerGeneration;
    setTimeout(() => {
      if (generation !== this.imagePickerGeneration) return;
      if (!this.pageActive || this.creating || this.attachmentsDisposed) {
        this.pickingImages = false;
        return;
      }
      takePhotoUri(context).then((uri: string) => {
        if (generation !== this.imagePickerGeneration) return;
        this.pickingImages = false;
        if (this.pageActive && !this.creating && !this.attachmentsDisposed && uri.length > 0) {
          this.enqueueImageUris([uri]);
        }
      }).catch(() => {
        if (generation !== this.imagePickerGeneration) return;
        this.pickingImages = false;
        if (this.pageActive && !this.creating && !this.attachmentsDisposed) {
          uiToast(this.getUIContext(), '无法打开相机');
        }
      });
    }, 160);
  }

  private pickFiles(): void {
    if (this.pickingFiles || this.creating) return;
    if (this.fileQueue.remainingSlots() <= 0) {
      uiToast(this.getUIContext(), '每条消息最多添加 20 个附件');
      return;
    }
    this.contextSheetOpen = false;
    this.fileQueue.pick(getContext(this) as common.UIAbilityContext);
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
      uiToast(this.getUIContext(), `最多添加 ${MAX_COMPOSER_IMAGES} 张图片`);
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
        return uploadImage(candidate, token, this.selectedDeviceId);
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
    if (this.creating || this.incomingBusy) return;
    const image = this.composerImages.find((item: ComposerImage) => item.localId === localId);
    if (image === undefined) return;
    if (!this.forgetIncomingFile(image.uri)) return;
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
    return this.fileQueue.readyFiles();
  }

  private canSend(): boolean {
    if (this.creating || !this.incomingRestored || this.incomingBusy || this.incomingBlocked || !this.incomingDraftMatchesTarget() || this.pickingImages || this.pickingFiles) return false;
    const routeChosen = this.selectedRouteId.length > 0 && this.selectedRouteDevice === this.selectedDeviceId;
    const plugin = this.selectedPickerPlugin();
    if (!this.canCreateOnDevice(this.selectedDeviceId) || this.runtimeCatalogScope !== this.currentRuntimeScope()
      || !this.runtimeDefaultsSettled || (!routeChosen && plugin?.availability !== 'available' && !newSessionRuntimeCanCreate(this.runtimeDefaultsSettled, this.runtimeCatalogReady,
        this.selectedAgentKind, this.currentRuntimeChoice(), this.modelVisibilityOverrides))) return false;
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
    if (this.creating || this.incomingBusy) return;
    const file = this.fileQueue.files.find((item: ComposerFile): boolean => item.localId === localId);
    if (file && !this.forgetIncomingFile(file.uri)) return;
    this.fileQueue.remove(localId);
  }

  private retryComposerFile(localId: string): void {
    this.fileQueue.retry(localId);
  }

  private recycleComposerFileRef(ref: RemoteSerializedAttachment): void {
    const parsed = parseAttachmentOssRef(ref.path);
    if (parsed === null || parsed.ossKey.length === 0) return;
    void AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token !== null && token.length > 0) return deleteUpload(parsed.ossKey, token);
      return Promise.resolve();
    }).catch(() => {});
  }

  private resetRuntimeDefaults(): void {
    this.model = '';
    this.providerId = '';
    this.agentDeviceId = '';
    this.effort = 'medium';
    this.permissionMode = 'auto';
    this.permissionModeBeforePlan = 'auto';
    this.planModeSupported = false;
    this.planModeNative = false;
    this.planModeEnabled = false;
    this.fastMode = false;
    this.fastModeTier = '';
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
    return parseComposerProviderModelOptions(value, agent, this.modelVisibilityOverrides,
      this.model.length === 0 || this.agentDeviceId.length > 0
        ? undefined : { model: this.model, providerId: this.providerId });
  }

  private currentRuntimeScope(): string {
    return runtimeDefaultsScope(AppServices.instance.auth.cacheAccountId, this.selectedDeviceId, this.selectedAgentKind);
  }

  private runtimeRequestIsCurrent(deviceId: string, agent: NewAgentKind, generation: number): boolean {
    return this.pageActive && generation === this.runtimeLoadGeneration
      && deviceId === this.selectedDeviceId && agent === this.selectedAgentKind
      && this.runtimeCatalogScope === this.currentRuntimeScope();
  }

  private currentRuntimeChoice(): NewSessionRuntime {
    const runtime = new NewSessionRuntime();
    runtime.model = this.model;
    runtime.providerId = this.providerId;
    runtime.effort = this.effort;
    runtime.fastMode = this.fastMode;
    runtime.fastModeTier = this.fastMode ? this.fastModeTier : '';
    return runtime;
  }

  private writeRuntimeChoice(markModelChoice: boolean, option: RuntimeModelOption | undefined = undefined): void {
    if (this.selectedDeviceId.length === 0) return;
    // 其他电脑的模型不在被控电脑目录里，不能写成被控电脑的新建默认。
    if (option !== undefined ? option.agentDeviceId.length > 0 : this.agentDeviceId.length > 0) return;
    const active = option === undefined || this.modelOptionIsCurrent(option);
    const runtime = this.currentRuntimeChoice();
    if (option !== undefined) {
      runtime.model = option.id;
      runtime.providerId = option.providerId;
      runtime.effort = this.modelEffortForRow(option);
      runtime.fastMode = this.modelFastForRow(option);
      runtime.fastModeTier = this.modelFastTierForRow(option);
    }
    if (runtime.model.length === 0 || (!active && runtime.providerId.length === 0)) return;
    const deviceId = this.selectedDeviceId;
    const agent = this.selectedAgentKind;
    const accountId = AppServices.instance.auth.cacheAccountId;
    const authEpoch = AppServices.instance.auth.sessionEpoch;
    const scope = runtimeDefaultsScope(accountId, deviceId, agent);
    if (active) this.runtimeChoices.remember(scope, runtime);
    const pref = newSessionDraftPref(agent, runtime, active, markModelChoice);
    void this.runtimePrefWriter.enqueue(scope, async (): Promise<void> => {
      if (AppServices.instance.auth.cacheAccountId !== accountId || AppServices.instance.auth.sessionEpoch !== authEpoch) return;
      await AppServices.instance.openLink(deviceId);
      if (AppServices.instance.auth.cacheAccountId !== accountId || AppServices.instance.auth.sessionEpoch !== authEpoch) return;
      const options = new DlInvokeOptions();
      options.channel = 'maker:apply-new-maker-draft-pref';
      options.args = [pref];
      await AppServices.instance.client.invoke(deviceId, options);
    });
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
      if (!this.runtimeRequestIsCurrent(deviceId, agent, generation)) return;
      const options = new DlInvokeOptions();
      options.channel = 'maker:provider:list';
      const request = new ProviderListOptions();
      request.capabilities = ['provider-logo-kinds-v2'];
      options.args = [request];
      const envelope = await AppServices.instance.client.invoke(deviceId, options);
      if (!this.runtimeRequestIsCurrent(deviceId, agent, generation)) return;
      const result = unwrapInvokeResult(envelope);
      if (!hasProviderCatalog(result)) throw new Error('Invalid provider catalog');
      this.runtimeCatalogReady = true;
      this.pickerCatalogPayload = result;
      const providerOptions = this.parseProviderModelOptions(result, agent);
      this.providerModelOptions = providerOptions;
      if (!this.modelPickerUserMoved && this.composerModelPopupOpen) this.modelPickerPositionPending = true;
      if (this.composerModelPopupOpen || (this.contextSheetOpen && this.contextSheetPage === 'model')) {
        void this.refreshModelQuotas();
      }
      this.remoteAgentLocationSupported = remoteAgentLocationSupported(result);
      this.providerModelAgent = hasProviderCatalog(result) ? agent : '';
      if (result !== undefined && result !== null && typeof result === 'object' && !Array.isArray(result)) {
        this.modelVisibilityOverrides = parseModelVisibilityOverrides(result);
        // Visibility overrides are part of the provider response. Reparse once so a
        // hidden model cannot remain in the list produced before the map was loaded.
        this.providerModelOptions = this.parseProviderModelOptions(result, agent);
        this.providerModelAgent = hasProviderCatalog(result) ? agent : '';
      }
    } catch (failure) {
      if (!this.runtimeRequestIsCurrent(deviceId, agent, generation)) return;
      const unsupported = providerCatalogUnavailable(failure instanceof Error ? failure.message : String(failure));
      if (unsupported || this.providerModelAgent !== agent) this.providerModelOptions = [];
      this.providerModelAgent = unsupported ? '' : agent;
      this.runtimeCatalogReady = unsupported;
      this.modelVisibilityOverrides = new Map();
      if (unsupported) this.remoteAgentLocationSupported = false;
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
    const source = this.visibleModelOptions()
      .filter((option: RuntimeModelOption): boolean => option.agentDeviceId === this.agentDeviceId);
    if (preferredProviderId.length > 0) {
      for (let i = 0; i < source.length; i++) {
        if (source[i].id === modelId && source[i].providerId === preferredProviderId) return source[i];
      }
      if (this.providerModelAgent === this.selectedAgentKind) return undefined;
    }
    for (let i = 0; i < source.length; i++) {
      if (source[i].id === modelId) return source[i];
    }
    return undefined;
  }

  private visibleModelOptions(): RuntimeModelOption[] {
    if (this.providerModelAgent.length > 0 && this.providerModelAgent === this.selectedAgentKind) {
      const remote = this.remoteModelOptions();
      return remote.length > 0 ? this.providerModelOptions.concat(remote) : this.providerModelOptions;
    }
    return this.modelOptions;
  }

  private hostModelNeedsReselection(agent: NewAgentKind): boolean {
    return this.agentDeviceId.length === 0
      && modelNeedsReselection(this.modelVisibilityOverrides, agent, this.model, this.providerId);
  }

  /** 读其他电脑的远程目录：选择器打开时列出所有可用电脑，否则只读已选模型所在那台。 */
  private refreshRemoteAgentCatalogs(pickerOpen: boolean): void {
    const keep: string[] = this.agentDeviceId.length > 0 ? [this.agentDeviceId] : [];
    const listAll = pickerOpen && this.remoteAgentLocationSupported;
    const devices = listAll || keep.length > 0
      ? selectRemoteAgentDevices(AppServices.instance.tasks.deviceList, this.selectedDeviceId, keep,
        harmonyV12String(this.getUIContext().getHostContext(), 'v134_unnamed_computer'))
        .filter((device: RemoteAgentDevice): boolean => listAll || keep.indexOf(device.deviceId) >= 0)
      : [];
    this.remoteAgentDevices = devices;
    AppServices.instance.remoteAgentCatalogs.refresh(devices);
    this.syncRemoteAgentCatalogs();
  }

  private syncRemoteAgentCatalogs(): void {
    this.remoteAgentCatalogList = AppServices.instance.remoteAgentCatalogs.catalogs(this.remoteAgentDevices);
    this.remoteAgentRevision += 1;
    if (this.composerModelPopupOpen || (this.contextSheetOpen && this.contextSheetPage === 'model')) {
      void this.refreshModelQuotas();
    }
  }

  private remoteModelOptions(): RuntimeModelOption[] {
    if (!this.remoteAgentLocationSupported) return [];
    const agent = this.selectedAgentKind;
    const selected = this.agentDeviceId.length > 0 ? this.agentDeviceId : null;
    const key = JSON.stringify([this.remoteAgentRevision, agent, this.model, this.providerId, selected ?? '']);
    if (key !== this.remoteOptionsKey) {
      this.remoteOptionsKey = key;
      let hint: ModelSelectionHint | undefined = undefined;
      if (selected !== null && this.model.length > 0) hint = { model: this.model, providerId: this.providerId };
      this.remoteOptionsCache = remoteAgentModelOptions(this.remoteAgentCatalogList, agent, hint, selected);
    }
    return this.remoteOptionsCache;
  }

  @State private pickerAllProviders: boolean = false;
  @State private pickerModelSearch: string = '';
  @State private pickerDetails: ComposerModelOption | null = null;
  @State private pickerCatalogPayload: Object | undefined = undefined;
  @State private pickerFavoriteItems: Object[] = [];
  @State private pickerFavoritesReady: boolean = false;
  @State private pickerFavoritesBusy: boolean = false;
  @State private pickerPluginProvider: string = '';
  @State private pickerPluginModel: string = 'default';
  @State private pickerPluginModelLabel: string = '';
  private pickerPluginDevice: string = '';

  private selectedPickerPlugin(): PluginEngine | undefined {
    if (this.pickerPluginDevice !== this.selectedDeviceId || !this.pickerPluginProvider) return undefined;
    return AppServices.instance.pluginEngines.find(this.selectedDeviceId, this.pickerPluginProvider);
  }

  private pickDraftPlugin(engine: PluginEngine, model: PluginEngineModel): void {
    if (engine.availability !== 'available' || this.creating) return;
    this.pickerPluginProvider = engine.providerId;
    this.pickerPluginModel = model.id;
    this.pickerPluginModelLabel = model.label;
    this.pickerPluginDevice = this.selectedDeviceId;
    this.selectedRouteId = '';
    this.selectedRouteDevice = '';
    this.dismissComposerControlPopup('model');
  }

  @State private pickerPluginRows: PluginEngine[] = [];
  private pickerRefreshRevision: number = 0;
  private pickerFavoriteUnsubscribe: (() => void) | undefined = undefined;

  private pickerCurrentProvider(): ComposerModelGroup | undefined {
    const groups = this.groupedModelOptions();
    return groups.find((group: ComposerModelGroup): boolean =>
      group.options.some((option: ComposerModelOption): boolean => this.modelOptionIsCurrent(option))) ?? groups[0];
  }

  private async refreshPickerFavorites(): Promise<void> {
    const app = AppServices.instance;
    const device = this.selectedDeviceId;
    const revision = ++this.pickerRefreshRevision;
    const current = (): boolean => this.composerModelPopupOpen && device === this.selectedDeviceId && revision === this.pickerRefreshRevision;
    try {
      const result = await app.modelPickerFavorites(device, 'maker:model-favorites:get', [], current);
      if (current() && Array.isArray(result) && result.length <= 4096) {
        this.pickerFavoriteItems = result as Object[];
        this.pickerFavoritesReady = true;
      }
    } catch (_) {}
  }

  private openPickerExtras(): void {
    this.pickerDetails = null;
    this.pickerFavoriteItems = [];
    this.pickerFavoritesReady = false;
    this.pickerFavoritesBusy = false;
    const device = this.selectedDeviceId;
    const app = AppServices.instance;
    const scope = app.moduleScope;
    this.pickerPluginRows = app.pluginEngines.listCached(device);
    void app.pluginEngines.load(device).then((rows: PluginEngine[]): void => {
      if (this.composerModelPopupOpen && device === this.selectedDeviceId && scope === app.moduleScope) this.pickerPluginRows = rows;
    });
    void this.refreshPickerFavorites();
  }

  private pickerGroups(): ComposerModelGroup[] {
    if (!this.pickerAllProviders) return pickerVisibleGroups(this.groupedModelOptions(),
      this.pickerCurrentProvider()?.key ?? '', false, this.pickerModelSearch);
    const options: ComposerModelOption[] = [];
    for (const harness of NEW_AGENT_OPTIONS) {
      if (harness !== this.selectedAgentKind && false) continue;
      const rows = harness === this.selectedAgentKind ? this.visibleModelOptions()
        : parseComposerProviderModelOptions(this.pickerCatalogPayload, harness, this.modelVisibilityOverrides, undefined, false).concat(
          remoteAgentModelOptions(this.remoteAgentCatalogList, harness, undefined, null));
      for (const row of rows) {
        row.pickerHarness = harness;
        options.push(row);
      }
    }
    return pickerFavorites(pickerVisibleGroups(groupComposerModelOptions(options), '', true, this.pickerModelSearch),
      this.pickerFavoriteItems);
  }

  private async togglePickerFavorite(option: ComposerModelOption): Promise<void> {
    if (!this.pickerFavoritesReady || this.pickerFavoritesBusy || !option.providerId) return;
    const device = this.selectedDeviceId;
    const app = AppServices.instance;
    const scope = app.moduleScope;
    const current = (): boolean => this.composerModelPopupOpen && device === this.selectedDeviceId && scope === app.moduleScope;
    this.pickerFavoritesBusy = true;
    try {
      const mutation = modelFavoriteMutation(option, this.selectedAgentKind, this.modelEffortForRow(option),
        this.modelFastForRow(option), this.pickerFavoriteItems);
      await app.modelPickerFavorites(device, 'maker:model-favorites:apply', [mutation], current);
      if (current()) await this.refreshPickerFavorites();
    } catch (_) {
      if (current()) uiToast(this.getUIContext(), '收藏未保存，请重试');
    } finally {
      if (current()) this.pickerFavoritesBusy = false;
    }
  }

  @Builder
  pickerSearchHeader() {
    Row({ space: 8 }) {
      TextInput({ placeholder: '搜索模型…', text: this.pickerModelSearch })
        .height(44).layoutWeight(1).fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary')).backgroundColor($r('app.color.bg_chip'))
        .onChange((value: string) => { this.pickerModelSearch = value; })
      Button() {
        Row({ space: 6 }) {
        if (!this.pickerAllProviders && (this.pickerCurrentProvider()?.options[0]?.providerId === 'openai'
          || this.pickerCurrentProvider()?.options[0]?.providerId === 'anthropic')) {
          Image(this.pickerCurrentProvider()?.options[0]?.providerId === 'openai' ? $r('app.media.usage_provider_openai')
            : $r('app.media.usage_provider_anthropic'))
            .width(16).height(16).objectFit(ImageFit.Contain).fillColor($r('app.color.text_secondary'))
        } else {
          SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(15).fontColor([$r('app.color.text_secondary')])
        }
        Text(this.pickerAllProviders ? '全部模型' : this.pickerCurrentProvider()?.name ?? '全部模型')
          .fontColor($r('app.color.text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 119 }).textAlign(TextAlign.End)
        }.justifyContent(FlexAlign.End)
      }
      .type(ButtonType.Normal).height(44).constraintSize({ minWidth: 44, maxWidth: 164 })
      .padding({ left: 0, right: 0 }).backgroundColor(Color.Transparent)
      .onClick(() => {
        this.pickerAllProviders = !this.pickerAllProviders;
        this.modelPickerScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
      })
    }.width('100%').padding({ left: 12, right: 12, bottom: 4 })
  }

  private groupedModelOptions(): ComposerModelGroup[] {
    return groupComposerModelOptions(this.visibleModelOptions());
  }

  private modelOptionKey(option: RuntimeModelOption): string {
    return composerModelKey(option);
  }

  private modelRuntimeKey(option: RuntimeModelOption): string {
    return this.currentRuntimeScope() + ':' + this.modelOptionKey(option);
  }

  private remoteModelMemoryKey(option: RuntimeModelOption): string {
    return remoteModelPreferenceKey(this.selectedAgentKind, option.agentDeviceId, option.providerId, option.id);
  }

  private modelOptionIsCurrent(option: RuntimeModelOption): boolean {
    return option.id === this.model && option.providerId === this.providerId
      && option.agentDeviceId === this.agentDeviceId;
  }

  private modelEffortForRow(option: RuntimeModelOption): string {
    if (this.modelOptionIsCurrent(option) && this.effort.length > 0) return this.effort;
    const remembered = option.agentDeviceId.length > 0
      ? AppServices.instance.remoteModelPreferences.read(this.remoteModelMemoryKey(option), 'effort')
      : this.modelEffortMemory.get(this.modelRuntimeKey(option));
    if (remembered !== undefined && this.modelSupportsEffort(option, remembered)) return remembered;
    if (option.defaultEffort.length > 0) return option.defaultEffort;
    return option.efforts.length > 0 ? option.efforts[0] : '';
  }

  private modelFastForRow(option: RuntimeModelOption): boolean {
    if (!this.fastModeCapability || !option.supportsFastMode) return false;
    if (this.modelOptionIsCurrent(option)) return this.fastMode;
    const key = this.modelRuntimeKey(option);
    // 记忆的超快档在目标模型撤回能力时整体关闭（对齐 Mobile isFastRestorable）。
    const remembered = option.agentDeviceId.length > 0
      ? AppServices.instance.remoteModelPreferences.read(this.remoteModelMemoryKey(option), 'speed') : '';
    return (remembered.length > 0 ? remembered !== 'standard' : this.modelFastMemory.get(key) ?? false)
      && ultrafastRestorable(remembered === 'ultrafast' ? MODEL_SPEED_ULTRAFAST
        : this.modelFastTierMemory.get(key) ?? '', this.selectedAgentKind, option.supportsUltrafastMode);
  }

  private modelFastTierForRow(option: RuntimeModelOption): string {
    if (!this.modelFastForRow(option)) return '';
    if (this.modelOptionIsCurrent(option)) return this.fastModeTier;
    if (option.agentDeviceId.length > 0
      && AppServices.instance.remoteModelPreferences.read(this.remoteModelMemoryKey(option), 'speed') === 'ultrafast') {
      return MODEL_SPEED_ULTRAFAST;
    }
    return this.modelFastTierMemory.get(this.modelRuntimeKey(option)) ?? '';
  }

  private modelRowSupportsUltrafast(option: RuntimeModelOption): boolean {
    return this.fastModeCapability && option.supportsFastMode && option.supportsUltrafastMode
      && this.selectedAgentKind === 'codex';
  }

  private modelSpeedForRow(option: RuntimeModelOption): string {
    if (!this.modelFastForRow(option)) return 'standard';
    return this.modelFastTierForRow(option) === MODEL_SPEED_ULTRAFAST ? 'ultrafast' : 'fast';
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
    if (option.agentDeviceId.length > 0) {
      AppServices.instance.remoteModelPreferences.save(this.remoteModelMemoryKey(option), 'effort', effort);
    }
    if (this.modelOptionIsCurrent(option)) {
      this.runtimeEffortTouchedGeneration = this.runtimeLoadGeneration;
      this.effort = effort;
    }
    this.error = '';
    this.writeRuntimeChoice(false, option);
  }

  private setModelRowFast(option: RuntimeModelOption, enabled: boolean): void {
    this.setModelRowSpeed(option, enabled ? 'fast' : 'standard');
  }

  private setModelRowSpeed(option: RuntimeModelOption, speed: string): void {
    if (this.creating || !this.fastModeCapability || !option.supportsFastMode) return;
    if (speed === 'ultrafast' && !this.modelRowSupportsUltrafast(option)) return;
    const enabled = speed !== 'standard';
    const tier = speed === 'ultrafast' ? MODEL_SPEED_ULTRAFAST : '';
    const key = this.modelRuntimeKey(option);
    const next = new Map(this.modelFastMemory);
    next.set(key, enabled);
    this.modelFastMemory = next;
    const tiers = new Map(this.modelFastTierMemory);
    tiers.set(key, tier);
    this.modelFastTierMemory = tiers;
    if (option.agentDeviceId.length > 0) {
      AppServices.instance.remoteModelPreferences.save(this.remoteModelMemoryKey(option), 'speed', speed);
    }
    if (this.modelOptionIsCurrent(option)) {
      this.runtimeFastTouchedGeneration = this.runtimeLoadGeneration;
      this.fastMode = enabled;
      this.fastModeTier = tier;
    }
    this.error = '';
    this.writeRuntimeChoice(false, option);
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
    if (this.hostModelNeedsReselection(this.selectedAgentKind)) {
      return harmonyV12String(this.getUIContext().getHostContext(), 'v132_model_reselect');
    }
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
    const previousGeneration = this.runtimeLoadGeneration;
    const scope = runtimeDefaultsScope(AppServices.instance.auth.cacheAccountId, deviceId, agent);
    const sameScope = this.runtimeCatalogScope === scope;
    this.runtimeCatalogScope = scope;
    const generation = ++this.runtimeLoadGeneration;
    this.runtimeCatalogReady = false;
    this.runtimeDefaultsSettled = false;
    this.runtimeToolbarLoadActive = true;
    this.composerToolbarReady = false;
    if (deviceId.length === 0) {
      this.runtimeToolbarLoadActive = false;
      this.composerToolbarReady = true;
      return;
    }
    if (!sameScope) this.resetRuntimeDefaults();
    const localChoice = this.runtimeChoices.read(scope);
    if (localChoice !== null) {
      this.model = localChoice.model;
      this.providerId = localChoice.providerId;
      this.agentDeviceId = '';
      this.effort = localChoice.effort;
      this.fastMode = localChoice.fastMode;
      this.fastModeTier = localChoice.fastMode ? localChoice.fastModeTier : '';
      this.runtimeModelTouchedGeneration = generation;
      this.runtimeEffortTouchedGeneration = generation;
      this.runtimeFastTouchedGeneration = generation;
    }
    if (sameScope && previousGeneration > 0) {
      if (this.runtimeModelTouchedGeneration === previousGeneration) this.runtimeModelTouchedGeneration = generation;
      if (this.runtimeEffortTouchedGeneration === previousGeneration) this.runtimeEffortTouchedGeneration = generation;
      if (this.runtimePermissionTouchedGeneration === previousGeneration) this.runtimePermissionTouchedGeneration = generation;
      if (this.runtimePlanTouchedGeneration === previousGeneration) this.runtimePlanTouchedGeneration = generation;
      if (this.runtimeFastTouchedGeneration === previousGeneration) this.runtimeFastTouchedGeneration = generation;
    }
    // 编辑失败返回的新建草稿在能力目录加载期间也应保持可见，避免用户看到并操作到临时默认值。
    this.applyPendingEditRuntime(deviceId, agent, false);
    try {
      await AppServices.instance.openLink(deviceId);
      if (!this.runtimeRequestIsCurrent(deviceId, agent, generation)) return;
      const options = new DlInvokeOptions();
      options.channel = 'maker:get-capabilities';
      options.args = [agent];
      const envelope = await AppServices.instance.client.invoke(deviceId, options);
      const result = unwrapInvokeResult(envelope);
      if (!this.runtimeRequestIsCurrent(deviceId, agent, generation)
        || result === undefined || result === null || typeof result !== 'object' || Array.isArray(result)) return;
      const capabilities = result as Record<string, Object>;
      this.modelOptions = parseModelOptions(capabilities['availableModels']);
      this.effortOptions = this.parseRuntimeChoices(capabilities['effortLevels'], false);
      this.permissionOptions = this.parseRuntimeChoices(capabilities['permissionModes'], true);
      this.fastModeCapability = readBool(capabilities, 'hasFastMode', false);

      this.planModeNative = this.capabilityHasNativePlan(capabilities);
      this.planModeSupported = this.planModeNative || this.capabilityHasLegacyPlan(capabilities);
      const hostRuntime = await readNewSessionRuntimeDefaults(
        async (): Promise<Object | undefined> => {
          const defaultsOptions = new DlInvokeOptions();
          defaultsOptions.channel = 'maker:get-new-maker-defaults';
          defaultsOptions.args = [agent];
          return unwrapInvokeResult(await AppServices.instance.client.invoke(deviceId, defaultsOptions));
        },
        (): boolean => this.runtimeRequestIsCurrent(deviceId, agent, generation),
        (): Promise<void> => new Promise<void>((resolve) => setTimeout(resolve, 1500)),
      );
      if (!this.runtimeRequestIsCurrent(deviceId, agent, generation)) return;
      const preferredRuntime = this.runtimeChoices.read(scope) ?? hostRuntime;
      if (this.runtimeModelTouchedGeneration !== generation && preferredRuntime !== null) {
        this.model = preferredRuntime.model;
        this.providerId = preferredRuntime.providerId;
        this.agentDeviceId = '';
      }
      await this.loadProviderModelOptions(agent, deviceId, generation);
      if (!this.runtimeRequestIsCurrent(deviceId, agent, generation) || !this.runtimeCatalogReady) return;

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
        const runtime = pickNewSessionRuntime(agent, preferredRuntime, source, this.modelVisibilityOverrides);
        this.model = runtime.model;
        this.providerId = runtime.providerId;
        this.agentDeviceId = '';
        if (!effortTouched) this.effort = runtime.effort;
        if (!fastTouched) {
          this.fastMode = this.fastModeCapability && runtime.fastMode;
          this.fastModeTier = this.fastMode ? runtime.fastModeTier : '';
        }
        selectedModel = this.findModelOption(this.model, this.providerId);
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
    } catch (failure) {
      if (this.runtimeRequestIsCurrent(deviceId, agent, generation)) {
        this.runtimeCatalogReady = false;
      }
    } finally {
      if (this.runtimeRequestIsCurrent(deviceId, agent, generation)) {
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
        this.runtimeDefaultsSettled = true;
        if (!this.runtimeCatalogReady) {
          this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v131_catalog_retry');
        } else if (this.hostModelNeedsReselection(agent)) {
          this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v132_model_reselection_required');
        } else if (this.model.trim().length === 0) {
          this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v132_model_required');
        }
      }
    }
  }

  private async loadBrowsePath(targetPath: string): Promise<void> {
    if (this.selectedDeviceId.length === 0 || this.creating) return;
    const generation = ++this.browseGeneration;
    const deviceId = this.selectedDeviceId;
    const accountId = AppServices.instance.auth.cacheAccountId;
    const isCurrent = (): boolean => this.pageActive && generation === this.browseGeneration
      && deviceId === this.selectedDeviceId && accountId === AppServices.instance.auth.cacheAccountId;
    this.browseLoading = true;
    this.browseError = '';
    this.browseDrives = [];
    try {
      await AppServices.instance.openLink(deviceId);
      if (!isCurrent()) return;
      const options = new DlInvokeOptions();
      options.channel = DlChannels.FS_LIST_DIR;
      const request: Record<string, Object> = {};
      request['path'] = targetPath.trim().length > 0 ? targetPath.trim() : '~';
      options.args = [request];
      const envelope = await AppServices.instance.client.invoke(deviceId, options);
      if (!isCurrent()) return;
      const result = unwrapInvokeResult(envelope);
      if (result === undefined || result === null || typeof result !== 'object' || Array.isArray(result)) {
        throw new Error('目录返回格式无效');
      }
      const record = result as Record<string, Object>;
      this.browsePath = readStr(record, 'resolvedPath');
      this.browseParent = readStr(record, 'parent');
      this.browseEntries = this.parseDirectories(record['entries']);
      this.browseDrives = normalizeRemoteDirectoryDrives(record['drives']);
      this.browseLoading = false;
      let drivesPending = record['drivesPending'];
      for (let attempt = 0; shouldRetryRemoteBrowseDrives(drivesPending, attempt); attempt += 1) {
        if (!isCurrent()) return;
        try {
          const retryOptions = new DlInvokeOptions();
          retryOptions.channel = DlChannels.FS_LIST_DIR;
          const retryRequest: Record<string, Object> = {};
          retryRequest['path'] = this.browsePath;
          retryOptions.args = [retryRequest];
          const retryEnvelope = await AppServices.instance.client.invoke(deviceId, retryOptions);
          if (!isCurrent()) return;
          const retryResult = unwrapInvokeResult(retryEnvelope);
          if (retryResult === undefined || retryResult === null || typeof retryResult !== 'object' || Array.isArray(retryResult)) return;
          const retryRecord = retryResult as Record<string, Object>;
          this.browseDrives = normalizeRemoteDirectoryDrives(retryRecord['drives']);
          drivesPending = retryRecord['drivesPending'];
        } catch {
          return;
        }
      }
    } catch (failure) {
      if (!isCurrent()) return;
      this.browseEntries = [];
      this.browseError = failure instanceof Error ? failure.message : '无法读取远端目录';
    } finally {
      if (generation === this.browseGeneration) this.browseLoading = false;
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

  private browseDriveMenuItems(): MenuElement[] {
    const items: MenuElement[] = [];
    for (const drive of this.browseDrives) {
      items.push({
        value: drive.name,
        action: (): void => { void this.loadBrowsePath(drive.path); },
      });
    }
    return items;
  }

  private browseDriveLabel(): string {
    const current = this.browseDrives.find((drive: NewSessionDirectoryDrive): boolean => drive.current);
    return current?.name ?? harmonyV12String(this.getUIContext().getHostContext(), 'v132_choose_drive');
  }

  /**
   * 对齐 Mobile `app/sessions/new.tsx` 项目选择器末尾的「新建项目」：电脑项目设置版本 ≥ 6 时
   * 打开新建项目表单；版本更旧、尚未读到或没有承载者时退回目录浏览。
   */
  private openProjectCreate(): void {
    if (this.selectedDeviceId.length === 0) {
      uiToast(this.getUIContext(), '请先选择一台在线电脑');
      return;
    }
    const create = this.onCreateProject;
    if (create === null || AppServices.instance.taskProjectAliases.settingsVersion(this.selectedDeviceId) < 6) {
      this.openProjectBrowse();
      return;
    }
    this.workspacePopupOpen = false;
    create(this.selectedDeviceId);
  }

  /** 新建项目保存后由首页回传；只接受当前草稿所选电脑上的项目。 */
  private applyCreatedProject(): void {
    const parts = this.createdProject.split('\n');
    if (parts.length < 3) return;
    const device = parts[0];
    const path = parts.slice(1, parts.length - 1).join('\n');
    if (device.length === 0 || device !== this.selectedDeviceId || path.trim().length === 0) return;
    this.selectProject(path);
  }

  private openProjectBrowse(): void {
    this.workspaceEditRevision += 1;
    if (this.selectedDeviceId.length === 0) {
      uiToast(this.getUIContext(), '请先选择一台在线电脑');
      return;
    }
    this.workspaceKind = 'project';
    this.workspacePopupOpen = false;
    this.browseOpen = true;
    this.contextSheetPage = 'workspace';
    this.contextSheetOpen = true;
    this.showHiddenDirectories = false;
    void this.loadBrowsePath((this.workingDir.trim().length > 0 ? this.workingDir : '~'));
  }

  private selectCurrentBrowsePath(): void {
    if (this.browsePath.length === 0) return;
    this.selectProject(this.browsePath);
    this.contextSheetOpen = false;
  }

  private createOptions(sessionId: string = ''): Record<string, Object> {
    const options: Record<string, Object> = {};
    options['agentKind'] = this.selectedAgentKind;
    options['workspaceKind'] = this.workspaceKind;
    options['model'] = this.model.trim();
    options['permissionMode'] = !this.planModeNative && this.planModeEnabled
      ? 'plan' : this.permissionMode;
    options['planMode'] = this.planModeNative && this.planModeEnabled;
    options['fastMode'] = fastModeWireValue(this.fastMode, this.fastModeTier);
    if (this.providerId.trim().length > 0) options['providerId'] = this.providerId.trim();
    // 远程 Agent：Agent 在选中模型所在的电脑运行（对齐 Mobile newSession 的 agentDeviceId）。
    if (this.agentDeviceId.length > 0) options['agentDeviceId'] = this.agentDeviceId;
    if (this.effort.trim().length > 0) options['effort'] = this.effort.trim();
    if (this.workspaceKind === 'project') options['workingDir'] = this.workingDir;
    if (sessionId.length > 0) options['id'] = sessionId;
    return options;
  }

  private buildOptimisticSession(
    sessionId: string,
    text: string,
    images: RemoteImageRef[] = [],
    files: RemoteSerializedAttachment[] = [],
  ): RemoteSession {
    const session = new RemoteSession();
    session.id = sessionId;
    session.workspaceKind = this.workspaceKind;
    session.workingDir = this.workspaceKind === 'project' ? this.workingDir : '';
    session.model = this.model.trim();
    session.providerId = this.providerId.trim();
    session.effort = this.effort.trim();
    session.permissionMode = !this.planModeNative && this.planModeEnabled ? 'plan' : this.permissionMode;
    session.planModeEnabled = this.planModeEnabled;
    session.fastMode = this.fastMode;
    session.fastModeTier = this.fastMode ? this.fastModeTier : '';
    session.agentKind = this.selectedAgentKind === 'claude-code' ? 'cc' : this.selectedAgentKind;
    session.status = 'active';
    session.pendingLocalCreation = true;
    // 纯图片 / 纯文件首条消息也要立即有可读标题：文字优先，其次第一个附件的
    // 展示名（去路径），再退到类别词。远端权威标题到达后覆盖本地预览。
    const attachmentNames: string[] = [];
    for (let i = 0; i < images.length; i++) {
      const name = images[i].originalName || images[i].name;
      if (name.length > 0) attachmentNames.push(name);
    }
    for (let i = 0; i < files.length; i++) {
      const name = files[i].originalName || files[i].name;
      if (name.length > 0) attachmentNames.push(name);
    }
    const optimisticTitle = deriveOptimisticSessionTitle(
      text, attachmentNames, images.length > 0);
    if (optimisticTitle.length > 0) session.title = optimisticTitle;
    if (text.length > 0) {
      session.preview = text;
    }
    const now = new Date().toISOString();
    session.createdAt = now;
    session.updatedAt = now;
    session.userSendAt = now;
    return session;
  }

  /** Resolve runtime permissions/plan/speed against the final target engine without changing
   * the user's underlying draft, preferences or selected model. */
  private async applyRoutingCreation(params: NewSessionCreationParams, route: ModelRoute, isCurrent: () => boolean): Promise<void> {
    const kind: NewAgentKind = route.agentKind === 'codex' ? 'codex' : route.agentKind === 'pi' ? 'pi' : 'claude-code';
    const capabilitiesRequest = new DlInvokeOptions(); capabilitiesRequest.channel = 'maker:get-capabilities'; capabilitiesRequest.args = [kind];
    const rawCapabilities = unwrapInvokeResult(await AppServices.instance.client.invoke(params.deviceId, capabilitiesRequest));
    if (!isCurrent()) throw new Error('MODEL_ROUTING_STALE');
    const capabilities = recordOrEmpty(rawCapabilities);
    if (!Array.isArray(capabilities['permissionModes'])) throw new Error('MODEL_ROUTING_CAPABILITIES_UNAVAILABLE');
    let row: RuntimeModelOption | undefined = undefined;
    if (!route.agentDeviceId) {
      const providerRequest = new DlInvokeOptions(); providerRequest.channel = 'maker:provider:list';
      const providerOptions = new ProviderListOptions(); providerOptions.capabilities = ['provider-logo-kinds-v2']; providerRequest.args = [providerOptions];
      try {
        const payload = unwrapInvokeResult(await AppServices.instance.client.invoke(params.deviceId, providerRequest));
        if (!isCurrent()) throw new Error('MODEL_ROUTING_STALE');
        if (!hasProviderCatalog(payload)) throw new Error('MODEL_ROUTING_CATALOG_INVALID');
        const rows = parseComposerProviderModelOptions(payload, kind, parseModelVisibilityOverrides(payload), undefined);
        row = rows.find((option: RuntimeModelOption): boolean => option.id === route.model && option.providerId === route.providerId);
        if (!row || row.suspended || row.availability === 'requires_payment') throw new Error('MODEL_ROUTING_SOURCE_UNAVAILABLE');
      } catch (error) {
        if (!providerCatalogUnavailable(String(error))) {
          if (error instanceof Error) throw error; throw new Error('MODEL_ROUTING_CATALOG_UNAVAILABLE');
        }
        // An older host may resolve routes but lack the provider catalogue. Trust its concrete
        // resolution, never a same-name provider from another computer or the old draft.
      }
    } else {
      const hint: ModelSelectionHint = { model: route.model, providerId: route.providerId };
      row = remoteAgentModelOptions(this.remoteAgentCatalogList, kind, hint, route.agentDeviceId).find((option: RuntimeModelOption): boolean =>
        option.agentDeviceId === route.agentDeviceId && option.providerId === route.providerId && option.id === route.model);
    }
    if (!isCurrent()) throw new Error('MODEL_ROUTING_STALE');
    const runtime = routedCreationRuntime(route, capabilities, row,
      this.permissionMode === 'plan' ? this.permissionModeBeforePlan : this.permissionMode, this.planModeEnabled);
    const options: Record<string, Object> = {};
    for (const key of Object.keys(params.createOptions)) {
      if (key !== 'agentDeviceId' && key !== 'effort') options[key] = params.createOptions[key];
    }
    params.createOptions = options;
    params.createOptions['agentKind'] = kind; params.createOptions['model'] = route.model;
    params.createOptions['providerId'] = route.providerId;
    if (route.agentDeviceId) params.createOptions['agentDeviceId'] = route.agentDeviceId;
    if (runtime.effort) params.createOptions['effort'] = runtime.effort;
    params.createOptions['permissionMode'] = runtime.permissionMode; params.createOptions['planMode'] = runtime.planMode;
    params.createOptions['fastMode'] = runtime.fastMode;
    params.planModeArm = runtime.planModeArm; params.legacyPlanRestore = runtime.legacyPlanRestore;
    params.session.agentKind = kind === 'claude-code' ? 'cc' : kind;
    params.session.model = route.model; params.session.providerId = route.providerId; params.session.agentDeviceId = route.agentDeviceId;
    params.session.effort = runtime.effort; params.session.permissionMode = runtime.permissionMode;
    params.session.planModeEnabled = runtime.planModeEnabled;
    params.session.fastMode = runtime.fastMode === true || runtime.fastMode === MODEL_SPEED_ULTRAFAST;
    params.session.fastModeTier = runtime.fastMode === MODEL_SPEED_ULTRAFAST ? MODEL_SPEED_ULTRAFAST : '';
  }

  private async send(): Promise<void> {
    const text = this.input.trim();
    if (this.creating || !this.incomingRestored || this.incomingBusy || this.incomingBlocked || this.pickingImages || this.pickingFiles) return;
    if (!this.incomingDraftMatchesTarget()) {
      this.error = harmonyV12String(this.getUIContext().getHostContext(), 'incoming_share_failed'); return;
    }
    let uploading = false;
    let failed = false;
    for (let i = 0; i < this.composerImages.length; i++) {
      if (this.composerImages[i].status === 'uploading') uploading = true;
      if (this.composerImages[i].status === 'failed') failed = true;
    }
    if (uploading) {
      uiToast(this.getUIContext(), '图片上传中，请稍候');
      return;
    }
    if (failed) {
      uiToast(this.getUIContext(), '请重试或移除上传失败的图片');
      return;
    }
    if (this.fileQueue.hasUploading()) {
      uiToast(this.getUIContext(), '文件上传中，请稍候');
      return;
    }
    if (this.fileQueue.hasFailed()) {
      uiToast(this.getUIContext(), '请重试或移除上传失败的文件');
      return;
    }
    const readyImages = this.readyComposerImages();
    const readyFiles = this.readyComposerFiles();
    if (text.length === 0 && readyImages.length === 0 && readyFiles.length === 0) return;
    if (!this.canCreateOnDevice(this.selectedDeviceId)) {
      this.error = '请选择一台在线且允许远程控制的电脑';
      return;
    }
    if (!this.runtimeDefaultsSettled || this.runtimeCatalogScope !== this.currentRuntimeScope()) {
      this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v132_defaults_loading');
      return;
    }
    const plugin = this.selectedPickerPlugin();
    const pluginChosen = plugin?.availability === 'available';
    if (this.pickerPluginDevice === this.selectedDeviceId && this.pickerPluginProvider && !pluginChosen) {
      this.error = '当前插件引擎不可用';
      return;
    }
    if (pluginChosen && this.workspaceKind === 'project' && this.worktreeEnabled) {
      this.error = '当前插件引擎暂不能与 worktree 一同创建';
      return;
    }
    const routeChosen = this.selectedRouteId.length > 0 && this.selectedRouteDevice === this.selectedDeviceId;
    if (!pluginChosen && !routeChosen && !this.runtimeCatalogReady) {
      this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v131_catalog_retry');
      if (!this.runtimeToolbarLoadActive) void this.loadRuntimeDefaults(this.selectedDeviceId, this.selectedAgentKind);
      return;
    }
    const generation = this.runtimeLoadGeneration;
    const deviceId = this.selectedDeviceId;
    const agent = this.selectedAgentKind;
    const ownerEpoch = AppServices.instance.auth.sessionEpoch;
    const isCurrent = (): boolean => this.runtimeRequestIsCurrent(deviceId, agent, generation)
      && ownerEpoch === AppServices.instance.auth.sessionEpoch && AppServices.instance.auth.isLoggedIn;
    this.creating = true;
    if (!pluginChosen && !routeChosen) await this.loadProviderModelOptions(agent, deviceId, generation);
    if (!isCurrent()) {
      this.creating = false;
      return;
    }
    this.creating = false;
    if (!pluginChosen && !routeChosen && !this.runtimeCatalogReady) {
      this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v131_catalog_retry');
      return;
    }
    if (!pluginChosen && !routeChosen && this.hostModelNeedsReselection(agent)) {
      this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v132_model_reselection_required');
      return;
    }
    const selectedModel = this.findModelOption(this.model, this.providerId);
    const ordinaryModelReady = this.model.trim().length > 0 && selectedModel !== undefined
      && !selectedModel.suspended && selectedModel.availability !== 'requires_payment'
      && !this.hostModelNeedsReselection(agent);
    if (!pluginChosen && !routeChosen && !ordinaryModelReady) {
      this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v132_model_required');
      return;
    }
    if (this.workspaceKind === 'project' && this.workingDir.trim().length === 0) {
      this.error = '请选择项目目录';
      this.workspacePopupOpen = true;
      return;
    }
    this.creating = true;
    this.error = '';
    const worktreeRequested = this.workspaceKind === 'project' && this.worktreeEnabled;
    const worktreeContext = this.getUIContext().getHostContext();
    if (this.workspaceKind === 'project' && this.worktreeLoading) {
      this.error = '正在检查项目的 worktree 设置，请稍候';
      this.creating = false;
      return;
    }
    if (worktreeRequested && (!this.worktreeTarget.supported || this.worktreeLoading || worktreeContext === undefined)) {
      this.error = '当前项目暂不能创建 worktree';
      this.creating = false;
      return;
    }
    const sessionId = util.generateRandomUUID();
    const firstMessageClientId = AppServices.instance.inputQueue.createDocumentClientId();
    const params = new NewSessionCreationParams();
    params.deviceId = this.selectedDeviceId;
    params.session = this.buildOptimisticSession(sessionId, text, readyImages, readyFiles);
    params.createOptions = this.createOptions(sessionId);
    if (pluginChosen && plugin !== undefined) {
      params.createOptions['agentKind'] = 'acp';
      params.createOptions['providerId'] = plugin.providerId;
      params.createOptions['model'] = this.pickerPluginModel;
      params.createOptions['fastMode'] = false;
      params.createOptions['effort'] = '';
      const pluginOptions: Record<string, Object> = {};
      for (const key of Object.keys(params.createOptions)) {
        if (key !== 'agentDeviceId') pluginOptions[key] = params.createOptions[key];
      }
      params.createOptions = pluginOptions;
      params.session.agentKind = 'acp';
      params.session.providerId = plugin.providerId;
      params.session.model = this.pickerPluginModel;
      params.session.effort = '';
      params.session.fastMode = false;
      params.session.fastModeTier = '';
    }
    if (worktreeRequested && worktreeContext !== undefined) {
      const app = AppServices.instance;
      const owner = app.usageCardOwner;
      const reservation = worktreeReservation(sessionId, this.worktreeTarget.baseRepo, this.worktreeBranch);
      const invoke = app.newSessionWorktree(params.deviceId, (): boolean => owner === app.usageCardOwner);
      const preparation = new WorktreePreparation(worktreeContext, app.newSessionWorktreeLedgerKey(params.deviceId),
        invoke, reservation);
      params.prepareWorktree = (current: () => boolean): Promise<string> => preparation.prepare(current);
      params.finishWorktree = (claimed: boolean): Promise<void> => preparation.finish(claimed);
    }
    params.firstMessageClientId = firstMessageClientId;
    params.firstMessageText = text;
    params.firstMessageImages = readyImages.slice();
    params.firstMessageFiles = readyFiles.slice();
    params.planModeArm = this.planModeNative && this.planModeEnabled;
    params.legacyPlanRestore = !this.planModeNative && this.planModeEnabled
      ? (this.permissionModeBeforePlan || this.permissionMode) : '';
    let routeTicket: ModelRoutingTicket | null = null;
    if (this.selectedRouteId && this.selectedRouteDevice === deviceId) {
      const routing = AppServices.instance.modelRouting;
      const context = new ModelRoutingContext();
      context.hasImages = readyImages.length > 0;
      if (this.routingSnapshot.catalog?.expandedRoutes.some((row: ModelRouteRow): boolean => row.id === this.selectedRouteId) === true) {
        context.effort = this.effort;
        context.fastMode = fastModeWireValue(this.fastMode, this.fastModeTier);
      }
      try {
        routeTicket = await routing.prepare(deviceId, this.selectedRouteId, context);
        if (!this.pageActive || deviceId !== this.selectedDeviceId
          || generation !== this.runtimeLoadGeneration) {
          routing.cancel(routeTicket);
          this.creating = false;
          return;
        }
        const route = routing.routeFor(routeTicket);
        if (route !== null) {
          await this.applyRoutingCreation(params, route, isCurrent);
        } else {
          // A routed send does not depend on the underlying catalog. A kept-model result
          // does: refresh it on this branch before applying the ordinary creation gate.
          await this.loadProviderModelOptions(agent, deviceId, generation);
          const fallback = this.findModelOption(this.model, this.providerId);
          if (!isCurrent()) { routing.cancel(routeTicket); this.creating = false; return; }
          if (!this.runtimeCatalogReady || !fallback || fallback.suspended || fallback.availability === 'requires_payment'
            || this.hostModelNeedsReselection(agent)) {
            routing.release(routeTicket); this.creating = false;
            this.error = harmonyV12String(this.getUIContext().getHostContext(), 'v139_route_unavailable'); return;
          }
        }
        if (!isCurrent()) { routing.cancel(routeTicket); this.creating = false; return; }
        const ticket = routeTicket;
        const note = buildModelRoutingNote(ticket.result, this.currentModelLabel(), '', (id: string): string =>
          this.devices.find((device: PresenceSnapshot): boolean => device.deviceId === id)?.deviceName || id);
        params.beforeFirstInput = (): Promise<void> => routing.bindBeforeFirstInput(ticket, sessionId);
        params.onFirstInputAccepted = (): Promise<void> => routing.accepted(ticket, sessionId, note)
          .finally((): void => routing.release(ticket));
      } catch (failure) {
        if (routeTicket !== null) routing.cancel(routeTicket);
        this.creating = false;
        const unsupported = failure instanceof Error
          && failure.message.indexOf('MODEL_ROUTING_ENGINE_UNSUPPORTED') >= 0;
        this.error = harmonyV12String(this.getUIContext().getHostContext(),
          unsupported ? 'v139_route_engine' : 'v139_route_unavailable');
        return;
      }
    }
    for (const image of this.composerImages) {
      if (image.status === 'ready' && image.ref !== null) {
        AppServices.instance.localAttachmentPreviews.remember(this.selectedDeviceId, image.ref.url, image.uri);
      }
    }
    const bridge = AppServices.instance.incomingComposer, delivery = this.incomingDelivery;
    let incomingPrepared = false;
    let reservationAttempted = false;
    try {
      if (!isCurrent()) throw new Error('NEW_SESSION_STALE');
      if (bridge !== null && delivery !== null && delivery.batchIds.length > 0) {
        if (delivery.target.ownerKey !== AppServices.instance.usageCardOwner || delivery.target.deviceId !== params.deviceId) throw new Error('INCOMING_COMPOSER_STALE');
        delivery.document = this.newSessionDocument;
        bridge.prepareInput(delivery, firstMessageClientId, sessionId); incomingPrepared = true;
      }
      const firstDocument = serializeComposerDocument(this.newSessionDocument);
      params.firstMessageText = firstDocument.text;
      reservationAttempted = true;
      AppServices.instance.inputQueue.reserveDocument(params.deviceId, params.session, firstDocument, readyImages, readyFiles, firstMessageClientId);
      if (incomingPrepared && bridge !== null && delivery !== null) {
        if (!AppServices.instance.inputQueue.hasPersistedDocument(params.deviceId, sessionId, firstMessageClientId)) throw new Error('INCOMING_COMPOSER_RESERVATION_MISSING');
        // Commit owned synchronously before start() can dispatch. Garbage cleanup is independent.
        void bridge.reconcileInput(delivery.target, firstMessageClientId, 'owned');
      }
    } catch (error) {
      // No remote creation/dispatch has started. Remove only this exact reservation before
      // restoring absence; another tap must never leave the earlier copy queued as well.
      let reservationRemoved = !reservationAttempted;
      if (reservationAttempted) {
        try {
          AppServices.instance.inputQueue.discardReserved(params.deviceId, sessionId, firstMessageClientId);
          reservationRemoved = true;
        } catch { this.incomingBlocked = true; }
      }
      if (incomingPrepared && reservationRemoved && bridge !== null && delivery !== null) {
        try { void bridge.reconcileInput(delivery.target, firstMessageClientId, 'absent'); }
        catch { this.incomingBlocked = true; }
      }
      if (routeTicket !== null) AppServices.instance.modelRouting.cancel(routeTicket);
      this.creating = false;
      this.error = incomingPrepared ? harmonyV12String(this.getUIContext().getHostContext(), 'incoming_share_failed')
        : `消息未保存：${error instanceof Error ? error.message : String(error)}`; return;
    }
    AppServices.instance.newSessionCreations.start(params);
    this.cancelNewSessionDraftCheckpoint();
    AppServices.instance.composerDrafts.clear(NEW_SESSION_COMPOSER_DRAFT_ID, this.newSessionDraftDevice);
    this.newSessionDocument = emptyComposerDocument(); this.input = '';
    this.incomingDelivery = null; this.incomingConsumedKey = ''; this.incomingBlocked = false;
    this.attachmentsHandedOff = true;
    // creation store 已持有首条附件的独立引用；从页面镜像移除但不调用回收，
    // 这样页面复用或创建失败回详情时不会显示/回收同一批已交接资源。
    for (let i = 0; i < this.composerImages.length; i++) {
      this.composerImages[i].removed = true;
      this.composerImages[i].uploadRevision += 1;
    }
    this.composerImages = [];
    this.fileQueue.removeSent(
      this.fileQueue.files.map((file: ComposerFile) => file.localId));
    this.composerFiles = [];
    this.onSessionStarted(params.deviceId, sessionId);
  }

  private closeImagePreview(): void {
    uiAnimateFastState(this.getUIContext(), () => {
      this.previewImageUrl = '';
    });
  }

  private previewImageOptions(): string[] {
    const options: string[] = [];
    for (const image of this.composerImages) {
      if (image.uri.length > 0 && !options.includes(image.uri)) options.push(image.uri);
    }
    return options;
  }

  private stepImagePreview(direction: number): void {
    const options = this.previewImageOptions();
    const index = options.indexOf(this.previewImageUrl);
    if (index < 0 || options.length < 2) return;
    this.previewImageUrl = options[(index + direction + options.length) % options.length];
  }

  build() {
    Stack() {
      HdsNavigation() {
        Column() {
          if (this.creating) {
            LoadingProgress().width(20).height(20).color($r('app.color.text_secondary'))
              .alignSelf(ItemAlign.End).margin({ top: 8, right: 16 })
          }
          // 尚未发送时没有远端消息，也不制造“正在同步”或空态卡片。
          Blank()
            .width('100%')
            .layoutWeight(1)
          if (!this.composerPickerOpen()) { this.worktreeOptions() }
          Column() { this.composer() }.width('100%').zIndex(3)
          if (this.composerPickerOpen()) {
            Row().width('100%').height('100%').position({ x: 0, y: 0 }).zIndex(2)
              .accessibilityLevel('no')
              .onClick(() => { this.dismissActiveComposerPicker(); })
          }
        }
        .width('100%')
        .height('100%')
        .onAreaChange((_old: Area, next: Area) => { this.composerPickerViewport = Number(next.height); })
        .backgroundColor($r('app.color.bg_page'))
      }
      .titleBar({
        enableComponentSafeArea: true,
        style: {
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
            blurEffectiveStartOffset: LengthMetrics.vp(0),
            blurEffectiveEndOffset: LengthMetrics.vp(20),
          },
          blurStrategy: BlurStrategy.ADAPTIVE,
          thermoCtrl: true,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
          },
        },
        content: {
          title: { mainTitle: '新任务' },
          backIcon: {
            label: '返回任务列表',
            action: (): void => { if (!this.dismissActiveComposerPicker()) this.onClose(); },
          },
        },
      })
      .hideBackButton(this.embedded)
      .hideToolBar(true)
      .mode(NavigationMode.Stack)
      .titleMode(HdsNavigationTitleMode.MINI)
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // 与任务详情 Composer 共用同一交互：ready 图片点击后进入全屏预览。
      if (this.previewImageUrl.length > 0) {
        Stack() {
          Image(this.previewImageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
          if (this.previewImageOptions().length > 1) {
            Column() {
              Blank().layoutWeight(1)
              Row({ space: 16 }) {
                Button('上一张')
                  .fontColor($r('app.color.chat_overlay_text'))
                  .backgroundColor($r('app.color.overlay'))
                  .onClick(() => this.stepImagePreview(-1))
                Text(`${this.previewImageOptions().indexOf(this.previewImageUrl) + 1} / ${this.previewImageOptions().length}`)
                  .fontColor($r('app.color.chat_overlay_text'))
                Button('下一张')
                  .fontColor($r('app.color.chat_overlay_text'))
                  .backgroundColor($r('app.color.overlay'))
                  .onClick(() => this.stepImagePreview(1))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ bottom: 42 })
            }
            .width('100%')
            .height('100%')
          }
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
      }
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.paneKeyboardInset })
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

  private localPickerTitle(): string {
    if (this.deviceMenuOpen) return '电脑';
    if (this.workspacePopupOpen) return '项目';
    return this.worktreeBranchOpen ? '来源分支' : '';
  }

  private openLocalPicker(kind: string): void {
    this.composerBlurGeneration += 1;
    this.composerFocused = false;
    this.composerSurfaceVisible = false;
    this.getUIContext().getFocusController().clearFocus();
    this.deviceMenuOpen = kind === 'device';
    this.workspacePopupOpen = kind === 'workspace';
    this.worktreeBranchOpen = kind === 'branch';
  }

  @Builder
  optionLabel(icon: Resource, label: string, limit: number) {
    Row({ space: 8 }) {
      SymbolGlyph(icon).width(20).fontSize(17).fontColor([$r('app.color.text_secondary')])
      Text(label).fontSize(uiFontSize(15)).fontColor($r('app.color.text_primary'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: limit })
      SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.text_secondary')])
    }
  }

  @Builder
  worktreeOptions() {
    Column({ space: 4 }) {
      Button() {
        this.optionLabel($r('sys.symbol.computer'), this.devices.find((row: PresenceSnapshot): boolean =>
          row.deviceId === this.selectedDeviceId)?.deviceName || '选择电脑', 180)
      }.type(ButtonType.Normal).height(44).padding({ left: 8, right: 8 })
        .backgroundColor(Color.Transparent).enabled(!this.creating && !this.incomingBusy && this.incomingDelivery === null)
        .clickEffect(UI_CLICK_EFFECT).onClick(() => this.openLocalPicker('device'))
      Button() {
        this.optionLabel($r('sys.symbol.folder'), this.workspaceKind === 'dialogue'
          ? '对话' : this.projectDisplayTitle(this.workingDir, this.projectAliasRevision), 180)
      }.type(ButtonType.Normal).height(44).padding({ left: 8, right: 8 })
        .backgroundColor(Color.Transparent).enabled(!this.creating)
        .clickEffect(UI_CLICK_EFFECT).onClick(() => this.openLocalPicker('workspace'))
      if (this.workspaceKind === 'project' && this.worktreeTarget.supported) {
        Row() {
          Button() {
            this.optionLabel($r('sys.symbol.split'), this.worktreeBranch, 132)
          }.type(ButtonType.Normal).height(44).padding({ left: 8, right: 8 }).backgroundColor(Color.Transparent)
            .enabled(!this.creating && !this.worktreeLoading).clickEffect(UI_CLICK_EFFECT)
            .onClick(() => { void this.openWorktreeBranches(); })
          Divider().vertical(true).height(20).color($r('app.color.border'))
          Button() {
            Row({ space: 6 }) {
              SymbolGlyph(this.worktreeEnabled ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.circle'))
                .fontSize(17).fontColor([$r('app.color.text_secondary')])
              Text('worktree').fontSize(uiFontSize(13)).fontColor($r('app.color.text_primary'))
            }
          }.type(ButtonType.Normal).height(44).backgroundColor(Color.Transparent).accessibilitySelected(this.worktreeEnabled)
            .enabled(!this.creating && !this.worktreeLoading).clickEffect(UI_CLICK_EFFECT)
            .onClick(() => this.toggleNewWorktree())
        }.backgroundColor($r('app.color.bg_chip')).borderRadius(22)
      }
    }.width('100%').constraintSize({ maxWidth: 720 }).padding({ left: 12, right: 12, bottom: 12 })
      .alignItems(HorizontalAlign.Start)
  }

  @Builder
  localPickerRow(label: ResourceStr, icon: Resource, selected: boolean, action: () => void) {
    Button() {
      Row({ space: 8 }) {
        SymbolGlyph(icon).width(24).fontSize(17).fontColor([$r('app.color.text_secondary')])
        Text(label).fontSize(UI_FONT_LIST_TITLE).fontColor($r('app.color.text_primary')).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Start)
        if (selected) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.accent')])
        }
      }.width('100%')
    }.type(ButtonType.Normal).constraintSize({ minHeight: 44 }).width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(selected ? $r('app.color.bg_chip') : Color.Transparent)
      .borderRadius(UI_RADIUS_CONTROL).accessibilitySelected(selected)
      .clickEffect(UI_CLICK_EFFECT).onClick(action)
  }

  @Builder
  localPickerContent(title: string) {
    Column({ space: 2 }) {
      if (title === '电脑') {
        ForEach(this.devices, (row: PresenceSnapshot) => {
          if (this.canCreateOnDevice(row.deviceId)) {
            this.localPickerRow(row.deviceName || row.deviceId, $r('sys.symbol.computer'),
              row.deviceId === this.selectedDeviceId, (): void => {
                this.deviceMenuOpen = false;
                this.refreshDevices(row.deviceId);
              })
          }
        }, (row: PresenceSnapshot) => row.deviceId)
      } else if (title === '项目') {
        this.localPickerRow('对话', $r('sys.symbol.ellipsis_message'), this.workspaceKind === 'dialogue',
          (): void => this.selectDialogue())
        ForEach(this.recentProjects(), (project: RecentProject) => {
          this.localPickerRow(project.title, $r('sys.symbol.folder'),
            this.workspaceKind === 'project' && this.workingDir === project.path,
            (): void => this.selectProject(project.path))
        }, (project: RecentProject) => project.path)
        if (this.recentProjects().length === 0) {
          Text('还没有最近项目').fontSize(uiFontSize(13)).fontColor($r('app.color.text_secondary')).padding(12)
        }
        this.localPickerRow('选择其他项目文件夹', $r('sys.symbol.folder'), false,
          (): void => this.openProjectBrowse())
        this.localPickerRow($r('app.string.v140_project_create'), $r('sys.symbol.folder_badge_plus'), false,
          (): void => this.openProjectCreate())
      } else {
        TextInput({ placeholder: '搜索分支', text: this.worktreeBranchQuery }).height(44).width('100%')
          .fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_chip'))
          .onChange((query: string) => { this.worktreeBranchQuery = query; })
        ForEach(this.worktreeBranches.filter((branch: string): boolean =>
          branch.toLowerCase().includes(this.worktreeBranchQuery.trim().toLowerCase())), (name: string) => {
          this.localPickerRow(name, $r('sys.symbol.split'), name === this.worktreeBranch,
            (): void => this.selectWorktreeBranch(name))
        }, (name: string) => name)
      }
    }.width('100%').padding({ left: 8, right: 8, bottom: 8 })
  }

  @Builder
  agentPanel() {
    Column({ space: 2 }) {
      ForEach(NEW_AGENT_OPTIONS, (kind: NewAgentKind) => {
        Row({ space: 10 }) {
          this.selectorIcon(agentMark(kind))
          Text(agentLabel(kind))
            .fontSize(uiFontSize(15))
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          if (kind === this.selectedAgentKind) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(uiFontSize(18))
              .fontColor([$r('app.color.chat_cta')])
          }
        }
        .width('100%')
        .height(44)
        .padding({ left: 10, right: 10 })
        .backgroundColor(kind === this.selectedAgentKind
          ? $r('app.color.bg_chip') : Color.Transparent)
        .borderRadius(UI_RADIUS_CONTROL)
        .clickEffect(UI_LIST_CLICK_EFFECT)
        .onClick(() => {
          this.selectAgent(kind);
          this.composerAgentPopupOpen = false;
        })
      }, (kind: NewAgentKind) => `new-agent:${kind}`)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 4, bottom: 10 })
  }

  /**
   * 分组：对话 / 最近项目 / 选择其他项目文件夹与新建项目（对齐 Mobile 项目选择器，新建项目在末尾）。
   */
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
        if (this.browseDrives.length > 1) {
          Button(this.browseDriveLabel())
            .type(ButtonType.Normal)
            .constraintSize({ minWidth: 44, minHeight: 44, maxWidth: 96 })
            .fontSize(uiFontSize(12))
            .fontColor($r('app.color.text_primary'))
            .backgroundColor(Color.Transparent)
            .borderRadius(UI_RADIUS_CONTROL)
            .enabled(!this.creating && !this.browseLoading)
            .bindMenu(this.browseDriveMenuItems())
            .accessibilityText(harmonyV12String(this.getUIContext().getHostContext(), 'v132_choose_drive'))
        }
        if (this.browseLoading) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color($r('app.color.text_secondary'))
        }
      }
      .width('100%')
      .height(this.browseDrives.length > 1 ? 44 : 36)
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
    .onClick(() => {
      this.selectProject(entry.path);
      this.contextSheetOpen = false;
    })
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
      const runtimeGeneration = this.runtimeLoadGeneration;
      const copy = uiConfirmCopy('确认完全访问', 'Cindy 将不再逐项询问工具操作。请仅在信任当前任务和项目时使用。',
        '继续', '取消');
      void uiConfirm(this.getUIContext(), copy).then((confirmed: boolean): void => {
        if (!confirmed || !this.pageActive || runtimeGeneration !== this.runtimeLoadGeneration) return;
        this.runtimePermissionTouchedGeneration = this.runtimeLoadGeneration;
        this.permissionMode = option.id;
        this.permissionModeBeforePlan = option.id;
        this.contextSheetOpen = false;
        this.composerPermissionPopupOpen = false;
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
    if (this.composerModelPopupOpen) {
      // 就地面板退场与模型提交共用同一条路径。
      this.pendingPopupModelSelection = option;
      this.dismissComposerControlPopup('model');
      return;
    }
    // Sheet 不依赖工具栏按钮作为锚点，可以在发起退场后直接更新本地草稿。
    this.returnToComposerAfterModelSheet();
    this.selectModel(option);
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
        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        this.contextActionRow($r('sys.symbol.doc'), '文件', () => this.pickFiles())
      }
      .width('100%')
      .padding({ bottom: 24 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  permissionContextView() {
    Column() {
    UiCard({ inset: 0 }) {
      ForEach(this.permissionOptions, (option: RuntimeChoiceOption) => {
        Row({ space: 8 }) {
          SymbolGlyph(composerPermissionSymbol(option.id))
            .fontSize(uiFontSize(16))
            .fontColor([composerPermissionTint(option.id)])
            .width(24)
          Column({ space: 1 }) {
            Text(option.label)
              .fontSize(UI_FONT_LIST_TITLE)
              .fontWeight(option.id === this.permissionMode
                ? FontWeight.Medium : FontWeight.Normal)
              .fontColor($r('app.color.text_primary'))
            if (option.description.length > 0) {
              Text(option.description)
                .fontSize(UI_FONT_SECONDARY)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .layoutWeight(1)
          if (option.id === this.permissionMode) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(uiFontSize(18))
              .fontColor([$r('app.color.accent')])
          }
        }
        .width('100%')
        .constraintSize({ minHeight: 44 })
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        .backgroundColor(option.id === this.permissionMode
          ? $r('app.color.bg_chip') : Color.Transparent)
        .borderRadius(UI_RADIUS_CONTROL)
        .opacity(this.creating ? 0.55 : 1)
        .clickEffect(UI_LIST_CLICK_EFFECT)
        .focusable(true)
        .accessibilityGroup(true)
        .accessibilitySelected(option.id === this.permissionMode)
        .onClick(() => this.selectContextPermission(option))
      }, (option: RuntimeChoiceOption) => option.id)
    }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 2, bottom: 8 })
  }

  @Builder
  contextModelRow(option: RuntimeModelOption) {
    ComposerModelOptionRow({
      label: option.label,
      providerKind: modelProviderKind(option),
      providerInitial: option.providerName.length > 0
        ? option.providerName.charAt(0).toUpperCase() : 'S',
      selected: this.modelOptionIsCurrent(option),
      subscription: option.subscription,
      paymentRequired: option.availability === 'requires_payment',
      disabled: this.creating || (option.suspended && !this.modelOptionIsCurrent(option)),
      quotaLine: modelQuotaLine(option, this.selectedDeviceId, this.modelQuotaValues),
      effortIds: option.efforts,
      selectedEffort: this.modelEffortForRow(option),
      effortPickerOpen: this.modelEffortPickerKey === this.modelOptionKey(option),
      fastModeVisible: this.fastModeCapability && option.supportsFastMode,
      fastModeOn: this.modelFastForRow(option),
      ultrafastAvailable: this.modelRowSupportsUltrafast(option),
      fastSpeed: this.modelSpeedForRow(option),
      effortLabel: (effort: string): string => this.modelEffortLabel(option, effort),
      onSelect: (): void => this.selectContextModel(option),
      onToggleEffortPicker: (): void => {
        const key = this.modelOptionKey(option);
        this.modelEffortPickerKey = this.modelEffortPickerKey === key ? '' : key;
      },
      onSelectEffort: (effort: string): void => {
        this.selectModelRowEffort(option, effort);
        this.modelEffortPickerKey = '';
      },
      onFastModeChange: (enabled: boolean): void => this.setModelRowFast(option, enabled),
      onSpeedChange: (speed: string): void => this.setModelRowSpeed(option, speed),
      onSelectedArea: (area: Area): void => this.positionSelectedModel(area),
    })
  }

  @Builder
  modelProviderGroup(group: ComposerModelGroup) {
    Column() {
    UiListGroup({ heading: group.name }) {
      ForEach(group.options, (option: RuntimeModelOption, index: number) => {
        if (index > 0) {
          Divider().color($r('app.color.border')).margin({ left: 16, right: 16 })
        }
        ModelPickerListRow({
          modelName: option.label, providerName: option.providerName, providerKind: modelProviderKind(option),
          harness: option.pickerHarness || this.selectedAgentKind,
          effort: this.modelEffortLabel(option, option.pickerEffort || this.modelEffortForRow(option)),
          quota: modelQuotaLine(option, this.selectedDeviceId, this.modelQuotaValues),
          selected: this.modelOptionIsCurrent(option) && (!option.pickerHarness || option.pickerHarness === this.selectedAgentKind)
            && (!option.pickerConfigurationId || (option.pickerEffort === this.modelEffortForRow(option)
              && option.pickerFast === this.modelFastForRow(option))),
          available: !(this.creating) && (!option.suspended || this.modelOptionIsCurrent(option))
            && (option.availability !== 'requires_payment' || this.modelOptionIsCurrent(option)),
          canConfigure: !(this.creating) && !option.suspended && option.availability !== 'requires_payment'
            && (!option.pickerHarness || option.pickerHarness === this.selectedAgentKind),
          onPick: (): void => { void this.pickOtherHarnessModel(option); },
          onConfigure: (): void => {
            this.pickerDetails = option;
            this.modelPickerScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
          },
        }).onAreaChange((_old: Area, area: Area) => {
          if (this.modelOptionIsCurrent(option) && !option.pickerConfigurationId) this.positionSelectedModel(area);
        })
      }, (option: RuntimeModelOption) => this.modelOptionKey(option) + ':' + option.pickerHarness + ':' + option.pickerConfigurationId)

    }
    }.width('100%').padding({ left: 12, right: 12, bottom: 8 })
  }

  private async pickOtherHarnessModel(option: ComposerModelOption): Promise<void> {
    if (this.creating) return;
    this.agentTouched = true;
    const kind = option.pickerHarness ? option.pickerHarness as NewAgentKind : this.selectedAgentKind;
    const device = this.selectedDeviceId;
    if (this.selectedAgentKind !== kind) {
      this.selectedAgentKind = kind;
      await this.loadRuntimeDefaults(device, kind);
    }
    if (!this.composerModelPopupOpen || device !== this.selectedDeviceId || kind !== this.selectedAgentKind) return;
    if (option.pickerConfigurationId) {
      this.selectModelRowEffort(option, option.pickerEffort);
      this.setModelRowFast(option, option.pickerFast);
    }
    this.selectContextModel(option);
  }

  private filteredPickerPluginRows(): PluginEngine[] {
    const query = this.pickerModelSearch.trim().toLowerCase();
    return this.pickerPluginRows.filter((engine: PluginEngine): boolean =>
      engine.name.toLowerCase().includes(query) || engine.models.some((model: PluginEngineModel): boolean =>
        model.label.toLowerCase().includes(query) || model.id.toLowerCase().includes(query)));
  }

  @Builder
  pickerPluginSections() {
    ForEach(this.filteredPickerPluginRows(), (engine: PluginEngine) => {
      Column() {
      UiListGroup({ heading: engine.name }) {
        if (engine.availability !== 'available') {
          Text(engine.availabilityMessage || '此电脑上的引擎不可用')
            .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Start)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('calc(100% - 36vp)').margin({ left: 18, right: 18, bottom: 4 })
        }
          ForEach(pluginPickerModels(engine, this.selectedPickerPlugin()?.providerId === engine.providerId ? this.pickerPluginModel : ''), (model: PluginEngineModel, index: number) => {
            if (index > 0) {
              Divider().color($r('app.color.border')).margin({ left: 16, right: 16 })
            }
            ModelPickerListRow({
              modelName: model.label, providerName: engine.name, providerIconUrl: engine.iconDataUrl,
              showConfigure: false, available: engine.availability === 'available' && !this.creating,
              selected: model.id === (this.selectedPickerPlugin()?.providerId === engine.providerId ? this.pickerPluginModel : ''),
              onPick: (): void => { this.pickDraftPlugin(engine, model); },
            })
          }, (model: PluginEngineModel) => model.id)
      }
      }.width('100%').padding({ left: 12, right: 12, bottom: 8 })
        .opacity(engine.availability === 'available' ? 1 : 0.6)
    }, (engine: PluginEngine) => engine.providerId)
  }

  private pickerCompatibleHarnesses(option: ComposerModelOption): ComposerModelOption[] {
    const choices: ComposerModelOption[] = [];
    for (const harness of NEW_AGENT_OPTIONS) {
      if (harness === this.selectedAgentKind) continue;
      const rows = option.agentDeviceId
        ? remoteAgentModelOptions(this.remoteAgentCatalogList, harness, undefined, null)
        : parseComposerProviderModelOptions(this.pickerCatalogPayload, harness, this.modelVisibilityOverrides, undefined, false);
      const matched = rows.find((row: ComposerModelOption): boolean => row.id === option.id
        && row.providerId === option.providerId && row.agentDeviceId === option.agentDeviceId
        && !row.suspended && row.availability !== 'requires_payment');
      if (matched !== undefined) {
        matched.pickerHarness = harness;
        choices.push(matched);
      }
    }
    return choices;
  }

  @Builder
  pickerDetailsView(option: ComposerModelOption) {
    Column({ space: 12 }) {
      Column() {
        UiCard() {
          Text([option.label, option.providerName, option.agentDeviceName, option.contextWindow > 0
            ? String(option.contextWindow) + ' 上下文' : ''].filter((item: string): boolean => !!item).join(' · '))
            .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
        }
      }.width('100%').borderRadius(UI_RADIUS_CARD).border({ width: 1, color: $r('app.color.border') })
      Column() {
        UiCard({ inset: 0 }) {
          UiListRow({ label: 'Harness', detail: agentLabel(this.selectedAgentKind) })
          ForEach(this.pickerCompatibleHarnesses(option), (compatible: ComposerModelOption) => {
            Divider().color($r('app.color.border')).margin({ left: 16, right: 16 })
            UiListRow({ label: '切换到 ' + agentLabel(compatible.pickerHarness as NewAgentKind), showChevron: true,
              onRowClick: () => { void this.pickOtherHarnessModel(compatible); } })
          }, (compatible: ComposerModelOption) => compatible.pickerHarness)
          Divider().color($r('app.color.border')).margin({ left: 16, right: 16 })
          UiListRow({ label: '推理强度', value: this.modelEffortLabel(option, this.modelEffortForRow(option)), showChevron: option.efforts.length > 0,
            rowEnabled: option.efforts.length > 0,
            onRowClick: () => { this.modelEffortPickerKey = this.modelEffortPickerKey ? '' : this.modelOptionKey(option); } })
          if (this.modelEffortPickerKey === this.modelOptionKey(option)) {
            ForEach(option.efforts, (level: string) => {
              UiListRow({ label: this.modelEffortLabel(option, level),
                onRowClick: () => { this.selectModelRowEffort(option, level); this.modelEffortPickerKey = ''; } })
                .accessibilitySelected(level === this.modelEffortForRow(option))
            }, (level: string) => level)
          }
          if (option.supportsFastMode) {
            Divider().color($r('app.color.border')).margin({ left: 16, right: 16 })
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.bolt')).fontSize(20).fontColor([$r('app.color.text_secondary')])
              Text('快速模式').layoutWeight(1).fontSize(UI_FONT_LIST_TITLE).fontColor($r('app.color.text_primary'))
              Toggle({ type: ToggleType.Switch, isOn: this.modelFastForRow(option) })
                .accessibilityText('快速模式').onChange((enabled: boolean) => this.setModelRowFast(option, enabled))
            }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 16, right: 16, top: 4, bottom: 4 })
          }
        }
      }.width('100%').borderRadius(UI_RADIUS_CARD).border({ width: 1, color: $r('app.color.border') })
      Column() {
        UiCard({ inset: 0 }) {
          UiListRow({ label: '使用推荐设定',
            detail: '恢复推荐会重设 Harness、推理强度和 Fast，已有收藏保持不变。',
            onRowClick: () => { void this.pickOtherHarnessModel(pickerRecommendedOption(option, this.pickerCompatibleHarnesses(option))); } })
        }
      }.width('100%').borderRadius(UI_RADIUS_CARD).border({ width: 1, color: $r('app.color.border') })
      UiListGroup({ heading: '目前设定' }) {
        Row() {
          SymbolGlyph($r('sys.symbol.star')).fontSize(20).fontColor([$r('app.color.text_secondary')])
          UiListRow({
            label: modelFavoriteMutation(option, this.selectedAgentKind, this.modelEffortForRow(option), this.modelFastForRow(option),
              this.pickerFavoriteItems)['kind'] === 'remove' ? '取消收藏此设定' : '收藏此设定',
            detail: agentLabel(this.selectedAgentKind) + ' · ' + this.modelEffortLabel(option, this.modelEffortForRow(option)) + (this.modelFastForRow(option) ? ' · Fast' : ''),
            rowEnabled: this.pickerFavoritesReady && !this.pickerFavoritesBusy && !!option.providerId,
            onRowClick: () => { void this.togglePickerFavorite(option); }
          }).layoutWeight(1)
        }.width('100%').padding({ left: 16 })
        Divider().color($r('app.color.border')).margin({ left: 16, right: 16 })
        Text('储存这组参数，方便下次从收藏清单直接使用。')
          .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary')).padding(16)
      }
    }.width('100%').padding(12).alignItems(HorizontalAlign.Start)
  }

  @Builder
  modelContextView(bodyHeight: number = 0,
    frame?: OnScrollFrameBeginCallback, settle?: () => void, metrics?: (viewport: number, content: number) => void) {
    Column() {
      if (this.pickerDetails === null) { this.pickerSearchHeader() }
      Scroll(this.modelPickerScroller) {
        Column() {
          if (this.pickerDetails !== null) {
            this.pickerDetailsView(this.pickerDetails)
          } else {
          if (this.pickerAllProviders) { this.pickerPluginSections() }
          if (this.pickerAllProviders && !this.pickerModelSearch.trim()
            && ((this.routingSnapshot.catalog?.routes.length ?? 0) + (this.routingSnapshot.catalog?.expandedRoutes.length ?? 0) > 0)) {
          Column() {
          ModelRoutingPanel({
            snapshot: this.routingSnapshot,
            labels: modelRoutingLabels(this.getUIContext().getHostContext()),
            activeId: this.selectedRouteDevice === this.selectedDeviceId ? this.selectedRouteId : '',
            busy: this.creating,
            onSelect: (id: string): void => {
              this.selectedRouteId = id;
              this.selectedRouteDevice = this.selectedDeviceId;
              if (this.composerModelPopupOpen) this.dismissComposerControlPopup('model');
              else this.returnToComposerAfterModelSheet();
            },
            onOrdinary: (): void => { this.selectedRouteId = ''; this.selectedRouteDevice = ''; },
            onRefresh: (): void => { void this.loadRouting(true); },
          })
          }.width('calc(100% - 24vp)').backgroundColor($r('app.color.bg_page')).borderRadius(12)
          }
          if (this.pickerGroups().length === 0) {
            Text('当前电脑未提供模型列表')
              .fontSize(uiFontSize(14))
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 28, bottom: 28 })
          } else {
            ForEach(this.pickerGroups(), (group: ComposerModelGroup) => {
              this.modelProviderGroup(group)
            }, (group: ComposerModelGroup) => group.key)
          }
          }
        }
        .width('100%')
        .padding({ top: 2, bottom: 24 })
        .onAreaChange((_old: Area, next: Area) => { metrics?.(-1, Number(next.height)); })
      }
      .width('100%')
      .height(bodyHeight > 0 ? Math.max(1, bodyHeight - (this.pickerDetails === null ? 48 : 0)) : undefined)
      .layoutWeight(bodyHeight > 0 ? 0 : 1)
      .edgeEffect(EdgeEffect.None, { alwaysEnabled: bodyHeight > 0 })
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .onScrollFrameBegin((offset: number, state: ScrollState): OnScrollFrameBeginHandlerResult =>
        frame ? frame(offset, state) : { offsetRemain: offset })
      .onScrollStop(() => { settle?.(); })
      .scrollBar(BarState.Auto)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) this.modelPickerUserMoved = true;
      })
      .onAreaChange((_old: Area, next: Area) => {
        this.modelPickerTop = Number(next.globalPosition.y);
        this.modelPickerHeight = Number(next.height);
        metrics?.(this.modelPickerHeight, -1);
        if (this.selectedModelArea !== null) this.positionSelectedModel(this.selectedModelArea);
      })
    }
    .width('100%')
    .height(bodyHeight > 0 ? bodyHeight : undefined)
    .layoutWeight(this.composerModelPopupOpen ? 0 : 1)
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
        Text(this.contextSheetPage === 'workspace'
          ? '选择工作目录'
          : this.contextSheetPage === 'permission'
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

      if (this.contextSheetPage === 'workspace') {
        this.browsePanel()
      } else if (this.contextSheetPage === 'permission') {
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
      if (this.incomingBlocked && !this.incomingBusy && !this.creating) {
        Button(harmonyV12String(this.getUIContext().getHostContext(), 'incoming_share_resume'))
          .height(44).fontSize(uiFontSize(12)).fontColor($r('app.color.text_primary'))
          .backgroundColor(Color.Transparent).borderRadius(UI_RADIUS_CONTROL)
          .onClick((): void => { if (!this.incomingRestored) void this.restoreNewSessionDraft(); else void this.consumeIncomingDraft(); })
      }
      if (this.runtimeDefaultsSettled && !this.runtimeCatalogReady && !this.runtimeToolbarLoadActive
        && !this.creating && this.canCreateOnDevice(this.selectedDeviceId)) {
        Button(harmonyV12String(this.getUIContext().getHostContext(), 'v132_defaults_retry'))
          .type(ButtonType.Normal)
          .constraintSize({ minHeight: 44 })
          .fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(Color.Transparent)
          .borderRadius(UI_RADIUS_CONTROL)
          .clickEffect(UI_LIST_CLICK_EFFECT)
          .onClick(() => {
            this.error = '';
            void this.loadRuntimeDefaults(this.selectedDeviceId, this.selectedAgentKind);
          })
      }
      ConversationComposer({
        pickerWindowHeight: this.composerPickerViewport + this.paneKeyboardInset,
        externalPickerTitle: this.localPickerTitle(),
        onExternalPickerDismiss: (): void => { this.dismissActiveComposerPicker(); },
        externalPickerContent: (title: string): void => { this.localPickerContent(title); },
        input: this.input,
        focused: this.composerFocused,
        surfaceExpanded: this.composerSurfaceVisible,
        images: this.composerImages,
        files: this.composerFiles,
        pickingImages: this.pickingImages,
        pickingFiles: this.pickingFiles,
        sending: this.creating,
        streaming: false,
        hasContent: this.hasComposerContent(),
        canSend: this.canSend(),
        composerEnabled: !this.creating && !this.incomingBusy,
        contextBusy: this.creating || this.incomingBusy,
        toolbarReady: this.composerToolbarReady,
        hasPermissionOptions: this.permissionOptions.length > 0,
        hasAgentOptions: NEW_AGENT_OPTIONS.length > 1,
        hasModelOptions: (this.visibleModelOptions().length > 0 && this.currentModelLabel().length > 0)
          || (this.routingSnapshot.catalog?.routes.length ?? 0) > 0 || (this.routingSnapshot.catalog?.expandedRoutes.length ?? 0) > 0,
        permissionMode: this.permissionMode,
        permissionLabel: this.currentPermissionModeLabel(),
        planModeEnabled: this.planModeEnabled,
        agentLabel: this.selectedPickerPlugin()?.name ?? agentLabel(this.selectedAgentKind),
        modelLabel: this.selectedPickerPlugin() ? this.pickerPluginModelLabel : this.currentModelLabel(),
        effortLabel: this.currentEffortLabel(),
        permissionPopupVisible: this.composerPermissionPopupOpen,
        agentPopupVisible: this.composerAgentPopupOpen,
        modelPopupVisible: this.composerModelPopupOpen,
        showAddButton: true,
        showStreamingStatus: false,
        floatingGlass: true,
        floatingBottomInset: this.paneComposerBottomInset,
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
        onAgent: (): void => this.openComposerControlPopup('agent'),
        onModel: (): void => this.openComposerControlPopup('model'),
        onPermissionPopupDismiss: (): void => {
          this.dismissComposerControlPopup('permission');
        },
        onAgentPopupDismiss: (): void => {
          this.dismissComposerControlPopup('agent');
        },
        onModelPopupDismiss: (): void => {
          this.dismissComposerControlPopup('model');
        },
        permissionPopupContent: (): void => {
          this.permissionContextView();
        },
        agentPopupContent: (): void => {
          this.agentPanel();
        },
        modelPanelScroller: this.modelPickerScroller,
        modelPickerTitle: this.pickerDetails?.label ?? '',
        onModelPickerBack: (): void => { this.pickerDetails = null; },
        modelPopupContent: (bodyHeight: number, frame: OnScrollFrameBeginCallback, settle: () => void,
          metrics: (viewport: number, content: number) => void): void => {
          this.modelContextView(bodyHeight, frame, settle, metrics);
        },
        onPlanToggle: (): void => this.togglePlanMode(),
        onExpand: (): void => this.expandComposerForEditing(),
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
        onRetryFile: (localId: string): void => this.retryComposerFile(localId),
      })
    }
    .width('100%')
    .padding({ top: 4, bottom: 0 })
  }
}

/** 独立新建路由入口；宽屏双栏直接使用上面的可嵌入草稿组件。 */
@Entry
@Component
struct NewSessionPage {
  @State keyboardHeight: number = 0;
  private pageActive: boolean = false;
  private workspaceEditRevision: number = 0;
  private runtimeCatalogReady: boolean = false;
  private runtimeCatalogScope: string = '';
  private workspaceRestoreGeneration: number = 0;
  private keyboardWindow: window.Window | null = null;
  private keyboardHeightListening: boolean = false;
  private keyboardHeightListener: (height: number) => void = (height: number): void => {
    this.keyboardHeight = Math.max(0, this.getUIContext().px2vp(height));
  };

  aboutToAppear(): void {
    this.pageActive = true;
    this.keyboardHeight = 0;
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
    void this.observeKeyboardHeight();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.stopKeyboardHeightObservation();
    this.keyboardHeight = 0;
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
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
      if (this.pageActive) this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    }
  }

  private stopKeyboardHeightObservation(): void {
    if (!this.keyboardHeightListening || this.keyboardWindow === null) return;
    try {
      this.keyboardWindow.off('keyboardHeightChange', this.keyboardHeightListener);
    } catch (_err) {
      // 页面退出时窗口可能已经回收。
    }
    this.keyboardWindow = null;
    this.keyboardHeightListening = false;
  }

  private composerBack: (() => boolean) | undefined = undefined;

  onBackPress(): boolean {
    return this.composerBack?.() ?? false;
  }

  build() {
    Column() {
      NewSessionPageContent({
        paneKeyboardInset: this.keyboardHeight,
        registerComposerBack: (handler): void => { this.composerBack = handler; },
      })
    }
    .width('100%')
    .height('100%')
  }
}
