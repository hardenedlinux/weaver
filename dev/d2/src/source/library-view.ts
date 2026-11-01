import {compileFigureSource,type FigureInput} from '@deterministic-engineering/render';
import {themes} from '../../themes';
import {bindModelView} from './model-view';
import type {Scene,SourceCatalog,ViewEntry} from './types';
/** Effects stop at the public Library boundary; no second compiler or renderer. */
export async function loadLibraryFigure(catalog:SourceCatalog,view:ViewEntry):Promise<FigureInput>{
 let figure=await compileFigureSource({...catalog.fs,...catalog.documents},view.source,{themeLayers:themes},{layout:'elk'});
 figure=bindModelView(figure,catalog.modelCapture);
 const icons={...figure.icons};
 for(const name of ['go','rust','kubernetes']){
  const svg=catalog.fs['docs/architecture/diagrams/assets/'+name+'.svg'];
  if(!svg)throw new Error('Missing captured technology icon');
  icons[name]={svg:svg.replace('<svg','<svg data-brand="'+name+'"'),label:name};
 }
 figure={...figure,icons};
 if(!figure.model||figure.modelSource&&!figure.modelTrace)throw new Error('Model-driven view lacks its captured model or SDK trace');
 return figure;
}
export function sceneFromFigure(view:ViewEntry,figure:FigureInput):Scene {
 if(!figure.model)throw new Error('Missing captured model');
 return {view,figure,nodes:figure.model.subjects.map(n=>({id:n.id,type:n.type,label:n.label??n.id,parent:n.parent})),edges:figure.model.relations.map(e=>({id:e.id,source:e.src,target:e.dst,label:e.label,sourceArrow:Boolean(e.srcArrow&&e.srcArrow!=='none'),targetArrow:Boolean(e.dstArrow&&e.dstArrow!=='none'),sourceMarker:e.srcArrow??'none',targetMarker:e.dstArrow??'none'})),svg:''};
}
export async function compileLibraryView(catalog:SourceCatalog,view:ViewEntry):Promise<Scene>{
 return sceneFromFigure(view,await loadLibraryFigure(catalog,view));
}
