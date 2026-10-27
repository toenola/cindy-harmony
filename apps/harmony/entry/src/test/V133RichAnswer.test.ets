import { describe, expect, it } from '@ohos/hypium';
import {
  RichAnswerStream, RichPart, RichValue, hasRichAnswer, richAnswerText, richLinePlot, richResolvedValues,
  richMediaMarkdown, richVisualStyle, richYoutubeWatchUrl, splitRichAnswer, RichChartPoint, RichNode, RichPlotTick,
} from '../main/ets/core/messages/RichAnswer';
import { RichInteractionMemory, RichStateStorage, parseStoredEntries } from '../main/ets/core/messages/RichInteractionMemory';
import { buildRenderItems, RenderItem, RenderMessageItem, RenderRichPart } from '../main/ets/core/messages/MessageRender';
import { freezeShareProjection } from '../main/ets/core/sharing/ConversationShareProjection';
import { parseMessage, RemoteMessage } from '../main/ets/core/tasks/TaskModels';

// 期望值均由共享实现 packages/maker-shared/src/richAnswer.ts 对同一输入实际运行得到。
const FENCE = '```';
const ANSWER = [
  'Intro',
  `${FENCE}cindy-ui`,
  '{"version":1,"seq":1,"op":"create","id":"months","kind":"range","props":{"label":"Months","min":1,"max":24,"default":6}}',
  '{"seq":2,"op":"create","id":"cost","kind":"stat","props":{"label":"Total","prefix":"¥","value":{"op":"mul","args":[{"ref":"months"},20]}}}',
  '{"seq":3,"op":"patch","id":"cost","props":{"value":{"op":"mul","args":[{"ref":"months"},18]}}}',
  '{"seq":4,"op":"create","id":"g","kind":"grid","props":{"columns":2}}',
  '{"seq":5,"op":"create","id":"h","kind":"heading","parent":"g","props":{"text":"Plan"}}',
  '{"seq":6,"op":"append","id":"h","text":" A"}',
  '{"seq":7,"op":"create","id":"ok","kind":"check","parent":"g","props":{"label":"Ready","default":true}}',
  '{"seq":8,"op":"create","id":"c","kind":"chart","props":{"label":"Sales","variant":"bar","data":[{"label":"Q1","value":3},{"label":"Q2","value":{"ref":"months"}}]}}',
  '{"seq":9,"op":"create","id":"t","kind":"text","parent":"h","props":{"text":"leaf"}}',
  '{"seq":11,"op":"create","id":"gap","kind":"text","props":{"text":"x"}}',
  FENCE,
  'Outro',
].join('\n');

function partSummary(parts: RichPart[]): string {
  return JSON.stringify(parts.map((part: RichPart) => [part.kind, part.key, part.complete, part.source.length]));
}

function richMessage(id: string, role: string, content: string, seconds: number, sealed: boolean = false): RemoteMessage {
  const raw: Record<string, Object> = {};
  raw['id'] = id;
  raw['clientId'] = id;
  raw['sessionId'] = 'rich-session';
  raw['role'] = role;
  raw['content'] = content;
  raw['createdAt'] = new Date(1000000 + seconds * 1000).toISOString();
  if (sealed) raw['turnCompleted'] = true;
  return parseMessage(raw);
}

function richTool(id: string, seconds: number): RemoteMessage {
  const content: Record<string, Object> = {};
  content['toolUseId'] = id;
  content['toolName'] = 'Read';
  content['input'] = JSON.parse('{"file_path":"a.ets"}') as Record<string, Object>;
  const raw: Record<string, Object> = {};
  raw['id'] = id;
  raw['clientId'] = id;
  raw['sessionId'] = 'rich-session';
  raw['role'] = 'tool_use';
  raw['content'] = content;
  raw['createdAt'] = new Date(1000000 + seconds * 1000).toISOString();
  return parseMessage(raw);
}

function rootMessage(items: RenderItem[], id: string): RenderMessageItem | undefined {
  for (let i = 0; i < items.length; i++) {
    if (items[i].type === 'message' && items[i].key === id) return items[i] as RenderMessageItem;
  }
  return undefined;
}

class MemoryStorage implements RichStateStorage {
  value: string = '';
  writes: number = 0;
  read(): Promise<string> {
    return Promise.resolve(this.value);
  }
  write(serialized: string): Promise<void> {
    this.value = serialized;
    this.writes++;
    return Promise.resolve();
  }
}

function values(entries: string): Map<string, RichValue> {
  const out: Map<string, RichValue> = new Map();
  const record = JSON.parse(entries) as Record<string, Object>;
  Object.keys(record).forEach((key: string) => out.set(key, record[key] as RichValue));
  return out;
}

export default function v133RichAnswerTest(): void {
  describe('V133RichAnswer', () => {
    it('splits_only_explicit_answer_fences_like_shared', 0, () => {
      expect(partSummary(splitRichAnswer(ANSWER)))
        .assertEqual('[["markdown",0,true,6],["rich",6,true,978],["markdown",1000,false,5]]');
      // 其它围栏里的 cindy-ui 示例保持为 Markdown 源码。
      const example = '````md\n```cindy-ui\n{"seq":1,"op":"create","id":"a","kind":"text","props":{"text":"x"}}\n```\n````\n';
      expect(JSON.stringify(splitRichAnswer(example).map((part: RichPart) => part.kind))).assertEqual('["markdown"]');
      expect(hasRichAnswer(example)).assertFalse();
      const streaming = 'a\n```cindy-ui\n{"seq":1,"op":"create","id":"a","kind":"text","props":{"text":"x"}}\n';
      expect(JSON.stringify(splitRichAnswer(streaming).map((part: RichPart) => [part.kind, part.key, part.complete])))
        .assertEqual('[["markdown",0,true],["rich",2,false]]');
    });

    it('applies_ops_counts_invalid_lines_and_exports_readable_text', 0, () => {
      const doc = new RichAnswerStream().update(splitRichAnswer(ANSWER)[1].source, true);
      expect(JSON.stringify(doc.roots)).assertEqual('["months","cost","g","c"]');
      // 叶子节点挂子节点、seq 跳号各计一次问题；后者之后不再推进。
      expect(doc.issues).assertEqual(2);
      expect(doc.revision).assertEqual(8);
      expect(JSON.stringify((doc.nodes.get('g') as RichNode).children)).assertEqual('["h","ok"]');
      expect((doc.nodes.get('h') as RichNode).props['text'] as string).assertEqual('Plan A');
      expect(richAnswerText(ANSWER))
        .assertEqual('Intro\n\n\nMonths: 6\n\nTotal: ¥108\n\n### Plan A\n\n☑ Ready\n\nSales\nQ1: 3\nQ2: 6\n\nOutro');
      expect(richAnswerText('plain answer')).assertEqual('plain answer');
    });

    it('moves_rejects_cycles_removes_subtrees_and_normalizes_side_style', 0, () => {
      const doc = new RichAnswerStream().update([
        '{"seq":1,"op":"create","id":"a","kind":"stack"}',
        '{"seq":2,"op":"create","id":"b","kind":"stack","parent":"a"}',
        '{"seq":3,"op":"create","id":"x","kind":"text","parent":"b","props":{"text":"x"}}',
        '{"seq":4,"op":"move","id":"a","parent":"b"}',
        '{"seq":5,"op":"move","id":"x","parent":"root","index":0}',
        '{"seq":6,"op":"remove","id":"b"}',
        '{"seq":6,"op":"remove","id":"a"}',
        '{"seq":7,"op":"create","id":"y","kind":"divider","style":{"marginTop":4,"color":"#f00","background":"red"}}',
      ].join('\n'), true);
      expect(JSON.stringify(doc.roots)).assertEqual('["x","a","y"]');
      expect(doc.issues).assertEqual(1);
      expect(JSON.stringify(Array.from(doc.nodes.keys()))).assertEqual('["a","x","y"]');
      // 背景与任意颜色值都不进入样式；重放的 seq 静默跳过。
      const style = richVisualStyle(doc.nodes.get('y') as RichNode);
      expect(JSON.stringify(Array.from(style.entries()))).assertEqual('[["marginTop",4]]');
    });

    it('streams_incrementally_and_rebuilds_on_snapshot_correction', 0, () => {
      const stream = new RichAnswerStream();
      const first = stream.update('{"seq":1,"op":"create","id":"a","kind":"text","props":{"text":"x"}}\n{"seq":2,"op"');
      expect(first.roots.length).assertEqual(1);
      expect(first.issues).assertEqual(0);
      const second = stream.update('{"seq":1,"op":"create","id":"a","kind":"text","props":{"text":"x"}}\n{"seq":2,"op":"append","id":"a","text":"y"}', true);
      expect((second.nodes.get('a') as RichNode).props['text'] as string).assertEqual('xy');
      // 快照修正（新源码不是旧源码前缀）时整体重建，不残留旧节点。
      const rebuilt = stream.update('{"seq":1,"op":"create","id":"b","kind":"divider"}\n');
      expect(JSON.stringify(rebuilt.roots)).assertEqual('["b"]');
      expect(first.nodes.size).assertEqual(1);
    });

    it('resolves_forward_refs_and_keeps_unavailable_values_unavailable', 0, () => {
      const doc = new RichAnswerStream().update([
        '{"seq":1,"op":"create","id":"r","kind":"stat","props":{"value":{"op":"div","args":[{"ref":"n"},{"ref":"z"}]}}}',
        '{"seq":2,"op":"create","id":"n","kind":"input","props":{"default":"4"}}',
        '{"seq":3,"op":"create","id":"z","kind":"input","props":{"default":""}}',
        '{"seq":4,"op":"create","id":"q","kind":"stat","props":{"value":{"op":"if","args":[{"op":"gt","args":[{"ref":"n"},1]},{"op":"concat","args":["n=",{"ref":"n"}]},{"ref":"missing"}]}}}',
      ].join('\n'), true);
      const resolved = richResolvedValues(doc);
      expect(resolved.get('n') as string).assertEqual('4');
      expect(resolved.has('r')).assertTrue();
      expect(resolved.get('r') === undefined).assertTrue();
      expect(resolved.get('q') as string).assertEqual('n=4');
      const edited = richResolvedValues(doc, values('{"z":"2"}'));
      expect(edited.get('r') as number).assertEqual(2);
    });

    it('computes_line_plot_geometry_like_shared', 0, () => {
      const point = (label: string, value: number): RichChartPoint => {
        const result = new RichChartPoint();
        result.label = label;
        result.value = value;
        return result;
      };
      const data: RichChartPoint[] = [point('Jan', 3), point('Feb', 7), point('Mar', 5)];
      const plot = richLinePlot(data, 320, {});
      expect(plot.left).assertEqual(33);
      expect(plot.min).assertClose(2.6, 0.0001);
      expect(plot.max).assertClose(7.4, 0.0001);
      expect(JSON.stringify(plot.ticks.map((tick: RichPlotTick) => tick.label))).assertEqual('["2.6","4.2","5.8","7.4"]');
      expect(plot.ticks[1].y).assertClose(137.3333, 0.001);
      expect(plot.points[1].x).assertClose(166.5, 0.001);
      expect(plot.points[1].y).assertClose(41.6667, 0.001);
      expect(plot.showValues).assertTrue();
    });

    it('rich_answers_stay_delivery_and_copy_share_as_readable_text', 0, () => {
      const answer = `${FENCE}cindy-ui\n{"version":1,"seq":1,"op":"create","id":"s","kind":"stat","props":{"label":"Total","value":3}}\n${FENCE}`;
      const items = buildRenderItems([
        richMessage('user', 'user', 'Report', 0), richMessage('thought', 'thinking', 'Plan', 1),
        richMessage('rich', 'assistant', answer, 2), richTool('notify', 3),
        richMessage('final', 'assistant', 'Done', 5, true),
      ]);
      // 短小的富组件回答排在收尾动作之前，也不能折进工作过程。
      const rich = rootMessage(items, 'rich') as RenderMessageItem;
      expect(rich !== undefined).assertTrue();
      expect(JSON.stringify(rich.richParts.map((part: RenderRichPart) => [part.kind, String(part.complete)]))).assertEqual('[["rich","true"]]');
      const share = freezeShareProjection([rich], new Set<string>(), 0);
      expect(share.items[0].text).assertEqual('Total: 3');
    });

    it('media_nodes_reuse_markdown_images_and_degrade_video_sites_to_links', 0, () => {
      const node = (kind: string, src: string, alt: string): RichNode => {
        const result = new RichNode();
        result.kind = kind;
        result.props['src'] = src;
        result.props['alt'] = alt;
        return result;
      };
      expect(richMediaMarkdown(node('image', 'cindy-media://blobs/a.png', 'Chart'), 'Open video', 'Open media'))
        .assertEqual('![Chart](cindy-media://blobs/a.png)');
      expect(richMediaMarkdown(node('video', 'https://youtu.be/dQw4w9WgXcQ?t=1m5s', ''), 'Open video', 'Open media'))
        .assertEqual('[Open video](https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=65)');
      expect(richMediaMarkdown(node('image', 'javascript:alert(1)', 'x'), 'Open video', 'Open media')).assertEqual('');
      expect(richYoutubeWatchUrl('https://evil.example/watch?v=dQw4w9WgXcQ')).assertEqual('');
      expect(richYoutubeWatchUrl('https://youtu.be/dQw4w9WgXcQ?t=%'))
        .assertEqual('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    });

    it('shares_only_the_visible_rich_subtree_without_changing_full_copy', 0, () => {
      const answer = [
        FENCE + 'cindy-ui',
        '{"seq":1,"op":"create","id":"details","kind":"details","props":{"label":"More","default":false}}',
        '{"seq":2,"op":"create","id":"secret","kind":"text","parent":"details","props":{"text":"HIDDEN DETAILS"}}',
        '{"seq":3,"op":"create","id":"tabs","kind":"tabs","props":{"label":"Pages","default":"b"}}',
        '{"seq":4,"op":"create","id":"a","kind":"stack","parent":"tabs","props":{"label":"A"}}',
        '{"seq":5,"op":"create","id":"hidden","kind":"text","parent":"a","props":{"text":"HIDDEN TAB"}}',
        '{"seq":6,"op":"create","id":"b","kind":"stack","parent":"tabs","props":{"label":"B"}}',
        '{"seq":7,"op":"create","id":"visible","kind":"text","parent":"b","props":{"text":"VISIBLE"}}',
        FENCE,
      ].join('\n');
      const items = buildRenderItems([richMessage('rich', 'assistant', answer, 0, true)]);
      const projection = freezeShareProjection(items, new Set<string>(), 0);
      expect(projection.items[0].text.includes('HIDDEN')).assertFalse();
      expect(projection.items[0].text.includes('VISIBLE')).assertTrue();
      expect(projection.omittedCollapsedContent).assertTrue();
      expect(richAnswerText(answer).includes('HIDDEN DETAILS')).assertTrue();
      const edited = values('{"details":true,"tabs":"a"}');
      const readKeys: string[] = [];
      const current = freezeShareProjection(items, new Set<string>(), 0, undefined,
        (message: RenderMessageItem, partKey: number): Map<string, RichValue> => {
          readKeys.push(message.key + ':' + partKey);
          return edited;
        });
      expect(JSON.stringify(readKeys)).assertEqual('["rich:0"]');
      expect(current.items[0].text.includes('HIDDEN DETAILS')).assertTrue();
      expect(current.items[0].text.includes('HIDDEN TAB')).assertTrue();
      expect(current.items[0].text.includes('VISIBLE')).assertFalse();
      edited.set('details', false);
      edited.set('tabs', 'b');
      expect(current.items[0].text.includes('HIDDEN DETAILS')).assertTrue();
    });

    it('persists_prototype_named_bindings_without_losing_their_values', 0, async () => {
      const storage = new MemoryStorage();
      const memory = new RichInteractionMemory(storage);
      memory.set('k', values('{"__proto__":"edited\\n\\\"value","constructor":true,"count":2}'));
      await memory.flush();
      const restored = new RichInteractionMemory(storage);
      await restored.load();
      expect(restored.get('k').get('__proto__') as string).assertEqual('edited\n"value');
      expect(restored.get('k').get('constructor') as boolean).assertTrue();
      expect(restored.get('k').get('count') as number).assertEqual(2);
    });

    it('memory_merges_patches_hydrates_without_losing_edits_and_drops_bad_entries', 0, async () => {
      const storage = new MemoryStorage();
      storage.value = '{"version":1,"entries":[["k",{"a":1,"bad key":2,"b":{"x":1}}],["old",{"c":true}]]}';
      const memory = new RichInteractionMemory(storage);
      memory.set('k', values('{"typed":"new"}'));
      await memory.load();
      expect(JSON.stringify(Array.from(memory.get('k').entries()))).assertEqual('[["a",1],["typed","new"]]');
      expect(memory.get('old').get('c') as boolean).assertTrue();
      await memory.flush();
      expect(storage.writes).assertEqual(1);
      expect(parseStoredEntries('{"version":2,"entries":[]}') === null).assertTrue();
    });
  });
}
