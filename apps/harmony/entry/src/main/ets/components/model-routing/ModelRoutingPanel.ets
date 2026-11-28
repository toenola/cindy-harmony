import { ModelRouteRow, ModelRoutingBinding, ModelRoutingOffer, ModelRoutingResult } from '../../core/model-routing/ModelRoutingModels';
import { ModelRoutingSnapshot } from '../../core/model-routing/ModelRoutingStore';
import { UI_LIST_CLICK_EFFECT, UI_RADIUS_CONTAINER, UI_RADIUS_PILL, uiFontSize, uiLineHeight } from '../UiKit';

/** All static copy comes from the integrating page's localized resource keys. */
export class ModelRoutingLabels {
  title: string = '';
  empty: string = '';
  unsupported: string = '';
  loading: string = '';
  unavailable: string = '';
  refresh: string = '';
  unbind: string = '';
  managed: string = '';
  fixed: string = '';
  pending: string = '';
  fallback: string = '';
  kept: string = '';
  unsupportedEngine: string = '';
  selected: string = '';
  ordinary: string = '';
}
/** Native panel shared by the existing model sheet on new-task and task-detail pages.
 * No network/lifecycle work here; hiding this panel creates no background polling. */
@Component
export struct ModelRoutingPanel {
  @Prop snapshot: ModelRoutingSnapshot = new ModelRoutingSnapshot();
  @Prop binding: ModelRoutingBinding | null = null;
  @Prop offer: ModelRoutingOffer | null = null;
  @Prop result: ModelRoutingResult | null = null;
  @Prop labels: ModelRoutingLabels = new ModelRoutingLabels();
  @Prop activeId: string = '';
  @Prop busy: boolean = false;
  @Prop reason: string = '';
  @Prop executionSource: string = '';
  @Prop sessionError: string = '';
  onSelect: (id: string) => void = (_id: string): void => {};
  onRefresh: () => void = (): void => {};
  onUnbind: () => void = (): void => {};
  onFallback: () => void = (): void => {};
  onOrdinary: () => void = (): void => {};
  deviceName: (device: string) => string = (device: string): string => device;
  rowHint: (row: ModelRouteRow) => string = (_row: ModelRouteRow): string => '';

  @Builder
  private routeRow(row: ModelRouteRow) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Text(row.name + (this.activeId === row.id ? ' · ' + this.labels.selected : ''))
          .fontSize(uiFontSize(14)).fontColor($r('app.color.text_primary')).width('100%')
          .textAlign(TextAlign.Start)
        if (row.parentName) {
          Text(row.parentName).fontSize(uiFontSize(12)).fontColor($r('app.color.text_secondary')).width('100%')
        }
        if (this.rowHint(row)) {
          Text(this.rowHint(row)).fontSize(uiFontSize(12)).fontColor($r('app.color.text_secondary'))
            .width('100%').textAlign(TextAlign.Start).lineHeight(uiLineHeight(17))
        }
      }.width('100%').padding(12)
    }
    .width('100%').constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent)
    .borderRadius(UI_RADIUS_CONTAINER).clickEffect(UI_LIST_CLICK_EFFECT)
    .enabled(!this.busy && this.snapshot.status === 'ready').onClick(() => { this.onSelect(row.id); })
  }
  @Builder
  private statusLine(text: string) {
    Text(text).fontSize(uiFontSize(13)).fontColor($r('app.color.text_secondary'))
      .lineHeight(uiLineHeight(19)).width('100%').textAlign(TextAlign.Start)
  }
  build() {
    Column({ space: 10 }) {
      Text(this.labels.title).fontSize(uiFontSize(14)).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary')).width('100%')
      if (this.binding !== null) {
        this.statusLine(this.binding.routeName + ' · ' + (this.binding.autoSwitch ? this.labels.managed : this.labels.fixed))
        if (this.binding.pendingSwitch) { this.statusLine(this.labels.pending) }
        Button(this.labels.unbind).height(44).borderRadius(UI_RADIUS_PILL)
          .fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_chip'))
          .enabled(!this.busy).onClick(() => { this.onUnbind(); })
      }
      if (this.executionSource) { this.statusLine(this.executionSource) }
      if (this.reason) { this.statusLine(this.reason) }
      if (this.result !== null && this.result.outcome !== 'routed' && this.result.outcome !== 'missing') {
        this.statusLine(this.labels.kept)
      }
      if (this.sessionError) {
        this.statusLine(this.sessionError.indexOf('MODEL_ROUTING_ENGINE_UNSUPPORTED') >= 0
          ? this.labels.unsupportedEngine : this.labels.unavailable)
      }
      if (this.snapshot.status === 'loading') { this.statusLine(this.labels.loading) }
      else if (this.snapshot.status === 'unsupported') { this.statusLine(this.labels.unsupported) }
      else if (this.snapshot.status === 'error') { this.statusLine(this.labels.unavailable) }
      else if (this.snapshot.status === 'ready' && this.snapshot.catalog !== null) {
        if (this.snapshot.catalog.routes.length === 0 && this.snapshot.catalog.expandedRoutes.length === 0) {
          this.statusLine(this.labels.empty)
        }
        ForEach(this.snapshot.catalog.routes, (row: ModelRouteRow) => { this.routeRow(row) },
          (row: ModelRouteRow): string => row.id)
        ForEach(this.snapshot.catalog.expandedRoutes, (row: ModelRouteRow) => { this.routeRow(row) },
          (row: ModelRouteRow): string => row.id)
      }
      if (this.offer !== null) {
        if (this.offer.route.agentKind === 'acp') { this.statusLine(this.labels.unsupportedEngine) }
        else {
          Button(this.labels.fallback + ' · ' + this.offer.modelName + ' · ' + this.offer.sourceName
            + (this.offer.route.agentDeviceId ? ' · ' + this.deviceName(this.offer.route.agentDeviceId) : ''))
            .constraintSize({ minHeight: 44 }).borderRadius(UI_RADIUS_PILL)
            .fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_chip'))
            .enabled(!this.busy).onClick(() => { this.onFallback(); })
        }
      }
      Button(this.labels.ordinary).height(44).borderRadius(UI_RADIUS_PILL)
        .fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_chip'))
        .enabled(!this.busy).onClick(() => { this.onOrdinary(); })
      Button(this.labels.refresh).height(44).borderRadius(UI_RADIUS_PILL)
        .fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_chip'))
        .enabled(!this.busy && this.snapshot.status !== 'loading').onClick(() => { this.onRefresh(); })
    }.width('100%').padding(12)
  }
}
