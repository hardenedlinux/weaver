import {loadLibraryFigure,sceneFromFigure} from './library-view';
import {LegacyReferenceCompiler} from './legacy-reference';
import type {Scene,SourceCatalog,ViewEntry} from './types';

/** One public declaration reader. Unsupported notations remain explicitly
 * selected references; projection/export failures never switch renderers. */
export class SourceCompiler {
 private reference?:LegacyReferenceCompiler;
 constructor(private readonly catalog:SourceCatalog){}
 async compile(view:ViewEntry):Promise<Scene>{
  const figure=await loadLibraryFigure(this.catalog,view);
  if(figure.layout==='question-map'||figure.layout==='model-map')return sceneFromFigure(view,figure);
  if(!['d2-reference','gateway-responsibility-map','gateway-relationship-matrix','execution-proof-correspondence'].includes(figure.layout??''))throw new Error('Unsupported declared composition: '+figure.layout);
  this.reference??=new LegacyReferenceCompiler(this.catalog);
  return this.reference.compile(view);
 }
}
