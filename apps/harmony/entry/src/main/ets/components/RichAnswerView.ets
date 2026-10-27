/**
 * `cindy-ui` 富组件回答的 ArkUI 原生渲染。
 *
 * 行为事实源：`apps/mobile/src/session/RichAnswer.tsx`。只呈现声明式节点：
 * 颜色只映射语义角色、背景归 Cindy；按钮 / 表单只改本机视图值，不执行代码、不发消息。
 * 宽度 ≤ 600vp 时 row / grid 退为单列（`mobileColumns` 可覆盖，`layout: aside` 保持并排）。
 */
import { LengthMetrics } from '@kit.ArkUI';
import {
  RichAnswerStream,
  RichChartPoint,
  RichDocument,
  RichLinePlot,
  RichNode,
  RichOption,
  RichPlotLabel,
  RichPlotPoint,
  RichPlotTick,
  RichValue,
  RichValues,
  RichVector,
  RichVectorShape,
  RichVisualStyle,
  richAction,
  richBind,
  richCalculationUnavailable,
  richChart,
  richColorRole,
  richLabel,
  richLinePlot,
  richMarkdown,
  richMediaMarkdown,
  richNumber,
  richOptions,
  richRange,
  richResolvedValues,
  richString,
  richVector,
  richVisualStyle,
} from '../core/messages/RichAnswer';
import { RichInteractionMemory } from '../core/messages/RichInteractionMemory';
import { UI_CLICK_EFFECT, UI_RADIUS_PILL, uiFontSize, uiLineHeight } from './UiKit';

const PHONE_LAYOUT_MAX_WIDTH = 600;
const STACK_GAP = 16;
const LAYOUT_GAP = 8;
const TEXT_STYLE_KEYS: string[] = [
  'color', 'fontSize', 'fontWeight', 'fontFamily', 'fontStyle', 'lineHeight', 'letterSpacing',
  'textAlign', 'textDecorationLine',
];

/** 视图状态快照：每次变化整体替换引用，让依赖它的节点即时刷新而不重建输入控件。 */
export class RichViewState {
  values: RichValues = new Map();
  edited: Map<string, RichValue> = new Map();
  complete: boolean = false;
  calcUnavailable: string = '';
  incomplete: string = '';
}

/** 节点交互回调；普通类实例，随组件树向下传递。 */
export class RichAnswerHost {
  change: (key: string, value: RichValue) => void = (_key: string, _value: RichValue): void => {};
  apply: (node: RichNode) => void = (_node: RichNode): void => {};
}

class RichTextRole {
  size: number = 17;
  lineHeight: number = 26;
  weight: FontWeight = FontWeight.Regular;
  color: ResourceColor = $r('app.color.text_primary');
}

function textRole(size: number, lineHeight: number, weight: FontWeight, color: ResourceColor): RichTextRole {
  const role = new RichTextRole();
  role.size = size;
  role.lineHeight = lineHeight;
  role.weight = weight;
  role.color = color;
  return role;
}

const ROLE_TEXT = textRole(17, 26, FontWeight.Regular, $r('app.color.text_primary'));
const ROLE_HEADING = textRole(18, 26, FontWeight.Medium, $r('app.color.text_primary'));
const ROLE_CAPTION = textRole(13, 18, FontWeight.Regular, $r('app.color.text_secondary'));
const ROLE_ICON_TITLE = textRole(17, 26, FontWeight.Medium, $r('app.color.text_primary'));
const ROLE_STAT = textRole(24, 30, FontWeight.Medium, $r('app.color.text_primary'));
const ROLE_BUTTON = textRole(16, 22, FontWeight.Medium, $r('app.color.text_primary'));

export function richRoleColor(role: string): ResourceColor | undefined {
  if (role === 'primary') return $r('app.color.text_primary');
  if (role === 'secondary') return $r('app.color.text_secondary');
  if (role === 'tertiary') return $r('app.color.text_tertiary');
  if (role === 'success') return $r('app.color.success');
  if (role === 'warning') return $r('app.color.warn');
  if (role === 'danger') return $r('app.color.danger');
  return undefined;
}

/** Canvas 不认资源色：按语义角色读取当前主题的实际颜色。 */
function roleColorName(role: string): string {
  if (role === 'secondary') return 'text_secondary';
  if (role === 'tertiary') return 'text_tertiary';
  if (role === 'success') return 'success';
  if (role === 'warning') return 'warn';
  if (role === 'danger') return 'danger';
  if (role === 'border') return 'border';
  return 'text_primary';
}

function argbToCss(argb: number): string {
  const value = argb >>> 0;
  const a = ((value >>> 24) & 255) / 255;
  return `rgba(${(value >>> 16) & 255},${(value >>> 8) & 255},${value & 255},${a.toFixed(3)})`;
}

function styleNumber(style: RichVisualStyle, key: string): number | undefined {
  const value = style.get(key);
  return typeof value === 'number' ? value as number : undefined;
}

function styleText(style: RichVisualStyle, key: string): string {
  const value = style.get(key);
  return typeof value === 'string' ? value as string : '';
}

function styleLength(style: RichVisualStyle, key: string): Length | undefined {
  const value = style.get(key);
  if (typeof value === 'number') return value as number;
  if (typeof value === 'string' && (value as string) !== 'auto') return value as string;
  return undefined;
}

function horizontalAlign(value: string): HorizontalAlign {
  if (value === 'center') return HorizontalAlign.Center;
  if (value === 'flex-end') return HorizontalAlign.End;
  return HorizontalAlign.Start;
}

function itemAlign(value: string): ItemAlign {
  if (value === 'center') return ItemAlign.Center;
  if (value === 'flex-end') return ItemAlign.End;
  if (value === 'stretch') return ItemAlign.Stretch;
  return ItemAlign.Start;
}

function flexAlign(value: string): FlexAlign {
  if (value === 'center') return FlexAlign.Center;
  if (value === 'flex-end') return FlexAlign.End;
  if (value === 'space-between') return FlexAlign.SpaceBetween;
  if (value === 'space-around') return FlexAlign.SpaceAround;
  if (value === 'space-evenly') return FlexAlign.SpaceEvenly;
  return FlexAlign.Start;
}

function flexDirection(value: string): FlexDirection {
  if (value === 'row') return FlexDirection.Row;
  if (value === 'row-reverse') return FlexDirection.RowReverse;
  if (value === 'column-reverse') return FlexDirection.ColumnReverse;
  return FlexDirection.Column;
}

/** ForEach key 用的内容签名：长度 + djb2，避免把整段文字放进 key。 */
function textSignature(text: string): string {
  let hash = 5381;
  for (let i = 0; i < text.length; i++) hash = ((hash << 5) + hash + text.charCodeAt(i)) | 0;
  return `${text.length}:${hash >>> 0}`;
}

function richIcon(name: string): Resource {
  if (name === 'mail') return $r('sys.symbol.envelope');
  if (name === 'calendar') return $r('sys.symbol.calendar');
  if (name === 'folder') return $r('sys.symbol.folder');
  if (name === 'chart') return $r('sys.symbol.histogram');
  if (name === 'check') return $r('sys.symbol.checkmark');
  if (name === 'clock') return $r('sys.symbol.clock');
  if (name === 'location') return $r('sys.symbol.map');
  if (name === 'coffee') return $r('sys.symbol.cup');
  if (name === 'image') return $r('sys.symbol.picture');
  if (name === 'users') return $r('sys.symbol.person_2');
  if (name === 'star') return $r('sys.symbol.star');
  return $r('sys.symbol.info_circle');
}

@Builder
function richPlainMarkdown(text: string, _key: string) {
  Text(text)
    .fontSize(uiFontSize(17))
    .lineHeight(uiLineHeight(26))
    .fontColor($r('app.color.text_primary'))
    .copyOption(CopyOptions.LocalDevice)
    .width('100%')
}

@Component
export struct RichAnswerView {
  @Prop @Watch('onSourceChange') source: string = '';
  @Prop @Watch('onSourceChange') complete: boolean = false;
  @Prop @Watch('onStateKeyChange') stateKey: string = '';
  memory: RichInteractionMemory = new RichInteractionMemory();
  @BuilderParam renderMarkdown: (text: string, key: string) => void = richPlainMarkdown;
  @Provide('cindyRichDoc') richDoc: RichDocument = new RichDocument();
  @Provide('cindyRichState') richState: RichViewState = new RichViewState();
  private parser: RichAnswerStream = new RichAnswerStream();
  private host: RichAnswerHost = new RichAnswerHost();
  private unsubscribe: () => void = (): void => {};

  aboutToAppear(): void {
    this.host.change = (key: string, value: RichValue): void => {
      const patch: Map<string, RichValue> = new Map();
      patch.set(key, value);
      this.memory.set(this.stateKey, patch);
    };
    this.host.apply = (node: RichNode): void => {
      const changes = richAction(node, this.richState.values);
      if (changes.size > 0) this.memory.set(this.stateKey, changes);
    };
    this.unsubscribe = this.memory.subscribe(() => this.refreshValues());
    this.richDoc = this.parser.update(this.source, this.complete);
    this.refreshValues();
    void this.memory.load();
  }

  aboutToDisappear(): void {
    this.unsubscribe();
    void this.memory.flush();
  }

  onSourceChange(): void {
    this.richDoc = this.parser.update(this.source, this.complete);
    this.refreshValues();
  }

  onStateKeyChange(): void {
    this.refreshValues();
  }

  private refreshValues(): void {
    const next = new RichViewState();
    next.edited = this.memory.get(this.stateKey);
    next.values = richResolvedValues(this.richDoc, next.edited);
    next.complete = this.complete;
    next.calcUnavailable = this.resourceText('v133_rich_calc_unavailable');
    next.incomplete = this.resourceText('v133_rich_incomplete');
    this.richState = next;
  }

  private resourceText(name: string): string {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) return '';
    try {
      return context.resourceManager.getStringByNameSync(name);
    } catch (_error) {
      return '';
    }
  }

  build() {
    Column({ space: STACK_GAP }) {
      ForEach(this.richDoc.roots, (id: string) => {
        RichNodeView({ nodeId: id, host: this.host, renderMarkdown: this.renderMarkdown })
      }, (id: string) => id)
      if (this.richDoc.issues > 0) {
        Text(this.richState.incomplete)
          .fontSize(uiFontSize(13))
          .lineHeight(uiLineHeight(18))
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
struct RichNodeView {
  nodeId: string = '';
  host: RichAnswerHost = new RichAnswerHost();
  @BuilderParam renderMarkdown: (text: string, key: string) => void = richPlainMarkdown;
  @Consume('cindyRichDoc') richDoc: RichDocument;
  @Consume('cindyRichState') richState: RichViewState;
  @State layoutWidth: number = 0;

  private node(): RichNode {
    const node = this.richDoc.nodes.get(this.nodeId);
    if (node !== undefined) return node;
    const empty = new RichNode();
    empty.id = this.nodeId;
    return empty;
  }

  private visual(): RichVisualStyle {
    return richVisualStyle(this.node());
  }

  /** 文字样式沿父节点继承（对齐 Mobile 渲染时向下传递的 inherited textStyle）。 */
  private textStyle(): RichVisualStyle {
    const chain: string[] = [];
    let cursor: string | undefined = this.nodeId;
    while (cursor !== undefined && chain.length < 40) {
      chain.unshift(cursor);
      cursor = this.richDoc.parents.get(cursor);
    }
    const merged: RichVisualStyle = new Map();
    chain.forEach((id: string) => {
      const node = this.richDoc.nodes.get(id);
      if (node === undefined) return;
      richVisualStyle(node).forEach((value: string | number, key: string) => {
        if (TEXT_STYLE_KEYS.includes(key)) merged.set(key, value);
      });
    });
    return merged;
  }

  private parentIsRowStack(): boolean {
    const parentId = this.richDoc.parents.get(this.nodeId);
    const parent = parentId !== undefined ? this.richDoc.nodes.get(parentId) : undefined;
    if (parent === undefined || (parent.kind !== 'stack' && parent.kind !== 'group' && parent.kind !== 'form')) {
      return false;
    }
    const direction = styleText(richVisualStyle(parent), 'flexDirection');
    return direction === 'row' || direction === 'row-reverse';
  }

  private wrapperWidth(): Length {
    const width = styleLength(this.visual(), 'width');
    if (width !== undefined) return width;
    return this.parentIsRowStack() ? 'auto' : '100%';
  }

  private wrapperConstraint(): ConstraintSizeOptions {
    const style = this.visual();
    const media = ['image', 'video', 'audio'].includes(this.node().kind);
    const options: ConstraintSizeOptions = {};
    const maxWidth = styleLength(style, 'maxWidth');
    // 在桌面写的回答也会在手机上看：固定宽度不得超出屏幕。
    options.maxWidth = maxWidth !== undefined ? maxWidth : '100%';
    const minWidth = styleLength(style, 'minWidth');
    if (minWidth !== undefined) options.minWidth = minWidth;
    if (!media) {
      const minHeight = styleLength(style, 'minHeight');
      const maxHeight = styleLength(style, 'maxHeight');
      if (minHeight !== undefined) options.minHeight = minHeight;
      if (maxHeight !== undefined) options.maxHeight = maxHeight;
    }
    return options;
  }

  private wrapperHeight(): Length | undefined {
    if (['image', 'video', 'audio', 'svg'].includes(this.node().kind)) return undefined;
    return styleLength(this.visual(), 'height');
  }

  private wrapperPadding(): Padding {
    const style = this.visual();
    const all = styleNumber(style, 'padding');
    const side = (key: string): number => {
      const value = styleNumber(style, key);
      return value !== undefined ? value : (all !== undefined ? all : 0);
    };
    const padding: Padding = {
      top: side('paddingTop'), right: side('paddingRight'),
      bottom: side('paddingBottom'), left: side('paddingLeft'),
    };
    return padding;
  }

  private wrapperMargin(): Margin {
    const style = this.visual();
    const top = styleNumber(style, 'marginTop');
    const bottom = styleNumber(style, 'marginBottom');
    const margin: Margin = { top: top !== undefined ? top : 0, bottom: bottom !== undefined ? bottom : 0 };
    return margin;
  }

  private wrapperBorder(): BorderOptions {
    const style = this.visual();
    const border: BorderOptions = { width: 0 };
    if (!style.has('borderWidth')) return border;
    const kind = styleText(style, 'borderStyle');
    border.width = 1;
    border.color = $r('app.color.border');
    border.style = kind === 'dashed' ? BorderStyle.Dashed : (kind === 'dotted' ? BorderStyle.Dotted : BorderStyle.Solid);
    return border;
  }

  private numberStyle(key: string, fallback: number): number {
    const value = styleNumber(this.visual(), key);
    return value !== undefined ? value : fallback;
  }

  private textSize(role: RichTextRole): number {
    const size = styleNumber(this.textStyle(), 'fontSize');
    return uiFontSize(size !== undefined ? size : role.size);
  }

  private textLineHeight(role: RichTextRole): number {
    const style = this.textStyle();
    const size = styleNumber(style, 'fontSize');
    const line = styleNumber(style, 'lineHeight');
    const fontSize = size !== undefined ? size : role.size;
    if (line === undefined) return uiLineHeight(fontSize * role.lineHeight / role.size);
    return uiLineHeight(line <= 4 ? fontSize * line : line);
  }

  private textColor(role: RichTextRole): ResourceColor {
    const color = richRoleColor(styleText(this.textStyle(), 'color'));
    return color !== undefined ? color : role.color;
  }

  private textWeight(role: RichTextRole): number | FontWeight | string {
    const weight = styleText(this.textStyle(), 'fontWeight');
    return weight.length > 0 ? weight : role.weight;
  }

  private textAlignment(): TextAlign {
    const align = styleText(this.textStyle(), 'textAlign');
    if (align === 'center') return TextAlign.Center;
    if (align === 'right') return TextAlign.End;
    if (align === 'justify') return TextAlign.JUSTIFY;
    return TextAlign.Start;
  }

  private textDecoration(): DecorationStyleInterface {
    const line = styleText(this.textStyle(), 'textDecorationLine');
    const decoration: DecorationStyleInterface = {
      type: line === 'underline' ? TextDecorationType.Underline
        : (line === 'line-through' ? TextDecorationType.LineThrough : TextDecorationType.None),
    };
    return decoration;
  }

  private textFamily(): string {
    const family = styleText(this.textStyle(), 'fontFamily');
    return family.length > 0 ? family : 'HarmonyOS Sans';
  }

  private textStyleKind(): FontStyle {
    return styleText(this.textStyle(), 'fontStyle') === 'italic' ? FontStyle.Italic : FontStyle.Normal;
  }

  private textSpacing(): number {
    const spacing = styleNumber(this.textStyle(), 'letterSpacing');
    return spacing !== undefined ? spacing : 0;
  }

  private bind(): string {
    return richBind(this.node());
  }

  private current(): RichValue | undefined {
    return this.richState.values.get(this.bind());
  }

  private label(): string {
    return richString(this.node(), 'label');
  }

  // ─── row / grid 排布（对齐 Mobile AnswerLayout） ──────────────────────────

  private layoutAside(): boolean {
    return richString(this.node(), 'layout') === 'aside';
  }

  private layoutPhone(): boolean {
    return this.layoutWidth <= PHONE_LAYOUT_MAX_WIDTH && !this.layoutAside();
  }

  private layoutWeights(): number[] {
    const raw = this.node().props['weights'];
    if (Array.isArray(raw)) {
      return (raw as Object[]).filter((v: Object) => typeof v === 'number' && Number.isFinite(v) && (v as number) > 0)
        .map((v: Object) => v as number);
    }
    return this.layoutAside() ? [0.7, 1.8] : [];
  }

  private layoutColumns(): number {
    if (styleText(this.visual(), 'flexDirection') === 'column') return 1;
    const weights = this.layoutWeights();
    const preferred = this.layoutPhone() ? richNumber(this.node(), 'mobileColumns', 1)
      : (weights.length > 0 ? weights.length : richNumber(this.node(), 'columns', 2));
    return Math.max(1, Math.round(preferred));
  }

  private layoutGap(): number {
    return this.numberStyle('gap', LAYOUT_GAP);
  }

  private layoutChildWidth(index: number): Length {
    if (this.layoutWidth <= 0) return '100%';
    const columns = this.layoutColumns();
    const usable = Math.max(0, this.layoutWidth - this.layoutGap() * (columns - 1));
    const weights = this.layoutWeights();
    if (!this.layoutPhone() && columns > 1 && weights.length > 0) {
      const total = weights.reduce((a: number, b: number) => a + b, 0);
      return Math.floor(usable * weights[index % columns] / total);
    }
    return Math.floor(usable / columns);
  }

  // ─── 柱状图 ────────────────────────────────────────────────────────────────

  private chartData(): RichChartPoint[] {
    return richChart(this.node(), this.richState.values);
  }

  private chartSpan(data: RichChartPoint[]): number[] {
    let min = 0;
    let max = 0;
    data.forEach((item: RichChartPoint) => {
      min = Math.min(min, item.value);
      max = Math.max(max, item.value);
    });
    const span = max - min;
    return [min, span !== 0 ? span : 1];
  }

  private barOffset(item: RichChartPoint, data: RichChartPoint[]): string {
    const span = this.chartSpan(data);
    return `${((Math.min(0, item.value) - span[0]) / span[1]) * 100}%`;
  }

  private barWidth(item: RichChartPoint, data: RichChartPoint[]): string {
    return `${(Math.abs(item.value) / this.chartSpan(data)[1]) * 100}%`;
  }

  private barColor(index: number): ResourceColor {
    const colors = this.node().props['colors'];
    if (Array.isArray(colors) && index < (colors as Object[]).length) {
      const indexed = richRoleColor(richColorRole((colors as Object[])[index]));
      if (indexed !== undefined) return indexed;
    }
    const single = richRoleColor(richColorRole(this.node().props['color']));
    return single !== undefined ? single : $r('app.color.text_secondary');
  }

  private mediaText(): string {
    const context = this.getUIContext().getHostContext();
    let openVideo = '';
    let openMedia = '';
    if (context !== undefined) {
      try {
        openVideo = context.resourceManager.getStringByNameSync('v133_rich_open_video');
        openMedia = context.resourceManager.getStringByNameSync('v133_rich_open_media');
      } catch (_error) {
        // 资源缺失时链接退回原地址。
      }
    }
    return richMediaMarkdown(this.node(), openVideo, openMedia);
  }

  /**
   * @Builder 的普通参数按值传入，状态变化后不会重新求值；计算值（text / heading / stat）
   * 必须在 builder 内部读取 richState，才能随滑块、输入即时刷新。
   */
  @Builder
  styledText(text: () => string, role: RichTextRole) {
    Text(text())
      .fontSize(this.textSize(role))
      .lineHeight(this.textLineHeight(role))
      .fontWeight(this.textWeight(role))
      .fontColor(this.textColor(role))
      .fontFamily(this.textFamily())
      .fontStyle(this.textStyleKind())
      .letterSpacing(this.textSpacing())
      .textAlign(this.textAlignment())
      .decoration(this.textDecoration())
      .copyOption(CopyOptions.LocalDevice)
      .width('100%')
  }

  private chipSelected(mode: string, choice: string): boolean {
    if (mode === 'select') return this.current() === choice;
    if (mode === 'tab') return this.selectedTab() === choice;
    return false;
  }

  /** 选中态同样在 builder 内读取状态（mode: select / tab / 空串表示普通按钮）。 */
  @Builder
  chip(label: () => string, mode: string, choice: string, action: () => void) {
    Text(label())
      .fontSize(uiFontSize(ROLE_BUTTON.size))
      .lineHeight(uiLineHeight(ROLE_BUTTON.lineHeight))
      .fontWeight(ROLE_BUTTON.weight)
      .fontColor($r('app.color.text_primary'))
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .constraintSize({ minHeight: 44 })
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(UI_RADIUS_PILL)
      .border({ width: this.chipSelected(mode, choice) ? 1 : 0, color: $r('app.color.text_tertiary') })
      .accessibilityText(label())
      .accessibilitySelected(this.chipSelected(mode, choice))
      .clickEffect(UI_CLICK_EFFECT)
      .onClick(() => action())
  }

  @Builder
  caption(text: () => string) {
    Text(text())
      .fontSize(uiFontSize(ROLE_CAPTION.size))
      .lineHeight(uiLineHeight(ROLE_CAPTION.lineHeight))
      .fontColor($r('app.color.text_secondary'))
  }

  @Builder
  children(direction: () => FlexDirection) {
    Flex({
      direction: direction(),
      wrap: styleText(this.visual(), 'flexWrap') === 'wrap' ? FlexWrap.Wrap : FlexWrap.NoWrap,
      justifyContent: flexAlign(styleText(this.visual(), 'justifyContent')),
      alignItems: itemAlign(styleText(this.visual(), 'alignItems')),
      space: { main: LengthMetrics.vp(this.numberStyle('gap', STACK_GAP)), cross: LengthMetrics.vp(this.numberStyle('gap', STACK_GAP)) },
    }) {
      ForEach(this.node().children, (child: string) => {
        RichNodeView({ nodeId: child, host: this.host, renderMarkdown: this.renderMarkdown })
      }, (child: string) => child)
    }
    .width('100%')
  }

  @Builder
  content() {
    if (richCalculationUnavailable(this.node(), this.richState.values)) {
      this.caption(() => this.richState.complete ? this.richState.calcUnavailable : '…')
    } else if (['image', 'video', 'audio'].includes(this.node().kind)) {
      ForEach(this.markdownSources(this.mediaText()), (text: string) => {
        this.renderMarkdown(text, `${this.nodeId}:media`)
      }, (text: string) => `${this.nodeId}:media:${textSignature(text)}`)
      if (richString(this.node(), 'caption').length > 0) this.caption(() => richString(this.node(), 'caption'))
    } else if (richMarkdown(this.node()) !== null) {
      // 内容按值传给 Markdown builder：以内容为 key，追加 / patch 后重建该段。
      ForEach(this.markdownSources(richMarkdown(this.node()) as string), (text: string) => {
        this.renderMarkdown(text, this.nodeId)
      }, (text: string) => `${this.nodeId}:md:${textSignature(text)}`)
      if (richString(this.node(), 'caption').length > 0) this.caption(() => richString(this.node(), 'caption'))
    } else if (this.node().kind === 'svg' || (this.node().kind === 'chart' && richString(this.node(), 'variant') === 'line')) {
      if (this.node().kind === 'chart') this.styledText(() => this.label(), ROLE_TEXT)
      RichCanvasView({ nodeId: this.nodeId })
    } else if (this.node().kind === 'text') {
      this.styledText(() => richLabel(this.node(), this.richState.values), ROLE_TEXT)
    } else if (this.node().kind === 'heading') {
      this.styledText(() => richLabel(this.node(), this.richState.values), ROLE_HEADING)
    } else if (this.node().kind === 'icon') {
      Row({ space: 12 }) {
        SymbolGlyph(richIcon(richString(this.node(), 'name')))
          .fontSize(richNumber(this.node(), 'size', 20))
          .fontColor([this.textColor(ROLE_TEXT)])
          .accessibilityLevel('no')
        Column({ space: 4 }) {
          this.styledText(() => this.label().length > 0 ? this.label() : richString(this.node(), 'name'), ROLE_ICON_TITLE)
          if (richString(this.node(), 'text').length > 0) this.styledText(() => richString(this.node(), 'text'), ROLE_TEXT)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    } else if (this.node().kind === 'divider') {
      Divider().color($r('app.color.border')).strokeWidth(0.5).width('100%')
    } else if (this.node().kind === 'stack' || this.node().kind === 'group') {
      this.children(() => flexDirection(styleText(this.visual(), 'flexDirection')))
    } else if (this.node().kind === 'row' || this.node().kind === 'grid') {
      Flex({
        direction: FlexDirection.Row,
        wrap: FlexWrap.Wrap,
        space: { main: LengthMetrics.vp(this.layoutGap()), cross: LengthMetrics.vp(this.layoutGap()) },
      }) {
        ForEach(this.node().children, (child: string, index: number) => {
          Column() {
            RichNodeView({ nodeId: child, host: this.host, renderMarkdown: this.renderMarkdown })
          }
          .width(this.layoutChildWidth(index))
          .alignItems(HorizontalAlign.Start)
        }, (child: string) => child)
      }
      .width('100%')
      .onAreaChange((_old: Area, next: Area) => {
        const width = Number(next.width);
        if (Math.abs(width - this.layoutWidth) >= 1) this.layoutWidth = width;
      })
    } else if (this.node().kind === 'stat') {
      Column({ space: 4 }) {
        this.caption(() => this.label())
        this.styledText(() => richLabel(this.node(), this.richState.values), ROLE_STAT)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 12, bottom: 12 })
      .border({ width: { top: 0.5 }, color: $r('app.color.border') })
    } else if (this.node().kind === 'input') {
      Column({ space: 8 }) {
        this.styledText(() => this.label(), ROLE_TEXT)
        TextInput({
          text: this.current() !== undefined ? String(this.current()) : '',
          placeholder: richString(this.node(), 'placeholder'),
        })
          .maxLength(4096)
          .fontSize(uiFontSize(16))
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_placeholder'))
          .backgroundColor($r('app.color.bg_chip'))
          .borderRadius(UI_RADIUS_PILL)
          .constraintSize({ minHeight: 44 })
          .padding({ left: 16, right: 16 })
          .accessibilityText(this.label())
          .onChange((value: string) => this.host.change(this.bind(), value))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (this.node().kind === 'range') {
      Column({ space: 4 }) {
        Row({ space: 12 }) {
          Text(this.label())
            .fontSize(uiFontSize(17)).lineHeight(uiLineHeight(26)).fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text(`${richRange(this.node(), this.current()).value}${richString(this.node(), 'suffix')}`)
            .fontSize(uiFontSize(17)).lineHeight(uiLineHeight(26)).fontColor($r('app.color.text_primary'))
        }
        .width('100%')
        Slider({
          value: richRange(this.node(), this.current()).value,
          min: richRange(this.node(), this.current()).min,
          max: richRange(this.node(), this.current()).max,
          step: richRange(this.node(), this.current()).step,
        })
          .width('100%')
          .height(44)
          .blockColor($r('app.color.text_primary'))
          .trackColor($r('app.color.border'))
          .selectedColor($r('app.color.text_secondary'))
          .accessibilityText(this.label())
          .onChange((value: number) => {
            const range = richRange(this.node(), value);
            const snapped = range.min + Math.round((range.value - range.min) / range.step) * range.step;
            this.host.change(this.bind(), Math.max(range.min, Math.min(range.max, snapped)));
          })
      }
      .width('100%')
    } else if (this.node().kind === 'check') {
      Row({ space: 12 }) {
        Text(this.label().length > 0 ? this.label() : richString(this.node(), 'text'))
          .fontSize(uiFontSize(17)).lineHeight(uiLineHeight(26)).fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.current() === true })
          .selectedColor($r('app.color.text_secondary'))
          .accessibilityText(this.label())
          .onChange((isOn: boolean) => this.host.change(this.bind(), isOn))
      }
      .width('100%')
    } else if (this.node().kind === 'select') {
      Column({ space: 8 }) {
        this.styledText(() => this.label(), ROLE_TEXT)
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
          ForEach(richOptions(this.node()), (option: RichOption) => {
            this.chip(() => this.optionLabel(option.value), 'select', option.value,
              () => this.host.change(this.bind(), option.value))
          }, (option: RichOption) => option.value)
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (this.node().kind === 'button') {
      this.chip(() => this.label().length > 0 ? this.label() : richString(this.node(), 'text'), '', '',
        () => this.host.apply(this.node()))
    } else if (this.node().kind === 'form') {
      Column({ space: STACK_GAP }) {
        this.children(() => FlexDirection.Column)
        if (this.label().length > 0) this.chip(() => this.label(), '', '', () => this.host.apply(this.node()))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (this.node().kind === 'details') {
      Column({ space: STACK_GAP }) {
        this.chip(() => this.label(), '', '', () => this.host.change(this.bind(), !this.current()))
        Column() {
          this.children(() => FlexDirection.Column)
        }
        .width('100%')
        // 收起时保留节点，展开 / 收起不丢失其中控件的状态（对齐 Mobile display:none）。
        .visibility(this.current() ? Visibility.Visible : Visibility.None)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (this.node().kind === 'tabs') {
      Column({ space: STACK_GAP }) {
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
          ForEach(this.node().children, (child: string) => {
            this.chip(() => this.tabLabel(child), 'tab', child,
              () => this.host.change(this.bind(), child))
          }, (child: string) => child)
        }
        .width('100%')
        ForEach(this.node().children, (child: string) => {
          Column() {
            RichNodeView({ nodeId: child, host: this.host, renderMarkdown: this.renderMarkdown })
          }
          .width('100%')
          .visibility(this.selectedTab() === child ? Visibility.Visible : Visibility.None)
        }, (child: string) => child)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (this.node().kind === 'chart') {
      Column({ space: STACK_GAP }) {
        this.styledText(() => this.label(), ROLE_TEXT)
        ForEach(this.chartData(), (item: RichChartPoint, index: number) => {
          Column({ space: 4 }) {
            Row({ space: 12 }) {
              this.caption(() => item.label)
              Blank()
              this.caption(() => String(item.value))
            }
            .width('100%')
            Row() {
              Row()
                .height('100%')
                .width(this.barWidth(item, this.chartData()))
                .margin({ left: this.barOffset(item, this.chartData()) })
                .backgroundColor(this.barColor(index))
            }
            .width('100%')
            .height(8)
            .backgroundColor($r('app.color.bg_chip'))
            .borderRadius(4)
            .clip(true)
          }
          .width('100%')
        }, (item: RichChartPoint, index: number) => `${index}:${item.label}:${item.value}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  private markdownSources(text: string): string[] {
    return text.length > 0 ? [text] : [];
  }

  private optionLabel(value: string): string {
    const option = richOptions(this.node()).find((item: RichOption) => item.value === value);
    return option !== undefined ? option.label : value;
  }

  private tabLabel(child: string): string {
    const node = this.richDoc.nodes.get(child);
    return node !== undefined ? richString(node, 'label', child) : child;
  }

  private selectedTab(): string {
    const children = this.node().children;
    const current = this.current();
    const selected = current !== undefined ? String(current) : '';
    return children.includes(selected) ? selected : (children.length > 0 ? children[0] : '');
  }

  build() {
    Column() {
      this.content()
    }
    .width(this.wrapperWidth())
    .height(this.wrapperHeight())
    .constraintSize(this.wrapperConstraint())
    .padding(this.wrapperPadding())
    .margin(this.wrapperMargin())
    .border(this.wrapperBorder())
    .borderRadius(this.numberStyle('borderRadius', 0))
    .opacity(this.numberStyle('opacity', 1))
    .flexGrow(this.numberStyle('flexGrow', 0))
    .flexShrink(this.numberStyle('flexShrink', 1))
    .alignItems(horizontalAlign(styleText(this.visual(), 'alignItems')))
  }
}

// ─── Canvas：SVG 与折线图 ─────────────────────────────────────────────────────

class CanvasPalette {
  primary: string = 'rgba(0,0,0,1)';
  secondary: string = 'rgba(0,0,0,0.6)';
  border: string = 'rgba(0,0,0,0.1)';
  roles: Map<string, string> = new Map();
}

function shapeNumber(shape: RichVectorShape, key: string, fallback: number): number {
  const value = shape.props.get(key);
  return typeof value === 'number' ? value as number : fallback;
}

function shapeText(shape: RichVectorShape, key: string): string {
  const value = shape.props.get(key);
  return typeof value === 'string' ? value as string : '';
}

function parsePoints(points: string): number[] {
  return points.trim().split(/[\s,]+/).filter((item: string) => item.length > 0).map((item: string) => Number(item));
}

/** 只解析已过白名单的 transform；按 SVG 语义从左到右叠加。 */
function applyTransform(ctx: CanvasRenderingContext2D, transform: string): void {
  const pattern = /(translate|scale|rotate|matrix|skewX|skewY)\(([^)]*)\)/g;
  let match = pattern.exec(transform);
  while (match !== null) {
    const args = parsePoints(match[2]);
    const name = match[1];
    if (name === 'translate') ctx.translate(args[0] ?? 0, args[1] ?? 0);
    else if (name === 'scale') ctx.scale(args[0] ?? 1, args.length > 1 ? args[1] : (args[0] ?? 1));
    else if (name === 'rotate') {
      const angle = (args[0] ?? 0) * Math.PI / 180;
      if (args.length >= 3) {
        ctx.translate(args[1], args[2]);
        ctx.rotate(angle);
        ctx.translate(-args[1], -args[2]);
      } else ctx.rotate(angle);
    } else if (name === 'matrix' && args.length >= 6) {
      ctx.transform(args[0], args[1], args[2], args[3], args[4], args[5]);
    } else if (name === 'skewX') ctx.transform(1, 0, Math.tan((args[0] ?? 0) * Math.PI / 180), 1, 0, 0);
    else if (name === 'skewY') ctx.transform(1, Math.tan((args[0] ?? 0) * Math.PI / 180), 0, 1, 0, 0);
    match = pattern.exec(transform);
  }
}

@Component
struct RichCanvasView {
  nodeId: string = '';
  @Consume('cindyRichDoc') @Watch('redraw') richDoc: RichDocument;
  @Consume('cindyRichState') @Watch('redraw') richState: RichViewState;
  @StorageProp('cindyColorMode') @Watch('redraw') colorMode: number = -1;
  @State canvasWidth: number = 0;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;

  private node(): RichNode {
    const node = this.richDoc.nodes.get(this.nodeId);
    if (node !== undefined) return node;
    const empty = new RichNode();
    empty.id = this.nodeId;
    return empty;
  }

  private isChart(): boolean {
    return this.node().kind === 'chart';
  }

  private plot(): RichLinePlot {
    return richLinePlot(richChart(this.node(), this.richState.values),
      this.canvasWidth > 0 ? this.canvasWidth : 320, this.node().props);
  }

  private vector(): RichVector {
    return richVector(this.node());
  }

  private canvasHeight(): number {
    if (this.isChart()) return this.plot().height;
    const box = this.vector().viewBox;
    const style = richVisualStyle(this.node());
    const fixed = styleNumber(style, 'height');
    const minHeight = styleNumber(style, 'minHeight');
    const maxHeight = styleNumber(style, 'maxHeight');
    const natural = fixed !== undefined ? fixed : this.canvasWidth * box[3] / box[2];
    return Math.min(maxHeight !== undefined ? maxHeight : Number.MAX_VALUE,
      Math.max(minHeight !== undefined ? minHeight : 0, natural));
  }

  private accessibility(): string {
    const node = this.node();
    if (!this.isChart()) return richString(node, 'label', richString(node, 'alt'));
    const points = richChart(node, this.richState.values)
      .map((item: RichChartPoint) => `${item.label}: ${item.value}`).join(', ');
    return `${richString(node, 'label')}. ${points}`;
  }

  private palette(): CanvasPalette {
    const palette = new CanvasPalette();
    const context = this.getUIContext().getHostContext();
    if (context === undefined) return palette;
    const resources = context.resourceManager.getOverrideResourceManager();
    const read = (role: string): string => {
      try {
        return argbToCss(resources.getColorByNameSync(roleColorName(role)));
      } catch (_error) {
        return palette.primary;
      }
    };
    palette.primary = read('primary');
    palette.secondary = read('secondary');
    palette.border = read('border');
    ['primary', 'secondary', 'tertiary', 'success', 'warning', 'danger'].forEach((role: string) => {
      palette.roles.set(role, read(role));
    });
    return palette;
  }

  redraw(): void {
    if (!this.ready || this.canvasWidth <= 0) return;
    const ctx = this.ctx;
    ctx.clearRect(0, 0, ctx.width, ctx.height);
    const palette = this.palette();
    if (this.isChart()) this.drawChart(palette);
    else this.drawVector(palette);
  }

  private drawChart(palette: CanvasPalette): void {
    const ctx = this.ctx;
    const node = this.node();
    const plot = this.plot();
    const ratio = this.canvasWidth / plot.width;
    const roleColor = palette.roles.get(richColorRole(node.props['color']));
    const color = roleColor !== undefined ? roleColor : palette.primary;
    ctx.save();
    ctx.scale(ratio, 1);
    ctx.font = `${uiFontSize(13)}vp sans-serif`;
    ctx.lineWidth = 1;
    plot.ticks.forEach((tick: RichPlotTick) => {
      if (node.props['showGrid'] !== false) {
        ctx.strokeStyle = palette.border;
        ctx.beginPath();
        ctx.moveTo(plot.left, tick.y);
        ctx.lineTo(plot.width - plot.right, tick.y);
        ctx.stroke();
      }
      ctx.fillStyle = palette.secondary;
      ctx.textAlign = 'right';
      ctx.fillText(tick.label, plot.left - 6, tick.y + 4);
    });
    if (plot.points.length > 0) {
      ctx.strokeStyle = color;
      ctx.lineWidth = richNumber(node, 'strokeWidth', 2);
      ctx.lineJoin = 'round';
      ctx.beginPath();
      plot.points.forEach((point: RichPlotPoint, index: number) => {
        if (index === 0) ctx.moveTo(point.x, point.y);
        else ctx.lineTo(point.x, point.y);
      });
      ctx.stroke();
    }
    ctx.fillStyle = palette.secondary;
    ctx.textAlign = 'center';
    plot.labels.forEach((label: RichPlotLabel) => ctx.fillText(label.label, label.x, plot.labelY));
    plot.points.forEach((point: RichPlotPoint) => {
      if (node.props['showPoints'] !== false) {
        ctx.fillStyle = color;
        ctx.beginPath();
        ctx.arc(point.x, point.y, richNumber(node, 'pointRadius', 3), 0, Math.PI * 2);
        ctx.fill();
      }
      if (plot.showValues) {
        ctx.fillStyle = palette.primary;
        ctx.fillText(String(point.value), point.x, point.y - 10);
      }
    });
    ctx.restore();
  }

  private paint(shape: RichVectorShape, key: string, palette: CanvasPalette, fallback: string): string {
    const role = shapeText(shape, key);
    if (role === 'none') return '';
    if (role.length === 0) return fallback;
    const color = palette.roles.get(role);
    return color !== undefined ? color : fallback;
  }

  private drawVector(palette: CanvasPalette): void {
    const ctx = this.ctx;
    const vector = this.vector();
    const box = vector.viewBox;
    const height = this.canvasHeight();
    ctx.save();
    ctx.scale(this.canvasWidth / box[2], height / box[3]);
    ctx.translate(-box[0], -box[1]);
    vector.shapes.forEach((shape: RichVectorShape) => {
      ctx.save();
      const transform = shapeText(shape, 'transform');
      if (transform.length > 0) applyTransform(ctx, transform);
      const opacity = shapeNumber(shape, 'opacity', 1);
      // 未指定填充的形状沿用宿主正文色，而不是 SVG 默认的黑色。
      const fill = this.paint(shape, 'fill', palette, shape.type === 'line' ? '' : palette.primary);
      const stroke = this.paint(shape, 'stroke', palette, '');
      ctx.lineWidth = shapeNumber(shape, 'strokeWidth', 1);
      const cap = shapeText(shape, 'strokeLinecap');
      if (cap.length > 0) ctx.lineCap = cap as CanvasLineCap;
      const join = shapeText(shape, 'strokeLinejoin');
      if (join.length > 0) ctx.lineJoin = join as CanvasLineJoin;
      const dash = shapeText(shape, 'strokeDasharray');
      ctx.setLineDash(dash.length > 0 ? parsePoints(dash) : []);
      if (shape.type === 'text') {
        const size = shapeNumber(shape, 'fontSize', 16);
        const weight = shapeText(shape, 'fontWeight');
        ctx.font = `${weight.length > 0 ? weight : 'normal'} ${size}vp sans-serif`;
        const anchor = shapeText(shape, 'textAnchor');
        ctx.textAlign = anchor === 'middle' ? 'center' : (anchor === 'end' ? 'end' : 'start');
        if (fill.length > 0) {
          ctx.globalAlpha = opacity * shapeNumber(shape, 'fillOpacity', 1);
          ctx.fillStyle = fill;
          ctx.fillText(shape.text, shapeNumber(shape, 'x', 0), shapeNumber(shape, 'y', 0));
        }
        ctx.restore();
        return;
      }
      const path = this.shapePath(shape);
      if (path !== null) {
        if (fill.length > 0) {
          ctx.globalAlpha = opacity * shapeNumber(shape, 'fillOpacity', 1);
          ctx.fillStyle = fill;
          ctx.fill(path);
        }
        if (stroke.length > 0) {
          ctx.globalAlpha = opacity * shapeNumber(shape, 'strokeOpacity', 1);
          ctx.strokeStyle = stroke;
          ctx.stroke(path);
        }
      }
      ctx.restore();
    });
    ctx.restore();
  }

  private shapePath(shape: RichVectorShape): Path2D | null {
    if (shape.type === 'path') {
      const d = shapeText(shape, 'd');
      return d.length > 0 ? new Path2D(d) : null;
    }
    const path = new Path2D();
    if (shape.type === 'rect') {
      const x = shapeNumber(shape, 'x', 0);
      const y = shapeNumber(shape, 'y', 0);
      const w = shapeNumber(shape, 'width', 0);
      const h = shapeNumber(shape, 'height', 0);
      if (w <= 0 || h <= 0) return null;
      const rxRaw = shape.props.has('rx') ? shapeNumber(shape, 'rx', 0) : shapeNumber(shape, 'ry', 0);
      const rx = Math.min(Math.max(0, rxRaw), w / 2);
      const ry = Math.min(Math.max(0, shape.props.has('ry') ? shapeNumber(shape, 'ry', 0) : rxRaw), h / 2);
      if (rx <= 0 || ry <= 0) {
        path.rect(x, y, w, h);
        return path;
      }
      path.moveTo(x + rx, y);
      path.lineTo(x + w - rx, y);
      path.ellipse(x + w - rx, y + ry, rx, ry, 0, -Math.PI / 2, 0);
      path.lineTo(x + w, y + h - ry);
      path.ellipse(x + w - rx, y + h - ry, rx, ry, 0, 0, Math.PI / 2);
      path.lineTo(x + rx, y + h);
      path.ellipse(x + rx, y + h - ry, rx, ry, 0, Math.PI / 2, Math.PI);
      path.lineTo(x, y + ry);
      path.ellipse(x + rx, y + ry, rx, ry, 0, Math.PI, Math.PI * 1.5);
      path.closePath();
      return path;
    }
    if (shape.type === 'circle') {
      const r = shapeNumber(shape, 'r', 0);
      if (r <= 0) return null;
      path.arc(shapeNumber(shape, 'cx', 0), shapeNumber(shape, 'cy', 0), r, 0, Math.PI * 2);
      return path;
    }
    if (shape.type === 'ellipse') {
      const rx = shapeNumber(shape, 'rx', 0);
      const ry = shapeNumber(shape, 'ry', 0);
      if (rx <= 0 || ry <= 0) return null;
      path.ellipse(shapeNumber(shape, 'cx', 0), shapeNumber(shape, 'cy', 0), rx, ry, 0, 0, Math.PI * 2);
      return path;
    }
    if (shape.type === 'line') {
      path.moveTo(shapeNumber(shape, 'x1', 0), shapeNumber(shape, 'y1', 0));
      path.lineTo(shapeNumber(shape, 'x2', 0), shapeNumber(shape, 'y2', 0));
      return path;
    }
    const points = parsePoints(shapeText(shape, 'points'));
    if (points.length < 4) return null;
    path.moveTo(points[0], points[1]);
    for (let i = 2; i + 1 < points.length; i += 2) path.lineTo(points[i], points[i + 1]);
    if (shape.type === 'polygon') path.closePath();
    return path;
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height(this.canvasHeight())
      .accessibilityText(this.accessibility())
      .onReady(() => {
        this.ready = true;
        this.redraw();
      })
      .onAreaChange((_old: Area, next: Area) => {
        const width = Number(next.width);
        if (Math.abs(width - this.canvasWidth) >= 1) {
          this.canvasWidth = width;
          // 尺寸变化后画布会清空，等下一帧布局完成再画。
          setTimeout(() => this.redraw(), 0);
        }
      })
  }
}
