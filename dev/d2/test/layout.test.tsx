import { describe, test, expect } from 'bun:test';
import fc from 'fast-check';
import { renderToStaticMarkup } from 'react-dom/server';
import { layoutScene } from '../src/graph/layout';
import { assertNoVisualCollisions } from '../src/graph/labels';
import { ArchitectureImage } from '../src/scene/Scene';
import { textWidth, wrapText } from '../src/scene/font';
import type { Scene, SceneNode, ViewKind } from '../src/source/types';

function fixture(count: number, kind: ViewKind): Scene {
  const node = (id: string, parent?: string): SceneNode => ({ id, label: id, title: id, details: [], shape: 'rectangle', role: 'runtime', parent, group: !parent, annotation: false, fields: [], x: 0, y: 0, width: 272, height: 148, layoutDirection: parent ? undefined : 'DOWN' });
  const nodes = [node('a'), node('b'), ...Array.from({ length: count }, (_, i) => node(`a.n${i}`, 'a')), ...Array.from({ length: count }, (_, i) => node(`b.n${i}`, 'b'))];
  const pairs: [string, string][] = [];
  for (let i = 1; i < count; i++) { pairs.push([`a.n${i - 1}`, `a.n${i}`], [`b.n${i - 1}`, `b.n${i}`]); }
  for (let i = 0; i < count; i++) pairs.push([`a.n${i}`, `b.n${i}`]);
  return { view: { id: 'fixture', source: 'fixture.d2', title: 'Source-bound graph', kind, sha256: 'a'.repeat(64) }, nodes,
    edges: pairs.map(([source, target], index) => ({ id: `edge-${index}`, source, target, label: 'Preserve original scope', dashed: index % 2 === 0, sourceArrow: false, targetArrow: true, points: [] })), width: 0, height: 0 };
}

describe('measured architecture graphics', () => {
  test('property: labels wrap within actual font metrics', () => {
    const text = fc.array(fc.constantFrom(...'Abcdefghijk WXYZ0123456789 <>"&/'), { maxLength: 220 }).map(chars => chars.join(''));
    fc.assert(fc.property(text, fc.integer({ min: 38, max: 400 }), fc.integer({ min: 9, max: 20 }), (label, width, size) => {
      const lines = wrapText(label, width, size, 3);
      expect(lines.length).toBeLessThanOrEqual(3);
      for (const line of lines) expect(textWidth(line, size)).toBeLessThanOrEqual(width + .001);
    }), { numRuns: 1000, seed: 293 });
  });

  test('property: nested layout preserves identities and separates nodes and labels', async () => {
    await fc.assert(fc.asyncProperty(fc.integer({ min: 1, max: 4 }), fc.constantFrom<ViewKind>('system', 'routing', 'flow', 'state', 'data', 'assurance'), async (count, kind) => {
      const source = fixture(count, kind);
      const image = await layoutScene(source);
      expect(image.nodes.map(node => node.id)).toEqual(source.nodes.map(node => node.id));
      expect(image.edges.map(edge => [edge.id, edge.source, edge.target, edge.label])).toEqual(source.edges.map(edge => [edge.id, edge.source, edge.target, edge.label]));
      assertNoVisualCollisions(image);
      for (const edge of image.edges) for (const point of edge.points) { expect(Number.isFinite(point.x) && Number.isFinite(point.y)).toBe(true); }
    }), { numRuns: 64, seed: 293 });
  });

  test('regression: inner edge coordinates stay inside their source container', async () => {
    const scene = await layoutScene(fixture(3, 'routing'));
    const box = scene.nodes.find(node => node.id === 'a')!;
    const inner = scene.edges.find(edge => edge.source === 'a.n0' && edge.target === 'a.n1')!;
    for (const point of inner.points) {
      expect(point.x).toBeGreaterThanOrEqual(box.x);
      expect(point.y).toBeGreaterThanOrEqual(box.y + 56);
      expect(point.x).toBeLessThanOrEqual(box.x + box.width);
      expect(point.y).toBeLessThanOrEqual(box.y + box.height);
    }
  });

  test('property: portable SVG retains every source node and edge without HTML', async () => {
    await fc.assert(fc.asyncProperty(fc.integer({ min: 1, max: 3 }), fc.constantFrom<ViewKind>('flow', 'state', 'data', 'assurance'), async (count, kind) => {
      const source = fixture(count, kind);
      source.nodes[2]!.label = '<script>untrusted source label</script>';
      const scene = await layoutScene(source);
      const svg = renderToStaticMarkup(<ArchitectureImage scene={scene} brands={{}}/>);
      expect((svg.match(/<g data-source-node=/g) ?? []).length).toBe(source.nodes.length);
      expect((svg.match(/<g data-source-edge=/g) ?? []).length).toBe(source.edges.length);
      expect(svg).not.toContain('<script>');
      expect(svg).not.toContain('<foreignObject');
      expect(svg).not.toContain('<iframe');
      expect(svg).toContain('&lt;script&gt;');
    }), { numRuns: 24, seed: 293 });
  });

  test('sequence preserves original message order and self messages', async () => {
    const source = fixture(2, 'sequence');
    const scene = await layoutScene(source);
    expect(scene.edges.map(edge => edge.id)).toEqual(source.edges.map(edge => edge.id));
    scene.edges.forEach((edge, index) => expect(edge.points[0]!.y).toBe(286 + index * 82));
  });
});

test('explicit boards preserve original ranks without routes through other cards', async () => {
  const source = fixture(3, 'system');
  source.nodes = source.nodes.filter(node => !node.group).map((node,index) => ({ ...node, parent: undefined, positionHint: { x: index % 3 * 750, y: Math.floor(index / 3) * 470 } }));
  source.edges = [{id:'diagonal',source:source.nodes[0]!.id,target:source.nodes[5]!.id,label:'Original contract',dashed:false,sourceArrow:false,targetArrow:true,points:[]}];
  const scene = await layoutScene(source);
  expect(scene.nodes[0]!.x).toBeLessThan(scene.nodes[1]!.x);
  expect(scene.nodes[0]!.y).toBe(scene.nodes[2]!.y);
  expect(scene.nodes[3]!.y).toBeGreaterThan(scene.nodes[0]!.y);
  for (const edge of scene.edges) for (let i=1;i<edge.points.length;i++) {
    const a=edge.points[i-1]!,b=edge.points[i]!;
    for (const node of scene.nodes.filter(node=>node.id!==edge.source&&node.id!==edge.target)) {
      const crosses = a.x===b.x ? a.x>node.x&&a.x<node.x+node.width&&Math.max(a.y,b.y)>node.y&&Math.min(a.y,b.y)<node.y+node.height : a.y>node.y&&a.y<node.y+node.height&&Math.max(a.x,b.x)>node.x&&Math.min(a.x,b.x)<node.x+node.width;
      expect(crosses).toBe(false);
    }
  }
});

test('sequence messages meet actual actor centers after header resizing', async () => {
  const source = fixture(3, 'sequence');
  const scene = await layoutScene(source);
  const center = (id: string) => { const actor=scene.nodes.find(node=>!node.annotation&&(id===node.id||id.startsWith(node.id+'.')))!;return actor.x+actor.width/2; };
  for (const edge of scene.edges) {
    expect(edge.points[0]!.x).toBe(center(edge.source));
    expect(edge.points.at(-1)!.x).toBe(center(edge.target));
  }
  expect(scene.width).toBeGreaterThan(Math.max(...scene.nodes.filter(node=>!node.annotation).map(node=>node.x+node.width)));
});
