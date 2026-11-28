import { resourceIssueText } from '../../core/resources/ResourceIssueStrings';
import { ResourceStore } from '../../core/resources/ResourceStore';
import { ResourceItem, ResourceBlock, ResourceCollection, ResourceAction, ResourceLink, resourceKey, resourceUnread } from '../../core/resources/ResourceModels';
import { UI_RADIUS_CONTAINER } from '../UiKit';

// All shell strings are injected, so integration uses the same five-language catalog as the app.
export class ResourcesLabels {
  refresh: string = 'Refresh'; more: string = 'Load more'; back: string = 'Back'; search: string = 'Search';
  empty: string = 'Nothing here yet'; openTask: string = 'Open task'; unread: string = 'Unread';
  unsupported: string = 'Not supported'; cancel: string = 'Cancel'; confirm: string = 'Confirm';
  status: (issue: string) => string = (issue: string): string => resourceIssueText(issue, 'en');
}
@Component
export struct ResourcesPanel {
  store: ResourceStore = new ResourceStore(async (): Promise<Object | undefined> => undefined);
  labels: ResourcesLabels = new ResourcesLabels();
  onOpen: (link: ResourceLink) => void = (): void => {};
  @State private revision: number = 0;
  @State private search: string = '';
  private unsubscribe: (() => void) | null = null;
  aboutToAppear(): void {
    this.unsubscribe = this.store.onChanged((): void => {
      this.revision++;
      if (this.store.navigation) { const link = this.store.navigation; this.store.navigation = null; this.onOpen(link); }
    });
    this.store.setVisible(true);
  }
  aboutToDisappear(): void { this.unsubscribe?.(); this.unsubscribe = null; this.store.setVisible(false); }
  private action(action: ResourceAction): void {
    if (!action.confirmation) { void this.store.runAction(action.id); return; }
    this.getUIContext().showAlertDialog({ title: action.confirmation, message: action.confirmationBody,
      primaryButton: { value: this.labels.cancel, action: (): void => {} },
      secondaryButton: { value: action.confirmLabel || this.labels.confirm,
        action: (): void => { void this.store.runAction(action.id, true); } } });
  }
  @Builder
  private actions(actions: ResourceAction[]) {
    ForEach(actions, (action: ResourceAction) => {
      Button(action.supported ? action.label : action.label + ' · ' + this.labels.unsupported)
        .height(44).fontSize(14)
        .fontColor(action.destructive ? $r('app.color.danger') : $r('app.color.text_primary'))
        .backgroundColor($r('app.color.bg_chip'))
        .enabled(action.supported && !action.disabled && this.store.verified && !this.store.actionBusy)
        .onClick((): void => this.action(action))
    }, (action: ResourceAction): string => action.id)
  }
  build() {
    Column({ space: 12 }) {
      if (this.revision >= 0) {
        Row({ space: 8 }) {
          if (this.store.collectionId) {
            Button(this.labels.back).height(44).onClick((): void => {
              if (this.store.detail) this.store.selectResource(null);
              else this.store.showCollections();
            })
          }
          Blank()
          Button(this.labels.refresh).height(44).enabled(!this.store.busy).onClick((): void => { void this.store.refresh(); })
        }.width('100%')
        if (this.store.issue) { Text(this.labels.status(this.store.issue)).fontSize(14).fontColor($r('app.color.text_secondary')) }
        if (this.store.notice) { Text(this.store.notice).fontSize(14).fontColor($r('app.color.text_secondary')) }
        if (this.store.busy) { LoadingProgress().width(28).height(28) }
        if (this.store.detail) {
          Scroll() {
            Column({ space: 12 }) {
              Text(this.store.detail.title).fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              Text(this.store.detail.subtitle).fontSize(14).fontColor($r('app.color.text_secondary'))
              ForEach(this.store.detail.blocks, (block: ResourceBlock) => {
                // Inert fallback: no WebView, host JavaScript, form runtime, or arbitrary media loading.
                Text(block.markdown).fontSize(14).copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_primary')).width('100%')
              })
              ForEach(this.store.detail.links, (link: ResourceLink) => {
                Button(link.label || this.labels.openTask).height(44).enabled(this.store.verified)
                  .onClick((): void => this.onOpen(link))
              })
              this.actions(this.store.detail.actions)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.layoutWeight(1)
        } else if (this.store.collectionId) {
          Row({ space: 8 }) {
            TextInput({ text: this.search, placeholder: this.labels.search }).layoutWeight(1)
              .onChange((value: string): void => { this.search = value; })
            Button(this.labels.search).height(44).onClick((): void => this.store.selectCollection(this.store.collectionId, this.search))
          }
          List({ space: 8 }) {
            ForEach(this.store.items, (item: ResourceItem) => {
              ListItem() {
                Column({ space: 4 }) {
                  Text(item.title + (resourceUnread(item) ? ' · ' + this.labels.unread : '')).fontSize(16).fontColor($r('app.color.text_primary'))
                  Text(item.preview || item.subtitle).fontSize(14).maxLines(2).fontColor($r('app.color.text_secondary'))
                }.width('100%').alignItems(HorizontalAlign.Start).padding(12).constraintSize({ minHeight: 56 })
                  .borderRadius(UI_RADIUS_CONTAINER).backgroundColor($r('app.color.bg_card'))
                  .onClick((): void => this.store.selectResource(item.ref))
              }
            }, (item: ResourceItem): string => resourceKey(item.ref))
            if (!this.store.items.length && !this.store.busy) { ListItem() { Text(this.labels.empty).fontColor($r('app.color.text_secondary')) } }
            if (this.store.nextCursor) { ListItem() { Button(this.labels.more).height(44).enabled(!this.store.busy).onClick((): void => { void this.store.loadMore(); }) } }
          }.layoutWeight(1).width('100%')
          this.actions(this.store.collections.find((row: ResourceCollection): boolean => row.id === this.store.collectionId)?.actions ?? [])
        } else {
          List({ space: 8 }) {
            ForEach(this.store.collections, (collection: ResourceCollection) => {
              ListItem() {
                Button(collection.title).height(48).width('100%').fontColor($r('app.color.text_primary'))
                  .backgroundColor($r('app.color.bg_card')).onClick((): void => this.store.selectCollection(collection.id))
              }
            }, (collection: ResourceCollection): string => collection.id)
            if (!this.store.collections.length && !this.store.busy) { ListItem() { Text(this.labels.empty).fontColor($r('app.color.text_secondary')) } }
          }.layoutWeight(1).width('100%')
        }
      }
    }.width('100%').height('100%').padding(16).backgroundColor($r('app.color.bg_page'))
  }
}
