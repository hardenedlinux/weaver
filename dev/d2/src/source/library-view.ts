import {compileFigureSource} from '@deterministic-engineering/render';
import {themes} from '../../themes';
import {bindModelView} from './model-view';
import type {Scene,SourceCatalog,ViewEntry} from './types';
/** Effects stop at the public Library boundary; no second compiler or renderer. */
export async function compileLibraryView(catalog:SourceCatalog,view:ViewEntry):Promise<Scene>{
 let figure=await compileFigureSource({...catalog.fs,...catalog.documents},view.source,{themeLayers:themes});
 figure=bindModelView(figure,catalog.modelCapture);
 const icons={...figure.icons};
 for(const name of ['go','rust','kubernetes']){
  const svg=catalog.fs['docs/architecture/diagrams/assets/'+name+'.svg'];
  if(!svg)throw new Error('Missing captured technology icon');
  icons[name]={svg,label:name};
 }
 figure={...figure,icons};
 if(!figure.model||!figure.modelTrace)throw new Error('Model-driven view lacks an authoritative SDK trace');
 return {view,figure,nodes:figure.model.subjects.map(n=>({id:n.id,type:n.type,label:n.label??n.id,parent:n.parent})),edges:figure.model.relations.map(e=>({id:e.id,source:e.src,target:e.dst,label:e.label,sourceArrow:e.srcArrow!=='none',targetArrow:e.dstArrow!=='none'})),svg:''};
}
