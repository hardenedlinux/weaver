import type { Point, SceneEdge, SceneNode } from '../source/types';

function intersects(a: Point, b: Point, node: SceneNode, padding = 7): boolean {
  const left = node.x - padding, right = node.x + node.width + padding;
  const top = node.y - padding, bottom = node.y + node.height + padding;
  return Math.abs(a.x - b.x) < .01
    ? a.x > left && a.x < right && Math.max(a.y, b.y) > top && Math.min(a.y, b.y) < bottom
    : a.y > top && a.y < bottom && Math.max(a.x, b.x) > left && Math.min(a.x, b.x) < right;
}
type Side = 'left' | 'right' | 'top' | 'bottom';
function port(node: SceneNode, side: Side, distance = 0): Point {
  return side === 'left' ? { x: node.x - distance, y: node.y + node.height / 2 }
    : side === 'right' ? { x: node.x + node.width + distance, y: node.y + node.height / 2 }
    : side === 'top' ? { x: node.x + node.width / 2, y: node.y - distance }
    : { x: node.x + node.width / 2, y: node.y + node.height + distance };
}

/** Visibility-grid routing honors explicit D2 board positions without drawing through cards. */
export function routeFixedBoard(nodes: SceneNode[], edges: SceneEdge[]): SceneEdge[] {
  const boxes = nodes.filter(node => !node.annotation);
  const map = new Map(boxes.map(node => [node.id, node]));
  const xs = [...new Set(boxes.flatMap(node => [node.x - 20, node.x + node.width / 2, node.x + node.width + 20]))].sort((a,b) => a-b);
  const ys = [...new Set(boxes.flatMap(node => [node.y - 20, node.y + node.height / 2, node.y + node.height + 20]))].sort((a,b) => a-b);
  return edges.map(edge => {
    const source = map.get(edge.source), target = map.get(edge.target);
    if (!source || !target) throw new Error('Fixed board edge has no node: ' + edge.id);
    if (source === target) {
      const x = source.x + source.width, y = source.y + source.height / 2;
      return { ...edge, points: [{x,y:y-20},{x:x+54,y:y-20},{x:x+54,y:y+20},{x,y:y+20}] };
    }
    const dx = target.x - source.x, dy = target.y - source.y;
    const horizontal = Math.abs(dx) > Math.abs(dy);
    const from: Side = horizontal ? (dx >= 0 ? 'right' : 'left') : (dy >= 0 ? 'bottom' : 'top');
    const to: Side = from === 'right' ? 'left' : from === 'left' ? 'right' : from === 'top' ? 'bottom' : 'top';
    const start = port(source, from, 20), end = port(target, to, 20);
    const startX = xs.indexOf(start.x), startY = ys.indexOf(start.y), endX = xs.indexOf(end.x), endY = ys.indexOf(end.y);
    const startKey = `${startX},${startY},-1`;
    const costs = new Map([[startKey,0]]), previous = new Map<string,string>();
    const states = new Map([[startKey,{x:startX,y:startY,d:-1}]]);
    const open = [{key:startKey,score:Math.abs(start.x-end.x)+Math.abs(start.y-end.y)}];
    let found: string | undefined;
    while (open.length) {
      open.sort((a,b)=>b.score-a.score);
      const current = open.pop()!;
      const state = states.get(current.key)!;
      if (state.x === endX && state.y === endY) { found = current.key; break; }
      for (const [nx,ny,direction] of [[state.x-1,state.y,0],[state.x+1,state.y,0],[state.x,state.y-1,1],[state.x,state.y+1,1]] as [number,number,number][]) {
        if (nx<0 || ny<0 || nx>=xs.length || ny>=ys.length) continue;
        const a = {x:xs[state.x]!,y:ys[state.y]!}, b = {x:xs[nx]!,y:ys[ny]!};
        if (boxes.some(box=>intersects(a,b,box))) continue;
        const key = `${nx},${ny},${direction}`;
        const cost = costs.get(current.key)! + Math.abs(a.x-b.x)+Math.abs(a.y-b.y)+(state.d>=0&&state.d!==direction?24:0);
        if (cost >= (costs.get(key) ?? Infinity)) continue;
        costs.set(key,cost);previous.set(key,current.key);states.set(key,{x:nx,y:ny,d:direction});
        open.push({key,score:cost+Math.abs(b.x-end.x)+Math.abs(b.y-end.y)});
      }
    }
    if (!found) throw new Error('No non-overlapping route: ' + edge.id);
    const path: Point[] = [];
    for (let key: string | undefined = found; key; key = previous.get(key)) { const state=states.get(key)!;path.push({x:xs[state.x]!,y:ys[state.y]!}); }
    path.reverse();
    const points = [port(source,from),...path,port(target,to)];
    return { ...edge, points: points.filter((point,index)=> index===0 || index===points.length-1 || !((points[index-1]!.x===point.x&&point.x===points[index+1]!.x)||(points[index-1]!.y===point.y&&point.y===points[index+1]!.y))) };
  });
}
