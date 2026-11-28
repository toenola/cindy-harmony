import { IncomingShareBatch, IncomingShareItem } from '../core/incoming-share/IncomingShareStore';
import { UI_RADIUS_PILL, uiFontSize, uiLineHeight } from '../components/UiKit';
export class IncomingShareTarget {
  id: string = ''; label: string = ''; detail: string = ''; deviceId: string = ''; sessionId: string = ''; enabled: boolean = true;
}
export class IncomingSharePreviewLabels {
  title: string = ''; target: string = ''; confirm: string = ''; cancel: string = ''; hint: string = ''; openInvite: string = '';
}
/** Parent supplies the actual authorized computer/tasks. Confirm only adopts into that composer. */
@Component
export struct IncomingSharePreview {
  @Prop batch: IncomingShareBatch = new IncomingShareBatch();
  @Prop targets: IncomingShareTarget[] = [];
  @Prop labels: IncomingSharePreviewLabels = new IncomingSharePreviewLabels();
  @Prop busy: boolean = false;
  @Prop error: string = '';
  @Prop maxBodyHeight: number = 360;
  @Prop canOpenInvite: boolean = false;
  @State selected: string = '';
  onConfirm: (targetId: string) => void = (_targetId: string): void => {};
  onCancel: () => void = (): void => {};
  onOpenInvite: () => void = (): void => {};
  build() {
    Column({ space: 12 }) {
      Text(this.labels.title).fontSize(uiFontSize(16)).fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary')).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          ForEach(this.batch.items, (item: IncomingShareItem) => {
            Text(item.file !== null ? item.file.name + ' · ' + item.file.mime : item.text)
              .fontSize(uiFontSize(14)).lineHeight(uiLineHeight(20)).fontColor($r('app.color.text_primary'))
              .maxLines(6).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          }, (_item: IncomingShareItem, index: number): string => this.batch.id + ':' + index)
          Text(this.labels.target).fontSize(uiFontSize(13)).fontColor($r('app.color.text_secondary')).width('100%')
          ForEach(this.targets, (target: IncomingShareTarget) => {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 3 }) {
                Text(target.label).fontSize(uiFontSize(14)).fontColor($r('app.color.text_primary')).width('100%')
                if (target.detail) { Text(target.detail).fontSize(uiFontSize(12)).fontColor($r('app.color.text_secondary')).width('100%') }
              }.padding(12).width('100%')
            }.width('100%').constraintSize({ minHeight: 48 }).borderRadius(UI_RADIUS_PILL)
            .backgroundColor(this.selected === target.id ? $r('app.color.bg_chip') : Color.Transparent)
            .border({ width: 1, color: $r('app.color.border') }).enabled(!this.busy && target.enabled)
            .onClick(() => { this.selected = target.id; })
          }, (target: IncomingShareTarget): string => target.id)
          Text(this.labels.hint).fontSize(uiFontSize(12)).fontColor($r('app.color.text_secondary')).width('100%')
          if (this.error) { Text(this.error).fontSize(uiFontSize(13)).fontColor($r('app.color.text_secondary')).width('100%') }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').constraintSize({ maxHeight: this.maxBodyHeight }).align(Alignment.TopStart)
      if (this.canOpenInvite) {
        Button(this.labels.openInvite).height(44).borderRadius(UI_RADIUS_PILL)
          .fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_chip'))
          .enabled(!this.busy).onClick(() => { this.onOpenInvite(); })
      }
      Row({ space: 12 }) {
        Button(this.labels.cancel).height(44).layoutWeight(1).borderRadius(UI_RADIUS_PILL)
          .fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.bg_chip'))
          .enabled(!this.busy).onClick(() => { this.onCancel(); })
        Button(this.labels.confirm).height(44).layoutWeight(1).borderRadius(UI_RADIUS_PILL)
          .fontColor($r('app.color.chat_cta_text')).backgroundColor($r('app.color.chat_cta'))
          .enabled(!this.busy && this.targets.some((target: IncomingShareTarget): boolean => target.id === this.selected && target.enabled))
          .onClick(() => { this.onConfirm(this.selected); })
      }.width('100%')
    }.width('100%').padding(16)
  }
}
