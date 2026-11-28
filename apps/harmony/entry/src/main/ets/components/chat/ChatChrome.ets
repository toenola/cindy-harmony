import { CapsuleSegmentButtonV2, SegmentButtonV2ItemOptions, SegmentButtonV2Items } from '@kit.ArkUI';
import { UiActionButton, UiIconButton } from '../common/UiActions';
import { UiSegmented } from '../common/UiSegmented';

@Component
export struct ChatIconButton {
  @Prop symbol: Resource = $r('sys.symbol.chevron_left');
  @Prop label: string = '';
  @Prop enable: boolean = true;
  onTap: () => void = (): void => {};

  build() {
    UiIconButton({ glyph: this.symbol, label: this.label, actionEnabled: this.enable, onAction: this.onTap })
  }
}

@Component
export struct ChatTextButton {
  @Prop label: string = '';
  @Prop enable: boolean = true;
  onTap: () => void = (): void => {};

  build() {
    UiActionButton({ label: this.label, actionEnabled: this.enable, onAction: this.onTap })
  }
}

@Component
export struct ChatSegmented {
  @Prop labels: string[] = [];
  @Prop selected: number = 0;
  @Prop disabledIndexes: number[] = [];
  onSelect: (index: number) => void = (_index: number): void => {};

  private disabledItems(): SegmentButtonV2Items {
    return new SegmentButtonV2Items(this.labels.map((label: string, index: number): SegmentButtonV2ItemOptions => {
      return { text: label, enabled: !this.disabledIndexes.includes(index) };
    }));
  }

  build() {
    if (this.disabledIndexes.length > 0) {
      // The shared wrapper has no disabled-item slot. Keep the platform's disabled accessibility state.
      CapsuleSegmentButtonV2({
        items: this.disabledItems(),
        selectedIndex: this.selected,
        $selectedIndex: (index: number): void => {
          if (!this.disabledIndexes.includes(index)) this.onSelect(index);
        },
      })
    } else {
      UiSegmented({ labels: this.labels, selectedIndex: this.selected, onSelectionChange: this.onSelect })
    }
  }
}
