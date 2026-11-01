import type { Point, Scene, SceneEdge } from '../source/types';
import { textWidth, wrapText } from '../scene/font';
export interface Rectangle { x: number; y: number; width: number; height: number; }
export function overlaps(a: Rectangle, b: Rectangle, margin = 0): boolean {
  return a.x < b.x + b.width + margin && a.x + a.width + margin > b.x && a.y < b.y + b.height + margin && a.y + a.height + margin > b.y;
}

/** Labels have measured geometry. Failed inline placement becomes an explicit side callout. */
export function placeLabels(scene: Scene): Scene {
  const obstacles = scene.nodes.filter(node => !node.annotation).map(node => ({ x: node.x, y: node.y, width: node.width, height: node.group ? 56 : node.height }));
  const occupied: Rectangle[] = [];
  let sideY = 110;
  let width = scene.width;
  const edges = scene.edges.map((edge): SceneEdge => {
    if (!edge.label.trim()) return edge;
    const lines = wrapText(edge.label, scene.view.kind === 'sequence' ? 330 : 156, 10.5, 3);
    const w = Math.max(...lines.map(line => textWidth(line, 10.5)), 0) + 18;
    const h = lines.length * 14 + 12;
    const segments = edge.points.slice(1).map((b, index) => {
      const a = edge.points[index]!;
      return { a, b, length: Math.hypot(b.x - a.x, b.y - a.y) };
    }).sort((a, b) => b.length - a.length);
    for (const segment of segments) for (const fraction of [.5, .25, .75, .1, .9]) for (const below of [false, true]) {
      const point = { x: segment.a.x + (segment.b.x - segment.a.x) * fraction, y: segment.a.y + (segment.b.y - segment.a.y) * fraction };
      const box = { x: point.x - w / 2, y: below ? point.y + 7 : point.y - h - 7, width: w, height: h };
      if (box.x < 24 || box.x + w > scene.width - 24 || box.y < 82) continue;
      if (obstacles.some(node => overlaps(box, node, 7)) || occupied.some(label => overlaps(box, label, 6))) continue;
      occupied.push(box);
      return { ...edge, labelBox: { ...box, lines } };
    }
    const segment = segments[0];
    const origin: Point = segment ? { x: (segment.a.x + segment.b.x) / 2, y: (segment.a.y + segment.b.y) / 2 } : { x: 30, y: 100 };
    const box = { x: scene.width + 24, y: sideY, width: w, height: h };
    sideY += h + 18;
    width = Math.max(width, box.x + w + 30);
    return { ...edge, labelBox: { ...box, lines, leader: [origin, { x: box.x - 12, y: origin.y }, { x: box.x - 12, y: box.y + h / 2 }, { x: box.x, y: box.y + h / 2 }] } };
  });
  return { ...scene, edges, width, height: Math.max(scene.height, sideY + 58) };
}

export function assertNoVisualCollisions(scene: Scene): void {
  const leaves = scene.nodes.filter(node => !node.annotation && !node.group);
  for (let i = 0; i < leaves.length; i++) for (let j = i + 1; j < leaves.length; j++) {
    if (overlaps(leaves[i]!, leaves[j]!)) throw new Error(`Overlapping source nodes: ${leaves[i]!.id} / ${leaves[j]!.id}`);
  }
  const boxes = scene.edges.flatMap(edge => edge.labelBox ? [{ id: edge.id, ...edge.labelBox }] : []);
  for (const box of boxes) {
    for (const node of scene.nodes.filter(node => !node.annotation)) {
      if (overlaps(box, { ...node, height: node.group ? 56 : node.height })) throw new Error(`Edge label overlaps node: ${box.id} / ${node.id}`);
    }
  }
  for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
    if (overlaps(boxes[i]!, boxes[j]!)) throw new Error(`Edge labels overlap: ${boxes[i]!.id} / ${boxes[j]!.id}`);
  }
}
