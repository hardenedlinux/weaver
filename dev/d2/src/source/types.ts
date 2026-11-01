export const viewKinds = ['system', 'routing', 'flow', 'sequence', 'state', 'data', 'assurance'] as const;
export type ViewKind = typeof viewKinds[number];
export function isViewKind(value: string): value is ViewKind { return viewKinds.some(kind => kind === value); }
export interface ViewEntry { id: string; source: string; title: string; kind: ViewKind; sha256: string; }
export interface SourceCatalog { views: ViewEntry[]; fs: Record<string, string>; brands: Record<string, string>; }
export interface Point { x: number; y: number; }
export type Role = 'semantic' | 'cloud' | 'runtime' | 'policy' | 'ledger' | 'verified' | 'unknown' | 'deny' | 'note';
export interface Field { name: string; value: string; }
export interface SceneNode {
  id: string; label: string; title: string; details: string[]; shape: string; role: Role;
  parent?: string; group: boolean; annotation: boolean; fields: Field[]; icon?: string;
  layoutDirection?: 'RIGHT' | 'DOWN';
  positionHint?: Point;
  x: number; y: number; width: number; height: number;
}
export interface SceneEdge {
  id: string; source: string; target: string; label: string; dashed: boolean;
  sourceArrow: boolean; targetArrow: boolean; points: Point[];
  labelBox?: { x: number; y: number; width: number; height: number; lines: string[]; leader?: Point[] };
}
export interface Scene { view: ViewEntry; nodes: SceneNode[]; edges: SceneEdge[]; width: number; height: number; notes?: string[]; footerTop?: number; generatedDecorations?: { id: string; actor: string }[]; }
