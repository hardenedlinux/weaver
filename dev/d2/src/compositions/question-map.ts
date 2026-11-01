import {composeDiagram,composeHeading,graphFromModel,type HeadingSpec,type FigureComposer} from '@deterministic-engineering/render';

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
 const styles=new Set<string>();
 const heading=(spec:HeadingSpec)=>{const part=composeHeading(context,spec);styles.add(part.css);return part.markup;};
 const hero=`<header class="hero-panel">${heading({role:'eyebrow',text:p.eyebrow})}${heading({role:'title',text:p.heading})}${heading({role:'subtitle',text:p.subtitle})}</header>`;
 const cards=(items:Card[])=>`<div class="cards columns-${items.length}">${items.map(card=>`<article data-surface="rectangle" data-role="answer">${heading({role:'answer',text:card.title,glyph:card.icon})}<div class="answer-details">${card.lines.map(line=>heading({role:'note',text:line})).join('')}</div></article>`).join('')}</div>`;
 const sections=p.sections.map(section=>{
  const question=context.question(section.question);
  const title=heading({role:'question',questionRef:question.ref,text:question.text});
  return `<section data-question="${text(question.ref)}">${title}${section.model?`<div data-region="model">${ownerHeading}${diagram.markup}</div>`:cards(section.cards!)}</section>`;
 }).join('');
 return {markup:`<main>${hero}${sections}</main>`,css:diagram.css+[...styles].join('\n')+`
 main{padding:36px 48px 40px}.owner-title{font-size:var(--type-headingSize);font-weight:700;fill:var(--accent)}.owner-heading{width:100%;margin:6px 0 20px}.hero-panel{display:grid;gap:24px;margin-bottom:24px}main>section{padding:28px 0;border-top:1px dashed var(--border)}main>section>[data-heading-role=question]{margin-bottom:24px}[data-heading-role=eyebrow] text{font-size:var(--type-eyebrowSize);letter-spacing:2px;fill:var(--accent)}[data-heading-role=subtitle] text{font-size:var(--type-subtitleSize);font-weight:400;fill:var(--muted)}.cards{display:grid;gap:24px}.columns-3{grid-template-columns:repeat(3,minmax(0,1fr))}.columns-2{grid-template-columns:repeat(2,minmax(0,1fr))}.cards article{min-width:0;background:var(--tint);border:1px solid var(--border);border-radius:var(--radius);padding:20px;display:grid;gap:30px;align-content:start}.answer-details{display:grid;gap:14px}[data-heading-role=answer] text{font-weight:700}[data-heading-role=answer] [data-annotation-part=glyph]{color:var(--accent)}
 .scene-title{font-size:25px}.scene-detail{font-size:22px}.scene-group-title{font-size:24px;fill:var(--accent)}.scene-glyph>svg{width:34px;height:34px}.scene-svg{--scene-padding:20;--scene-label-padding:8}.scene-edge{stroke-width:2}.scene-frame{rx:12}[data-role="execution"]>.scene-frame{fill:var(--secondaryTint)}[data-role="semantic"]>.scene-frame{fill:var(--tint)}
 `};
};
