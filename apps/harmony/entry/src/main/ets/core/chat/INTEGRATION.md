# Module C integration contract — 2026-11-28

Reference remains `91179cedad`. Shared ownership: Lead alone edits AppServices, CloudChatRuntime, routes, registered tests and public pages. All code here is production-path implementation behind injected account/host ports; no module verification result is claimed until Lead runs Harmony checks. No worker build/install/signing change has been performed.

## Existing constructor contracts are unchanged

- `createChatAuthenticatedRequest(auth, chatApiBaseUrl, current)` → `ChatRequest(path,method,body?,actorId?):Promise<Object>`. Chat paths INCLUDE `/v1`; endpoint comes from account/realm discovery and never the selected relay.
- `new ChatServerApi(request)`; `new ChatOutbox(initializedSecureStore)`; `new ChatStore(stableOwner,api,outbox)`.
- `stableOwner` is account + realm + endpoint, WITHOUT transient session epoch so restart can restore. The request `current()` closure checks epoch and account. `store.restore()` restores outbox and attached cached roster; it never automatically replays sends.
- `store.attachRoster(new ChatRosterPreferences(secureStore))` and `store.attachHistory(new ChatHistory(owner,api,historyStorage,current,newId))`.
- `ChatHistoryPreferences` remains compatible with the Lead's existing composition root (bounded fallback: eight room snapshots per owner, 4MiB/room). Prefer `ChatHistoryFiles(context,current)` when ability context is available: it atomically replaces one room file, caps a room at 4MiB, keeps at most 32 room files per owner and isolates filenames with SHA256(owner). Files are app-private derived data, never tokens. Before actual logout: await store.shutdown(), then await files.clearOwner(oldOwner), then clear auth. Preferences-backed caches are cleared by existing SecureStore.clearSensitive.

## Shutdown guarantee

`ChatStore.shutdown()` returns one retained promise, published BEFORE dispose notifications (including reentrant calls). It invalidates state immediately, starts history, roster and outbox drains together and awaits every drain even if one rejects; only then can it report an error. Repeated shutdown returns that same settled/rejected promise. Writes cannot start after the store generation is invalidated; list persistence rechecks generation after notifications.

Root must not chain another old store behind an unrecovered rejected closeTail: use a recovered chain before appending the next shutdown, while reporting the original failure separately. No root implementation was changed by this worker.

## List and detail realtime: exact scope usage

`ChatSubscription(store,endpoint,token,current,createSocket?)` constructor is unchanged. It now supports `store.page === null` (list-only):

1. While chat list OR chat detail is visible and foreground, keep ONE subscription instance. Stop it when neither is visible or on background/logout. Recreate on room/thread identity change.
2. Call `socket.setListVisible(listActuallyVisible)` before `start()`. On a folded phone detail pass false; on chat list or expanded split pane with left chat list pass true. Default without the setter is list-visible only when page is null.
3. Root socket scope key must include a list-only sentinel, e.g. visible/current/me ? JSON.stringify([page?.room.id ?? 'list',page?.threadRootId ?? '',listVisible]) : ''. A page-required condition incorrectly disables list realtime.
4. On ready the module reads `/v1/changes?scope=actor:<actorUUID>&after=0&limit=1`, captures `head` BEFORE reloading the roster, then subscribes `actor:<actorUUID>`. `RESET_REQUIRED` starts at 0 and uses the socket's reset head. Membership/read/list-state events update the directory and visible room.
5. If a detail exists, the SAME socket additionally subscribes `conversation:<roomUUID>` after its durable history cursor. Incoming message/reaction deltas commit cache before ACK. It uses at most TWO scopes, not one per room (official limit is 16).
6. IMPORTANT: actor scope does NOT announce every other room's new message. Official Mobile also reads conversation room heads every 30s while the list is visible (`useChatServer.ts` lines 335–378). The module implements that SAME 30s coalesced list-only read, stops it when list is hidden, honors account-level 429 cooldown and fetches changed visible summaries with global maximum four requests. No polling remains when the entire surface is hidden/backgrounded.
7. Scope failure on a removed room does not reset Device Link or unrelated rooms. Actor/list reset re-reads authoritative list-state; `conversation.list.changed` revisions govern personal hidden items, not fake archive/delete.

## History, delivery and permission

`ChatHistory` implements same-owner durable snapshots/pages/cursor, decimal precision, loaded old-page edits/tombstones, revision guards, bounded catch-up (20 × 100), membership/reset bootstrap with a new generation, reaction/root aggregate re-read, and metadata preference verification on foreground sync. It retains at most 40 page windows per room and 4000 idle in-memory messages. Failed persistence does not publish/ack the staged cursor. Store generation changes discard old loaded pages; otherwise older paging cursor is preserved. Offline history is explicitly unverified and cannot authorize a write; fresh permission snapshots precede sends/settings. Explicit 403/404 purges durable room before offline fallback. Cached roster allows offline entry after restart without showing a prior account's list.

Outbox persists the EXACT original body before POST, retains operationId on unknown receipts, and manual retry never rebuilds quote/recipients/attachments. No reconnect auto-send. `send(body, quoteId?, onEnqueued?)`, `retry`, `markRead(visibleIds,atEnd,foreground)`, `react`, `loadOlder`, `loadTopics`, `loadMentions`, `locate`, `manage`, `inviteLink`, `setHidden` are public production Store actions. The optional enqueue callback preserves older callers and transfers composer ownership only after the first durable write. Settings also retain prepared exact body/revision/actor for uncertain operation retry.

Cloud companion detail alignment was verified against `useCloudCompanionRoom.ts`: it is READ-ONLY cloud history. `openCompanion(actor)` resolves the fixed direct room with official stable operation ID/SHA256 conflict fallback. `ChatWorkspace` suppresses composer/actions there; ordinary companion work continues through the EXISTING computer main conversation. `ChatListPresentation` merges real local TeammateRosterEntry rows with cloud actor directory by externalId+canonical homeDeviceId, preserves existing main conversations, suppresses stale copies and never invents a device identity.

## Native components and additional ports

- `ChatWorkspace`: embedded list/detail; props store/locale/foreground/localCompanions; callbacks onLocalCompanion (existing main chat), onCompanion (optional override; default opens readonly cloud history), deviceName, onBack, onSettings, onMedia. It supplies measured read position, main/topic drafts and anchors, quote/send/retry controls, emoji reactions, member/@all picker, explicit topic/mention index and locate/highlight. List/group/avatar/summary/unread sorting use actual snapshots.
- `attachmentPicker:ChatAttachmentPickerPort` can be supplied as `new ChatAttachmentPicker(context,chatRequest,current)`. This implementation opens native photo/document pickers and uploads through actual Chat Server media reservation → signed PUT without Cindy token → complete. Only sealed media blocks enter the durable outbox. It reuses existing URI/image readers. Limit 20 attachments/message and 100MiB/file, as official Mobile. `onMedia(room,id)` uses `api.media` for the authorized URL and Lead's existing media preview surface; no message filesystem path grants access.
- `ChatSettingsPanel`: store, locale, optional shares, pickAvatar, confirm. It supports role-gated name/archive/restore, nickname/avatar, notifications, invitation, own bots, roles/removal/transfer, own-bot access, allow-member-invites/@all toggles, leave/dissolve. Destructive buttons are absent unless `confirm(title,body):Promise<boolean>` is supplied; their five-language confirmation explains actual impact. Server role is re-read before every write, and archived/dissolved scopes fail closed.
- For avatars use `pickAvatar:()=>pickChatAvatar(publicAssetRequest,current)`. It uses actual `/api/oss/presign-put` scene=avatar, native resize to 512px and <=5MiB, exact signed PUT headers, then updates only the public URL.
- Share/OSS auth ports can be built with `createAuthenticatedCloudRequest(auth,discoveredCindyEndpoint,'/api/',current)`; same AuthStore/token refresh, HTTPS/no-redirect, no credential copies. Never pass an incoming invite hostname. `ChatInviteShareClient(shareBase,region,realm,shareRequest,current)` handles actual Share Server create/opaque resolve. `ChatInvitePanel` + `ChatInvitationStore(owner,api,shares,newId,current)` keep preview read-only, join explicit and uncertain retry on the same operation; disposal drops late navigation.
- `ChatGroupCreatePanel(adapter,actors,locale,onCreated,onReviewUnknown)` creates only through the selected real computer resource action. Parses actual navigate effects; no guessed cloud create body or local fallback.
- `ChatCards` + timeline present task/plan/process snapshots as readable structured cards. `onOwnedTask(target)` is only offered for a server-identified account-owned bot and a device accepted by injected `canControlDevice(deviceId)`. Root reuses existing task/process viewer. A card never grants another account's session or filesystem access. The exact owned process source is existing `local-db:messages:around-client-id(sessionId,clientId,{radius:80})`; unrestricted task history is not a fallback.

## Original computer-resource path

`ChatResourceAdapter(invoke,actualDeviceId,locale)` calls `maker:remote-resources:list/get/invoke` with collection `bot-groups`, kind `bot-group`, primitive `bot-group-chat`. Injected invoke returns the unwrapped authorized resource/action payload, not a tunnel envelope. `ChatResourceStore(owner,groupId,adapter,ChatHostPersistence)` and `ChatResourceWorkspace` implement actual host projection/text/attachment send, exact clientId outbox and measured host read forwarding. Host workspace reuses existing ComposerImageQueue/ComposerFileQueue with actual target device; no cloud-room coercion. `ChatHostOutbox` uses initialized private SecureStore. Dispose/shutdown on account or host-route change. Root forwards filtered `maker:remote-resources:changed` to `store.refresh()` only for that host/group.

## Concrete official capability limits (not silently counted as implemented)

- At the pinned snapshot `useBotGroupChat` explicitly returns undefined for host-resource loadOlder/react/uploadAttachment/threadBackfill/followThread. Those absent resource-adapter operations must not become invented host protocol. IMPORTANT correction: its undefined `media` port does NOT mean received host media is unavailable: Mobile separately uses `useBotGroupRemoteMedia.ts` and the original `device-link:media:fetch` / relay presign-get / temporary-object cleanup path. The latest host attachment implementation below preserves this origin through explicit native root media ports. Outbound real host attachment queues are available where `supportsAttachments===true`.
- Mobile chat client exposes no edit/retract endpoint in this snapshot. No PATCH/DELETE message API has been invented.
- Selected-host group create input is officially `{name,botIds}` with no operation ID. On a lost creation receipt the component disables duplicate create and asks for list review; it cannot prove a unique created group from its name. Reliable automatic create retry is blocked by that concrete official contract.
- Full live execution/process detail continues through the root's authorized existing task viewer port; another account's execution is display-only. No mobile Agent or private task-wide history fallback is added.
- Product acceptance still requires Lead main-entry wiring and real double-account/host tests. Images/files preview use onMedia/onOwnedTask existing native viewers rather than a new unrestricted web/file viewer.

## Validation receipt

`ChatStore.test.ets` currently contains 31 production-entry cases, including account isolation, persist-before-send/exact unknown retry, fresh role checks, precise reads, concurrent page coalescing, preview-vs-join, durable delta/cursor failure, full shutdown drains, real share-service auth/origin, list/actor subscriptions, invite grammar, selected-host creation authority, captured UI account epochs, attachment-only host messages, passive-media transfer bounds, explicit retry, foreground lease replacement and precise durable draft handoff. No real timers/disk/socket/model waits in unit tests. Lead owns registration and ALL Hvigor runs; no results after the latest module edits are claimed by Worker. Compiled ArkTS diagnostics were repaired without relaxing linter.

## Concrete factory and earlier root wiring — historical handoff

The earlier root check found missing shares and list-only realtime. These are now resolved by the integrated ChatHomePanel and two-argument CloudChatRuntime.setVisible; the wiring snippets below document the underlying ports rather than further required root edits. Later review findings and their closure evidence appear below.

### Official share service, not an empty port

`createOfficialChatInviteShares(auth,scope,http?)` in `ChatInviteShares.ets` is the directly usable production factory. Pass existing AuthStore as auth. Scope is named `ChatInviteServiceScope {region:string; realm:string; current:()=>boolean; shareBaseUrl?:string}`; optional HTTP implements `ChatCloudHttp` (HarmonyHttp is the default). Verified pinned endpoints: CN `https://share.cindy.com.cn` from `config/endpoint.json`; Global `https://share.cindy.app` from `endpoint.global.json`. Endpoint selection uses BUILD region, while request body authRealm uses account realm, matching Mobile. A discovered trusted share origin may override; incoming-link hostname never does.

Factory behavior is real HTTP: `/api/shares` create with Bearer from AuthStore and one 401 refresh, exact schema-1 attributed share receipt validation, public opaque `/api/chat-invites/:id/token` resolve without account header, 20s timeout and redirects disabled. It checks current account scope before/after each await. Signed/session secrets are never logged or written into routes.

For one-line complete composition use `createOfficialChatInviteServices(store.owner,api,auth,scope,http?)` from `ChatInviteServices.ets`, returning `{shares,invitation,dispose()}`. It constructs the real Share adapter AND `ChatInvitationStore` with native UUID operations. Existing factory/class signatures remain compatible.

In HomeModulePanel.prepareChat after obtaining store and checking current():

```ts
const api = services.cloudChat.api;
if (!api) throw new Error('CHAT_UNAVAILABLE');
const scope: ChatInviteServiceScope = {
  region: AppConfig.region, realm: AppConfig.region, current,
};
this.invites?.dispose();
this.invites = createOfficialChatInviteServices(store.owner, api, services.auth, scope);
```

Keep `invites:ChatInviteServices|null` in the root, dispose on scope replacement/unmount, and pass `shares:this.invites?.shares ?? null` into ChatSettingsPanel; pass `invitation:this.invites?.invitation ?? null` into ChatWorkspace. The latter now contains a real manual invite entry/preview/join panel in its list view, opens the returned group only after explicit join and keeps uncertain joins on the same operation. No deep-link token needs to enter a route; root may call invitation.read(link) from its existing system invite dispatcher.

Settings now also offers revoke for its generated invitation link. It calls actual Chat Server `/v1/conversations/:id/invite-links/revoke` with live owned manager/self actor and stable operationId, then marks the public share page revoked best-effort. Failure of public-page cleanup cannot turn authoritative revocation into failure. This matches official Mobile's two-attempt public cleanup boundary.

### Current list realtime root change (required)

Replace the page-required runtime scope decision with the equivalent of:

```ts
const listVisible = page === null || page === undefined;
const scope = this.visible && this.foreground && current() && store?.me
  ? JSON.stringify([page?.snapshot.room.id ?? 'list', page?.threadRootId ?? '', listVisible]) : '';
```

Retain existing stop/recreate when scope changes. Before socket.start call `socket.setListVisible(listVisible)` (if expanded UI actually keeps the module chat list alongside detail, root supplies true there). All existing ChatSubscription constructor arguments still work; optional sixth clock port is only a deterministic test seam.

List-only ready now subscribes actor:<id> even with no page. Actor directory events refresh companion directory; personal read/membership events invalidate relevant summary even when room.head is unchanged; pure work.available hints are acknowledged without any mobile HTTP reload. Ordinary new messages in other groups require official Mobile's same 30s visible-list head read because actor scope does not broadcast every conversation message. Hiding stops it immediately. Authentication deadline ends on the ready frame, not after potentially slow history/list reads. Detail uses the same socket's conversation scope and durable ACK rules.

### Tests added for this handoff

Module tests now total 17 cases. New production-boundary cases exercise official Share factory CN origin vs auth realm, 401-refresh headers/no-redirect/time budget, untrusted input hostname remaining local-only and public resolution without token, account switch before receipt exposure, list-only actor subscription and hidden-list polling cancellation/work-hint no-read, unchanged-head personal read updating unread, actor event refreshing companion directory without detail, and authoritative revoke surviving failed public-share cleanup. HTTP/socket/clock are injected in memory; no timer waits/network/model calls. Prior Lead report was 565 tests pass BEFORE these additions. Worker has not run build or tests.

## Native ChatHomePanel — replace the public chat branch with one component

`components/chat/ChatHomePanel.ets` now composes all module-native entry points. It owns no global AuthStore, cloud Store/API, Device Link or socket. It locally wires existing ChatWorkspace, cloud settings, real avatar upload, real share/invite bundle, native attachment picker, computer-group directory, capability-checked group create, ChatResourceWorkspace and declared host settings. Thus the root does not need to maintain separate settings/invite/create mode booleans or leave those callbacks empty.

Required inputs for the complete cloud + computer flow:

- `cloudStore:ChatStore`, `cloudApi:ChatServerApi`, existing `auth:AuthStore`.
- `scopeKey:string` changes on account/realm identity changes; `current:()=>boolean` is the captured account/epoch guard. Component generation additionally fences its own async work. `foreground:boolean` follows actual app foreground.
- `selectedDevice:string` is the real chosen owned computer; `resourceInvoke:ChatRemoteInvoke` must open/authorize the link and return the UNWRAPPED existing resource result. The current root's `services.invokeOwnedModule(device,channel,args)` is the exact suitable implementation; do not feed a raw DlInvoke envelope.
- `canControlDevice(device):boolean` supplies current same-account control grant. `deviceName(device)` supplies display name. An empty selectedDevice disables create until a real computer is chosen; optional `onSelectDevice` opens the root's existing picker.
- `onCloudVisibility(visible,listVisible)` must delegate visibility to the EXISTING CloudChatRuntime, preventing hidden cloud polling/socket activity while the user is in host/create pages. ChatHomePanel never creates a second subscription. Its cloud page does not show an internal group list concurrently with detail, so current CloudChatRuntime's `setListVisible(page==null)` matches this panel. Pass `visible` to runtime.setVisible and stop the old unconditional visible=true code from overriding child navigation.

Recommended inputs: initialized `secureStore` (optional fallback initializes another wrapper around the SAME existing private preference namespace, never another auth singleton), locale, region/realm, AppConfig chat/share/oss bases, localCompanions/onLocalCompanion, onOwnedTask, onMedia and onClose. The component itself creates the correct official share/avatar services from these endpoints and existing auth. Without endpoint overrides it derives CN/Global share and OSS origins from region; Chat Server is the verified shared `https://chat.cindy.app`.

For live computer-group projection, pass `subscribePush:ChatHomePushSubscribe` as a wrapper around current `services.onModulePush(listener)`. Only actual `maker:remote-resources:changed` for the selected device and `bot-groups` collection triggers a read. An open group also filters resourceRefs to its own id. `link-closed` invalidates host content; no global peer reset or polling is added. Manual refresh and foreground restore remain available.

A root builder can use:

```ts
ChatHomePanel({
  cloudStore: this.cloud, cloudApi: services.cloudChat.api, auth: services.auth,
  scopeKey: accountEpochKey, current: accountCurrent, foreground: this.foreground,
  selectedDevice: chosenComputerId, locale: this.locale,
  region: AppConfig.region, realm: AppConfig.region,
  chatBaseUrl: AppConfig.chatApiBaseUrl, shareBaseUrl: AppConfig.shareBaseUrl,
  ossBaseUrl: AppConfig.ossApiBaseUrl,
  resourceInvoke: (device, channel, args) => services.invokeOwnedModule(device, channel, args),
  subscribePush: listener => services.onModulePush(listener),
  deviceName: device => services.tasks.getDeviceName(device),
  canControlDevice: isOwnedControllableDevice,
  localCompanions: this.localCompanions, onLocalCompanion: this.onLocalCompanion,
  onOwnedTask: target => this.onOpenTask(target.deviceId, target.sessionId),
  onMedia: (room, id) => { void this.preview(room, id); },
  onCloudVisibility: visible => services.cloudChat.setVisible(visible),
  onClose: this.onClose,
})
```

Use explicit parameter types when copying into ArkTS; the snippet abbreviates existing root callbacks. Root keeps its existing image preview overlay. Remove the root's separate ChatSettingsPanel branch, local picker and invite construction for this branch; the new panel owns those instances. AppServices/CloudChatRuntime still own the cloud lifecycle and socket.

Security/lifecycle: computer group stores register their exact shutdown with `cloudStore.registerOwnedDrain`. Existing root cloud shutdown now waits every registered child host durable write as well as history/roster/cloud-outbox, including when one drain fails. Unmount immediately invalidates the host store and only unregisters its drain AFTER it settles; this prevents a private host outbox write from resurfacing after AuthStore clears preferences. Rapid device/group switches use a navigation fence. No new singleton or global logout hook is installed.

Host capability/list logic is in `ChatHostDirectory`: real manifest → actual `bot-groups` list/pagination; create availability comes from the declared collection action and is rechecked by the adapter before create. Source identity is always the chosen actual device. Host settings only execute freshly declared actions; rename/leave/dissolve never fall back to a guessed cloud or local delete API. Missing host-specific richer features remain explicitly as described above.

### run7 invite parsing correction

The two reported C runtime errors occurred during platform URL-based candidate filtering in parseChatInviteReference. It now parses the narrowly defined canonical share/native/token grammar without platform URL objects, preserving strict credentials/query/hash/port/non-loopback HTTP/ambiguous-link rejection and never treating the input hostname as a network endpoint. Existing failing assertions were preserved. Added accepted canonical CN/embedded/localhost/IPv6-loopback and rejected ambiguous/credential/query/hash/invalid-port matrix coverage, plus child host-drain and actual host-directory/create-permission tests. Module now has 20 cases. No test/build was run by Worker; Lead's run7 result precedes these fixes/additions.

### Initial explicit deep-link/system-share invitation

ChatHomePanel now exposes `@Prop initialInvitation:string=''`. Pass the root's in-memory `request.invitation` directly. When the panel is ready, current and foreground, it switches into its actual ChatInvitePanel preview surface and calls ONLY `invitation.read(link)`. It does not call accept/join. The sole join/open action remains the explicit button in ChatInvitePanel; successful user acceptance then loads/opens the returned authorized group. Before ready or while backgrounded, the prop is retained and processed on readiness/foreground. Repeated rendering or foreground recovery with the same account-scope+link does not restart the preview or reopen a dismissed intent. A changed account scope disposes the prior invitation and re-reads its target under the new identity.

Native back from preview returns to the cloud list without joining; back is guarded while an accept request is active. ChatInvitePanel's initialInput only fills visible text and NEVER triggers network or join itself. Link resolution still uses the configured official Share service, never the incoming hostname. No token is copied into a navigation URL or persistent state.

Root's announced `cloudChat.setVisible(visible,listVisible?)` can now be used directly in the existing ChatHomePanel callback: `onCloudVisibility:(visible,listVisible)=>services.cloudChat.setVisible(visible,listVisible)`. No module-side WebSocket is added.

## Actual root integration review — after Build8

Read-only review covered CloudChatRuntime, HomeModulePanel, TaskListPage and IncomingShareSurface, with supporting AuthStore/AppServices and official snapshot sources. Public files were not changed.

Confirmed: actor/list sentinel and detail share one runtime socket; both visibility arguments are passed; actual foreground hooks stop the runtime. Owner+epoch invalidation precedes old-store drains. AppServices waits cloud shutdown before private preference clearing. The registered exact host-store drain remains registered until settled. Task/card and local-companion navigation use setSelectedTask, which closes moduleRequest; cards preserve the clientId anchor. System/deep-link invitation enters preview only, with explicit acceptance, fixed trusted share/OSS endpoints and real native avatar/picker ports.

Module fixes from this review:

- Captured AuthStore account+sessionEpoch now guard invite, avatar, attachment and host async ports even if root's mutable current-store predicate becomes true after rebinding. A production-entry helper test covers the smallest old-account/new-epoch rebound case.
- Cloud component preparation uses stable cloud identity, not transient Device Link route generation; switching/reconnecting a computer no longer disposes the cloud picker or discards cloud drafts. Host resources still follow their actual device/link scope.
- Already accepted invitations resume opening after foreground recovery; an explicit Open button retries navigation without replaying join. A later incoming invite arriving during an active join is deferred until that operation settles rather than silently marked consumed. Navigation respects back/new-intent fences.
- Host resource transport no longer requires a successfully fetched cloud me actor: the captured account and actual root-owned device permission authorize the original host path.
- Build8 CustomComponent.visibility collision is renamed syncCloudVisibility throughout.

Historical findings — all three closed in this implementation round:

1. **Closed — former P1, root account isolation.** Evidence at review: HomeModulePanel kept an already displayed mediaUrl across owner/epoch changes; invalidating only future await results did not clear the existing image, and TaskListPage left moduleRequest mounted. Current closure: HomeModulePanel.configure clears mediaUrl/mediaOwner and disposes the previous native media lease; the overlay additionally requires its captured mediaOwner to match mediaScope. TaskListPage.syncResidentAccount closes moduleRequest when the account epoch changes. These changes were verified in the actual root source; the former leak is not an outstanding implementation gap.
2. **Closed — former P2, root invitation error handling.** Evidence at review: IncomingShareSurface dropped inbox.openInvitation's Promise, so a ledger commit rejection after routing or a repeated press could become unhandled without visible recovery. Current closure: onOpenInvite enters the real openInvitation handler, which enforces busy state and owner/epoch scope, catches failures into the visible error surface and refreshes in finally. The core's durable consume semantics and explicit preview-before-join behavior remain intact.
3. **Closed — former P1, received host attachments and native wiring.** Evidence at review: ChatResourceStore discarded received attachments and ChatResourceWorkspace displayed only author/body, hiding the sole content of attachment-only messages. Official useBotGroupRemoteMedia already supplied the authorized device-link:media:fetch route. Current closure: the module preserves ordered attachment metadata, loading/unavailable placeholders and opaque context-bearing references; native rows provide thumbnails, explicit retry and original/file opening. HomeModulePanel connects both agreed host callbacks to page-owned OwnedHostMedia using the actual device, separate from cloud onMedia. Original references, account/foreground fences and queue cleanup are implemented and have production-path unit coverage.

Closure above means implemented and source-reviewed, not complete device acceptance. The Lead reported Run14 with 671 passing tests; the later durable composer handoff changes have a separate validation boundary below. This worker did not start Hvigor/tests/install. Real device checks remain required for native image/file opening, foreground recovery, account switching, Light/Dark and narrow/wide layouts; no claim of all-device or all-real-account success is made.

## Received computer-group attachments — native handoff

ChatHomePanel exposes the exact two agreed inputs (also forwarded to ChatResourceWorkspace):

```ts
resolveHostMedia:(deviceId:string,reference:string,thumbnail:boolean)=>Promise<string>
onHostMedia:(deviceId:string,reference:string,name:string,mime:string)=>void
```

Root wiring is `resolveHostMedia:(device,reference,thumbnail)=>services.ownedMediaUrl(device,reference,thumbnail)` and `onHostMedia` opens the original/file viewer through that same owned-host resolver with `thumbnail=false`. This remains completely separate from `onMedia(cloudRoomId,mediaId)`. ChatHomePanel checks the actual selected/controllable device, foreground, captured account epoch, host instance and route source before/after passive resolution. Root must retain its own epoch/route check for the full viewer and media transfer.

`ChatResourceStore.refresh` now projects the original attachment sequence into `ChatHostAttachment[]`, including pending/unavailable records and empty captions. Tombstones expose no attachments. `reference` keeps the entire original URL byte-for-byte, including encoded sessionId/remoteHostId/workdir query context. Only an actual attachment path on older hosts uses the official xdt-file://open?path fallback; no context is borrowed from a group folder, task card, filename or message text. Unsupported schemes remain visible but unavailable. Newer controllers deliberately receive path:null from botGroupRemoteChatData, so a name-only file honestly shows that it cannot yet be fetched rather than inventing a path or hiding it.

`ChatHostAttachmentRow` renders each attachment within its original message bubble, including attachment-only messages, in sent order. Five-language loading/unavailable/on-computer placeholders stay in place. Ready image rows lazily resolve thumbnail=true only while visible and foreground; tapping any ready address calls onHostMedia with the original reference/name/MIME, never the thumbnail URL. Native Image preserves picture proportions within the thumbnail viewport; filenames wrap and retain the full name for the viewer.

`ChatHostThumbnailQueue` is workspace-instance owned: duplicate keys coalesce, thumbnail/original keys differ, at most two transfers and 64 outstanding distinct jobs, hidden queued work is discarded before dispatch, passive failures have 20s cooldown without timers, cached URL/data-URI strings have a 16MiB/128-entry bound and short reuse lifetime. Unmount releases queued waiters/cache; old-account/closed-host results cannot publish. No media URLs are persisted. Since the agreed root resolver returns only a string (not an OSS key or release lease), the root transfer layer owns temporary-object/orphan cleanup and AgentNet release; the module cannot infer an object key from a signed URL or delete an existing attachment.

Three production tests were added at this stage using a real ChatResourceStore.refresh through the original host adapter and in-memory ports: attachment-only ordering/context/pending/deleted projection; transfer deduplication/concurrency and thumbnail-vs-original separation; invisible queued work and late former-account response rejection. The module count was 24 at this historical checkpoint; see the validation receipt for the current count. This worker did not run checks, per serial verification ownership.

### Root media lease alignment and explicit retry

Read-only inspection of the integrated HomeModulePanel and OwnedHostMedia confirms the exact two public callbacks match: thumbnail requests use the page-owned resolver; open passes original reference to previewHost and resolves thumbnail=false. Home clears existing preview and disposes its media lease on scope/foreground changes; leaving the parent disposes the lease. The module workspace releases its queue/cache and rows clear their URLs on disappear.

The follow-up adds a visible Retry action when thumbnail resolution or native Image decoding fails. Queue.retry evicts that key's cached URL and passive failure cooldown and performs another bounded/coalesced read; passive scrolling retains the 20s cooldown. Image geometry/ratio notifications do not repeatedly reset a visible failure. Clicking the main attachment still opens the original; it does not confuse a failed thumbnail with an unavailable source. Missing image MIME uses image/* viewer intent rather than misrouting a known image to a generic file handler.

Home also replaces/disposes its media lease while backgrounded. The still-mounted host workspace resets its own URLs/cache/pending requests on background, fences old in-flight results by queue generation (even after a quick foreground resume), and loads again on foreground. A previous generation's finalizer cannot delete a new same-key job. Two further production tests exercise explicit retry through failure/cached-image branches and background lease reset with overlapping old/new same-key responses. The module count was 26 at this historical checkpoint; these changes postdated Build12 and preceded the Lead's reported successful Run14.

The following two adapter findings are also closed by Root; public files were not modified by this worker:

- **Closed — xdt-file references.** OwnedHostMedia formerly rejected xdt-file:// despite the actual attachment contract and older-host fallback. It now accepts that scheme through the existing authorized media fetch, preserving encoded path/sessionId/remoteHostId/workdir context instead of granting bare-path access.
- **Closed — deleted temporary upload keys.** Evidence: disposing/evicting a temporary OSS object could leave the computer's cindy-media/xdt-image upload cache returning the deleted key; a module URL-cache retry alone could not repair it while skipCache remained false. Root now passes skipCache=true as the fetch port's fifth argument and AppServices forwards it to the existing MessageStore.fetchRemoteMedia option. UI deduplication still bounds requests, temporary-key capacity is 128, and original attachments are not deleted. Root added the actual service-port regression `reopening_a_cleaned_host_picture_bypasses_the_computers_stale_upload_key` in V139Integration.test.ets. This is a completed implementation/regression addition; device acceptance remains pending as stated above.

## Durable composer snapshot handoff

The send review found real data-loss and duplicate-intent paths: host completion cleared newly typed text; cloud used page-object/text equality to clear an entire mutable composer, restoring sent away-thread drafts or deleting later attachments; both Stores could throw a later unknown-state persistence failure after the outgoing intent was already durably queued, leaving a fresh-send composer alongside its original pending ID.

Both existing Store APIs retain their await-delivery semantics and add an optional callback:

```ts
ChatStore.send(body:ChatSendBody,quoteId:string='',onEnqueued:(()=>void)|null=null):Promise<void>
ChatResourceStore.send(text:string,botIds:string[],clientId:string,attachments:RemoteSerializedAttachment[]=[],onEnqueued:(()=>void)|null=null):Promise<void>
```

The callback fires once after the exact first durable write and before the RPC. Old callers need no changes. Workspace consumers transfer only the captured composer snapshot at this point, so a later network or unknown-state-write failure cannot return the same intent to a new-UUID Send button. Unknown pending operations remain visible and retry the original body/ID. Failure of the initial write performs no handoff, removes the unaccepted in-memory pending row and dispatches no RPC, preserving the editable draft without leaving a phantom retry. Retry is blocked while an operation is still obtaining initial durable ownership. Host outbox input is deep-cloned so later mutable attachment references cannot alter the captured body.

Cloud uses the production ChatDraftBook, keyed by existing account/room/thread identity, for both active and away-page drafts. Durable handoff consumes the originating key independently of page-object replacement, metadata refresh or thread navigation. Text has an edit revision; a new edit survives even if its text is subsequently equal to the original. Only exact captured attachment blocks are removed; newly uploaded blocks remain. Explicit quote/mention edits have independent revisions and survive an older handoff. Existing workspace pick/quote/mention/text controls update these versions. Host applies the same text-revision rule and removes only its captured local attachment IDs. Neither workspace performs a whole-composer clear after waiting for the RPC.

An already accepted RPC response is kept accepted even if persisting its row removal fails: it surfaces the persistence error without relabeling the detached row unknown or offering an in-process retry. If the app crashes while receipt cleanup cannot be persisted, the previous durable operation may still be restored; there is no automatic replay and any manual retry retains its original server-idempotent ID. No local implementation can claim a durable new receipt while storage writes are failing.

Five additional unit cases exercise the actual Store/adapter/consumer helpers: away-key and later text/file/quote/mention preservation; original-host unknown plus second-write failure; cloud unknown/second-write failure while navigating a real Store thread; both Stores' first-write failure; and both Stores' accepted receipt with cleanup-write failure. No timers or native I/O. Total 31. The Lead's reported Run14 (671 passing tests) predates these changes; this worker has not started tests or builds, and the new module changes await serial verification.
