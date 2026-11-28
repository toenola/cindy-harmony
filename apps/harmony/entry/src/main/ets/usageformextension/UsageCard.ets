class UsageCardRouteParams { usageCardId: string = ''; }
class UsageCardRouteAction {
  action: string = 'router'; abilityName: string = 'EntryAbility'; params: UsageCardRouteParams = new UsageCardRouteParams();
}
/** Live Form data comes from the provider's sanitized snapshot. All colors follow existing dual-mode resources. */
@Entry
@Component
struct UsageCard {
  @LocalStorageProp('dimension') dimension: number = 2;
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('deviceName') deviceName: string = '';
  @LocalStorageProp('status') status: string = 'signed-out';
  @LocalStorageProp('updatedAt') updatedAt: number = 0;
  @LocalStorageProp('stale') stale: boolean = true;
  @LocalStorageProp('source1') source1: string = '';
  @LocalStorageProp('value1') value1: string = '';
  @LocalStorageProp('reset1') reset1: string = '';
  @LocalStorageProp('fill1') fill1: number = 0;
  @LocalStorageProp('source2') source2: string = '';
  @LocalStorageProp('value2') value2: string = '';
  @LocalStorageProp('reset2') reset2: string = '';
  @LocalStorageProp('fill2') fill2: number = 0;
  @LocalStorageProp('tokens') tokens: string = '';
  @LocalStorageProp('paid') paid: string = '';
  @Builder
  private quota(name: string, value: string, reset: string, fill: number) {
    Column({ space: 3 }) {
      Row({ space: 4 }) {
        Text(name).fontSize(12).fontColor($r('app.color.text_secondary')).maxLines(1).layoutWeight(1)
        Text(value).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(1)
      }.width('100%')
      Progress({ value: fill, total: 100, type: ProgressType.Linear }).color($r('app.color.accent'))
        .backgroundColor($r('app.color.bg_chip')).height(3)
      Text(reset).fontSize(10).fontColor($r('app.color.text_tertiary')).maxLines(1)
    }.width('100%')
  }
  build() {
    Column({ space: 7 }) {
      Row({ space: 4 }) {
        Text($r('app.string.usage_tab')).fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(this.deviceName).fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(1).layoutWeight(1)
      }.width('100%')
      if (this.status === 'snapshot') {
        if (this.dimension === 3 && this.source2) {
          Row({ space: 12 }) {
            Column() { this.quota(this.source1, this.value1, this.reset1, this.fill1) }.layoutWeight(1)
            Column() { this.quota(this.source2, this.value2, this.reset2, this.fill2) }.layoutWeight(1)
          }.width('100%')
        } else if (this.source1) { this.quota(this.source1, this.value1, this.reset1, this.fill1) }
        Row({ space: 4 }) {
          Text($r('app.string.usage_today')).fontSize(11).fontColor($r('app.color.text_tertiary'))
          Text(this.tokens).fontSize(12).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text(this.paid).fontSize(12).fontColor($r('app.color.text_secondary'))
        }.width('100%')
        if (this.stale) {
          Text($r('app.string.usage_stale')).fontSize(10).fontColor($r('app.color.text_tertiary')).width('100%')
        }
        Text(new Date(this.updatedAt).toLocaleString()).fontSize(10).fontColor($r('app.color.text_tertiary')).maxLines(1).width('100%')
      } else {
        Text($r('app.string.usage_unavailable')).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
      }
    }.width('100%').height('100%').padding(12).alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.bg_card'))
    .onClick(() => {
      const action = new UsageCardRouteAction(); action.params.usageCardId = this.formId; postCardAction(this, action);
    })
  }
}
