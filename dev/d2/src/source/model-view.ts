import {renderedViewFromJson} from '@openmbee/opensysml';
import {projectOpenSysMLView} from '@deterministic-engineering/render/opensysml';
import type {FigureInput} from '@deterministic-engineering/render';
import type {ModelCapture} from './models';

export interface SubjectCaption {name:string;type:string;label:string;icon:string;role?:string;}
const object=(value:unknown):value is Record<string,unknown>=>Boolean(value)&&typeof value==='object'&&!Array.isArray(value);
/** Only presentation selectors use names. Native SDK IDs own all model identity. */
export function bindModelView(input:FigureInput,capture:ModelCapture|undefined):FigureInput {
 const p=input.presentation;
 if(!object(p)||p.modelView===undefined)return input;
 if(typeof p.modelView!=='string'||!capture||!Object.hasOwn(capture.views,p.modelView))throw new Error('Missing Go-owned SDK view capture');
 if(!Array.isArray(p.captions))throw new Error('Model view needs explicit presentation selectors');
 const rendering=renderedViewFromJson(capture.views[p.modelView]);
 const labels:Record<string,string>={},icons:Record<string,string>={},roles:Record<string,string>={};
 for(const selector of p.captions){
  if(!object(selector)||typeof selector.name!=='string'||typeof selector.type!=='string'||typeof selector.label!=='string'||typeof selector.icon!=='string'||selector.role!==undefined&&typeof selector.role!=='string')throw new Error('Invalid model caption selector');
  const nodes=rendering.nodes.filter(node=>node.name===selector.name&&node.type===selector.type);
  if(nodes.length!==1||Object.hasOwn(labels,nodes[0]!.id))throw new Error('Ambiguous, missing or duplicate SDK caption selector: '+selector.name);
  const id=nodes[0]!.id;labels[id]=selector.label;icons[id]=selector.icon;if(selector.role)roles[id]=selector.role;
 }
 if(Object.keys(labels).length!==rendering.nodes.length)throw new Error('Model presentation omitted SDK subjects');
 const selected={modelHash:capture.modelHash,requestedView:p.modelView,rendering};
 const projection=projectOpenSysMLView(selected,{selection:input.view,layout:'reflow',portProjection:'owner',labels});
 const ref='sdkCapture',source='dev/sysml/captures/'+p.modelView.replaceAll('::','-')+'.json';
 return {...input,model:projection.model,modelTrace:projection.trace,
  modelSource:{ref,view:p.modelView,modelHash:capture.modelHash,portProjection:'owner',labels},
  sources:{...input.sources,[source]:projection.trace.capturedRenderingJSON},references:{...input.references,[ref]:source},presentation:{...p,icons,roles}};
}
