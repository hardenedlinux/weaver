import ELK, { type ElkNode, type ElkExtendedEdge } from 'elkjs/lib/elk.bundled.js';
import type { Point, Scene, SceneEdge, SceneNode } from '../source/types';
import { wrapText } from '../scene/font';
import { placeLabels, assertNoVisualCollisions } from './labels';
import { routeFixedBoard } from './routing';
const elk = new ELK();
type Direction = 'RIGHT' | 'DOWN';
interface Box { id: string; width: number; height: number; direction: Direction; children: { box: Box; x: number; y: number }[]; routes: Map<string, Point[]>; }
interface Guide { points: Point[]; source: string; target: string; direction: Direction; }
const rootId = '\u0000weaver-layout';

export async function layoutScene(source: Scene): Promise<Scene> {
  if (source.view.kind === 'sequence') return finishScene(sequenceLayout(source));
  const active = source.nodes.filter(node => !node.annotation);
  if (active.length && active.every(node => !node.parent && !node.group && node.positionHint)) {
    const columns = [...new Set(active.map(node => node.positionHint!.x))].sort((a,b)=>a-b);
    const rows = [...new Set(active.map(node => node.positionHint!.y))].sort((a,b)=>a-b);
    const cells = new Set(active.map(node=>`${node.positionHint!.x},${node.positionHint!.y}`));
    if (cells.size === active.length) {
      const columnWidths = columns.map(x=>Math.max(...active.filter(node=>node.positionHint!.x===x).map(node=>node.width)));
      const rowHeights = rows.map(y=>Math.max(...active.filter(node=>node.positionHint!.y===y).map(node=>node.height)));
      const nodes = source.nodes.map(node=>node.annotation?node:{...node,
        x:38+columnWidths.slice(0,columns.indexOf(node.positionHint!.x)).reduce((sum,width)=>sum+width+164,0),
        y:100+rowHeights.slice(0,rows.indexOf(node.positionHint!.y)).reduce((sum,height)=>sum+height+112,0),
      });
      return finishScene({...source,nodes,edges:routeFixedBoard(nodes,source.edges),width:Math.max(...nodes.filter(node=>!node.annotation).map(node=>node.x+node.width))+38,height:0});
    }
  }
  const byId = new Map(active.map(node => [node.id, node]));
  const rootDirection: Direction = ['routing', 'data', 'assurance'].includes(source.view.kind) ? 'DOWN' : 'RIGHT';
  const childOf = (id: string, owner: string): string | undefined => {
    let node = byId.get(id);
    while (node && (node.parent ?? rootId) !== owner) node = node.parent ? byId.get(node.parent) : undefined;
    return node?.id;
  };
  const edgeScopes = new Map<string, { source: string; target: string }>();
  async function pack(owner: string): Promise<Box> {
    const nodes = active.filter(node => (node.parent ?? rootId) === owner);
    const direction: Direction = owner === rootId ? rootDirection : byId.get(owner)?.layoutDirection ?? (['routing', 'data'].includes(source.view.kind) ? 'RIGHT' : 'DOWN');
    const entries = await Promise.all(nodes.map(async node => {
      const children = active.filter(child => child.parent === node.id);
      return children.length ? pack(node.id) : { id: node.id, width: node.width, height: node.height, direction, children: [], routes: new Map<string, Point[]>() } satisfies Box;
    }));
    const scoped = source.edges.flatMap(edge => {
      const from = childOf(edge.source, owner), to = childOf(edge.target, owner);
      if (!from || !to || from === to) return [];
      edgeScopes.set(edge.id, { source: from, target: to });
      return [{ ...edge, source: from, target: to }];
    });
    // Trace mappings do not impose a causal order between independent proof lanes.
    const ranking = scoped.filter(edge => !(source.view.kind === 'assurance' && edge.dashed));
    const padX = owner === rootId ? 0 : 26, padY = owner === rootId ? 0 : 66;
    const routes = new Map<string, Point[]>();
    if (!ranking.length) {
      let cursor = 0;
      const children = entries.map(box => {
        const position = { box, x: padX + (direction === 'RIGHT' ? cursor : 0), y: padY + (direction === 'DOWN' ? cursor : 0) };
        cursor += (direction === 'RIGHT' ? box.width : box.height) + 34;
        return position;
      });
      return {
        id: owner, direction, children, routes,
        width: (direction === 'RIGHT' ? Math.max(0, cursor - 34) : Math.max(...entries.map(box => box.width), 0)) + padX * 2,
        height: (direction === 'DOWN' ? Math.max(0, cursor - 34) : Math.max(...entries.map(box => box.height), 0)) + padY + (owner === rootId ? 0 : 28),
      };
    }
    const graph: ElkNode = await elk.layout({
      id: rootId, layoutOptions: {
        'elk.algorithm': 'layered', 'elk.direction': direction, 'elk.edgeRouting': 'ORTHOGONAL',
        'elk.spacing.nodeNode': owner === rootId ? '56' : '34',
        'elk.layered.spacing.nodeNodeBetweenLayers': owner === rootId ? '156' : direction === 'RIGHT' ? '204' : '98',
        'elk.spacing.edgeNode': '28', 'elk.padding': '[top=0,left=0,bottom=0,right=0]',
        'elk.layered.considerModelOrder.strategy': 'NODES_AND_EDGES', 'elk.randomSeed': '1',
      },
      children: entries.map(box => ({ id: box.id, width: box.width, height: box.height })),
      edges: ranking.map(edge => ({ id: edge.id, sources: [edge.source], targets: [edge.target] })),
    });
    const positions = new Map((graph.children ?? []).map(node => [node.id, node]));
    for (const edge of graph.edges ?? []) {
      const points = (edge as ElkExtendedEdge).sections?.flatMap(section => [section.startPoint, ...(section.bendPoints ?? []), section.endPoint]) ?? [];
      routes.set(edge.id, points.map(point => ({ x: point.x + padX, y: point.y + padY })));
    }
    return {
      id: owner, direction, routes, width: (graph.width ?? 0) + padX * 2, height: (graph.height ?? 0) + padY + (owner === rootId ? 0 : 28),
      children: entries.map(box => {
        const position = positions.get(box.id);
        if (!position) throw new Error('Layout lost a source node: ' + box.id);
        return { box, x: (position.x ?? 0) + padX, y: (position.y ?? 0) + padY };
      }),
    };
  }
  const root = await pack(rootId);
  const positions = new Map<string, { x: number; y: number; width: number; height: number }>();
  const directions = new Map<string, Direction>();
  const guides = new Map<string, Guide>();
  function place(box: Box, x: number, y: number) {
    directions.set(box.id, box.direction);
    if (box.id !== rootId) positions.set(box.id, { x, y, width: box.width, height: box.height });
    for (const [id, points] of box.routes) {
      const scope = edgeScopes.get(id);
      if (!scope) throw new Error('Edge has no source scope: ' + id);
      guides.set(id, { ...scope, direction: box.direction, points: points.map(point => ({ x: point.x + x, y: point.y + y })) });
    }
    for (const child of box.children) place(child.box, x + child.x, y + child.y);
  }
  place(root, 38, 100);
  const nodes = source.nodes.map(node => node.annotation ? node : { ...node, ...positions.get(node.id) });
  const mapped = new Map(nodes.map(node => [node.id, node]));
  function adapt(edge: SceneEdge): Point[] {
    const start = mapped.get(edge.source), end = mapped.get(edge.target);
    if (!start || !end) throw new Error('Edge endpoint disappeared: ' + edge.id);
    const guide = guides.get(edge.id);
    if (!guide) {
      if (start.id === end.id) {
        const x = start.x + start.width, y = start.y + start.height / 2;
        return [{ x, y: y - 16 }, { x: x + 70, y: y - 16 }, { x: x + 70, y: y + 16 }, { x, y: y + 16 }];
      }
      const x1 = start.x + start.width, y1 = start.y + start.height / 2;
      const x2 = end.x, y2 = end.y + end.height / 2;
      const middle = (x1 + x2) / 2;
      return [{ x: x1, y: y1 }, { x: middle, y: y1 }, { x: middle, y: y2 }, { x: x2, y: y2 }];
    }
    const points = [...guide.points];
    if (!points.length) throw new Error('Layout omitted an edge route: ' + edge.id);
    const first = points[0]!, last = points[points.length - 1]!;
    if (guide.source !== edge.source) {
      const owner = positions.get(guide.source)!;
      const lane = 8 + (source.edges.indexOf(edge) % 4) * 4;
      if (guide.direction === 'DOWN' && directions.get(guide.source) === 'DOWN') {
        const port = { x: start.x + start.width, y: start.y + start.height / 2 };
        const side = owner.x + owner.width - lane;
        points.unshift(port, { x: side, y: port.y }, { x: side, y: first.y });
      } else if (guide.direction === 'RIGHT' && directions.get(guide.source) === 'RIGHT') {
        const port = { x: start.x + start.width / 2, y: start.y + start.height };
        const side = owner.y + owner.height - lane;
        points.unshift(port, { x: port.x, y: side }, { x: first.x, y: side });
      } else {
        const port = guide.direction === 'DOWN' ? { x: start.x + start.width / 2, y: start.y + start.height } : { x: start.x + start.width, y: start.y + start.height / 2 };
        const elbow = guide.direction === 'DOWN' ? { x: port.x, y: first.y } : { x: first.x, y: port.y };
        points.unshift(port, elbow);
      }
    }
    if (guide.target !== edge.target) {
      const owner = positions.get(guide.target)!;
      const lane = 8 + (source.edges.indexOf(edge) % 4) * 4;
      if (guide.direction === 'DOWN' && directions.get(guide.target) === 'DOWN') {
        const port = { x: end.x, y: end.y + end.height / 2 };
        const side = owner.x + lane;
        points.push({ x: side, y: last.y }, { x: side, y: port.y }, port);
      } else if (guide.direction === 'RIGHT' && directions.get(guide.target) === 'RIGHT') {
        const port = { x: end.x + end.width / 2, y: end.y + end.height };
        const side = owner.y + owner.height - lane;
        points.push({ x: last.x, y: side }, { x: port.x, y: side }, port);
      } else {
        const port = guide.direction === 'DOWN' ? { x: end.x + end.width / 2, y: end.y } : { x: end.x, y: end.y + end.height / 2 };
        const elbow = guide.direction === 'DOWN' ? { x: port.x, y: last.y } : { x: last.x, y: port.y };
        points.push(elbow, port);
      }
    }
    return points;
  }
  return finishScene({ ...source, nodes, edges: source.edges.map(edge => ({ ...edge, points: adapt(edge) })), width: root.width + 76, height: root.height + 180 });
}

function finishScene(scene: Scene): Scene {
  scene = placeLabels(scene);
  assertNoVisualCollisions(scene);
  const width = Math.max(scene.width, ...scene.edges.flatMap(edge => edge.points.map(point => point.x + 48)), 820);
  const bottom = Math.max(...scene.nodes.filter(node => !node.annotation).map(node => node.y + node.height), ...scene.edges.flatMap(edge => [...edge.points.map(point => point.y), edge.labelBox ? edge.labelBox.y + edge.labelBox.height : 0]), 200);
  const notes = scene.nodes.filter(node => node.annotation && node.shape !== 'image' && node.id !== 'title').flatMap(node => wrapText(node.label, width - 112, 11, 100));
  const footerTop = bottom + 38;
  return { ...scene, width, height: footerTop + (notes.length ? 42 + notes.length * 16 : 0) + 58, notes, footerTop };
}
function sequenceLayout(source: Scene): Scene {
  const actors = source.nodes.filter(node => !node.annotation && !node.parent);
  const indexes = new Map(actors.map((actor, index) => [actor.id, index]));
  const actorId = (id: string): string => {
    if (indexes.has(id)) return id;
    const parent = actors.find(actor => id.startsWith(actor.id + '.'));
    if (!parent) throw new Error('Sequence has no actor: ' + id);
    return parent.id;
  };
  const nodes = source.nodes.map(node => indexes.has(node.id)
    ? { ...node, group: false, x: 46 + (indexes.get(node.id) ?? 0) * 312, y: 100, width: 272, height: 148 }
    : { ...node, annotation: true });
  const edges = source.edges.map((edge, index) => {
    const x1 = 182 + (indexes.get(actorId(edge.source)) ?? 0) * 312;
    const x2 = 182 + (indexes.get(actorId(edge.target)) ?? 0) * 312;
    const y = 286 + index * 82;
    return { ...edge, points: x1 === x2 ? [{ x: x1, y }, { x: x1 + 64, y }, { x: x1 + 64, y: y + 28 }, { x: x1, y: y + 28 }] : [{ x: x1, y }, { x: x2, y }] };
  });
  return { ...source, nodes, edges, width: actors.length * 312 + 64, height: 330 + edges.length * 82 };
}
