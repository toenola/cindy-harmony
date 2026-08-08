/**
 * 任务详情页：按渲染模型展示消息流 + Composer。
 *
 * 消息流由 MessageRender.buildRenderItems 构建（tool 配对 / thinking /
 * todo 卡 / 系统消息），正文走 MarkdownParser 渲染为 ArkUI 原生组件。
 * - thinking 默认折叠，点击展开；
 * - tool_group 默认展开，点击折叠；
 * - 消息动作（复制/Fork/Rewind）在切片 2.3 接入。
 */

import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  photoAccessHelper, PhotoPickerComponent, PickerController, PickerOptions,
  SelectMode, PickerOrientation, SingleLineConfig, ItemInfo, DataType,
} from '@kit.MediaLibraryKit';
import { AppServices } from '../core/AppServices';
import { pickImageUris, pickScreenshotUris, takePhotoUri, buildImageCandidate } from '../core/attachments/ImagePicker';
import { uploadImage, presignGet, deleteUpload } from '../core/attachments/AttachmentUpload';
import { RemoteImageRef, RemoteMediaFetchResult } from '../core/attachments/AttachmentModels';
import { parseAttachmentOssRef } from '../core/attachments/AttachmentOssRef';
import { PendingInteraction } from '../core/interactions/InteractionStore';
import { DlInvokeOptions } from '../core/device-link/DlClient';
import { GoalModeState } from '../core/goals/GoalModels';
import { GoalStartOptions } from '../core/goals/GoalStore';
import { unwrapInvokeResult } from '../core/tasks/TaskStore';
import { RemoteSession, readBool, readNum, readObj, readStr } from '../core/tasks/TaskModels';
import {
  RenderItem, RenderMessageItem, RenderThinkingItem,
  RenderToolGroupItem, RenderToolItem, RenderToolMediaItem, RenderTodoCardItem, RenderTodoItem,
  RenderWorkGroupItem, RenderTextSegment,
  buildRenderItems, summarizeText, collapsedUserMessageLineLimit,
} from '../core/messages/MessageRender';
import {
  MdBlock, tokenizeInline, InlineToken, parseMarkdown,
} from '../core/messages/MarkdownParser';

/** 活动 work_group 收起态的实时步骤预览行（对齐 Mobile collapsedBody）。 */
class WorkPreviewRow {
  key: string = '';
  kind: string = '';
  text: string = '';
  done: boolean = false;
  error: boolean = false;
}

class ComposerChoiceOption {
  id: string = '';
  label: string = '';
  description: string = '';
}

class ProviderListOptions {
  capabilities: string[] = [];
}

class ComposerModelOption {
  id: string = '';
  label: string = '';
  description: string = '';
  efforts: string[] = [];
  defaultEffort: string = '';
  supportsFastMode: boolean = false;
  effortDisplayNames: Record<string, string> = {};
  /** provider-aware 目录行；空值表示旧 capabilities 扁平回退。 */
  providerId: string = '';
  providerName: string = '';
  providerLogoKind: string = '';
  modelIcon: string = '';
  subscription: boolean = false;
}

const MAX_COMPOSER_IMAGES = 20;
const TASK_DETAIL_FONT_SCALE = 0.84;
const TASK_DETAIL_MIN_FONT_SIZE = 8;
const TASK_DETAIL_MIN_LINE_HEIGHT = 10;
const MODEL_AGENT_KINDS: string[] = ['claude-code', 'codex', 'pi'];

function taskDetailFontSize(base: number): number {
  return Math.max(TASK_DETAIL_MIN_FONT_SIZE, Math.round(base * TASK_DETAIL_FONT_SCALE));
}

function taskDetailLineHeight(base: number): number {
  return Math.max(TASK_DETAIL_MIN_LINE_HEIGHT, Math.round(base * TASK_DETAIL_FONT_SCALE));
}

function taskDetailDimension(base: number): number {
  return Math.max(1, Math.round(base * TASK_DETAIL_FONT_SCALE));
}

function modelAgentLabel(kind: string): string {
  if (kind === 'claude-code' || kind === 'cc') return 'Claude';
  if (kind === 'codex') return 'Codex';
  return 'Pi';
}

function modelAgentId(kind: string): string {
  return kind === 'cc' ? 'claude-code' : kind;
}

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
function queryValue(query: string, key: string): string {
  const pairs = query.split('&');
  for (let i = 0; i < pairs.length; i++) {
    const eq = pairs[i].indexOf('=');
    if (eq <= 0 || pairs[i].slice(0, eq) !== key) continue;
    try {
      return decodeURIComponent(pairs[i].slice(eq + 1));
    } catch (e) {
      return '';
    }
  }
  return '';
}

function isAbsoluteMediaPath(value: string): boolean {
  return value.startsWith('/') || /^[A-Za-z]:[\\/]/.test(value) || value.startsWith('\\\\');
}

function normalizeImageUrlScheme(value: string): string {
  return value.replace(
    /^(https?|data|xdt-image|cindy-media|xdt-file|file|cindy-oss-attach|xdt-oss-attach):/i,
    (scheme: string) => scheme.toLowerCase(),
  );
}

function isImageMimeType(value: string): boolean {
  return value.toLowerCase().startsWith('image/');
}


@Component
export struct TaskPageContent {
  /** 宽屏双栏中由父页面传入；为空时沿用独立详情页的路由参数。 */
  @Prop paneDeviceId: string = '';
  @Prop paneSessionId: string = '';
  @State items: RenderItem[] = [];
  @State input: string = '';
  @State sending: boolean = false;
  @State error: string = '';
  @State loadFailed: boolean = false;
  /** 首次历史请求已经结束；空任务据此从“正在同步”切到真实空态。 */
  @State initialLoadResolved: boolean = false;
  /** 空列表请求超过 200ms 后才显形，避免快速本地读取闪一下 loading。 */
  @State showInitialSync: boolean = false;
  /** 会话仍在流式生成；驱动 Header、Composer 和消息尾部状态。 */
  @State sessionStreaming: boolean = false;
  /** 用户是否仍明确跟随消息尾部。 */
  @State followingLatest: boolean = true;
  /** 离底期间收到尾部更新时，在回到底部浮标上显示提示点。 */
  @State hasNewMessages: boolean = false;
  /** Composer 焦点态切换为多行卡片几何。 */
  @State composerFocused: boolean = false;
  /** 会话内本地搜索；Header 搜索按钮展开紧凑搜索栏。 */
  @State searchOpen: boolean = false;
  @State searchQuery: string = '';
  @State searchActiveIndex: number = 0;
  /** thinking 展开的 key（默认折叠）。 */
  @State expandedThinking: string[] = [];
  /** tool_group 折叠的 key（默认展开）。 */
  /** work_group 展开的 key（默认折叠）。 */
  @State expandedWorkGroups: string[] = [];
  /** 单条工具结果展开 key（默认折叠）。 */
  @State expandedTools: string[] = [];
  /** user 长文本块展开的 key（默认折叠）。 */
  @State expandedTextBlocks: string[] = [];
  private deviceId: string = '';
  private sessionId: string = '';
  private unsubs: Array<() => void> = [];
  private listScroller: Scroller = new Scroller();
  private initialScrolled: boolean = false;
  /** 初始列表仍在布局/补齐历史时，禁止 onReachStart 抢走底部锚点。 */
  private initialScrollSettling: boolean = true;
  private initialScrollGeneration: number = 0;
  private initialLoadGeneration: number = 0;
  private sessionOpenResolved: boolean = false;
  /** 加载更早消息进行中（防重复触发，并驱动列表头入口）。 */
  @State loadingOlder: boolean = false;
  /** List 当前可见的首尾渲染项，用于贴底意图和历史分页。 */
  private visibleStartIndex: number = 0;
  private visibleEndIndex: number = -1;
  /** 单条/短首屏无法产生 List 滚动索引时，用真实手势触发一次历史分页。 */
  private listTouchStartY: number = 0;
  /** 当前手势是否明确表达了“向下回看更早消息”的意图。 */
  private listTouchPulledDown: boolean = false;
  /** 当前手势是否明确向消息尾部移动。 */
  private listTouchPushedUp: boolean = false;
  private listTouchLoadTriggered: boolean = false;
  /** 待发送图片（上传状态）。 */
  @State composerImages: ComposerImage[] = [];
  private pickingImages: boolean = false;
  /** 发送开始后的输入变更不会被旧请求的成功回调清空。 */
  private composerInputRevision: number = 0;
  /** Composer 加号的原生上下文 Sheet。 */
  @State contextSheetOpen: boolean = false;
  @State contextSheetPage: string = 'main';
  @State contextSelectedUris: string[] = [];
  @State planModeSupported: boolean = false;
  @State planModeEnabled: boolean = false;
  @State permissionOptions: ComposerChoiceOption[] = [];
  @State modelOptions: ComposerModelOption[] = [];
  /** 被控端 provider:list 的真实目录；为空时才回退 capabilities.availableModels。 */
  @State providerModelOptions: ComposerModelOption[] = [];
  @State providerModelAgent: string = '';
  @State modelVisibilityOverrides: Map<string, boolean> = new Map();
  @State effortOptions: ComposerChoiceOption[] = [];
  @State fastModeCapability: boolean = false;
  /** 模型浮窗可以浏览其它 Agent 的能力目录；选中后走真实 agent-switch RPC。 */
  @State modelAgentTab: string = '';
  @State modelSearchQuery: string = '';
  @State alternateModelOptions: ComposerModelOption[] = [];
  @State alternateEffortOptions: ComposerChoiceOption[] = [];
  @State alternateFastModeCapability: boolean = false;
  @State sessionAgentSwitchSupported: boolean = false;
  @State modelOptionsTargetId: string = '';
  @State contextRpcBusy: boolean = false;
  @State goalState: GoalModeState | null = null;
  @State goalObjective: string = '';
  @State goalMaxTurns: string = '';
  @State goalBudgetTokens: string = '';
  @State goalNoProgressLimit: string = '3';
  @State goalActionBusy: boolean = false;
  private recentPickerOptions: PickerOptions = createRecentPickerOptions();
  @State recentPickerController: PickerController = new PickerController();
  private permissionModeBeforePlan: string = 'default';
  /** 历史图片：ref.url → 可加载的 OSS URL（懒解析 + 缓存）。 */
  @State imageSources: Map<string, string> = new Map();
  private imageResolutions: Map<string, Promise<string>> = new Map();
  private ossUrlCache: Map<string, string> = new Map();
  /** 全屏预览中的图片 URL（空 = 无预览）。 */
  @State previewImageUrl: string = '';
  /** 挂起的交互请求（Permission / Ask User / Plan Review）。 */
  @State pendingInteractions: PendingInteraction[] = [];
  /** Ask User 选项选择（requestId → 选中的 label 列表）。 */
  @State askSelections: Map<string, string[]> = new Map();
  /** Ask User 自定义输入（requestId → 文本）。 */
  @State askCustomInputs: Map<string, string> = new Map();
  /** 当前设备是否关闭远程控制（只读提示）。 */
  @State deviceDisabled: boolean = false;
  /** 活动工作组的实时计时基准；与 Mobile 每 500ms 刷新一次。 */
  @State workClockNowMs: number = Date.now();
  private workClockTimer: number = -1;

  aboutToAppear(): void {
    this.stopWorkClock();
    const params = router.getParams() as Record<string, Object>;
    this.deviceId = this.paneDeviceId.length > 0
      ? this.paneDeviceId
      : readStr(params, 'deviceId');
    this.sessionId = this.paneSessionId.length > 0
      ? this.paneSessionId
      : readStr(params, 'sessionId');
    this.initialScrolled = false;
    this.initialScrollSettling = true;
    this.initialScrollGeneration += 1;
    this.initialLoadGeneration += 1;
    this.sessionOpenResolved = false;
    this.initialLoadResolved = false;
    this.showInitialSync = false;
    this.followingLatest = true;
    this.hasNewMessages = false;
    this.visibleStartIndex = 0;
    this.visibleEndIndex = -1;
    this.listTouchStartY = 0;
    this.listTouchPulledDown = false;
    this.listTouchPushedUp = false;
    this.listTouchLoadTriggered = false;

    this.unsubs.push(AppServices.instance.messages.onChanged(() => {
      this.refreshItems();
    }));
    this.refreshItems();

    // 交互确认：订阅挂起交互 + 拉快照。
    this.unsubs.push(AppServices.instance.interactions.onChanged(() => {
      this.pendingInteractions = AppServices.instance.interactions.getPending(this.sessionId);
    }));
    this.pendingInteractions = AppServices.instance.interactions.getPending(this.sessionId);
    void AppServices.instance.interactions.refreshPending(this.deviceId, this.sessionId);

    // 撤权检查：设备关闭远程控制时只读。
    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      this.deviceDisabled = this.checkDeviceDisabled();
      this.syncMessageCount();
      this.syncComposerContextState();
    }));
    this.deviceDisabled = this.checkDeviceDisabled();
    this.syncMessageCount();
    this.syncComposerContextState();

    // 目标模式走 session topic 推送；打开任务时补拉一次快照。
    this.unsubs.push(AppServices.instance.goals.onChanged(() => {
      this.goalState = AppServices.instance.goals.getState(this.sessionId);
    }));
    this.goalState = AppServices.instance.goals.getState(this.sessionId);
    void AppServices.instance.goals.refresh(this.deviceId, this.sessionId);
    void this.loadComposerCapabilities();

    this.beginInitialLoad();
  }

  aboutToDisappear(): void {
    this.initialScrollGeneration += 1;
    this.initialLoadGeneration += 1;
    this.initialScrollSettling = false;
    this.contextSheetOpen = false;
    this.stopWorkClock();
    for (const u of this.unsubs) {
      u();
    }
    this.unsubs = [];
    void AppServices.instance.messages.closeSession(this.sessionId);
  }

  /**
   * 首次取数延迟 200ms 再显形。Mobile 的本地历史通常瞬时返回，不应闪一下
   * loading；慢链路才显示“正在同步”，空结果则稳定落到“暂无消息”。
   */
  private beginInitialLoad(): void {
    const generation = this.initialLoadGeneration;
    setTimeout(() => {
      if (generation === this.initialLoadGeneration
        && !this.initialLoadResolved
        && this.items.length === 0) {
        this.showInitialSync = true;
      }
    }, 200);
    AppServices.instance.messages.openSession(this.deviceId, this.sessionId).then((loaded: boolean) => {
      if (generation !== this.initialLoadGeneration) return;
      this.sessionOpenResolved = true;
      this.initialLoadResolved = true;
      this.showInitialSync = false;
      this.loadFailed = !loaded || AppServices.instance.messages.loadFailed(this.sessionId);
      this.refreshItems();
      if (loaded) this.scrollToBottomOnce();
    });
  }

  /** 判断当前设备是否关闭远程控制（撤权只读）。 */
  private checkDeviceDisabled(): boolean {
    const devices = AppServices.instance.tasks.deviceList;
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].deviceId === this.deviceId) {
        return !devices[i].remoteControlEnabled;
      }
    }
    return false;
  }

  private isEmbedded(): boolean {
    return this.paneDeviceId.length > 0 && this.paneSessionId.length > 0;
  }

  private session(): RemoteSession | undefined {
    const sessions = AppServices.instance.tasks.getSessions(this.deviceId);
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === this.sessionId) {
        return sessions[i];
      }
    }
    return undefined;
  }

  /** 把任务列表的服务端消息总数交给分页 Store，覆盖 device-link 短页场景。 */
  private syncMessageCount(): void {
    const session = this.session();
    if (session !== undefined && session.messageCount > 0) {
      AppServices.instance.messages.setMessageCount(this.sessionId, session.messageCount);
    }
  }

  /** sessions:patched 回流计划模式后，保持 Sheet 与桌面端真相一致。 */
  private syncComposerContextState(): void {
    const session = this.session();
    if (session === undefined) {
      return;
    }
    this.planModeEnabled = session.planModeEnabled || session.permissionMode === 'plan';
    if (session.permissionMode.length > 0 && session.permissionMode !== 'plan') {
      this.permissionModeBeforePlan = session.permissionMode;
    }
  }

  private agentKindForCapability(session: RemoteSession): string {
    return session.agentKind === 'cc' ? 'claude-code' : session.agentKind;
  }

  private permissionLabel(id: string, fallback: string): string {
    if (id === 'default') return '默认';
    if (id === 'ask') return '每次询问';
    if (id === 'acceptEdits') return '自动接受编辑';
    if (id === 'bypassPermissions') return '完全访问';
    if (id === 'auto') return '自动';
    return fallback.length > 0 ? fallback : id;
  }

  private permissionDescription(id: string, fallback: string): string {
    if (id === 'default') return '使用当前 Agent 的默认权限策略。';
    if (id === 'ask') return '只读工具直接运行；写文件、执行命令和 MCP 工具每次询问。';
    if (id === 'acceptEdits') return '自动允许文件编辑；其它敏感操作仍会询问。';
    if (id === 'auto') return '工作区内写入和安全命令自动运行；高风险操作仍会询问。';
    if (id === 'bypassPermissions') return '所有工具无需询问即可运行。风险最高，仅用于可信任务。';
    return fallback;
  }

  private effortLabel(id: string, fallback: string): string {
    if (id === 'minimal') return '最小';
    if (id === 'low') return '低';
    if (id === 'medium') return '中';
    if (id === 'high') return '高';
    if (id === 'xhigh') return '超高';
    if (id === 'max') return '最高';
    if (id === 'ultra') return '极致';
    return fallback.length > 0 ? fallback : id;
  }

  private parseChoiceOptions(value: Object | undefined, permission: boolean): ComposerChoiceOption[] {
    const out: ComposerChoiceOption[] = [];
    if (!Array.isArray(value)) {
      return out;
    }
    const rows = value as Object[];
    for (let i = 0; i < rows.length; i++) {
      const raw = rows[i];
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        continue;
      }
      const record = raw as Record<string, Object>;
      const id = readStr(record, 'id');
      if (id.length === 0 || (permission && id === 'plan')) {
        continue;
      }
      const option = new ComposerChoiceOption();
      option.id = id;
      const displayName = readStr(record, 'displayName');
      option.label = permission
        ? this.permissionLabel(id, displayName)
        : this.effortLabel(id, displayName);
      option.description = permission
        ? this.permissionDescription(id, readStr(record, 'description'))
        : readStr(record, 'description');
      out.push(option);
    }
    return out;
  }

  private parseModelOptions(value: Object | undefined): ComposerModelOption[] {
    const out: ComposerModelOption[] = [];
    if (!Array.isArray(value)) {
      return out;
    }
    const rows = value as Object[];
    for (let i = 0; i < rows.length; i++) {
      const raw = rows[i];
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
        continue;
      }
      const record = raw as Record<string, Object>;
      const id = readStr(record, 'id');
      if (id.length === 0) {
        continue;
      }
      const option = new ComposerModelOption();
      option.id = id;
      option.label = readStr(record, 'displayName') || id;
      option.description = readStr(record, 'description');
      const rawEfforts = record['efforts'];
      if (Array.isArray(rawEfforts)) {
        const effortValues = rawEfforts as Object[];
        for (let j = 0; j < effortValues.length; j++) {
          if (typeof effortValues[j] === 'string') {
            option.efforts.push(effortValues[j] as string);
          }
        }
      }
      option.defaultEffort = readStr(record, 'defaultEffort');
      option.supportsFastMode = readBool(record, 'supportsFastMode', false);
      const displayNames = readObj(record, 'effortDisplayNames');
      const displayNameKeys = Object.keys(displayNames);
      for (let j = 0; j < displayNameKeys.length; j++) {
        const key = displayNameKeys[j];
        const label = readStr(displayNames, key);
        if (label.length > 0) option.effortDisplayNames[key] = label;
      }
      out.push(option);
    }
    return out;
  }

  private stringArrayHas(value: Object | undefined, expected: string): boolean {
    if (!Array.isArray(value)) return false;
    const values = value as Object[];
    for (let i = 0; i < values.length; i++) {
      if (values[i] === expected) return true;
    }
    return false;
  }

  /**
   * 解析被控端 maker:provider:list 的 per-provider 模型目录。
   * capabilities.availableModels 是跨 provider 去重后的旧平面列表，只能作为旧主机回退；
   * 只要 provider:list 有 connected 来源，就必须以这里的用户配置为准，保留同名模型的
   * 不同 provider 行、订阅标记、模型图标和 per-provider Fast/effort 能力。
   */
  private parseProviderModelOptions(value: Object | undefined, agent: string): ComposerModelOption[] {
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
      return [];
    }
    const root = value as Record<string, Object>;
    const rawProvidersValue = root['providers'];
    if (!Array.isArray(rawProvidersValue)) return [];
    const rawProviders = rawProvidersValue as Object[];
    const out: ComposerModelOption[] = [];
    const selected = this.session();
    for (let i = 0; i < rawProviders.length; i++) {
      const rawProvider: Object = rawProviders[i];
      if (rawProvider === null || typeof rawProvider !== 'object' || Array.isArray(rawProvider)) continue;
      const provider = rawProvider as Record<string, Object>;
      if (!readBool(provider, 'connected', false) || readBool(provider, 'suspended', false)) continue;
      const providerId = readStr(provider, 'id');
      if (providerId.length === 0 || !this.stringArrayHas(provider['agents'], agent)) continue;
      const modelsByAgent = readObj(provider, 'models');
      const rawModelsValue = modelsByAgent[agent];
      if (!Array.isArray(rawModelsValue)) continue;
      const rawModels = rawModelsValue as Object[];
      const access = readObj(provider, 'access');
      const subscription = readStr(access, 'kind') === 'subscription';
      const providerName = readStr(provider, 'name') || providerId;
      const providerLogoKind = readStr(provider, 'logoKind');
      for (let j = 0; j < rawModels.length; j++) {
        const rawModel = rawModels[j];
        if (rawModel === null || typeof rawModel !== 'object' || Array.isArray(rawModel)) continue;
        const model = rawModel as Record<string, Object>;
        const id = readStr(model, 'id');
        if (id.length === 0 || readBool(model, 'disabled', false)) continue;
        const visibilityKey = `${agent}:${providerId}:${id}`;
        const visibility = this.modelVisibilityOverrides.get(visibilityKey);
        if (visibility === false && !(selected !== undefined
          && selected.model === id && selected.providerId === providerId)) continue;
        if (visibility === undefined && !readBool(model, 'defaultEnabled', true)
          && !(selected !== undefined && selected.model === id && selected.providerId === providerId)) continue;
        const option = new ComposerModelOption();
        option.id = id;
        option.label = readStr(model, 'name') || readStr(model, 'displayName') || id;
        option.description = readStr(model, 'description');
        option.defaultEffort = readStr(model, 'defaultEffort');
        option.supportsFastMode = readBool(model, 'supportsFastMode', false);
        const displayNames = readObj(model, 'effortDisplayNames');
        const displayNameKeys = Object.keys(displayNames);
        for (let k = 0; k < displayNameKeys.length; k++) {
          const key = displayNameKeys[k];
          const label = readStr(displayNames, key);
          if (label.length > 0) option.effortDisplayNames[key] = label;
        }
        option.providerId = providerId;
        option.providerName = providerName;
        option.providerLogoKind = providerLogoKind;
        option.modelIcon = readStr(model, 'icon');
        option.subscription = subscription;
        const rawEfforts = model['efforts'];
        if (Array.isArray(rawEfforts)) {
          const efforts = rawEfforts as Object[];
          for (let k = 0; k < efforts.length; k++) {
            if (typeof efforts[k] === 'string') option.efforts.push(efforts[k] as string);
          }
        }
        out.push(option);
      }
    }
    return out;
  }

  private async loadProviderModelOptions(agent: string): Promise<void> {
    try {
      const request = new ProviderListOptions();
      request.capabilities = ['provider-logo-kinds-v2'];
      const result = await this.invokeContextRpc('maker:provider:list', [request]);
      if (result !== undefined && result !== null && typeof result === 'object' && !Array.isArray(result)) {
        const root = result as Record<string, Object>;
        const rawOverrides = root['modelVisibilityOverrides'];
        const nextOverrides = new Map<string, boolean>();
        if (rawOverrides !== null && rawOverrides !== undefined
          && typeof rawOverrides === 'object' && !Array.isArray(rawOverrides)) {
          const overrides = rawOverrides as Record<string, Object>;
          const keys = Object.keys(overrides);
          for (let i = 0; i < keys.length; i++) {
            const key = keys[i];
            if (typeof overrides[key] === 'boolean') nextOverrides.set(key, overrides[key] as boolean);
          }
        }
        this.modelVisibilityOverrides = nextOverrides;
      }
      const options = this.parseProviderModelOptions(result, agent);
      this.providerModelOptions = options;
      this.providerModelAgent = agent;
    } catch (e) {
      // 旧被控端没有 provider:list 时保持 capabilities 扁平回退，不影响模型页其它能力。
      this.providerModelOptions = [];
      this.providerModelAgent = '';
    }
  }

  /** 新主机用 planMode.supported；旧主机以 permissionModes 含 plan 兼容。 */
  private async loadComposerCapabilities(): Promise<void> {
    const session = this.session();
    if (session === undefined) {
      return;
    }
    try {
      const result = await this.invokeContextRpc('maker:get-capabilities', [
        this.agentKindForCapability(session),
      ]);
      if (result === undefined || result === null || typeof result !== 'object' || Array.isArray(result)) {
        return;
      }
      const capabilities = result as Record<string, Object>;
      this.permissionOptions = this.parseChoiceOptions(capabilities['permissionModes'], true);
      this.effortOptions = this.parseChoiceOptions(capabilities['effortLevels'], false);
      this.modelOptions = this.parseModelOptions(capabilities['availableModels']);
      this.fastModeCapability = readBool(capabilities, 'hasFastMode', false);
      await this.loadProviderModelOptions(this.currentAgentTab());
      this.sessionAgentSwitchSupported = readBool(capabilities, 'supportsSessionAgentSwitch', false);
      this.modelAgentTab = this.currentAgentTab();
      if (this.session()?.permissionMode === 'plan') {
        let rememberedSupported = false;
        for (let i = 0; i < this.permissionOptions.length; i++) {
          if (this.permissionOptions[i].id === this.permissionModeBeforePlan) {
            rememberedSupported = true;
            break;
          }
        }
        if (!rememberedSupported) {
          let fallback = this.permissionOptions.length > 0 ? this.permissionOptions[0].id : 'ask';
          for (let i = 0; i < this.permissionOptions.length; i++) {
            if (this.permissionOptions[i].id === 'ask') {
              fallback = 'ask';
              break;
            }
          }
          this.permissionModeBeforePlan = fallback;
        }
      }
      this.planModeSupported = this.capabilityHasNativePlan(capabilities)
        || this.capabilityHasLegacyPlan(capabilities);
      this.syncComposerContextState();
    } catch (e) {
      // 旧主机不支持 capabilities 时隐藏对应运行时控制；其它上下文能力仍可用。
      this.planModeSupported = false;
      this.permissionOptions = [];
      this.modelOptions = [];
      this.effortOptions = [];
      this.fastModeCapability = false;
      this.sessionAgentSwitchSupported = false;
    }
  }

  private capabilityHasNativePlan(capabilities: Record<string, Object>): boolean {
    return readBool(readObj(capabilities, 'planMode'), 'supported', false);
  }

  private capabilityHasLegacyPlan(capabilities: Record<string, Object>): boolean {
    const modes = capabilities['permissionModes'];
    if (!Array.isArray(modes)) {
      return false;
    }
    const permissionModes = modes as Object[];
    for (let i = 0; i < permissionModes.length; i++) {
      const mode = permissionModes[i];
      if (mode === 'plan') {
        return true;
      }
      if (mode !== null && typeof mode === 'object' && !Array.isArray(mode)
        && readStr(mode as Record<string, Object>, 'id') === 'plan') {
        return true;
      }
    }
    return false;
  }

  private async invokeContextRpc(channel: string, args: Object[]): Promise<Object | undefined> {
    await AppServices.instance.openLink(this.deviceId);
    const options = new DlInvokeOptions();
    options.channel = channel;
    options.args = args;
    const envelope = await AppServices.instance.client.invoke(this.deviceId, options);
    return unwrapInvokeResult(envelope);
  }

  private async togglePlanMode(): Promise<void> {
    if (this.contextRpcBusy || !this.planModeSupported) {
      return;
    }
    const session = this.session();
    if (session === undefined) {
      return;
    }
    const next = !this.planModeEnabled;
    this.contextRpcBusy = true;
    try {
      const capabilities = await this.capabilitiesRecord();
      if (this.capabilityHasNativePlan(capabilities)) {
        await this.invokeContextRpc('maker:set-plan-mode', [session.id, next]);
      } else {
        const mode = next ? 'plan' : this.permissionModeBeforePlan;
        await this.invokeContextRpc('maker:set-permission-mode', [session.id, mode]);
      }
      this.planModeEnabled = next;
    } catch (e) {
      promptAction.showToast({ message: '计划模式更新失败，请重试' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  /** 切换时复查一次能力，避免仅靠页面首次加载的兼容推断走错 RPC。 */
  private async capabilitiesRecord(): Promise<Record<string, Object>> {
    const session = this.session();
    if (session === undefined) {
      return {};
    }
    const result = await this.invokeContextRpc('maker:get-capabilities', [
      this.agentKindForCapability(session),
    ]);
    if (result !== undefined && result !== null && typeof result === 'object' && !Array.isArray(result)) {
      return result as Record<string, Object>;
    }
    return {};
  }

  private effectivePermissionMode(): string {
    const session = this.session();
    if (session === undefined) {
      return '';
    }
    return session.permissionMode === 'plan' ? this.permissionModeBeforePlan : session.permissionMode;
  }

  private currentPermissionLabel(): string {
    const mode = this.effectivePermissionMode();
    for (let i = 0; i < this.permissionOptions.length; i++) {
      if (this.permissionOptions[i].id === mode) {
        return this.permissionOptions[i].label;
      }
    }
    return this.permissionLabel(mode, mode);
  }

  private currentAgentTab(): string {
    return modelAgentId(this.agentKindForCapability(this.session() ?? new RemoteSession()));
  }

  private browsingCurrentAgent(): boolean {
    return this.modelAgentTab.length === 0 || this.modelAgentTab === this.currentAgentTab();
  }

  private visibleModelOptions(): ComposerModelOption[] {
    if (this.providerModelOptions.length > 0 && this.providerModelAgent === this.modelAgentTab) {
      return this.providerModelOptions;
    }
    return this.browsingCurrentAgent() ? this.modelOptions : this.alternateModelOptions;
  }

  private visibleEffortOptions(): ComposerChoiceOption[] {
    return this.browsingCurrentAgent() ? this.effortOptions : this.alternateEffortOptions;
  }

  private visibleFastModeCapability(): boolean {
    return this.browsingCurrentAgent() ? this.fastModeCapability : this.alternateFastModeCapability;
  }

  private filteredModelOptions(): ComposerModelOption[] {
    const query = this.modelSearchQuery.trim().toLowerCase();
    const source = this.visibleModelOptions();
    if (query.length === 0) return source;
    const out: ComposerModelOption[] = [];
    for (let i = 0; i < source.length; i++) {
      const option = source[i];
      if (option.label.toLowerCase().includes(query)
        || option.id.toLowerCase().includes(query)
        || option.description.toLowerCase().includes(query)) {
        out.push(option);
      }
    }
    return out;
  }

  private modelOptionKey(option: ComposerModelOption): string {
    return option.providerId.length > 0 ? `${option.providerId}::${option.id}` : option.id;
  }

  private modelOptionIsCurrent(option: ComposerModelOption): boolean {
    const session = this.session();
    if (!this.browsingCurrentAgent() || session === undefined || option.id !== session.model) return false;
    if (session.providerId.length > 0) return option.providerId === session.providerId;
    if (option.providerId.length === 0) return true;
    const source = this.visibleModelOptions();
    for (let i = 0; i < source.length; i++) {
      if (source[i].id === session.model) return source[i].providerId === option.providerId;
    }
    return false;
  }

  private effortOptionLabel(id: string, fallback: string): string {
    const options = this.visibleEffortOptions();
    for (let i = 0; i < options.length; i++) {
      if (options[i].id === id && options[i].label.length > 0) return options[i].label;
    }
    return this.effortLabel(id, fallback);
  }

  private modelEffortText(option: ComposerModelOption): string {
    const session = this.session();
    const effort = this.modelOptionIsCurrent(option) && session !== undefined
      ? session.effort
      : option.defaultEffort;
    if (effort.length === 0) return '';
    return option.effortDisplayNames[effort] ?? this.effortOptionLabel(effort, effort);
  }

  private currentModelKey(): string {
    const source = this.visibleModelOptions();
    for (let i = 0; i < source.length; i++) {
      if (this.modelOptionIsCurrent(source[i])) return this.modelOptionKey(source[i]);
    }
    return this.session()?.model ?? '';
  }

  private modelOptionsForTarget(target: string): ComposerModelOption[] {
    const source = this.visibleModelOptions();
    for (let i = 0; i < source.length; i++) {
      if (this.modelOptionKey(source[i]) === target) return [source[i]];
    }
    for (let i = 0; i < source.length; i++) {
      if (source[i].id === target && this.modelOptionIsCurrent(source[i])) return [source[i]];
    }
    for (let i = 0; i < source.length; i++) {
      if (source[i].id === target) return [source[i]];
    }
    return [];
  }

  private currentModelOption(): ComposerModelOption | null {
    const source = this.visibleModelOptions();
    for (let i = 0; i < source.length; i++) {
      if (this.modelOptionIsCurrent(source[i])) return source[i];
    }
    const modelId = this.session()?.model ?? '';
    for (let i = 0; i < source.length; i++) {
      if (source[i].id === modelId) return source[i];
    }
    return null;
  }

  private currentModelLabel(): string {
    const option = this.currentModelOption();
    if (option !== null) {
      return option.label;
    }
    return this.session()?.model ?? '';
  }

  private currentModelEffortLabel(): string {
    const option = this.currentModelOption();
    if (option !== null) {
      const selectedEffort = this.session()?.effort ?? '';
      const effort = selectedEffort.length > 0 ? selectedEffort : option.defaultEffort;
      if (effort.length === 0) return '';
      return option.effortDisplayNames[effort] ?? this.effortOptionLabel(effort, effort);
    }
    const effort = this.session()?.effort ?? '';
    return effort.length > 0 ? this.effortOptionLabel(effort, effort) : '';
  }

  private currentModelEffortOptions(): ComposerChoiceOption[] {
    const targetId = this.modelOptionsTargetId.length > 0
      ? this.modelOptionsTargetId
      : this.currentModelKey();
    const source = this.modelOptionsForTarget(targetId);
    const model = source.length > 0 ? source[0] : this.currentModelOption();
    if (model === null || model.efforts.length === 0) return [];
    const effortSource = this.browsingCurrentAgent() ? this.effortOptions : this.alternateEffortOptions;
    const out: ComposerChoiceOption[] = [];
    for (let i = 0; i < model.efforts.length; i++) {
      const id = model.efforts[i];
      let matched: ComposerChoiceOption | null = null;
      for (let j = 0; j < effortSource.length; j++) {
        if (effortSource[j].id === id) {
          matched = effortSource[j];
          break;
        }
      }
      if (matched !== null) {
        const customLabel = model.effortDisplayNames[id];
        if (customLabel !== undefined && customLabel.length > 0) {
          const customized = new ComposerChoiceOption();
          customized.id = matched.id;
          customized.label = customLabel;
          customized.description = matched.description;
          out.push(customized);
        } else {
          out.push(matched);
        }
      } else {
        const fallback = new ComposerChoiceOption();
        fallback.id = id;
        fallback.label = model.effortDisplayNames[id] ?? this.effortLabel(id, id);
        out.push(fallback);
      }
    }
    return out;
  }

  private modelAgentIsActive(kind: string): boolean {
    return this.modelAgentTab === kind;
  }

  private modelProviderKind(option: ComposerModelOption): string {
    const icon = option.modelIcon.toLowerCase();
    const logo = option.providerLogoKind.toLowerCase();
    const provider = option.providerId.toLowerCase();
    const id = option.id.toLowerCase();
    if (icon.includes('claude') || logo.includes('anthropic') || provider === 'anthropic') return 'claude';
    if (icon.includes('openai') || logo.includes('openai') || provider === 'openai') return 'openai';
    if (icon.includes('deepseek') || logo.includes('deepseek') || provider === 'deepseek'
      || id.includes('deepseek')) return 'deepseek';
    if (option.providerId.length === 0 && (id.includes('gpt') || id.includes('openai') || id.includes('codex'))) {
      return 'openai';
    }
    return 'other';
  }

  private modelOptionHasOptions(option: ComposerModelOption): boolean {
    return option.efforts.length > 0 || (this.visibleFastModeCapability() && option.supportsFastMode);
  }

  private modelOptionsTarget(): ComposerModelOption[] {
    return this.modelOptionsForTarget(this.modelOptionsTargetId);
  }

  private modelOptionEffortSelected(option: ComposerChoiceOption): boolean {
    return option.id === (this.session()?.effort ?? '');
  }

  private currentModelSupportsFastMode(): boolean {
    const modelId = this.modelOptionsTargetId.length > 0
      ? this.modelOptionsTargetId
      : this.currentModelKey();
    const source = this.modelOptionsForTarget(modelId);
    const model = source.length > 0 ? source[0] : this.currentModelOption();
    return this.visibleFastModeCapability() && model !== null && model.supportsFastMode;
  }

  private openComposerControlSheet(page: string): void {
    if (this.sending || this.contextRpcBusy || this.deviceDisabled) {
      return;
    }
    if (page === 'model') {
      this.modelAgentTab = this.currentAgentTab();
      this.modelSearchQuery = '';
      this.modelOptionsTargetId = '';
      this.alternateModelOptions = [];
      this.alternateEffortOptions = [];
      this.alternateFastModeCapability = false;
      if (this.providerModelAgent !== this.currentAgentTab()) {
        void this.loadProviderModelOptions(this.currentAgentTab());
      }
    }
    this.contextSheetPage = page;
    this.getUIContext().getFocusController().clearFocus();
    this.contextSheetOpen = true;
  }

  private async browseModelAgent(kind: string): Promise<void> {
    if (kind === this.modelAgentTab || this.contextRpcBusy) return;
    if (!this.sessionAgentSwitchSupported) {
      promptAction.showToast({ message: '当前任务不支持切换 Agent' });
      return;
    }
    this.modelAgentTab = kind;
    this.modelSearchQuery = '';
    this.contextRpcBusy = true;
    try {
      const result = await this.invokeContextRpc('maker:get-capabilities', [kind]);
      if (result === undefined || result === null || typeof result !== 'object' || Array.isArray(result)) {
        throw new Error('capabilities unavailable');
      }
      const capabilities = result as Record<string, Object>;
      this.alternateModelOptions = this.parseModelOptions(capabilities['availableModels']);
      this.alternateEffortOptions = this.parseChoiceOptions(capabilities['effortLevels'], false);
      this.alternateFastModeCapability = readBool(capabilities, 'hasFastMode', false);
      await this.loadProviderModelOptions(kind);
    } catch (e) {
      this.modelAgentTab = this.currentAgentTab();
      this.alternateModelOptions = [];
      this.alternateEffortOptions = [];
      this.alternateFastModeCapability = false;
      promptAction.showToast({ message: '无法加载该 Agent 的模型' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  private openModelOptions(option: ComposerModelOption): void {
    if (this.contextRpcBusy) return;
    const session = this.session();
    if (session === undefined) return;
    this.modelOptionsTargetId = this.modelOptionKey(option);
    if (!this.modelOptionIsCurrent(option) || !this.browsingCurrentAgent()) {
      // 非当前模型先完成真实模型/Agent 切换；在远端状态回流前不伪造其推理设置。
      void this.selectComposerModel(option, false);
      return;
    }
    this.contextSheetPage = 'model-options';
  }

  private requestPermissionMode(option: ComposerChoiceOption): void {
    if (option.id === this.effectivePermissionMode() || this.contextRpcBusy) {
      return;
    }
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
            void this.applyPermissionMode(option);
          },
        },
      });
      return;
    }
    void this.applyPermissionMode(option);
  }

  private async applyPermissionMode(option: ComposerChoiceOption): Promise<void> {
    const session = this.session();
    if (session === undefined || this.contextRpcBusy) {
      return;
    }
    this.contextRpcBusy = true;
    try {
      await this.invokeContextRpc('maker:set-permission-mode', [session.id, option.id]);
      this.permissionModeBeforePlan = option.id;
      this.contextSheetOpen = false;
    } catch (e) {
      promptAction.showToast({ message: '权限模式更新失败，请重试' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  private async selectComposerModel(option: ComposerModelOption, keepOpen: boolean = false): Promise<void> {
    const session = this.session();
    if (session === undefined || this.contextRpcBusy) {
      return;
    }
    const targetAgent = this.modelAgentTab.length > 0 ? this.modelAgentTab : this.currentAgentTab();
    const currentAgent = this.currentAgentTab();
    if (session.model === option.id && targetAgent === currentAgent) {
      if (keepOpen) this.contextSheetPage = 'model-options';
      else this.contextSheetOpen = false;
      return;
    }
    this.contextRpcBusy = true;
    try {
      let result: Object | undefined;
      if (targetAgent !== currentAgent) {
        const effort = option.defaultEffort.length > 0
          ? option.defaultEffort
          : (option.efforts.length > 0 ? option.efforts[0] : '');
        result = await this.invokeContextRpc('maker:switch-session-agent', [
          session.id, targetAgent, option.id, option.providerId, effort, false,
        ]);
      } else {
        const args: Object[] = option.providerId.length > 0
          ? [session.id, option.id, option.providerId]
          : [session.id, option.id];
        result = await this.invokeContextRpc('maker:set-model', args);
      }
      if (result !== undefined && result !== null && typeof result === 'object' && !Array.isArray(result)
        && readBool(result as Record<string, Object>, 'deferred', false)) {
        promptAction.showToast({ message: '将在当前运行结束后切换模型' });
      }
      if (keepOpen) {
        this.contextSheetPage = 'model-options';
      } else {
        this.contextSheetOpen = false;
      }
    } catch (e) {
      promptAction.showToast({ message: '模型切换失败，请重试' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  private async selectComposerEffort(option: ComposerChoiceOption): Promise<void> {
    const session = this.session();
    if (session === undefined || this.contextRpcBusy || session.effort === option.id) {
      return;
    }
    this.contextRpcBusy = true;
    try {
      await this.invokeContextRpc('maker:set-effort', [session.id, option.id]);
    } catch (e) {
      promptAction.showToast({ message: '推理强度更新失败，请重试' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  private async toggleFastMode(): Promise<void> {
    const session = this.session();
    if (session === undefined || this.contextRpcBusy || !this.currentModelSupportsFastMode()) {
      return;
    }
    this.contextRpcBusy = true;
    try {
      await this.invokeContextRpc('maker:set-fast-mode', [session.id, !session.fastMode]);
    } catch (e) {
      promptAction.showToast({ message: 'Fast 模式更新失败，请重试' });
    } finally {
      this.contextRpcBusy = false;
    }
  }

  private positiveIntegerOrDefault(value: string, fallback: number): number {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      return fallback;
    }
    const parsed = Number(trimmed);
    return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
  }

  private async startGoal(): Promise<void> {
    const objective = this.goalObjective.trim();
    if (objective.length === 0 || this.goalActionBusy) {
      if (objective.length === 0) {
        promptAction.showToast({ message: '请先填写目标' });
      }
      return;
    }
    const limits = new GoalStartOptions();
    limits.maxTurns = this.positiveIntegerOrDefault(this.goalMaxTurns, -1);
    limits.budgetTokens = this.positiveIntegerOrDefault(this.goalBudgetTokens, -1);
    limits.noProgressLimit = this.positiveIntegerOrDefault(this.goalNoProgressLimit, 3);
    this.goalActionBusy = true;
    try {
      // unknown 状态下先权威回读，避免快照尚未返回时覆盖已存在的目标。
      const statusSynced = await AppServices.instance.goals.refresh(this.deviceId, this.sessionId);
      if (!statusSynced) {
        promptAction.showToast({ message: '无法确认当前目标状态，请重试' });
        return;
      }
      const existing = AppServices.instance.goals.getState(this.sessionId);
      if (existing !== null) {
        this.goalState = existing;
        promptAction.showToast({ message: '当前任务已有目标' });
        return;
      }
      await AppServices.instance.goals.start(this.deviceId, this.sessionId, objective, limits);
      this.goalState = AppServices.instance.goals.getState(this.sessionId);
      this.input = '';
      this.composerInputRevision += 1;
      this.contextSheetOpen = false;
      this.contextSheetPage = 'main';
      this.followLatestSoon();
    } catch (e) {
      promptAction.showToast({ message: '目标启动失败，请重试' });
    } finally {
      this.goalActionBusy = false;
    }
  }

  private async pauseOrResumeGoal(): Promise<void> {
    if (this.goalState === null || this.goalActionBusy) {
      return;
    }
    this.goalActionBusy = true;
    try {
      if (this.goalState.status === 'active') {
        await AppServices.instance.goals.pause(this.deviceId, this.sessionId);
      } else {
        await AppServices.instance.goals.resume(this.deviceId, this.sessionId);
      }
      this.goalState = AppServices.instance.goals.getState(this.sessionId);
    } catch (e) {
      promptAction.showToast({ message: '目标状态更新失败，请重试' });
    } finally {
      this.goalActionBusy = false;
    }
  }

  private confirmClearGoal(): void {
    if (this.goalActionBusy) {
      return;
    }
    this.getUIContext().showActionSheet({
      title: '终止目标',
      message: '目标会停止自动推进，但已经产生的消息会保留。',
      sheets: [{
        title: '终止目标',
        action: () => {
          void this.clearGoal();
        },
      }],
    });
  }

  private async clearGoal(): Promise<void> {
    this.goalActionBusy = true;
    try {
      await AppServices.instance.goals.clear(this.deviceId, this.sessionId);
      this.goalState = null;
    } catch (e) {
      promptAction.showToast({ message: '目标终止失败，请重试' });
    } finally {
      this.goalActionBusy = false;
    }
  }

  private goalStatusText(status: string): string {
    if (status === 'active') return '自动推进中';
    if (status === 'paused') return '已暂停';
    if (status === 'blocked') return '等待处理';
    if (status === 'complete') return '已完成';
    if (status === 'budgetLimited') return '已达到 token 上限';
    if (status === 'usageLimited') return '等待用量恢复';
    return status.length > 0 ? status : '状态未知';
  }

  private send(): void {
    const text = this.input.trim();
    const readyImages: RemoteImageRef[] = [];
    let uploading = false;
    let failed = false;
    for (let i = 0; i < this.composerImages.length; i++) {
      const c = this.composerImages[i];
      if (c.status === 'uploading') {
        uploading = true;
      } else if (c.status === 'failed') {
        failed = true;
      } else if (c.status === 'ready' && c.ref !== null) {
        readyImages.push(c.ref);
      }
    }
    if (this.sending) return;
    if (this.deviceDisabled) {
      promptAction.showToast({ message: '设备已关闭远程控制，仅可查看' });
      return;
    }
    if (uploading) {
      promptAction.showToast({ message: '图片上传中，请稍候' });
      return;
    }
    if (failed) {
      promptAction.showToast({ message: '请重试或移除上传失败的图片' });
      return;
    }
    if (text.length === 0 && readyImages.length === 0) return;
    const s = this.session();
    if (s === undefined) {
      this.error = '任务信息缺失，请返回列表重新进入';
      return;
    }
    const sentInputRevision = this.composerInputRevision;
    const sentImages = this.composerImages.slice();
    this.sending = true;
    this.error = '';
    AppServices.instance.messages.sendText(this.deviceId, s, text, readyImages).then(() => {
      if (this.composerInputRevision === sentInputRevision) {
        this.input = '';
        this.composerInputRevision += 1;
      }
      const remainingImages: ComposerImage[] = [];
      for (let i = 0; i < this.composerImages.length; i++) {
        if (sentImages.indexOf(this.composerImages[i]) < 0) {
          remainingImages.push(this.composerImages[i]);
        }
      }
      this.composerImages = remainingImages;
      this.sending = false;
    }).catch((e: Error) => {
      this.sending = false;
      this.error = `发送失败：${e.message}`;
    });
  }

  // ─── Composer 上下文与图片附件 ──────────────────────────────────────────────

  private openContextSheet(): void {
    if (this.sending || this.pickingImages || this.deviceDisabled) {
      return;
    }
    this.contextSheetPage = 'main';
    this.contextSelectedUris = [];
    try {
      this.recentPickerController.setData(DataType.SET_SELECTED_URIS, []);
    } catch (e) {
      // Picker 尚未挂载时无需清理；新组件会从空选择开始。
    }
    this.getUIContext().getFocusController().clearFocus();
    this.contextSheetOpen = true;
  }

  private remainingImageSlots(): number {
    return Math.max(0, MAX_COMPOSER_IMAGES - this.composerImages.length);
  }

  private selectRecentImage(uri: string): void {
    if (uri.length === 0 || this.contextSelectedUris.includes(uri)) {
      return;
    }
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
    if (this.pickingImages || this.sending) {
      return;
    }
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
    if (this.pickingImages || this.sending) {
      return;
    }
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
    if (this.pickingImages || this.sending || this.remainingImageSlots() <= 0) {
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
        if (uri.length > 0) {
          this.enqueueImageUris([uri]);
        }
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
      if (duplicate) {
        continue;
      }
      this.uploadComposerImage(uri, this.composerImages.length + accepted);
      accepted += 1;
      remaining -= 1;
    }
    if (uris.length > accepted && remaining <= 0) {
      promptAction.showToast({ message: `最多添加 ${MAX_COMPOSER_IMAGES} 张图片` });
    }
  }

  private uploadComposerImage(uri: string, index: number): void {
    const img = new ComposerImage();
    img.uri = uri;
    img.name = `image-${index + 1}`;
    this.composerImages = this.composerImages.concat([img]);
    buildImageCandidate(uri, index).then((candidate) => {
      img.name = candidate.name;
      return AppServices.instance.auth.getAccessToken().then((token: string | null) => {
        if (token === null || token.length === 0) {
          throw new Error('未登录');
        }
        return uploadImage(candidate, token);
      });
    }).then((ref: RemoteImageRef) => {
      img.ref = ref;
      if (img.removed) {
        this.recycleComposerImage(img);
        return;
      }
      img.status = 'ready';
      this.syncComposerImages();
    }).catch(() => {
      if (!img.removed) {
        img.status = 'failed';
        this.syncComposerImages();
      }
    });
  }

  private syncComposerImages(): void {
    this.composerImages = this.composerImages.slice();
  }

  private removeComposerImage(img: ComposerImage): void {
    if (this.sending) {
      return;
    }
    img.removed = true;
    const out: ComposerImage[] = [];
    for (let i = 0; i < this.composerImages.length; i++) {
      if (this.composerImages[i] !== img) {
        out.push(this.composerImages[i]);
      }
    }
    this.composerImages = out;
    this.recycleComposerImage(img);
  }

  private recycleComposerImage(img: ComposerImage): void {
    if (img.ref === null) {
      return;
    }
    const parsed = parseAttachmentOssRef(img.ref.url);
    if (parsed === null || parsed.ossKey.length === 0) {
      return;
    }
    void AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token !== null && token.length > 0) {
        return deleteUpload(parsed.ossKey, token);
      }
      return Promise.resolve();
    }).catch(() => {
      // 删除中转对象是 best-effort，不阻断 Composer 操作。
    });
  }

  private retryComposerImage(img: ComposerImage): void {
    if (this.sending) {
      return;
    }
    img.removed = true;
    // 移除原失败项，再以同一 uri 重新上传（避免新旧两个对象并存）。
    const out: ComposerImage[] = [];
    for (let i = 0; i < this.composerImages.length; i++) {
      if (this.composerImages[i] !== img) {
        out.push(this.composerImages[i]);
      }
    }
    this.composerImages = out;
    this.uploadComposerImage(img.uri, this.composerImages.length);
  }

  private abort(): void {
    AppServices.instance.messages.abort(this.deviceId, this.sessionId).catch(() => {
    });
  }

  private retryLoad(): void {
    this.loadFailed = false;
    this.initialScrolled = false;
    this.initialScrollSettling = true;
    this.initialScrollGeneration += 1;
    this.initialLoadGeneration += 1;
    this.sessionOpenResolved = false;
    this.initialLoadResolved = false;
    this.showInitialSync = false;
    this.followingLatest = true;
    this.hasNewMessages = false;
    this.visibleStartIndex = 0;
    this.visibleEndIndex = -1;
    this.listTouchStartY = 0;
    this.listTouchPulledDown = false;
    this.listTouchPushedUp = false;
    this.listTouchLoadTriggered = false;
    this.syncMessageCount();
    this.beginInitialLoad();
  }

  /** 历史 + 流式统一进入同一个渲染模型，并把会话是否正在流式传入聚合层。 */
  private refreshItems(): void {
    this.syncMessageCount();
    const previousTailToken = this.renderTailToken(this.items);
    const messages = AppServices.instance.messages.getMessagesWithStreaming(this.sessionId);
    const streaming = AppServices.instance.messages.isSessionStreaming(this.sessionId);
    const nextItems = buildRenderItems(messages, streaming);
    const nextTailToken = this.renderTailToken(nextItems);
    const tailChanged = previousTailToken.length > 0 && previousTailToken !== nextTailToken;
    this.sessionStreaming = streaming;
    this.syncWorkClock(streaming);
    this.items = nextItems;
    this.loadFailed = AppServices.instance.messages.loadFailed(this.sessionId);
    this.ensureImageUrls();
    if (this.sessionOpenResolved && this.items.length > 0 && !this.initialScrolled) {
      this.scrollToBottomOnce();
      return;
    }
    if (!tailChanged || this.loadingOlder || !this.sessionOpenResolved) return;
    if (this.followingLatest) {
      this.followLatestSoon();
    } else {
      this.hasNewMessages = true;
    }
  }

  /** 尾部内容 token 同时覆盖同 key 的流式正文增长和工作组内部步骤变化。 */
  private renderTailToken(items: RenderItem[]): string {
    if (items.length === 0) return '';
    const item = items[items.length - 1];
    if (item.type === 'message') {
      const message = item as RenderMessageItem;
      const streaming = message.message !== undefined && message.message.isStreaming ? '1' : '0';
      return `${item.key}:message:${message.body.length}:${message.images.length}:${streaming}`;
    }
    if (item.type === 'work_group') {
      const work = item as RenderWorkGroupItem;
      return `${item.key}:work:${work.children.length}:${work.isStreaming ? '1' : '0'}:${this.renderTailToken(work.children)}`;
    }
    if (item.type === 'tool_group') {
      const tools = (item as RenderToolGroupItem).tools;
      if (tools.length === 0) return `${item.key}:tools:0`;
      const tool = tools[tools.length - 1];
      return `${item.key}:tools:${tools.length}:${tool.hasResult ? '1' : '0'}:${tool.resultText.length}:${tool.media.length}`;
    }
    if (item.type === 'tool_media') {
      const media = item as RenderToolMediaItem;
      return `${item.key}:media:${media.images.length}`;
    }
    if (item.type === 'thinking') {
      return `${item.key}:thinking:${(item as RenderThinkingItem).body.length}`;
    }
    return item.key;
  }

  /** List 顶部的“加载更早消息”也是一个 ListItem，所有渲染项索引都要补这个偏移。 */
  private renderListIndex(renderIndex: number): number {
    return renderIndex + (AppServices.instance.messages.hasMore(this.sessionId) ? 1 : 0);
  }

  private lastMessageListIndex(): number {
    return this.items.length === 0 ? -1 : this.renderListIndex(this.items.length - 1);
  }

  /** 贴底态的流式补滚；不在用户回看历史或 prepend 期间抢阅读位置。 */
  private followLatestSoon(): void {
    const generation = this.initialScrollGeneration;
    setTimeout(() => {
      if (generation !== this.initialScrollGeneration
        || !this.followingLatest
        || this.loadingOlder
        || this.items.length === 0) return;
      this.listScroller.scrollToIndex(this.lastMessageListIndex(), false, ScrollAlign.END);
    }, 24);
  }

  private jumpToLatest(): void {
    this.followingLatest = true;
    this.hasNewMessages = false;
    if (this.items.length > 0) {
      this.listScroller.scrollToIndex(this.lastMessageListIndex(), true, ScrollAlign.END);
    }
  }

  /** 活动工作组使用实时 elapsed，而不是每次事件生成的 duration 快照。 */
  private syncWorkClock(active: boolean): void {
    if (!active) {
      this.stopWorkClock();
      return;
    }
    this.workClockNowMs = Date.now();
    if (this.workClockTimer >= 0) return;
    this.workClockTimer = setInterval(() => {
      this.workClockNowMs = Date.now();
    }, 500);
  }

  private stopWorkClock(): void {
    if (this.workClockTimer >= 0) {
      clearInterval(this.workClockTimer);
      this.workClockTimer = -1;
    }
  }

  private workElapsedMs(item: RenderWorkGroupItem): number {
    if (item.isStreaming && item.startedAtMs > 0) {
      return Math.max(0, this.workClockNowMs - item.startedAtMs);
    }
    return item.durationMs;
  }

  /** 进入会话/重试后定位到最新消息；等待列表完成布局，并阻止首屏翻页抢占锚点。 */
  private scrollToBottomOnce(): void {
    if (this.initialScrolled) {
      return;
    }
    if (this.items.length === 0) {
      return;
    }
    this.initialScrolled = true;
    this.followingLatest = true;
    this.hasNewMessages = false;
    const generation = this.initialScrollGeneration;
    const scroll = (): void => {
      if (generation !== this.initialScrollGeneration || this.items.length === 0) return;
      // List 的默认对齐是 START：滚到最后一项后，后续懒布局会把它重新放回
      // 中间。明确使用 END，并且不再紧接着调用 scrollEdge(Bottom)；后者在
      // 虚拟列表尚未完成测量时会再次改写 offset，正是“到底后弹回中间”的来源。
      this.listScroller.scrollToIndex(this.lastMessageListIndex(), false, ScrollAlign.END);
    };
    setTimeout(scroll, 120);
    setTimeout(scroll, 450);
    setTimeout(scroll, 900);
    setTimeout(() => {
      if (generation === this.initialScrollGeneration) {
        this.initialScrollSettling = false;
      }
    }, 1050);
  }

  /** 短首屏没有可用滚动索引时，对齐 Mobile：用户手指下滑才请求更早历史。 */
  private handleListTouch(event: TouchEvent): void {
    if (event.changedTouches.length === 0) return;
    const point = event.changedTouches[0];
    if (event.type === TouchType.Down) {
      this.listTouchStartY = point.displayY;
      this.listTouchPulledDown = false;
      this.listTouchPushedUp = false;
      this.listTouchLoadTriggered = false;
      return;
    }
    if (event.type === TouchType.Move) {
      const deltaY = point.displayY - this.listTouchStartY;
      // 手指向下超过 8vp 代表明确回看历史。长列表立即解除贴底，后续流式
      // content change 不再把用户拽回末尾；短列表不解除，避免 bounce 误判。
      if (deltaY > 8) {
        this.listTouchPulledDown = true;
        if (this.visibleStartIndex > 0) {
          this.followingLatest = false;
        }
      }
      // 手指向上是回到最新消息的方向；尾项重新可见后恢复贴底跟随。
      if (deltaY < -8) {
        this.listTouchPushedUp = true;
        if (this.visibleEndIndex >= this.lastMessageListIndex()) {
          this.followingLatest = true;
          this.hasNewMessages = false;
        }
      }
      if (this.listTouchLoadTriggered || !this.sessionOpenResolved) {
        return;
      }
      // 未展示的历史在列表上方，因此用户应以“手指向下拖”的方式回看更早消息。
      if (deltaY > 48 && this.visibleStartIndex <= 0) {
        this.listTouchLoadTriggered = true;
        this.loadOlder();
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.listTouchPushedUp && this.visibleEndIndex >= this.lastMessageListIndex()) {
        this.followingLatest = true;
        this.hasNewMessages = false;
      }
      this.listTouchStartY = 0;
      this.listTouchPulledDown = false;
      this.listTouchPushedUp = false;
      this.listTouchLoadTriggered = false;
    }
  }

  /** 滚动到顶部：加载更早历史，并锚定到旧内容起始位置（阅读位置保持）。 */
  private loadOlder(): void {
    if (this.loadingOlder) {
      return;
    }
    if (!AppServices.instance.messages.hasMore(this.sessionId)) {
      return;
    }
    const msgs = AppServices.instance.messages.getMessages(this.sessionId);
    if (msgs.length === 0) {
      return;
    }
    // 不能用“新增原始消息数”作为 List index：多个 thinking/tool 行会被渲染模型
    // 合成一个 work_group，原始消息下标与可见 ListItem 下标并不相等。
    const previousFirstRenderKey = this.items.length > 0 ? this.items[0].key : '';
    this.loadingOlder = true;
    AppServices.instance.messages.loadOlder(this.deviceId, this.sessionId).then(() => {
      this.loadingOlder = false;
      const after = AppServices.instance.messages.getMessages(this.sessionId).length;
      const added = after - msgs.length;
      if (added > 0) {
        // 新加载的更早消息插在头部：回到 prepend 前的第一条渲染项，保持当前阅读点。
        // 这是桌面/Mobile 的 mVCP 语义在 ArkUI List 上的稳定 key 版本。
        setTimeout(() => {
          const anchorIndex = this.renderItemIndex(previousFirstRenderKey);
          if (anchorIndex >= 0) {
            this.listScroller.scrollToIndex(this.renderListIndex(anchorIndex), false);
          } else {
            // 极旧历史没有稳定 work_group key 时保留一个保守兜底，避免阅读位置跳回顶部。
            const fallbackIndex = Math.min(added, Math.max(0, this.items.length - 1));
            this.listScroller.scrollToIndex(this.renderListIndex(fallbackIndex), false);
          }
        }, 50);
      }
    }).catch(() => {
      this.loadingOlder = false;
    });
  }

  /** todo 卡标题（对齐 iOS：{completed}/{total} · 进行中内容）。 */
  private todoTitle(item: RenderTodoCardItem): string {
    let doneCount = 0;
    let activeContent = '';
    for (let i = 0; i < item.todos.length; i++) {
      const t = item.todos[i];
      if (t.status === 'completed') {
        doneCount += 1;
      } else if (t.status === 'in_progress' && activeContent.length === 0) {
        activeContent = t.content;
      }
    }
    const base = `${doneCount}/${item.todos.length}`;
    return activeContent.length > 0 ? `${base} · ${activeContent}` : base;
  }

  /** 思考卡标题（对齐 iOS：思考中 / 思考 Xs / 思考内容已隐藏）。 */
  private thinkingTitle(item: RenderThinkingItem): string {
    if (item.redacted) {
      return '思考内容已隐藏';
    }
    if (item.durationMs > 0) {
      return `思考 ${this.formatDuration(item.durationMs)}`;
    }
    return '思考过程';
  }

  /** 工作过程标题（对齐 iOS：已工作 Xs / 工作过程）。 */
  private workGroupTitle(item: RenderWorkGroupItem): string {
    if (item.isStreaming) {
      return '正在工作…';
    }
    if (item.durationMs >= 0) {
      return `已工作 ${this.formatDuration(item.durationMs)}`;
    }
    return '工作过程';
  }

  /** 活动态收起面板显示最近 5 条步骤，与 Mobile MAX_LIVE_WORK_ACTIVITIES 对齐。 */
  private workPreviewRows(item: RenderWorkGroupItem): WorkPreviewRow[] {
    const rows: WorkPreviewRow[] = [];
    this.appendWorkPreviewRows(item.children, rows);
    if (rows.length <= 5) {
      return rows;
    }
    return rows.slice(rows.length - 5);
  }

  private appendWorkPreviewRows(children: RenderItem[], rows: WorkPreviewRow[]): void {
    for (let i = 0; i < children.length; i++) {
      const child = children[i];
      if (child.type === 'work_group') {
        this.appendWorkPreviewRows((child as RenderWorkGroupItem).children, rows);
      } else if (child.type === 'thinking') {
        const thinking = child as RenderThinkingItem;
        const row = new WorkPreviewRow();
        row.key = child.key;
        row.kind = 'thinking';
        row.text = thinking.body.trim().length > 0
          ? summarizeText(thinking.body, 120)
          : '思考中…';
        rows.push(row);
      } else if (child.type === 'tool_group') {
        const tools = (child as RenderToolGroupItem).tools;
        for (let j = 0; j < tools.length; j++) {
          const tool = tools[j];
          const row = new WorkPreviewRow();
          row.key = `${child.key}-${tool.seq}`;
          row.kind = 'tool';
          row.done = tool.hasResult;
          row.error = tool.hasError;
          row.text = this.toolStepLabel(tool);
          rows.push(row);
        }
      }
    }
  }

  /** 工作步骤文案：优先显示文件/命令等关键输入，避免只显示“正在工作”。 */
  private toolStepLabel(tool: RenderToolItem): string {
    const name = tool.toolName.length > 0 ? tool.toolName : 'tool';
    const lower = name.toLowerCase();
    let action = `调用 ${name}`;
    if (lower.includes('read') || lower === 'cat') {
      action = '读取';
    } else if (lower.includes('grep') || lower.includes('search') || lower.includes('find')) {
      action = '搜索';
    } else if (lower.includes('glob') || lower === 'ls' || lower.includes('list')) {
      action = '查找';
    } else if (lower.includes('write') || lower.includes('edit') || lower.includes('patch')) {
      action = '修改';
    } else if (lower.includes('bash') || lower.includes('shell') || lower.includes('exec') || lower.includes('run')) {
      action = '执行';
    }
    const detail = this.toolStepDetail(tool);
    if (action === `调用 ${name}`) {
      return detail.length > 0 ? `${action} · ${detail}` : action;
    }
    return detail.length > 0 ? `${action} ${detail}` : `${action} ${name}`;
  }

  private toolStepDetail(tool: RenderToolItem): string {
    if (tool.inputRaw.length > 0) {
      try {
        const parsed = JSON.parse(tool.inputRaw) as Object;
        if (parsed !== undefined && parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
          const record = parsed as Record<string, Object>;
          const keys: string[] = ['file_path', 'filePath', 'path', 'command', 'pattern', 'query', 'url'];
          for (let i = 0; i < keys.length; i++) {
            const value = readStr(record, keys[i]);
            if (value.length > 0) return summarizeText(value, 100);
          }
        }
      } catch (e) {
        // inputRaw 可能是旧版非 JSON 摘要，回退到 inputText。
      }
    }
    return tool.inputText.length > 0 ? summarizeText(tool.inputText, 100) : '';
  }

  private toolRowLabel(tool: RenderToolItem): string {
    const name = tool.toolName.length > 0 ? tool.toolName : 'tool';
    const lower = name.toLowerCase();
    if (lower.includes('read') || lower === 'cat') return `读取 ${name}`;
    if (lower.includes('grep') || lower.includes('search') || lower.includes('find')) return `搜索 ${name}`;
    if (lower.includes('glob') || lower === 'ls' || lower.includes('list')) return `查找 ${name}`;
    if (lower.includes('write') || lower.includes('edit') || lower.includes('patch')) return `修改 ${name}`;
    if (lower.includes('bash') || lower.includes('shell') || lower.includes('exec') || lower.includes('run')) return `执行 ${name}`;
    return `调用 ${name}`;
  }

  private compactBoundaryLabel(item: RenderMessageItem): string {
    const message = item.message;
    if (message !== undefined && readStr(message.systemCardData, 'trigger') === 'manual') {
      return '手动压缩';
    }
    return '自动压缩';
  }

  /** 时长格式化（对齐 shared formatDuration：Xs / Xm Ys / Xh Ym）。 */
  private formatDuration(ms: number): string {
    if (ms <= 0) {
      return '1s';
    }
    const totalSeconds = Math.max(1, Math.round(ms / 1000));
    if (totalSeconds < 60) {
      return `${totalSeconds}s`;
    }
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    if (minutes < 60) {
      return seconds > 0 ? `${minutes}m ${seconds}s` : `${minutes}m`;
    }
    const hours = Math.floor(minutes / 60);
    const restMinutes = minutes % 60;
    return restMinutes > 0 ? `${hours}h ${restMinutes}m` : `${hours}h`;
  }

  private toggleExpanded(list: string[], key: string): string[] {
    const idx = list.indexOf(key);
    if (idx >= 0) {
      const out = list.slice(0, idx).concat(list.slice(idx + 1));
      return out;
    }
    return list.concat([key]);
  }

  private isIn(list: string[], key: string): boolean {
    return list.indexOf(key) >= 0;
  }

  /** 返回渲染列表中稳定 key 的位置；渲染项可能把多条原始消息折成一个 work_group。 */
  private renderItemIndex(key: string): number {
    if (key.length === 0) {
      return -1;
    }
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].key === key) {
        return i;
      }
    }
    return -1;
  }

  private headerNotice(): string {
    if (this.deviceDisabled) return '设备已关闭远程控制，仅可查看';
    if (!this.initialLoadResolved && this.showInitialSync) return '正在同步';
    if (this.loadFailed) return '同步失败';
    if (this.pendingInteractions.length > 0) return `待处理 ${this.pendingInteractions.length}`;
    if (this.sessionStreaming) return '运行中';
    return '';
  }

  private searchItemText(item: RenderItem): string {
    if (item.type === 'message') return (item as RenderMessageItem).body;
    if (item.type === 'thinking') return (item as RenderThinkingItem).body;
    if (item.type === 'tool_group') {
      const tools = (item as RenderToolGroupItem).tools;
      let text = '';
      for (let i = 0; i < tools.length; i++) {
        text += ` ${tools[i].toolName} ${tools[i].inputText} ${tools[i].resultText}`;
      }
      return text;
    }
    if (item.type === 'tool_media') {
      const media = item as RenderToolMediaItem;
      let text = '';
      for (let i = 0; i < media.images.length; i++) {
        text += ` ${media.images[i].originalName} ${media.images[i].url}`;
      }
      return text;
    }
    if (item.type === 'todo') {
      const todos = (item as RenderTodoCardItem).todos;
      let text = '';
      for (let i = 0; i < todos.length; i++) text += ` ${todos[i].content}`;
      return text;
    }
    if (item.type === 'work_group') {
      const children = (item as RenderWorkGroupItem).children;
      let text = '';
      for (let i = 0; i < children.length; i++) text += ` ${this.searchItemText(children[i])}`;
      return text;
    }
    return '';
  }

  private searchHitIndices(): number[] {
    const query = this.searchQuery.trim().toLowerCase();
    if (query.length === 0) return [];
    const hits: number[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.searchItemText(this.items[i]).toLowerCase().includes(query)) hits.push(i);
    }
    return hits;
  }

  private moveSearch(delta: number): void {
    const hits = this.searchHitIndices();
    if (hits.length === 0) return;
    let next = (this.searchActiveIndex + delta) % hits.length;
    if (next < 0) next += hits.length;
    this.searchActiveIndex = next;
    this.followingLatest = false;
    this.listScroller.scrollToIndex(this.renderListIndex(hits[next]), true, ScrollAlign.CENTER);
  }

  private closeSearch(): void {
    this.searchOpen = false;
    this.searchQuery = '';
    this.searchActiveIndex = 0;
  }

  private hasComposerContent(): boolean {
    return this.input.trim().length > 0 || this.composerImages.length > 0;
  }

  private canSend(): boolean {
    if (this.sending || this.deviceDisabled) return false;
    let hasReadyImage = false;
    for (let i = 0; i < this.composerImages.length; i++) {
      const image = this.composerImages[i];
      if (image.status !== 'ready' || image.ref === null) return false;
      hasReadyImage = true;
    }
    return this.input.trim().length > 0 || hasReadyImage;
  }

  build() {
    Column() {
      this.taskHeader()
      if (this.searchOpen) {
        this.sessionSearchBar()
      }
      this.messageArea()

      if (this.pendingInteractions.length > 0) {
        // 多个交互请求在窄屏/键盘态内滚动，不能无限挤压消息区和 Composer。
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.pendingInteractions, (item: PendingInteraction) => {
              this.pendingInteractionCard(item)
            }, (item: PendingInteraction) => item.requestId)
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxWidth: 760, maxHeight: 240 })
        .alignSelf(ItemAlign.Center)
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })
      }

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(taskDetailFontSize(12))
          .fontColor($r('app.color.danger'))
          .width('100%')
          .constraintSize({ maxWidth: 760 })
          .alignSelf(ItemAlign.Center)
          .padding({ left: 16, right: 16, top: 4 })
      }

      if (this.deviceDisabled) {
        Text('设备已关闭远程控制，仅可查看')
          .fontSize(taskDetailFontSize(12))
          .fontColor($r('app.color.chat_text_secondary'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 16 })
          .border({ width: { top: 1 }, color: { top: $r('app.color.chat_header_divider') } })
      } else if (this.pendingInteractions.length === 0) {
        // Mobile 中可由本机完成的 pending 会接管 Composer，避免等待确认时继续发送。
        this.composerBar()
      }

      // 全屏图片预览层
      if (this.previewImageUrl.length > 0) {
        Stack() {
          Image(this.previewImageUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
          Text('×')
            .fontSize(taskDetailFontSize(22))
            .fontColor($r('app.color.chat_overlay_text'))
            .backgroundColor($r('app.color.overlay'))
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .borderRadius(18)
            .position({ x: 16, y: 48 })
            .onClick(() => {
              this.previewImageUrl = '';
            })
        }
        .width('100%')
        .height('100%')
        .position({ x: 0, y: 0 })
        .zIndex(99)
        .backgroundColor($r('app.color.chat_overlay_surface'))
        .onClick(() => {
          this.previewImageUrl = '';
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .bindSheet($$this.contextSheetOpen, this.contextSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: true,
      showClose: false,
      preferType: SheetType.BOTTOM,
      backgroundColor: $r('app.color.bg_card'),
      maskColor: $r('app.color.overlay'),
    })
  }

  /** iOS 同层级会话 Header：50vp 内容高、44vp 返回热区与 38vp 动作槽。 */
  @Builder
  taskHeader() {
    Row({ space: 4 }) {
      if (!this.isEmbedded()) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(taskDetailFontSize(20))
            .fontColor([$r('app.color.text_primary')])
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .margin({ left: -8 })
        .onClick(() => router.back())
      }

      Column({ space: 1 }) {
        Text(this.sessionTitle())
          .fontSize(taskDetailFontSize(16))
          .lineHeight(taskDetailLineHeight(22))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.headerNotice().length > 0) {
          Text(this.headerNotice())
            .fontSize(taskDetailFontSize(11))
            .lineHeight(taskDetailLineHeight(16))
            .fontColor(this.sessionStreaming
              ? $r('app.color.chat_status_accent')
              : $r('app.color.chat_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 4 })

      if ((this.session()?.workingDir ?? '').length > 0) {
        Button() {
          SymbolGlyph($r('sys.symbol.folder'))
            .fontSize(taskDetailFontSize(20))
            .fontColor([$r('app.color.text_primary')])
        }
        .width(38)
        .height(38)
        .padding(0)
        .borderRadius(19)
        .backgroundColor(Color.Transparent)
        .onClick(() => this.showProjectActions())
      }

      if (this.items.length > 0) {
        Button() {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(taskDetailFontSize(20))
            .fontColor([$r('app.color.text_primary')])
        }
        .width(38)
        .height(38)
        .padding(0)
        .borderRadius(19)
        .backgroundColor(this.searchOpen ? $r('app.color.bg_chip') : Color.Transparent)
        .onClick(() => {
          if (this.searchOpen) this.closeSearch();
          else this.searchOpen = true;
        })
      }

      Button() {
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(taskDetailFontSize(20))
          .fontColor([$r('app.color.text_primary')])
      }
      .width(38)
      .height(38)
      .padding(0)
      .borderRadius(19)
      .backgroundColor(Color.Transparent)
      .onClick(() => this.showSessionActions())
    }
    .width('100%')
    .constraintSize({ minHeight: 50 })
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .backgroundColor(this.isEmbedded()
      ? $r('app.color.bg_page')
      : $r('app.color.chat_header_surface'))
    .backgroundBlurStyle(this.isEmbedded() ? BlurStyle.NONE : BlurStyle.Thin)
    .border({ width: { bottom: 1 }, color: { bottom: $r('app.color.chat_header_divider') } })
  }

  @Builder
  sessionSearchBar() {
    Row({ space: 4 }) {
      Search({ value: this.searchQuery, placeholder: '搜索消息' })
        .height(36)
        .textFont({ size: taskDetailFontSize(15) })
        .layoutWeight(1)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(18)
        .onChange((value: string) => {
          this.searchQuery = value;
          this.searchActiveIndex = 0;
        })
      if (this.searchQuery.trim().length > 0) {
        Text(this.searchHitIndices().length === 0
          ? '0/0'
          : `${this.searchActiveIndex + 1}/${this.searchHitIndices().length}`)
          .fontSize(taskDetailFontSize(12))
          .fontColor($r('app.color.chat_text_secondary'))
          .constraintSize({ minWidth: 32 })
          .textAlign(TextAlign.Center)
      }
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_up'))
          .fontSize(taskDetailFontSize(16))
          .fontColor([$r('app.color.chat_text_secondary')])
      }
      .width(34)
      .height(34)
      .padding(0)
      .borderRadius(17)
      .backgroundColor(Color.Transparent)
      .enabled(this.searchHitIndices().length > 0)
      .onClick(() => this.moveSearch(-1))
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(taskDetailFontSize(16))
          .fontColor([$r('app.color.chat_text_secondary')])
      }
      .width(34)
      .height(34)
      .padding(0)
      .borderRadius(17)
      .backgroundColor(Color.Transparent)
      .enabled(this.searchHitIndices().length > 0)
      .onClick(() => this.moveSearch(1))
      Button() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(taskDetailFontSize(15))
          .fontColor([$r('app.color.chat_text_secondary')])
      }
      .width(34)
      .height(34)
      .padding(0)
      .borderRadius(17)
      .backgroundColor(Color.Transparent)
      .onClick(() => this.closeSearch())
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 6, bottom: 6 })
    .backgroundColor(this.isEmbedded()
      ? $r('app.color.bg_page')
      : $r('app.color.chat_header_surface'))
    .border({ width: { bottom: 1 }, color: { bottom: $r('app.color.chat_header_divider') } })
  }

  @Builder
  messageArea() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.items.length === 0) {
        Column({ space: 8 }) {
          if (this.loadFailed) {
            Text('加载失败，请检查连接后重试')
              .fontSize(taskDetailFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.danger'))
            Button('重试')
              .fontSize(taskDetailFontSize(12))
              .fontColor($r('app.color.text_primary'))
              .height(32)
              .padding({ left: 12, right: 12 })
              .borderRadius(16)
              .backgroundColor($r('app.color.bg_chip'))
              .onClick(() => this.retryLoad())
          } else if (!this.initialLoadResolved && this.showInitialSync) {
            LoadingProgress()
              .width(14)
              .height(14)
              .color($r('app.color.text_tertiary'))
            Text('正在同步')
              .fontSize(taskDetailFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_tertiary'))
          } else if (this.initialLoadResolved) {
            Text('暂无消息')
              .fontSize(taskDetailFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%')
        .height('100%')
        .constraintSize({ minHeight: 168 })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List({ space: 16, scroller: this.listScroller }) {
          if (AppServices.instance.messages.hasMore(this.sessionId)) {
            ListItem() {
              Button(this.loadingOlder ? '加载中' : '加载更早消息')
                .fontSize(taskDetailFontSize(12))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_tertiary'))
                .height(32)
                .padding({ left: 12, right: 12 })
                .borderRadius(16)
                .backgroundColor(Color.Transparent)
                .enabled(!this.loadingOlder)
                .onClick(() => this.loadOlder())
            }
          }
          ForEach(this.items, (item: RenderItem) => {
            ListItem() {
              this.renderItem(item)
            }
          }, (item: RenderItem) => item.key)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
        .onScrollIndex((start: number, end: number, _center: number) => {
          this.visibleStartIndex = start;
          this.visibleEndIndex = end;
          if (this.listTouchPushedUp && end >= this.lastMessageListIndex()) {
            this.followingLatest = true;
            this.hasNewMessages = false;
          }
          // 不要因为短首屏/初始布局停在 index=0 就自动追翻整段历史。
          if (!this.initialScrollSettling
            && start <= 0
            && this.listTouchPulledDown
            && !this.listTouchLoadTriggered) {
            this.listTouchLoadTriggered = true;
            this.loadOlder();
          }
        })
        .onTouch((event: TouchEvent) => {
          this.handleListTouch(event);
        })
        .onReachStart(() => {
          if (this.initialScrollSettling
            || !this.listTouchPulledDown
            || this.listTouchLoadTriggered) return;
          this.listTouchLoadTriggered = true;
          this.loadOlder();
        })
      }

      if (this.items.length > 0 && !this.followingLatest) {
        Button() {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(taskDetailFontSize(20))
              .fontColor([$r('app.color.chat_text_secondary')])
            if (this.hasNewMessages) {
              Circle()
                .width(8)
                .height(8)
                .fill($r('app.color.chat_cta'))
                .position({ x: 24, y: 3 })
            }
          }
          .width(36)
          .height(36)
        }
        .width(36)
        .height(36)
        .padding(0)
        .borderRadius(18)
        .backgroundColor($r('app.color.chat_fab_surface'))
        .border({ width: 1, color: $r('app.color.chat_fab_border') })
        .margin({ right: 23, bottom: 12 })
        .onClick(() => this.jumpToLatest())
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: 760 })
    .alignSelf(ItemAlign.Center)
    .layoutWeight(1)
  }

  /** Mobile 同款 Composer：活动状态独立于 50vp 输入胶囊，焦点态再展开为卡片。 */
  @Builder
  composerBar() {
    Column({ space: taskDetailDimension(4) }) {
      if (this.sessionStreaming) {
        Row({ space: 6 }) {
          LoadingProgress()
            .width(12)
            .height(12)
            .color($r('app.color.chat_status_accent'))
          Text('正在工作…')
            .fontSize(taskDetailFontSize(12))
            .lineHeight(taskDetailLineHeight(18))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.chat_status_accent'))
        }
        .height(20)
        .padding({ left: 12, right: 12 })
      }

      Column({ space: taskDetailDimension(6) }) {
        if (this.composerImages.length > 0) {
          List() {
            ForEach(this.composerImages, (img: ComposerImage) => {
              ListItem() {
                this.composerImageItem(img)
              }
            }, (img: ComposerImage) => img.uri)
          }
          .listDirection(Axis.Horizontal)
          .width('100%')
          .height(taskDetailDimension(70))
        }

        if (this.composerFocused) {
          Row() {
            Divider()
              .width(taskDetailDimension(40))
              .strokeWidth(taskDetailDimension(4))
              .color($r('app.color.composer_border'))
              .borderRadius(taskDetailDimension(2))
          }
          .height(taskDetailDimension(10))
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }

        Row({ space: taskDetailDimension(6) }) {
          if (this.composerFocused || this.composerImages.length > 0) {
            Button() {
              SymbolGlyph($r('sys.symbol.plus'))
                .fontSize(taskDetailFontSize(20))
                .fontColor([$r('app.color.text_primary')])
            }
            .width(34)
            .height(34)
            .padding(0)
            .borderRadius(17)
            .backgroundColor(Color.Transparent)
            .enabled(!this.sending && !this.pickingImages)
            .onClick(() => this.openContextSheet())

            if (this.permissionOptions.length > 0) {
              Button() {
                SymbolGlyph($r('sys.symbol.lock'))
                  .fontSize(taskDetailFontSize(18))
                  .fontColor([this.effectivePermissionMode() === 'bypassPermissions'
                    || this.effectivePermissionMode() === 'auto'
                    ? $r('app.color.danger')
                    : $r('app.color.text_secondary')])
              }
              .width(34)
              .height(34)
              .padding(0)
              .borderRadius(17)
              .backgroundColor(Color.Transparent)
              .enabled(!this.sending && !this.contextRpcBusy)
              .onClick(() => this.openComposerControlSheet('permission'))
            }

            if (this.planModeEnabled) {
              Button('计划')
                .height(30)
                .fontSize(taskDetailFontSize(12))
                .fontColor($r('app.color.chat_cta'))
                .backgroundColor($r('app.color.bg_chip'))
                .borderRadius(8)
                .padding({ left: 8, right: 8 })
                .enabled(!this.contextRpcBusy)
                .onClick(() => {
                  void this.togglePlanMode();
                })
            }
          }

          TextArea({ placeholder: '输入远程消息', text: this.input })
            .id('task-composer-input')
            .fontSize(taskDetailFontSize(15))
            .placeholderFont({ size: taskDetailFontSize(15) })
            .lineHeight(taskDetailLineHeight(22))
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .caretColor($r('app.color.chat_input_caret'))
            .backgroundColor(Color.Transparent)
            .align(Alignment.Center)
            .textAlign(TextAlign.Start)
            .padding({
              left: taskDetailDimension(4),
              right: taskDetailDimension(4),
            })
            .height(this.composerFocused || this.input.includes('\n')
              ? taskDetailDimension(56)
              : taskDetailDimension(40))
            .layoutWeight(1)
            .onFocus(() => {
              this.composerFocused = true;
            })
            .onBlur(() => {
              this.composerFocused = false;
            })
            .onChange((v: string) => {
              this.input = v;
              this.composerInputRevision += 1;
            })

          if ((this.composerFocused || this.composerImages.length > 0)
            && this.modelOptions.length > 0 && this.currentModelLabel().length > 0) {
            Button() {
              Row({ space: taskDetailDimension(4) }) {
                Text(this.currentModelLabel())
                  .fontSize(taskDetailFontSize(12))
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.currentModelEffortLabel().length > 0) {
                  Text('·')
                    .fontSize(taskDetailFontSize(12))
                    .fontColor($r('app.color.text_tertiary'))
                  Text(this.currentModelEffortLabel())
                    .fontSize(taskDetailFontSize(12))
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                SymbolGlyph($r('sys.symbol.chevron_down'))
                  .fontSize(taskDetailFontSize(13))
                  .fontColor([$r('app.color.text_secondary')])
              }
              .alignItems(VerticalAlign.Center)
            }
            .height(30)
            .constraintSize({ minWidth: 100, maxWidth: 180 })
            .padding({ left: 8, right: 8 })
            .borderRadius(8)
            .backgroundColor($r('app.color.bg_chip'))
            .enabled(!this.sending && !this.contextRpcBusy)
            .onClick(() => this.openComposerControlSheet('model'))
          }

          Button() {
            if (this.sending) {
              LoadingProgress()
                .width(15)
                .height(15)
                .color($r('app.color.chat_cta_text'))
            } else if (this.sessionStreaming && !this.hasComposerContent()) {
              SymbolGlyph($r('sys.symbol.square'))
                .fontSize(taskDetailFontSize(12))
                .fontColor([$r('app.color.chat_cta_text')])
            } else if (this.canSend()) {
              SymbolGlyph($r('sys.symbol.arrow_up'))
                .fontSize(taskDetailFontSize(18))
                .fontColor([$r('app.color.chat_cta_text')])
            } else {
              SymbolGlyph($r('sys.symbol.mic'))
                .fontSize(taskDetailFontSize(20))
                .fontColor([$r('app.color.chat_text_secondary')])
            }
          }
          .width(34)
          .height(34)
          .padding(0)
          .borderRadius(17)
          .backgroundColor(this.sessionStreaming && !this.hasComposerContent() || this.canSend()
            ? $r('app.color.chat_cta')
            : Color.Transparent)
          .enabled(!this.sending)
          .onClick(() => {
            if (this.sessionStreaming && !this.hasComposerContent()) {
              this.abort();
            } else if (this.canSend()) {
              this.send();
            } else {
              this.composerFocused = true;
              setTimeout(() => {
                focusControl.requestFocus('task-composer-input');
                promptAction.showToast({ message: '请点击系统键盘中的麦克风' });
              }, 0);
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .constraintSize({ minHeight: taskDetailDimension(34) })
      .padding({
        left: taskDetailDimension(12),
        right: taskDetailDimension(12),
        top: this.composerFocused ? taskDetailDimension(4) : taskDetailDimension(3),
        bottom: this.composerFocused ? taskDetailDimension(4) : taskDetailDimension(3),
      })
      .backgroundColor($r('app.color.composer_surface'))
      .border({ width: 1, color: $r('app.color.composer_border') })
      .borderRadius(this.composerFocused || this.composerImages.length > 0
        ? taskDetailDimension(8)
        : taskDetailDimension(28))
    }
    .width('100%')
    .constraintSize({ maxWidth: 760 })
    .alignSelf(ItemAlign.Center)
    .padding({
      left: taskDetailDimension(12),
      right: taskDetailDimension(12),
      top: taskDetailDimension(4),
      bottom: taskDetailDimension(2),
    })
  }

  /** iOS 加号同层级：原生可拖拽 Sheet，主视图与目标模式二级视图共用。 */
  @Builder
  contextSheet() {
    Column() {
      Row() {
        if (this.contextSheetPage !== 'main') {
          Button() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(taskDetailFontSize(20))
              .fontColor([$r('app.color.text_primary')])
          }
          .width(36)
          .height(36)
          .padding(0)
          .borderRadius(18)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.contextSheetPage = this.contextSheetPage === 'model-options' ? 'model' : 'main';
          })
        } else {
          Row().width(36).height(36)
        }
        Text(this.contextSheetPage === 'goal'
          ? '目标模式'
          : this.contextSheetPage === 'permission'
            ? '权限模式'
            : this.contextSheetPage === 'model-options'
              ? '推理设置'
              : this.contextSheetPage === 'model'
                ? '模型'
                : '上下文')
          .fontSize(taskDetailFontSize(17))
          .lineHeight(taskDetailLineHeight(24))
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

      if (this.contextSheetPage === 'goal') {
        this.goalContextView()
      } else if (this.contextSheetPage === 'permission') {
        this.permissionContextView()
      } else if (this.contextSheetPage === 'model') {
        this.modelContextView()
      } else if (this.contextSheetPage === 'model-options') {
        this.modelOptionsContextView()
      } else {
        this.contextMainView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_card'))
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
            .fontSize(taskDetailFontSize(15))
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
                .fontSize(taskDetailFontSize(16))
                .lineHeight(taskDetailLineHeight(22))
                .fontColor($r('app.color.text_primary'))
              Text('先生成计划，确认后再执行')
                .fontSize(taskDetailFontSize(12))
                .lineHeight(taskDetailLineHeight(18))
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.planModeEnabled })
              .enabled(!this.contextRpcBusy)
              .onChange(() => {
                void this.togglePlanMode();
              })
          }
          .width('100%')
          .constraintSize({ minHeight: 64 })
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

          Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        }

        this.contextActionRow(
          $r('sys.symbol.flag'),
          '目标模式',
          this.goalState === null ? '让 Cindy 持续推进一个目标' : this.goalStatusText(this.goalState.status),
          () => {
            if (this.goalState === null && this.goalObjective.trim().length === 0) {
              this.goalObjective = this.input;
            }
            this.contextSheetPage = 'goal';
            void AppServices.instance.goals.refresh(this.deviceId, this.sessionId);
          },
        )
        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        this.contextActionRow($r('sys.symbol.picture'), '照片', '', () => this.pickImages())
        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        this.contextActionRow($r('sys.symbol.snapshot'), '截图', '', () => this.pickScreenshots())
        Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        this.contextActionRow($r('sys.symbol.camera'), '拍照', '', () => this.takePhoto())
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
      Column() {
        ForEach(this.permissionOptions, (option: ComposerChoiceOption) => {
          Row({ space: 12 }) {
            this.contextRowIcon($r('sys.symbol.lock'))
            Column({ space: 2 }) {
              Text(option.label)
                .fontSize(taskDetailFontSize(16))
                .lineHeight(taskDetailLineHeight(22))
                .fontColor($r('app.color.text_primary'))
              if (option.description.length > 0) {
                Text(option.description)
                  .fontSize(taskDetailFontSize(12))
                  .lineHeight(taskDetailLineHeight(18))
                  .fontColor($r('app.color.text_tertiary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            if (option.id === this.effectivePermissionMode()) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(taskDetailFontSize(18))
                .fontColor([$r('app.color.chat_cta')])
            }
          }
          .width('100%')
          .constraintSize({ minHeight: 58 })
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .opacity(this.contextRpcBusy ? 0.55 : 1)
          .onClick(() => this.requestPermissionMode(option))
          Divider().strokeWidth(0.5).color($r('app.color.border')).margin({ left: 64 })
        }, (option: ComposerChoiceOption) => option.id)
      }
      .width('100%')
      .padding({ top: 8, bottom: 24 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  modelAgentMark(kind: string, active: boolean) {
    Text(kind === 'claude-code' ? '♟' : kind === 'codex' ? '✣' : 'π')
      .fontSize(taskDetailFontSize(kind === 'pi' ? 20 : 18))
      .fontWeight(FontWeight.Medium)
      .fontColor(active ? $r('app.color.chat_cta_text') : $r('app.color.text_secondary'))
      .width(24)
      .height(24)
      .textAlign(TextAlign.Center)
  }

  @Builder
  modelProviderMark(option: ComposerModelOption) {
    if (this.modelProviderKind(option) === 'claude') {
      Text('♟')
        .fontSize(taskDetailFontSize(22))
        .fontColor($r('app.color.text_secondary'))
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
    } else if (this.modelProviderKind(option) === 'deepseek') {
      Text('◉')
        .fontSize(taskDetailFontSize(22))
        .fontColor($r('app.color.text_secondary'))
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
    } else if (this.modelProviderKind(option) === 'openai') {
      Text('✣')
        .fontSize(taskDetailFontSize(21))
        .fontColor($r('app.color.text_secondary'))
        .width(30)
        .height(30)
        .textAlign(TextAlign.Center)
    } else {
      Stack({ alignContent: Alignment.Center }) {
          Text(option.providerName.length > 0
          ? option.providerName.charAt(0).toUpperCase()
          : 'S')
          .fontSize(taskDetailFontSize(16))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
      }
      .width(30)
      .height(30)
      .border({ width: 2, color: $r('app.color.text_secondary') })
      .borderRadius(15)
    }
  }

  @Builder
  modelAgentSwitcher() {
    Row({ space: 4 }) {
      ForEach(MODEL_AGENT_KINDS, (kind: string) => {
        Button() {
          Row({ space: 7 }) {
            this.modelAgentMark(kind, this.modelAgentIsActive(kind))
            Text(modelAgentLabel(kind))
              .fontSize(taskDetailFontSize(16))
              .fontWeight(this.modelAgentIsActive(kind) ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.modelAgentIsActive(kind)
                ? $r('app.color.chat_cta_text') : $r('app.color.text_secondary'))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height('100%')
        }
        .layoutWeight(1)
        .height(42)
        .padding(0)
        .borderRadius(21)
        .backgroundColor(this.modelAgentIsActive(kind)
          ? $r('app.color.chat_cta') : Color.Transparent)
        .enabled(!this.contextRpcBusy
          && (this.modelAgentIsActive(kind) || this.sessionAgentSwitchSupported))
        .onClick(() => {
          void this.browseModelAgent(kind);
        })
      }, (kind: string) => kind)
    }
    .width('100%')
    .height(52)
    .padding(5)
    .backgroundColor($r('app.color.bg_chip'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(26)
    .margin({ left: 16, right: 16, top: 10 })
  }

  @Builder
  modelOptionRow(option: ComposerModelOption) {
    Row({ space: 10 }) {
      this.modelProviderMark(option)
      Column({ space: 1 }) {
        Row({ space: 8 }) {
          Text(option.label)
            .fontSize(taskDetailFontSize(17))
            .lineHeight(taskDetailLineHeight(23))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (option.subscription) {
            Text('订阅')
              .fontSize(taskDetailFontSize(12))
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.bg_chip'))
              .borderRadius(8)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          }
          if (this.modelEffortText(option).length > 0) {
            Text(this.modelEffortText(option))
              .fontSize(taskDetailFontSize(15))
              .lineHeight(taskDetailLineHeight(22))
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.modelOptionIsCurrent(option)) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(taskDetailFontSize(20))
          .fontColor([$r('app.color.text_primary')])
          .margin({ right: 2 })
      }
      Button() {
        SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
          .fontSize(taskDetailFontSize(20))
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(38)
      .height(38)
      .padding(0)
      .borderRadius(19)
      .backgroundColor(Color.Transparent)
      .enabled(!this.contextRpcBusy && this.modelOptionHasOptions(option))
      .opacity(this.modelOptionHasOptions(option) ? 1 : 0.4)
      .onClick(() => this.openModelOptions(option))
    }
    .width('calc(100% - 32vp)')
    .constraintSize({ minHeight: 66 })
    .padding({ left: 4, right: 4, top: 8, bottom: 8 })
    .margin({ left: 16, right: 16 })
    .backgroundColor(this.modelOptionIsCurrent(option)
      ? $r('app.color.bg_chip') : Color.Transparent)
    .borderRadius(33)
    .opacity(this.contextRpcBusy ? 0.6 : 1)
    .onClick(() => {
      void this.selectComposerModel(option);
    })
  }

  @Builder
  modelContextView() {
    Scroll() {
      Column({ space: 12 }) {
        this.modelAgentSwitcher()

        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(taskDetailFontSize(20))
            .fontColor([$r('app.color.text_secondary')])
          TextInput({ placeholder: '搜索模型...', text: this.modelSearchQuery })
            .fontSize(taskDetailFontSize(15))
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .backgroundColor(Color.Transparent)
            .layoutWeight(1)
            .height(40)
            .padding(0)
            .onChange((value: string) => {
              this.modelSearchQuery = value;
            })
        }
        .width('calc(100% - 32vp)')
        .height(44)
        .padding({ left: 14, right: 12 })
        .border({ width: 1, color: $r('app.color.border') })
        .borderRadius(22)
        .margin({ left: 16, right: 16, top: 2, bottom: 2 })

        Column() {
          if (this.filteredModelOptions().length === 0) {
            Text(this.contextRpcBusy ? '正在加载模型...' : '没有匹配的模型')
              .fontSize(taskDetailFontSize(14))
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 28, bottom: 28 })
          } else {
            ForEach(this.filteredModelOptions(), (option: ComposerModelOption) => {
              this.modelOptionRow(option)
            }, (option: ComposerModelOption) => this.modelOptionKey(option))
          }
        }
        .width('100%')
        .padding({ top: 2, bottom: 20 })
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  modelOptionsContextView() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.modelOptionsTarget().length > 0) {
          Row({ space: 10 }) {
            this.modelProviderMark(this.modelOptionsTarget()[0])
            Column({ space: 2 }) {
              Text(this.modelOptionsTarget()[0].label)
                .fontSize(taskDetailFontSize(19))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('选择推理强度')
                .fontSize(taskDetailFontSize(13))
                .fontColor($r('app.color.text_secondary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 18, bottom: 8 })
        }

        if (this.currentModelEffortOptions().length > 0) {
          Column({ space: 8 }) {
            Text('推理强度')
              .fontSize(taskDetailFontSize(14))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.currentModelEffortOptions(), (option: ComposerChoiceOption) => {
                Button(option.label)
                  .height(38)
                  .fontSize(taskDetailFontSize(14))
                  .fontColor(this.modelOptionEffortSelected(option)
                    ? $r('app.color.chat_cta_text') : $r('app.color.text_primary'))
                  .backgroundColor(this.modelOptionEffortSelected(option)
                    ? $r('app.color.chat_cta') : $r('app.color.bg_chip'))
                  .borderRadius(19)
                  .margin({ right: 8, bottom: 8 })
                  .enabled(!this.contextRpcBusy)
                  .onClick(() => {
                    void this.selectComposerEffort(option);
                  })
              }, (option: ComposerChoiceOption) => option.id)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 20, right: 20, top: 12 })
        }

        if (this.currentModelSupportsFastMode()) {
          Row({ space: 12 }) {
            this.contextRowIcon($r('sys.symbol.bolt'))
            Column({ space: 2 }) {
              Text('Fast 模式')
                .fontSize(taskDetailFontSize(16))
                .fontColor($r('app.color.text_primary'))
              Text('使用当前模型的快速服务通道')
                .fontSize(taskDetailFontSize(12))
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.session()?.fastMode ?? false })
              .enabled(!this.contextRpcBusy)
              .onChange(() => {
                void this.toggleFastMode();
              })
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
        }
      }
      .width('100%')
      .padding({ bottom: 24 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  contextRowIcon(symbol: Resource) {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph(symbol)
        .fontSize(taskDetailFontSize(22))
        .fontColor([$r('app.color.text_primary')])
    }
    .width(36)
    .height(36)
    .borderRadius(8)
    .backgroundColor($r('app.color.bg_chip'))
  }

  @Builder
  contextActionRow(symbol: Resource, title: string, subtitle: string, action: () => void) {
    Row({ space: 12 }) {
      this.contextRowIcon(symbol)
      Column({ space: 2 }) {
        Text(title)
          .fontSize(taskDetailFontSize(16))
          .lineHeight(taskDetailLineHeight(22))
          .fontColor($r('app.color.text_primary'))
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(taskDetailFontSize(12))
            .lineHeight(taskDetailLineHeight(18))
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(taskDetailFontSize(14))
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .onClick(action)
  }

  @Builder
  goalContextView() {
    Scroll() {
      if (this.goalState === null) {
        Column({ space: 14 }) {
          Column({ space: 6 }) {
            Text('目标')
              .fontSize(taskDetailFontSize(13))
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            TextArea({ placeholder: '描述要持续推进的结果', text: this.goalObjective })
              .fontSize(taskDetailFontSize(15))
              .placeholderFont({ size: taskDetailFontSize(15) })
              .lineHeight(taskDetailLineHeight(22))
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              .caretColor($r('app.color.chat_input_caret'))
              .height(108)
              .width('100%')
              .padding(10)
              .backgroundColor($r('app.color.composer_surface'))
              .border({ width: 1, color: $r('app.color.composer_border') })
              .borderRadius(8)
              .onChange((value: string) => {
                this.goalObjective = value;
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Text('可选限制')
            .fontSize(taskDetailFontSize(13))
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          Row({ space: 8 }) {
            Column({ space: 5 }) {
              Text('最大轮数').fontSize(taskDetailFontSize(12)).fontColor($r('app.color.text_tertiary'))
              TextInput({ placeholder: '不限', text: this.goalMaxTurns })
                .type(InputType.Number)
                .height(40)
                .fontSize(taskDetailFontSize(14))
                .backgroundColor($r('app.color.composer_surface'))
                .border({ width: 1, color: $r('app.color.composer_border') })
                .borderRadius(8)
                .onChange((value: string) => {
                  this.goalMaxTurns = value;
                })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Column({ space: 5 }) {
              Text('token 预算').fontSize(taskDetailFontSize(12)).fontColor($r('app.color.text_tertiary'))
              TextInput({ placeholder: '不限', text: this.goalBudgetTokens })
                .type(InputType.Number)
                .height(40)
                .fontSize(taskDetailFontSize(14))
                .backgroundColor($r('app.color.composer_surface'))
                .border({ width: 1, color: $r('app.color.composer_border') })
                .borderRadius(8)
                .onChange((value: string) => {
                  this.goalBudgetTokens = value;
                })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Column({ space: 5 }) {
              Text('无进展轮数').fontSize(taskDetailFontSize(12)).fontColor($r('app.color.text_tertiary'))
              TextInput({ placeholder: '3', text: this.goalNoProgressLimit })
                .type(InputType.Number)
                .height(40)
                .fontSize(taskDetailFontSize(14))
                .backgroundColor($r('app.color.composer_surface'))
                .border({ width: 1, color: $r('app.color.composer_border') })
                .borderRadius(8)
                .onChange((value: string) => {
                  this.goalNoProgressLimit = value;
                })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          Button(this.goalActionBusy ? '正在启动…' : '开始目标')
            .width('100%')
            .height(44)
            .fontSize(taskDetailFontSize(15))
            .fontColor($r('app.color.chat_cta_text'))
            .backgroundColor($r('app.color.chat_cta'))
            .borderRadius(8)
            .enabled(!this.goalActionBusy && this.goalObjective.trim().length > 0)
            .onClick(() => {
              void this.startGoal();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 28 })
      } else {
        Column({ space: 14 }) {
          Row({ space: 8 }) {
            Circle()
              .width(8)
              .height(8)
              .fill(this.goalState.status === 'active'
                ? $r('app.color.chat_status_accent')
                : $r('app.color.text_tertiary'))
            Text(this.goalStatusText(this.goalState.status))
              .fontSize(taskDetailFontSize(14))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')

          Text(this.goalState.objective)
            .fontSize(taskDetailFontSize(17))
            .lineHeight(taskDetailLineHeight(25))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text(`${this.goalState.currentTurns} 轮 · ${this.goalState.cumulativeTokens} tokens`)
            .fontSize(taskDetailFontSize(13))
            .lineHeight(taskDetailLineHeight(20))
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          if (this.goalState.lastReason.length > 0) {
            Text(this.goalState.lastReason)
              .fontSize(taskDetailFontSize(13))
              .lineHeight(taskDetailLineHeight(20))
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
          }

          Row({ space: 10 }) {
            if (this.goalState.status === 'active'
              || this.goalState.status === 'paused'
              || this.goalState.status === 'blocked'
              || this.goalState.status === 'usageLimited') {
              Button(this.goalState.status === 'active' ? '暂停' : '继续')
                .height(42)
                .layoutWeight(1)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.bg_chip'))
                .borderRadius(8)
                .enabled(!this.goalActionBusy)
                .onClick(() => {
                  void this.pauseOrResumeGoal();
                })
            }
            Button('终止')
              .height(42)
              .layoutWeight(1)
              .fontColor($r('app.color.danger'))
              .backgroundColor($r('app.color.bg_chip'))
              .borderRadius(8)
              .enabled(!this.goalActionBusy)
              .onClick(() => this.confirmClearGoal())
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 20, bottom: 28 })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ─── 渲染项分派 ─────────────────────────────────────────────────────────────

  @Builder
  renderItem(item: RenderItem) {
    if (item.type === 'message') {
      if ((item as RenderMessageItem).kind === 'system'
        && (item as RenderMessageItem).message !== undefined
        && (item as RenderMessageItem).message?.systemCardType === 'compact') {
        this.compactBoundaryBlock(item as RenderMessageItem)
      } else {
        this.messageBlock(item as RenderMessageItem)
      }
    } else if (item.type === 'thinking') {
      this.thinkingBlock(item as RenderThinkingItem)
    } else if (item.type === 'tool_group') {
      this.toolGroupBlock(item as RenderToolGroupItem)
    } else if (item.type === 'tool_media') {
      this.toolMediaBlock(item as RenderToolMediaItem)
    } else if (item.type === 'todo') {
      this.todoBlock(item as RenderTodoCardItem)
    } else if (item.type === 'work_group') {
      this.workGroupBlock(item as RenderWorkGroupItem)
    }
  }

  /** 工具产出的图片：独立于工作过程折叠块，保留完整可见结果。 */
  @Builder
  toolMediaBlock(item: RenderToolMediaItem) {
    Column({ space: 6 }) {
      Text('媒体结果')
        .fontSize(taskDetailFontSize(12))
        .fontColor($r('app.color.text_tertiary'))
      List({ space: 8 }) {
        ForEach(item.images, (ref: RemoteImageRef) => {
          ListItem() {
            this.toolMediaImage(ref)
          }
        }, (ref: RemoteImageRef) => `${item.key}-${ref.url}`)
      }
      .listDirection(Axis.Horizontal)
      .height(176)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  toolMediaImage(ref: RemoteImageRef) {
    if ((this.imageSources.get(ref.url) ?? '').length > 0) {
      Image(this.imageSources.get(ref.url) ?? '')
        .width(220)
        .height(165)
        .borderRadius(8)
        .objectFit(ImageFit.Contain)
        .onClick(() => this.openImagePreview(ref))
    } else {
      Row({ space: 6 }) {
        LoadingProgress()
          .width(16)
          .height(16)
        Text(ref.originalName.length > 0 ? ref.originalName : '图片')
          .fontSize(taskDetailFontSize(12))
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width(220)
      .height(165)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(8)
    }
  }

  /**
   * 工作过程折叠面板：历史默认折叠，活动中的 work_group 保留 Mobile 同款
   * 收起态实时步骤预览；点击后展示完整 thinking / tool 行。
   */
  @Builder
  workGroupBlock(item: RenderWorkGroupItem) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        if (item.isStreaming) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('app.color.text_tertiary'))
        } else {
          SymbolGlyph($r('sys.symbol.layer'))
            .fontSize(taskDetailFontSize(14))
            .fontColor([$r('app.color.text_tertiary')])
            .width(16)
        }
        Text(this.workGroupTitle(item))
          .fontSize(taskDetailFontSize(14))
          .lineHeight(taskDetailLineHeight(20))
          .fontColor($r('app.color.chat_text_secondary'))
          .layoutWeight(1)
        if (item.isStreaming) {
          Text(this.formatDuration(this.workElapsedMs(item)))
            .fontSize(taskDetailFontSize(12))
            .fontColor($r('app.color.text_tertiary'))
        }
        SymbolGlyph(this.isIn(this.expandedWorkGroups, item.key)
          ? $r('sys.symbol.chevron_down')
          : $r('sys.symbol.chevron_right'))
          .fontSize(taskDetailFontSize(13))
          .fontColor([$r('app.color.text_tertiary')])
          .width(16)
      }
      .constraintSize({ minHeight: 22 })
      .padding({ top: 2, bottom: 2 })
      .onClick(() => {
        this.expandedWorkGroups = this.toggleExpanded(this.expandedWorkGroups, item.key);
      })
      .width('100%')

      if (item.isStreaming
        && !this.isIn(this.expandedWorkGroups, item.key)
        && this.workPreviewRows(item).length > 0) {
        Column() {
          ForEach(this.workPreviewRows(item), (row: WorkPreviewRow) => {
            this.workPreviewRow(row)
          }, (row: WorkPreviewRow) => `${item.key}-${row.key}`)
        }
        .width('100%')
        .padding({ left: 10, top: 2, bottom: 2 })
        .border({ width: { left: 2 }, color: { left: $r('app.color.border') } })
      }

      if (this.isIn(this.expandedWorkGroups, item.key)) {
        Column({ space: 4 }) {
          ForEach(item.children, (child: RenderItem) => {
            // shared/Desktop 的 outer work_group 展开后直接展示活动内容；Harmony
            // 模型为保持时长边界可能保留一层 nested work_group，这里只展开它的
            // chrome，不再给用户第二个“已工作”折叠入口。
            this.workGroupChild(child)
          }, (child: RenderItem) => `${item.key}-${child.key}`)
        }
        .width('100%')
        .padding({ left: 10, top: 2, bottom: 2 })
        .border({ width: { left: 2 }, color: { left: $r('app.color.border') } })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  workPreviewRow(row: WorkPreviewRow) {
    Row({ space: 6 }) {
      if (row.kind === 'thinking') {
        SymbolGlyph($r('sys.symbol.wand_and_stars'))
          .fontSize(taskDetailFontSize(14))
          .fontColor([$r('app.color.text_tertiary')])
          .width(16)
      } else if (row.error) {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
          .fontSize(taskDetailFontSize(15))
          .fontColor([$r('app.color.danger')])
          .width(16)
      } else if (row.done) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(taskDetailFontSize(14))
          .fontColor([$r('app.color.text_tertiary')])
          .width(16)
      } else {
        LoadingProgress()
          .width(14)
          .height(14)
          .color($r('app.color.text_tertiary'))
          .margin({ left: 1, right: 1 })
      }
      Text(row.text)
        .fontSize(taskDetailFontSize(14))
        .lineHeight(taskDetailLineHeight(20))
        .fontStyle(row.kind === 'thinking' ? FontStyle.Italic : FontStyle.Normal)
        .fontColor($r('app.color.chat_text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .constraintSize({ minHeight: 28 })
    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
  }

  @Builder
  workGroupChild(child: RenderItem) {
    if (child.type === 'work_group') {
      ForEach((child as RenderWorkGroupItem).children, (nested: RenderItem) => {
        this.workGroupChild(nested)
      }, (nested: RenderItem) => `${child.key}-${nested.key}`)
    } else {
      this.renderItem(child)
    }
  }

  /** 自动压缩边界：与 Desktop CompactBoundaryCard 同款“分隔线 + 居中 chip”。 */
  @Builder
  compactBoundaryBlock(item: RenderMessageItem) {
    Row({ space: 8 }) {
      Divider()
        .color($r('app.color.border'))
        .layoutWeight(1)
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.layer'))
          .fontSize(taskDetailFontSize(11))
          .fontColor([$r('app.color.text_tertiary')])
        Text(this.compactBoundaryLabel(item))
          .fontSize(taskDetailFontSize(11))
          .fontColor($r('app.color.text_tertiary'))
      }
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .backgroundColor($r('app.color.bg_chip'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(16)
      Divider()
        .color($r('app.color.border'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  /** 历史消息图片缩略图（点击全屏预览）。 */
  @Builder
  imageThumb(ref: RemoteImageRef) {
    Image(this.imageSources.get(ref.url) ?? '')
      .width(88)
      .height(88)
      .borderRadius(8)
      .objectFit(ImageFit.Contain)
      .onClick(() => this.openImagePreview(ref))
  }

  /** 交互卡分派（按 kind）。 */
  @Builder
  pendingInteractionCard(item: PendingInteraction) {
    if (item.kind === 'permission') {
      this.permissionCard(item)
    } else if (item.kind === 'ask_user_question') {
      this.askUserCard(item)
    } else if (item.kind === 'plan_review') {
      this.planReviewCard(item)
    } else {
      Text(`交互请求（${item.kind}）`)
        .fontSize(taskDetailFontSize(13))
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(10)
    }
  }

  /** Permission 卡：允许一次 / 始终允许 / 拒绝。 */
  @Builder
  permissionCard(item: PendingInteraction) {
    Column({ space: 6 }) {
      Text('权限请求')
        .fontSize(taskDetailFontSize(13))
        .fontWeight(FontWeight.Bold)
      Text(this.permissionToolName(item))
        .fontSize(taskDetailFontSize(14))
      Text(this.permissionInputSummary(item))
        .fontSize(taskDetailFontSize(12))
        .fontColor($r('app.color.text_secondary'))
      Row({ space: 8 }) {
        Button('拒绝')
          .fontSize(taskDetailFontSize(12))
          .backgroundColor($r('app.color.text_secondary'))
          .onClick(() => this.resolveInteraction(item, this.permissionDecision(item, 'deny')))
        Button('允许一次')
          .fontSize(taskDetailFontSize(12))
          .onClick(() => this.resolveInteraction(item, this.permissionDecision(item, 'allow-once')))
        if (this.permissionCanAlwaysAllow(item)) {
          Button('始终允许')
            .fontSize(taskDetailFontSize(12))
            .onClick(() => this.resolveInteraction(item, this.permissionDecision(item, 'always-allow')))
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(10)
  }

  /** Ask User 卡：问题 + 选项（单选/多选）+ 自定义输入 + 提交。 */
  @Builder
  askUserCard(item: PendingInteraction) {
    Column({ space: 6 }) {
      Text(this.askQuestion(item))
        .fontSize(taskDetailFontSize(14))
        .fontWeight(FontWeight.Medium)
      if (this.askOptions(item).length > 0) {
        ForEach(this.askOptions(item), (opt: string) => {
          Row({ space: 6 }) {
            Text(this.isAskSelected(item, opt) ? '☑' : '☐')
              .fontSize(taskDetailFontSize(13))
              .fontColor(this.isAskSelected(item, opt) ? $r('app.color.accent') : $r('app.color.text_secondary'))
            Text(opt)
              .fontSize(taskDetailFontSize(13))
          }
          .width('100%')
          .onClick(() => this.toggleAskSelection(item, opt))
        }, (opt: string) => `${item.requestId}-${opt}`)
      }
      if (this.askAllowsCustom(item)) {
        TextInput({ placeholder: '自定义输入…', text: this.askCustomInputs.get(item.requestId) ?? '' })
          .onChange((v: string) => {
            const next = new Map(this.askCustomInputs);
            next.set(item.requestId, v);
            this.askCustomInputs = next;
          })
          .fontSize(taskDetailFontSize(13))
      }
      Row({ space: 8 }) {
        Button('跳过')
          .fontSize(taskDetailFontSize(12))
          .backgroundColor($r('app.color.text_secondary'))
          .onClick(() => this.resolveInteraction(item, this.askSkip(item)))
        Button('提交')
          .fontSize(taskDetailFontSize(12))
          .onClick(() => this.resolveInteraction(item, this.askDecision(item)))
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(10)
  }

  /** Plan Review 卡：计划查看 + 批准 / 反馈拒绝。 */
  @Builder
  planReviewCard(item: PendingInteraction) {
    Column({ space: 6 }) {
      Text('计划审批')
        .fontSize(taskDetailFontSize(13))
        .fontWeight(FontWeight.Bold)
      Text(this.planText(item))
        .fontSize(taskDetailFontSize(12))
        .fontColor($r('app.color.code_text'))
        .maxLines(8)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row({ space: 8 }) {
        Button('拒绝')
          .fontSize(taskDetailFontSize(12))
          .backgroundColor($r('app.color.text_secondary'))
          .onClick(() => this.resolveInteraction(item, this.planDecision(item, false, '')))
        Button('批准')
          .fontSize(taskDetailFontSize(12))
          .onClick(() => this.resolveInteraction(item, this.planDecision(item, true, this.planText(item))))
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(10)
  }

  /** 待发送图片项（缩略图 + 上传状态 + 移除）。 */
  @Builder
  composerImageItem(img: ComposerImage) {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Image(img.uri)
          .width(56)
          .height(56)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
        Text('✕')
          .fontSize(taskDetailFontSize(10))
          .fontColor($r('app.color.chat_overlay_text'))
          .backgroundColor($r('app.color.overlay'))
          .width(16)
          .height(16)
          .textAlign(TextAlign.Center)
          .borderRadius(8)
          .onClick(() => this.removeComposerImage(img))
      }
      if (img.status === 'uploading') {
        Text('上传中…')
          .fontSize(taskDetailFontSize(10))
          .fontColor($r('app.color.text_secondary'))
      } else if (img.status === 'failed') {
        Text('重试')
          .fontSize(taskDetailFontSize(10))
          .fontColor($r('app.color.danger'))
          .onClick(() => this.retryComposerImage(img))
      } else {
        Text('✓')
          .fontSize(taskDetailFontSize(10))
          .fontColor($r('app.color.success'))
      }
    }
    .padding({ right: 8 })
  }

  private hasVisibleMessageBody(item: RenderMessageItem): boolean {
    return item.body.trim().length > 0 || item.mdBlocks.length > 0 || item.segments.length > 0;
  }

  private messageVerticalPadding(item: RenderMessageItem): number {
    if (item.kind !== 'user') return 4;
    return item.body.length > 140 || item.body.includes('\n') ? 12 : 8;
  }

  private hasMessageActions(item: RenderMessageItem): boolean {
    return item.kind === 'user'
      || (item.kind === 'assistant'
        && item.message !== undefined
        && item.message.turnCompleted);
  }

  private collapsedMessageLines(item: RenderMessageItem): number {
    return collapsedUserMessageLineLimit(
      item.message !== undefined && item.message.automationOrigin,
    );
  }

  private plainMessageExpandKey(item: RenderMessageItem): string {
    return `plain-${item.key}`;
  }

  /**
   * ArkUI 当前没有把 Markdown 子树的真实行数回传给父层；按字符显示宽度做与
   * Mobile 首轮粗筛同用途的保守估算。CJK 计一格，ASCII 计半格，约 21 格/行。
   */
  private estimatedUserMessageLines(text: string): number {
    const rows = text.replace(/\r\n/g, '\n').split('\n');
    let total = 0;
    for (let rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      const row = rows[rowIndex];
      let units = 0;
      for (let i = 0; i < row.length; i++) {
        units += row.charCodeAt(i) > 255 ? 1 : 0.5;
      }
      total += Math.max(1, Math.ceil(units / 21));
    }
    return total;
  }

  /** 结构化粘贴段继续走 chip；这里补普通 user 长消息的整条收起。 */
  private shouldCollapsePlainUserMessage(item: RenderMessageItem): boolean {
    if (item.kind !== 'user' || item.body.trim().length === 0) return false;
    for (let i = 0; i < item.segments.length; i++) {
      if (item.segments[i].isPasted) return false;
    }
    const automation = item.message !== undefined && item.message.automationOrigin;
    return this.estimatedUserMessageLines(item.body) > (automation ? 4 : 14);
  }

  @Builder
  collapsedPlainUserMessage(item: RenderMessageItem) {
    Text(item.body)
      .fontSize(taskDetailFontSize(17))
      .lineHeight(taskDetailLineHeight(26))
      .maxLines(this.collapsedMessageLines(item))
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
    Text('展开全文')
      .fontSize(taskDetailFontSize(12))
      .lineHeight(taskDetailLineHeight(18))
      .fontColor($r('app.color.accent'))
      .onClick(() => {
        this.expandedTextBlocks = this.toggleExpanded(
          this.expandedTextBlocks,
          this.plainMessageExpandKey(item),
        );
      })
  }

  @Builder
  messageBlock(item: RenderMessageItem) {
    Column({ space: 2 }) {
      if (item.kind === 'user'
        && item.message !== undefined
        && item.message.automationOrigin) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.timer'))
            .fontSize(taskDetailFontSize(12))
            .fontColor([$r('app.color.text_tertiary')])
          Text('由自动化发送')
            .fontSize(taskDetailFontSize(12))
            .lineHeight(taskDetailLineHeight(16))
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('86%')
        .justifyContent(FlexAlign.End)
        .alignSelf(ItemAlign.End)
      }

      // iOS 把附件放在文字气泡外；纯附件消息不会留下空白气泡。
      if (item.images.length > 0) {
        List({ space: 6 }) {
          ForEach(item.images, (ref: RemoteImageRef) => {
            ListItem() {
              this.imageThumb(ref)
            }
          }, (ref: RemoteImageRef) => ref.url)
        }
        .listDirection(Axis.Horizontal)
        .height(88)
        .width(item.kind === 'user' ? '86%' : '100%')
        .alignSelf(item.kind === 'user' ? ItemAlign.End : ItemAlign.Start)
      }

      if (this.hasVisibleMessageBody(item)) {
        Column({ space: 4 }) {
          // 普通 user/assistant 没有身份前缀；系统卡保留必要元信息。
          if (item.kind !== 'user' && item.kind !== 'assistant') {
            Row({ space: 8 }) {
              Text(item.label)
                .fontSize(taskDetailFontSize(11))
                .fontColor(this.labelColor(item.kind))
              Text(this.timeLabel(item.message !== undefined ? item.message.createdAt : ''))
                .fontSize(taskDetailFontSize(11))
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
          }

          if (this.shouldCollapsePlainUserMessage(item)
            && !this.isIn(this.expandedTextBlocks, this.plainMessageExpandKey(item))) {
            this.collapsedPlainUserMessage(item)
          } else if (item.kind === 'user' && item.segments.length > 1) {
            ForEach(item.segments, (seg: RenderTextSegment) => {
              if (seg.isPasted) {
                this.pastedChip(item, seg)
              } else if (seg.mdBlocks.length > 0) {
                this.mdBlocks(seg.mdBlocks)
              }
            }, (seg: RenderTextSegment) => `${item.key}-${seg.seq}`)
          } else if (item.kind === 'user' && item.segments.length > 0 && item.segments[0].isPasted) {
            this.pastedBlock(item, item.segments[0])
          } else if (item.mdBlocks.length > 0) {
            this.mdBlocks(item.mdBlocks)
          }

          if (this.shouldCollapsePlainUserMessage(item)
            && this.isIn(this.expandedTextBlocks, this.plainMessageExpandKey(item))) {
            Text('收起')
              .fontSize(taskDetailFontSize(12))
              .lineHeight(taskDetailLineHeight(18))
              .fontColor($r('app.color.accent'))
              .onClick(() => {
                this.expandedTextBlocks = this.toggleExpanded(
                  this.expandedTextBlocks,
                  this.plainMessageExpandKey(item),
                );
              })
          }

          if (item.kind === 'assistant'
            && item.message !== undefined
            && item.message.isStreaming) {
            Text('生成中')
              .fontSize(taskDetailFontSize(12))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.chat_text_secondary'))
              .opacity(0.72)
          }
        }
        .constraintSize({ maxWidth: item.kind === 'user' ? '86%' : '100%' })
        .alignItems(HorizontalAlign.Start)
        .alignSelf(item.kind === 'user' ? ItemAlign.End : ItemAlign.Start)
        .backgroundColor(item.kind === 'user' ? $r('app.color.bg_card') : Color.Transparent)
        .borderRadius(item.kind === 'user' ? 12 : 0)
        .border({
          width: item.kind === 'user' ? 1 : 0,
          color: $r('app.color.chat_bubble_border'),
        })
        .padding({
          left: item.kind === 'user' ? 12 : 0,
          right: item.kind === 'user' ? 12 : 0,
          top: this.messageVerticalPadding(item),
          bottom: this.messageVerticalPadding(item),
        })
      }

      // iOS 操作栏顺序：user 为时间→复制→分叉→更多，assistant 为复制→分叉→更多→时间→用量。
      if (this.hasMessageActions(item)) {
        Row({ space: 2 }) {
          if (item.kind === 'user') {
            Text(this.timeLabel(item.message !== undefined ? item.message.createdAt : ''))
              .fontSize(taskDetailFontSize(12))
              .lineHeight(taskDetailLineHeight(24))
              .fontColor($r('app.color.chat_text_secondary'))
              .margin({ right: 2 })
          }
          Button() {
            SymbolGlyph($r('sys.symbol.rectangle_on_rectangle'))
              .fontSize(taskDetailFontSize(14))
              .fontColor([$r('app.color.chat_text_secondary')])
          }
          .width(24)
          .height(24)
          .padding(0)
          .borderRadius(12)
          .backgroundColor(Color.Transparent)
          .onClick(() => this.copyMessage(item))
          if (this.canFork(item)) {
            Button() {
              SymbolGlyph($r('sys.symbol.split'))
                .fontSize(taskDetailFontSize(14))
                .fontColor([$r('app.color.chat_text_secondary')])
            }
            .width(24)
            .height(24)
            .padding(0)
            .borderRadius(12)
            .backgroundColor(Color.Transparent)
            .onClick(() => this.confirmFork(item))
          }
          Button() {
            SymbolGlyph($r('sys.symbol.ellipsis_circle'))
              .fontSize(taskDetailFontSize(14))
              .fontColor([$r('app.color.chat_text_secondary')])
          }
          .width(24)
          .height(24)
          .padding(0)
          .borderRadius(12)
          .backgroundColor(Color.Transparent)
          .onClick(() => this.showMessageActions(item))
          if (item.kind === 'assistant') {
            Text(this.timeLabel(item.message !== undefined ? item.message.createdAt : ''))
              .fontSize(taskDetailFontSize(12))
              .lineHeight(taskDetailLineHeight(24))
              .fontColor($r('app.color.chat_text_secondary'))
              .margin({ left: 2 })
            if (this.turnTokensLabel(item).length > 0) {
              Text(this.turnTokensLabel(item))
                .fontSize(taskDetailFontSize(12))
                .lineHeight(taskDetailLineHeight(24))
                .fontColor($r('app.color.chat_text_secondary'))
            }
          }
        }
        .height(24)
        .alignSelf(item.kind === 'user' ? ItemAlign.End : ItemAlign.Start)
      }
    }
    .width('100%')
    .alignItems(item.kind === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
  }

  /** 粘贴段 chip：文件图标 + display 摘要，点击展开全文（对齐 iOS InlineReferenceChip）。 */
  @Builder
  pastedChip(item: RenderMessageItem, seg: RenderTextSegment) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text('▤')
          .fontSize(taskDetailFontSize(14))
          .fontColor($r('app.color.text_tertiary'))
        Text(seg.display.length > 0 ? seg.display : `已粘贴文本（${seg.text.length} 字）`)
          .fontSize(taskDetailFontSize(13))
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.isIn(this.expandedTextBlocks, `${item.key}-${seg.seq}`) ? '▾' : '▸')
          .fontSize(taskDetailFontSize(11))
          .fontColor($r('app.color.text_tertiary'))
      }
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(8)
      .width('100%')
      .onClick(() => {
        this.expandedTextBlocks = this.toggleExpanded(this.expandedTextBlocks, `${item.key}-${seg.seq}`);
      })

      if (this.isIn(this.expandedTextBlocks, `${item.key}-${seg.seq}`)) {
        this.mdBlocks(seg.mdBlocks)
        Text('收起')
          .fontSize(taskDetailFontSize(12))
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.expandedTextBlocks = this.toggleExpanded(this.expandedTextBlocks, `${item.key}-${seg.seq}`);
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  pastedBlock(item: RenderMessageItem, seg: RenderTextSegment) {
    Column({ space: 4 }) {
      if (this.isIn(this.expandedTextBlocks, `${item.key}-${seg.seq}`)) {
        this.mdBlocks(seg.mdBlocks)
        Text('收起')
          .fontSize(taskDetailFontSize(12))
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.expandedTextBlocks = this.toggleExpanded(this.expandedTextBlocks, `${item.key}-${seg.seq}`);
          })
      } else {
        // 自动化消息使用更紧的 4/3 行策略；手打消息保持 14/10。
        Text(seg.text)
          .fontSize(taskDetailFontSize(17))
          .lineHeight(taskDetailLineHeight(26))
          .maxLines(this.collapsedMessageLines(item))
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .onClick(() => {
            this.expandedTextBlocks = this.toggleExpanded(this.expandedTextBlocks, `${item.key}-${seg.seq}`);
          })
        Text('展开全文')
          .fontSize(taskDetailFontSize(12))
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.expandedTextBlocks = this.toggleExpanded(this.expandedTextBlocks, `${item.key}-${seg.seq}`);
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  thinkingBlock(item: RenderThinkingItem) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        SymbolGlyph(this.isIn(this.expandedThinking, item.key)
          ? $r('sys.symbol.chevron_down')
          : $r('sys.symbol.chevron_right'))
          .fontSize(taskDetailFontSize(13))
          .fontColor([$r('app.color.chat_text_secondary')])
          .width(16)
        Text(this.thinkingTitle(item))
          .fontSize(taskDetailFontSize(14))
          .lineHeight(taskDetailLineHeight(20))
          .fontColor($r('app.color.chat_text_secondary'))
      }
      .onClick(() => {
        this.expandedThinking = this.toggleExpanded(this.expandedThinking, item.key);
      })

      if (this.isIn(this.expandedThinking, item.key)) {
        if (item.redacted) {
          Text('思考内容已隐藏')
            .fontSize(taskDetailFontSize(12))
            .fontStyle(FontStyle.Italic)
            .fontColor($r('app.color.text_secondary'))
        } else if (item.body.trim().length > 0) {
          // Thinking 正文使用 12/18 斜体小字和 2vp rail，不继承普通消息 17/26 档。
          Text(item.body)
            .fontSize(taskDetailFontSize(12))
            .lineHeight(taskDetailLineHeight(18))
            .fontStyle(FontStyle.Italic)
            .fontColor($r('app.color.chat_text_secondary'))
            .width('100%')
            .padding({ left: 12, top: 2, bottom: 2 })
            .border({ width: { left: 2 }, color: { left: $r('app.color.composer_border') } })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 2, bottom: 2 })
  }

  @Builder
  toolGroupBlock(item: RenderToolGroupItem) {
    Column({ space: 2 }) {
      // work_group 展开后只显示每个真实调用行；tool_group 自己再加“调用 bash”
      // 标题会与行标题叠加，历史数据里尤其容易形成重复的 Bash 行。
      ForEach(item.tools, (t: RenderToolItem) => {
        this.toolRow(t)
      }, (t: RenderToolItem) => `${item.key}-${t.seq}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
  }

  private toolKey(t: RenderToolItem): string {
    return t.toolUseId.length > 0 ? t.toolUseId : `${t.toolName}-${t.seq}`;
  }

  private toolHasDetails(t: RenderToolItem): boolean {
    return t.inputText.length > 0 || (t.hasResult && t.resultText.length > 0);
  }

  @Builder
  toolRow(t: RenderToolItem) {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        if (t.hasError) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(taskDetailFontSize(15))
            .fontColor([$r('app.color.danger')])
            .width(16)
        } else if (t.hasResult) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(taskDetailFontSize(14))
            .fontColor([$r('app.color.text_tertiary')])
            .width(16)
        } else {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('app.color.text_tertiary'))
            .margin({ left: 1, right: 1 })
        }
        Text(this.toolRowLabel(t))
          .fontSize(taskDetailFontSize(14))
          .lineHeight(taskDetailLineHeight(20))
          .fontColor($r('app.color.chat_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.toolHasDetails(t)) {
          SymbolGlyph(this.isIn(this.expandedTools, this.toolKey(t))
            ? $r('sys.symbol.chevron_down')
            : $r('sys.symbol.chevron_right'))
            .fontSize(taskDetailFontSize(13))
            .fontColor([$r('app.color.text_tertiary')])
            .width(16)
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 28 })
      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      .onClick(() => {
        if (this.toolHasDetails(t)) {
          this.expandedTools = this.toggleExpanded(this.expandedTools, this.toolKey(t));
        }
      })

      if (this.toolHasDetails(t) && this.isIn(this.expandedTools, this.toolKey(t))) {
        Column({ space: 4 }) {
          if (t.inputText.length > 0) {
            Text(t.inputText)
              .fontSize(taskDetailFontSize(12))
              .fontFamily('monospace')
              .fontColor($r('app.color.chat_text_secondary'))
              .lineHeight(taskDetailLineHeight(18))
              .width('100%')
          }
          if (t.hasResult && t.resultText.length > 0) {
            Text(t.resultText)
              .fontSize(taskDetailFontSize(12))
              .fontFamily('monospace')
              .fontColor($r('app.color.chat_text_secondary'))
              .lineHeight(taskDetailLineHeight(18))
              .width('100%')
          }
        }
        .width('100%')
        .padding(8)
        .margin({ left: 8, right: 8, bottom: 4 })
        .backgroundColor($r('app.color.bg_code'))
        .border({ width: 1, color: $r('app.color.composer_border') })
        .borderRadius(12)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  todoBlock(item: RenderTodoCardItem) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(this.todoTitle(item))
          .fontSize(taskDetailFontSize(12))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')

      ForEach(item.todos, (t: RenderTodoItem) => {
        Row({ space: 6 }) {
          Text(this.todoMark(t.status))
            .fontSize(taskDetailFontSize(13))
            .fontColor(this.todoColor(t.status))
          Text(t.content)
            .fontSize(taskDetailFontSize(13))
            .fontColor(t.status === 'completed' ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
          if (t.status === 'in_progress') {
            Text('…')
              .fontSize(taskDetailFontSize(13))
              .fontColor($r('app.color.warn'))
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }, (t: RenderTodoItem) => `${item.key}-${t.seq}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(10)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .border({ width: 1, color: $r('app.color.border') })
    .margin({ top: 4, bottom: 4 })
  }

  // ─── Markdown 渲染 ──────────────────────────────────────────────────────────

  private hasImageToken(tokens: InlineToken[]): boolean {
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].kind === 'image') return true;
    }
    return false;
  }

  private markdownImageWidth(token: InlineToken): number {
    return Math.min(token.width > 0 ? token.width : 220, 260);
  }

  private markdownImageHeight(token: InlineToken): number {
    const width = this.markdownImageWidth(token);
    if (token.width > 0 && token.height > 0) {
      return Math.min(260, Math.max(1, Math.round(width * token.height / token.width)));
    }
    return token.height > 0 ? Math.min(token.height, 260) : Math.round(width * 0.75);
  }

  @Builder
  mdInlineContent(tokens: InlineToken[]) {
    Column({ space: 4 }) {
      ForEach(tokens, (token: InlineToken) => {
        if (token.kind === 'image') {
          this.mdInlineImage(token)
        } else {
          this.inlineText(token.value)
        }
      }, (token: InlineToken) => `${token.seq}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  mdInlineImage(token: InlineToken) {
    if ((this.imageSources.get(token.url) ?? '').length > 0) {
      Image(this.imageSources.get(token.url) ?? '')
        .width(this.markdownImageWidth(token))
        .height(this.markdownImageHeight(token))
        .objectFit(ImageFit.Contain)
        .borderRadius(8)
        .onClick(() => this.openInlineImagePreview(token.url))
    } else {
      Row({ space: 6 }) {
        LoadingProgress()
          .width(14)
          .height(14)
        Text(token.value.length > 0 ? token.value : '图片')
          .fontSize(taskDetailFontSize(12))
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width(this.markdownImageWidth(token))
      .height(32)
      .padding({ left: 8, right: 8 })
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(8)
    }
  }

  @Builder
  mdBlocks(blocks: MdBlock[]) {
    ForEach(blocks, (b: MdBlock) => {
      this.mdBlock(b)
    }, (b: MdBlock) => `${b.type}-${b.seq}`)
  }

  @Builder
  mdBlock(b: MdBlock) {
    if (b.type === 'heading') {
      if (this.hasImageToken(b.inlineTokens)) {
        this.mdInlineContent(b.inlineTokens)
      } else {
        Text(b.text)
          .fontSize(taskDetailFontSize(b.level <= 1 ? 20 : (b.level === 2 ? 18 : 17)))
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .lineHeight(taskDetailLineHeight(b.level <= 2 ? 28 : 26))
          .padding({ top: 4, bottom: 4 })
      }
    } else if (b.type === 'paragraph') {
      if (this.hasImageToken(b.inlineTokens)) {
        this.mdInlineContent(b.inlineTokens)
      } else {
        this.inlineText(b.text)
      }
    } else if (b.type === 'list') {
      Column({ space: 2 }) {
        ForEach(b.items, (it: string, idx?: number) => {
          Row({ space: 6 }) {
            Text(b.ordered ? `${(idx ?? 0) + 1}.` : '•')
              .fontSize(taskDetailFontSize(17))
              .fontColor($r('app.color.text_secondary'))
            if (this.hasImageToken(b.itemTokens[idx ?? 0] ?? [])) {
              this.mdInlineContent(b.itemTokens[idx ?? 0] ?? [])
            } else {
              this.inlineText(it)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (it: string, idx?: number) => `${b.seq}:${idx ?? 0}:${it}`)
      }
      .padding({ top: 2, bottom: 2 })
    } else if (b.type === 'quote') {
      if (this.hasImageToken(b.inlineTokens)) {
        Row() {
          this.mdInlineContent(b.inlineTokens)
        }
        .width('100%')
        .padding({ left: 10 })
        .border({ width: { left: 3 }, color: { left: $r('app.color.border') } })
      } else {
        Text(b.text)
          .fontSize(taskDetailFontSize(14))
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(taskDetailLineHeight(22))
          .padding({ left: 10 })
          .border({ width: { left: 3 }, color: { left: $r('app.color.border') } })
          .width('100%')
      }
    } else if (b.type === 'code') {
      Column({ space: 4 }) {
        Text(b.code)
          .fontSize(taskDetailFontSize(12))
          .fontFamily('monospace')
          .fontColor($r('app.color.code_text'))
          .lineHeight(taskDetailLineHeight(18))
          .padding(10)
          .backgroundColor($r('app.color.bg_code'))
          .border({ width: 1, color: $r('app.color.border') })
          .borderRadius(12)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
    } else if (b.type === 'table') {
      this.tableBlock(b)
    } else if (b.type === 'divider') {
      Divider()
        .color($r('app.color.border'))
        .margin({ top: 6, bottom: 6 })
    }
  }

  private tableHeaderTokens(b: MdBlock, index: number): InlineToken[] {
    return b.headerTokens[index] ?? [];
  }

  private tableRowCellTokens(b: MdBlock, rowIndex: number, cellIndex: number): InlineToken[] {
    const row = b.rowTokens[rowIndex];
    return row === undefined ? [] : (row[cellIndex] ?? []);
  }

  private tableContentWidth(b: MdBlock): number {
    return Math.max(320, b.headers.length * 140);
  }

  @Builder
  tableBlock(b: MdBlock) {
    Scroll() {
      Column() {
        Row() {
          ForEach(b.headers, (h: string, hIndex?: number) => {
            Row() {
              if (this.hasImageToken(this.tableHeaderTokens(b, hIndex ?? 0))) {
                this.mdInlineContent(this.tableHeaderTokens(b, hIndex ?? 0))
              } else {
                this.inlineText(h)
              }
            }
            .width(140)
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .border({ width: { right: 1, bottom: 1 }, color: $r('app.color.border') })
          }, (h: string, hIndex?: number) => `${b.seq}-h-${hIndex ?? 0}`)
        }
        .width(this.tableContentWidth(b))

        ForEach(b.rows, (row: string[], rowIndex?: number) => {
          Row() {
            ForEach(row, (cell: string, cellIndex?: number) => {
              Row() {
                if (this.hasImageToken(this.tableRowCellTokens(b, rowIndex ?? 0, cellIndex ?? 0))) {
                  this.mdInlineContent(this.tableRowCellTokens(b, rowIndex ?? 0, cellIndex ?? 0))
                } else {
                  this.inlineText(cell)
                }
              }
              .width(140)
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .border({ width: { right: 1, bottom: 1 }, color: $r('app.color.border') })
            }, (cell: string, cellIndex?: number) => `${b.seq}-${rowIndex ?? 0}-${cellIndex ?? 0}`)
          }
          .width(this.tableContentWidth(b))
        }, (row: string[], rowIndex?: number) => `${b.seq}-r-${rowIndex ?? 0}`)
      }
      .width(this.tableContentWidth(b))
      .border({ width: { left: 1, top: 1 }, color: $r('app.color.border') })
    }
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
  }

  @Builder
  inlineText(text: string) {
    Text() {
      ForEach(tokenizeInline(text), (t: InlineToken) => {
        if (t.kind === 'code') {
          Span(t.value)
            .fontFamily('monospace')
            .fontColor($r('app.color.code_text'))
            .textBackgroundStyle({ color: $r('app.color.bg_chip') })
        } else if (t.kind === 'strong') {
          Span(t.value)
            .fontWeight(FontWeight.Medium)
        } else if (t.kind === 'link' && this.isLocalReference(t.url)) {
          // Desktop 将文件路径、代码文件名等本地引用显示为中性的 code chip，
          // 只有真正的外部链接使用 accent；这样不会把 .ets / HAP 误染成蓝色。
          Span(t.value)
            .fontFamily('monospace')
            .fontColor($r('app.color.code_text'))
            .textBackgroundStyle({ color: $r('app.color.bg_chip') })
            .decoration({ type: TextDecorationType.Underline })
            .onClick(() => this.openUrl(t.url))
        } else if (t.kind === 'link') {
          Span(t.value)
            .fontColor($r('app.color.text_primary'))
            .decoration({ type: TextDecorationType.Underline })
            .onClick(() => this.openUrl(t.url))
        } else {
          Span(t.value)
        }
      }, (t: InlineToken) => `${t.seq}`)
    }
    .fontSize(taskDetailFontSize(17))
    .lineHeight(taskDetailLineHeight(26))
    .textAlign(TextAlign.Start)
  }

  // ─── 样式/工具 ──────────────────────────────────────────────────────────────

  private isLocalReference(url: string): boolean {
    const lower = url.toLowerCase();
    return !lower.startsWith('http://')
      && !lower.startsWith('https://')
      && !lower.startsWith('mailto:')
      && !lower.startsWith('#');
  }

  private labelColor(kind: string): Resource {
    switch (kind) {
      case 'error':
        return $r('app.color.danger');
      case 'agent_switch':
        return $r('app.color.accent');
      case 'user':
        return $r('app.color.text_secondary');
      default:
        return $r('app.color.text_secondary');
    }
  }

  private todoMark(status: string): string {
    if (status === 'completed') return '☑';
    if (status === 'in_progress') return '◐';
    return '☐';
  }

  private todoColor(status: string): Resource {
    if (status === 'completed') return $r('app.color.success');
    if (status === 'in_progress') return $r('app.color.warn');
    return $r('app.color.text_tertiary');
  }

  private pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /** 与 Mobile messageActions 同口径：一分钟内、分钟、小时，再回退日期时间。 */
  private timeLabel(iso: string): string {
    const timestamp = new Date(iso).getTime();
    if (!Number.isFinite(timestamp)) return '';
    const now = Date.now();
    const diff = Math.max(0, now - timestamp);
    if (diff < 60000) return '刚刚';
    if (diff < 3600000) return `${Math.floor(diff / 60000)} 分钟前`;
    if (diff < 86400000) return `${Math.floor(diff / 3600000)} 小时前`;
    const date = new Date(timestamp);
    const current = new Date(now);
    const prefix = date.getFullYear() === current.getFullYear()
      ? `${this.pad2(date.getMonth() + 1)}-${this.pad2(date.getDate())}`
      : `${date.getFullYear()}-${this.pad2(date.getMonth() + 1)}-${this.pad2(date.getDate())}`;
    return `${prefix} ${this.pad2(date.getHours())}:${this.pad2(date.getMinutes())}`;
  }

  private turnTokensLabel(item: RenderMessageItem): string {
    if (item.kind !== 'assistant' || item.message === undefined) return '';
    const usage = readObj(item.message.agentMeta, 'turnUsageDetails');
    const total = readNum(usage, 'totalTokens', 0);
    if (total <= 0) return '';
    if (total >= 1000000) {
      const value = total >= 10000000 ? (total / 1000000).toFixed(1) : (total / 1000000).toFixed(2);
      return `${value.endsWith('.0') ? value.slice(0, -2) : value}M tokens`;
    }
    if (total >= 1000) {
      const value = total >= 10000 ? (total / 1000).toFixed(1) : (total / 1000).toFixed(2);
      return `${value.endsWith('.0') ? value.slice(0, -2) : value}K tokens`;
    }
    return `${Math.floor(total)} tokens`;
  }

  private sessionTitle(): string {
    const s = this.session();
    if (s !== undefined && s.title.length > 0) {
      return s.title;
    }
    return '任务';
  }

  // ─── 消息动作（复制 / Fork / Rewind）───────────────────────────────────────

  /** Fork 条件（对齐 mobile）：assistant 消息，或非首条的 user 消息。 */
  private canFork(item: RenderMessageItem): boolean {
    if (item.kind === 'assistant') {
      return true;
    }
    return item.kind === 'user' && !this.isFirstUserMessage(item);
  }

  /** Rewind 条件（对齐 mobile）：仅 user 消息且非首条。 */
  private canRewind(item: RenderMessageItem): boolean {
    return item.kind === 'user' && !this.isFirstUserMessage(item);
  }

  /** 判断是否为消息流中的首条 user 消息。 */
  private isFirstUserMessage(item: RenderMessageItem): boolean {
    for (let i = 0; i < this.items.length; i++) {
      const it = this.items[i];
      if (it.type === 'message') {
        const m = it as RenderMessageItem;
        if (m.kind === 'user') {
          return m.key === item.key;
        }
      }
    }
    return false;
  }

  private copyPlainText(value: string, successMessage: string): void {
    if (value.length === 0) return;
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: successMessage });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败' });
    });
  }

  private showProjectActions(): void {
    const workingDir = this.session()?.workingDir ?? '';
    if (workingDir.length === 0) return;
    this.getUIContext().showActionSheet({
      title: '项目文件',
      message: workingDir,
      sheets: [{
        title: '复制项目路径',
        action: () => this.copyPlainText(workingDir, '已复制项目路径'),
      }],
    });
  }

  private showSessionActions(): void {
    const workingDir = this.session()?.workingDir ?? '';
    if (workingDir.length > 0) {
      this.getUIContext().showActionSheet({
        title: '任务操作',
        message: this.sessionTitle(),
        sheets: [{
          title: '复制任务 ID',
          action: () => this.copyPlainText(this.sessionId, '已复制任务 ID'),
        }, {
          title: '复制任务标题',
          action: () => this.copyPlainText(this.sessionTitle(), '已复制任务标题'),
        }, {
          title: '复制项目路径',
          action: () => this.copyPlainText(workingDir, '已复制项目路径'),
        }],
      });
      return;
    }
    this.getUIContext().showActionSheet({
      title: '任务操作',
      message: this.sessionTitle(),
      sheets: [{
        title: '复制任务 ID',
        action: () => this.copyPlainText(this.sessionId, '已复制任务 ID'),
      }, {
        title: '复制任务标题',
        action: () => this.copyPlainText(this.sessionTitle(), '已复制任务标题'),
      }],
    });
  }

  private addMessageToComposer(item: RenderMessageItem): void {
    const body = item.body.trim();
    if (body.length === 0) return;
    this.input = this.input.trim().length === 0 ? body : `${this.input}\n\n${body}`;
    this.composerInputRevision += 1;
    promptAction.showToast({ message: '已添加到输入框' });
  }

  private showMessageActions(item: RenderMessageItem): void {
    const messageId = item.message?.clientId || item.message?.id || item.key;
    if (this.canRewind(item)) {
      this.getUIContext().showActionSheet({
        title: '消息操作',
        message: this.timeLabel(item.message?.createdAt ?? '') || '选择操作',
        sheets: [{
          title: '添加到输入框',
          action: () => this.addMessageToComposer(item),
        }, {
          title: '复制消息 ID',
          action: () => this.copyPlainText(messageId, '已复制消息 ID'),
        }, {
          title: '回退到这里',
          action: () => this.confirmRewind(item),
        }],
      });
      return;
    }
    this.getUIContext().showActionSheet({
      title: '消息操作',
      message: this.timeLabel(item.message?.createdAt ?? '') || '选择操作',
      sheets: [{
        title: '添加到输入框',
        action: () => this.addMessageToComposer(item),
      }, {
        title: '复制消息 ID',
        action: () => this.copyPlainText(messageId, '已复制消息 ID'),
      }],
    });
  }

  private copyMessage(item: RenderMessageItem): void {
    this.copyPlainText(item.body, '已复制');
  }

  private confirmFork(item: RenderMessageItem): void {
    this.resolveClientId(item).then((clientId: string) => {
      if (clientId.length === 0) {
        promptAction.showToast({ message: '无法定位消息' });
        return;
      }
      AlertDialog.show({
        title: '分叉任务',
        message: '将以这条消息为起点创建新任务，原任务保持不变。',
        primaryButton: {
          value: '取消',
          action: () => {
          },
        },
        secondaryButton: {
          value: '分叉',
          action: () => this.doFork(clientId),
        },
      });
    });
  }

  private confirmRewind(item: RenderMessageItem): void {
    this.resolveClientId(item).then((clientId: string) => {
      if (clientId.length === 0) {
        promptAction.showToast({ message: '无法定位消息' });
        return;
      }
      AlertDialog.show({
        title: '回退任务',
        message: '将回退到这条消息，之后的消息会被移除。',
        primaryButton: {
          value: '取消',
          action: () => {
          },
        },
        secondaryButton: {
          value: '回退',
          action: () => this.doRewind(clientId),
        },
      });
    });
  }

  /** 取消息的 clientId（messages:list 返回完整行，含 clientId）。 */
  private resolveClientId(item: RenderMessageItem): Promise<string> {
    const msg = item.message;
    return Promise.resolve(msg !== undefined ? msg.clientId : '');
  }

  // ─── 历史图片（懒解析 OSS URL / 缩略图 / 全屏预览）─────────────────────────

  /** 遍历当前消息流的图片引用，补齐附件和 Markdown 图片的可加载 URL。 */
  private ensureImageUrls(): void {
    for (let i = 0; i < this.items.length; i++) {
      const item = this.items[i];
      if (item.type === 'tool_media') {
        const media = item as RenderToolMediaItem;
        for (let j = 0; j < media.images.length; j++) {
          const ref = media.images[j];
          this.ensureImageSource(ref.url, ref);
        }
        continue;
      }
      if (item.type !== 'message') continue;
      const message = item as RenderMessageItem;
      for (let j = 0; j < message.images.length; j++) {
        const ref = message.images[j];
        this.ensureImageSource(ref.url, ref);
      }
      const blocks: MdBlock[] = [];
      if (message.segments.length > 0) {
        for (let j = 0; j < message.segments.length; j++) {
          const segment = message.segments[j];
          for (let k = 0; k < segment.mdBlocks.length; k++) blocks.push(segment.mdBlocks[k]);
        }
      } else {
        for (let j = 0; j < message.mdBlocks.length; j++) blocks.push(message.mdBlocks[j]);
      }
      for (let j = 0; j < blocks.length; j++) {
        const block = blocks[j];
        this.ensureInlineImageSources(block.inlineTokens);
        for (let k = 0; k < block.itemTokens.length; k++) {
          this.ensureInlineImageSources(block.itemTokens[k]);
        }
        for (let k = 0; k < block.headerTokens.length; k++) {
          this.ensureInlineImageSources(block.headerTokens[k]);
        }
        for (let k = 0; k < block.rowTokens.length; k++) {
          const rowTokens = block.rowTokens[k];
          for (let c = 0; c < rowTokens.length; c++) {
            this.ensureInlineImageSources(rowTokens[c]);
          }
        }
      }
    }
  }

  private ensureInlineImageSources(tokens: InlineToken[]): void {
    for (let i = 0; i < tokens.length; i++) {
      const token = tokens[i];
      if (token.kind !== 'image' || token.url.length === 0) continue;
      const ref = this.markdownImageRef(token);
      this.ensureImageSource(token.url, ref);
    }
  }

  private ensureImageSource(key: string, ref: RemoteImageRef): void {
    if (key.length === 0 || this.imageSources.has(key) || this.imageResolutions.has(key)) return;
    const pending = this.resolveImageUrl(ref);
    this.imageResolutions.set(key, pending);
    pending.then((url: string) => {
      if (url.length > 0) {
        const next = new Map(this.imageSources);
        next.set(key, url);
        this.imageSources = next;
      }
      this.imageResolutions.delete(key);
    }).catch(() => {
      this.imageResolutions.delete(key);
    });
  }

  private markdownImageRef(token: InlineToken): RemoteImageRef {
    const ref = new RemoteImageRef();
    ref.url = this.normalizeMarkdownImageUrl(token.url);
    ref.originalName = token.value;
    return ref;
  }

  /**
   * Markdown 图片地址只在被控端媒体链路消费点解析：相对路径绑定当前 session
   * workingDir，SSH 上下文绑定当前 session 的 remoteHostId，绝不把远端绝对路径
   * 当成 Harmony 本机路径。
   */
  private normalizeMarkdownImageUrl(raw: string): string {
    const url = normalizeImageUrlScheme(raw.trim());
    if (url.startsWith('http://') || url.startsWith('https://')
      || /^data:image\//i.test(url) || parseAttachmentOssRef(url) !== null
      || url.startsWith('xdt-image://') || url.startsWith('cindy-media://')) {
      return url;
    }
    // 绝对 Windows / UNC 路径不是 URI scheme；其它显式 scheme（尤其
    // javascript:/vbscript:）不能降级成 workingDir 下的相对文件名。
    if (!isAbsoluteMediaPath(url) && /^[A-Za-z][A-Za-z0-9+.-]*:/.test(url)
      && !url.startsWith('file://') && !url.startsWith('xdt-file://')) {
      return '';
    }
    const session = this.session();
    const workingDir = session !== undefined ? session.workingDir : '';
    const remoteHostId = session !== undefined ? session.remoteHostId : '';
    let path = url;
    if (url.startsWith('xdt-file://')) {
      const query = url.indexOf('?');
      const encodedPath = query >= 0 ? queryValue(url.slice(query + 1), 'path') : '';
      if (encodedPath.length === 0) return '';
      path = encodedPath;
    } else if (url.startsWith('file://')) {
      path = url.slice('file://'.length);
      if (path.startsWith('localhost/')) path = path.slice('localhost'.length);
      try {
        path = decodeURIComponent(path);
      } catch (e) {
        return '';
      }
    }
    if (!isAbsoluteMediaPath(path)) {
      if (workingDir.length === 0) return '';
      const relative = path.startsWith('./') ? path.slice(2) : path;
      path = workingDir.endsWith('/') || workingDir.endsWith('\\')
        ? `${workingDir}${relative}`
        : `${workingDir}/${relative}`;
    }
    let normalized = `xdt-file://open?path=${encodeURIComponent(path)}`;
    if (remoteHostId.length > 0) {
      if (workingDir.length === 0) return '';
      normalized += `&sessionId=${encodeURIComponent(this.sessionId)}`
        + `&remoteHostId=${encodeURIComponent(remoteHostId)}`
        + `&workdir=${encodeURIComponent(workingDir)}`;
    }
    return normalized;
  }

  /**
   * 解析图片引用为可加载 URL：
   * - http(s) 直链直接使用；
   * - cindy/xdt OSS 引用走 presign-get；
   * - Desktop 本地媒体引用走 device-link:media:fetch，再兼容 inline 缩略图和 OSS。
   */
  private resolveImageUrl(ref: RemoteImageRef): Promise<string> {
    const url = normalizeImageUrlScheme(ref.url.trim());
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return Promise.resolve(url);
    }
    if (/^data:image\//i.test(url)) {
      return Promise.resolve(url);
    }
    const parsed = parseAttachmentOssRef(url);
    if (parsed !== null) {
      return this.resolveOssUrl(parsed.ossKey).catch(() => {
        return '';
      });
    }
    if (!this.isDesktopLocalImageUrl(url)) {
      return Promise.resolve('');
    }

    return AppServices.instance.messages.fetchRemoteMedia(this.deviceId, url, true).then(
      (fetched: RemoteMediaFetchResult) => {
        if (fetched.inlineBase64.length > 0) {
          const mimeType = fetched.mimeType.length > 0
            ? fetched.mimeType
            : (ref.mimeType.length > 0 ? ref.mimeType : 'image/webp');
          if (!isImageMimeType(mimeType)) return '';
          return `data:${mimeType};base64,${fetched.inlineBase64}`;
        }
        if (fetched.ossKey.length === 0) {
          return '';
        }
        return this.resolveOssUrl(fetched.ossKey);
      },
    ).catch(() => {
      return '';
    });
  }

  /** 解析被控端历史媒体 URL 的最小图片 scheme 集合。 */
  private isDesktopLocalImageUrl(url: string): boolean {
    return /^(?:xdt-image|cindy-media|xdt-file):\/\//i.test(url);
  }

  /** OSS key → 临时可加载地址，并在页面生命周期内复用。 */
  private resolveOssUrl(ossKey: string): Promise<string> {
    const cached = this.ossUrlCache.get(ossKey);
    if (cached !== undefined) {
      return Promise.resolve(cached);
    }
    return AppServices.instance.auth.getAccessToken().then((token: string | null) => {
      if (token === null || token.length === 0) {
        throw new Error('未登录');
      }
      return presignGet(ossKey, token);
    }).then((getUrl: string) => {
      this.ossUrlCache.set(ossKey, getUrl);
      return getUrl;
    });
  }

  /** 用系统浏览器打开链接（Markdown 链接点击）。 */
  private openUrl(url: string): void {
    if (url.length === 0) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    context.startAbility({
      action: 'ohos.want.action.viewData',
      uri: url,
    }).catch(() => {
      promptAction.showToast({ message: '无法打开链接' });
    });
  }

  private openInlineImagePreview(url: string): void {
    const src = this.imageSources.get(url) ?? '';
    if (src.length > 0) {
      this.previewImageUrl = src;
    }
  }

  private openImagePreview(ref: RemoteImageRef): void {
    const src = this.imageSources.get(ref.url) ?? '';
    if (src.length > 0) {
      this.previewImageUrl = src;
    }
  }

  // ─── 交互确认（Permission / Ask User / Plan Review）──────────────────────────

  private resolveInteraction(item: PendingInteraction, decision: Record<string, Object>): void {
    AppServices.instance.interactions.resolve(this.deviceId, item.requestId, decision).catch(() => {
      promptAction.showToast({ message: '提交失败，请重试' });
    });
  }

  private requestStr(item: PendingInteraction, key: string): string {
    const v = item.raw[key];
    return typeof v === 'string' ? v : '';
  }

  private requestObj(item: PendingInteraction, key: string): Record<string, Object> {
    const v = item.raw[key];
    if (v !== undefined && typeof v === 'object' && !Array.isArray(v)) {
      return v as Record<string, Object>;
    }
    return {};
  }

  private requestBool(item: PendingInteraction, key: string): boolean {
    const v = item.raw[key];
    return v === true;
  }

  // ── Permission ──
  private permissionToolName(item: PendingInteraction): string {
    const toolName = this.requestStr(item, 'toolName');
    return toolName.length > 0 ? toolName : '工具调用';
  }

  private permissionInputSummary(item: PendingInteraction): string {
    const input = this.requestObj(item, 'input');
    if (Object.keys(input).length === 0) {
      return '';
    }
    const s = JSON.stringify(input);
    return s.length > 120 ? `${s.slice(0, 120)}…` : s;
  }

  private permissionCanAlwaysAllow(item: PendingInteraction): boolean {
    return this.requestBool(item, 'canAlwaysAllow');
  }

  private permissionDecision(item: PendingInteraction, behavior: string): Record<string, Object> {
    const d: Record<string, Object> = {};
    d['kind'] = 'permission';
    if (behavior === 'deny') {
      d['behavior'] = 'deny';
      d['reason'] = 'User denied';
    } else {
      d['behavior'] = 'allow';
      // 始终允许：session 级 permissionUpdates（request 携带时透传）。
      if (behavior === 'always-allow') {
        const suggestions = this.sessionSuggestions(item);
        if (suggestions.length > 0) {
          d['permissionUpdates'] = suggestions;
        }
      }
    }
    return d;
  }

  private sessionSuggestions(item: PendingInteraction): Object[] {
    const raw = item.raw['permissionSuggestions'];
    const out: Object[] = [];
    if (Array.isArray(raw)) {
      const list: Object[] = raw as Object[];
      for (let i = 0; i < list.length; i++) {
        const s = list[i];
        if (s !== undefined && typeof s === 'object' && !Array.isArray(s)) {
          const r = s as Record<string, Object>;
          if (r['destination'] === 'session') {
            out.push(s);
          }
        }
      }
    }
    return out;
  }

  // ── Ask User ──
  /** questions 是数组，取第一个问题（多步骤一期先逐题 resolve）。 */
  private firstQuestion(item: PendingInteraction): Record<string, Object> {
    const raw = item.raw['questions'];
    if (Array.isArray(raw)) {
      const list: Object[] = raw as Object[];
      if (list.length > 0) {
        const first = list[0];
        if (first !== undefined && typeof first === 'object' && !Array.isArray(first)) {
          return first as Record<string, Object>;
        }
      }
    }
    return {};
  }

  private askQuestion(item: PendingInteraction): string {
    const q = this.firstQuestion(item);
    const v = q['question'];
    return typeof v === 'string' ? v : '';
  }

  private askMultiSelect(item: PendingInteraction): boolean {
    const q = this.firstQuestion(item);
    return q['multiSelect'] === true;
  }

  private askOptions(item: PendingInteraction): string[] {
    const q = this.firstQuestion(item);
    const raw = q['options'];
    const out: string[] = [];
    if (Array.isArray(raw)) {
      const list: Object[] = raw as Object[];
      for (let i = 0; i < list.length; i++) {
        const o = list[i];
        if (o !== undefined && typeof o === 'object' && !Array.isArray(o)) {
          const label = (o as Record<string, Object>)['label'];
          if (typeof label === 'string' && label.length > 0) {
            out.push(label);
          }
        }
      }
    }
    return out;
  }

  private askAllowsCustom(item: PendingInteraction): boolean {
    const q = this.firstQuestion(item);
    const allows = q['allowsCustomAnswer'];
    return allows === true || allows === undefined;
  }

  private isAskSelected(item: PendingInteraction, label: string): boolean {
    const selected = this.askSelections.get(item.requestId);
    return selected !== undefined && selected.indexOf(label) >= 0;
  }

  private toggleAskSelection(item: PendingInteraction, label: string): void {
    const selected = this.askSelections.get(item.requestId) ?? [];
    const idx = selected.indexOf(label);
    let next: string[];
    if (idx >= 0) {
      next = selected.slice(0, idx).concat(selected.slice(idx + 1));
    } else {
      next = selected.concat([label]);
    }
    const map = new Map(this.askSelections);
    map.set(item.requestId, next);
    this.askSelections = map;
  }

  private askDecision(item: PendingInteraction): Record<string, Object> {
    const q = this.firstQuestion(item);
    const qv = q['question'];
    const question = typeof qv === 'string' ? qv : '';
    const selected = this.askSelections.get(item.requestId) ?? [];
    const custom = (this.askCustomInputs.get(item.requestId) ?? '').trim();
    const parts = selected.slice();
    if (custom.length > 0) {
      parts.push(custom);
    }
    // 多选按协议编码为 JSON 数组；单选直接文本。
    const answer = this.askMultiSelect(item) ? JSON.stringify(parts) : parts.join('\n');
    const answers: Record<string, Object> = {};
    answers[question] = answer;
    const d: Record<string, Object> = {};
    d['kind'] = 'ask_user_question';
    d['answers'] = answers;
    return d;
  }

  /** Skip：跳过当前问题（空答案，桌面端继续下一题/结束）。 */
  private askSkip(item: PendingInteraction): Record<string, Object> {
    const q = this.firstQuestion(item);
    const qv = q['question'];
    const question = typeof qv === 'string' ? qv : '';
    const answers: Record<string, Object> = {};
    answers[question] = '';
    const d: Record<string, Object> = {};
    d['kind'] = 'ask_user_question';
    d['answers'] = answers;
    return d;
  }

  // ── Plan Review ──
  private planText(item: PendingInteraction): string {
    return this.requestStr(item, 'plan');
  }

  private planDecision(item: PendingInteraction, approved: boolean, plan: string): Record<string, Object> {
    const d: Record<string, Object> = {};
    d['kind'] = 'plan_review';
    d['behavior'] = approved ? 'allow' : 'deny';
    if (approved) {
      d['editedPlan'] = plan;
    } else {
      d['reason'] = 'User rejected';
    }
    return d;
  }

  private doFork(clientId: string): void {
    AppServices.instance.messages.fork(this.deviceId, this.sessionId, clientId).then((newSessionId: string) => {
      if (newSessionId.length > 0) {
        promptAction.showToast({ message: '已创建新任务' });
        // 返回任务列表（列表会刷新显示新任务）。嵌入式详情留在右侧，等待列表选择状态更新。
        if (!this.isEmbedded()) router.back();
      } else {
        promptAction.showToast({ message: '分叉失败' });
      }
    }).catch(() => {
      promptAction.showToast({ message: '分叉失败' });
    });
  }

  private doRewind(clientId: string): void {
    AppServices.instance.messages.rewindCommit(this.deviceId, this.sessionId, clientId).then((newSessionId: string) => {
      if (newSessionId.length > 0) {
        promptAction.showToast({ message: '已回退' });
        if (!this.isEmbedded()) router.back();
      } else {
        promptAction.showToast({ message: '回退失败' });
      }
    }).catch(() => {
      promptAction.showToast({ message: '回退失败' });
    });
  }
}

/** 独立详情路由入口；宽屏双栏直接使用上面的可嵌入内容组件。 */
@Entry
@Component
struct TaskPage {
  build() {
    Column() {
      TaskPageContent()
    }
    .width('100%')
    .height('100%')
  }
}

/** 待发送图片（上传状态机：uploading → ready / failed）。 */
class ComposerImage {
  uri: string = '';
  name: string = '';
  status: string = 'uploading';
  ref: RemoteImageRef | null = null;
  /** 用户已移除；异步上传若稍后成功，立即回收中转对象。 */
  removed: boolean = false;
}
