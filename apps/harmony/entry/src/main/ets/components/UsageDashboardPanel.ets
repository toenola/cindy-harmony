import { CapsuleSegmentButtonV2, SegmentButtonV2ItemOptions, SegmentButtonV2Items } from '@kit.ArkUI';
import { UiCard, UiListRow } from './common/UiList';
import { UiInlineError, UiEmptyState } from './common/UiStatus';
import { UiIconButton } from './common/UiActions';
import { uiToast } from './common/UiOverlay';
import { PluginEngineMark } from './PluginEngineMark';
import { PluginEngine, PluginUsage, PluginUsageBalance, PluginUsageWindow } from '../core/plugin-engines/PluginEngines';

import { PresenceSnapshot } from '../core/device-link/DlProtocol';
import { AppServices } from '../core/AppServices';
import { RelayRoute } from '../core/device-link/RelayRoute';
import { harmonyV12String } from '../core/HarmonyStrings';
import {
  UsageSnapshot, UsageSource, UsageSeries, UsageDay, UsageWindow, UsageTotals, usageCompact, usageSeries, usageTotals, usageRangeStart, usageHasModels,
  usageResetLabel, readUsageDashboard, usageCandidates,
} from '../core/usage/UsageDashboard';
import { UI_FONT_TITLE_L, UI_FONT_TITLE_S, UI_FONT_LIST_TITLE, UI_FONT_BODY, UI_FONT_SECONDARY, UI_FONT_CAPTION, UI_FONT_CAPTION_SMALL, UI_RADIUS_CONTENT, UI_SPACE_GROUP, UI_SPACE_PAGE } from './UiKit';

class PluginQuotaRow {
  engine: PluginEngine = new PluginEngine();
  usage: PluginUsage = new PluginUsage();
}
/** Same snapshot / grouping as iOS. Only visible openings and reconnects read the computer. */
@Component
export struct UsageDashboardPanel {
  @Prop @Watch('contextChanged') active: boolean = false;
  @Prop @Watch('contextChanged') pinnedDeviceId: string = '';
  scroller: Scroller = new Scroller();
  @State private rangeIndex: number = 0;
  @State private pickedDay: number = -1;
  @State private modelKey: string = '';
  @State private expandedQuota: string = '';
  @State private chartRows: UsageSeries[] = [];
  @State private summary: UsageTotals = new UsageTotals();
  @State private graphMax: number = 1;
  @State private snapshot: UsageSnapshot | null = null;
  @State private pluginQuotaRows: PluginQuotaRow[] = [];
  private pluginDeviceId: string = '';
  private pluginReadGeneration: number = 0;
  private pluginOpeningPending: boolean = false;
  private wasActive: boolean = false;
  @State private deviceName: string = '';
  @State private loading: boolean = false;
  @State private issue: string = '';
  @State private now: number = Date.now();
  @State private quotaGridWidth: number = 232;
  @State private chartWidth: number = 320;
  private mounted: boolean = false;
  private identity: string = '';
  private generation: number = 0;
  private request: boolean = false;
  private candidateKey: string = '';
  private reloadRequested: boolean = false;
  private timer: number = -1;
  private unsubs: Array<() => void> = [];

  private currentCandidateKey(): string {
    return usageCandidates(AppServices.instance.tasks.deviceList, '', this.pinnedDeviceId)
      .map((device: PresenceSnapshot): string => device.deviceId).sort().join(':');
  }

  aboutToAppear(): void {
    this.mounted = true;
    this.candidateKey = this.currentCandidateKey();
    this.unsubs.push(AppServices.instance.auth.onChanged(() => this.contextChanged()));
    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      const key = this.currentCandidateKey();
      if (key === this.candidateKey) return;
      this.candidateKey = key;
      if (this.active) this.contextChanged();
    }));
    this.unsubs.push(AppServices.instance.onStatus((status: string): void => {
      this.syncIdentity();
      if (status === 'online' && this.active) void this.refresh();
    }));
    this.contextChanged();
  }
  aboutToDisappear(): void {
    this.mounted = false; this.generation++; this.pluginReadGeneration++;
    this.unsubs.forEach((unsubscribe: () => void): void => unsubscribe()); this.unsubs = [];
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
  }
  private text(key: string): string { return harmonyV12String(this.getUIContext().getHostContext(), key); }
  private syncIdentity(): void {
    const identity = `${AppServices.instance.auth.sessionEpoch}:${RelayRoute.instance.generation}:${this.pinnedDeviceId}`;
    if (identity === this.identity) return;
    this.identity = identity; this.generation++;
    this.snapshot = null; this.deviceName = ''; this.issue = '';
    this.pickedDay = -1; this.modelKey = ''; this.expandedQuota = ''; this.rebuildUsage();
    this.clearPluginQuota();
    this.pluginOpeningPending = this.active;
    if (this.request) this.reloadRequested = true;
  }
  private contextChanged(): void {
    if (!this.mounted) return;
    this.candidateKey = this.currentCandidateKey();
    this.syncIdentity();
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    if (!this.active) {
      this.wasActive = false;
      this.pluginOpeningPending = false;
      this.generation++;
      this.clearPluginQuota();
      return;
    }
    if (!this.wasActive) this.pluginOpeningPending = true;
    this.wasActive = true;
    this.now = Date.now();
    // Countdown only; never a network poll.
    this.timer = setInterval(() => { this.now = Date.now(); }, 60000);
    if (this.request) this.reloadRequested = true;
    else void this.refresh();
  }
  private async refresh(manual: boolean = false): Promise<void> {
    if (!this.mounted || !this.active || this.request) return;
    this.syncIdentity();
    const loadPlugins = manual || this.pluginOpeningPending;
    this.pluginOpeningPending = false;
    if (loadPlugins) this.clearPluginQuota();
    const generation = this.generation;
    const epoch = AppServices.instance.auth.sessionEpoch;
    const route = RelayRoute.instance.generation;
    const pinned = this.pinnedDeviceId;
    const current = (): boolean => this.mounted && this.active && generation === this.generation
      && epoch === AppServices.instance.auth.sessionEpoch && route === RelayRoute.instance.generation;
    this.request = true; this.loading = true; this.issue = '';
    try {
      const result = await readUsageDashboard(AppServices.instance.client,
        AppServices.instance.tasks.deviceList, AppServices.instance.usageAutomaticDevice(), current, pinned);
      if (!current()) return;
      this.issue = result.issue;
      if (result.snapshot !== null) {
        if (this.pickedDay >= 0 && this.snapshot?.days[this.pickedDay]?.date !== result.snapshot.days[this.pickedDay]?.date) {
          this.pickedDay = -1;
        }
        this.snapshot = result.snapshot; this.deviceName = result.deviceName;
        this.rebuildUsage();
        if (this.pluginDeviceId && this.pluginDeviceId !== result.deviceId) this.clearPluginQuota();
        if (loadPlugins && AppServices.instance.appInForeground) {
          this.pluginDeviceId = result.deviceId;
          void this.readPluginQuota(result.deviceId, manual, current);
        }
        void AppServices.instance.syncUsageCards(result.snapshot, result.deviceId, result.deviceName, epoch, !!pinned).catch((): void => {});
      } else {
        this.clearPluginQuota();
        if (result.issue === 'unsupported') {
          this.snapshot = null;
          this.deviceName = '';
          if (!pinned) {
            void AppServices.instance.markUsageAutomaticUnsupported(result.deviceId, epoch).catch((): void => {});
          }
        }
      }
      this.now = Date.now();
    } catch (_error) {
      if (current()) this.issue = 'unavailable';
    } finally {
      this.request = false;
      if (this.mounted) this.loading = false;
      if (this.reloadRequested) { this.reloadRequested = false; if (this.mounted && this.active) void this.refresh(); }
    }
  }
  private clearPluginQuota(): void {
    this.pluginDeviceId = '';
    this.pluginReadGeneration++;
    this.pluginQuotaRows = [];
  }

  private async readPluginQuota(deviceId: string, manual: boolean, panelCurrent: () => boolean): Promise<void> {
    const app = AppServices.instance;
    const generation = ++this.pluginReadGeneration;
    const current = (): boolean => panelCurrent() && this.pluginReadGeneration === generation
      && app.appInForeground && this.pluginDeviceId === deviceId;
    const engines = await app.pluginEngines.load(deviceId, manual);
    const rows: PluginQuotaRow[] = [];
    for (const engine of engines) {
      if (!current()) return;
      if (!engine.reportsUsage) continue;
      const usage = await app.pluginEngines.readUsage(deviceId, engine.providerId);
      if (!current()) return;
      if (usage === null) continue;
      const row = new PluginQuotaRow();
      row.engine = engine;
      row.usage = usage;
      rows.push(row);
      this.pluginQuotaRows = rows.slice();
    }
  }

  private data(): UsageSnapshot { return this.snapshot ?? new UsageSnapshot(); }
  private accounts(): UsageSource[] { return this.data().sources.filter((s: UsageSource): boolean => s.kind === 'subscription'); }
  private rangeStart(): number {
    return usageRangeStart(this.data(), [1, 7, 30][this.rangeIndex]);
  }
  private rebuildUsage(): void {
    const snapshot = this.data();
    const start = this.pickedDay >= 0 ? this.pickedDay : this.rangeStart();
    const end = this.pickedDay >= 0 ? start + 1 : snapshot.days.length;
    const series = usageSeries(snapshot, this.text('usage_other'), start, end);
    const filter = usageHasModels(snapshot) ? series.find((row: UsageSeries): boolean => row.key === this.modelKey) : undefined;
    if (filter === undefined) this.modelKey = '';
    this.chartRows = series;
    this.summary = usageTotals(snapshot, start, end, filter);
    const displayed = filter === undefined ? series : [filter];
    this.graphMax = Math.max(1, ...snapshot.days.map((_day: UsageDay, index: number): number =>
      displayed.reduce((sum: number, row: UsageSeries): number => sum + (row.values[index] ?? 0), 0)));
  }
  private chartSeries(): UsageSeries[] {
    return this.chartRows.filter((row: UsageSeries): boolean => !this.modelKey || row.key === this.modelKey).reverse();
  }
  private dayActive(index: number): boolean {
    return this.pickedDay >= 0 ? this.pickedDay === index : index >= this.rangeStart();
  }
  private rangeLabels(): string[] {
    const locale = this.data().locale.toLowerCase();
    if (locale.startsWith('zh')) return [this.text('usage_today'), '近 7 天', '近 30 天'];
    if (locale.startsWith('ja')) return [this.text('usage_today'), '過去7日', '過去30日'];
    if (locale.startsWith('ko')) return [this.text('usage_today'), '최근 7일', '최근 30일'];
    return [this.text('usage_today'), 'Last 7 days', 'Last 30 days'];
  }
  private usageCopy(key: string): string {
    const locale = this.data().locale.toLowerCase();
    if (key === 'models') {
      if (locale.startsWith('zh')) return '僅顯示近 30 天常用模型，其餘合併為其他';
      if (locale.startsWith('ja')) return '過去30日間の主要モデルのみ。残りは「その他」に集約します。';
      if (locale.startsWith('ko')) return '최근 30일의 주요 모델만 표시하며 나머지는 기타로 합산합니다.';
      return 'Shows top models from the last 30 days. The rest are grouped as Other.';
    }
    if (key === 'unused') {
      if (locale.startsWith('zh')) return '依目前用量，重置時可能仍有剩餘額度';
      if (locale.startsWith('ja')) return '現在のペースでは、リセット時に利用枠が残る見込みです';
      if (locale.startsWith('ko')) return '현재 사용 속도라면 재설정 시 할당량이 남을 수 있습니다';
      return 'Some quota may remain at reset at the current pace.';
    }
    if (locale.startsWith('zh')) return '窗口 ' + key;
    if (locale.startsWith('ja')) return '期間 ' + key;
    if (locale.startsWith('ko')) return '기간 ' + key;
    return 'Window ' + key;
  }
  private today(): UsageDay { const days = this.data().days; return days[days.length - 1] ?? new UsageDay(); }
  private rangeCaption(): string {
    if (this.pickedDay >= 0) return this.data().days[this.pickedDay]?.date ?? '';
    const end = this.today().date;
    const start = this.data().days[this.rangeStart()]?.date ?? '';
    return start && start !== end ? start + ' – ' + end : end;
  }
  private todayLabel(): string {
    const date = new Date(this.now);
    const local = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
    return this.today().date && this.today().date !== local ? this.today().date : this.text('usage_today');
  }
  private modelRowDetail(series: UsageSeries): string {
    const estimate = this.showModelEstimates() && series.estimated !== null
      ? this.text('usage_estimated') + ' ' + this.money(series.estimated) : '';
    return [series.harness, estimate].filter((part: string): boolean => part.length > 0).join(' · ');
  }
  private showModelEstimates(): boolean {
    return this.chartRows.some((row: UsageSeries): boolean => (!this.modelKey || row.key === this.modelKey) && row.hasEstimate);
  }
  private money(value: number): string { return this.data().moneySymbol + value.toFixed(2); }
  private stale(): boolean { const d = this.data(); return this.now - (d.updatedAtMs || d.generatedAtMs) >= 3600000; }
  // P2-13: data-series colors are not action colors. Keep legend and chart on the same mapping.
  private tint(series: UsageSeries): Resource {
    if (series.other) return $r('app.color.usage_chart_other');
    const colors: Resource[] = [$r('app.color.usage_chart_teal'), $r('app.color.usage_chart_pink'),
      $r('app.color.usage_chart_purple'), $r('app.color.usage_chart_blue'), $r('app.color.usage_chart_amber')];
    return colors[series.colorIndex % colors.length];
  }
  private windowTint(color: string): Resource {
    if (color === 'claude' || color === 'claude2' || color === 'claude3') {
      return color === 'claude2' ? $r('app.color.usage_chart_pink')
        : color === 'claude3' ? $r('app.color.usage_chart_purple') : $r('app.color.usage_chart_amber');
    }
    if (color === 'codex') return $r('app.color.usage_chart_blue');
    if (color === 'warn') return $r('app.color.warn');
    if (color === 'crit' || color === 'error') return $r('app.color.danger');
    if (color.startsWith('ink')) return $r('app.color.text_tertiary');
    return $r('app.color.usage_quota_plenty');
  }
  private quotaTint(source: UsageSource): Resource {
    return source.level === 'error' ? $r('app.color.danger') : source.level === 'warn'
      ? $r('app.color.warn') : $r('app.color.usage_quota_plenty');
  }
  private notice(): string { return this.text(this.issue === 'offline' ? 'usage_offline'
    : this.issue === 'unsupported' ? 'usage_unsupported' : 'usage_unavailable'); }

  @State private pullRefreshing: boolean = false;

  private async pullRefresh(): Promise<void> {
    if (this.pullRefreshing || this.loading) return;
    this.pullRefreshing = true;
    try {
      await this.refresh(true);
      if (this.mounted && this.active && this.issue) uiToast(this.getUIContext(), this.notice());
    } catch (_error) {
      if (this.mounted && this.active) uiToast(this.getUIContext(), this.text('usage_unavailable'));
    } finally {
      this.pullRefreshing = false;
    }
  }

  build() {
    Refresh({ refreshing: this.pullRefreshing }) {
    Scroll(this.scroller) {
      Column({ space: 18 }) {
        Row({ space: 12 }) {
          Text(this.deviceName).fontSize(UI_FONT_BODY).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary')).maxLines(2).layoutWeight(1)
          UiIconButton({ label: this.text(this.loading ? 'usage_loading' : 'usage_refresh'),
            glyph: $r('sys.symbol.arrow_clockwise'), actionEnabled: !this.loading, onAction: () => void this.refresh(true) })
        }.width('100%')
        if (this.issue) {
          UiInlineError({ message: this.notice() })
        }
        if (this.snapshot !== null) {
          if (this.accounts().length > 0 || this.pluginQuotaRows.length > 0) this.quotaCard()
          this.tokenCard()
          if (this.data().updatedAtMs || this.data().generatedAtMs) {
            Text(this.text('usage_updated') + ' ' + new Date(this.data().updatedAtMs || this.data().generatedAtMs).toLocaleString())
              .fontSize(UI_FONT_CAPTION).fontColor($r('app.color.text_tertiary')).width('100%')
          }
        } else if (this.loading) {
          LoadingProgress().width(32).height(32).margin({ top: 48 })
        }
      }
      .width('100%').constraintSize({ maxWidth: 860 })
      .padding({ left: 20, right: 20, top: 12, bottom: 112 })
    }
    .width('100%').height('100%').scrollBar(BarState.Auto)
    .backgroundColor($r('app.color.bg_page'))
    }
    .onRefreshing((): void => { void this.pullRefresh(); }).width('100%').height('100%')

  }

  private quotaColumnCount(): number {
    const count = this.accounts().length;
    if (count <= 3) return Math.max(1, count);
    // Mobile balances rows based on the available width, up to six columns.
    const maxColumns = Math.max(1, Math.min(6, Math.floor(this.quotaGridWidth / 82)));
    return Math.ceil(count / Math.ceil(count / maxColumns));
  }

  @Builder
  quotaCard() {
    UiCard({ inset: UI_SPACE_PAGE }) {
      Column({ space: UI_SPACE_GROUP }) {
        Row() {
          Text($r('app.string.usage_plans')).fontSize(UI_FONT_LIST_TITLE).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).layoutWeight(1)
          if (this.stale()) Text($r('app.string.usage_stale')).fontSize(UI_FONT_CAPTION).fontColor($r('app.color.warn'))
        }.width('100%')
        if (this.accounts().length > 0) {
          GridRow({ columns: this.quotaColumnCount(), gutter: { y: 12 } }) {
            ForEach(this.accounts(), (source: UsageSource) => {
              GridCol({ span: 1 }) {
                this.quotaColumn(source, this.quotaGridWidth / this.quotaColumnCount() < 100)
              }
            }, (source: UsageSource) => source.id)
          }.width('100%')
            .onAreaChange((_old: Area, area: Area) => {
              const width = Number(area.width);
              if (width > 0 && width !== this.quotaGridWidth) this.quotaGridWidth = width;
            })
        }
        ForEach(this.accounts(), (source: UsageSource) => {
          if (this.expandedQuota === source.id && source.detail !== null) {
            this.quotaDetails(source)
          }
        }, (source: UsageSource) => 'detail:' + source.id)
        ForEach(this.pluginQuotaRows, (row: PluginQuotaRow) => {
          this.pluginQuotaRow(row)
        }, (row: PluginQuotaRow) => row.engine.providerId)
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }
  @Builder
  pluginQuotaRow(row: PluginQuotaRow) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        PluginEngineMark({ iconDataUrl: row.engine.iconDataUrl, markSize: 24 })
        Text(row.engine.name).fontSize(UI_FONT_BODY).fontColor($r('app.color.text_primary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Center)
      ForEach(row.usage.windows, (window: PluginUsageWindow) => {
        Text(harmonyV12String(this.getUIContext().getHostContext(), 'v131_usage_remaining',
          window.label, String(Math.round(window.remainingPercent)) + '%'))
          .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
        if (window.resetsAt) {
          Text(harmonyV12String(this.getUIContext().getHostContext(), 'v131_usage_reset',
            new Date(window.resetsAt).toLocaleString())).fontSize(UI_FONT_CAPTION).fontColor($r('app.color.text_tertiary'))
        }
      }, (window: PluginUsageWindow, index: number) => window.label + ':' + String(index))
      ForEach(row.usage.balances, (balance: PluginUsageBalance) => {
        Text(balance.amount + ' ' + balance.currency).fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
      }, (balance: PluginUsageBalance, index: number) => balance.currency + ':' + String(index))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  quotaDetails(source: UsageSource) {
    Column({ space: 8 }) {
      Text(source.detail?.title || source.name)
        .fontSize(UI_FONT_BODY).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      if (source.detail?.plan) {
        Text(source.detail?.plan ?? '').fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
      }
      ForEach(source.detail?.windows ?? [], (window: UsageWindow, index: number) => {
        Row({ space: 8 }) {
          Circle().width(8).height(8).fill(this.windowTint(window.color))
          Text(window.label || this.usageCopy(String(index + 1))).layoutWeight(1)
            .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_primary'))
          Text(String(Math.round(window.fraction * 100)) + '%')
            .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
        }.width('100%')
      }, (window: UsageWindow, index: number) => String(index) + ':' + window.label)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor($r('app.color.bg_chip')).borderRadius(UI_RADIUS_CONTENT)
  }

  @Builder
  quotaColumn(source: UsageSource, compact: boolean) {
    Column({ space: compact ? 5 : 8 }) {
      Text((source.value || source.label || '—') + (source.reserve ? '' : source.unit))
        .fontSize(compact ? UI_FONT_LIST_TITLE : UI_FONT_TITLE_S).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (source.reserve && source.unit) Text(source.unit).fontSize(UI_FONT_CAPTION).fontColor($r('app.color.text_secondary'))
      Stack({ alignContent: Alignment.Bottom }) {
        Column().width('100%').height(source.fill > 0 ? Math.max(3, (compact ? 58 : 68) * source.fill) : 0)
          .backgroundColor(this.quotaTint(source)).borderRadius(10)
      }.width(compact ? 26 : 30).height(compact ? 64 : 74).padding(3).clip(true).borderRadius(14)
        .border({ width: source.emphasized ? 1.25 : 1, color: $r('app.color.border') })
        .backgroundColor($r('app.color.bg_chip')).opacity(this.stale() || source.stale ? 0.45 : 1)
      Row({ space: compact ? 2 : 8 }) {
        if (source.logo === 'codex' || source.logo === 'claude') {
          Image(source.logo === 'codex' ? $r('app.media.usage_provider_openai')
            : $r('app.media.usage_provider_anthropic'))
            .width(compact ? 16 : 24).height(compact ? 16 : 24).objectFit(ImageFit.Contain).flexShrink(0)
        } else {
          // MobileProviderMark uses the first code point of monogram, or of name when absent.
          Text((Array.from((source.monogram || source.name).trim())[0] ?? '?').toUpperCase())
            .fontSize(UI_FONT_CAPTION_SMALL).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            .width(compact ? 16 : 18).height(compact ? 16 : 18).textAlign(TextAlign.Center).align(Alignment.Center).flexShrink(0)
            .border({ width: 1, color: $r('app.color.text_primary') }).borderRadius(4)
        }
        Text(source.name).fontSize(compact ? UI_FONT_CAPTION : UI_FONT_BODY).fontColor($r('app.color.text_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
      }.alignItems(VerticalAlign.Center).justifyContent(FlexAlign.Center).width('100%')
      Text(usageResetLabel(source, this.data().strings, this.now, this.text('usage_reset_pending')))
        .fontSize(compact ? UI_FONT_CAPTION_SMALL : UI_FONT_CAPTION).fontColor($r('app.color.text_secondary'))
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
      if (source.stale) {
        Text($r('app.string.usage_stale')).fontSize(UI_FONT_CAPTION_SMALL).fontColor($r('app.color.warn')).textAlign(TextAlign.Center)
      }
      if (source.unusedAtReset && !source.stale && !this.stale()) {
        Text(this.usageCopy('unused')).fontSize(UI_FONT_CAPTION_SMALL).fontColor($r('app.color.warn')).textAlign(TextAlign.Center)
      }
      if (source.detail !== null) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph(this.expandedQuota === source.id ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
            .fontSize(UI_FONT_SECONDARY).fontColor([$r('app.color.text_secondary')])
        }.height(44).width('100%').padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(source.detail?.title || source.name)
          .onClick((): void => { this.expandedQuota = this.expandedQuota === source.id ? '' : source.id; })
      }
    }
    .width('100%')
    .padding({ left: compact ? 2 : 4, right: compact ? 2 : 4 })
  }
  private rangeItems(): SegmentButtonV2Items {
    return new SegmentButtonV2Items(this.rangeLabels().map((label: string): SegmentButtonV2ItemOptions => {
      return { text: label };
    }));
  }

  @Builder
  tokenCard() {
    UiCard({ inset: UI_SPACE_PAGE }) {
      Column({ space: UI_SPACE_GROUP }) {
        Row({ space: 12 }) {
          Text(this.pickedDay >= 0 ? this.rangeCaption() : this.rangeIndex === 0 ? this.todayLabel()
            : this.rangeLabels()[this.rangeIndex]).fontSize(UI_FONT_LIST_TITLE).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary')).layoutWeight(1)
          if (this.data().scope !== 'local' || this.deviceName) {
            Text(this.data().scope === 'local'
              ? harmonyV12String(this.getUIContext().getHostContext(), 'usage_only_device', this.deviceName)
              : $r('app.string.usage_all_devices'))
              .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary')).maxLines(2)
              .constraintSize({ maxWidth: '45%' }).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.width('100%')
        if (this.data().days.length > 0) {
          CapsuleSegmentButtonV2({ items: this.rangeItems(), selectedIndex: this.rangeIndex,
            onItemClicked: (index: number): void => {
              this.rangeIndex = index; this.pickedDay = -1; this.rebuildUsage();
            } })
          Column({ space: 6 }) {
            Text(this.rangeCaption()).fontSize(UI_FONT_CAPTION).fontColor($r('app.color.text_tertiary'))
            Text(usageCompact(this.summary.tokens) + ' token').fontSize(UI_FONT_TITLE_L).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            if (this.summary.estimated !== null) {
              Text(this.text('usage_estimated') + ' ' + this.money(this.summary.estimated))
                .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
            }
            if (this.summary.paid !== null) {
              Text(this.text('usage_paid') + ' ' + this.money(this.summary.paid))
                .fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
          Column({ space: 8 }) {
            Text(this.text('usage_average') + ' ' + usageCompact(this.summary.average) + ' token')
              .fontSize(UI_FONT_CAPTION).fontColor($r('app.color.text_secondary')).width('100%').textAlign(TextAlign.End)
            this.historyChart()
            Row() {
              Text(this.data().days[0].date).layoutWeight(1).fontSize(UI_FONT_CAPTION).fontColor($r('app.color.text_tertiary'))
              Text(this.today().date).fontSize(UI_FONT_CAPTION).fontColor($r('app.color.text_tertiary'))
            }.width('100%').constraintSize({ minHeight: 30 })
              .onClick((): void => { if (this.pickedDay >= 0) { this.pickedDay = -1; this.rebuildUsage(); } })
          }.width('100%')
          Divider().color($r('app.color.border'))
          if (usageHasModels(this.data())) {
            Text(this.usageCopy('models')).fontSize(UI_FONT_CAPTION).fontColor($r('app.color.text_tertiary'))
          }
          Column({ space: 4 }) {
            ForEach(this.chartRows, (series: UsageSeries) => {
              Row({ space: 8 }) {
                if (this.modelKey === series.key) {
                  SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([$r('app.color.accent')]).flexShrink(0)
                } else {
                  Circle().width(8).height(8).fill(this.tint(series)).flexShrink(0)
                }
                UiListRow({ label: series.name, detail: this.modelRowDetail(series), value: usageCompact(series.total),
                  showChevron: usageHasModels(this.data()), onRowClick: usageHasModels(this.data())
                    ? (): void => { this.modelKey = this.modelKey === series.key ? '' : series.key; this.rebuildUsage(); }
                    : undefined }).layoutWeight(1)
              }.width('100%').alignItems(VerticalAlign.Center)
                .borderRadius(UI_RADIUS_CONTENT).backgroundColor(this.modelKey === series.key ? $r('app.color.bg_chip') : Color.Transparent)
            }, (series: UsageSeries) => series.key)
          }.width('100%')
        } else {
          UiEmptyState({ heading: $r('app.string.usage_no_history') })
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }
  private averageDashes(): number[] {
    const indices: number[] = [];
    const count = Math.ceil(Math.max(0, this.chartWidth) / 8);
    for (let i = 0; i < count; i++) indices.push(i);
    return indices;
  }

  @Builder
  historyChart() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row({ space: 3 }) {
        ForEach(this.data().days, (_day: UsageDay, index: number) => {
          Column() {
            ForEach(this.chartSeries(), (series: UsageSeries) => {
              Column().width('100%').height(180 * (series.values[index] ?? 0) / this.graphMax)
                .backgroundColor(this.tint(series))
            }, (series: UsageSeries) => `${series.colorIndex}:${series.name}`)
          }.layoutWeight(1).height(180).justifyContent(FlexAlign.End).borderRadius(2).clip(true)
            .opacity(this.dayActive(index) ? 1 : 0.23)
            .backgroundColor(this.pickedDay === index ? $r('app.color.bg_chip') : Color.Transparent)
            .accessibilityText(_day.date)
            .onClick((): void => { this.pickedDay = this.pickedDay === index ? -1 : index; this.rebuildUsage(); })
        }, (day: UsageDay, index: number) => `${index}:${day.date}`)
      }.width('100%').height(180)
      if (this.summary.average > 0) {
        Row({ space: 4 }) {
          ForEach(this.averageDashes(), (index: number) => {
            Rect().width(4).height(1.5).fill($r('app.color.text_secondary'))
          }, (index: number) => String(index))
        }.width('100%').height(2).clip(true).zIndex(1)
          .position({ x: 0, y: Math.min(178, 180 * (1 - this.summary.average / this.graphMax)) })
          .hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').height(180)
      .onAreaChange((_old: Area, area: Area) => { this.chartWidth = Number(area.width); })
  }
}
