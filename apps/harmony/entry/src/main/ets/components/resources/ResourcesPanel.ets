import { uiToast } from '../common/UiOverlay';
import { uiConfirm, uiConfirmCopy } from '../common/UiOverlay';
import { resourceIssueText } from '../../core/resources/ResourceIssueStrings';
import { ResourceStore } from '../../core/resources/ResourceStore';
import { ResourceItem, ResourceBlock, ResourceCollection, ResourceAction, ResourceLink, resourceKey, resourceUnread } from '../../core/resources/ResourceModels';
import { UI_FONT_SECONDARY, UI_SPACE_INLINE, UI_SPACE_GROUP, UI_SPACE_PAGE } from '../UiKit';
import { UiListRow } from '../common/UiList';
import { UiInlineError, UiEmptyState } from '../common/UiStatus';
import { UiPanelHeading } from '../common/UiNavigation';
import { UiActionButton, UiActionKind, UiIconButton } from '../common/UiActions';

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
    void uiConfirm(this.getUIContext(), uiConfirmCopy(action.confirmation, action.confirmationBody,
      action.confirmLabel || this.labels.confirm, this.labels.cancel, action.destructive)).then((confirmed: boolean): void => {
      if (confirmed) void this.store.runAction(action.id, true);
    });
  }
  @Builder
  private actions(actions: ResourceAction[]) {
    ForEach(actions, (action: ResourceAction) => {
      UiActionButton({ label: action.supported ? action.label : action.label + ' · ' + this.labels.unsupported,
        kind: action.destructive ? UiActionKind.Danger : UiActionKind.Secondary,
        actionEnabled: action.supported && !action.disabled && this.store.verified && !this.store.actionBusy,
        onAction: () => this.action(action) })
    }, (action: ResourceAction): string => action.id)
  }
  @State private pullRefreshing: boolean = false;

  private async pullRefresh(): Promise<void> {
    if (this.pullRefreshing) return;
    this.pullRefreshing = true;
    try {
      await this.store.refresh();
      if (this.store.issue) uiToast(this.getUIContext(), this.labels.status(this.store.issue));
    } catch (_error) {
      uiToast(this.getUIContext(), this.labels.status('failed'));
    } finally {
      this.pullRefreshing = false;
    }
  }

  build() {
    Column({ space: UI_SPACE_GROUP }) {
      if (this.revision >= 0) {
        Row({ space: UI_SPACE_INLINE }) {
          if (this.store.collectionId) {
            UiIconButton({ label: this.labels.back, glyph: $r('sys.symbol.chevron_left'), onAction: (): void => {
              if (this.store.detail) this.store.selectResource(null);
              else this.store.showCollections();
            } })
          }
          Blank()
          UiIconButton({ label: this.labels.refresh, glyph: $r('sys.symbol.arrow_clockwise'), actionEnabled: !this.store.busy, onAction: () => void this.store.refresh() })
        }.width('100%')
        if (this.store.issue) { UiInlineError({ message: this.labels.status(this.store.issue) }) }
        if (this.store.notice) { Text(this.store.notice).fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary')) }
        if (this.store.busy) { LoadingProgress().width(28).height(28) }
        if (this.store.detail) {
          Scroll() {
            Column({ space: UI_SPACE_GROUP }) {
              UiPanelHeading({ heading: this.store.detail.title })
              Text(this.store.detail.subtitle).fontSize(UI_FONT_SECONDARY).fontColor($r('app.color.text_secondary'))
              ForEach(this.store.detail.blocks, (block: ResourceBlock) => {
                // Inert fallback: no WebView, host JavaScript, form runtime, or arbitrary media loading.
                Text(block.markdown).fontSize(UI_FONT_SECONDARY).copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_primary')).width('100%')
              })
              ForEach(this.store.detail.links, (link: ResourceLink) => {
                Button(link.label || this.labels.openTask).height(44).enabled(this.store.verified)
                  .onClick((): void => this.onOpen(link))
              })
              this.actions(this.store.detail.actions)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.layoutWeight(1)
        } else if (this.store.collectionId) {
          Search({ value: this.search, placeholder: this.labels.search })
            .width('100%').searchButton(this.labels.search)
            .onChange((value: string): void => { this.search = value; })
            .onSubmit((value: string): void => {
              this.search = value;
              this.store.selectCollection(this.store.collectionId, value);
            })
          Refresh({ refreshing: this.pullRefreshing }) {
          List({ space: UI_SPACE_INLINE }) {
            ForEach(this.store.items, (item: ResourceItem) => {
              ListItem() {
                UiListRow({ label: item.title + (resourceUnread(item) ? ' · ' + this.labels.unread : ''),
                  detail: item.preview || item.subtitle, showChevron: true, onRowClick: () => this.store.selectResource(item.ref) })
              }
            }, (item: ResourceItem): string => resourceKey(item.ref))
            if (!this.store.items.length && !this.store.busy) { ListItem() { UiEmptyState({ heading: this.labels.empty, actionLabel: this.labels.refresh, onAction: () => void this.store.refresh() }) } }
            if (this.store.nextCursor) { ListItem() { Button(this.labels.more).height(44).enabled(!this.store.busy).onClick((): void => { void this.store.loadMore(); }) } }
          }.layoutWeight(1).width('100%')
          }
          .onRefreshing((): void => { void this.pullRefresh(); }).layoutWeight(1).width('100%')
          this.actions(this.store.collections.find((row: ResourceCollection): boolean => row.id === this.store.collectionId)?.actions ?? [])
        } else {
          Refresh({ refreshing: this.pullRefreshing }) {
          List({ space: UI_SPACE_INLINE }) {
            ForEach(this.store.collections, (collection: ResourceCollection) => {
              ListItem() {
                UiListRow({ label: collection.title, showChevron: true, onRowClick: () => this.store.selectCollection(collection.id) })
              }
            }, (collection: ResourceCollection): string => collection.id)
            if (!this.store.collections.length && !this.store.busy) { ListItem() { UiEmptyState({ heading: this.labels.empty, actionLabel: this.labels.refresh, onAction: () => void this.store.refresh() }) } }
          }.layoutWeight(1).width('100%')
          }
          .onRefreshing((): void => { void this.pullRefresh(); }).layoutWeight(1).width('100%')
        }
      }
    }.width('100%').height('100%').padding(UI_SPACE_PAGE).backgroundColor($r('app.color.bg_page'))
  }
}
