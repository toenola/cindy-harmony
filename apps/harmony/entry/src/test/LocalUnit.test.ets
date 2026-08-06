import { describe, it, expect } from '@ohos/hypium';
import { parseMessage, parseSession, RemoteMessage } from '../main/ets/core/tasks/TaskModels';
import { parseGoalModeState } from '../main/ets/core/goals/GoalModels';
import {
  shouldAutoCollapseUserMessage,
  collapsedUserMessageLineLimit,
  toolResultHasError,
  buildRenderItems,
  RenderToolGroupItem,
  RenderWorkGroupItem,
} from '../main/ets/core/messages/MessageRender';

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
  });
}
