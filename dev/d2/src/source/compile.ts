import {D2,type Connection} from '@terrastruct/d2';
import {readD2Figure} from '@deterministic-engineering/render';
import type {Scene,SourceCatalog,ViewEntry} from './types';
import {bindD2SVG} from './d2-svg';
export function generatedLifeline(edge:Pick<Connection,'id'|'src'|'dst'|'label'|'strokeDash'|'srcArrow'|'dstArrow'>,ids:Set<string>,kind:ViewEntry['kind']):boolean {
 return kind==='sequence'&&ids.has(edge.src)&&!ids.has(edge.dst)&&edge.dst.startsWith(`${edge.src}-lifeline-end-`)&&/^\d+$/.test(edge.dst.slice(`${edge.src}-lifeline-end-`.length))&&edge.id===`(${edge.src} -- )[0]`&&edge.strokeDash===6&&!edge.label&&edge.srcArrow==='none'&&edge.dstArrow==='none';
}
/** Host supplies effects and capture; the library owns rendering and declaration semantics. */
export class SourceCompiler {
 private readonly engine=new D2();
 constructor(private readonly catalog:SourceCatalog){}
 async compile(view:ViewEntry):Promise<Scene>{
  const compiled=await this.engine.compile({fs:this.catalog.fs,inputPath:view.source,options:{layout:'elk'}});
  const ids=new Set(compiled.diagram.shapes.map(n=>n.id));
  const connections=compiled.diagram.connections.filter(e=>!generatedLifeline(e,ids,view.kind));
  const figure=readD2Figure({data:compiled.graph.data as unknown,diagram:{shapes:compiled.diagram.shapes,connections},inputPath:view.source,fs:compiled.fs},{...this.catalog.documents,...this.catalog.fs});
  // Full D2 SVG remains a technical source reference, separate from Library scenes.
  const technicalSVG=await this.engine.render(compiled.diagram,compiled.renderOptions);
  const resolve=(id:string)=>ids.has(id)?id:[...ids].filter(parent=>id.startsWith(parent+'.')).sort((a,b)=>b.length-a.length)[0]??id;
  const nodes=compiled.diagram.shapes.map(n=>({id:n.id,type:n.type,label:(('label' in n&&typeof n.label==='string')?n.label:n.id),parent:[...ids].filter(id=>n.id.startsWith(id+'.')).sort((a,b)=>b.length-a.length)[0]}));
  const edges=connections.map(e=>({id:e.id,source:resolve(e.src),target:resolve(e.dst),label:e.label,sourceArrow:e.srcArrow!=='none'&&Boolean(e.srcArrow),targetArrow:e.dstArrow!=='none'&&Boolean(e.dstArrow)}));
  const icons={...figure.icons};
  for(const shape of compiled.diagram.shapes.filter(n=>n.icon)){
   const value:unknown=shape.icon;
   const resource=typeof value==='string'?value:value&&typeof value==='object'&&'Path' in value&&typeof value.Path==='string'?value.Path:undefined;
   if(!resource)throw new Error('Image has no captured asset: '+shape.id);
   const file=new URL(resource,'file:///'+view.source).pathname.slice(1);
   const svg=this.catalog.fs[file];if(!svg)throw new Error('Missing source asset: '+file);
   icons[shape.id]={svg,label:shape.id};
  }
  const scene={view,figure:{...figure,icons},nodes,edges,svg:technicalSVG};
  return {...scene,svg:bindD2SVG(scene,this.catalog.fs)};
 }
}
