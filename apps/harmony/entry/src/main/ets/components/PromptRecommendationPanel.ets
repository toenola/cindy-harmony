import { PresenceSnapshot } from '../core/device-link/DlProtocol';
import { AppServices } from '../core/AppServices';
import { RelayRoute } from '../core/device-link/RelayRoute';
import {
  PromptRecommendationInput, PromptRecommendationController, PromptRecommendationVisibility,
  recommendationScope, requestPromptRecommendation,
} from '../core/messages/PromptRecommendation';
import { UI_RADIUS_PILL, UI_CLICK_EFFECT, uiAnimateFastState, uiFontSize, uiLineHeight } from './UiKit';
import { HarmonySettingsGroup } from './SettingsRows';
import { harmonyV12String } from '../core/HarmonyStrings';

@Component
export struct PromptRecommendationPanel {
  @Prop @Watch('reconcile') state: PromptRecommendationInput = new PromptRecommendationInput();
  @Prop @Watch('reconcile') draft: string = '';
  @Prop @Watch('reconcile') composerActive: boolean = false;
  @Prop @Watch('reconcile') show: boolean = true;
  onAccept: (prompt: string) => void = (_prompt: string): void => {};
  @State private prompt: string = '';
  @State private visible: boolean = false;
  @State private dragX: number = 0;
  private cardWidth: number = 320;
  private controller: PromptRecommendationController | null = null;
  private presentation: PromptRecommendationVisibility = new PromptRecommendationVisibility();
  private connectionEpoch: number = 0;
  private lastAvailable: boolean = false;
  private unsubs: Array<() => void> = [];

  aboutToAppear(): void {
    this.controller = new PromptRecommendationController(
      async (input: PromptRecommendationInput, cacheOnly: boolean): Promise<string> => {
        const services = AppServices.instance;
        const route = RelayRoute.instance.generation;
        if (input.owner !== JSON.stringify([services.auth.cacheAccountId, services.auth.sessionEpoch])) return '';
        const prompt = await requestPromptRecommendation(services.client, input, cacheOnly);
        if (route !== RelayRoute.instance.generation) throw new Error('Recommendation route changed');
        return input.owner === JSON.stringify([services.auth.cacheAccountId, services.auth.sessionEpoch]) ? prompt : '';
      }, () => this.syncResult());
    this.unsubs.push(AppServices.instance.promptRecommendationPreference.onChanged(() => this.reconcile()));
    this.unsubs.push(AppServices.instance.onStatus(() => { this.connectionEpoch++; this.reconcile(); }));
    this.unsubs.push(AppServices.instance.auth.onChanged(() => this.reconcile()));
    this.unsubs.push(AppServices.instance.tasks.onChanged(() => this.reconcile()));
    this.reconcile();
  }
  aboutToDisappear(): void {
    this.controller?.dispose(); this.controller = null;
    this.unsubs.forEach((unsubscribe: () => void): void => unsubscribe()); this.unsubs = [];
  }
  private reconcile(): void {
    if (this.controller === null) return;
    const args = this.state, services = AppServices.instance;
    const input = new PromptRecommendationInput();
    input.owner = JSON.stringify([services.auth.cacheAccountId, services.auth.sessionEpoch]);
    input.deviceId = args.deviceId; input.sessionId = args.sessionId; input.agentKind = args.agentKind;
    input.revision = args.revision; input.running = args.running;
    input.available = args.available && services.client.getStatus() === 'online' && args.owner === input.owner
      && services.tasks.deviceList.some((device: PresenceSnapshot): boolean => device.deviceId === args.deviceId
        && device.online && device.remoteControlEnabled);
    if (input.available !== this.lastAvailable) { this.lastAvailable = input.available; this.connectionEpoch++; }
    input.connectionEpoch = `${RelayRoute.instance.generation}:${this.connectionEpoch}`;
    input.ready = services.promptRecommendationPreference.ready;
    input.enabled = services.promptRecommendationPreference.enabled;
    input.hasDraft = args.hasDraft; input.displayBlocked = args.displayBlocked; input.terminalError = args.terminalError;
    this.presentation.update(recommendationScope(input), this.draft, this.composerActive);
    this.controller.update(input);
    this.syncResult();
  }
  private syncResult(): void {
    const prompt = this.controller?.prompt() ?? '';
    if (this.prompt !== prompt) this.prompt = prompt;
    const visible = !!prompt && this.show && !this.presentation.hidden;
    if (this.visible !== visible) this.visible = visible;
  }
  private accept(): void {
    if (!this.visible || !this.prompt) return;
    this.presentation.hide(); this.visible = false; this.onAccept(this.prompt);
  }
  private dismiss(): void { this.controller?.dismiss(); this.dragX = 0; }
  build() {
    Column() {
      if (this.visible) {
        Button() {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(18)
              .fontColor([$r('app.color.text_secondary')])
            Text(this.prompt).fontSize(uiFontSize(14)).lineHeight(uiLineHeight(20))
              .fontColor($r('app.color.text_primary')).layoutWeight(1).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
        }
        .type(ButtonType.Normal).width('100%').constraintSize({ minHeight: 44 })
        .padding(0).backgroundColor($r('app.color.bg_card')).borderRadius(UI_RADIUS_PILL)
        .border({ width: 1, color: $r('app.color.border') }).clickEffect(UI_CLICK_EFFECT)
        .accessibilityText(this.prompt).accessibilityDescription($r('app.string.prompt_recommendation_dismiss'))
        .translate({ x: this.dragX }).onClick(() => this.accept())
        .gesture(PanGesture({ direction: PanDirection.Horizontal, distance: 8 })
          .onActionUpdate((event: GestureEvent): void => { this.dragX = event.offsetX; })
          .onActionEnd((event: GestureEvent): void => {
            if (Math.abs(event.offsetX) > Math.min(90, this.cardWidth * 0.25)
              || (Math.abs(event.offsetX) > 24 && Math.abs(event.velocityX) > 550
                && event.offsetX * event.velocityX > 0)) this.dismiss();
            else uiAnimateFastState(this.getUIContext(), () => { this.dragX = 0; });
          })
          .onActionCancel(() => { this.dragX = 0; }))
      }
    }
    .width('100%').constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
    .padding(this.visible ? { left: 16, right: 16, bottom: 8 } : 0)
    .onAreaChange((_old: Area, area: Area): void => { this.cardWidth = Number(area.width); })
  }
}

@Component
export struct PromptRecommendationSettings {
  @State private ready: boolean = false;
  @State private preferenceEnabled: boolean = false;
  @State private customized: boolean = false;
  @State private saving: boolean = false;
  @State private failed: boolean = false;
  private unsubscribe: (() => void) | null = null;
  aboutToAppear(): void {
    this.sync(); this.unsubscribe = AppServices.instance.promptRecommendationPreference.onChanged(() => this.sync());
  }
  aboutToDisappear(): void { this.unsubscribe?.(); this.unsubscribe = null; }
  private sync(): void {
    const store = AppServices.instance.promptRecommendationPreference;
    this.ready = store.ready; this.preferenceEnabled = store.enabled; this.customized = store.customized;
  }
  private text(key: string): string { return harmonyV12String(this.getUIContext().getHostContext(), key); }
  private async save(value: boolean | null): Promise<void> {
    this.saving = true; this.failed = false;
    try { await AppServices.instance.promptRecommendationPreference.save(value); }
    catch (_error) { this.failed = true; }
    finally { this.saving = false; }
  }
  build() {
    HarmonySettingsGroup({ footer: this.text('prompt_recommendation_description') }) {
      Row({ space: 12 }) {
        Text($r('app.string.prompt_recommendation_label')).fontSize(uiFontSize(14))
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.preferenceEnabled }).selectedColor($r('app.color.accent'))
          .enabled(this.ready && !this.saving)
          .accessibilityText($r('app.string.prompt_recommendation_label'))
          .onChange((value: boolean): void => { void this.save(value); })
      }.width('100%').constraintSize({ minHeight: 52 }).padding({ left: 16, right: 12, top: 10, bottom: 10 })
      if (this.customized) {
        Divider().color($r('app.color.border'))
        Button($r('app.string.prompt_recommendation_reset')).type(ButtonType.Normal).width('100%').height(48)
          .fontSize(uiFontSize(14)).fontColor($r('app.color.text_primary')).backgroundColor(Color.Transparent)
          .enabled(!this.saving).onClick(() => void this.save(null))
      }
      if (this.failed) {
        Text($r('app.string.prompt_recommendation_save_failed')).fontSize(uiFontSize(12))
          .fontColor($r('app.color.text_secondary')).padding(16).width('100%')
      }
    }
  }
}
