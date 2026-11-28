import { PresenceSnapshot } from '../core/device-link/DlProtocol';
import { AppServices } from '../core/AppServices';
import { RelayRoute } from '../core/device-link/RelayRoute';
import { harmonyV12String } from '../core/HarmonyStrings';
import {
  UsageSnapshot, UsageSource, UsageSeries, UsageDay, usageSum, usageCompact, usageSeries,
  usageResetLabel, readUsageDashboard, usageCandidates,
} from '../core/usage/UsageDashboard';
import { UI_RADIUS_CONTAINER, UI_RADIUS_PILL } from './UiKit';

/** Same snapshot / grouping as iOS. Only visible openings and reconnects read the computer. */
@Component
export struct UsageDashboardPanel {
  @Prop @Watch('contextChanged') active: boolean = false;
  @Prop @Watch('contextChanged') scopeDeviceId: string = '';
  scroller: Scroller = new Scroller();
  @State private snapshot: UsageSnapshot | null = null;
  @State private deviceName: string = '';
  @State private loading: boolean = false;
  @State private issue: string = '';
  @State private now: number = Date.now();
  @State private contentWidth: number = 320;
  @State private chartWidth: number = 320;
  private mounted: boolean = false;
  private identity: string = '';
  private generation: number = 0;
  private request: boolean = false;
  private candidateKey: string = '';
  private reloadRequested: boolean = false;
  private timer: number = -1;
  private unsubs: Array<() => void> = [];

  aboutToAppear(): void {
    this.mounted = true;
    this.unsubs.push(AppServices.instance.auth.onChanged(() => this.contextChanged()));
    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      const key = usageCandidates(AppServices.instance.tasks.deviceList, this.scopeDeviceId)
        .map((device: PresenceSnapshot): string => device.deviceId).sort().join(':');
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
    this.mounted = false; this.generation++;
    this.unsubs.forEach((unsubscribe: () => void): void => unsubscribe()); this.unsubs = [];
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
  }
  private text(key: string): string { return harmonyV12String(this.getUIContext().getHostContext(), key); }
  private syncIdentity(): void {
    const identity = `${AppServices.instance.auth.sessionEpoch}:${RelayRoute.instance.generation}:${this.scopeDeviceId}`;
    if (identity === this.identity) return;
    this.identity = identity; this.generation++;
    this.snapshot = null; this.deviceName = ''; this.issue = '';
    if (this.request) this.reloadRequested = true;
  }
  private contextChanged(): void {
    if (!this.mounted) return;
    this.syncIdentity();
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    if (!this.active) { this.generation++; return; }
    this.now = Date.now();
    // Countdown only; never a network poll.
    this.timer = setInterval(() => { this.now = Date.now(); }, 60000);
    if (this.request) this.reloadRequested = true;
    else void this.refresh();
  }
  private async refresh(): Promise<void> {
    if (!this.mounted || !this.active || this.request) return;
    this.syncIdentity();
    const generation = this.generation;
    const epoch = AppServices.instance.auth.sessionEpoch;
    const route = RelayRoute.instance.generation;
    const current = (): boolean => this.mounted && this.active && generation === this.generation
      && epoch === AppServices.instance.auth.sessionEpoch && route === RelayRoute.instance.generation;
    this.request = true; this.loading = true; this.issue = '';
    try {
      const result = await readUsageDashboard(AppServices.instance.client,
        AppServices.instance.tasks.deviceList, this.scopeDeviceId, current);
      if (!current()) return;
      this.issue = result.issue;
      if (result.snapshot !== null) {
        this.snapshot = result.snapshot; this.deviceName = result.deviceName;
        void AppServices.instance.syncUsageCards(result.snapshot, result.deviceId, result.deviceName, epoch).catch((): void => {});
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
  private data(): UsageSnapshot { return this.snapshot ?? new UsageSnapshot(); }
  private accounts(): UsageSource[] { return this.data().sources.filter((s: UsageSource): boolean => s.kind === 'subscription'); }
  private series(): UsageSeries[] { return usageSeries(this.data(), this.text('usage_other')); }
  private legend(): UsageSeries[] {
    return this.series().sort((a: UsageSeries, b: UsageSeries): number => a.other ? 1 : b.other ? -1 : b.total - a.total);
  }
  private total(): number { return this.data().days.reduce((sum: number, day: UsageDay): number => sum + usageSum(day.tokens), 0); }
  private average(): number { return this.data().days.length ? this.total() / this.data().days.length : 0; }
  private chartMax(): number { return Math.max(1, ...this.data().days.map((day: UsageDay): number => usageSum(day.tokens))); }
  private today(): UsageDay { const days = this.data().days; return days[days.length - 1] ?? new UsageDay(); }
  private todayLabel(): string {
    const date = new Date(this.now);
    const local = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
    return this.today().date && this.today().date !== local ? this.today().date : this.text('usage_today');
  }
  private money(value: number): string { return this.data().moneySymbol + value.toFixed(2); }
  private stale(): boolean { const d = this.data(); return this.now - (d.updatedAtMs || d.generatedAtMs) >= 3600000; }
  private tint(series: UsageSeries): Resource {
    if (series.other) return $r('app.color.usage_chart_other');
    const colors: Resource[] = [$r('app.color.usage_chart_teal'), $r('app.color.usage_chart_pink'),
      $r('app.color.usage_chart_purple'), $r('app.color.accent'), $r('app.color.warn')];
    return colors[series.colorIndex % colors.length];
  }
  private quotaTint(source: UsageSource): Resource {
    return source.level === 'error' ? $r('app.color.danger') : source.level === 'warn'
      ? $r('app.color.warn') : $r('app.color.usage_quota_plenty');
  }
  private notice(): string { return this.text(this.issue === 'offline' ? 'usage_offline'
    : this.issue === 'unsupported' ? 'usage_unsupported' : 'usage_unavailable'); }

  build() {
    Scroll(this.scroller) {
      Column({ space: 18 }) {
        Row({ space: 12 }) {
          Text(this.deviceName).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_secondary')).maxLines(2).layoutWeight(1)
          Button(this.loading ? $r('app.string.usage_loading') : $r('app.string.usage_refresh'))
            .height(44).fontSize(14).padding({ left: 18, right: 18 })
            .fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_chip'))
            .borderRadius(UI_RADIUS_PILL).enabled(!this.loading)
            .onClick(() => void this.refresh())
        }.width('100%')
        if (this.issue) {
          Text(this.notice()).fontSize(14).fontColor($r('app.color.text_secondary')).width('100%')
        }
        if (this.snapshot !== null) {
          if (this.accounts().length > 0) this.quotaCard()
          this.tokenCard()
          if (this.data().updatedAtMs || this.data().generatedAtMs) {
            Text(this.text('usage_updated') + ' ' + new Date(this.data().updatedAtMs || this.data().generatedAtMs).toLocaleString())
              .fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%')
          }
        } else if (this.loading) {
          LoadingProgress().width(32).height(32).margin({ top: 48 })
        }
      }
      .width('100%').constraintSize({ maxWidth: 860 })
      .padding({ left: 20, right: 20, top: 12, bottom: 112 })
      .onAreaChange((_old: Area, area: Area) => { this.contentWidth = Number(area.width); })
    }
    .width('100%').height('100%').scrollBar(BarState.Auto)
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  quotaCard() {
    Column({ space: 24 }) {
      Row() {
        Text($r('app.string.usage_plans')).fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
        if (this.stale()) Text($r('app.string.usage_stale')).fontSize(12).fontColor($r('app.color.warn'))
      }.width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.accounts(), (source: UsageSource) => {
          this.quotaColumn(source)
        }, (source: UsageSource) => source.id)
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(24)
      .backgroundColor($r('app.color.bg_card')).borderRadius(UI_RADIUS_CONTAINER)
      .border({ width: 1, color: $r('app.color.border') })
  }
  @Builder
  quotaColumn(source: UsageSource) {
    Column({ space: 8 }) {
      Text((source.value || source.label || '—') + (source.reserve ? '' : source.unit))
        .fontSize(28).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (source.reserve && source.unit) Text(source.unit).fontSize(12).fontColor($r('app.color.text_secondary'))
      Stack({ alignContent: Alignment.Bottom }) {
        Column().width('100%').height(source.fill > 0 ? Math.max(3, 68 * source.fill) : 0)
          .backgroundColor(this.quotaTint(source)).borderRadius(10)
      }.width(30).height(74).padding(3).clip(true).borderRadius(14)
        .border({ width: source.emphasized ? 1.25 : 1, color: $r('app.color.border') })
        .backgroundColor($r('app.color.bg_chip')).opacity(this.stale() || source.stale ? 0.45 : 1)
      Row({ space: 8 }) {
        if (source.logo === 'codex' || source.logo === 'claude') {
          Image(source.logo === 'codex' ? $r('app.media.usage_provider_openai')
            : $r('app.media.usage_provider_anthropic'))
            .width(24).height(24).objectFit(ImageFit.Contain).flexShrink(0)
        } else if (source.monogram) {
          Text(source.monogram).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        }
        Text(source.name).fontSize(16).lineHeight(24).fontColor($r('app.color.text_primary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
      }.alignItems(VerticalAlign.Center).justifyContent(FlexAlign.Center).width('100%')
      Text(usageResetLabel(source, this.data().strings, this.now, this.text('usage_reset_pending')))
        .fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(2).textAlign(TextAlign.Center)
    }
    .width(this.contentWidth >= 600 && this.accounts().length > 2 ? '25%' : this.accounts().length === 1 ? '100%' : '50%')
    .padding({ left: 4, right: 4, bottom: 12 })
  }
  @Builder
  tokenCard() {
    Column({ space: 20 }) {
      Row({ space: 12 }) {
        Text(this.todayLabel()).fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
        Text(this.data().scope === 'all' ? $r('app.string.usage_all_devices') : this.deviceName)
          .fontSize(13).fontColor($r('app.color.text_secondary')).maxLines(2)
      }.width('100%')
      if (this.data().days.length > 0) {
        Column({ space: 6 }) {
          Text(usageCompact(usageSum(this.today().tokens)) + ' token').fontSize(32).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.text('usage_estimated') + ' ' + this.money(usageSum(this.today().money))
            + ' · ' + this.text('usage_paid') + ' ' + this.money(this.today().paid))
            .fontSize(13).fontColor($r('app.color.text_secondary'))
        }.width('100%').alignItems(HorizontalAlign.Start)
        Column({ space: 8 }) {
          Text(this.text('usage_average') + ' ' + usageCompact(this.average()) + ' token')
            .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%').textAlign(TextAlign.End)
          this.historyChart()
          Row() {
            Text(this.data().days[0].date).layoutWeight(1).fontSize(12).fontColor($r('app.color.text_tertiary'))
            Text(this.today().date).fontSize(12).fontColor($r('app.color.text_tertiary'))
          }.width('100%')
        }.width('100%')
        Divider().color($r('app.color.border'))
        Row() {
          Text($r('app.string.usage_total')).layoutWeight(1).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text(usageCompact(this.total())).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        }.width('100%')
        Column({ space: 12 }) {
          ForEach(this.legend(), (series: UsageSeries) => {
            Row({ space: 8 }) {
              Circle().width(8).height(8).fill(this.tint(series))
              Text(series.name).layoutWeight(1).maxLines(2).fontSize(14).fontColor($r('app.color.text_secondary'))
              Text(`${this.total() ? Math.round(series.total / this.total() * 100) : 0}% · ${usageCompact(series.total)}`).fontSize(14).fontColor($r('app.color.text_secondary'))
            }.width('100%')
          }, (series: UsageSeries) => `${series.colorIndex}:${series.name}`)
        }.width('100%')
      } else {
        Text($r('app.string.usage_no_history')).fontSize(14).fontColor($r('app.color.text_secondary'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(24)
      .backgroundColor($r('app.color.bg_card')).borderRadius(UI_RADIUS_CONTAINER)
      .border({ width: 1, color: $r('app.color.border') })
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
            ForEach(this.series().slice().reverse(), (series: UsageSeries) => {
              Column().width('100%').height(180 * (series.values[index] ?? 0) / this.chartMax())
                .backgroundColor(this.tint(series))
            }, (series: UsageSeries) => `${series.colorIndex}:${series.name}`)
          }.layoutWeight(1).height(180).justifyContent(FlexAlign.End).borderRadius(2).clip(true)
        }, (day: UsageDay, index: number) => `${index}:${day.date}`)
      }.width('100%').height(180)
      if (this.average() > 0) {
        Row({ space: 4 }) {
          ForEach(this.averageDashes(), (index: number) => {
            Rect().width(4).height(1.5).fill($r('app.color.text_secondary'))
          }, (index: number) => String(index))
        }.width('100%').height(2).clip(true).zIndex(1)
          .position({ x: 0, y: Math.min(178, 180 * (1 - this.average() / this.chartMax())) })
          .hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').height(180)
      .onAreaChange((_old: Area, area: Area) => { this.chartWidth = Number(area.width); })
  }
}
