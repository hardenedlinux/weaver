import { D2, type Diagram, type Shape, type Connection, type Graph } from '@terrastruct/d2';
import type { Role, Scene, SceneNode, SourceCatalog, ViewEntry } from './types';
const roles: readonly Role[] = ['semantic', 'cloud', 'runtime', 'policy', 'ledger', 'verified', 'unknown', 'deny', 'note'];

function labelOf(shape: Shape): string {
  return ('label' in shape && typeof shape.label === 'string' ? shape.label : shape.id).replaceAll('\\n', '\n');
}
export function localIcon(value: unknown): string | undefined {
  if (typeof value === 'string') return value;
  if (value && typeof value === 'object' && 'Path' in value && typeof value.Path === 'string') return value.Path;
  return undefined;
}
export function generatedLifeline(edge: Pick<Connection, 'id' | 'src' | 'dst' | 'label' | 'strokeDash' | 'srcArrow' | 'dstArrow'>, ids: Set<string>, kind: ViewEntry['kind']): boolean {
  return kind === 'sequence' && ids.has(edge.src) && !ids.has(edge.dst) && edge.dst.startsWith(`${edge.src}-lifeline-end-`) &&
    /^\d+$/.test(edge.dst.slice(`${edge.src}-lifeline-end-`.length)) && edge.id === `(${edge.src} -- )[0]` &&
    edge.strokeDash === 6 && !edge.label && edge.srcArrow === 'none' && edge.dstArrow === 'none';
}
export function visualRole(id: string, label: string, classes: string[] = []): Role {
  const explicit = classes.find(value => roles.some(role => role === value));
  if (explicit) return explicit as Role;
  const text = `${id} ${label}`.toLowerCase();
  if (/unknown|uncertain|pending/.test(text)) return 'unknown';
  if (/deny|reject|abort|quarantine/.test(text)) return 'deny';
  if (/scheme|governor|semantic/.test(text)) return 'semantic';
  if (/cedar|policy|authoriz/.test(text)) return 'policy';
  if (/ledger|budget|claim|persist|commit|account|reservation|retained|checkpoint|spent/.test(text)) return 'ledger';
  if (/\bgo\b|kubernetes|cloud|provider/.test(text)) return 'cloud';
  return 'runtime';
}
function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}
function coordinate(value: unknown): number | undefined {
  const text = record(value)?.value;
  if (typeof text !== 'string' || !text.trim()) return undefined;
  const result = Number(text);
  return Number.isFinite(result) ? result : undefined;
}
export function sourceScene(diagram: Diagram, view: ViewEntry, graph?: Graph): Scene {
  const hints = new Map<string, { x: number; y: number }>();
  for (const value of graph?.objects ?? []) {
    const object = record(value), attributes = record(object?.attributes);
    const x = coordinate(attributes?.left), y = coordinate(attributes?.top);
    if (typeof object?.id === 'string' && x !== undefined && y !== undefined) hints.set(object.id, { x, y });
  }
  const ids = new Set(diagram.shapes.map(shape => shape.id));
  if (ids.size !== diagram.shapes.length) throw new Error('D2 returned duplicate node identities');
  const decorations = diagram.connections.filter(edge => generatedLifeline(edge, ids, view.kind));
  const connections = diagram.connections.filter(edge => !decorations.includes(edge));
  const connected = new Set(connections.flatMap(edge => [edge.src, edge.dst]));
  const nodes: SceneNode[] = diagram.shapes.map(shape => {
    const label = labelOf(shape);
    const lines = label.split('\n').map(line => line.trim()).filter(Boolean);
    const parent = [...ids].filter(id => shape.id.startsWith(`${id}.`)).sort((a, b) => b.length - a.length)[0];
    const group = [...ids].some(id => id.startsWith(`${shape.id}.`));
    const fields = 'columns' in shape && Array.isArray(shape.columns) ? shape.columns.map(column => ({ name: column.name.label, value: column.type.label })) : [];
    const note = (shape.classes ?? []).includes('note') || /^(QUINT|LEAN)(?:\s|\/)/.test(label);
    const annotation = (shape.type === 'text' || shape.type === 'image' || note) && !connected.has(shape.id) && !group;
    return {
      id: shape.id, label, title: lines[0] ?? shape.id, details: lines.slice(1), shape: shape.type,
      role: visualRole(shape.id, label, shape.classes ?? []), parent, group, annotation, fields, icon: localIcon(shape.icon),
      layoutDirection: shape.classes?.includes('column') ? 'DOWN' : shape.classes?.includes('row') ? 'RIGHT' : undefined,
      positionHint: hints.get(shape.id),
      x: shape.pos.x, y: shape.pos.y, width: fields.length ? 324 : (view.kind === 'state' ? 236 : 272),
      height: fields.length ? 56 + fields.length * 28 : (view.kind === 'state' ? 100 : 148),
    };
  });
  const resolve = (id: string): string => {
    if (ids.has(id)) return id;
    const owner = [...ids].filter(parent => id.startsWith(`${parent}.`)).sort((a, b) => b.length - a.length)[0];
    if (!owner) throw new Error(`Unknown D2 edge endpoint: ${id}`);
    return owner;
  };
  const edges = connections.map(edge => ({
    id: edge.id, source: resolve(edge.src), target: resolve(edge.dst), label: edge.label.replaceAll('\\n', '\n'),
    dashed: edge.strokeDash > 0, sourceArrow: Boolean(edge.srcArrow && edge.srcArrow !== 'none'), targetArrow: Boolean(edge.dstArrow && edge.dstArrow !== 'none'), points: [],
  }));
  if (new Set(edges.map(edge => edge.id)).size !== edges.length) throw new Error('D2 returned duplicate edge identities');
  return { view, nodes, edges, width: 0, height: 0, generatedDecorations: decorations.map(edge => ({ id: edge.id, actor: edge.src })) };
}

/** One public D2 worker; serialized compilation avoids overlapping WASM mutation. */
export class SourceCompiler {
  private readonly engine = new D2();
  private queue: Promise<void> = Promise.resolve();
  constructor(private readonly catalog: SourceCatalog) {}
  compile(view: ViewEntry): Promise<Scene> {
    const result = this.queue.then(async () => {
      const compiled = await this.engine.compile({ fs: this.catalog.fs, inputPath: view.source, options: { layout: 'elk' } });
      return sourceScene(compiled.diagram, view, compiled.graph);
    });
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }
}
