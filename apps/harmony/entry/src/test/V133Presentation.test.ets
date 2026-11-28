import { parseUsageSnapshot, usageSeries, usageSum, usageResetLabel, usageCandidates, usageRangeStart, usageTotals, UsageDay, UsageSeries } from '../main/ets/core/usage/UsageDashboard';
import { PresenceSnapshot } from '../main/ets/core/device-link/DlProtocol';
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
    // Unit tier, real dashboard projection: Mobile's legacy/model bucket contract was not
    // covered by message rendering tests. Minimal inputs exercise zero vs unavailable,
    // raw model consistency, and explicit device-scope/offline selection.
    it('usage_snapshot_distinguishes_unavailable_from_zero_and_keeps_legacy_harnesses', 0, () => {
      expect(parseUsageSnapshot(presentationRecord('{"version":2}')) === null).assertTrue();
      const raw = presentationRecord('{"version":1,"sources":[],"usage":{"days":["2026-11-26"],"daily":[{"tokens":[10,20,0],"money":[1,2,0],"paid":0}]}}');
      const snapshot = parseUsageSnapshot(raw);
      expect(snapshot !== null).assertTrue();
      if (snapshot === null) return;
      expect(snapshot.days[0].paid).assertEqual(0);
      const series = usageSeries(snapshot, 'Other');
      expect(series[0].name).assertEqual('Codex');
      expect(series[0].total).assertEqual(20);
      expect(series[1].name).assertEqual('Claude Code');
      expect(series[1].total).assertEqual(10);
    });
    it('usage_chart_and_legend_keep_all_named_buckets_and_other', 0, () => {
      const raw = presentationRecord('{"version":1,"sources":[{"id":"a","kind":"subscription","fill":2,"value":"80","resetsAtMs":3600000,"when":"old"}],"strings":{"durationShort.hours":"{{h}}h","resetsIn":"Resets in {{duration}}"},"usage":{"days":["2026-11-26"],"models":[{"name":"A"},{"name":"B"},{"name":"C"},{"name":"D"}],"daily":[{"tokens":[100,50,0],"models":[0,0,0,0,0],"modelTokens":[50,40,30,20,10]}]}}');
      const snapshot = parseUsageSnapshot(raw);
      if (snapshot === null) { expect(false).assertTrue(); return; }
      const series = usageSeries(snapshot, 'Other');
      expect(series.length).assertEqual(5);
      expect(series[3].name).assertEqual('D');
      expect(series[4].name).assertEqual('Other');
      expect(series[4].total).assertEqual(10);
      expect(usageSum(series.map((s: UsageSeries): number => s.total))).assertEqual(usageSum(snapshot.days[0].tokens));
      expect(snapshot.sources[0].fill).assertEqual(1);
      expect(usageResetLabel(snapshot.sources[0], snapshot.strings, 0, 'Reset pending')).assertEqual('Resets in 1h');
      expect(usageResetLabel(snapshot.sources[0], snapshot.strings, 3600000, 'Reset pending')).assertEqual('Reset pending');
      // One missing daily bucket array must fall back for the entire period, like Mobile.
      snapshot.days.push(new UsageDay());
      expect(usageSeries(snapshot, 'Other')[0].name).assertEqual('Codex');
      expect(usageSeries(snapshot, 'Other')[0].total).assertEqual(50);
    });
    // Unit: the last seven buckets include the last day and do not mix estimated and paid.
    it('usage_range_and_model_totals_keep_money_at_its_reported_scope', 0, () => {
      const snapshot = parseUsageSnapshot(presentationRecord(
        '{"version":1,"sources":[],"usage":{"days":[],"daily":[],"models":[{"name":"A","harness":"codex"}]}}'));
      if (snapshot === null) { expect(false).assertTrue(); return; }
      for (let i = 0; i < 30; i++) {
        const day = new UsageDay();
        day.tokens = [i + 1]; day.money = [4]; day.paid = 1;
        day.modelTokens = [1, i]; day.modelMoney = [2, 2];
        snapshot.days.push(day);
      }
      const start = usageRangeStart(snapshot, 7);
      expect(start).assertEqual(23);
      expect(usageTotals(snapshot, start, 30).tokens).assertEqual(189);
      expect(usageTotals(snapshot, usageRangeStart(snapshot, 30), 30).tokens).assertEqual(465);
      const model = usageSeries(snapshot, 'Other', start, 30)[0];
      expect(model.harness).assertEqual('codex');
      const filtered = usageTotals(snapshot, start, 30, model);
      expect(filtered.tokens).assertEqual(7);
      expect(filtered.estimated).assertEqual(14);
      expect(filtered.paid).assertEqual(null);
      snapshot.days[29].modelMoney = [];
      expect(usageSeries(snapshot, 'Other', start, 30)[0].estimated).assertEqual(12);
    });

    // Unit: two days distinguish all-zero/missing and partial data through the production projection.
    it('usage_money_hides_all_zero_or_missing_buckets_per_selection', 0, () => {
      const snapshot = parseUsageSnapshot(presentationRecord(
        '{"version":1,"sources":[],"usage":{"days":["2026-11-27","2026-11-28"],"models":[{"name":"A"}],"daily":['
        + '{"tokens":[1],"money":[0],"paid":0,"modelTokens":[1,0],"models":[0,0]},'
        + '{"tokens":[1],"modelTokens":[1,0]}]}}'));
      if (snapshot === null) { expect(false).assertTrue(); return; }
      expect(usageTotals(snapshot, 0, 2).estimated).assertEqual(null);
      expect(usageTotals(snapshot, 0, 2).paid).assertEqual(null);
      expect(usageSeries(snapshot, 'Other')[0].hasEstimate).assertFalse();
      snapshot.days[0].money = [4, 0];
      snapshot.days[0].paid = 2;
      snapshot.days[0].modelMoney = [4, 0];
      const series = usageSeries(snapshot, 'Other');
      expect(usageTotals(snapshot, 0, 2).estimated).assertEqual(4);
      expect(usageTotals(snapshot, 0, 2).paid).assertEqual(2);
      expect(usageTotals(snapshot, 1, 2).estimated).assertEqual(null);
      expect(usageTotals(snapshot, 1, 2).paid).assertEqual(null);
      expect(usageTotals(snapshot, 0, 2, series[0]).estimated).assertEqual(4);
      expect(usageTotals(snapshot, 0, 2, series[1]).estimated).assertEqual(null);
      expect(series[1].estimated).assertEqual(0);
      snapshot.days[1].money = [-4, 0];
      expect(usageTotals(snapshot, 0, 2).estimated).assertEqual(0);
    });

    // Unit: structured ratios stay separate from display labels and from absent detail.
    it('usage_detail_accepts_optional_rings_and_legend', 0, () => {
      const snapshot = parseUsageSnapshot(presentationRecord(
        '{"version":1,"locale":"en","usage":{"days":[],"daily":[]},"sources":['
        + '{"kind":"subscription","unusedAtReset":true,"detail":{"title":"A","rings":[{"fraction":0.75,"color":"codex"}],"legend":[{"label":"Week"}]}},'
        + '{"kind":"subscription","detail":{"plan":"Plus","bigCaption":"Period","rings":[{"fraction":0,"color":"ink"}]}},'
        + '{"kind":"subscription","detail":{"plan":"Pro"}},{"kind":"subscription"}]}'));
      if (snapshot === null) { expect(false).assertTrue(); return; }
      expect(snapshot.locale).assertEqual('en');
      expect(snapshot.sources[0].unusedAtReset).assertTrue();
      expect(snapshot.sources[0].detail?.windows[0].label).assertEqual('Week');
      expect(snapshot.sources[0].detail?.windows[0].fraction).assertEqual(0.75);
      expect(snapshot.sources[1].detail?.windows[0].label).assertEqual('Period');
      expect(snapshot.sources[2].detail?.windows.length).assertEqual(0);
      expect(snapshot.sources[3].detail).assertEqual(null);
    });
    // Unit: one Mac and the last responding PC distinguish automatic order from pinned filtering.
    it('usage_candidates_rank_last_answer_then_mac_and_keep_card_scope_strict', 0, () => {
      const mac = new PresenceSnapshot(); mac.deviceId = 'mac'; mac.platform = 'darwin'; mac.online = true; mac.remoteControlEnabled = true;
      const pc = new PresenceSnapshot(); pc.deviceId = 'pc'; pc.platform = 'win32'; pc.online = true; pc.remoteControlEnabled = true;
      const phone = new PresenceSnapshot(); phone.deviceId = 'phone'; phone.platform = 'harmony'; phone.online = true; phone.remoteControlEnabled = true;
      expect(usageCandidates([pc, phone, mac], '')[0].deviceId).assertEqual('mac');
      expect(usageCandidates([pc, mac], 'pc').length).assertEqual(2);
      expect(usageCandidates([pc, mac], 'pc', 'pc').length).assertEqual(1);
      expect(usageCandidates([pc, mac], 'pc')[0].deviceId).assertEqual('pc');
      mac.online = false;
      expect(usageCandidates([pc, mac], 'mac')[0].deviceId).assertEqual('pc');
      expect(usageCandidates([pc, mac], '', 'mac').length).assertEqual(0);
    });

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

    // Mobile process-media contract, unit tier: object-form history results must not lose
    // the thumbnail to contentPreview's text shortcut. No network or native UI required.
    it('object_tool_result_keeps_process_image_and_does_not_infer_command_paths', 0, () => {
      const blob = `cindy-media://blobs/${'c'.repeat(64)}.png`;
      const result = presentationToolResult('image-result', 'image-use', '', 2);
      const envelope: Record<string, Object> = {};
      envelope['text'] = 'Image inspected';
      const media: Record<string, Object> = {};
      media['kind'] = 'image';
      media['url'] = blob;
      envelope['cindy_process_media'] = [media];
      result.content = envelope;
      const tool = collectTools(buildRenderItems([
        presentationMessage('image-user', 'user', 'Inspect', 0),
        presentationToolUse('image-use', 1, 'view_image'), result,
      ]), [])[0];
      expect(tool.resultText).assertEqual('Image inspected');
      expect(tool.processMedia.length).assertEqual(1);
      expect(tool.processMedia[0].url).assertEqual(blob);
      result.content = `Image inspected: ${blob}`;
      const plain = collectTools(buildRenderItems([
        presentationToolUse('image-use', 1, 'view_image'), result,
      ]), [])[0];
      expect(plain.processMedia.length).assertEqual(0);
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
