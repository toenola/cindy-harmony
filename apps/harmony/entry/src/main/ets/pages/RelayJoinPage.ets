import { router } from '@kit.ArkUI';
import { UiPanelHeading } from '../components/common/UiNavigation';
import { RelaySettingsPanel } from '../components/RelaySettingsPanel';

@Entry
@Component
struct RelayJoinPage {
  @State private offer: string = '';
  aboutToAppear(): void {
    const params = (router.getParams() ?? {}) as Record<string, Object>;
    this.offer = typeof params['offer'] === 'string' ? params['offer'] as string : '';
  }
  build() {
    Column() {
      Row() {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([$r('app.color.text_primary')])
        }.width(44).height(44).backgroundColor($r('app.color.bg_card')).onClick(() => router.back())
        Column() { UiPanelHeading({ heading: $r('app.string.relay_join_title') }) }.layoutWeight(1)
      }.width('100%').padding(16)
      Scroll() {
        Column() { RelaySettingsPanel({ joinOnly: true, offerJson: this.offer }) }
          .width('100%').constraintSize({ maxWidth: 680 }).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor($r('app.color.bg_page'))
  }
}
