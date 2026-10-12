import { describe, expect, it } from '@ohos/hypium';
import { stripGoalVerdictBlock } from '../main/ets/core/messages/InternalOutputSanitizer';
import { PresenceSnapshot } from '../main/ets/core/device-link/DlProtocol';
import { TaskStore } from '../main/ets/core/tasks/TaskStore';
import { DeviceView } from '../main/ets/core/tasks/TaskModels';
import { formatWorkDuration, messageSourceBadges, sanitizeSourceName } from '../main/ets/core/messages/MessageSourcePresentation';
import {
  OrcaCollabPresentation, orcaCollabCanExpand, projectOrcaDispatchCard, projectOrcaPersistedMessage,
} from '../main/ets/core/messages/MessageRender';
import { sentSessionMessageChipLabel } from '../main/ets/core/messages/SentQuotePresentation';
import { parseMessage, readStr, RemoteMessage } from '../main/ets/core/tasks/TaskModels';

function presentationDeviceMeta(deviceId: string, platform: string, name: string = ''): Record<string, Object> {
  const device: Record<string, Object> = {};
  device['deviceId'] = deviceId;
  device['platform'] = platform;
  device['name'] = name;
  const meta: Record<string, Object> = {};
  meta['sourceDevice'] = device;
  return meta;
}

function presentationPluginMeta(pluginId: string, name: string = ''): Record<string, Object> {
  const plugin: Record<string, Object> = {};
  plugin['pluginId'] = pluginId;
  plugin['name'] = name;
  const meta: Record<string, Object> = {};
  meta['sourcePlugin'] = plugin;
  return meta;
}

function presentationSessionOrigin(sessionId: string = '', title: string = ''): Record<string, Object> {
  const origin: Record<string, Object> = {};
  origin['kind'] = 'session';
  origin['senderSessionId'] = sessionId;
  origin['senderSessionTitle'] = title;
  return origin;
}

function presentationOrcaMessage(direction: string, body: Object, serialized: boolean = false): RemoteMessage {
  const content: Record<string, Object> = {};
  content['orcaSource'] = direction;
  content['content'] = body;
  const raw: Record<string, Object> = {};
  raw['id'] = 'orca-message';
  raw['clientId'] = 'orca-message';
  raw['sessionId'] = 'orca-session';
  raw['role'] = 'user';
  raw['content'] = serialized ? JSON.stringify(content) : content;
  return parseMessage(raw);
}

export default function v132PresentationTests() {
  describe('V132Presentation', () => {
    it('keeps_all_source_devices_without_adding_phones_to_control_targets', 0, () => {
      const store = new TaskStore();
      const phone = new DeviceView();
      phone.deviceId = 'phone';
      phone.name = 'Phone';
      phone.platform = 'ios';
      const desktop = new DeviceView();
      desktop.deviceId = 'desktop';
      desktop.name = 'Desktop';
      desktop.platform = 'darwin';
      expect(store.messageSourceDirectoryLoaded).assertFalse();
      store.mergeServerDevices([phone, desktop]);
      expect(store.messageSourceDirectoryLoaded).assertTrue();
      expect(store.messageSourceDeviceNames.get('phone')).assertEqual('Phone');
      expect(store.deviceList.length).assertEqual(1);
      expect(store.deviceList[0].deviceId).assertEqual('desktop');
      const presence = new PresenceSnapshot();
      presence.deviceId = 'phone';
      presence.deviceName = 'Renamed phone';
      presence.platform = 'ios';
      store.handlePresence(presence);
      expect(store.messageSourceDeviceNames.get('phone')).assertEqual('Renamed phone');
      expect(store.deviceList.length).assertEqual(1);
      store.mergeServerDevices([desktop]);
      expect(store.messageSourceDeviceNames.has('phone')).assertFalse();
      store.clearAll();
      expect(store.messageSourceDeviceNames.size).assertEqual(0);
      expect(store.messageSourceDirectoryLoaded).assertFalse();
    });
    it('strips_only_trailing_goal_protocol_not_regular_json', 0, () => {
      expect(stripGoalVerdictBlock('Done\n{"goal_status":"done"}')).assertEqual('Done');
      expect(stripGoalVerdictBlock('Done\n\x60\x60\x60json\n{"goal_setup":true}\n\x60\x60\x60')).assertEqual('Done');
      const regular = '{"goal_status":"example"}\nFurther explanation';
      expect(stripGoalVerdictBlock(regular)).assertEqual(regular);
      expect(stripGoalVerdictBlock('Body\n{"ordinary":true}')).assertEqual('Body\n{"ordinary":true}');
    });
    it('shows_only_other_known_source_devices_and_prefers_live_names', 0, () => {
      const meta = presentationDeviceMeta('sender', 'mobile', 'old');
      const names = new Map<string, string>();
      expect(messageSourceBadges(meta, 'sender', names).length).assertEqual(0);
      names.set('sender', 'live');
      const badges = messageSourceBadges(meta, 'viewer', names);
      expect(badges[0].name).assertEqual('live');
      expect(messageSourceBadges(presentationDeviceMeta('sender', 'unknown'), 'viewer', names).length).assertEqual(0);
    });
    it('prefers_plugin_identity_and_bounds_untrusted_names', 0, () => {
      const meta = presentationPluginMeta('plugin', '「Name」\nnext');
      meta['origin'] = presentationSessionOrigin('task');
      const names = new Map<string, string>();
      const badges = messageSourceBadges(meta, '', names);
      expect(badges.length).assertEqual(1);
      expect(badges[0].kind).assertEqual('plugin');
      expect(badges[0].name).assertEqual('"Name" next');
      expect(sanitizeSourceName('x'.repeat(100)).length).assertEqual(80);
      const anonymousMeta: Record<string, Object> = {};
      anonymousMeta['origin'] = presentationSessionOrigin();
      expect(messageSourceBadges(anonymousMeta, '', names)[0].name).assertEqual('');
    });
    it('formats_day_hour_minute_duration_with_zero_minutes', 0, () => {
      expect(formatWorkDuration(86400000)).assertEqual('1d 0h 0m');
      expect(formatWorkDuration(3600000)).assertEqual('1h 0m');
      expect(formatWorkDuration(90061000)).assertEqual('1d 1h 1m');
      expect(formatWorkDuration(NaN)).assertEqual('1s');
    });

    it('source_sender_and_device_badges_are_independent_and_preserve_metadata', 0, () => {
      const meta = presentationPluginMeta('plugin', 'Plugin');
      const deviceMeta = presentationDeviceMeta('sender', 'desktop', 'Computer');
      meta['sourceDevice'] = deviceMeta['sourceDevice'];
      meta['origin'] = presentationSessionOrigin('task', 'Task');
      const original = JSON.stringify(meta);
      const badges = messageSourceBadges(meta, 'viewer', new Map<string, string>());
      expect(badges.length).assertEqual(2);
      expect(badges[0].kind).assertEqual('plugin');
      expect(badges[0].id).assertEqual('plugin');
      expect(badges[1].kind).assertEqual('desktop');
      expect(badges[1].id).assertEqual('sender');
      expect(badges[1].name).assertEqual('Computer');
      expect(JSON.stringify(meta)).assertEqual(original);
    });

    it('source_unknown_device_does_not_hide_valid_plugin_or_session_sender', 0, () => {
      const meta = presentationPluginMeta('plugin', 'Plugin');
      const deviceMeta = presentationDeviceMeta('sender', 'future-platform');
      meta['sourceDevice'] = deviceMeta['sourceDevice'];
      const badges = messageSourceBadges(meta, '', new Map<string, string>());
      expect(badges.length).assertEqual(1);
      expect(badges[0].kind).assertEqual('plugin');
      const sessionMeta = presentationPluginMeta('', 'Invalid plugin');
      sessionMeta['origin'] = presentationSessionOrigin('task', 'Task');
      const sessionBadges = messageSourceBadges(sessionMeta, '', new Map<string, string>());
      expect(sessionBadges.length).assertEqual(1);
      expect(sessionBadges[0].kind).assertEqual('session');
      expect(sessionBadges[0].id).assertEqual('task');
      expect(sessionBadges[0].name).assertEqual('Task');
    });

    it('source_missing_and_malformed_metadata_never_become_inferred_badges', 0, () => {
      const names = new Map<string, string>();
      const empty: Record<string, Object> = {};
      expect(messageSourceBadges(empty, 'viewer', names).length).assertEqual(0);
      expect(messageSourceBadges(presentationDeviceMeta('', 'mobile'), 'viewer', names).length).assertEqual(0);
      expect(messageSourceBadges(presentationDeviceMeta('sender', ''), 'viewer', names).length).assertEqual(0);
      expect(messageSourceBadges(presentationPluginMeta('', 'Named'), 'viewer', names).length).assertEqual(0);
      const malformed: Record<string, Object> = {};
      malformed['sourceDevice'] = 'not a record';
      const pluginArray: Object[] = [];
      malformed['sourcePlugin'] = pluginArray;
      malformed['origin'] = 42;
      expect(messageSourceBadges(malformed, 'viewer', names).length).assertEqual(0);
    });

    it('source_live_names_are_sanitized_without_mutating_the_directory', 0, () => {
      const meta = presentationDeviceMeta('sender', 'mobile', 'Snapshot');
      const names = new Map<string, string>();
      const live = '「Phone」\u0000\nnext\u2028line';
      names.set('sender', live);
      const badges = messageSourceBadges(meta, 'viewer', names);
      expect(badges[0].name).assertEqual('"Phone" next line');
      expect(names.get('sender')).assertEqual(live);
      expect(sanitizeSourceName(' \t\n ')).assertEqual('');
      expect(sanitizeSourceName('x'.repeat(81))).assertEqual('x'.repeat(79) + '…');
    });

    it('source_normalizes_ids_like_shared_readers_before_self_comparison', 0, () => {
      const names = new Map<string, string>();
      const deviceMeta = presentationDeviceMeta(' sender ', 'mobile');
      expect(messageSourceBadges(deviceMeta, 'sender', names).length).assertEqual(0);
      expect(messageSourceBadges(presentationDeviceMeta(' \t ', 'desktop'), 'viewer', names).length).assertEqual(0);
      const pluginBadges = messageSourceBadges(presentationPluginMeta(' plugin ', 'Plugin'), 'viewer', names);
      expect(pluginBadges[0].id).assertEqual('plugin');
      expect(messageSourceBadges(presentationPluginMeta(' \t '), 'viewer', names).length).assertEqual(0);
    });

    it('source_empty_live_name_falls_back_to_sanitized_snapshot', 0, () => {
      const meta = presentationDeviceMeta('sender', 'mobile', '「Snapshot」\nPhone');
      const names = new Map<string, string>();
      names.set('sender', ' \n\t ');
      const badges = messageSourceBadges(meta, 'viewer', names);
      expect(badges[0].name).assertEqual('"Snapshot" Phone');
    });

    it('source_duplicate_device_names_append_short_id_like_mobile', 0, () => {
      const meta = presentationDeviceMeta('sender123', 'mobile', 'Old');
      const names = new Map<string, string>();
      names.set('sender123', 'iPhone');
      names.set('other123', ' IPHONE ');
      const badges = messageSourceBadges(meta, 'viewer', names);
      expect(badges[0].name).assertEqual('iPhone (sender)');
      expect(badges[0].id).assertEqual('sender123');
    });

    it('source_sanitization_does_not_rewrite_regular_brackets_or_user_text', 0, () => {
      const input = '[Client](ID) User text';
      expect(sanitizeSourceName(input)).assertEqual(input);
      expect(input).assertEqual('[Client](ID) User text');
      const unknownViewer = messageSourceBadges(presentationDeviceMeta('sender', 'desktop'), '', new Map<string, string>());
      expect(unknownViewer.length).assertEqual(1);
      expect(unknownViewer[0].name).assertEqual('');
    });

    it('quote_chip_summarizes_visible_markdown_only_and_keeps_input_unchanged', 0, () => {
      const input = '**Result**\n![Screen](cindy-media://blobs/private-id)';
      expect(sentSessionMessageChipLabel(input)).assertEqual('Result Screen');
      expect(input).assertEqual('**Result**\n![Screen](cindy-media://blobs/private-id)');
      expect(sentSessionMessageChipLabel('## Title\n[**Readable**](https://example.com)')).assertEqual('Title Readable');
      expect(sentSessionMessageChipLabel('![](cindy-media://blobs/private-id)')).assertEqual('');
      expect(sentSessionMessageChipLabel('cindy-oss-attach://private-id')).assertEqual('');
    });

    it('quote_chip_keeps_display_clusters_and_bounds_log_prefixes', 0, () => {
      const source = 'a'.repeat(22) + '👨‍👩‍👧' + 'bb';
      expect(sentSessionMessageChipLabel(source)).assertEqual('a'.repeat(22) + '👨‍👩‍👧…');
      expect(sentSessionMessageChipLabel('**构建日志**\n' + 'line of output\n'.repeat(20000)))
        .assertEqual('构建日志 line of output lin…');
    });

    it('orca_presentation_reads_object_and_serialized_envelopes_without_raw_json', 0, () => {
      const objectRow = presentationOrcaMessage('worker', '  Completed  ');
      const serializedRow = presentationOrcaMessage('worker', '  Completed  ', true);
      const objectCard = projectOrcaPersistedMessage(objectRow) as OrcaCollabPresentation;
      const serializedCard = projectOrcaPersistedMessage(serializedRow) as OrcaCollabPresentation;
      expect(objectCard.body).assertEqual('Completed');
      expect(serializedCard.body).assertEqual('Completed');
      expect(objectCard.variant).assertEqual('report');
      expect(objectCard.defaultExpanded).assertFalse();
      expect(serializedRow.content).assertEqual('{"orcaSource":"worker","content":"  Completed  "}');
    });

    it('orca_sender_titles_use_host_metadata_and_safe_localized_arguments', 0, () => {
      const message = presentationOrcaMessage('worker', 'Done');
      const origin: Record<string, Object> = {};
      origin['kind'] = 'orca';
      origin['senderLabel'] = '「Reviewer」\nnext';
      message.agentMeta['origin'] = origin;
      const card = projectOrcaPersistedMessage(message) as OrcaCollabPresentation;
      expect(card.titleKey).assertEqual('interaction.collab.fromWorkerNamed');
      expect(readStr(card.titleArgs, 'role')).assertEqual('"Reviewer" next');
      expect(origin['senderLabel']).assertEqual('「Reviewer」\nnext');
      origin['kind'] = 'unknown';
      const unknownCard = projectOrcaPersistedMessage(message) as OrcaCollabPresentation;
      expect(unknownCard.titleKey).assertEqual('interaction.collab.fromWorker');
      expect((projectOrcaPersistedMessage(presentationOrcaMessage('lead', 'Next')) as OrcaCollabPresentation).titleKey)
        .assertEqual('interaction.collab.fromLead');
    });

    it('orca_dispatch_fixture_has_explicit_record_types_and_exact_tool_matching', 0, () => {
      const worker: Record<string, Object> = {};
      worker['label'] = 'reviewer';
      worker['initial_task'] = 'Review';
      const workers: Object[] = [worker];
      const input: Record<string, Object> = {};
      input['workers'] = workers;
      const original = JSON.stringify(input);
      const batch = projectOrcaDispatchCard('mcp__orca_lead_bridge__create_workers', input) as OrcaCollabPresentation;
      expect(batch.body).assertEqual('reviewer: Review');
      expect(batch.titleArgs['count']).assertEqual(1);
      expect(batch.defaultExpanded).assertFalse();
      expect(orcaCollabCanExpand(batch)).assertTrue();
      expect(projectOrcaDispatchCard('create_workers_backup', input)).assertEqual(null);
      expect(JSON.stringify(input)).assertEqual(original);
    });

    it('orca_unknown_or_nontext_content_is_not_stringified_into_a_card', 0, () => {
      const hiddenMetadata: Record<string, Object> = {};
      hiddenMetadata['privateId'] = 'not readable';
      const card = projectOrcaPersistedMessage(presentationOrcaMessage('worker', hiddenMetadata)) as OrcaCollabPresentation;
      expect(card.body).assertEqual('');
      expect(card.bodyKey).assertEqual('interaction.collab.emptyMessageBody');
      expect(projectOrcaPersistedMessage(presentationOrcaMessage('unknown', 'Normal'))).assertEqual(null);
      const blankCard = new OrcaCollabPresentation();
      blankCard.body = ' \n ';
      expect(orcaCollabCanExpand(blankCard)).assertFalse();
    });
  });
}
