import {composeDiagram,graphFromModel,type FigureComposer} from '@deterministic-engineering/render';

interface Card {icon:string;title:string;lines:string[];}
interface Section {question:string;cards?:Card[];model?:boolean;}
interface Presentation {eyebrow:string;heading:string;subtitle:string;sections:Section[];icons:Record<string,string>;roles:Record<string,string>;options?:Record<string,string>;containerProjection?:'heading';}
const object=(value:unknown):value is Record<string,unknown>=>Boolean(value)&&typeof value==='object'&&!Array.isArray(value);
function declaration(value:unknown):Presentation {
 if(!object(value)||typeof value.eyebrow!=='string'||typeof value.heading!=='string'||typeof value.subtitle!=='string'||!Array.isArray(value.sections)||!object(value.icons)||!object(value.roles))throw new Error('Invalid question map presentation');
 for(const section of value.sections){
  if(!object(section)||typeof section.question!=='string'||(section.model!==true&&!Array.isArray(section.cards)))throw new Error('Invalid question map section');
  for(const card of Array.isArray(section.cards)?section.cards:[]){if(!object(card)||typeof card.icon!=='string'||typeof card.title!=='string'||!Array.isArray(card.lines)||card.lines.some((line:unknown)=>typeof line!=='string'))throw new Error('Invalid question card');}
 }
 return value as unknown as Presentation;
}
/** Functional Library extension: D2 declares questions/content; the Library owns
 * fonts, icons, measured ELK geometry, drawing and vector export. No page IDs. */
export const questionMap:FigureComposer=context=>{
 const p=declaration(context.presentation);
 if(!context.model)throw new Error('Question map needs a captured model');
 const graph=graphFromModel(context.model,p.options);
 let ownerHeading='';
 if(p.containerProjection!==undefined){
  if(p.containerProjection!=='heading'||graph.children?.length!==1||!graph.children[0]!.children)throw new Error('Unsupported container projection');
  const owner=graph.children[0]!;
  if(context.model.relations.some(edge=>edge.src===owner.id||edge.dst===owner.id))throw new Error('Container heading cannot hide an incident relation');
  const subject=context.model.subjects.find(node=>node.id===owner.id)!;
  ownerHeading=`<svg data-vector-annotation class="owner-heading"><g data-scene-node="${context.text(owner.id)}"><text x="0" y="26" class="owner-title">${context.text(subject.label??subject.id)}</text></g></svg>`;
  graph.children=owner.children;
 }
 const configure=(node:typeof graph):void=>{if(node.children){node.layoutOptions={...node.layoutOptions,...p.options};node.children.forEach(configure);}};configure(graph);
 const diagram=composeDiagram(context,{graph,icons:p.icons,roles:p.roles,edgeLabels:false});
 const text=context.text;
 const annotation=(body:string,cls:string,height:number)=>`<svg data-vector-annotation class="${cls}" viewBox="0 0 864 ${height}">${body}</svg>`;
 const heading=annotation(`<text x="0" y="22" class="eyebrow">${text(p.eyebrow)}</text><text x="0" y="82" class="hero">${text(p.heading)}</text><text x="0" y="151" class="subtitle">${text(p.subtitle)}</text>`,'hero-panel',180);
 const cards=(items:Card[])=>`<div class="cards columns-${items.length}">${items.map((card,index)=>`<article>${annotation(`<rect width="100%" height="100%" rx="12" fill="var(--${index%2?'secondaryTint':'tint'})"/><g transform="translate(20 10)" class="card-icon">${context.glyph(card.icon).replace(/<svg\b/,'<svg width="34" height="34" style="width:34px;height:34px"')}</g><text x="68" y="46" class="card-title">${text(card.title)}</text>${card.lines.map((line,i)=>`<text x="20" y="${102+i*46}" class="card-detail">${text(line)}</text>`).join('')}`,'card-copy',126+card.lines.length*46).replace('viewBox="0 0 864','viewBox="0 0 '+(items.length===3?272:420))}</article>`).join('')}</div>`;
 const sections=p.sections.map((section,index)=>{
  const question=context.question(section.question);
  const title=annotation(`<circle cx="18" cy="28" r="18" class="number"/><text x="18" y="36" text-anchor="middle" class="number-text">${index+1}</text><text x="52" y="37" class="section-title">${text(question.text)}</text>`,'section-heading',64);
  return `<section data-question="${text(question.ref)}">${title}${section.model?`<div data-region="model">${ownerHeading}${diagram.markup}</div>`:cards(section.cards!)}</section>`;
 }).join('');
 return {markup:`<main>${heading}${sections}</main>`,css:diagram.css+`
 main{padding:36px 48px 40px;background:var(--background)}.owner-title{font-size:24px;font-weight:700;fill:var(--accent)}.owner-heading{width:100%;margin:6px 0 20px}.hero-panel,.section-heading{display:block;width:100%;height:auto}.eyebrow{font-size:17px;letter-spacing:2px;font-weight:700;fill:var(--accent)}.hero{font-size:42px;font-weight:700;fill:var(--ink)}.subtitle{font-size:23px;fill:var(--muted)}main>section{padding:22px 0;border-top:1px dashed var(--border)}.section-title{font-size:27px;font-weight:700;fill:var(--ink)}.number{fill:var(--accent)}.number-text{font-size:24px;font-weight:700;fill:var(--onAccent)}.cards{display:grid;gap:24px}.columns-3{grid-template-columns:repeat(3,minmax(0,1fr))}.columns-2{grid-template-columns:repeat(2,minmax(0,1fr))}.cards article{background:var(--tint);border-radius:14px;overflow:hidden}.cards article:nth-child(2){background:var(--secondaryTint)}.card-copy{display:block;width:100%;height:auto}.card-icon>svg{width:34px;height:34px;color:var(--accent)}.card-title{font-size:25px;font-weight:700;fill:var(--ink)}.card-detail{font-size:22px;fill:var(--muted)}
 .scene-title{font-size:25px}.scene-detail{font-size:22px}.scene-group-title{font-size:24px;fill:var(--accent)}.scene-glyph>svg{width:34px;height:34px}.scene-svg{--scene-padding:20;--scene-label-padding:8}.scene-edge{stroke-width:2}.scene-frame{rx:12}[data-role="execution"]>.scene-frame{fill:var(--secondaryTint)}[data-role="semantic"]>.scene-frame{fill:var(--tint)}
 `};
};
