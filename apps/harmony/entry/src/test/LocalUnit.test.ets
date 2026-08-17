import { describe, it, expect } from '@ohos/hypium';
import {
  parseMessage,
  parseSession,
  readAny,
  readBool,
  readNum,
  readObj,
  readStr,
  recordOrEmpty,
  DeviceView,
  RemoteMessage,
  RemoteSession,
  sortMessagesAsc,
} from '../main/ets/core/tasks/TaskModels';
import {
  RemoteImageRef,
  composerAttachmentRenderKey,
  createComposerAttachmentLocalId,
} from '../main/ets/core/attachments/AttachmentModels';
import {
  isRetryablePresignStatus,
  isUploadRevisionCurrent,
  uploadExtForName,
} from '../main/ets/core/attachments/AttachmentUpload';
import { renameForImagePreprocess } from '../main/ets/core/attachments/ImagePreprocess';
import { parseGoalModeState } from '../main/ets/core/goals/GoalModels';
import {
  shouldAutoCollapseUserMessage,
  collapsedUserMessageLineLimit,
  toolResultHasError,
  buildRenderItems,
  RenderToolGroupItem,
  RenderToolItem,
  RenderToolMediaItem,
  RenderTodoCardItem,
  RenderTodoItem,
  RenderAgentTaskItem,
  RenderSubagentGroupItem,
  RenderThinkingItem,
  RenderWorkGroupItem,
  RenderMessageItem,
  todoCardContentSignature,
  todoCardIndexAtRankFromTail,
  todoCardRankFromTail,
  findTodoPlanInsertions,
  latestTaskPlanWindowResolved,
  applyCodexPlanSnapshotOnDone,
  markCodexPlanTurnFailed,
  planRowSealed,
  planRowTurnFailed,
  parseThinkingPresentation,
  shouldSplitToolGroup,
  turnFinalAssistantIds,
} from '../main/ets/core/messages/MessageRender';
import {
  workExplorationSummary,
  workGroupHasHiddenRows,
  workPreviewRows,
} from '../main/ets/core/messages/WorkGroupPresentation';
import {
  AgentTaskUpdate,
  deriveAgentTaskStatus,
} from '../main/ets/core/messages/AgentTaskStore';
import {
  findMessageSearchHits,
  messageSearchPagingPresentation,
  nextMessageSearchIndex,
  reconcileMessageSearchIndex,
} from '../main/ets/core/messages/MessageSearch';
import { projectToolUseActions } from '../main/ets/core/messages/ToolUsePresentation';
import {
  AuthoritativeEmptyDeferrals,
  buildAgentUserContent,
  buildPersistedUserContent,
  MessageStore,
  TEXT_DELTA_BATCH_INTERVAL_MS,
  preferIncomingCreatedMessage,
  reconcileDeferredAuthoritativeEmptyMessages,
  shouldDeferAuthoritativeEmptyWindow,
  shouldPreserveCachedMessagesForAuthoritativeEmpty,
} from '../main/ets/core/messages/MessageStore';
import {
  CachedSessionMessages,
  MAX_CACHED_MESSAGE_SESSIONS,
  MAX_CACHED_SESSION_MESSAGES,
  normalizeSessionCacheMessages,
  parseSessionMessageSnapshot,
  serializeSessionMessageSnapshot,
} from '../main/ets/core/messages/SessionMessageCacheStore';
import {
  formatSessionActivityElapsed,
  sessionActivityElapsedMs,
} from '../main/ets/core/messages/SessionActivityPresentation';
import {
  compareTaskListLabels,
  compareTaskSessionsForList,
  resolveTaskRightStatus,
  taskActivityAt,
  taskDisplayTitle,
  taskIsAutomation,
  taskListCategory,
  taskListEntryPresentationState,
  taskPreviewText,
  taskProjectKey,
  taskProjectName,
  taskRelativeTime,
  taskVisibleInTaskList,
  taskVisibleOnHome,
} from '../main/ets/pages/TaskListPresentation';
import {
  parseTaskListPreferences,
  serializeTaskListPreferences,
  TaskListPreferences,
} from '../main/ets/core/tasks/TaskListPreferenceStore';
import {
  consumeTaskSplitRouteSelection,
  handoffTaskSplitRouteSelection,
  isWideTaskLayout,
  TASK_FOLD_STATUS_EXPANDED,
  TASK_FOLD_STATUS_FOLDED,
  TASK_FOLD_STATUS_HALF_FOLDED,
  taskDetailKeyboardInset,
  taskDetailPaneWidth,
  taskListPaneWidth,
  taskSplitRatioForDrag,
  TASK_SPLIT_DEFAULT_RATIO,
} from '../main/ets/pages/TaskSplitLayout';

import {
  groupInlineTokens,
  parseMarkdown,
  tokenizeInline,
} from '../main/ets/core/messages/MarkdownParser';
import { tokenizeThinkingText } from '../main/ets/core/messages/ThinkingTextParser';
import { buildMarkdownTableColumnWidths } from '../main/ets/core/messages/MarkdownTableLayout';
import {
  appendAutoResumePendingMessage,
  deriveAutoResumePresentation,
  summarizeAutoResumeError,
} from '../main/ets/core/messages/AutoResumePresentation';
import {
  InputQueueStore,
  pendingQueueBubbleRenderKey,
  parseInputProjection,
  parseQueuedInputItem,
} from '../main/ets/core/messages/InputQueueStore';
import { shouldApplyComposerDraftRead } from '../main/ets/core/messages/ComposerDraftStore';
import { SerializedComposerDocument } from '../main/ets/core/messages/ComposerDocument';
import {
  extendCoverageEarlier,
  MessageWindowCoverage,
  reconcileLatestMessageWindow,
} from '../main/ets/core/messages/HistoryWindowCoverage';
import {
  historyRetryLimits,
  isPayloadTooLargeError,
  shouldInferOlderMessagesFromCount,
  shouldKeepOlderMessagesAffordance,
} from '../main/ets/core/messages/MessagePaging';
import {
  computeReconnectDelayMs,
  DlChannels,
  Envelope,
  expandMakerEventBatchPayload,
} from '../main/ets/core/device-link/DlProtocol';
import {
  assertInvokeSucceeded,
  DlError,
  isSafeUnsentDlError,
} from '../main/ets/core/device-link/DlClient';
import {
  parseChoiceOptions,
  parseModelOptions,
  parseModelVisibilityOverrides,
  parseProviderModelOptions,
  reconcileModelEffort,
  selectedPermissionModeLabel,
} from '../main/ets/core/ComposerCatalog';
import { TaskStore } from '../main/ets/core/tasks/TaskStore';
import {
  TASK_LIST_RECONCILE_INTERVAL_MS,
  TaskListReconcileBackoff,
} from '../main/ets/core/tasks/TaskListReconcilePolicy';
import {
  CachedTaskListDevice,
  parseTaskListSnapshot,
  serializeTaskListSnapshot,
} from '../main/ets/core/tasks/TaskListSnapshotStore';
import {
  firstVisibleMessageRenderIndex,
  FOLLOW_LATEST_RETRY_DELAYS,
  INITIAL_HISTORY_AUTOFILL_PAGES,
  messageListBottomIndex,
  messageListItemPresentationState,
  messageListRenderNodeKey,
  shouldAutoLoadEarlier,
} from '../main/ets/pages/TaskScrollState';
import {
  decideNewSessionRecoveryAction,
  exactNewSessionRecord,
  isTransientNewSessionError,
  shouldBlockNewSessionRemoteOperation,
} from '../main/ets/core/tasks/NewSessionCreationStore';
import {
  askOptionPresentations,
  buildPlanReviewEvidence,
  buildPermissionDecision,
  isHighRiskShellCommand,
  permissionCanAlwaysAllow,
  permissionRiskSummary,
  pendingInteractionsBlockRemoteComposer,
  sessionScopedPermissionSuggestions,
  sortPendingInteractions,
} from '../main/ets/core/interactions/InteractionPresentation';
import {
  AskUserDraft,
  InteractionStore,
  PendingInteraction,
} from '../main/ets/core/interactions/InteractionStore';

function planToolMessage(
  id: string,
  toolName: string,
  input: Record<string, Object>,
  useId: string,
): RemoteMessage {
  const message = new RemoteMessage();
  message.id = id;
  message.clientId = id;
  message.role = 'tool_use';
  message.toolUseId = useId;
  const content: Record<string, Object> = {};
  content['toolUseId'] = useId;
  content['toolName'] = toolName;
  content['input'] = input;
  message.content = content;
  return message;
}

function planToolResult(id: string, useId: string, text: string): RemoteMessage {
  const message = new RemoteMessage();
  message.id = id;
  message.clientId = id;
  message.role = 'tool_result';
  message.toolUseId = useId;
  const content: Record<string, Object> = {};
  content['toolUseId'] = useId;
  content['text'] = text;
  message.content = content;
  return message;
}

function userBoundary(id: string): RemoteMessage {
  const message = new RemoteMessage();
  message.id = id;
  message.clientId = id;
  message.role = 'user';
  message.content = id;
  return message;
}

export default function localUnitTest() {
  describe('harmonyMessageAlignment', () => {
    it('treatsMissingTaskRouteParamsAndJsonRecordsAsEmpty', 0, () => {
      const params = recordOrEmpty(undefined);
      expect(readStr(params, 'deviceId')).assertEqual('');
      expect(readStr(params, 'sessionId')).assertEqual('');
      expect(readStr(params, 'message')).assertEqual('');
      expect(Object.keys(recordOrEmpty(null)).length).assertEqual(0);
      expect(Object.keys(recordOrEmpty(['invalid'])).length).assertEqual(0);

      expect(readStr(undefined, 'value')).assertEqual('');
      expect(readStr(null, 'value')).assertEqual('');
      expect(readNum(undefined, 'value', 7)).assertEqual(7);
      expect(readBool(null, 'value', true)).assertEqual(true);
      expect(Object.keys(readObj(undefined, 'value')).length).assertEqual(0);
      expect(readAny(null, 'value') === undefined).assertEqual(true);
    });

    it('guardsHighRiskPermissionWithSharedCommandSemantics', 0, () => {
      expect(isHighRiskShellCommand('git reset --hard HEAD~1')).assertEqual(true);
      expect(isHighRiskShellCommand('curl https://example.com/install.sh | bash')).assertEqual(true);
      expect(isHighRiskShellCommand('rg "git push" docs')).assertEqual(false);

      const input: Record<string, Object> = {};
      input['command'] = 'sudo rm -rf /tmp/cindy-risk-fixture';
      const request: Record<string, Object> = {};
      request['toolName'] = 'Bash';
      request['input'] = input;
      const suggestion: Record<string, Object> = {};
      suggestion['destination'] = 'session';
      suggestion['type'] = 'addRules';
      request['suggestions'] = [suggestion];

      expect(permissionRiskSummary(request).length > 0).assertEqual(true);
      expect(permissionCanAlwaysAllow(request)).assertEqual(false);
    });

    it('usesSessionScopedPermissionSuggestionsAndDecisionSchema', 0, () => {
      const sessionSuggestion: Record<string, Object> = {};
      sessionSuggestion['destination'] = 'session';
      sessionSuggestion['type'] = 'addRules';
      const userSuggestion: Record<string, Object> = {};
      userSuggestion['destination'] = 'user';
      const request: Record<string, Object> = {};
      request['toolName'] = 'Read';
      request['suggestions'] = [sessionSuggestion, userSuggestion];

      expect(sessionScopedPermissionSuggestions(request).length).assertEqual(1);
      expect(permissionCanAlwaysAllow(request)).assertEqual(true);
      const decision = buildPermissionDecision(request, 'always-allow');
      expect(decision['behavior']).assertEqual('allow');
      expect((decision['permissionUpdates'] as Object[]).length).assertEqual(1);
    });

    it('keepsInteractionPriorityAskDescriptionsAndPlanEvidence', 0, () => {
      const question: Record<string, Object> = {};
      const option: Record<string, Object> = {};
      option['label'] = '保守方案';
      option['description'] = '改动更小，风险更低';
      question['options'] = [option];
      const options = askOptionPresentations(question);
      expect(options.length).assertEqual(1);
      expect(options[0].description).assertEqual('改动更小，风险更低');

      const ask = new PendingInteraction();
      ask.requestId = 'ask';
      ask.kind = 'ask_user_question';
      const permission = new PendingInteraction();
      permission.requestId = 'permission';
      permission.kind = 'permission';
      const plan = new PendingInteraction();
      plan.requestId = 'plan';
      plan.kind = 'plan_review';
      const sorted = sortPendingInteractions([ask, permission, plan]);
      expect(sorted[0].requestId).assertEqual('plan');
      expect(sorted[1].requestId).assertEqual('permission');
      expect(sorted[2].requestId).assertEqual('ask');

      const evidence = buildPlanReviewEvidence([
        '# 总览',
        '```md',
        '## 围栏内忽略',
        '```',
        '## 实现',
        '### 验证',
        '# 交付',
      ].join('\n'), '/repo/docs/plan.md', 3);
      expect(evidence.fileName).assertEqual('plan.md');
      expect(evidence.outlineTotalCount).assertEqual(4);
      expect(evidence.outlineItems.length).assertEqual(3);
      expect(evidence.outlineOverflowCount).assertEqual(1);
      expect(evidence.outlineItems[1].title).assertEqual('实现');
    });

    it('publishesAskDraftSelectionsAsClonedSnapshots', 0, () => {
      const store = new InteractionStore();
      let changed = 0;
      const unsubscribe = store.onChanged(() => {
        changed += 1;
      });
      const draft = new AskUserDraft();
      draft.selectedLabels = ['最近优先'];
      draft.answers.set('请选择排序方式', '最近优先');
      store.saveAskDraft('ask-1', draft);

      expect(changed).assertEqual(1);
      const snapshot = store.readAskDraft('ask-1');
      expect(snapshot !== null).assertEqual(true);
      expect(snapshot?.selectedLabels[0]).assertEqual('最近优先');
      snapshot?.selectedLabels.push('字母排序');
      expect(store.readAskDraft('ask-1')?.selectedLabels.length).assertEqual(1);
      unsubscribe();
    });

    it('blocksComposerOnlyForLocallyResolvablePendingInteractions', 0, () => {
      const plugin = new PendingInteraction();
      plugin.requestId = 'plugin';
      plugin.kind = 'plugin_setup';
      const issue = new PendingInteraction();
      issue.requestId = 'issue';
      issue.kind = 'issue_confirm';
      const unknown = new PendingInteraction();
      unknown.requestId = 'unknown';
      unknown.kind = 'future_kind';
      const permission = new PendingInteraction();
      permission.requestId = 'permission';
      permission.kind = 'permission';
      const ask = new PendingInteraction();
      ask.requestId = 'ask';
      ask.kind = 'ask_user_question';
      const plan = new PendingInteraction();
      plan.requestId = 'plan';
      plan.kind = 'plan_review';

      expect(pendingInteractionsBlockRemoteComposer([])).assertEqual(false);
      expect(pendingInteractionsBlockRemoteComposer([plugin, issue, unknown])).assertEqual(false);
      expect(pendingInteractionsBlockRemoteComposer([plugin, permission])).assertEqual(true);
      expect(pendingInteractionsBlockRemoteComposer([ask])).assertEqual(true);
      expect(pendingInteractionsBlockRemoteComposer([plan])).assertEqual(true);
    });

    it('classifiesAttachmentRetriesAndKeepsTranscodedMetadataConsistent', 0, () => {
      expect(isRetryablePresignStatus(408)).assertEqual(true);
      expect(isRetryablePresignStatus(429)).assertEqual(true);
      expect(isRetryablePresignStatus(503)).assertEqual(true);
      expect(isRetryablePresignStatus(400)).assertEqual(false);
      expect(isRetryablePresignStatus(404)).assertEqual(false);

      const pngName = renameForImagePreprocess('camera.webp', 'png');
      expect(pngName).assertEqual('camera.png');
      expect(uploadExtForName(pngName)).assertEqual('png');
      expect(renameForImagePreprocess('capture', 'jpeg')).assertEqual('capture.jpg');

      expect(isUploadRevisionCurrent(2, 2, false, true)).assertEqual(true);
      expect(isUploadRevisionCurrent(3, 2, false, true)).assertEqual(false);
      expect(isUploadRevisionCurrent(2, 2, true, true)).assertEqual(false);
      expect(isUploadRevisionCurrent(2, 2, false, false)).assertEqual(false);

      const uploadingKey = composerAttachmentRenderKey('photo://1', 'uploading', 1);
      expect(composerAttachmentRenderKey('photo://1', 'ready', 1) === uploadingKey).assertEqual(false);
      expect(composerAttachmentRenderKey('photo://1', 'failed', 1) === uploadingKey).assertEqual(false);
      expect(composerAttachmentRenderKey('photo://1', 'uploading', 2) === uploadingKey).assertEqual(false);

      const firstLocalId = createComposerAttachmentLocalId();
      const secondLocalId = createComposerAttachmentLocalId();
      expect(firstLocalId.length > 0).assertEqual(true);
      expect(secondLocalId === firstLocalId).assertEqual(false);
      expect(composerAttachmentRenderKey(secondLocalId, 'ready', 1) ===
        composerAttachmentRenderKey(firstLocalId, 'ready', 1)).assertEqual(false);
    });

    it('recognizesSchedulerAutomationOrigin', 0, () => {
      const origin: Record<string, Object> = {};
      origin['kind'] = 'scheduler';
      origin['scheduleId'] = 'schedule-1';
      const agentMeta: Record<string, Object> = {};
      agentMeta['origin'] = origin;
      const raw: Record<string, Object> = {};
      raw['id'] = 'message-1';
      raw['role'] = 'user';
      raw['content'] = 'scheduled prompt';
      raw['agentMeta'] = agentMeta;

      expect(parseMessage(raw).automationOrigin).assertEqual(true);
    });

    it('rejectsIncompleteAutomationOrigin', 0, () => {
      const origin: Record<string, Object> = {};
      origin['kind'] = 'scheduler';
      const agentMeta: Record<string, Object> = {};
      agentMeta['origin'] = origin;
      const raw: Record<string, Object> = {};
      raw['id'] = 'message-2';
      raw['role'] = 'user';
      raw['content'] = 'not a valid scheduler message';
      raw['agentMeta'] = agentMeta;

      expect(parseMessage(raw).automationOrigin).assertEqual(false);
    });

    it('keepsSentTextAndImagesInAgentAndTranscriptShapes', 0, () => {
      const image = new RemoteImageRef();
      image.url = 'cindy-oss-attach://m/test';
      image.originalName = 'screen.png';
      image.mimeType = 'image/png';
      image.size = 42;
      image.sha256 = 'abc';

      const agentContent = buildAgentUserContent('请检查截图', [image]) as Object[];
      const imageBlock = agentContent[1] as Record<string, Object>;
      expect(agentContent.length).assertEqual(2);
      expect(imageBlock['type']).assertEqual('image');
      expect(imageBlock['path']).assertEqual(image.url);

      const persisted = JSON.parse(buildPersistedUserContent('请检查截图', [image])) as Record<string, Object>;
      expect(persisted['text']).assertEqual('请检查截图');
      const persistedImages = persisted['images'] as Object[];
      const persistedImage = persistedImages[0] as Record<string, Object>;
      expect(persistedImage['url']).assertEqual(image.url);
      expect(persistedImage['originalName']).assertEqual('screen.png');
    });

    it('usesMobileLongMessageThresholdsAndLineLimits', 0, () => {
      const fiveLines = 'one\ntwo\nthree\nfour\nfive';
      expect(shouldAutoCollapseUserMessage(fiveLines, true)).assertEqual(true);
      expect(shouldAutoCollapseUserMessage(fiveLines, false)).assertEqual(false);
      expect(collapsedUserMessageLineLimit(true)).assertEqual(3);
      expect(collapsedUserMessageLineLimit(false)).assertEqual(10);
    });

    it('distinguishesSettledToolErrorsFromNormalOutput', 0, () => {
      const failed = new RemoteMessage();
      failed.role = 'tool_result';
      const failedContent: Record<string, Object> = {};
      failedContent['isError'] = true;
      failedContent['text'] = 'request failed';
      failed.content = failedContent;

      const plainFailure = new RemoteMessage();
      plainFailure.role = 'tool_result';
      plainFailure.content = 'Error: connection refused';

      const normal = new RemoteMessage();
      normal.role = 'tool_result';
      normal.content = 'Read docs/error-handling.md successfully';

      expect(toolResultHasError(failed)).assertEqual(true);
      expect(toolResultHasError(plainFailure, 'Bash')).assertEqual(true);
      expect(toolResultHasError(normal)).assertEqual(false);
    });

    it('keepsContentToolErrorsAnchoredAndPreservesFullToolResults', 0, () => {
      const contentMention = new RemoteMessage();
      contentMention.role = 'tool_result';
      contentMention.content = 'docs/error-handling.md\nThis document explains failure recovery.';
      expect(toolResultHasError(contentMention, 'Read')).assertEqual(false);

      const contentFailure = new RemoteMessage();
      contentFailure.role = 'tool_result';
      contentFailure.content = 'Error: ENOENT /repo/missing.txt';
      expect(toolResultHasError(contentFailure, 'Read')).assertEqual(true);

      expect(shouldSplitToolGroup(
        '2026-08-09T00:00:00.000Z', '2026-08-09T00:31:00.000Z')).assertEqual(true);
      expect(shouldSplitToolGroup(
        '2026-08-09T00:00:00.000Z', '2026-08-09T00:29:00.000Z')).assertEqual(false);
    });

    it('parsesSafeMarkdownImagesAndLeavesScriptSchemesAsText', 0, () => {
      const tokens = tokenizeInline('before ![chart](xdt-image://art/chart.png) <img src="cindy-media://blobs/photo.png" alt="photo"> after');
      let imageCount = 0;
      for (let i = 0; i < tokens.length; i++) {
        if (tokens[i].kind === 'image') imageCount += 1;
      }
      expect(imageCount).assertEqual(2);

      const blocked = tokenizeInline('![bad](javascript:alert(1)) and <img src="vbscript:evil">');
      let blockedImageCount = 0;
      for (let i = 0; i < blocked.length; i++) {
        if (blocked[i].kind === 'image') blockedImageCount += 1;
      }
      expect(blockedImageCount).assertEqual(0);
    });

    it('preservesMarkdownFormattingAroundImagesAndTaskLists', 0, () => {
      const tokens = tokenizeInline(
        '**bold** *em* ~~gone~~ $x^2$ ![chart](xdt-image://art/chart.png) `code`');
      expect(tokens[0].kind).assertEqual('strong');
      expect(tokens[2].kind).assertEqual('emphasis');
      expect(tokens[4].kind).assertEqual('strikethrough');
      expect(tokens[6].kind).assertEqual('math');
      expect(tokens[8].kind).assertEqual('image');
      expect(tokens[10].kind).assertEqual('code');
      const groups = groupInlineTokens(tokens);
      expect(groups.length).assertEqual(3);
      expect(groups[0].tokens[0].kind).assertEqual('strong');
      expect(groups[1].image?.kind).assertEqual('image');
      expect(groups[2].tokens[0].kind).assertEqual('text');

      const blocks = parseMarkdown('## **计划** ##\n\n- [x] 已完成\n- [ ] 待处理');
      expect(blocks[0].type).assertEqual('heading');
      expect(blocks[0].text).assertEqual('**计划**');
      expect(blocks[0].inlineTokens[0].kind).assertEqual('strong');
      expect(blocks[1].itemChecked[0]).assertEqual(1);
      expect(blocks[1].itemChecked[1]).assertEqual(0);

      const currency = tokenizeInline('$5 和 $10；`$HOME`');
      let mathCount = 0;
      for (let i = 0; i < currency.length; i++) {
        if (currency[i].kind === 'math') mathCount += 1;
      }
      expect(mathCount).assertEqual(0);
    });

    it('parsesOnlyCompactThinkingStrongAndCodeMarkers', 0, () => {
      const tokens = tokenizeThinkingText('**Reviewing** `TaskPage.ets` and ``a ` b``');
      expect(tokens.length).assertEqual(5);
      expect(tokens[0].kind).assertEqual('strong');
      expect(tokens[0].value).assertEqual('Reviewing');
      expect(tokens[1].kind).assertEqual('text');
      expect(tokens[2].kind).assertEqual('code');
      expect(tokens[2].value).assertEqual('TaskPage.ets');
      expect(tokens[4].kind).assertEqual('code');
      expect(tokens[4].value).assertEqual('a ` b');

      const literal = tokenizeThinkingText('\\**escaped** **unclosed `also unclosed');
      expect(literal.length).assertEqual(1);
      expect(literal[0].kind).assertEqual('text');
      expect(literal[0].value).assertEqual('\\**escaped** **unclosed `also unclosed');

      const unsupported = tokenizeThinkingText('*emphasis* [link](https://example.com)');
      expect(unsupported.length).assertEqual(1);
      expect(unsupported[0].kind).assertEqual('text');
    });

    it('searchesNestedWorkAndPreservesTheSelectedHitAcrossPrepend', 0, () => {
      const thinking = new RenderThinkingItem();
      thinking.type = 'thinking';
      thinking.key = 'thinking-leaf';
      thinking.body = 'deep needle';
      const work = new RenderWorkGroupItem();
      work.type = 'work_group';
      work.key = 'work-inner';
      work.children = [thinking];
      const subagent = new RenderSubagentGroupItem();
      subagent.type = 'subagent_group';
      subagent.key = 'subagent-top';
      subagent.children = [work];

      const task = new RenderAgentTaskItem();
      task.type = 'agent_task';
      task.key = 'agent-task-top';
      task.update = new AgentTaskUpdate();
      task.update.taskId = 'task-source';
      task.update.description = 'second needle';

      const firstHits = findMessageSearchHits([subagent, task], 'needle');
      expect(firstHits.length).assertEqual(2);
      expect(firstHits[0].itemKey).assertEqual('subagent-top');
      expect(firstHits[0].sourceKey).assertEqual('thinking-leaf');
      expect(firstHits[1].sourceKey).assertEqual('task-source');

      const prepended = new RenderThinkingItem();
      prepended.type = 'thinking';
      prepended.key = 'older-source';
      prepended.body = 'older needle';
      const afterPrepend = findMessageSearchHits([prepended, subagent, task], 'needle');
      expect(reconcileMessageSearchIndex(
        afterPrepend, 1, firstHits[1].sourceKey)).assertEqual(2);
      expect(nextMessageSearchIndex(afterPrepend.length, 0, -1)).assertEqual(2);

      expect(messageSearchPagingPresentation('needle', true, false, 0).label)
        .assertEqual('加载更早继续搜索');
      expect(messageSearchPagingPresentation('needle', true, true, 1).enabled)
        .assertEqual(false);
    });

    it('tracksProjectionCapabilityAndAuthorityFences', 0, () => {
      expect(parseInputProjection(undefined, 's1').continuationInFlightProjectionCapability)
        .assertEqual('unknown');
      const legacy: Record<string, Object> = {};
      legacy['sessionId'] = 's1';
      expect(parseInputProjection(legacy, 's1').continuationInFlightProjectionCapability)
        .assertEqual('legacy');
      const supported: Record<string, Object> = {};
      supported['sessionId'] = 's1';
      supported['continuationTurnClientId'] = JSON.parse('null') as Object;
      expect(parseInputProjection(supported, 's1').continuationInFlightProjectionCapability)
        .assertEqual('supported');

      const store = new InputQueueStore();
      const beforePush = store.captureAuthorityEpoch('s1');
      const owner: Record<string, Object> = {};
      owner['sessionId'] = 's1';
      owner['continuationTurnClientId'] = 'continuation-1';
      store.handleProjectionPush(owner);
      expect(store.captureAuthorityEpoch('s1') > beforePush).assertEqual(true);
      store.noteTurnTerminal('s1');
      expect(store.getProjection('s1').continuationTurnClientId).assertEqual('');
      const beforeClear = store.captureAuthorityEpoch('s1');
      store.clearSession('s1');
      expect(store.captureAuthorityEpoch('s1') > beforeClear).assertEqual(true);
      const oldOther = store.captureAuthorityEpoch('other');
      store.clearAll();
      expect(store.captureAuthorityEpoch('other') > oldOther).assertEqual(true);

      const beforeStop = store.captureAuthorityEpoch('stop-session');
      store.stop('device-1', 'stop-session').catch(() => {});
      expect(store.captureAuthorityEpoch('stop-session') > beforeStop).assertEqual(true);
    });

    it('acceptsMobileCompatibleEmptyQueuedInputFields', 0, () => {
      const chat: Record<string, Object> = {};
      chat['role'] = 'user';
      chat['createdAt'] = '2026-08-01T00:00:00.000Z';
      const raw: Record<string, Object> = {};
      raw['clientId'] = 'empty-message';
      raw['text'] = '';
      raw['persistedContent'] = '';
      raw['model'] = '';
      raw['workingDir'] = '';
      const emptyCreateOpts: Record<string, Object> = {};
      raw['createOpts'] = emptyCreateOpts;
      raw['chatMessage'] = chat;
      expect(parseQueuedInputItem(raw) !== null).assertEqual(true);
    });

    it('invalidatesProjectionWhenOwningDeviceBecomesUnavailable', 0, () => {
      const store = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'owned-session';
      session.model = 'model';
      session.permissionMode = 'ask';
      store.seedOptimisticText('device-1', session, 'hello', [], 'stable-client');
      const before = store.captureAuthorityEpoch(session.id);
      expect(store.getProjection(session.id).pendingQueue.length).assertEqual(1);
      store.invalidateDevice('device-1');
      expect(store.getProjection(session.id).pendingQueue.length).assertEqual(0);
      expect(store.captureAuthorityEpoch(session.id) > before).assertEqual(true);
    });

    it('doesNotDuplicateOptimisticFirstMessageWithStableClientId', 0, () => {
      const store = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'optimistic-session';
      session.model = 'model';
      session.permissionMode = 'ask';
      store.seedOptimisticText('device-1', session, 'first', [], 'stable-client');
      store.seedOptimisticText('device-1', session, 'first', [], 'stable-client');
      const queue = store.getProjection(session.id).pendingQueue;
      expect(queue.length).assertEqual(1);
      expect(queue[0].clientId).assertEqual('stable-client');
    });

    it('rebuildsQueueBubblePresentationAfterAckAndRenumbersAfterDrain', 0, () => {
      const store = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'queue-render-session';
      session.model = 'model';
      session.permissionMode = 'ask';
      store.seedOptimisticText('device-1', session, 'one', [], 'queue-1');
      store.seedOptimisticText('device-1', session, 'two', [], 'queue-2');
      store.seedOptimisticText('device-1', session, 'three', [], 'queue-3');
      const rawQueue = store.getProjection(session.id).pendingQueue
        .map((item) => item.raw as Object);

      const sendingProjection: Record<string, Object> = {};
      sendingProjection['sessionId'] = session.id;
      sendingProjection['pendingQueue'] = rawQueue;
      sendingProjection['steeringQueueClientIds'] = ['queue-1'];
      store.handleProjectionPush(sendingProjection);
      const sendingBubble = store.getBubbles(session.id)[0];
      const sendingKey = pendingQueueBubbleRenderKey(sendingBubble);
      expect(sendingBubble.phase).assertEqual('sending');

      const acknowledgedProjection: Record<string, Object> = {};
      acknowledgedProjection['sessionId'] = session.id;
      acknowledgedProjection['pendingQueue'] = rawQueue;
      acknowledgedProjection['steeringQueueClientIds'] = [];
      store.handleProjectionPush(acknowledgedProjection);
      const queuedBubble = store.getBubbles(session.id)[0];
      expect(queuedBubble.phase).assertEqual('queued');
      expect(pendingQueueBubbleRenderKey(queuedBubble) === sendingKey).assertEqual(false);

      const drainedProjection: Record<string, Object> = {};
      drainedProjection['sessionId'] = session.id;
      drainedProjection['pendingQueue'] = [rawQueue[1], rawQueue[2]];
      store.handleProjectionPush(drainedProjection);
      const afterDrain = store.getBubbles(session.id);
      const second = afterDrain.find((item) => item.clientId === 'queue-2');
      const third = afterDrain.find((item) => item.clientId === 'queue-3');
      expect(second?.queueIndex).assertEqual(1);
      expect(third?.queueIndex).assertEqual(2);
    });

    it('doesNotApplyAsyncComposerDraftAfterUserStartsTyping', 0, () => {
      expect(shouldApplyComposerDraftRead('session-1', 'session-1', 3, 3, 7, 7, false))
        .assertEqual(true);
      expect(shouldApplyComposerDraftRead('session-1', 'session-1', 3, 3, 7, 8, false))
        .assertEqual(false);
      expect(shouldApplyComposerDraftRead('session-1', 'session-2', 3, 3, 7, 7, false))
        .assertEqual(false);
    });

    it('keepsCreationFollowUpsInLocalFifoUntilExplicitHandoff', 0, () => {
      const store = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'creating-session';
      session.model = 'model';
      session.permissionMode = 'ask';
      const first = new SerializedComposerDocument();
      first.text = 'follow-up one';
      const second = new SerializedComposerDocument();
      second.text = 'follow-up two';
      store.deferDocument('device-1', session, first, [], []);
      store.deferDocument('device-1', session, second, [], []);

      const bubbles = store.getBubbles(session.id);
      expect(bubbles.length).assertEqual(2);
      expect(store.shouldDeferNewInput(session.id)).assertEqual(true);
      expect(bubbles[0].text).assertEqual('follow-up one');
      expect(bubbles[0].phase).assertEqual('waiting');
      expect(bubbles[1].text).assertEqual('follow-up two');
      const recovered = store.takeDeferred(session.id);
      expect(recovered.length).assertEqual(2);
      expect(recovered[0].text).assertEqual('follow-up one');
      expect(recovered[1].text).assertEqual('follow-up two');
      expect(store.getBubbles(session.id).length).assertEqual(0);
      expect(store.shouldDeferNewInput(session.id)).assertEqual(false);
    });

    it('clearsSettlingFailureStateWhenDeliveryResolvesOrProjectionDrops', 0, () => {
      const makeSettling = (clientId: string): InputQueueStore => {
        const store = new InputQueueStore();
        const session = new RemoteSession();
        session.id = 'settling-session';
        session.model = 'model';
        session.permissionMode = 'ask';
        store.seedOptimisticText('device-1', session, 'first', [], clientId);
        store.markLocalFailure(session.id, clientId, 'not confirmed');
        const empty: Record<string, Object> = {};
        empty['sessionId'] = session.id;
        empty['pendingQueue'] = [];
        store.handleProjectionPush(empty);
        return store;
      };

      const resolved = makeSettling('settling-resolved');
      expect(resolved.getBubbles('settling-session').length).assertEqual(1);
      resolved.resolveAppliedDelivery('settling-session', 'settling-resolved');
      expect(resolved.getBubbles('settling-session').length).assertEqual(0);
      expect(resolved.isLocallyFailed('settling-resolved')).assertEqual(false);

      const discarded = makeSettling('settling-discarded');
      discarded.discardProjection('settling-session');
      expect(discarded.getBubbles('settling-session').length).assertEqual(0);
      expect(discarded.isLocallyFailed('settling-discarded')).assertEqual(false);
    });

    it('restoresOnlyOneFailedBubbleWhenEmptyProjectionMovedItemToSettling', 0, () => {
      const store = new InputQueueStore();
      const session = new RemoteSession();
      session.id = 'enqueue-failure-session';
      session.model = 'model';
      session.permissionMode = 'ask';
      store.seedOptimisticText('device-1', session, 'send once', [], 'failed-client');
      const empty: Record<string, Object> = {};
      empty['sessionId'] = session.id;
      empty['pendingQueue'] = [];
      store.handleProjectionPush(empty);
      store.markLocalFailure(session.id, 'failed-client', 'relay unavailable');

      const bubbles = store.getBubbles(session.id);
      expect(bubbles.length).assertEqual(1);
      expect(bubbles[0].clientId).assertEqual('failed-client');
      expect(bubbles[0].phase).assertEqual('failed');
      expect(bubbles[0].errorText).assertEqual('relay unavailable');
    });

    it('keepsTodoCardAndStepKeysStableAcrossPlanStatusUpdates', 0, () => {
      const user = new RemoteMessage();
      user.id = 'plan-user-row';
      user.clientId = 'plan-user-client';
      user.role = 'user';
      user.content = '按步骤执行';

      const planMessage = (id: string, firstStatus: string): RemoteMessage => {
        const message = new RemoteMessage();
        message.id = id;
        message.role = 'tool_use';
        const first: Record<string, Object> = {};
        first['step'] = '读取项目';
        first['status'] = firstStatus;
        const second: Record<string, Object> = {};
        second['step'] = '完成修改';
        second['status'] = firstStatus === 'completed' ? 'in_progress' : 'pending';
        const input: Record<string, Object> = {};
        input['plan'] = [first, second];
        const content: Record<string, Object> = {};
        content['toolUseId'] = `${id}-use`;
        content['toolName'] = 'update_plan';
        content['input'] = input;
        message.content = content;
        return message;
      };

      const firstItems = buildRenderItems([user, planMessage('plan-1', 'in_progress')], true);
      const updatedItems = buildRenderItems([
        user,
        planMessage('plan-1', 'in_progress'),
        planMessage('plan-2', 'completed'),
      ], true);
      const firstCard = firstItems.find((item) => item.type === 'todo') as RenderTodoCardItem;
      const updatedCard = updatedItems.find((item) => item.type === 'todo') as RenderTodoCardItem;
      expect(firstCard.key).assertEqual('todo-plan-1');
      expect(updatedCard.key).assertEqual(firstCard.key);
      expect(updatedCard.todos.length).assertEqual(2);
      expect(updatedCard.todos[0].seq).assertEqual(0);
      expect(updatedCard.todos[1].seq).assertEqual(1);
    });

    it('keepsOnlyTheCurrentTurnTodoCardActiveWhileStreaming', 0, () => {
      const planMessage = (id: string): RemoteMessage => {
        const message = new RemoteMessage();
        message.id = id;
        message.role = 'tool_use';
        const step: Record<string, Object> = {};
        step['step'] = '执行步骤';
        step['status'] = 'in_progress';
        const input: Record<string, Object> = {};
        input['plan'] = [step];
        const content: Record<string, Object> = {};
        content['toolUseId'] = `${id}-use`;
        content['toolName'] = 'update_plan';
        content['input'] = input;
        message.content = content;
        return message;
      };
      const answer = new RemoteMessage();
      answer.id = 'old-answer';
      answer.role = 'assistant';
      answer.content = '上一轮已完成';
      const historicalItems = buildRenderItems([
        userBoundary('old-user'),
        planMessage('old-plan'),
        answer,
        userBoundary('current-user'),
      ], true);
      let historicalCard: RenderTodoCardItem | undefined = undefined;
      for (let i = 0; i < historicalItems.length; i++) {
        if (historicalItems[i].type === 'todo') {
          historicalCard = historicalItems[i] as RenderTodoCardItem;
        }
      }
      expect(historicalCard !== undefined).assertEqual(true);
      expect(historicalCard?.isStreaming).assertEqual(false);

      const currentItems = buildRenderItems([
        userBoundary('current-user'),
        planMessage('current-plan'),
      ], true);
      let currentCard: RenderTodoCardItem | undefined = undefined;
      for (let i = 0; i < currentItems.length; i++) {
        if (currentItems[i].type === 'todo') currentCard = currentItems[i] as RenderTodoCardItem;
      }
      expect(currentCard !== undefined).assertEqual(true);
      expect(currentCard?.isStreaming).assertEqual(true);
    });

    it('parsesThinkingMetadataAndDerivesItsStartTime', 0, () => {
      const text = new RemoteMessage();
      text.createdAt = '2026-08-01T12:00:00.000Z';
      text.content = '分析中';
      const textPresentation = parseThinkingPresentation(text);
      expect(textPresentation?.body).assertEqual('分析中');
      expect(textPresentation?.durationMs).assertEqual(-1);
      expect(textPresentation?.startedAt).assertEqual(text.createdAt);

      const structured = new RemoteMessage();
      structured.createdAt = '2026-08-01T12:00:05.000Z';
      const structuredContent: Record<string, Object> = {};
      structuredContent['thinking'] = '检查实现';
      structuredContent['durationMs'] = 2500;
      structuredContent['finishedAt'] = '2026-08-01T12:00:05.000Z';
      structured.content = structuredContent;
      const structuredPresentation = parseThinkingPresentation(structured);
      expect(structuredPresentation?.body).assertEqual('检查实现');
      expect(structuredPresentation?.durationMs).assertEqual(2500);
      expect(structuredPresentation?.startedAt).assertEqual('2026-08-01T12:00:02.500Z');

      const redacted = new RemoteMessage();
      redacted.createdAt = structured.createdAt;
      const redactedContent: Record<string, Object> = {};
      redactedContent['isRedacted'] = true;
      redacted.content = redactedContent;
      expect(parseThinkingPresentation(redacted)?.redacted).assertEqual(true);
    });

    it('marksOnlyFinalAssistantMessagesForCompletedTurns', 0, () => {
      const assistant = (id: string, body: string): RemoteMessage => {
        const message = new RemoteMessage();
        message.id = id;
        message.role = 'assistant';
        message.content = body;
        return message;
      };
      const firstDraft = assistant('first-draft', '处理中');
      const firstFinal = assistant('first-final', '第一轮完成');
      const secondDraft = assistant('second-draft', '第二轮处理中');
      secondDraft.isStreaming = true;
      const messages = [
        userBoundary('first-user'), firstDraft, firstFinal,
        userBoundary('second-user'), secondDraft,
      ];
      const streaming = turnFinalAssistantIds(messages, true);
      expect(streaming.has('first-final')).assertEqual(true);
      expect(streaming.has('first-draft')).assertEqual(false);
      expect(streaming.has('second-draft')).assertEqual(false);
      const settled = turnFinalAssistantIds(messages, false);
      expect(settled.has('first-final')).assertEqual(true);
      expect(settled.has('second-draft')).assertEqual(true);
    });

    it('keepsCompletedTailActionsWhileTheNextSendStartsBeforeItsUserRowLoads', 0, () => {
      const answer = new RemoteMessage();
      answer.id = 'completed-tail';
      answer.role = 'assistant';
      answer.content = '上一轮已完成回答';
      const messages = [userBoundary('previous-user'), answer];
      expect(turnFinalAssistantIds(messages, true).has(answer.id)).assertEqual(true);

      answer.isStreaming = true;
      expect(turnFinalAssistantIds(messages, true).has(answer.id)).assertEqual(false);
      answer.isStreaming = false;

      const localCard = new RemoteMessage();
      localCard.id = 'local-card';
      localCard.role = 'user';
      localCard.systemCardType = 'pwd';
      expect(turnFinalAssistantIds(messages.concat([localCard]), true).has(answer.id)).assertEqual(true);

      const staleTool = new RemoteMessage();
      staleTool.id = 'stale-tool';
      staleTool.role = 'tool_use';
      const staleToolContent: Record<string, Object> = {};
      staleToolContent['toolUseId'] = 'stale-use';
      staleToolContent['toolName'] = 'Bash';
      staleTool.content = staleToolContent;
      expect(turnFinalAssistantIds([
        userBoundary('tool-user'), staleTool, answer,
      ], true).has(answer.id)).assertEqual(true);
      expect(turnFinalAssistantIds([
        userBoundary('active-tool-user'), answer, staleTool,
      ], true).has(answer.id)).assertEqual(false);
    });

    it('retriesHistoryWithSmallerPagesOnlyForOversizedFrames', 0, () => {
      expect(historyRetryLimits(50).join(',')).assertEqual('50,25,10,5,1');
      expect(historyRetryLimits(80).join(',')).assertEqual('80,40,20,10,5,1');

      const coded: Record<string, Object> = {};
      coded['code'] = 'PAYLOAD_TOO_LARGE';
      expect(isPayloadTooLargeError(coded)).assertEqual(true);
      expect(isPayloadTooLargeError(new Error('PAYLOAD_TOO_LARGE: history page'))).assertEqual(true);
      expect(isPayloadTooLargeError(new Error('WebSocket frame exceeds 1048576 bytes'))).assertEqual(true);
      expect(isPayloadTooLargeError(new Error('network disconnected'))).assertEqual(false);
    });

    it('letsASettledHistoryPageOwnTheLoadEarlierAffordance', 0, () => {
      expect(shouldKeepOlderMessagesAffordance(80, true)).assertEqual(true);
      expect(shouldKeepOlderMessagesAffordance(5, true)).assertEqual(true);
      expect(shouldKeepOlderMessagesAffordance(52, false)).assertEqual(false);
      expect(shouldKeepOlderMessagesAffordance(0, true)).assertEqual(false);
      expect(shouldInferOlderMessagesFromCount(false, 213, 212)).assertEqual(true);
      expect(shouldInferOlderMessagesFromCount(true, 213, 212)).assertEqual(false);
    });

    it('projectsFriendlyToolLabelsAndKeepsCommandsInDetails', 0, () => {
      const bashInput: Record<string, Object> = {};
      bashInput['description'] = '搜索 DlClient 的定义';
      bashInput['command'] = 'rg -n "class DlClient" apps/harmony';
      const bash = projectToolUseActions('Bash', JSON.stringify(bashInput), '');
      expect(bash[0].label).assertEqual('搜索 DlClient 的定义');
      expect(bash[0].detail).assertEqual('rg -n "class DlClient" apps/harmony');
      expect(bash[0].label.includes('/bin/zsh')).assertEqual(false);

      const readInput: Record<string, Object> = {};
      readInput['file_path'] = '/repo/apps/harmony/DlClient.ets';
      const read = projectToolUseActions('Read', JSON.stringify(readInput), '');
      expect(read[0].label).assertEqual('读取 DlClient.ets');
      expect(read[0].detail).assertEqual('/repo/apps/harmony/DlClient.ets');

      const unknownInput: Record<string, Object> = {};
      unknownInput['command'] = '/bin/zsh -lc export DEVECO_HOME=/Applications/DevEco-Studio.app';
      const unknown = projectToolUseActions('exec', JSON.stringify(unknownInput), '');
      expect(unknown[0].label).assertEqual('运行命令');
      expect(unknown[0].detail.includes('/bin/zsh -lc')).assertEqual(true);
    });

    it('projectsAndDeduplicatesCollapsedWorkGroupRows', 0, () => {
      const work = new RenderWorkGroupItem();
      const thinking = new RenderThinkingItem();
      thinking.type = 'thinking';
      thinking.key = 'thinking-1';
      thinking.body = '**先检查** `MessageStore.ets`，再继续分析。';

      const tools = new RenderToolGroupItem();
      tools.type = 'tool_group';
      tools.key = 'tools-1';
      for (let i = 0; i < 2; i++) {
        const read = new RenderToolItem();
        read.seq = i + 1;
        read.toolName = 'Read';
        read.inputRaw = '{"file_path":"/repo/MessageStore.ets"}';
        read.hasResult = true;
        tools.tools.push(read);
      }
      const search = new RenderToolItem();
      search.seq = 3;
      search.toolName = 'Grep';
      search.inputRaw = '{"pattern":"loadInitial","path":"/repo"}';
      tools.tools.push(search);
      work.children = [thinking, tools];

      const rows = workPreviewRows(work);
      expect(rows.length).assertEqual(3);
      expect(rows[0].kind).assertEqual('thinking');
      const thinkingTokens = tokenizeThinkingText(rows[0].text);
      expect(thinkingTokens[0].kind).assertEqual('strong');
      expect(thinkingTokens[2].kind).assertEqual('code');
      expect(rows[1].text).assertEqual('读取 MessageStore.ets');
      expect(rows[1].done).assertEqual(true);
      expect(rows[2].explorationKind).assertEqual('search');
      expect(workExplorationSummary(work)).assertEqual('读取 1 个文件 · 搜索 1 次');
      work.isStreaming = true;
      expect(workGroupHasHiddenRows(work)).assertEqual(false);

      for (let i = 0; i < 4; i++) {
        const extra = new RenderThinkingItem();
        extra.type = 'thinking';
        extra.key = `thinking-extra-${i}`;
        extra.body = `继续分析 ${i}`;
        work.children.push(extra);
      }
      expect(workPreviewRows(work).length).assertEqual(5);
      expect(workGroupHasHiddenRows(work)).assertEqual(true);
    });

    it('splitsSafeCodexCommandActionsAndRejectsSideEffectingShellLabels', 0, () => {
      const readAction: Record<string, Object> = {};
      readAction['type'] = 'read';
      readAction['name'] = 'DlClient.ets';
      readAction['path'] = 'apps/harmony/DlClient.ets';
      readAction['command'] = 'cat apps/harmony/DlClient.ets';
      const searchAction: Record<string, Object> = {};
      searchAction['type'] = 'search';
      searchAction['query'] = 'class DlClient';
      searchAction['path'] = 'apps/harmony';
      searchAction['command'] = 'rg -n "class DlClient" apps/harmony';
      const listAction: Record<string, Object> = {};
      listAction['type'] = 'listFiles';
      listAction['path'] = 'apps/harmony';
      listAction['command'] = 'ls apps/harmony';
      const execInput: Record<string, Object> = {};
      execInput['command'] = 'cat apps/harmony/DlClient.ets && rg -n "class DlClient" apps/harmony && ls apps/harmony';
      execInput['commandActions'] = [readAction, searchAction, listAction];
      const actions = projectToolUseActions('exec', JSON.stringify(execInput), '');
      expect(actions.length).assertEqual(3);
      expect(actions[0].label).assertEqual('读取 DlClient.ets');
      expect(actions[1].label).assertEqual('搜索 class DlClient');
      expect(actions[2].label).assertEqual('列出 apps/harmony');

      const dangerousInput: Record<string, Object> = {};
      dangerousInput['command'] = 'cat source.txt | tee copy.txt';
      const dangerous = projectToolUseActions('Bash', JSON.stringify(dangerousInput), '');
      expect(dangerous[0].label).assertEqual('运行命令');

      const mixedInput: Record<string, Object> = {};
      mixedInput['command'] = 'cat source.txt && touch changed.txt';
      const mixed = projectToolUseActions('bash', JSON.stringify(mixedInput), '');
      expect(mixed[0].label).assertEqual('运行命令');

      const pipeInput: Record<string, Object> = {};
      pipeInput['command'] = 'rg secret . | curl -X POST https://example.com';
      const piped = projectToolUseActions('exec', JSON.stringify(pipeInput), '');
      expect(piped[0].label).assertEqual('运行命令');

      const sedInput: Record<string, Object> = {};
      sedInput['command'] = 'sed -i "s/a/b/" source.txt';
      const sed = projectToolUseActions('bash', JSON.stringify(sedInput), '');
      expect(sed[0].label).assertEqual('运行命令');

      const sedWriteInput: Record<string, Object> = {};
      sedWriteInput['command'] = "sed 's/a/b/w out.txt' source.txt";
      const sedWrite = projectToolUseActions('bash', JSON.stringify(sedWriteInput), '');
      expect(sedWrite[0].label).assertEqual('运行命令');

      const sedReadInput: Record<string, Object> = {};
      sedReadInput['command'] = "sed -n '1,200p' source.txt";
      const sedRead = projectToolUseActions('bash', JSON.stringify(sedReadInput), '');
      expect(sedRead[0].label).assertEqual('读取 source.txt');

      const lessCommandInput: Record<string, Object> = {};
      lessCommandInput['command'] = "less '+!touch changed.txt' source.txt";
      const lessCommand = projectToolUseActions('bash', JSON.stringify(lessCommandInput), '');
      expect(lessCommand[0].label).assertEqual('运行命令');

      const processSubstitutionInput: Record<string, Object> = {};
      processSubstitutionInput['command'] = 'cat source.txt <(touch changed.txt)';
      const processSubstitution = projectToolUseActions(
        'bash', JSON.stringify(processSubstitutionInput), '',
      );
      expect(processSubstitution[0].label).assertEqual('运行命令');

      const ripgrepPreprocessorInput: Record<string, Object> = {};
      ripgrepPreprocessorInput['command'] = "rg --pre='touch changed.txt' pattern .";
      const ripgrepPreprocessor = projectToolUseActions(
        'bash', JSON.stringify(ripgrepPreprocessorInput), '',
      );
      expect(ripgrepPreprocessor[0].label).assertEqual('运行命令');
    });

    it('unwrapsOnlyUnambiguousPosixShellCommandsForOldHistory', 0, () => {
      const readInput: Record<string, Object> = {};
      readInput['command'] = "/bin/zsh -lc 'cat /repo/src/DlClient.ets'";
      const read = projectToolUseActions('exec', JSON.stringify(readInput), '');
      expect(read[0].label).assertEqual('读取 DlClient.ets');
      expect(read[0].detail).assertEqual('cat /repo/src/DlClient.ets');

      const searchInput: Record<string, Object> = {};
      searchInput['command'] = "/usr/bin/bash -c 'rg -n \"DlClient\" apps/harmony'";
      const search = projectToolUseActions('exec', JSON.stringify(searchInput), '');
      expect(search[0].label).assertEqual('搜索 DlClient');

      const malformedInput: Record<string, Object> = {};
      malformedInput['command'] = "/bin/zsh -lc 'cat source.txt' trailing";
      const malformed = projectToolUseActions('exec', JSON.stringify(malformedInput), '');
      expect(malformed[0].label).assertEqual('运行命令');
    });

    it('preservesStructuredLiveToolInputForFriendlyLabels', 0, () => {
      const store = new MessageStore();
      const input: Record<string, Object> = {};
      input['description'] = '读取鸿蒙消息实现';
      input['command'] = 'sed -n "1,200p" MessageRender.ets';
      const data: Record<string, Object> = {};
      data['toolUseId'] = 'live-use-1';
      data['toolName'] = 'Bash';
      data['input'] = input;
      const event: Record<string, Object> = {};
      event['type'] = 'tool_use';
      event['data'] = data;
      store.handleMakerEvent('live-session', event);

      const messages = store.getMessagesWithStreaming('live-session');
      const content = messages[0].content as Record<string, Object>;
      expect(typeof content['input']).assertEqual('object');
      const actions = projectToolUseActions('Bash', JSON.stringify(content['input']), '');
      expect(actions[0].label).assertEqual('读取鸿蒙消息实现');

      const legacy = projectToolUseActions('Bash', JSON.stringify(JSON.stringify(input)), '');
      expect(legacy[0].label).assertEqual('读取鸿蒙消息实现');
    });

    it('batchesRapidTextNotificationsAndFlushesBeforeToolBoundaries', 0, () => {
      const store = new MessageStore();
      let notifications = 0;
      const unsubscribe = store.onChanged(() => {
        notifications += 1;
      });
      const firstData: Record<string, Object> = {};
      firstData['text'] = '前';
      const firstEvent: Record<string, Object> = {};
      firstEvent['type'] = 'text';
      firstEvent['data'] = firstData;
      store.handleMakerEvent('batched-text', firstEvent, 'answer-1');
      const secondData: Record<string, Object> = {};
      secondData['text'] = '进';
      const secondEvent: Record<string, Object> = {};
      secondEvent['type'] = 'text';
      secondEvent['data'] = secondData;
      store.handleMakerEvent('batched-text', secondEvent, 'answer-1');
      expect(notifications).assertEqual(0);
      expect(store.getStreaming('batched-text')?.text ?? '').assertEqual('前进');

      const toolData: Record<string, Object> = {};
      toolData['toolUseId'] = 'batch-tool';
      toolData['toolName'] = 'Read';
      const toolEvent: Record<string, Object> = {};
      toolEvent['type'] = 'tool_use';
      toolEvent['data'] = toolData;
      store.handleMakerEvent('batched-text', toolEvent, 'tool-1');
      expect(notifications).assertEqual(1);
      expect(TEXT_DELTA_BATCH_INTERVAL_MS).assertEqual(32);
      unsubscribe();
    });

    it('closesEarlierWorkImmediatelyWhenSameMillisecondProgressPushArrives', 0, () => {
      const sessionId = 'same-ms-live-session';
      const createdAt = '2026-08-10T00:00:00.000Z';
      const store = new MessageStore();

      const thinkingMessage: Record<string, Object> = {};
      thinkingMessage['id'] = 'thinking-before-progress';
      thinkingMessage['clientId'] = 'thinking-before-progress';
      thinkingMessage['sessionId'] = sessionId;
      thinkingMessage['role'] = 'thinking';
      thinkingMessage['content'] = '检查现有实现';
      thinkingMessage['createdAt'] = createdAt;
      thinkingMessage['rowid'] = 41;
      const thinkingPush: Record<string, Object> = {};
      thinkingPush['sessionId'] = sessionId;
      thinkingPush['message'] = thinkingMessage;
      store.handleSessionPush('device-1', 'local-db:messages:created', thinkingPush);

      const progressData: Record<string, Object> = {};
      progressData['text'] = '已经找到同步问题，继续修复。';
      const progressEvent: Record<string, Object> = {};
      progressEvent['type'] = 'text';
      progressEvent['data'] = progressData;
      store.handleMakerEvent(sessionId, progressEvent, 'progress-answer');

      // Desktop messages:created 实时帧不保证携带 DB rowid；与前一行同毫秒时
      // 必须保留到达顺序，不能把正文排到工作步骤前面。
      const answerMessage: Record<string, Object> = {};
      answerMessage['id'] = 'progress-answer';
      answerMessage['clientId'] = 'progress-answer';
      answerMessage['sessionId'] = sessionId;
      answerMessage['role'] = 'assistant';
      answerMessage['content'] = '已经找到同步问题，继续修复。';
      answerMessage['createdAt'] = createdAt;
      const answerPush: Record<string, Object> = {};
      answerPush['sessionId'] = sessionId;
      answerPush['message'] = answerMessage;
      store.handleSessionPush('device-1', 'local-db:messages:created', answerPush);

      const nextToolInput: Record<string, Object> = {};
      nextToolInput['description'] = '修改实时收口逻辑';
      const nextToolData: Record<string, Object> = {};
      nextToolData['toolUseId'] = 'tool-after-progress';
      nextToolData['toolName'] = 'Bash';
      nextToolData['input'] = nextToolInput;
      const nextToolEvent: Record<string, Object> = {};
      nextToolEvent['type'] = 'tool_use';
      nextToolEvent['data'] = nextToolData;
      store.handleMakerEvent(sessionId, nextToolEvent, 'next-tool-block');

      const messages = store.getMessagesWithStreaming(sessionId);
      expect(messages.length).assertEqual(3);
      expect(messages[0].id).assertEqual('thinking-before-progress');
      expect(messages[1].id).assertEqual('progress-answer');
      expect(messages[2].role).assertEqual('tool_use');
      expect(store.isSessionStreaming(sessionId)).assertEqual(true);

      const items = buildRenderItems(messages, true);
      expect(items.length).assertEqual(3);
      expect(items[0].type).assertEqual('work_group');
      expect((items[0] as RenderWorkGroupItem).isStreaming).assertEqual(false);
      expect(items[1].type).assertEqual('message');
      expect(items[2].type).assertEqual('work_group');
      expect((items[2] as RenderWorkGroupItem).isStreaming).assertEqual(true);

      const historyRow = new RemoteMessage();
      historyRow.createdAt = createdAt;
      historyRow.rowid = 41;
      const liveRow = new RemoteMessage();
      liveRow.createdAt = createdAt;
      expect(sortMessagesAsc(liveRow, historyRow)).assertEqual(0);
    });

    it('rebuildsMessageListNodesWhenTheirPresentationChanges', 0, () => {
      expect(messageListRenderNodeKey('work-a', 'work_group', true))
        .assertEqual('render:10:work_group:6:work-a:work:live');
      expect(messageListRenderNodeKey('work-a', 'work_group', false))
        .assertEqual('render:10:work_group:6:work-a:work:done');
      expect(messageListRenderNodeKey('work-a', 'work_group', true))
        .assertEqual('render:10:work_group:6:work-a:work:live');
      expect(messageListRenderNodeKey('message-a', 'message', true))
        .assertEqual('render:7:message:9:message-a');
      expect(messageListRenderNodeKey(
        'subagent-a', 'subagent_group', false, 's:7:running:0:w1'))
        .assertEqual('render:14:subagent_group:10:subagent-a:state:16:s:7:running:0:w1');
      expect(messageListRenderNodeKey(
        'subagent-a', 'subagent_group', false, 's:9:completed:0:w0'))
        .assertEqual('render:14:subagent_group:10:subagent-a:state:18:s:9:completed:0:w0');

      const todo = new RenderTodoCardItem();
      todo.type = 'todo';
      todo.key = 'todo-a';
      todo.isStreaming = true;
      const step = new RenderTodoItem();
      step.seq = 0;
      step.content = '完成实时刷新';
      step.status = 'in_progress';
      todo.todos = [step];
      const pendingTodoKey = messageListRenderNodeKey(
        todo.key, todo.type, false, messageListItemPresentationState(todo));
      step.status = 'completed';
      const completedTodoKey = messageListRenderNodeKey(
        todo.key, todo.type, false, messageListItemPresentationState(todo));
      expect(pendingTodoKey === completedTodoKey).assertEqual(false);
      expect(todo.key).assertEqual('todo-a');

      const agent = new RenderAgentTaskItem();
      agent.type = 'agent_task';
      agent.key = 'task-a';
      agent.update = new AgentTaskUpdate();
      agent.update.taskId = 'agent-a';
      agent.update.status = 'running';
      agent.update.updatedAt = '2026-08-17T10:00:00.000Z';
      const runningAgentKey = messageListRenderNodeKey(
        agent.key, agent.type, false, messageListItemPresentationState(agent));
      agent.update.status = 'completed';
      agent.update.updatedAt = '2026-08-17T10:00:01.000Z';
      const completedAgentKey = messageListRenderNodeKey(
        agent.key, agent.type, false, messageListItemPresentationState(agent));
      expect(runningAgentKey === completedAgentKey).assertEqual(false);
      expect(agent.key).assertEqual('task-a');

      const toolGroup = new RenderToolGroupItem();
      toolGroup.type = 'tool_group';
      toolGroup.key = 'tool-a';
      const tool = new RenderToolItem();
      tool.toolUseId = 'tool-a';
      tool.toolName = 'Bash';
      toolGroup.tools = [tool];
      const work = new RenderWorkGroupItem();
      work.type = 'work_group';
      work.key = 'work-a';
      work.isStreaming = true;
      work.children = [toolGroup];
      const runningWorkKey = messageListRenderNodeKey(
        work.key, work.type, true, messageListItemPresentationState(work));
      tool.hasResult = true;
      tool.resultText = 'ok';
      const settledWorkKey = messageListRenderNodeKey(
        work.key, work.type, true, messageListItemPresentationState(work));
      expect(runningWorkKey === settledWorkKey).assertEqual(false);
      expect(work.key).assertEqual('work-a');
    });

    it('keepsToolsAfterProgressTextInTheLiveWorkGroupAndPreservesTurnClock', 0, () => {
      const store = new MessageStore();
      const textData: Record<string, Object> = {};
      textData['text'] = '先汇报当前进度';
      const textEvent: Record<string, Object> = {};
      textEvent['type'] = 'text';
      textEvent['data'] = textData;
      store.handleMakerEvent('interleaved-live', textEvent, 'progress-1');
      const startedAt = store.getSessionRunStartedAt('interleaved-live');
      expect(startedAt > 0).assertEqual(true);

      const input: Record<string, Object> = {};
      input['description'] = '搜索后续实现';
      const toolData: Record<string, Object> = {};
      toolData['toolUseId'] = 'post-progress-tool';
      toolData['toolName'] = 'Bash';
      toolData['input'] = input;
      const toolEvent: Record<string, Object> = {};
      toolEvent['type'] = 'tool_use';
      toolEvent['data'] = toolData;
      store.handleMakerEvent('interleaved-live', toolEvent, 'tool-1');

      expect(store.getSessionRunStartedAt('interleaved-live')).assertEqual(startedAt);
      void store.closeSession('interleaved-live');
      expect(store.getSessionRunStartedAt('interleaved-live')).assertEqual(startedAt);
      // 离开页面只停订阅：重进首帧应仍看到进度正文和当前工具，且计时不归零。
      expect(store.getSessionRunStartedAt('interleaved-live')).assertEqual(startedAt);
      const cachedMessages = store.getMessagesWithStreaming('interleaved-live');
      expect(cachedMessages.length).assertEqual(2);
      expect(cachedMessages[0].role).assertEqual('assistant');
      expect(cachedMessages[1].role).assertEqual('tool_use');
      const items = buildRenderItems(cachedMessages, store.isSessionStreaming('interleaved-live'));
      const work = items[items.length - 1] as RenderWorkGroupItem;
      expect(work.type).assertEqual('work_group');
      expect(work.isStreaming).assertEqual(true);
      const tools = work.children[0] as RenderToolGroupItem;
      expect(tools.tools[0].toolUseId).assertEqual('post-progress-tool');

      const done: Record<string, Object> = {};
      done['type'] = 'done';
      store.handleMakerEvent('interleaved-live', done);
      expect(store.getSessionRunStartedAt('interleaved-live')).assertEqual(0);
      const completed = buildRenderItems(
        store.getMessagesWithStreaming('interleaved-live'),
        store.isSessionStreaming('interleaved-live'),
      );
      const completedWork = completed[completed.length - 1] as RenderWorkGroupItem;
      expect(completedWork.isStreaming).assertEqual(false);
    });

    it('evictsLeastRecentlyUsedInactiveMessageSessions', 0, async () => {
      const store = new MessageStore();
      for (let i = 0; i <= MAX_CACHED_MESSAGE_SESSIONS; i++) {
        const data: Record<string, Object> = {};
        data['index'] = i;
        const sessionId = `cached-session-${i}`;
        store.appendLocalSystemCard(sessionId, 'learn', data);
        await store.closeSession(sessionId);
      }
      expect(store.getMessages('cached-session-0').length).assertEqual(0);
      expect(store.getMessages(`cached-session-${MAX_CACHED_MESSAGE_SESSIONS}`).length).assertEqual(1);
    });

    it('roundTripsStructuredRecentMessageCacheAndStripsHeavyMediaBytes', 0, () => {
      const messages: RemoteMessage[] = [];
      for (let i = 0; i < MAX_CACHED_SESSION_MESSAGES + 2; i++) {
        const message = new RemoteMessage();
        message.id = `message-${i}`;
        message.clientId = message.id;
        message.sessionId = 'cache-session';
        message.role = 'user';
        message.createdAt = new Date(1_700_000_000_000 + i).toISOString();
        const image: Record<string, Object> = {};
        image['url'] = 'https://example.invalid/image.png';
        image['base64'] = 'very-heavy-binary';
        const content: Record<string, Object> = {};
        content['text'] = `正文 ${i}`;
        content['images'] = [image];
        message.content = content;
        messages.push(message);
      }
      const normalized = normalizeSessionCacheMessages(messages);
      expect(normalized.length).assertEqual(MAX_CACHED_SESSION_MESSAGES);
      expect(normalized[0].id).assertEqual('message-2');
      const normalizedContent = normalized[0].content as Record<string, Object>;
      const images = normalizedContent['images'] as Object[];
      const cachedImage = images[0] as Record<string, Object>;
      expect(cachedImage['url']).assertEqual('https://example.invalid/image.png');
      expect(cachedImage['base64'] === undefined).assertEqual(true);

      const entry = new CachedSessionMessages();
      entry.deviceId = 'device-1';
      entry.sessionId = 'cache-session';
      entry.updatedAt = 123;
      entry.messages = normalized;
      const serialized = serializeSessionMessageSnapshot('account-a', [entry]) ?? '';
      expect(parseSessionMessageSnapshot(serialized, 'account-b').length).assertEqual(0);
      const restored = parseSessionMessageSnapshot(serialized, 'account-a');
      expect(restored.length).assertEqual(1);
      expect(restored[0].messages.length).assertEqual(MAX_CACHED_SESSION_MESSAGES);
      expect(restored[0].messages[0].id).assertEqual('message-2');
    });

    it('keepsLiveCacheOnAuthoritativeEmptyAndCancelsDeferredClearForNewPush', 0, () => {
      expect(shouldPreserveCachedMessagesForAuthoritativeEmpty(0, true)).assertEqual(true);
      expect(shouldPreserveCachedMessagesForAuthoritativeEmpty(1, true)).assertEqual(false);
      expect(shouldDeferAuthoritativeEmptyWindow(0, true, 4, 4)).assertEqual(true);
      // messages:list 请求期间已有新权威 push：旧空响应不能重新挂起清窗。
      expect(shouldDeferAuthoritativeEmptyWindow(0, true, 4, 5)).assertEqual(false);

      const deferrals = new AuthoritativeEmptyDeferrals();
      deferrals.update('cache-live', true);
      // 空响应先到、push 后到：push 必须取消已挂起的清窗。
      deferrals.cancel('cache-live');
      expect(deferrals.consume('cache-live')).assertEqual(false);
      deferrals.update('cache-live', true);
      expect(deferrals.consume('cache-live')).assertEqual(true);
      expect(deferrals.consume('cache-live')).assertEqual(false);
    });

    it('clearsStaleCachedRowsAfterLiveTurnButKeepsLocalAndFinalProjection', 0, () => {
      const stale = new RemoteMessage();
      stale.id = 'stale-server-row';
      stale.role = 'assistant';
      stale.createdAt = '2026-08-01T00:00:01.000Z';
      const local = new RemoteMessage();
      local.id = 'custom-local-card';
      local.role = 'system';
      local.localOnly = true;
      local.createdAt = '2026-08-01T00:00:02.000Z';
      const finalProjection = new RemoteMessage();
      finalProjection.id = 'final-projection';
      finalProjection.role = 'assistant';
      finalProjection.content = '刚完成但尚未收到 DB push 的回答';
      finalProjection.createdAt = '2026-08-01T00:00:03.000Z';
      finalProjection.isStreaming = false;
      const protectedKeys = new Set<string>();
      protectedKeys.add('id:final-projection');
      const reconciled = reconcileDeferredAuthoritativeEmptyMessages(
        [stale, local, finalProjection], protectedKeys);
      expect(reconciled.length).assertEqual(2);
      expect(reconciled[0].id).assertEqual(local.id);
      expect(reconciled[1].id).assertEqual(finalProjection.id);
      expect(reconciled[1].isStreaming).assertEqual(false);
    });

    it('formatsTheComposerActivityClockLikeIos', 0, () => {
      expect(sessionActivityElapsedMs(10_999, 10_000)).assertEqual(999);
      expect(sessionActivityElapsedMs(9_000, 10_000)).assertEqual(0);
      expect(formatSessionActivityElapsed(999)).assertEqual('0s');
      expect(formatSessionActivityElapsed(1_000)).assertEqual('1s');
      expect(formatSessionActivityElapsed(62_900)).assertEqual('1m 2s');
    });

    it('keepsNewPersistedStreamingBlockWhenOlderPushArrives', 0, () => {
      const store = new MessageStore();
      const firstData: Record<string, Object> = {};
      firstData['text'] = '第一段';
      const firstEvent: Record<string, Object> = {};
      firstEvent['type'] = 'text';
      firstEvent['data'] = firstData;
      store.handleMakerEvent('persist-session', firstEvent, 'persist-1');

      const secondData: Record<string, Object> = {};
      secondData['text'] = '第二段仍在生成';
      const secondEvent: Record<string, Object> = {};
      secondEvent['type'] = 'text';
      secondEvent['data'] = secondData;
      store.handleMakerEvent('persist-session', secondEvent, 'persist-2');

      const oldMessage: Record<string, Object> = {};
      oldMessage['id'] = 'persist-1';
      oldMessage['clientId'] = 'persist-1';
      oldMessage['role'] = 'assistant';
      oldMessage['content'] = '第一段（已落库）';
      const push: Record<string, Object> = {};
      push['sessionId'] = 'persist-session';
      push['message'] = oldMessage;
      store.handleSessionPush('', 'local-db:messages:created', push);

      const rows = store.getMessagesWithStreaming('persist-session');
      expect(rows.some((row: RemoteMessage) => row.id === 'persist-1'
        && row.content === '第一段（已落库）')).assertEqual(true);
      expect(rows.some((row: RemoteMessage) => row.id === 'persist-2'
        && row.content === '第二段仍在生成')).assertEqual(true);
    });

    it('replacesTruncatedRowsWithCompleteCreatedPushes', 0, () => {
      const truncated = new RemoteMessage();
      truncated.id = 'same-row';
      truncated.content = '内容过大，已截断';
      truncated.agentMeta['remoteContentTruncated'] = true;
      const complete = new RemoteMessage();
      complete.id = 'same-row';
      complete.content = '完整正文';
      expect(preferIncomingCreatedMessage(truncated, complete)).assertEqual(true);
      expect(preferIncomingCreatedMessage(complete, truncated)).assertEqual(false);
    });

    it('deduplicatesLiveToolRowsAfterThePersistedCallArrives', 0, () => {
      const store = new MessageStore();
      const input: Record<string, Object> = {};
      input['file_path'] = '/repo/MessageRender.ets';
      const liveData: Record<string, Object> = {};
      liveData['toolUseId'] = 'same-use';
      liveData['toolName'] = 'Read';
      liveData['input'] = input;
      const liveEvent: Record<string, Object> = {};
      liveEvent['type'] = 'tool_use';
      liveEvent['data'] = liveData;
      store.handleMakerEvent('same-session', liveEvent);

      const persistedMessage: Record<string, Object> = {};
      persistedMessage['id'] = 'persisted-tool';
      persistedMessage['clientId'] = 'persisted-tool';
      persistedMessage['role'] = 'tool_use';
      persistedMessage['toolUseId'] = 'same-use';
      const persistedContent: Record<string, Object> = {};
      persistedContent['toolUseId'] = 'same-use';
      persistedContent['toolName'] = 'Read';
      persistedContent['input'] = input;
      persistedMessage['content'] = persistedContent;
      const push: Record<string, Object> = {};
      push['sessionId'] = 'same-session';
      push['message'] = persistedMessage;
      store.handleSessionPush('', 'local-db:messages:created', push);

      const resultData: Record<string, Object> = {};
      resultData['toolUseId'] = 'same-use';
      const resultEvent: Record<string, Object> = {};
      resultEvent['type'] = 'tool_result';
      resultEvent['data'] = resultData;
      store.handleMakerEvent('same-session', resultEvent);

      const messages = store.getMessagesWithStreaming('same-session');
      let useCount = 0;
      let resultCount = 0;
      for (let i = 0; i < messages.length; i++) {
        if (messages[i].role === 'tool_use' && messages[i].toolUseId === 'same-use') useCount += 1;
        if (messages[i].role === 'tool_result' && messages[i].toolUseId === 'same-use') resultCount += 1;
      }
      expect(useCount).assertEqual(1);
      expect(resultCount).assertEqual(1);
      const items = buildRenderItems(messages, true);
      const work = items[0] as RenderWorkGroupItem;
      const group = work.children[0] as RenderToolGroupItem;
      expect(group.tools.length).assertEqual(1);
      expect(group.tools[0].hasResult).assertEqual(true);
    });

    it('reconstructsTaskCreateAndTaskUpdateIntoOnePlanSession', 0, () => {
      const createInput: Record<string, Object> = {};
      createInput['subject'] = '检查鸿蒙工作步骤';
      const updateInput: Record<string, Object> = {};
      updateInput['taskId'] = '42';
      updateInput['status'] = 'completed';
      const create = planToolMessage('task-create', 'TaskCreate', createInput, 'create-use');
      const result = planToolResult(
        'task-created', 'create-use', 'Task #42 created successfully: 检查鸿蒙工作步骤');
      const update = planToolMessage('task-update', 'TaskUpdate', updateInput, 'update-use');
      const insertions = findTodoPlanInsertions([create, result, update]);

      expect(insertions.size).assertEqual(1);
      expect(insertions.get(2)?.key).assertEqual('todo-task-create');
      expect(insertions.get(2)?.todos[0].content).assertEqual('检查鸿蒙工作步骤');
      expect(insertions.get(2)?.todos[0].status).assertEqual('completed');
    });

    it('startsANewPlanSessionAcrossRealUserBoundaries', 0, () => {
      const firstStep: Record<string, Object> = {};
      firstStep['step'] = '读取代码';
      firstStep['status'] = 'in_progress';
      const firstInput: Record<string, Object> = {};
      firstInput['plan'] = [firstStep];
      const completedStep: Record<string, Object> = {};
      completedStep['step'] = '读取代码';
      completedStep['status'] = 'completed';
      const completedInput: Record<string, Object> = {};
      completedInput['plan'] = [completedStep];
      const first = planToolMessage('plan-first', 'update_plan', firstInput, 'plan-use-1');
      const ordinaryInput: Record<string, Object> = {};
      ordinaryInput['command'] = 'git status';
      const ordinary = planToolMessage('ordinary-tool', 'Bash', ordinaryInput, 'bash-use');
      const second = planToolMessage('plan-second', 'update_plan', completedInput, 'plan-use-2');
      const insertions = findTodoPlanInsertions([
        first, userBoundary('user-between'), ordinary, second,
      ]);

      expect(insertions.size).assertEqual(2);
      expect(insertions.get(0)?.key).assertEqual('todo-plan-first');
      expect(insertions.get(3)?.key).assertEqual('todo-plan-second');
      expect(insertions.get(3)?.todos[0].status).assertEqual('completed');
    });

    it('keepsPlanOwnershipAcrossSteerAndSyntheticRows', 0, () => {
      const step: Record<string, Object> = {};
      step['step'] = '继续执行';
      step['status'] = 'in_progress';
      const input: Record<string, Object> = {};
      input['plan'] = [step];
      const first = planToolMessage('plan-owner', 'update_plan', input, 'plan-owner-use');
      const steer = userBoundary('steer-row');
      steer.agentMeta['delivery'] = 'steer';
      const synthetic = userBoundary('resume-row');
      synthetic.isSyntheticTrigger = true;
      const second = planToolMessage('plan-update', 'update_plan', input, 'plan-update-use');
      const insertions = findTodoPlanInsertions([first, steer, synthetic, second]);
      expect(insertions.size).assertEqual(1);
      expect(insertions.get(3)?.key).assertEqual('todo-plan-owner');
    });

    it('doesNotLetSubagentPlansCompeteWithTheMainPlan', 0, () => {
      const step: Record<string, Object> = {};
      step['step'] = '主计划';
      step['status'] = 'in_progress';
      const input: Record<string, Object> = {};
      input['plan'] = [step];
      const main = planToolMessage('main-plan', 'update_plan', input, 'main-plan-use');
      const child = planToolMessage('child-plan', 'update_plan', input, 'child-plan-use');
      child.agentMeta['parentUuid'] = 'toolu_parent';
      const insertions = findTodoPlanInsertions([main, child]);
      expect(insertions.size).assertEqual(1);
      expect(insertions.get(0)?.key).assertEqual('todo-main-plan');
    });

    it('requiresEarlierHistoryForStatusOnlyTaskPlans', 0, () => {
      const boundary = userBoundary('task-owner');
      const updateInput: Record<string, Object> = {};
      updateInput['taskId'] = '42';
      updateInput['status'] = 'completed';
      const update = planToolMessage('task-update-only', 'TaskUpdate', updateInput, 'task-update-use');
      expect(latestTaskPlanWindowResolved([update], true)).assertEqual(false);
      expect(latestTaskPlanWindowResolved([boundary, update], true)).assertEqual(false);

      const createInput: Record<string, Object> = {};
      createInput['taskId'] = '42';
      createInput['subject'] = '完整任务';
      const create = planToolMessage('task-create-complete', 'TaskCreate', createInput, 'task-create-use');
      expect(latestTaskPlanWindowResolved([boundary, create, update], true)).assertEqual(true);
    });

    it('startsANewPlanSessionAfterThePreviousPlanCompletes', 0, () => {
      const doneStep: Record<string, Object> = {};
      doneStep['step'] = '完成旧计划';
      doneStep['status'] = 'completed';
      const doneInput: Record<string, Object> = {};
      doneInput['plan'] = [doneStep];
      const nextStep: Record<string, Object> = {};
      nextStep['step'] = '执行新计划';
      nextStep['status'] = 'in_progress';
      const nextInput: Record<string, Object> = {};
      nextInput['plan'] = [nextStep];
      const done = planToolMessage('plan-done', 'update_plan', doneInput, 'done-use');
      const next = planToolMessage('plan-next', 'update_plan', nextInput, 'next-use');
      const insertions = findTodoPlanInsertions([done, next]);

      expect(insertions.size).assertEqual(2);
      expect(insertions.get(0)?.key).assertEqual('todo-plan-done');
      expect(insertions.get(1)?.key).assertEqual('todo-plan-next');
    });

    it('doesNotMoveAStaleTaskPlanToAnAuthoritativeEmptyTaskList', 0, () => {
      const createInput: Record<string, Object> = {};
      createInput['subject'] = '旧任务';
      const create = planToolMessage('empty-create', 'TaskCreate', createInput, 'empty-create-use');
      const created = planToolResult(
        'empty-created', 'empty-create-use', 'Task #empty created successfully: 旧任务');
      const listInput: Record<string, Object> = {};
      const list = planToolMessage('empty-list', 'TaskList', listInput, 'empty-list-use');
      const empty = planToolResult('empty-result', 'empty-list-use', JSON.stringify({ tasks: [] }));
      const insertions = findTodoPlanInsertions([create, created, list, empty]);

      expect(insertions.size).assertEqual(1);
      expect(insertions.get(0)?.key).assertEqual('todo-empty-create');
      expect(insertions.get(2) === undefined).assertEqual(true);
    });

    it('matchesIdenticalTodoCardsByTheirPositionFromTheTail', 0, () => {
      const card = (key: string): RenderTodoCardItem => {
        const item = new RenderTodoCardItem();
        item.key = key;
        const first = new RenderTodoItem();
        first.content = '读取项目';
        const second = new RenderTodoItem();
        second.content = '完成修改';
        item.todos = [first, second];
        return item;
      };
      const previous = [card('old-earlier'), card('old-current')];
      const next = [card('new-oldest'), card('new-earlier'), card('new-current')];
      const signature = todoCardContentSignature(previous[1]);

      expect(todoCardRankFromTail(previous, 'old-current')).assertEqual(0);
      expect(todoCardIndexAtRankFromTail(next, signature, 0)).assertEqual(2);
      expect(todoCardRankFromTail(previous, 'old-earlier')).assertEqual(1);
      expect(todoCardIndexAtRankFromTail(next, signature, 1)).assertEqual(1);
    });

    it('classifiesOnlyRetryableNewSessionFailuresAsTransient', 0, () => {
      expect(isTransientNewSessionError(new Error('INVOKE_TIMEOUT'))).assertEqual(true);
      expect(isTransientNewSessionError(new Error('relay backpressure'))).assertEqual(true);
      expect(isTransientNewSessionError(new DlError('NOT_CONNECTED', 'not online'))).assertEqual(true);
      expect(isTransientNewSessionError(new DlError('BACKPRESSURE', 'buffer full'))).assertEqual(true);
      expect(isTransientNewSessionError(new DlError('CHANNEL_NOT_ALLOWED', 'timeout text')))
        .assertEqual(false);
      expect(isTransientNewSessionError(new Error('invalid working directory'))).assertEqual(false);
    });

    it('onlyReturnsNewSessionToEditAfterExactAbsence', 0, () => {
      const exact: Record<string, Object> = {};
      exact['id'] = 'session-1';
      const wrong: Record<string, Object> = {};
      wrong['id'] = 'session-other';
      expect(exactNewSessionRecord(exact, 'session-1') !== undefined).assertEqual(true);
      expect(exactNewSessionRecord(wrong, 'session-1') === undefined).assertEqual(true);
      expect(decideNewSessionRecoveryAction('edit', 'found')).assertEqual('resume');
      expect(decideNewSessionRecoveryAction('edit', 'missing')).assertEqual('edit');
      expect(decideNewSessionRecoveryAction('edit', 'unknown')).assertEqual('hold');
      expect(decideNewSessionRecoveryAction('retry', 'found')).assertEqual('resume');
      expect(decideNewSessionRecoveryAction('retry', 'missing')).assertEqual('create');
      expect(shouldBlockNewSessionRemoteOperation(false, 'running')).assertEqual(true);
      expect(shouldBlockNewSessionRemoteOperation(false, 'create-failed')).assertEqual(true);
      expect(shouldBlockNewSessionRemoteOperation(false, 'enqueue-failed')).assertEqual(false);
      expect(shouldBlockNewSessionRemoteOperation(true, '')).assertEqual(true);
    });

    it('derivesAndCollapsesAutoResumeCardsLikeMobile', 0, () => {
      expect(summarizeAutoResumeError(' API Error: timeout.\nsecond line'))
        .assertEqual('timeout.');
      const failedData: Record<string, Object> = {};
      failedData['live'] = true;
      failedData['error'] = 'API Error: relay unavailable';
      failedData['attempt'] = 2;
      failedData['maxAttempts'] = 3;
      failedData['sessionTotal'] = 4;
      failedData['outcome'] = 'failed';
      const failed = deriveAutoResumePresentation(failedData, true);
      expect(failed.state).assertEqual('failed');
      expect(failed.canExpand).assertEqual(true);

      const empty = deriveAutoResumePresentation({}, true);
      expect(empty.state).assertEqual('separator');

      const persistedInfo: Record<string, Object> = {};
      persistedInfo['outcome'] = 'succeeded';
      const persistedMeta: Record<string, Object> = {};
      persistedMeta['autoResume'] = true;
      persistedMeta['autoResumeInfo'] = persistedInfo;
      persistedMeta['autoResumeOutcome'] = 'invalid';
      const persistedRaw: Record<string, Object> = {};
      persistedRaw['id'] = 'persisted-resume';
      persistedRaw['role'] = 'user';
      persistedRaw['agentMeta'] = persistedMeta;
      const persisted = parseMessage(persistedRaw);
      expect(persisted.systemCardType).assertEqual('auto-resume');
      expect(persisted.systemCardData['outcome']).assertEqual('succeeded');

      const first = new RemoteMessage();
      first.id = 'resume-1';
      first.clientId = 'resume-client-1';
      first.role = 'user';
      first.systemCardType = 'auto-resume';
      first.isSyntheticTrigger = true;
      first.createdAt = '2026-08-01T00:00:01.000Z';
      const thinking = new RemoteMessage();
      thinking.id = 'thinking-empty';
      thinking.role = 'thinking';
      thinking.content = '  ';
      thinking.createdAt = '2026-08-01T00:00:02.000Z';
      const second = new RemoteMessage();
      second.id = 'resume-2';
      second.clientId = 'resume-client-2';
      second.role = 'user';
      second.systemCardType = 'auto-resume';
      second.systemCardData = failedData;
      second.isSyntheticTrigger = true;
      second.createdAt = '2026-08-01T00:00:03.000Z';
      const items = buildRenderItems(
        [first, thinking, second], true, undefined, false,
        'resume-client-2', 'supported', true);
      let visibleCards = 0;
      let inFlight = false;
      for (let i = 0; i < items.length; i++) {
        if (items[i].type !== 'message') continue;
        const item = items[i] as RenderMessageItem;
        if (item.message?.systemCardType === 'auto-resume') {
          visibleCards += 1;
          inFlight = item.autoResumeInFlight;
        }
      }
      expect(visibleCards).assertEqual(1);
      expect(inFlight).assertEqual(true);

      const pending: Record<string, Object> = {};
      pending['attempt'] = 1;
      const appended = appendAutoResumePendingMessage([second], pending);
      expect(appended.length).assertEqual(2);
      expect(appended[1].systemCardData['live']).assertEqual(true);
    });

    it('appliesCongestionBackoffAndExpandsMakerEventBatches', 0, () => {
      expect(computeReconnectDelayMs(0, 1, 1)).assertEqual(5000);
      expect(computeReconnectDelayMs(0, 2, 1)).assertEqual(10000);
      expect(computeReconnectDelayMs(0, 1, 0)).assertEqual(3500);
      expect(computeReconnectDelayMs(8, 8, 1)).assertEqual(30000);

      const first: Record<string, Object> = {};
      first['sessionId'] = 's1';
      first['event'] = 'one';
      const bad: Record<string, Object> = {};
      bad['sessionId'] = 's2';
      const second: Record<string, Object> = {};
      second['sessionId'] = 's1';
      second['event'] = 'two';
      const batch: Record<string, Object> = {};
      batch['sessionId'] = 's1';
      batch['events'] = [first, bad, 'broken', second];
      const expanded = expandMakerEventBatchPayload(batch);
      expect(expanded.length).assertEqual(2);
      expect(expanded[0]['event']).assertEqual('one');
      expect(expanded[1]['event']).assertEqual('two');
    });

    it('sizesMarkdownTablesForContentAndAvailablePane', 0, () => {
      const header = [tokenizeInline('Name'), tokenizeInline('状态')];
      const rows = [[tokenizeInline('Cindy'), tokenizeInline('Ready')]];
      const shortWidths = buildMarkdownTableColumnWidths(header, rows, 112, 220, 400);
      expect(shortWidths.length).assertEqual(2);
      expect(shortWidths[0] + shortWidths[1]).assertEqual(400);

      const unevenRows = [[tokenizeInline('one'), tokenizeInline('two'), tokenizeInline('three')]];
      const uneven = buildMarkdownTableColumnWidths(header, unevenRows, 96, 220, 0);
      expect(uneven.length).assertEqual(3);
      expect(uneven[2] >= 96).assertEqual(true);

      const wideHeader = [tokenizeInline('A'.repeat(80)), tokenizeInline('B'.repeat(80))];
      const wide = buildMarkdownTableColumnWidths(wideHeader, [], 112, 220, 280);
      expect(wide[0]).assertEqual(220);
      expect(wide[1]).assertEqual(220);
    });

    it('keepsOnlyContinuousHistoryAcrossLatestWindowRefresh', 0, () => {
      const make = (id: string, second: number): RemoteMessage => {
        const message = new RemoteMessage();
        message.id = id;
        message.role = 'assistant';
        message.content = id;
        message.createdAt = `2026-08-01T00:00:0${second}.000Z`;
        return message;
      };
      const old1 = make('old-1', 1);
      const old2 = make('old-2', 2);
      const overlap = make('overlap', 3);
      const newest = make('newest', 4);
      const unverified = reconcileLatestMessageWindow(
        [old1, old2, overlap], [overlap, newest], true, null, false);
      expect(unverified.items.length).assertEqual(2);

      const coverage = new MessageWindowCoverage();
      coverage.since = Date.parse(old1.createdAt);
      coverage.until = Date.parse(overlap.createdAt);
      const verified = reconcileLatestMessageWindow(
        [old1, old2, overlap], [overlap, newest], true, coverage, true);
      expect(verified.items.length).assertEqual(4);
      expect(verified.coverage?.liveTailTrusted).assertEqual(true);

      const unknownInside = make('unknown-inside', 2);
      const invalidated = reconcileLatestMessageWindow(
        [old1, old2, overlap], [unknownInside, overlap, newest], true, coverage, false);
      expect(invalidated.items.length).assertEqual(3);

      const local = make('harmony-system-local', 1);
      const tail = make('live-tail', 5);
      const preserved = reconcileLatestMessageWindow(
        [old1, overlap, local, tail], [overlap, newest], true, null, false);
      let hasLocal = false;
      let hasTail = false;
      for (let i = 0; i < preserved.items.length; i++) {
        if (preserved.items[i].id === local.id) hasLocal = true;
        if (preserved.items[i].id === tail.id) hasTail = true;
      }
      expect(hasLocal).assertEqual(true);
      expect(hasTail).assertEqual(true);

      const sameTimestampTail = make('same-time-tail', 4);
      const sameTimestamp = reconcileLatestMessageWindow(
        [overlap, sameTimestampTail], [overlap, newest], true, null, false);
      let hasSameTimestampTail = false;
      for (let i = 0; i < sameTimestamp.items.length; i++) {
        if (sameTimestamp.items[i].id === sameTimestampTail.id) hasSameTimestampTail = true;
      }
      expect(hasSameTimestampTail).assertEqual(true);
      expect(sameTimestamp.items.length).assertEqual(3);
    });

    it('clearsStaleHistoryOnAuthoritativeEmptyPageAndKeepsLocalTail', 0, () => {
      const stale = new RemoteMessage();
      stale.id = 'stale';
      stale.role = 'assistant';
      stale.createdAt = '2026-08-01T00:00:01.000Z';
      const local = new RemoteMessage();
      local.id = 'harmony-system-local';
      local.role = 'system';
      local.createdAt = '2026-08-01T00:00:02.000Z';
      const streaming = new RemoteMessage();
      streaming.id = 'streaming';
      streaming.role = 'assistant';
      streaming.isStreaming = true;
      streaming.createdAt = '2026-08-01T00:00:03.000Z';
      const result = reconcileLatestMessageWindow([stale, local, streaming], [], false, null, false);
      expect(result.items.length).assertEqual(2);
      expect(result.items[0].id).assertEqual(local.id);
      expect(result.items[1].id).assertEqual(streaming.id);
      expect(result.coverage === null).assertEqual(true);
    });

    it('establishesCoverageWhenLoadingOlderWithoutPreviousCoverage', 0, () => {
      const older = new RemoteMessage();
      older.id = 'older';
      older.createdAt = '2026-08-01T00:00:01.000Z';
      const joinsAt = new RemoteMessage();
      joinsAt.id = 'join';
      joinsAt.createdAt = '2026-08-01T00:00:03.000Z';
      const coverage = extendCoverageEarlier(null, [older], joinsAt);
      expect(coverage !== null).assertEqual(true);
      expect(coverage?.since).assertEqual(Date.parse(older.createdAt));
      expect(coverage?.until).assertEqual(Date.parse(joinsAt.createdAt));
    });

    it('preservesPendingLocalCreationAcrossAuthoritativeSessionPatch', 0, () => {
      const store = new TaskStore();
      const session = new RemoteSession();
      session.id = 'pending-session';
      session.pendingLocalCreation = true;
      store.upsertSession('device-1', session);
      const patch: Record<string, Object> = {};
      patch['title'] = 'Authoritative title';
      const payload: Record<string, Object> = {};
      payload['sessionId'] = session.id;
      payload['patch'] = patch;
      store.handleSessionsPush('device-1', DlChannels.SESSIONS_PATCHED, payload);
      const updated = store.getSessions('device-1')[0];
      expect(updated.title).assertEqual('Authoritative title');
      expect(updated.pendingLocalCreation).assertEqual(true);
    });

    it('keepsCreatedSessionInTheListWhenStartingPostCreateReconciliation', 0, () => {
      const store = new TaskStore();
      const session = new RemoteSession();
      session.id = 'new-project-session';
      session.workspaceKind = 'project';
      session.workingDir = '/workspace/cindy';
      session.pendingLocalCreation = true;
      store.upsertSession('device-1', session);

      // 未 attach client 时列表刷新会安全失败；成功收口仍必须保留本地行并解除创建锁。
      store.completeLocalCreation('device-1', session.id);

      const sessions = store.getSessions('device-1');
      expect(sessions.length).assertEqual(1);
      expect(sessions[0].id).assertEqual(session.id);
      expect(sessions[0].pendingLocalCreation).assertEqual(false);
    });

    it('roundTripsAWhitelistedTaskListStartupSnapshot', 0, () => {
      const device = new CachedTaskListDevice();
      device.deviceId = 'desktop-1';
      device.deviceName = 'Office Mac';
      const session = new RemoteSession();
      session.id = 'session-1';
      session.title = 'A'.repeat(300);
      session.workingDir = '/workspace/cindy';
      session.status = 'active';
      session.agentKind = 'codex';
      session.createdAt = '2026-08-10T01:00:00.000Z';
      session.updatedAt = '2026-08-10T02:00:00.000Z';
      session.preview = 'cached preview';
      device.sessions = [session];

      const serialized = serializeTaskListSnapshot('account-1', [device]);
      expect(serialized !== null && serialized.length > 0).assertEqual(true);
      const restored = parseTaskListSnapshot(serialized ?? '', 'account-1');
      expect(restored.length).assertEqual(1);
      expect(restored[0].deviceId).assertEqual('desktop-1');
      expect(restored[0].sessions.length).assertEqual(1);
      expect(restored[0].sessions[0].title.length).assertEqual(240);
      expect(restored[0].sessions[0].workingDir).assertEqual('/workspace/cindy');
      expect(restored[0].sessions[0].preview).assertEqual('cached preview');
      expect(parseTaskListSnapshot(serialized ?? '', 'account-2').length).assertEqual(0);
    });

    it('showsCachedTasksImmediatelyButLetsTheServerRemoveGhostDevices', 0, () => {
      const cached = new CachedTaskListDevice();
      cached.deviceId = 'desktop-stale';
      cached.deviceName = 'Last known desktop';
      const session = new RemoteSession();
      session.id = 'cached-session';
      session.status = 'active';
      session.createdAt = '2026-08-10T01:00:00.000Z';
      cached.sessions = [session];
      const store = new TaskStore();

      store.hydrateTaskListSnapshot([cached]);
      expect(store.deviceList.length).assertEqual(1);
      expect(store.deviceList[0].online).assertEqual(false);
      expect(store.getSessions('desktop-stale').length).assertEqual(1);

      store.mergeServerDevices([]);
      expect(store.deviceList.length).assertEqual(0);
      expect(store.getSessions('desktop-stale').length).assertEqual(0);
    });

    it('keepsCachedSessionsVisibleWhileAKnownDeviceIsBeingRevalidated', 0, () => {
      const cached = new CachedTaskListDevice();
      cached.deviceId = 'desktop-1';
      const session = new RemoteSession();
      session.id = 'cached-session';
      session.status = 'active';
      session.createdAt = '2026-08-10T01:00:00.000Z';
      cached.sessions = [session];
      const store = new TaskStore();
      store.hydrateTaskListSnapshot([cached]);

      const live = new DeviceView();
      live.deviceId = 'desktop-1';
      live.name = 'Live desktop';
      live.platform = 'darwin';
      live.online = true;
      live.remoteControlEnabled = true;
      store.mergeServerDevices([live]);

      expect(store.deviceList[0].online).assertEqual(true);
      expect(store.getSessions('desktop-1')[0].id).assertEqual('cached-session');
    });

    it('anchorsStreamingFollowToTheRealListTailAndRetriesAfterLayout', 0, () => {
      expect(messageListBottomIndex(true, 3, true, true, 2)).assertEqual(8);
      expect(messageListBottomIndex(false, 3, false, false, 0)).assertEqual(3);
      expect(firstVisibleMessageRenderIndex(true, 0, 12)).assertEqual(0);
      expect(firstVisibleMessageRenderIndex(true, 8, 12)).assertEqual(7);
      expect(firstVisibleMessageRenderIndex(false, 8, 12)).assertEqual(8);
      expect(firstVisibleMessageRenderIndex(true, 20, 12)).assertEqual(11);
      expect(firstVisibleMessageRenderIndex(true, 0, 0)).assertEqual(-1);
      expect(FOLLOW_LATEST_RETRY_DELAYS.length).assertEqual(3);
      expect(FOLLOW_LATEST_RETRY_DELAYS[0] < FOLLOW_LATEST_RETRY_DELAYS[1]).assertEqual(true);
      expect(FOLLOW_LATEST_RETRY_DELAYS[1] < FOLLOW_LATEST_RETRY_DELAYS[2]).assertEqual(true);
    });

    it('autofillsShortHistoryThenKeepsPrefetchingForRealUserReview', 0, () => {
      expect(INITIAL_HISTORY_AUTOFILL_PAGES).assertEqual(3);
      expect(shouldAutoLoadEarlier(
        false, 3, true, true, false, false, true, true, 2, 'first-1', '',
      )).assertEqual(true);
      expect(shouldAutoLoadEarlier(
        false, 0, true, true, false, false, true, true, 2, 'first-1', '',
      )).assertEqual(false);
      expect(shouldAutoLoadEarlier(
        false, 3, false, true, false, false, true, true, 2, 'first-1', '',
      )).assertEqual(false);
      expect(shouldAutoLoadEarlier(
        true, 0, false, true, false, false, true, true, 2, 'first-2', '',
      )).assertEqual(true);
      expect(shouldAutoLoadEarlier(
        true, 0, false, true, false, false, true, true, 2, 'first-2', 'first-2',
      )).assertEqual(false);
      expect(shouldAutoLoadEarlier(
        true, 0, false, true, false, true, true, true, 2, 'first-3', '',
      )).assertEqual(false);
    });

    it('rejectsUnknownImageSchemesAndNormalizesSupportedCase', 0, () => {
      const tokens = tokenizeInline('![local](../screen.png) ![remote](HTTPS://example.com/a.png) <IMG SRC="XDT-IMAGE://art/a.png">');
      const urls: string[] = [];
      for (let i = 0; i < tokens.length; i++) {
        if (tokens[i].kind === 'image') urls.push(tokens[i].url);
      }
      expect(urls.length).assertEqual(3);
      expect(urls[1]).assertEqual('https://example.com/a.png');
      expect(urls[2]).assertEqual('xdt-image://art/a.png');

      const unsupported = tokenizeInline('![bad](mailto:test@example.com) <img src="custom://image">');
      let unsupportedImageCount = 0;
      let text = '';
      for (let i = 0; i < unsupported.length; i++) {
        if (unsupported[i].kind === 'image') unsupportedImageCount += 1;
        text += unsupported[i].value;
      }
      expect(unsupportedImageCount).assertEqual(0);
      expect(text.includes('mailto:test@example.com')).assertEqual(true);
      expect(text.includes('custom://image')).assertEqual(true);
    });

    it('rendersInlineBase64ImagesFromPersistedContent', 0, () => {
      const message = new RemoteMessage();
      message.id = 'user-base64';
      message.role = 'user';
      const content: Record<string, Object> = {};
      content['text'] = '查看内联图';
      const image: Record<string, Object> = {};
      image['base64'] = 'AQI=';
      image['mimeType'] = 'image/png';
      image['name'] = 'inline.png';
      content['images'] = [image];
      message.content = content;

      const items = buildRenderItems([message]);
      const rendered = items[0] as RenderMessageItem;
      expect(rendered.images.length).assertEqual(1);
      expect(rendered.images[0].url).assertEqual('data:image/png;base64,AQI=');
      expect(rendered.images[0].originalName).assertEqual('inline.png');
    });

    it('closesRunningProjectionForActivityAndStatusBoundaries', 0, () => {
      const store = new MessageStore();
      let runningTransitions = 0;
      const unsubscribe = store.onRunningStateChanged(() => {
        runningTransitions += 1;
      });
      const textData: Record<string, Object> = {};
      textData['text'] = '正在运行';
      const textEvent: Record<string, Object> = {};
      textEvent['type'] = 'text';
      textEvent['data'] = textData;
      store.handleMakerEvent('run-1', textEvent);
      expect(store.isSessionStreaming('run-1')).assertEqual(true);
      expect(store.isSessionRunning('run-1')).assertEqual(true);
      expect(runningTransitions).assertEqual(1);

      store.handleMakerEvent('run-1', textEvent);
      expect(runningTransitions).assertEqual(1);

      const completed: Record<string, Object> = {};
      completed['sessionId'] = 'run-1';
      completed['phase'] = 'completed';
      completed['isRunning'] = true;
      store.handleSessionActivity(completed);
      expect(store.isSessionStreaming('run-1')).assertEqual(false);
      expect(store.isSessionRunning('run-1')).assertEqual(false);
      expect(runningTransitions).assertEqual(2);

      const continuedStatusData: Record<string, Object> = {};
      continuedStatusData['isRunning'] = false;
      const continuedStatus: Record<string, Object> = {};
      continuedStatus['type'] = 'status';
      continuedStatus['data'] = continuedStatusData;
      continuedStatus['turnContinuationId'] = 1;
      store.handleMakerEvent('run-1', continuedStatus);
      expect(store.isSessionStreaming('run-1')).assertEqual(true);
      expect(runningTransitions).assertEqual(3);

      const continuedDone: Record<string, Object> = {};
      continuedDone['type'] = 'done';
      continuedDone['turnContinuationId'] = 1;
      store.handleMakerEvent('run-1', continuedDone);
      expect(store.isSessionStreaming('run-1')).assertEqual(true);

      const finalDone: Record<string, Object> = {};
      finalDone['type'] = 'done';
      store.handleMakerEvent('run-1', finalDone);
      expect(store.isSessionStreaming('run-1')).assertEqual(false);
      expect(runningTransitions).assertEqual(4);

      const reopenedData: Record<string, Object> = {};
      reopenedData['text'] = '再次运行';
      const reopened: Record<string, Object> = {};
      reopened['type'] = 'text';
      reopened['data'] = reopenedData;
      store.handleMakerEvent('run-1', reopened);
      const statusClosed: Record<string, Object> = {};
      statusClosed['sessionId'] = 'run-1';
      statusClosed['status'] = 'closed';
      store.handleMakerStatusChanged(statusClosed);
      expect(store.isSessionStreaming('run-1')).assertEqual(false);
      expect(runningTransitions).assertEqual(6);
      unsubscribe();
    });

    it('surfacesManagedToolResultImagesOutsideWorkGroup', 0, () => {
      const user = new RemoteMessage();
      user.id = 'user-media';
      user.role = 'user';
      user.content = '生成截图';

      const tool = new RemoteMessage();
      tool.id = 'tool-media';
      tool.role = 'tool_use';
      tool.toolUseId = 'use-media';
      const toolContent: Record<string, Object> = {};
      toolContent['toolUseId'] = 'use-media';
      toolContent['toolName'] = 'image_generate';
      toolContent['input'] = '{}';
      tool.content = toolContent;

      const result = new RemoteMessage();
      result.id = 'result-media';
      result.role = 'tool_result';
      result.toolUseId = 'use-media';
      result.content = JSON.stringify({
        xdt_image_urls: ['xdt-image://art/a.png', 'cindy-media://blobs/b.png'],
      });

      const answer = new RemoteMessage();
      answer.id = 'answer-media';
      answer.role = 'assistant';
      answer.content = '已生成';

      const items = buildRenderItems([user, tool, result, answer]);
      let media: RenderToolMediaItem | undefined = undefined;
      for (let i = 0; i < items.length; i++) {
        if (items[i].type === 'tool_media') media = items[i] as RenderToolMediaItem;
      }
      expect(media !== undefined).assertEqual(true);
      expect(media?.images.length).assertEqual(2);
      expect(media?.images[0].url).assertEqual('xdt-image://art/a.png');
    });

    it('settlesUnfinishedToolsOutsideTheActiveTail', 0, () => {
      const firstUser = new RemoteMessage();
      firstUser.id = 'user-1';
      firstUser.role = 'user';
      firstUser.content = 'first turn';

      const oldTool = new RemoteMessage();
      oldTool.id = 'tool-old';
      oldTool.role = 'tool_use';
      const oldToolContent: Record<string, Object> = {};
      oldToolContent['toolUseId'] = 'old-use';
      oldToolContent['toolName'] = 'Read';
      oldTool.content = oldToolContent;

      const secondUser = new RemoteMessage();
      secondUser.id = 'user-2';
      secondUser.role = 'user';
      secondUser.content = 'second turn';

      const activeTool = new RemoteMessage();
      activeTool.id = 'tool-active';
      activeTool.role = 'tool_use';
      const activeToolContent: Record<string, Object> = {};
      activeToolContent['toolUseId'] = 'active-use';
      activeToolContent['toolName'] = 'Bash';
      activeTool.content = activeToolContent;

      const items = buildRenderItems([firstUser, oldTool, secondUser, activeTool], true);
      const oldWork = items[1] as RenderWorkGroupItem;
      const activeWork = items[3] as RenderWorkGroupItem;
      const oldGroup = oldWork.children[0] as RenderToolGroupItem;
      const activeGroup = activeWork.children[0] as RenderToolGroupItem;

      expect(oldGroup.tools[0].hasResult).assertEqual(true);
      expect(activeGroup.tools[0].hasResult).assertEqual(false);
      expect(activeWork.isStreaming).assertEqual(true);
    });

    it('parsesComposerContextSessionAndGoalState', 0, () => {
      const rawSession: Record<string, Object> = {};
      rawSession['id'] = 'session-1';
      rawSession['planModeEnabled'] = true;
      const session = parseSession(rawSession);

      const rawGoal: Record<string, Object> = {};
      rawGoal['sessionId'] = 'session-1';
      rawGoal['status'] = 'active';
      rawGoal['objective'] = 'Finish the Harmony composer';
      rawGoal['turnsUsed'] = 4;
      rawGoal['tokensUsed'] = 1200;
      rawGoal['maxTurns'] = 12;
      rawGoal['noProgressLimit'] = 3;
      const goal = parseGoalModeState(rawGoal);

      expect(session.planModeEnabled).assertEqual(true);
      expect(goal?.currentTurns).assertEqual(4);
      expect(goal?.cumulativeTokens).assertEqual(1200);
      expect(goal?.maxTurns).assertEqual(12);
      expect(goal?.budgetTokens).assertEqual(-1);
    });

    it('usesMediumWidthSplitLayoutAndClampsDrag', 0, () => {
      expect(isWideTaskLayout(639, 400)).assertEqual(false);
      expect(isWideTaskLayout(640, 400)).assertEqual(true);
      expect(isWideTaskLayout(900, 1200, TASK_FOLD_STATUS_EXPANDED)).assertEqual(false);
      expect(isWideTaskLayout(1200, 900, TASK_FOLD_STATUS_EXPANDED)).assertEqual(true);
      expect(isWideTaskLayout(1200, 900, TASK_FOLD_STATUS_FOLDED)).assertEqual(false);
      expect(isWideTaskLayout(1200, 900, TASK_FOLD_STATUS_HALF_FOLDED)).assertEqual(false);
      expect(isWideTaskLayout(1200, 900, 0)).assertEqual(false);
      expect(taskListPaneWidth(900, TASK_SPLIT_DEFAULT_RATIO)).assertEqual(300);
      expect(taskListPaneWidth(640, TASK_SPLIT_DEFAULT_RATIO)).assertEqual(300);
      expect(taskDetailPaneWidth(900, TASK_SPLIT_DEFAULT_RATIO)).assertEqual(580);
      expect(taskDetailPaneWidth(640, TASK_SPLIT_DEFAULT_RATIO)).assertEqual(320);
      expect(taskListPaneWidth(1200, 0.4)
        + 20
        + taskDetailPaneWidth(1200, 0.4)).assertEqual(1200);
      expect(taskDetailKeyboardInset(639, 400, -1, 320)).assertEqual(0);
      expect(taskDetailKeyboardInset(900, 600, -1, 320)).assertEqual(320);
      expect(taskDetailKeyboardInset(640, 900, -1, 320)).assertEqual(0);
      expect(taskDetailKeyboardInset(900, 600, TASK_FOLD_STATUS_FOLDED, 320)).assertEqual(0);
      expect(taskDetailKeyboardInset(900, 600, -1, -1)).assertEqual(0);

      const dragged = taskSplitRatioForDrag(900, TASK_SPLIT_DEFAULT_RATIO, 200);
      expect(dragged > 0.55 && dragged <= 0.6).assertEqual(true);
      expect(taskSplitRatioForDrag(900, TASK_SPLIT_DEFAULT_RATIO, -500)).assertEqual(0.25);
    });

    it('handsCurrentTaskBackToSplitLayoutOnlyOnce', 0, () => {
      handoffTaskSplitRouteSelection('device-1', 'session-1', 'message-1');
      const selection = consumeTaskSplitRouteSelection();
      expect(selection?.deviceId).assertEqual('device-1');
      expect(selection?.sessionId).assertEqual('session-1');
      expect(selection?.messageClientId).assertEqual('message-1');
      expect(consumeTaskSplitRouteSelection()).assertNull();
    });

    it('projectsTaskListCopyAndRelativeTimeLikeMobile', 0, () => {
      const session = new RemoteSession();
      session.title = 'New Maker';
      session.status = 'active';
      expect(taskDisplayTitle(session)).assertEqual('未命名任务');
      expect(taskPreviewText('  first\n  second  ')).assertEqual('first second');
      expect(taskProjectName('C:\\work\\cindy-harmony\\')).assertEqual('cindy-harmony');
      expect(taskProjectName('C:\\work\\cindy-harmony\\.cindy-worktrees\\feature-one')).assertEqual('cindy-harmony');
      expect(taskProjectName('/work/app/.claude/worktrees/feature-two')).assertEqual('app');
      expect(taskProjectKey('device-1', 'C:\\Work\\App\\')).assertEqual('device-1:c:/work/app');

      session.userSendAt = '2026-08-01T10:00:00.000Z';
      session.updatedAt = '2026-08-01T11:00:00.000Z';
      expect(taskActivityAt(session)).assertEqual('2026-08-01T10:00:00.000Z');

      const now = Date.parse('2026-08-01T12:00:00.000Z');
      expect(taskRelativeTime('2026-08-01T11:59:45.000Z', now)).assertEqual('刚刚');
      expect(taskRelativeTime('2026-08-01T11:35:00.000Z', now)).assertEqual('25 分钟');
      expect(taskRelativeTime('2026-07-30T12:00:00.000Z', now)).assertEqual('2 天');
      expect(taskVisibleOnHome(session)).assertEqual(true);
      session.orcaRole = 'worker';
      expect(taskVisibleOnHome(session)).assertEqual(false);
    });

    it('keepsTaskListRunningAheadOfStaleCompletedAttention', 0, () => {
      expect(resolveTaskRightStatus('completed', true, 0, true)).assertEqual('running');
      expect(resolveTaskRightStatus('completed', true, 0, false)).assertEqual('done');
      expect(resolveTaskRightStatus('error', true, 0, true)).assertEqual('error');
      expect(resolveTaskRightStatus('completed', true, 1, true)).assertEqual('waiting');
    });

    it('rebuildsTaskListRowsWhenVisibleSessionStateChanges', 0, () => {
      const session = new RemoteSession();
      session.id = 'session-stable-id';
      session.title = '旧标题';
      session.preview = '正在检查';
      session.agentKind = 'codex';
      session.status = 'active';
      session.updatedAt = '2026-08-17T08:00:00.000Z';

      const original = taskListEntryPresentationState(session, 'running');
      expect(taskListEntryPresentationState(session, 'running')).assertEqual(original);

      session.title = '绘画已经完成';
      const renamed = taskListEntryPresentationState(session, 'running');
      expect(renamed === original).assertEqual(false);

      session.preview = '已完成绘画';
      const previewUpdated = taskListEntryPresentationState(session, 'running');
      expect(previewUpdated === renamed).assertEqual(false);

      const completed = taskListEntryPresentationState(session, 'time');
      expect(completed === previewUpdated).assertEqual(false);
      expect(session.id).assertEqual('session-stable-id');
    });

    it('classifiesTaskListCategoriesWithAutomationPriority', 0, () => {
      const project = new RemoteSession();
      project.title = 'Build Harmony';
      project.workspaceKind = 'project';
      project.workingDir = '/work/cindy-harmony';
      expect(taskListCategory(project)).assertEqual('projects');

      const dialogue = new RemoteSession();
      dialogue.title = 'Quick question';
      dialogue.workspaceKind = 'dialogue';
      dialogue.workingDir = '/tmp/assigned';
      expect(taskListCategory(dialogue)).assertEqual('dialogues');

      const emptyWorkspace = new RemoteSession();
      emptyWorkspace.title = 'No workspace';
      emptyWorkspace.workspaceKind = 'project';
      emptyWorkspace.workingDir = '';
      expect(taskListCategory(emptyWorkspace)).assertEqual('dialogues');

      const scheduler = new RemoteSession();
      scheduler.title = 'Daily check';
      scheduler.source = 'scheduler';
      scheduler.workspaceKind = 'project';
      scheduler.workingDir = '/work/cindy-harmony';
      expect(taskIsAutomation(scheduler)).assertEqual(true);
      expect(taskListCategory(scheduler)).assertEqual('automations');

      const legacySchedule = new RemoteSession();
      legacySchedule.title = '[Schedule] Weekly report';
      legacySchedule.workspaceKind = 'dialogue';
      legacySchedule.workingDir = '';
      expect(taskIsAutomation(legacySchedule)).assertEqual(true);
      expect(taskListCategory(legacySchedule)).assertEqual('automations');

      const archived = new RemoteSession();
      archived.status = 'archived';
      expect(taskVisibleInTaskList(archived, false)).assertEqual(false);
      expect(taskVisibleInTaskList(archived, true)).assertEqual(true);
      archived.status = 'deleted';
      expect(taskVisibleInTaskList(archived, true)).assertEqual(false);
    });

    it('sortsTaskListByRecencyAlphabetAndSourceDefault', 0, () => {
      const alpha = new RemoteSession();
      alpha.id = 'alpha';
      alpha.title = 'alpha 任务';
      alpha.userSendAt = '2026-08-01T10:00:00.000Z';
      const bravo = new RemoteSession();
      bravo.id = 'bravo';
      bravo.title = 'Bravo 任务';
      bravo.userSendAt = '2026-08-01T11:00:00.000Z';

      const recent = [alpha, bravo];
      recent.sort((left: RemoteSession, right: RemoteSession) =>
        compareTaskSessionsForList(left, right, 'recency'));
      expect(recent[0].id).assertEqual('bravo');
      expect(recent[1].id).assertEqual('alpha');

      const alphabetic = [bravo, alpha];
      alphabetic.sort((left: RemoteSession, right: RemoteSession) =>
        compareTaskSessionsForList(left, right, 'alphabetic'));
      expect(alphabetic[0].id).assertEqual('alpha');
      expect(alphabetic[1].id).assertEqual('bravo');
      expect(compareTaskListLabels('alpha', 'Bravo') < 0).assertEqual(true);

      // 默认排序不施加客户端比较，调用方可保留被控端提供的原始稳定顺序。
      expect(compareTaskSessionsForList(bravo, alpha, 'default')).assertEqual(0);
    });

    it('persistsAutomationCategoryAndDropsLegacyFilters', 0, () => {
      const preferences = new TaskListPreferences();
      preferences.activeListTab = 'automations';
      preferences.sortMode = 'alphabetic';
      preferences.searchQuery = '巡检';
      const serialized = serializeTaskListPreferences(preferences);
      const roundTrip = parseTaskListPreferences(serialized);
      expect(roundTrip.activeListTab).assertEqual('automations');
      expect(roundTrip.sortMode).assertEqual('alphabetic');
      expect(roundTrip.searchQuery).assertEqual('巡检');

      const invalidSort = parseTaskListPreferences(JSON.stringify({ sortMode: 'unknown' }));
      expect(invalidSort.sortMode).assertEqual('recency');
      expect(serializeTaskListPreferences(new TaskListPreferences()).indexOf('sortMode')).assertEqual(-1);

      const legacy = parseTaskListPreferences(JSON.stringify({
        activeListTab: 'dialogues',
        statusFilter: 'automation',
        projectFilterKeys: ['device:/work/app'],
        agentFilter: 'codex',
        activityFilter: '7d',
      }));
      expect(legacy.activeListTab).assertEqual('automations');
      const migrated = serializeTaskListPreferences(legacy);
      expect(migrated.indexOf('statusFilter')).assertEqual(-1);
      expect(migrated.indexOf('projectFilterKeys')).assertEqual(-1);
      expect(migrated.indexOf('agentFilter')).assertEqual(-1);
      expect(migrated.indexOf('activityFilter')).assertEqual(-1);
    });

    it('rejectsFailedInvokeResultsBeforeMarkingTopicSubscribed', 0, () => {
      const okEnvelope = new Envelope();
      const okPayload: Record<string, Object> = {};
      okPayload['ok'] = true;
      okEnvelope.payload = okPayload;
      assertInvokeSucceeded(okEnvelope);

      const failedEnvelope = new Envelope();
      const failedPayload: Record<string, Object> = {};
      failedPayload['ok'] = false;
      const error: Record<string, Object> = {};
      error['code'] = 'REMOTE_DISABLED';
      error['message'] = 'remote control disabled';
      failedPayload['error'] = error;
      failedEnvelope.payload = failedPayload;
      let rejected = false;
      try {
        assertInvokeSucceeded(failedEnvelope);
      } catch (caught) {
        rejected = caught instanceof DlError
          && caught.code === 'REMOTE_DISABLED'
          && caught.message === 'remote control disabled';
      }
      expect(rejected).assertEqual(true);
    });

    it('onlyAutoRetriesConnectionErrorsThatWereNotSent', 0, () => {
      expect(isSafeUnsentDlError(new DlError('NOT_CONNECTED', 'offline'))).assertEqual(true);
      expect(isSafeUnsentDlError(new DlError('BACKPRESSURE', 'busy'))).assertEqual(true);
      expect(isSafeUnsentDlError(new DlError('NOT_CONNECTED', 'ack lost', true))).assertEqual(false);
      expect(isSafeUnsentDlError(new DlError('INVOKE_TIMEOUT', 'timeout', true))).assertEqual(false);
    });

    it('keepsCancelledCodexPlansAliveAndSealsSuccessfulOnes', 0, () => {
      const step: Record<string, Object> = {};
      step['step'] = '同步鸿蒙';
      step['status'] = 'in_progress';
      const input: Record<string, Object> = {};
      input['plan'] = [step];
      const cancelled = planToolMessage('cancelled-plan', 'update_plan', input, 'plan:turn-cancelled');
      applyCodexPlanSnapshotOnDone(
        [cancelled], [step], 'turn-cancelled', 'completed', 100, true);
      expect(planRowSealed(cancelled)).assertEqual(false);
      expect(planRowTurnFailed(cancelled)).assertEqual(true);

      const successful = planToolMessage('successful-plan', 'update_plan', input, 'plan:turn-success');
      applyCodexPlanSnapshotOnDone(
        [successful], [step], 'turn-success', 'completed', 200, false);
      expect(planRowSealed(successful)).assertEqual(true);
      expect(successful.terminalPlanAtMs).assertEqual(200);
    });

    it('keepsExplicitFailedPlanStampAheadOfLegacyTurnUsageSeal', 0, () => {
      const raw: Record<string, Object> = {};
      raw['role'] = 'tool_use';
      const content: Record<string, Object> = {};
      content['turnCompleted'] = false;
      raw['content'] = content;
      const agentMeta: Record<string, Object> = {};
      const usage: Record<string, Object> = {};
      usage['inputTokens'] = 1;
      agentMeta['turnUsageDetails'] = usage;
      raw['agentMeta'] = agentMeta;
      const parsed = parseMessage(raw);
      expect(parsed.hasTurnCompleted).assertEqual(true);
      expect(parsed.turnCompleted).assertEqual(false);
      expect(planRowTurnFailed(parsed)).assertEqual(true);
    });

    it('stampsOnlyTheCurrentCodexPlanAcrossSteerRows', 0, () => {
      const step: Record<string, Object> = {};
      step['step'] = '继续排查';
      step['status'] = 'in_progress';
      const input: Record<string, Object> = {};
      input['plan'] = [step];
      const oldPlan = planToolMessage('old-plan', 'update_plan', input, 'plan:old');
      const boundary = userBoundary('new-turn');
      const currentPlan = planToolMessage('current-plan', 'update_plan', input, 'plan:current');
      const steer = userBoundary('steer');
      steer.agentMeta['delivery'] = 'steer';
      const messages = [oldPlan, boundary, currentPlan, steer];
      expect(markCodexPlanTurnFailed(messages)).assertEqual(true);
      expect(planRowTurnFailed(currentPlan)).assertEqual(true);
      expect(planRowTurnFailed(oldPlan)).assertEqual(false);
    });

    it('usesTerminalPlanSealsAsHardPlanSessionBoundaries', 0, () => {
      const step: Record<string, Object> = {};
      step['step'] = '未勾完但本轮成功';
      step['status'] = 'pending';
      const input: Record<string, Object> = {};
      input['plan'] = [step];
      const first = planToolMessage('sealed-plan', 'update_plan', input, 'plan:first');
      first.terminalPlanSnapshot = true;
      const second = planToolMessage('next-plan', 'update_plan', input, 'plan:second');
      expect(findTodoPlanInsertions([first, second]).size).assertEqual(2);
    });

    it('distinguishesSubagentLaunchReceiptsFromRealTerminalResults', 0, () => {
      const spawnInput: Record<string, Object> = {};
      spawnInput['name'] = 'reviewer';
      expect(deriveAgentTaskStatus(
        'running', 'collab:spawn', JSON.stringify(spawnInput), 'reviewer')).assertEqual('running');
      expect(deriveAgentTaskStatus(
        'running', 'Agent', '{}', 'Async agent launched successfully.')).assertEqual('running');
      expect(deriveAgentTaskStatus(
        'running', 'collab:spawnAgent', '{}', 'reviewer: active')).assertEqual('running');
      expect(deriveAgentTaskStatus(
        'running', 'collab:spawnAgent', '{}', 'reviewer: completed')).assertEqual('completed');
      expect(deriveAgentTaskStatus(
        'failed', 'collab:spawnAgent', '{}', 'reviewer: completed')).assertEqual('failed');
    });

    it('deduplicatesLegacyDefaultAndAskPermissionModes', 0, () => {
      const rows: Object[] = ['default', 'ask', 'ask', 'plan', 'acceptEdits'];
      const options = parseChoiceOptions(rows, true);
      expect(options.length).assertEqual(2);
      expect(options[0].id).assertEqual('ask');
      expect(options[1].id).assertEqual('acceptEdits');
      expect(selectedPermissionModeLabel(options, 'acceptEdits')).assertEqual('自动接受编辑');
      expect(selectedPermissionModeLabel(options, 'auto')).assertEqual('自动');
      expect(selectedPermissionModeLabel(options, '')).assertEqual('权限模式');
    });

    it('reconcilesEffortWhenSwitchingComposerModels', 0, () => {
      const rawModel: Record<string, Object> = {};
      rawModel['id'] = 'model-a';
      rawModel['efforts'] = ['medium', 'high'];
      rawModel['defaultEffort'] = 'high';
      const model = parseModelOptions([rawModel])[0];
      expect(reconcileModelEffort(model, 'medium')).assertEqual('medium');
      expect(reconcileModelEffort(model, 'low')).assertEqual('high');

      const rawNoEffortModel: Record<string, Object> = {};
      rawNoEffortModel['id'] = 'model-b';
      const noEffortModel = parseModelOptions([rawNoEffortModel])[0];
      expect(reconcileModelEffort(noEffortModel, 'high')).assertEqual('');
    });

    it('parsesSharedComposerModelsForNewAndExistingTasks', 0, () => {
      const fallbackModel: Record<string, Object> = {};
      fallbackModel['id'] = 'gpt-test';
      fallbackModel['displayName'] = 'GPT Test';
      fallbackModel['defaultEffort'] = 'high';
      fallbackModel['supportsFastMode'] = true;
      fallbackModel['efforts'] = ['medium', 'high'];
      const fallback = parseModelOptions([fallbackModel]);
      expect(fallback.length).assertEqual(1);
      expect(fallback[0].label).assertEqual('GPT Test');
      expect(fallback[0].defaultEffort).assertEqual('high');
      expect(fallback[0].supportsFastMode).assertEqual(true);

      const model: Record<string, Object> = {};
      model['id'] = 'gpt-test';
      model['name'] = 'Provider GPT';
      model['defaultEnabled'] = false;
      const models: Record<string, Object> = {};
      models['codex'] = [model];
      const provider: Record<string, Object> = {};
      provider['id'] = 'provider-a';
      provider['name'] = 'Provider A';
      provider['connected'] = true;
      provider['agents'] = ['codex'];
      provider['models'] = models;
      const overrides: Record<string, Object> = {};
      overrides['codex:provider-a:gpt-test'] = false;
      const response: Record<string, Object> = {};
      response['providers'] = [provider];
      response['modelVisibilityOverrides'] = overrides;
      const visibility = parseModelVisibilityOverrides(response);
      expect(parseProviderModelOptions(response, 'codex', visibility, undefined).length).assertEqual(0);
      const selected = parseProviderModelOptions(response, 'codex', visibility,
        { model: 'gpt-test', providerId: 'provider-a' });
      expect(selected.length).assertEqual(1);
      expect(selected[0].providerId).assertEqual('provider-a');
    });

    it('backsOffTaskListAntiEntropyPerDeviceAndResetsAfterSuccess', 0, () => {
      const backoff = new TaskListReconcileBackoff();
      const start = 1_000;
      backoff.report('desktop-a', false, start, 0.5);
      expect(backoff.shouldAttempt('desktop-a', start + TASK_LIST_RECONCILE_INTERVAL_MS - 1))
        .assertEqual(false);
      expect(backoff.shouldAttempt('desktop-b', start)).assertEqual(true);
      expect(backoff.shouldAttempt('desktop-a', start + TASK_LIST_RECONCILE_INTERVAL_MS))
        .assertEqual(true);

      backoff.report('desktop-a', false, start + TASK_LIST_RECONCILE_INTERVAL_MS, 0.5);
      expect(backoff.shouldAttempt('desktop-a', start + TASK_LIST_RECONCILE_INTERVAL_MS * 3 - 1))
        .assertEqual(false);
      backoff.report('desktop-a', true, start + TASK_LIST_RECONCILE_INTERVAL_MS * 3, 0.5);
      expect(backoff.shouldAttempt('desktop-a', start + TASK_LIST_RECONCILE_INTERVAL_MS * 3))
        .assertEqual(true);
    });
  });
}
