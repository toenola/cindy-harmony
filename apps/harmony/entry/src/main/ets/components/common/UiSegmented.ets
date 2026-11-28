import { CapsuleSegmentButtonV2, SegmentButtonV2ItemOptions, SegmentButtonV2Items } from '@kit.ArkUI';

/** The caller owns selection. SegmentButton supplies native focus, motion and selection semantics. */
@Component
export struct UiSegmented {
  @Require @Prop labels: ResourceStr[] = [];
  @Require @Prop selectedIndex: number = 0;
  onSelectionChange: (index: number) => void = () => {};

  private nativeItems(): SegmentButtonV2Items {
    return new SegmentButtonV2Items(this.labels.map((label: ResourceStr): SegmentButtonV2ItemOptions => {
      return { text: label };
    }));
  }

  build() {
    CapsuleSegmentButtonV2({
      items: this.nativeItems(),
      selectedIndex: this.selectedIndex,
      $selectedIndex: (index: number) => this.onSelectionChange(index),
    })
  }
}
