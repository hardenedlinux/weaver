import type { ComponentType } from 'react';
import { Cloud, Cpu, Database, ShieldCheck, KeyRound, Route, GitBranch, Workflow, Layers, Sigma, FileText, CircleHelp, AlertTriangle, Check, Code, Lambda, type LucideProps } from 'lucide-react';
import type { Point, Role, Scene, SceneEdge, SceneNode, SourceCatalog } from '../source/types';
import { Lettering, wrapText } from './font';

import { palettes, themes } from '../../themes/presentation';

function nodeIcon(node: SceneNode): ComponentType<LucideProps> {
  if (node.role === 'unknown' || node.role === 'deny') return palettes[node.role].icon;
  if (node.fields.length) return Database;
  if (/claim|nonce|grant|custody|key/i.test(`${node.id} ${node.title}`)) return KeyRound;
  if (/route|model|provider/i.test(node.title)) return Route;
  if (/quint/i.test(node.title)) return GitBranch;
  if (/lean|proof|invariant/i.test(node.title)) return Sigma;
  return palettes[node.role].icon;
}
function brand(node: SceneNode, brands: SourceCatalog['brands']): string | undefined {
  if (/\brust\b/i.test(node.title)) return brands.rust;
  if (/\bgo\b/i.test(node.title)) return brands.go;
  if (/kubernetes/i.test(node.title)) return brands.kubernetes;
  return undefined;
}
function Avatar({ node, brands, x = 18, y = 18, size = 34 }: { node: SceneNode; brands: SourceCatalog['brands']; x?: number; y?: number; size?: number }) {
  const color = palettes[node.role];
  const Icon = nodeIcon(node);
  const logo = brand(node, brands);
  return <g>
    <rect x={x} y={y} width={size} height={size} rx={10} fill={color.tint}/>
    {logo ? <image href={logo} x={x + 5} y={y + 5} width={size - 10} height={size - 10}/> : <Icon x={x + 8} y={y + 8} size={size - 16} color={color.ink} strokeWidth={1.8}/>}
  </g>;
}
function Card({ node, scene, brands }: { node: SceneNode; scene: Scene; brands: SourceCatalog['brands'] }) {
  const color = palettes[node.role];
  const state = scene.view.kind === 'state';
  const radius = state ? 26 : 14;
  const titles = wrapText(node.title, node.width - 86, 14, 2, true);
  const details = wrapText(node.details.join(' · '), node.width - 36, 11.5, state ? 2 : 3);
  return <g data-source-node={node.id} data-role={node.role} transform={`translate(${node.x} ${node.y})`}>
    <title>{node.label}</title><desc>{node.id}</desc>
    {node.shape === 'hexagon' ? <path d={`M16 0 H${node.width - 16} L${node.width} ${node.height / 2} L${node.width - 16} ${node.height} H16 L0 ${node.height / 2} Z`} fill="#FFFFFF" stroke={color.ink} strokeOpacity={.45} strokeWidth={1.2} filter="url(#card-shadow)"/> : <rect width={node.width} height={node.height} rx={radius} fill="#FFFFFF" stroke={node.role === 'unknown' || node.role === 'deny' ? color.ink : '#DCE4EC'} strokeWidth={1.2} filter="url(#card-shadow)"/>}
    {!state && node.shape !== 'hexagon' && <rect x={0} y={18} width={3} height={node.height - 36} rx={1.5} fill={color.ink} opacity={.8}/>}
    <Avatar node={node} brands={brands}/>
    {titles.map((line, index) => <Lettering key={index} text={line} x={64} y={31 + index * 19} size={14} strong/>)}
    {details.map((line, index) => <Lettering key={index} text={line} x={18} y={(state ? 66 : 76) + index * 16} size={11.5} fill="#65758B"/>)}
    {!state && <Lettering text={color.label} x={18} y={node.height - 13} size={8.5} strong fill={color.ink}/>}
  </g>;
}
function RecordCard({ node, brands }: { node: SceneNode; brands: SourceCatalog['brands'] }) {
  return <g data-source-node={node.id} transform={`translate(${node.x} ${node.y})`}>
    <title>{node.label}</title>
    <rect width={node.width} height={node.height} rx={13} fill="#FFF" stroke="#CFDFDA" filter="url(#card-shadow)"/>
    <rect width={node.width} height={49} rx={13} fill="#EAF4EF"/>
    <rect y={31} width={node.width} height={18} fill="#EAF4EF"/>
    <Avatar node={{ ...node, role: 'ledger' }} brands={brands} x={12} y={9} size={30}/>
    <Lettering text={wrapText(node.title, node.width - 67, 13.5, 1, true)[0] ?? ''} x={52} y={30} size={13.5} strong fill="#2E5D52"/>
    {node.fields.map((field, index) => <g key={field.name}>
      <title>{`${field.name}: ${field.value}`}</title>
      <line x1={14} y1={50 + index * 28} x2={node.width - 14} y2={50 + index * 28} stroke="#EDF2EF"/>
      <Lettering text={wrapText(field.name, 96, 10.5, 1, true)[0] ?? ''} x={16} y={69 + index * 28} size={10.5} strong fill="#426659"/>
      <Lettering text={wrapText(field.value, node.width - 132, 10.5, 1)[0] ?? ''} x={116} y={69 + index * 28} size={10.5} fill="#6C7D76"/>
    </g>)}
  </g>;
}
function Group({ node, brands, scene }: { node: SceneNode; brands: SourceCatalog['brands']; scene: Scene }) {
  const color = palettes[node.role];
  const extra = [...new Set(scene.nodes.filter(child => child.parent === node.id && child.shape === 'image').flatMap(child => {
    const key = child.icon?.match(/(go|rust|kubernetes)\.svg$/)?.[1];
    return key && brands[key] && brands[key] !== brand(node, brands) ? [key] : [];
  }))];
  return <g data-source-node={node.id} transform={`translate(${node.x} ${node.y})`}>
    <title>{node.label}</title>
    <rect width={node.width} height={node.height} rx={20} fill={color.tint} fillOpacity={.46} stroke={color.ink} strokeOpacity={.18}/>
    <Avatar node={node} brands={brands} x={18} y={14} size={30}/>
    <Lettering text={wrapText(node.title, node.width - 80 - extra.length * 30, 12, 1, true)[0] ?? ''} x={59} y={34} size={12} strong fill={color.ink}/>
    {extra.map((key, index) => <image key={key} href={brands[key]} x={node.width - 40 - index * 30} y={19} width={22} height={22}/>)}
  </g>;
}
function edgePath(points: Point[]): string {
  return points.map((point, index) => `${index ? 'L' : 'M'} ${point.x.toFixed(2)} ${point.y.toFixed(2)}`).join(' ');
}
function Connection({ edge, scene, prefix }: { edge: SceneEdge; scene: Scene; prefix: string }) {
  const box = edge.labelBox;
  return <g data-source-edge={edge.id} data-source-from={edge.source} data-source-to={edge.target}>
    <title>{edge.label}</title>
    <path d={edgePath(edge.points)} fill="none" stroke={edge.dashed ? '#7A9AA8' : '#7F8CA6'} strokeWidth={1.65} strokeLinejoin="round" strokeLinecap="round" strokeDasharray={edge.dashed ? '5 5' : undefined} markerEnd={edge.targetArrow ? `url(#${prefix}-arrow)` : undefined} markerStart={edge.sourceArrow ? `url(#${prefix}-arrow-back)` : undefined}/>
    {box?.leader && <path d={edgePath(box.leader)} fill="none" stroke="#C6D2DE" strokeDasharray="2 4" strokeWidth={1}/>}
    {box && <g transform={`translate(${box.x} ${box.y})`}>
      <rect width={box.width} height={box.height} rx={5} fill={themes[scene.view.kind].paper} fillOpacity={.97}/>
      {box.lines.map((line, index) => <Lettering key={index} text={line} x={box.width / 2} y={17 + index * 14} size={10.5} anchor="middle" fill="#63748C"/>)}
    </g>}
  </g>;
}

/** Pure SVG only: font outlines, local logos, native paths; no server or HTML foreignObject. */
export function ArchitectureImage({ scene, brands }: { scene: Scene; brands: SourceCatalog['brands'] }) {
  const theme = themes[scene.view.kind];
  const prefix = `weaver-${scene.view.sha256.slice(0, 12)}`;
  const annotations = scene.nodes.filter(node => node.annotation);
  return <svg xmlns="http://www.w3.org/2000/svg" viewBox={`0 0 ${scene.width} ${scene.height}`} width={scene.width} height={scene.height} role="img" aria-label={scene.view.title}>
    <title>{scene.view.title}</title>
    <metadata>{JSON.stringify({ source: scene.view.source, sourceDigest: scene.view.sha256, nodes: scene.nodes.map(node => ({ id: node.id, label: node.label })), edges: scene.edges.map(edge => ({ id: edge.id, source: edge.source, target: edge.target, label: edge.label })), generatedDecorations: scene.generatedDecorations })}</metadata>
    <defs>
      <filter id="card-shadow" x="-15%" y="-15%" width="130%" height="145%"><feDropShadow dx={0} dy={3} stdDeviation={5} floodColor="#274260" floodOpacity={.07}/></filter>
      <pattern id={`${prefix}-dots`} width={24} height={24} patternUnits="userSpaceOnUse"><circle cx={2} cy={2} r={.7} fill="#C8D5E0" fillOpacity={.45}/></pattern>
      <marker id={`${prefix}-arrow`} markerWidth={7} markerHeight={7} refX={6} refY={3.5} orient="auto"><path d="M0 0 L7 3.5 L0 7 Z" fill="#7F8CA6"/></marker>
      <marker id={`${prefix}-arrow-back`} markerWidth={7} markerHeight={7} refX={1} refY={3.5} orient="auto"><path d="M7 0 L0 3.5 L7 7 Z" fill="#7F8CA6"/></marker>
    </defs>
    <rect width="100%" height="100%" fill={theme.paper}/>
    <rect y={76} width="100%" height={scene.height - 76} fill={`url(#${prefix}-dots)`}/>
    <rect x={32} y={26} width={4} height={31} rx={2} fill={theme.accent}/>
    <theme.icon x={49} y={27} size={24} color={theme.accent} strokeWidth={1.8}/>
    <Lettering text={theme.name} x={86} y={35} size={9} strong fill={theme.accent}/>
    <Lettering text={wrapText(scene.view.title, scene.width - 124, 18, 1, true)[0] ?? ''} x={86} y={59} size={18} strong fill="#263850"/>
    {scene.nodes.filter(node => node.group && !node.annotation).map(node => <Group key={node.id} node={node} brands={brands} scene={scene}/>)}
    {scene.view.kind === 'sequence' && scene.nodes.filter(node => !node.annotation).map(node => <line key={node.id} x1={node.x + node.width / 2} y1={node.y + node.height} x2={node.x + node.width / 2} y2={scene.height - 80} stroke="#BECFDE" strokeDasharray="4 7"/>)}
    {scene.edges.map(edge => <Connection key={edge.id} edge={edge} scene={scene} prefix={prefix}/>)}
    {scene.nodes.filter(node => !node.group && !node.annotation).map(node => node.fields.length ? <RecordCard key={node.id} node={node} brands={brands}/> : <Card key={node.id} node={node} scene={scene} brands={brands}/>)}
    {annotations.map(node => <g key={node.id} data-source-node={node.id}><title>{node.label}</title><desc>{node.id}</desc></g>)}
    {!!scene.notes?.length && <g transform={`translate(32 ${scene.footerTop ?? scene.height - 100})`}>
      <rect width={scene.width - 64} height={36 + scene.notes.length * 16} rx={12} fill="#FFFFFF" fillOpacity={.7} stroke="#E3EAF0"/>
      <ShieldCheck x={15} y={13} size={15} color={theme.accent}/>
      <Lettering text="DESIGN CONTRACT" x={40} y={25} size={9} strong fill={theme.accent}/>
      {scene.notes.map((line, index) => <Lettering key={index} text={line} x={16} y={44 + index * 16} size={11} fill="#62748B"/>)}
    </g>}
    <line x1={32} y1={scene.height - 43} x2={scene.width - 32} y2={scene.height - 43} stroke="#DEE6EC"/>
    <Lettering text="WEAVER" x={34} y={scene.height - 22} size={10} strong fill="#7B8EA5"/>
    <Lettering text="ORIGINAL SEMANTICS  /  CURRENT AUTHORITY  /  GUARDED EXECUTION" x={scene.width - 34} y={scene.height - 22} size={8} fill="#8594A6" anchor="end"/>
  </svg>;
}
