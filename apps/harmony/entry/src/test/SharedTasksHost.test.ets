import { sharedTaskInvitationServer, parseOfficialSharedTaskInvitation, buildOfficialSharedTaskInvitation } from '../main/ets/core/shared-tasks/SharedTaskInvitation';
import { describe, expect, it } from '@ohos/hypium';
import { WsAdapter } from '../main/ets/network/WsAdapter';
import { HelloPayload } from '../main/ets/core/device-link/DlProtocol';
import { createSharedTasksHost, SharedTasksHostOptions, SharedTaskAuthenticatedRequest, SharedTaskAgentNetAdapter } from '../main/ets/core/shared-tasks/SharedTasksHost';
import { SharedTaskRequest, SharedTaskInvitation, SharedTaskDetail, SharedTaskFault } from '../main/ets/core/shared-tasks/SharedTaskModels';
import { SharedTaskMediaPorts, SharedTaskReadyTransport } from '../main/ets/core/shared-tasks/SharedTaskGuestClient';
import { recordOrEmpty } from '../main/ets/core/tasks/TaskModels';

// Unit tier: actual authority adapter's destination/epoch/fallback boundary. Store transport fakes
// cannot detect accidental self-host relay substitution. Minimal fixture: one request or one old receipt.
// No network, native engines, wall-clock sleeps or source-string reads.
function options(): SharedTasksHostOptions {
  const media: SharedTaskMediaPorts = { upload: async (): Promise<string> => '', fetch: async (): Promise<Object | undefined> => undefined };
  return { officialApiBase: 'https://official.invalid', officialWsUrl: 'wss://official.invalid/ws', app: 'cindy',
    accountId: (): string => 'account', scope: (): string => 'account:1',
    apiFetch: async (): Promise<Object> => JSON.parse('{"sharedTasks":[]}') as Object,
    ownerInvoke: async (): Promise<Object | undefined> => undefined, getToken: async (): Promise<string> => 'fixture',
    getHello: (): HelloPayload => new HelloPayload(), createOfficialWs: (): WsAdapter => { throw new Error('socket must not open'); },
    refreshAuth: (): void => {}, media, openOwner: async (): Promise<void> => {}, guestReady: (): void => {} };
}
class PinnedFailure implements SharedTaskAgentNetAdapter {
  parseInvitation(_input: string): SharedTaskInvitation | null { return null; }
  async request(_path: string, _options: SharedTaskRequest): Promise<Object | null> { throw new SharedTaskFault('failed'); }
  async join(_invitation: SharedTaskInvitation, _name: string, _current: () => boolean): Promise<Object | undefined> { throw new SharedTaskFault('unsupported'); }
  owns(_id: string): boolean { return true; }
  async open(_detail: SharedTaskDetail): Promise<SharedTaskReadyTransport> { throw new SharedTaskFault('unsupported'); }
  invitationLink(_token: string, _detail: SharedTaskDetail): string { throw new SharedTaskFault('unsupported'); }
  dispose(): void {}
}
export default function sharedTasksHostTests(): void {
  describe('SharedTasksHost', () => {
    it('official_invitation_normalizes_safe_host_port_and_base_path_without_sdk_url', 0, () => {
      const token = 'A'.repeat(43), base = 'https://official.invalid/root';
      expect(sharedTaskInvitationServer('HTTPS://Official.INVALID:443/root///')).assertEqual(base);
      expect(sharedTaskInvitationServer('http://[0:0:0:0:0:0:0:1]:80/')).assertEqual('http://[::1]');
      const link = buildOfficialSharedTaskInvitation(token, base, 'cindycn');
      expect(parseOfficialSharedTaskInvitation('Task https://ordinary.invalid/page ' + link, base)?.invitation).assertEqual(token);
    });
    it('official_invitation_rejects_credential_escaped_authority_query_and_ambiguous_links', 0, () => {
      const token = 'A'.repeat(43), base = 'https://official.invalid', good = base + '/shared-task/join#' + token;
      const invalid: string[] = [
        'https://user@official.invalid/shared-task/join#' + token,
        'https://official%2einvalid/shared-task/join#' + token,
        base + '/shared-task/join?invitation=' + token,
        good + ' https://user@official.invalid/shared-task/join#' + token,
        good + ' ' + good,
      ];
      for (const value of invalid) expect(parseOfficialSharedTaskInvitation(value, base) === null).assertTrue();
      expect(sharedTaskInvitationServer('https://official.invalid:65536')).assertEqual(null);
      expect(sharedTaskInvitationServer('https://official.invalid/%2e%2e')).assertEqual(null);
      expect(sharedTaskInvitationServer('http://public.invalid')).assertEqual(null);
    });
    it('foreign_official_invitation_reports_source_mismatch_without_substituting_api_base', 0, () => {
      let code = '';
      try { parseOfficialSharedTaskInvitation('https://foreign.invalid/shared-task/join#' + 'A'.repeat(43), 'https://official.invalid'); }
      catch (error) { if (error instanceof SharedTaskFault) code = error.code; }
      expect(code).assertEqual('different-server');
    });
    it('native_official_handoffs_use_exact_routes_and_all_three_registered_schemes', 0, () => {
      const host = createSharedTasksHost(options()), token = 'A'.repeat(43), server = encodeURIComponent('HTTPS://Official.INVALID:443/');
      for (const scheme of ['cindy', 'cindycn', 'cindydev']) {
        for (const route of ['shared-task/join', 'shared-session']) {
          const parsed = host.parseInvitation(scheme + '://' + route + '?invitation=' + token + '&server=' + server);
          expect(parsed?.kind).assertEqual('official'); expect(parsed?.invitation).assertEqual(token);
          expect(parsed?.server).assertEqual('https://official.invalid');
        }
      }
      host.dispose?.();
    });
    it('native_official_handoff_rejects_wrong_authority_route_duplicates_hash_and_extra_query', 0, () => {
      const host = createSharedTasksHost(options()), token = 'A'.repeat(43), query = '?invitation=' + token + '&server=https%3A%2F%2Fofficial.invalid';
      const invalid: string[] = [
        'other://shared-task/join' + query, 'cindy://SHARED-TASK/join' + query,
        'cindy://shared-task/join/' + query, 'cindy://shared-task:80/join' + query,
        'cindy://user@shared-task/join' + query, 'cindy://shared-session/' + query,
        'cindy://shared-task/join' + query + '#', 'cindy://shared-task/join' + query + '&extra=value',
        'cindy://shared-task/join' + query + '&invitation=' + token,
        'cindy://shared-task/join' + query + '&%73erver=https%3A%2F%2Fofficial.invalid',
        'cindy://shared-task/join?invitation=' + token, 'cindy://shared-task/join' + query.replace(token, 'short'),
        'cindy://shared-task/join' + query.replace('https%3A', '%ZZ'),
      ];
      for (const value of invalid) expect(host.parseInvitation(value) === null).assertTrue();
      host.dispose?.();
    });
    it('foreign_native_server_is_comparison_metadata_and_never_selects_an_authenticated_api', 0, () => {
      const config = options(); let requests = 0;
      config.apiFetch = async (): Promise<Object> => { requests++; return JSON.parse('{}') as Object; };
      const host = createSharedTasksHost(config); let code = '';
      try { host.parseInvitation('cindycn://shared-task/join?invitation=' + 'A'.repeat(43) + '&server=https%3A%2F%2Fforeign.invalid'); }
      catch (error) { if (error instanceof SharedTaskFault) code = error.code; }
      expect(code).assertEqual('different-server'); expect(requests).assertEqual(0); host.dispose?.();
    });
    it('official_membership_request_uses_fixed_authenticated_base_no_store_and_12s_budget', 0, async () => {
      const config = options(); const seen: SharedTaskAuthenticatedRequest[] = [];
      config.apiFetch = async (_path: string, request: SharedTaskAuthenticatedRequest): Promise<Object> => { seen.push(request); return JSON.parse('{"sharedTasks":[]}') as Object; };
      const host = createSharedTasksHost(config), request: SharedTaskRequest = { method: 'GET', isCurrent: (): boolean => true };
      await host.request('/api/device-link/shared-tasks', request);
      expect(seen[0].baseUrl).assertEqual('https://official.invalid'); expect(seen[0].cache).assertEqual('no-store'); expect(seen[0].timeoutMs).assertEqual(12000); host.dispose?.();
    });
    it('failure_on_pinned_agent_net_authority_never_falls_back_to_official', 0, async () => {
      const config = options(); let official = 0; config.agentNet = new PinnedFailure();
      config.apiFetch = async (): Promise<Object> => { official++; return JSON.parse('{}') as Object; };
      const host = createSharedTasksHost(config), request: SharedTaskRequest = { method: 'GET', isCurrent: (): boolean => true }; let rejected = false;
      try { await host.request('/api/device-link/shared-tasks/share', request); } catch { rejected = true; }
      expect(rejected).assertTrue(); expect(official).assertEqual(0); host.dispose?.();
    });
    it('incomplete_agent_net_list_preserves_authority_incomplete_instead_of_claiming_empty_success', 0, async () => {
      const config = options(); config.agentNet = new PinnedFailure();
      const host = createSharedTasksHost(config), request: SharedTaskRequest = { method: 'GET', isCurrent: (): boolean => true };
      const result = recordOrEmpty(await host.request('/api/device-link/shared-tasks', request));
      expect(result['authorityIncomplete']).assertTrue(); host.dispose?.();
    });
    it('plain_authority_error_preserves_code_and_status_when_converted_to_throwable_error', 0, async () => {
      const config = options();
      const failure = JSON.parse('{"code":"NOT_FOUND","status":404}') as Object;
      config.apiFetch = (): Promise<Object> => Promise.reject<Object>(failure);
      const host = createSharedTasksHost(config), request: SharedTaskRequest = { method: 'GET', isCurrent: (): boolean => true };
      let code = '', status = 0;
      try { await host.request('/api/device-link/shared-tasks', request); }
      catch (error) { if (error instanceof SharedTaskFault) { code = error.code; status = error.status; } }
      expect(code).assertEqual('NOT_FOUND'); expect(status).assertEqual(404); host.dispose?.();
    });
    it('late_http_success_from_previous_account_is_rejected_after_auth_scope_changes', 0, async () => {
      const config = options(); let scope = 'account:1'; let finish: (value: Object) => void = (_value: Object): void => {};
      config.scope = (): string => scope;
      config.apiFetch = (): Promise<Object> => new Promise<Object>((resolve) => { finish = resolve; });
      const host = createSharedTasksHost(config), request: SharedTaskRequest = { method: 'GET', isCurrent: (): boolean => true };
      const pending = host.request('/api/device-link/shared-tasks', request); let rejected = false;
      const checked = pending.catch((): void => { rejected = true; }); scope = 'account:2'; finish(JSON.parse('{"sharedTasks":[]}') as Object); await checked;
      expect(rejected).assertTrue(); host.dispose?.();
    });
  });
}
