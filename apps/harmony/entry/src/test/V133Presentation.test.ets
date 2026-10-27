import { describe, expect, it } from '@ohos/hypium';
import {
  buildRenderItems, RenderItem, RenderMessageItem, RenderSubagentGroupItem, RenderToolGroupItem, RenderToolItem,
  RenderWorkGroupItem,
} from '../main/ets/core/messages/MessageRender';
import { messageSourceBadges } from '../main/ets/core/messages/MessageSourcePresentation';
import { ProcessMediaRef, readToolProcessText } from '../main/ets/core/messages/ToolProcessMedia';
import { parseMessage, RemoteMessage } from '../main/ets/core/tasks/TaskModels';

function presentationRecord(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

function presentationMessage(id: string, role: string, content: Object, seconds: number,
  agentMeta: string = '{}'): RemoteMessage {
  const raw: Record<string, Object> = {};
  raw['id'] = id;
  raw['clientId'] = id;
  raw['sessionId'] = 'presentation-session';
  raw['role'] = role;
  raw['content'] = content;
  raw['agentMeta'] = presentationRecord(agentMeta);
  raw['createdAt'] = new Date(2000000 + seconds * 1000).toISOString();
  return parseMessage(raw);
}

function presentationToolUse(id: string, seconds: number, toolName: string = 'mcp__browser__screenshot'): RemoteMessage {
  const content: Record<string, Object> = {};
  content['toolUseId'] = id;
  content['toolName'] = toolName;
  content['input'] = presentationRecord('{}');
  return presentationMessage(id, 'tool_use', content, seconds);
}

function presentationToolResult(id: string, useId: string, text: string, seconds: number): RemoteMessage {
  const message = presentationMessage(id, 'tool_result', text, seconds);
  message.toolUseId = useId;
  return message;
}

function collectTools(items: RenderItem[], out: RenderToolItem[]): RenderToolItem[] {
  items.forEach((item: RenderItem) => {
    if (item.type === 'tool_group') (item as RenderToolGroupItem).tools.forEach((tool: RenderToolItem) => out.push(tool));
    else if (item.type === 'work_group') collectTools((item as RenderWorkGroupItem).children, out);
    else if (item.type === 'subagent_group') collectTools((item as RenderSubagentGroupItem).children, out);
  });
  return out;
}

function rootIds(items: RenderItem[]): string[] {
  return items.filter((item: RenderItem) => item.type === 'message').map((item: RenderItem) => item.key);
}

function workChildIds(items: RenderItem[]): string[] {
  const out: string[] = [];
  const visit = (list: RenderItem[]): void => {
    list.forEach((item: RenderItem) => {
      if (item.type === 'work_group') visit((item as RenderWorkGroupItem).children);
      else if (item.type === 'message') out.push(item.key);
    });
  };
  items.forEach((item: RenderItem) => {
    if (item.type === 'work_group') visit((item as RenderWorkGroupItem).children);
  });
  return out;
}

export default function v133PresentationTest(): void {
  describe('V133Presentation', () => {
    it('failed_sampling_attempt_folds_into_work_and_never_completes_a_turn', 0, () => {
      const failed = presentationMessage('failed', 'assistant', 'Partial answer that was retried', 2,
        '{"failedSamplingAttempt":{"threadId":"t","turnId":"u","attempt":1,"itemId":"i"},"turnCompleted":true}');
      expect(failed.failedSamplingAttempt).assertTrue();
      expect(failed.turnCompleted).assertFalse();
      const items = buildRenderItems([
        presentationMessage('user', 'user', 'Explain', 0), presentationMessage('thought', 'thinking', 'Plan', 1),
        failed, presentationMessage('final', 'assistant', 'Complete answer', 4, '{"turnCompleted":true}'),
      ]);
      // 失败草稿不能和最终回答并列出现，看起来像回答了两遍。
      expect(rootIds(items).indexOf('failed')).assertEqual(-1);
      expect(workChildIds(items).indexOf('failed') >= 0).assertTrue();
      const finalItem = items.find((item: RenderItem) => item.key === 'final') as RenderMessageItem;
      expect(finalItem.isTurnFinalAssistant).assertTrue();
      // 普通进度旁白（未被标记失败）仍按原规则处理，不受影响。
      const user = presentationMessage('assistant-user', 'user', 'x', 0);
      expect(user.failedSamplingAttempt).assertFalse();
    });

    it('tool_process_media_stays_in_its_step_and_unwraps_the_display_text', 0, () => {
      const blob = `cindy-media://blobs/${'a'.repeat(64)}.png`;
      const envelope = JSON.stringify(presentationRecord(
        `{"text":"captured","cindy_process_media":[{"kind":"image","url":"${blob}"},{"kind":"image","url":"javascript:alert(1)"},{"kind":"video","url":"xdt-video://clip"}],"cindy_process_media_omitted":1}`));
      const items = buildRenderItems([
        presentationMessage('user', 'user', 'Look', 0), presentationToolUse('shot', 1),
        presentationToolResult('shot-result', 'shot', envelope, 2),
        presentationMessage('final', 'assistant', 'Done', 3, '{"turnCompleted":true}'),
      ]);
      const tool = collectTools(items, [])[0];
      expect(tool.resultText).assertEqual('captured');
      expect(JSON.stringify(tool.processMedia.map((media: ProcessMediaRef) => [media.kind, media.url])))
        .assertEqual(JSON.stringify([['image', blob], ['video', 'xdt-video://clip']]));
      // 普通 JSON 工具输出保持原样；只剥掉我们的信封。
      expect(readToolProcessText('{"ok":true}')).assertEqual('{"ok":true}');
      expect(readToolProcessText('{"a":1,"cindy_process_media":[]}')).assertEqual('{\n  "a": 1\n}');
    });

    it('only_host_issued_failed_image_records_enable_delivery_retry', 0, () => {
      const id = 'b'.repeat(64);
      const failed = `{"kind":"generation","ok":false,"native_image_delivery":{"id":"${id}","state":"failed"}}`;
      const stored = `{"kind":"generation","ok":true,"native_image_delivery":{"id":"${id}","state":"stored"}}`;
      const forged = '{"kind":"generation","native_image_delivery":{"id":"../etc","state":"failed"}}';
      const build = (text: string): RenderToolItem => collectTools(buildRenderItems([
        presentationMessage('user', 'user', 'Draw', 0), presentationToolUse('gen', 1, 'imagegen'),
        presentationToolResult('gen-result', 'gen', text, 2),
      ]), [])[0];
      expect(build(failed).failedImageDeliveryId).assertEqual(id);
      expect(build(stored).failedImageDeliveryId).assertEqual('');
      expect(build(forged).failedImageDeliveryId).assertEqual('');
    });

    it('mcp_app_sources_show_the_server_id_instead_of_the_plugin_prefix', 0, () => {
      const badges = messageSourceBadges(presentationRecord(
        '{"sourcePlugin":{"pluginId":"mcp-app:weather-server","name":""}}'), 'viewer', new Map<string, string>());
      expect(badges.length).assertEqual(1);
      expect(badges[0].kind).assertEqual('mcpApp');
      expect(badges[0].id).assertEqual('weather-server');
      expect(badges[0].name).assertEqual('weather-server');
      const plugin = messageSourceBadges(presentationRecord('{"sourcePlugin":{"pluginId":"notes","name":"Notes"}}'),
        'viewer', new Map<string, string>());
      expect(plugin[0].kind).assertEqual('plugin');
      expect(plugin[0].id).assertEqual('notes');
    });
  });
}
