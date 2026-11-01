import {composeDiagram,type DiagramSpec,type FigureContext,type FigureComposer} from '@deterministic-engineering/render';
import type {Scene} from '../source/types';

/** Weaver projections use the Library's measured layout and vector scene export. */
export function readmeComposition(context:FigureContext,scene:Scene):ReturnType<FigureComposer>{
 const declaration=context.presentation;
 if(!declaration||typeof declaration!=='object'||!('heading'in declaration)||typeof declaration.heading!=='string'||!('subtitle'in declaration)||typeof declaration.subtitle!=='string'||!('icons'in declaration)||!declaration.icons||typeof declaration.icons!=='object')throw new Error('README scene needs its declared heading, subtitle and icons');
 const icons:Record<string,string>={};
 for(const [id,name]of Object.entries(declaration.icons)){
  if(typeof name!=='string'||!scene.nodes.some(node=>node.id===id))throw new Error('Undeclared README scene icon');
  icons[id]=name;
 }
 const branch=(id:string):DiagramSpec['graph']=>{
  const children=scene.nodes.filter(node=>node.parent===id);
  return {id,...(children.length?{children:children.map(child=>branch(child.id)),layoutOptions:{'elk.direction':'DOWN'}}:{})};
 };
 const swimlane=context.layout==='readme-swimlane';
 const graph:DiagramSpec['graph']={id:'weaver-readme',children:scene.nodes.filter(node=>!node.parent).map(node=>branch(node.id)),layoutOptions:{
  'elk.direction':'DOWN',
  'elk.hierarchyHandling':'INCLUDE_CHILDREN',
  'elk.spacing.nodeNode':'24',
  'elk.layered.spacing.nodeNodeBetweenLayers':'40',
 }};
 const roles=Object.fromEntries(scene.nodes.map(node=>[node.id,node.id.startsWith('execution')||node.id==='runtime'?'execution':node.id.startsWith('scheme')?'semantic':'default']));
 const diagram=composeDiagram(context,{graph,icons,roles,edgeLabels:false},(node,{text})=>`<text>${(node.label??node.id).replaceAll('\\n','\n').split('\n').map((line,index)=>`<tspan class="${index?'scene-detail':'scene-title'}" x="0" dy="${index?'1.45em':'0'}">${text(line)}</tspan>`).join('')}</text>`);
 const width=scene.figure.width-48;
 const banner=`<svg data-vector-annotation class="banner" viewBox="0 0 ${width} 112"><text x="8" y="25" class="eyebrow">WEAVER / ${swimlane?'RESPONSIBILITY FLOW':context.layout==='readme-assurance'?'DESIGN ASSURANCE':'AI AGENT GATEWAY'}</text><text x="8" y="64" class="heading">${context.text(declaration.heading)}</text><text x="8" y="99" class="subtitle">${context.text(declaration.subtitle)}</text></svg>`;
 return {markup:`<main>${banner}<section data-question="${context.text(scene.figure.view.question.ref)}" data-region="diagram">${diagram.markup}</section></main>`,css:diagram.css+`
 [data-figure]{background:var(--background)}main{padding:24px}.banner{width:100%;height:auto;margin-bottom:18px}.eyebrow{font-size:16px;letter-spacing:2px;font-weight:700;fill:var(--accent)}.heading{font-size:32px;font-weight:700;fill:var(--ink)}.subtitle{font-size:21px;fill:var(--muted)}
 .scene-svg{--scene-padding:20;--scene-label-padding:8}.scene-title{font-size:24px}.scene-detail{font-size:21px}.scene-group-title{font-size:22px;fill:var(--accent)}.scene-label text{font-size:20px}.scene-frame{fill:var(--surface);stroke:var(--border);stroke-width:1.5;rx:12}[data-scene-group="true"]>.scene-frame{fill:var(--tint);stroke:var(--border);rx:14}[data-role="execution"]>.scene-frame{fill:var(--secondaryTint)}[data-role="semantic"]>.scene-frame{fill:var(--tint)}.scene-glyph>svg{width:34px;height:34px}.scene-edge{stroke-width:2}
 `.trimEnd()};
}
