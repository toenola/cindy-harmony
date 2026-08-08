import { describe, it, expect } from '@ohos/hypium';
import { parseMessage, parseSession, RemoteMessage, RemoteSession } from '../main/ets/core/tasks/TaskModels';
import { RemoteImageRef } from '../main/ets/core/attachments/AttachmentModels';
import { parseGoalModeState } from '../main/ets/core/goals/GoalModels';
import {
  shouldAutoCollapseUserMessage,
  collapsedUserMessageLineLimit,
  toolResultHasError,
  buildRenderItems,
  RenderToolGroupItem,
  RenderToolMediaItem,
  RenderWorkGroupItem,
  RenderMessageItem,
} from '../main/ets/core/messages/MessageRender';
import {
  buildAgentUserContent,
  buildPersistedUserContent,
  MessageStore,
} from '../main/ets/core/messages/MessageStore';
import {
  taskActivityAt,
  taskDisplayTitle,
  taskPreviewText,
  taskProjectKey,
  taskProjectName,
  taskRelativeTime,
  taskVisibleOnHome,
} from '../main/ets/pages/TaskListPresentation';
import {
  isWideTaskLayout,
  TASK_FOLD_STATUS_FOLDED,
  taskListPaneWidth,
  taskSplitRatioForDrag,
  TASK_SPLIT_DEFAULT_RATIO,
} from '../main/ets/pages/TaskSplitLayout';

import {
  tokenizeInline,
} from '../main/ets/core/messages/MarkdownParser';

export default function localUnitTest() {
  describe('harmonyMessageAlignment', () => {
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
      expect(toolResultHasError(plainFailure)).assertEqual(false);
      expect(toolResultHasError(normal)).assertEqual(false);
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
      const textData: Record<string, Object> = {};
      textData['text'] = '正在运行';
      const textEvent: Record<string, Object> = {};
      textEvent['type'] = 'text';
      textEvent['data'] = textData;
      store.handleMakerEvent('run-1', textEvent);
      expect(store.isSessionStreaming('run-1')).assertEqual(true);

      const completed: Record<string, Object> = {};
      completed['sessionId'] = 'run-1';
      completed['phase'] = 'completed';
      completed['isRunning'] = true;
      store.handleSessionActivity(completed);
      expect(store.isSessionStreaming('run-1')).assertEqual(false);

      const continuedStatusData: Record<string, Object> = {};
      continuedStatusData['isRunning'] = false;
      const continuedStatus: Record<string, Object> = {};
      continuedStatus['type'] = 'status';
      continuedStatus['data'] = continuedStatusData;
      continuedStatus['turnContinuationId'] = 1;
      store.handleMakerEvent('run-1', continuedStatus);
      expect(store.isSessionStreaming('run-1')).assertEqual(true);

      const continuedDone: Record<string, Object> = {};
      continuedDone['type'] = 'done';
      continuedDone['turnContinuationId'] = 1;
      store.handleMakerEvent('run-1', continuedDone);
      expect(store.isSessionStreaming('run-1')).assertEqual(true);

      const finalDone: Record<string, Object> = {};
      finalDone['type'] = 'done';
      store.handleMakerEvent('run-1', finalDone);
      expect(store.isSessionStreaming('run-1')).assertEqual(false);

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
      expect(isWideTaskLayout(599)).assertEqual(false);
      expect(isWideTaskLayout(600)).assertEqual(true);
      expect(isWideTaskLayout(900, TASK_FOLD_STATUS_FOLDED)).assertEqual(false);
      expect(taskListPaneWidth(900, TASK_SPLIT_DEFAULT_RATIO)).assertEqual(293);
      expect(taskListPaneWidth(600, TASK_SPLIT_DEFAULT_RATIO)).assertEqual(220);

      const dragged = taskSplitRatioForDrag(900, TASK_SPLIT_DEFAULT_RATIO, 200);
      expect(dragged > 0.55 && dragged <= 0.6).assertEqual(true);
      expect(taskSplitRatioForDrag(900, TASK_SPLIT_DEFAULT_RATIO, -500)).assertEqual(0.25);
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
  });
}
