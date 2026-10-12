import { describe, expect, it } from '@ohos/hypium';
import {
  buildRenderItems, isRenderContinuation, OrcaCollabPresentation, orcaCollabCanExpand,
  orcaCollabExpansionKey, projectOrcaDispatchCard, projectOrcaPersistedMessage,
  RenderItem, RenderMessageItem, RenderWorkGroupItem, turnFinalAssistantIds,
} from '../main/ets/core/messages/MessageRender';
import { formatSessionActivityElapsed, sessionActivityElapsedMs } from '../main/ets/core/messages/SessionActivityPresentation';
import { sentSessionMessageChipLabel } from '../main/ets/core/messages/SentQuotePresentation';
import { freezeShareProjection } from '../main/ets/core/sharing/ConversationShareProjection';
import { CONTINUE_AFTER_APP_EXIT_PROMPT, CONTINUE_AFTER_ERROR_PROMPT } from '../main/ets/core/messages/SessionTailPresentation';
import { WorkPreviewRow, workPreviewRows } from '../main/ets/core/messages/WorkGroupPresentation';
import { parseMessage, readStr, RemoteMessage } from '../main/ets/core/tasks/TaskModels';

function renderingRecord(json: string): Record<string, Object> {
  return JSON.parse(json) as Record<string, Object>;
}

function renderingMessage(id: string, role: string, content: Object, seconds: number = 0,
  sealed: boolean = false): RemoteMessage {
  const raw: Record<string, Object> = {};
  raw['id'] = id;
  raw['clientId'] = id;
  raw['sessionId'] = 'rendering-session';
  raw['role'] = role;
  raw['content'] = content;
  raw['createdAt'] = new Date(1000000 + seconds * 1000).toISOString();
  if (sealed) raw['turnCompleted'] = true;
  return parseMessage(raw);
}

function renderingTool(id: string, seconds: number, toolName: string = 'Read',
  input: Record<string, Object> = renderingRecord('{"file_path":"src/app.ets"}')): RemoteMessage {
  const content: Record<string, Object> = {};
  content['toolUseId'] = id;
  content['toolName'] = toolName;
  content['input'] = input;
  return renderingMessage(id, 'tool_use', content, seconds);
}

function renderingResult(id: string, useId: string, seconds: number): RemoteMessage {
  const content: Record<string, Object> = {};
  content['toolUseId'] = useId;
  content['text'] = 'done';
  const message = renderingMessage(id, 'tool_result', content, seconds);
  message.toolUseId = useId;
  return message;
}

function rootRenderingMessage(items: RenderItem[], id: string): RenderMessageItem | undefined {
  for (let itemIndex = 0; itemIndex < items.length; itemIndex++) {
    if (items[itemIndex].type === 'message' && items[itemIndex].key === id) {
      return items[itemIndex] as RenderMessageItem;
    }
  }
  return undefined;
}

function nestedRenderingMessage(items: RenderItem[], id: string): RenderMessageItem | undefined {
  const direct = rootRenderingMessage(items, id);
  if (direct !== undefined) return direct;
  for (let itemIndex = 0; itemIndex < items.length; itemIndex++) {
    if (items[itemIndex].type !== 'work_group') continue;
    const found = nestedRenderingMessage((items[itemIndex] as RenderWorkGroupItem).children, id);
    if (found !== undefined) return found;
  }
  return undefined;
}

function renderingTypes(items: RenderItem[]): string {
  return items.map((item: RenderItem) => item.type).join('|');
}

export default function v132RenderingTests() {
  describe('V132Rendering', () => {
    it('excludes_orca_cards_and_source_labels_from_share_images', 0, () => {
      const visible = renderingMessage('visible', 'user', 'Visible body');
      visible.agentMeta = renderingRecord('{"sourceDevice":{"deviceId":"private-device","platform":"mobile","name":"private-phone"},"sourcePlugin":{"pluginId":"private-plugin","name":"private-name"}}');
      const report = renderingMessage('report', 'user', renderingRecord('{"orcaSource":"worker","content":"Private coordination"}'), 1);
      const projection = freezeShareProjection(buildRenderItems([visible, report]), new Set<string>(), 0);
      expect(projection.items.length).assertEqual(1);
      expect(projection.items[0].text).assertEqual('Visible body');
      const serialized = JSON.stringify(projection);
      expect(serialized.includes('private-')).assertFalse();
      expect(serialized.includes('Private coordination')).assertFalse();
    });
    it('strips_goal_only_from_assistant_display_without_changing_source_or_actions', 0, () => {
      const body = 'Done\n\x60\x60\x60json\n{"goal_status":"done"}\n\x60\x60\x60';
      const source = renderingMessage('assistant', 'assistant', body, 2, true);
      const items = buildRenderItems([renderingMessage('user', 'user', body), source]);
      const assistant = rootRenderingMessage(items, 'assistant') as RenderMessageItem;
      expect(assistant.body).assertEqual('Done');
      expect(assistant.mdBlocks[0].text).assertEqual('Done');
      expect(assistant.message === source).assertTrue();
      expect(source.content).assertEqual(body);
      expect(assistant.isTurnFinalAssistant).assertTrue();
      expect((rootRenderingMessage(items, 'user') as RenderMessageItem).body).assertEqual(body);
    });

    it('keeps_system_and_thinking_goal_examples_intact', 0, () => {
      const body = 'Example\n{"goal_setup":true}';
      const items = buildRenderItems([
        renderingMessage('thinking', 'thinking', body),
        renderingMessage('system', 'system', body, 1),
      ]);
      expect((rootRenderingMessage(items, 'system') as RenderMessageItem).body).assertEqual(body);
      const work = items[0] as RenderWorkGroupItem;
      expect(workPreviewRows(work)[0].text.includes('goal_setup')).assertTrue();
    });

    it('keeps_normal_json_and_nontrailing_goal_documentation', 0, () => {
      const examples = [
        '{"status":"done","value":42}',
        'Example: {"goal_status":"done"}\nFurther explanation',
        '\x60\x60\x60json\n{"value":{"goal_status":"example"}}\n\x60\x60\x60',
      ];
      for (let exampleIndex = 0; exampleIndex < examples.length; exampleIndex++) {
        const items = buildRenderItems([renderingMessage('json', 'assistant', examples[exampleIndex])]);
        expect((rootRenderingMessage(items, 'json') as RenderMessageItem).body).assertEqual(examples[exampleIndex]);
      }
    });

    it('does_not_make_protocol_only_snapshots_final_answers', 0, () => {
      const visible = renderingMessage('visible', 'assistant', 'Readable answer', 1);
      const protocol = renderingMessage('protocol', 'assistant', '{"goal_status":"done"}', 2);
      const items = buildRenderItems([visible, protocol], true);
      expect(rootRenderingMessage(items, 'protocol') === undefined).assertTrue();
      expect((rootRenderingMessage(items, 'visible') as RenderMessageItem).isTurnFinalAssistant).assertTrue();
      expect(turnFinalAssistantIds([protocol], false).size).assertEqual(0);
      expect(protocol.content).assertEqual('{"goal_status":"done"}');
    });

    it('projects_orca_dispatch_as_a_standalone_default_closed_card', 0, () => {
      const tool = renderingTool('dispatch', 1, 'mcp__orca_lead_bridge__create_worker',
        renderingRecord('{"label":"frontend","role":"UI","initial_task":"Build the screen"}'));
      const items = buildRenderItems([tool, renderingResult('result', 'dispatch', 2)]);
      expect(renderingTypes(items)).assertEqual('message');
      const item = items[0] as RenderMessageItem;
      const card = item.orcaCard as OrcaCollabPresentation;
      expect(card.variant).assertEqual('dispatch');
      expect(card.body).assertEqual('Build the screen');
      expect(readStr(card.titleArgs, 'who')).assertEqual('frontend');
      expect(card.defaultExpanded).assertFalse();
      expect(orcaCollabCanExpand(card)).assertTrue();
      expect(item.message === tool).assertTrue();
    });

    it('recognizes_batch_send_and_mcp_dispatch_aliases_only', 0, () => {
      const batch = projectOrcaDispatchCard('mcp:orca_lead_bridge:create_workers',
        renderingRecord('{"workers":[{"label":"UI","initial_task":"build"},{"role":"reviewer"}]}')) as OrcaCollabPresentation;
      expect(batch.body).assertEqual('UI: build\nreviewer');
      expect(batch.titleArgs['count']).assertEqual(2);
      expect(batch.defaultExpanded).assertFalse();
      const send = projectOrcaDispatchCard('send_to_worker', renderingRecord('{"message":"Continue"}')) as OrcaCollabPresentation;
      expect(send.body).assertEqual('Continue');
      expect(send.titleKey).assertEqual('interaction.collab.sendTitle');
      expect(projectOrcaDispatchCard('create_worker_backup', renderingRecord('{}'))).assertEqual(null);
      expect(projectOrcaDispatchCard('Read', renderingRecord('{}'))).assertEqual(null);
    });

    it('projects_orca_fallbacks_without_dumping_input_records', 0, () => {
      const create = projectOrcaDispatchCard('create_worker', renderingRecord('{"role":"reviewer","agent":"codex"}')) as OrcaCollabPresentation;
      expect(create.bodyKey).assertEqual('interaction.collab.dispatchRole');
      expect(readStr(create.bodyArgs, 'meta')).assertEqual('reviewer · codex');
      const batch = projectOrcaDispatchCard('create_workers', renderingRecord('{"workers":"invalid"}')) as OrcaCollabPresentation;
      expect(batch.body).assertEqual('');
      expect(batch.bodyKey).assertEqual('interaction.collab.batchBodyFallback');
      const send = projectOrcaDispatchCard('send_to_worker', renderingRecord('{"target_session_id":"worker-session"}')) as OrcaCollabPresentation;
      expect(send.body).assertEqual('→ worker-session');
    });

    it('reads_serialized_orca_reports_and_sanitizes_host_sender_labels', 0, () => {
      const source = renderingMessage('report', 'user', '{"orcaSource":"worker","content":"  Completed  "}');
      const origin: Record<string, Object> = {};
      origin['kind'] = 'orca';
      origin['senderLabel'] = '「reviewer」\nnext';
      source.agentMeta['origin'] = origin;
      const item = buildRenderItems([source])[0] as RenderMessageItem;
      const card = item.orcaCard as OrcaCollabPresentation;
      expect(card.variant).assertEqual('report');
      expect(card.body).assertEqual('Completed');
      expect(card.titleKey).assertEqual('interaction.collab.fromWorkerNamed');
      expect(readStr(card.titleArgs, 'role')).assertEqual('"reviewer" next');
      expect(card.defaultExpanded).assertFalse();
      expect(item.message === source).assertTrue();
      expect(source.content).assertEqual('{"orcaSource":"worker","content":"  Completed  "}');
    });

    it('does_not_guess_orca_messages_from_prose_or_arbitrary_json', 0, () => {
      const samples: Object[] = ['From Orca Worker: done', '{invalid',
        renderingRecord('{"orcaSource":"other","content":"normal"}'), renderingRecord('{"result":"normal"}')];
      for (let sampleIndex = 0; sampleIndex < samples.length; sampleIndex++) {
        const message = renderingMessage('normal', 'user', samples[sampleIndex]);
        expect(projectOrcaPersistedMessage(message)).assertEqual(null);
        expect((buildRenderItems([message])[0] as RenderMessageItem).orcaCard).assertEqual(null);
      }
      expect(projectOrcaPersistedMessage(renderingMessage('assistant', 'assistant',
        renderingRecord('{"orcaSource":"worker","content":"normal assistant"}')))).assertEqual(null);
    });

    it('empty_orca_messages_use_neutral_localized_fallback_not_raw_json', 0, () => {
      const source = renderingMessage('empty', 'user', renderingRecord('{"orcaSource":"worker","content":{"secret":"metadata"}}'));
      source.agentMeta['origin'] = renderingRecord('{"kind":"orca","senderLabel":"worker"}');
      const card = projectOrcaPersistedMessage(source) as OrcaCollabPresentation;
      expect(card.body).assertEqual('');
      expect(card.bodyKey).assertEqual('interaction.collab.emptyMessageBody');
      expect(card.titleKey).assertEqual('interaction.collab.fromWorker');
      const blank = new OrcaCollabPresentation();
      blank.body = ' \n ';
      expect(orcaCollabCanExpand(blank)).assertFalse();
    });

    it('orcas_new_expansion_identity_is_scoped_and_does_not_reuse_legacy_toggles', 0, () => {
      const item = buildRenderItems([
        renderingMessage('report', 'user', renderingRecord('{"orcaSource":"worker","content":"done"}')),
      ])[0] as RenderMessageItem;
      const key = orcaCollabExpansionKey('account-a', 'device-a', item);
      expect(key.startsWith('orca-expanded-')).assertTrue();
      expect(key === orcaCollabExpansionKey('account-b', 'device-a', item)).assertFalse();
      expect(key === orcaCollabExpansionKey('account-a', 'device-b', item)).assertFalse();
      const otherSessionMessage = renderingMessage('report', 'user', renderingRecord('{"orcaSource":"worker","content":"done"}'));
      otherSessionMessage.sessionId = 'other-rendering-session';
      const otherSessionItem = buildRenderItems([otherSessionMessage])[0] as RenderMessageItem;
      expect(otherSessionItem.key).assertEqual(item.key);
      expect(otherSessionItem.message?.id).assertEqual(item.message?.id);
      expect(otherSessionItem.orcaCard?.variant).assertEqual(item.orcaCard?.variant);
      expect(otherSessionItem.message?.sessionId === item.message?.sessionId).assertFalse();
      expect(key === orcaCollabExpansionKey('account-a', 'device-a', otherSessionItem)).assertFalse();
      const sameSessionItem = buildRenderItems([
        renderingMessage('report', 'user', renderingRecord('{"orcaSource":"worker","content":"done"}')),
      ])[0] as RenderMessageItem;
      expect(key).assertEqual(orcaCollabExpansionKey('account-a', 'device-a', sameSessionItem));
    });

    it('worker_reports_do_not_cut_the_user_turn_or_promote_progress_to_final', 0, () => {
      const progress = renderingMessage('progress', 'assistant', 'Checking next', 2);
      const final = renderingMessage('final', 'assistant', 'Completed', 6);
      const items = buildRenderItems([
        renderingMessage('user', 'user', 'Work'), renderingMessage('thought', 'thinking', 'Plan', 1), progress,
        renderingMessage('report', 'user', '{"orcaSource":"worker","content":"Worker done"}', 3),
        renderingTool('read', 4), renderingResult('result', 'read', 5), final,
      ]);
      expect(rootRenderingMessage(items, 'progress') === undefined).assertTrue();
      expect((nestedRenderingMessage(items, 'progress') as RenderMessageItem).isTurnFinalAssistant).assertFalse();
      expect((rootRenderingMessage(items, 'report') as RenderMessageItem).orcaCard?.variant).assertEqual('report');
      expect((rootRenderingMessage(items, 'final') as RenderMessageItem).isTurnFinalAssistant).assertTrue();
    });

    it('lead_messages_still_start_a_new_worker_turn', 0, () => {
      const progress = renderingMessage('progress', 'assistant', 'Previous answer', 2);
      const items = buildRenderItems([
        renderingMessage('user', 'user', 'Work'), renderingMessage('thought', 'thinking', 'Plan', 1), progress,
        renderingMessage('lead', 'user', renderingRecord('{"orcaSource":"lead","content":"Next task"}'), 3),
        renderingMessage('final', 'assistant', 'New answer', 4),
      ]);
      expect((rootRenderingMessage(items, 'lead') as RenderMessageItem).orcaCard?.variant).assertEqual('lead');
      expect((rootRenderingMessage(items, 'progress') as RenderMessageItem).isTurnFinalAssistant).assertTrue();
    });

    it('seals_completed_work_before_an_active_tail_without_hiding_its_answer_actions', 0, () => {
      const final = renderingMessage('sealed', 'assistant', 'Delivered', 5, true);
      const active = renderingMessage('active', 'thinking', 'Next step', 6);
      active.isStreaming = true;
      const items = buildRenderItems([
        renderingMessage('user', 'user', 'Work'), renderingMessage('thought', 'thinking', 'Plan', 1),
        renderingMessage('progress', 'assistant', 'Checking', 2),
        renderingTool('read', 3), renderingResult('result', 'read', 4), final, active,
      ], true);
      expect(renderingTypes(items)).assertEqual('message|work_group|message|work_group');
      expect((items[1] as RenderWorkGroupItem).isStreaming).assertFalse();
      expect((items[3] as RenderWorkGroupItem).isStreaming).assertTrue();
      const answer = rootRenderingMessage(items, 'sealed') as RenderMessageItem;
      expect(answer.isTurnFinalAssistant).assertTrue();
      expect(answer.message === final).assertTrue();
      expect(answer.message?.clientId).assertEqual('sealed');
    });

    it('archives_short_earlier_seals_but_keeps_last_seal_like_shared_workrun_grouping', 0, () => {
      const items = buildRenderItems([
        renderingMessage('user', 'user', 'Work'), renderingMessage('first', 'thinking', 'Plan', 1),
        renderingMessage('waiting', 'assistant', 'Still waiting', 2, true),
        renderingMessage('second', 'thinking', 'Continue', 3),
        renderingMessage('final', 'assistant', 'All done', 4, true),
      ]);
      expect(renderingTypes(items)).assertEqual('message|work_group|message');
      expect(rootRenderingMessage(items, 'waiting') === undefined).assertTrue();
      expect((nestedRenderingMessage(items, 'waiting') as RenderMessageItem).body).assertEqual('Still waiting');
      expect((rootRenderingMessage(items, 'final') as RenderMessageItem).isTurnFinalAssistant).assertTrue();
    });

    it('keeps_the_whole_sealed_delivery_run_and_all_answer_source_identities', 0, () => {
      const intro = renderingMessage('intro', 'assistant', 'Here is the result', 2);
      const delivery = renderingMessage('delivery', 'assistant', '## Report\nImplemented and checked', 3, true);
      const items = buildRenderItems([
        renderingMessage('user', 'user', 'Work'), renderingMessage('first', 'thinking', 'Plan', 1), intro, delivery,
        renderingMessage('second', 'thinking', 'Notify', 4),
        renderingMessage('final', 'assistant', 'Notified', 5, true),
      ]);
      expect((rootRenderingMessage(items, 'intro') as RenderMessageItem).message === intro).assertTrue();
      expect((rootRenderingMessage(items, 'delivery') as RenderMessageItem).message === delivery).assertTrue();
      expect((rootRenderingMessage(items, 'delivery') as RenderMessageItem).isTurnFinalAssistant).assertTrue();
      expect((rootRenderingMessage(items, 'final') as RenderMessageItem).isTurnFinalAssistant).assertTrue();
    });

    it('preserves_image_delivery_prose_before_trailing_side_effect_work', 0, () => {
      const images = ['![output](cindy-media://blobs/abc)', '<img src="cindy-media://blobs/abc">'];
      for (let imageIndex = 0; imageIndex < images.length; imageIndex++) {
        const items = buildRenderItems([
          renderingMessage('user', 'user', 'Draw'), renderingMessage('thought', 'thinking', 'Plan', 1),
          renderingMessage('image', 'assistant', images[imageIndex], 2), renderingTool('notify', 3),
          renderingResult('result', 'notify', 4), renderingMessage('final', 'assistant', 'Notified', 5, true),
        ]);
        expect((rootRenderingMessage(items, 'image') as RenderMessageItem).body).assertEqual(images[imageIndex]);
      }
    });

    it('folds_interrupted_progress_on_recovery_but_keeps_errors_and_original_rows', 0, () => {
      const progress = renderingMessage('progress', 'assistant', 'Still checking', 2);
      const recovery = renderingMessage('recovery', 'user', CONTINUE_AFTER_ERROR_PROMPT, 5);
      const items = buildRenderItems([
        renderingMessage('user', 'user', 'Work'), renderingMessage('thought', 'thinking', 'Plan', 1), progress,
        renderingTool('pending', 3), renderingMessage('error', 'error', 'Connection interrupted', 4), recovery,
        renderingMessage('second', 'thinking', 'Resume', 6), renderingMessage('final', 'assistant', 'Finished', 7, true),
      ]);
      expect(rootRenderingMessage(items, 'progress') === undefined).assertTrue();
      expect((nestedRenderingMessage(items, 'progress') as RenderMessageItem).message === progress).assertTrue();
      expect(rootRenderingMessage(items, 'error') !== undefined).assertTrue();
      expect(rootRenderingMessage(items, 'recovery') === undefined).assertTrue();
      expect((rootRenderingMessage(items, 'final') as RenderMessageItem).isTurnFinalAssistant).assertTrue();
      expect(progress.content).assertEqual('Still checking');
    });

    it('auto_resume_closes_only_the_interrupted_attempt_and_keeps_delivery', 0, () => {
      const recovery = renderingMessage('recovery', 'user', '', 4);
      recovery.systemCardType = 'auto-resume';
      recovery.agentMeta['autoResume'] = true;
      const items = buildRenderItems([
        renderingMessage('user', 'user', 'Work'), renderingMessage('thought', 'thinking', 'Plan', 1),
        renderingMessage('delivery', 'assistant', '## Delivered\nKeep this report', 2, true), renderingTool('pending', 3),
        recovery, renderingMessage('next', 'thinking', 'Continue', 5),
      ], true);
      expect((rootRenderingMessage(items, 'delivery') as RenderMessageItem).isTurnFinalAssistant).assertTrue();
      expect(rootRenderingMessage(items, 'recovery') !== undefined).assertTrue();
      expect((items[items.length - 1] as RenderWorkGroupItem).isStreaming).assertTrue();
      expect(isRenderContinuation(recovery)).assertTrue();
    });

    it('recovery_recognition_uses_exact_protocol_not_general_continue_prose', 0, () => {
      const checkpoint = CONTINUE_AFTER_APP_EXIT_PROMPT + '\n\n[CINDY_RECOVERY_CHECKPOINT v1]\nstate';
      const checkpointContent: Record<string, Object> = {};
      checkpointContent['text'] = checkpoint;
      expect(isRenderContinuation(renderingMessage('checkpoint', 'user', JSON.stringify(checkpointContent)))).assertTrue();
      expect(isRenderContinuation(renderingMessage('normal', 'user', 'Continue after error'))).assertFalse();
      expect(isRenderContinuation(renderingMessage('generic', 'user', '[UI_ACTION_TRIGGER] Generate image'))).assertFalse();
      expect(isRenderContinuation(renderingMessage('assistant', 'assistant', CONTINUE_AFTER_ERROR_PROMPT))).assertFalse();
    });

    it('generic_synthetic_triggers_do_not_archive_unfinished_answers_as_recovery', 0, () => {
      const items = buildRenderItems([
        renderingMessage('user', 'user', 'Work'), renderingMessage('thought', 'thinking', 'Plan', 1),
        renderingMessage('partial', 'assistant', 'Partial answer', 2), renderingTool('pending', 3),
        renderingMessage('generic', 'user', '[UI_ACTION_TRIGGER] Generate image', 4),
      ]);
      expect(rootRenderingMessage(items, 'partial') !== undefined).assertTrue();
      expect(rootRenderingMessage(items, 'generic') === undefined).assertTrue();
    });

    it('recovery_after_a_history_gap_does_not_reclassify_work_on_the_far_side', 0, () => {
      const items = buildRenderItems([
        renderingMessage('user', 'user', 'Work'), renderingMessage('thought', 'thinking', 'Plan', 1),
        renderingMessage('partial', 'assistant', 'Partial answer', 2), renderingTool('pending', 3),
        renderingMessage('recovery', 'user', CONTINUE_AFTER_ERROR_PROMPT, 2000),
        renderingMessage('final', 'assistant', 'Finished', 2001, true),
      ]);
      expect(rootRenderingMessage(items, 'partial') !== undefined).assertTrue();
      expect((rootRenderingMessage(items, 'final') as RenderMessageItem).isTurnFinalAssistant).assertTrue();
    });

    it('steer_inputs_are_visible_without_cutting_the_active_workrun', 0, () => {
      const steer = renderingMessage('steer', 'user', 'Also check tests', 3);
      steer.agentMeta['delivery'] = 'steer';
      const items = buildRenderItems([
        renderingMessage('user', 'user', 'Work'), renderingMessage('thought', 'thinking', 'Plan', 1),
        renderingMessage('progress', 'assistant', 'Checking', 2), steer, renderingTool('read', 4),
        renderingResult('result', 'read', 5), renderingMessage('final', 'assistant', 'Finished', 6, true),
      ]);
      expect(rootRenderingMessage(items, 'progress') === undefined).assertTrue();
      expect((rootRenderingMessage(items, 'steer') as RenderMessageItem).message === steer).assertTrue();
      expect((rootRenderingMessage(items, 'final') as RenderMessageItem).isTurnFinalAssistant).assertTrue();
    });

    it('elapsed_clock_keeps_subhour_floor_and_adds_hour_day_minutes', 0, () => {
      expect(formatSessionActivityElapsed(999)).assertEqual('0s');
      expect(formatSessionActivityElapsed(1000)).assertEqual('1s');
      expect(formatSessionActivityElapsed(60000)).assertEqual('1m 0s');
      expect(formatSessionActivityElapsed(62900)).assertEqual('1m 2s');
      expect(formatSessionActivityElapsed(3599999)).assertEqual('59m 59s');
      expect(formatSessionActivityElapsed(3600000)).assertEqual('1h 0m');
      expect(formatSessionActivityElapsed(3659999)).assertEqual('1h 0m');
      expect(formatSessionActivityElapsed(3660000)).assertEqual('1h 1m');
      expect(formatSessionActivityElapsed(86400000)).assertEqual('1d 0h 0m');
      expect(formatSessionActivityElapsed(90061000)).assertEqual('1d 1h 1m');
    });

    it('elapsed_clock_handles_invalid_and_reordered_wall_times', 0, () => {
      expect(formatSessionActivityElapsed(NaN)).assertEqual('0s');
      expect(formatSessionActivityElapsed(Infinity)).assertEqual('0s');
      expect(formatSessionActivityElapsed(-1000)).assertEqual('0s');
      expect(sessionActivityElapsedMs(10999, 10000)).assertEqual(999);
      expect(sessionActivityElapsedMs(9000, 10000)).assertEqual(0);
      expect(sessionActivityElapsedMs(10000, 0)).assertEqual(0);
    });

    it('sent_quote_chips_show_short_readable_markdown_not_media_ids', 0, () => {
      expect(sentSessionMessageChipLabel('**1. 深色·打开过程**：第一帧\n\n![深色-打开过程](cindy-media://blobs/abc)'))
        .assertEqual('1. 深色·打开过程：第一帧 深色-打开过程');
      expect(sentSessionMessageChipLabel('上次我用的是 Claude Code 自带的 \x60SendUserFile\x60 发文件，工具返回了已送达'))
        .assertEqual('上次我用的是 Claude Code 自带的…');
      expect(sentSessionMessageChipLabel('## Title\n\n[Readable](https://example.com)')).assertEqual('Title Readable');
      expect(sentSessionMessageChipLabel('[**Readable**](https://example.com)')).assertEqual('Readable');
      expect(sentSessionMessageChipLabel('![](cindy-media://blobs/abc)')).assertEqual('');
      expect(sentSessionMessageChipLabel('  \n ')).assertEqual('');
    });

    it('sent_quote_chips_reparse_nested_emphasis_and_strip_internal_image_residue', 0, () => {
      expect(sentSessionMessageChipLabel('**![](cindy-media://blobs/abc)**')).assertEqual('');
      expect(sentSessionMessageChipLabel('*![图](cindy-media://blobs/x)* 后文')).assertEqual('图 后文');
      expect(sentSessionMessageChipLabel('**<img src="cindy-media://blobs/x">** 尾')).assertEqual('尾');
      expect(sentSessionMessageChipLabel('**加粗 ![说明](cindy-media://blobs/y) 中**')).assertEqual('加粗 说明 中');
      expect(sentSessionMessageChipLabel('cindy-oss-attach://key/internal')).assertEqual('');
    });

    it('sent_quote_chips_never_expose_media_markup_in_wrapper_length_combinations', 0, () => {
      const tokens = ['![](cindy-media://blobs/abc)', '![图](cindy-media://blobs/abc)',
        '![' + '说'.repeat(2500) + '](cindy-media://blobs/abc)',
        '![alt](cindy-media://blobs/' + 'f'.repeat(3000) + ')',
        '<img src="cindy-media://blobs/abc" width="10">', '![x](xdt-image://abc)',
        'cindy-media://blobs/bare', 'cindy-oss-attach://private/file'];
      for (let tokenIndex = 0; tokenIndex < tokens.length; tokenIndex++) {
        const token = tokens[tokenIndex];
        const wrappers = [token, '**' + token + '**', '*' + token + '*', '***' + token + '***',
          '**外 *内 ' + token + '* 外**', '- ' + token, '| ' + token + ' |\n| --- |', '前文 ' + token + ' 后文'];
        for (let wrapperIndex = 0; wrapperIndex < wrappers.length; wrapperIndex++) {
          const tails = ['', '\n正文继续', '\n' + '下一行\n'.repeat(1000)];
          for (let tailIndex = 0; tailIndex < tails.length; tailIndex++) {
            const label = sentSessionMessageChipLabel(wrappers[wrapperIndex] + tails[tailIndex]);
            expect(/!\[|<img|cindy-media|cindy-oss-attach|xdt-image/i.test(label)).assertFalse();
          }
        }
      }
    });

    it('sent_quote_chips_bound_long_logs_without_cutting_inline_syntax', 0, () => {
      const log = '**构建日志**\n' + 'line of output\n'.repeat(20000) + '![](cindy-media://blobs/tail)';
      expect(sentSessionMessageChipLabel(log)).assertEqual('构建日志 line of output lin…');
      expect(sentSessionMessageChipLabel('开头说明 ' + 'x'.repeat(5000)).startsWith('开头说明 x')).assertTrue();
      expect(sentSessionMessageChipLabel('| **Header** |\n| --- |\n| \x60value\x60 |')).assertEqual('Header value');
    });

    it('sent_quote_chips_preserve_display_clusters_and_do_not_mutate_source_strings', 0, () => {
      expect(sentSessionMessageChipLabel('😀'.repeat(40))).assertEqual('😀'.repeat(23) + '…');
      const clusters = ['🇨🇳', '👨‍👩‍👧', '👍🏽'];
      for (let clusterIndex = 0; clusterIndex < clusters.length; clusterIndex++) {
        const source = 'a'.repeat(22) + clusters[clusterIndex] + 'bb';
        expect(sentSessionMessageChipLabel(source)).assertEqual('a'.repeat(22) + clusters[clusterIndex] + '…');
        expect(source).assertEqual('a'.repeat(22) + clusters[clusterIndex] + 'bb');
      }
      expect(sentSessionMessageChipLabel('🇨🇳🇨🇳')).assertEqual('🇨🇳🇨🇳');
      expect(sentSessionMessageChipLabel('a'.repeat(23) + 'e\u0301')).assertEqual('a'.repeat(23) + 'e\u0301');
    });

    it('nested_work_preview_still_exposes_exact_tools_without_duplicate_results', 0, () => {
      const tool = renderingTool('read', 2);
      const items = buildRenderItems([
        renderingMessage('user', 'user', 'Work'), renderingMessage('thought', 'thinking', 'Plan', 1), tool,
        renderingResult('result', 'read', 3), renderingMessage('progress', 'assistant', 'Checking', 4),
        renderingMessage('more', 'thinking', 'Finish', 5), renderingMessage('final', 'assistant', 'Done', 6, true),
      ]);
      const work = items[1] as RenderWorkGroupItem;
      const rows = workPreviewRows(work, 0);
      const toolRows = rows.filter((row: WorkPreviewRow) => row.kind === 'tool');
      expect(toolRows.length).assertEqual(1);
      expect(toolRows[0].tool?.toolUseId).assertEqual('read');
      expect(toolRows[0].done).assertTrue();
      expect(rows.filter((row: WorkPreviewRow) => row.kind === 'thinking').length).assertEqual(2);
      expect((nestedRenderingMessage(items, 'progress') as RenderMessageItem).body).assertEqual('Checking');
    });
  });
}
