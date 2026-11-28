import { hilog } from '@kit.PerformanceAnalysisKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { TeammateRosterEntry } from '../../core/tasks/TeammateRoster';
import { TeammateAvatar } from '../TeammateAvatar';
import { UI_FONT_CAPTION, UI_RADIUS_CONTROL, UI_LIST_CLICK_EFFECT } from '../UiKit';

let modeWrites: Promise<void> = Promise.resolve();

function ownerPreferenceKey(owner: string): string {
  const sha = cryptoFramework.createMd('SHA256');
  sha.updateSync({ data: util.TextEncoder.create('utf-8').encodeInto(owner) });
  return new util.Base64Helper().encodeToStringSync(sha.digestSync().data);
}

export async function readCompanionCompact(context: common.Context, owner: string): Promise<boolean> {
  await modeWrites;
  const store = await preferences.getPreferences(context, { name: 'cindy_home_companion_view' });
  return await store.get(ownerPreferenceKey(owner), false) === true;
}

export function writeCompanionCompact(context: common.Context, owner: string, value: boolean): void {
  modeWrites = modeWrites.then(async (): Promise<void> => {
    const store = await preferences.getPreferences(context, { name: 'cindy_home_companion_view' });
    await store.put(ownerPreferenceKey(owner), value);
    await store.flush();
  }).catch((): void => {});
}

const COMPANION_TILE_SIZE = 56;

@Component
export struct CompanionStrip {
  @Prop keys: string[] = [];
  @Prop byKey: Map<string, TeammateRosterEntry> = new Map();
  private buildEvaluations: number = 0;
  private buildInputMs: number = 0;

  private renderKeys(): string[] {
    const started = Date.now();
    const keys = this.keys;
    this.buildInputMs += Date.now() - started;
    if (++this.buildEvaluations % 32 === 1) {
      hilog.debug(0, 'CindyCompanionPerf', 'strip_build_evaluations count=%{public}d input_ms=%{public}d rows=%{public}d',
        this.buildEvaluations, this.buildInputMs, keys.length);
    }
    return keys;
  }
  @BuilderParam addMenu: () => void = this.emptyAddMenu;
  online: (row: TeammateRosterEntry) => boolean = (_row: TeammateRosterEntry): boolean => false;
  status: (row: TeammateRosterEntry) => Resource | null = (_row: TeammateRosterEntry): Resource | null => null;
  statusLabel: (row: TeammateRosterEntry) => string = (_row: TeammateRosterEntry): string => '';
  open: (row: TeammateRosterEntry) => void = (_row: TeammateRosterEntry): void => {};

  @Builder
  emptyAddMenu() {}

  @Builder
  cell(row: TeammateRosterEntry) {
    Column({ space: 5 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        TeammateAvatar({ teammate: row, online: this.online(row), diameter: COMPANION_TILE_SIZE })
          .opacity(this.online(row) ? 1 : 0.55)
        if (this.status(row) !== null) {
          Circle().width(10).height(10).fill(this.status(row) ?? $r('app.color.text_tertiary'))
            .stroke($r('app.color.bg_page')).strokeWidth(1.5)
        }
      }.width(COMPANION_TILE_SIZE).height(COMPANION_TILE_SIZE)
      Text(row.name).fontSize(UI_FONT_CAPTION).fontColor($r('app.color.text_primary'))
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').constraintSize({ minHeight: 32 }).textAlign(TextAlign.Center)
    }
    .width(COMPANION_TILE_SIZE).flexShrink(0).padding({ top: 4, bottom: 4 })
    .borderRadius(UI_RADIUS_CONTROL).clickEffect(UI_LIST_CLICK_EFFECT)
    .focusable(true)
    .accessibilityText(row.name + this.statusLabel(row))
    .onClick((): void => this.open(row))
  }

  build() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.renderKeys(), (key: string) => {
          if (this.byKey.has(key)) this.cell(this.byKey.get(key) as TeammateRosterEntry)
        }, (key: string): string => key)
        Column({ space: 5 }) {
          Stack({ alignContent: Alignment.Center }) {
            Row()
              .width(COMPANION_TILE_SIZE).height(COMPANION_TILE_SIZE).borderRadius(COMPANION_TILE_SIZE / 2)
              .border({ width: 1.5, color: $r('app.color.text_tertiary'), style: BorderStyle.Dashed })
              .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
            this.addMenu()
          }.width(COMPANION_TILE_SIZE).height(COMPANION_TILE_SIZE)
          Blank().height(32)
        }.width(COMPANION_TILE_SIZE).flexShrink(0).padding({ top: 4, bottom: 4 })
      }.justifyContent(FlexAlign.Start).alignItems(VerticalAlign.Top).padding({ left: 16, right: 16 })
    }.width('100%').align(Alignment.Start).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
  }
}
