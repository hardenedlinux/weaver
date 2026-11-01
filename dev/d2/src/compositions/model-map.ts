import {composeDiagram,graphFromModel,type FigureComposer,type FigureModel} from '@deterministic-engineering/render';
interface Breaks {title:number[];detail:number[];}
interface RelationBreaks {binding:number[];detail:number[];}
interface Declaration {captions:Record<string,Breaks>;annotations:Record<string,'heading'|'constraint'>;icons:Record<string,string>;roles:Record<string,string>;options:Record<string,string>;nodeOptions?:Record<string,Record<string,string>>;relations:Record<string,RelationBreaks>;lineGap:number;}
const object=(value:unknown):value is Record<string,unknown>=>Boolean(value)&&typeof value==='object'&&!Array.isArray(value);
const words=(text:string):string[]=>text.trim()?text.trim().split(/\s+/u):[];
/** Explicit source-authored break positions, never another wording source or
 * font measurement engine. Every captured word must appear exactly once. */
export function partitionWords(text:string,cuts:unknown):string[]{
 const source=words(text);
 if(!Array.isArray(cuts)||cuts.some(cut=>!Number.isInteger(cut))||cuts.length===0&&source.length>0||cuts.length>0&&cuts.at(-1)!==source.length)throw new Error('Breaks do not cover the captured wording');
 let previous=0;const lines:string[]=[];
 for(const cut of cuts){if(cut<=previous||cut>source.length)throw new Error('Invalid captured-word partition');lines.push(source.slice(previous,cut).join(' '));previous=cut;}
 return lines;
}
function caption(model:FigureModel,id:string,value:unknown):{title:string[];detail:string[]}{
 const node=model.subjects.find(node=>node.id===id);
 if(!node||!object(value))throw new Error('Unknown captured caption subject: '+id);
 const [title,...detail]=(node.label??node.id).split('\n');
 let boundary=0;
 for(const paragraph of detail.slice(0,-1)){boundary+=words(paragraph).length;if(boundary>0&&(!Array.isArray(value.detail)||!value.detail.includes(boundary)))throw new Error('Caption erases a captured paragraph boundary');}
 return {title:partitionWords(title!,value.title),detail:partitionWords(detail.join(' '),value.detail)};
}
const originalTitle=(model:FigureModel,id:string)=>model.subjects.find(node=>node.id===id)?.label?.split('\n')[0]??id;
function declaration(value:unknown,model:FigureModel):Declaration {
 if(!object(value)||!object(value.captions)||!object(value.annotations)||!object(value.icons)||!object(value.roles)||!object(value.options)||!object(value.relations))throw new Error('Model map requires explicit presentation data');
 const ids=new Set(model.subjects.map(node=>node.id));
 if(Object.keys(value.captions).length!==ids.size)throw new Error('Model captions must cover the complete captured inventory');
 for(const [id,breaks]of Object.entries(value.captions))caption(model,id,breaks);
 for(const [id,role]of Object.entries(value.annotations)){
  const node=model.subjects.find(node=>node.id===id);
  if(!node||node.type!=='text'||role!=='heading'&&role!=='constraint'||model.relations.some(edge=>edge.src===id||edge.dst===id))throw new Error('Annotation cannot hide a connected model subject: '+id);
 }
 for(const mapping of [value.icons,value.roles])for(const [id,name]of Object.entries(mapping))if(!ids.has(id)||typeof name!=='string')throw new Error('Unknown model presentation subject: '+id);
 if(Object.values(value.options).some(option=>typeof option!=='string'))throw new Error('Invalid declared layout options');
 if(value.nodeOptions!==undefined){
  if(!object(value.nodeOptions))throw new Error('Invalid declared node layout options');
  for(const [id,options]of Object.entries(value.nodeOptions))if(!ids.has(id)||Object.hasOwn(value.annotations,id)||!object(options)||Object.values(options).some(option=>typeof option!=='string'))throw new Error('Unresolved native node layout options: '+id);
 }
 if(typeof value.lineGap!=='number'||!Number.isInteger(value.lineGap)||value.lineGap<32||value.lineGap>64)throw new Error('Invalid declared text spacing');
 if(Object.keys(value.relations).length!==model.relations.length)throw new Error('Relation captions must cover every captured relationship');
 for(const edge of model.relations){
  const item=value.relations[edge.id];
  if(!object(item))throw new Error('Missing captured relationship caption');
  partitionWords(originalTitle(model,edge.src)+' → '+originalTitle(model,edge.dst),item.binding);
  partitionWords(edge.label||'Connection',item.detail);
 }
 return value as unknown as Declaration;
}
/** A pure functional Library extension. D2 chooses word breaks, glyphs and
 * roles; native identities, wording and endpoints remain in the captured model. */
export const modelMap:FigureComposer=context=>{
 if(!context.model)throw new Error('Model map requires a captured source model');
 const model=context.model,p=declaration(context.presentation,model),text=context.text;
 if(model.subjects.some(node=>['class','sql_table'].includes(node.type)||node.columns?.length||node.fields?.length||node.methods?.length))throw new Error('Typed member notation requires a supported dedicated adapter');
 const ids=new Set(model.subjects.map(node=>node.id));
 if(model.relations.some(edge=>!ids.has(edge.src)||!ids.has(edge.dst)))throw new Error('Missing model endpoint requires a supported notation adapter');
 const graph=graphFromModel(model,p.options);
 graph.children=graph.children!.filter(node=>!Object.hasOwn(p.annotations,node.id));
 for(const node of graph.children)node.layoutOptions={...node.layoutOptions,...p.nodeOptions?.[node.id]};
 const body=(id:string,titleOnly=false)=>{
  const item=caption(model,id,p.captions[id]);
  return `<text>${[...item.title.map(line=>({line,kind:'title'})),...(titleOnly?[]:item.detail.map(line=>({line,kind:'detail'})))].map(({line,kind},index)=>`<tspan class="scene-${kind}" x="0" dy="${index?p.lineGap:0}">${text(line)}</tspan>`).join('')}</text>`;
 };
 // A numbered display projection keeps the original relation IDs, endpoints and
 // arrowheads. Its complete source wording is rendered in the keyed cards below.
 const display={...context,model:{...model,relations:model.relations.map((edge,index)=>({...edge,label:String(index+1)}))}};
 const diagram=composeDiagram(display,{graph,icons:p.icons,roles:p.roles},node=>body(node.id,true));
 const annotation=(id:string)=>`<svg width="100%" data-vector-annotation class="model-note ${p.annotations[id]}">${p.annotations[id]==='constraint'?'<rect width="100%" height="100%" fill="var(--tint)" rx="12"/>':''}<g data-scene-node="${text(id)}">${body(id)}</g></svg>`;
 const header=(wording:string,kind:string)=>`<svg width="100%" data-vector-annotation class="${kind}"><text x="0" y="26">${text(wording)}</text></svg>`;
 const relationships=model.relations.map((edge,index)=>{
  const item=p.relations[edge.id]!,binding=partitionWords(originalTitle(model,edge.src)+' → '+originalTitle(model,edge.dst),item.binding),detail=partitionWords(edge.label||'Connection',item.detail);
  return `<svg width="100%" data-vector-annotation class="relation-copy"><rect width="100%" height="100%" rx="12" fill="var(--tint)"/><g data-relation-caption="${text(edge.id)}"><text>${detail.map((line,i)=>`<tspan x="16" dy="${i?p.lineGap:0}" class="relation-title">${i?'':index+1+'. '}${text(line)}</tspan>`).join('')}${binding.map(line=>`<tspan x="16" dy="${p.lineGap}" class="relation-detail">${text(line)}</tspan>`).join('')}</text></g></svg>`;
 }).join('');
 const responsibilities=model.subjects.filter(node=>!Object.hasOwn(p.annotations,node.id)).map(node=>`<svg width="100%" data-vector-annotation class="responsibility-copy"><rect width="100%" height="100%" rx="12" fill="var(--surface)"/><g transform="translate(16 0)" data-caption-for="${text(node.id)}">${body(node.id)}</g></svg>`).join('');
 return {markup:`<main data-question="${text(context.view.question.ref)}">${header(context.view.question.text,'model-question')}${Object.keys(p.annotations).filter(id=>p.annotations[id]==='heading').map(annotation).join('')}<section data-region="model">${diagram.markup}</section><section class="constraints" data-region="constraints">${Object.keys(p.annotations).filter(id=>p.annotations[id]==='constraint').map(annotation).join('')}</section><section class="relations" data-region="relationships">${relationships?header('What does each connection carry?','relation-heading')+'<div class="caption-grid">'+relationships+'</div>':''}</section><section class="responsibilities" data-region="responsibilities">${header('What does each owner retain?','relation-heading')}<div class="caption-grid">${responsibilities}</div></section></main>`,css:diagram.css+`
 main{padding:36px 48px;background:var(--background)}.model-question{margin-bottom:26px}.model-question text{font-size:25px;fill:var(--accent);font-weight:700}.model-note{display:block;margin:18px 0 28px}.heading .scene-title{font-size:30px}.constraints{margin:28px 0;padding:20px;background:var(--tint);border-radius:12px}.constraints:empty{display:none}.relations{border-top:1px dashed var(--border);padding-top:26px}.relation-heading{margin-bottom:22px}.relation-heading text{font-size:27px;font-weight:700;fill:var(--accent)}.relation-copy{margin:0 0 24px}.relation-title{font-size:23px;font-weight:700;fill:var(--ink)}.relation-detail{font-size:22px;fill:var(--muted)}.scene-glyph>svg{width:34px;height:34px}.scene-glyph>svg[data-brand="rust"]{fill:var(--ink)}.scene-title{font-size:25px}.scene-detail{font-size:22px}.scene-edge{stroke-width:2}[data-role="execution"]>.scene-frame{fill:var(--secondaryTint)}[data-role="semantic"]>.scene-frame{fill:var(--tint)}[data-role="policy"]>.scene-frame{stroke:var(--secondary);fill:var(--secondaryTint)}
 .caption-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:24px;align-items:start}.caption-grid>svg{min-width:0}.responsibilities{border-top:1px dashed var(--border);padding-top:26px}.responsibility-copy{margin-bottom:16px}.scene-svg .scene-label text{font-size:24px}
 `};
};
