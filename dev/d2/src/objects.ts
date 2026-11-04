// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import {composeHeading,type FigureComposer} from '@deterministic-engineering/render';
import {componentVocabulary} from './source/components';
import {illustrationNames} from './source/assets';

interface ObjectPresentation {
 readonly icons:Readonly<Record<string,string>>;
 readonly illustrations?:Readonly<Record<string,string>>;
 readonly objectRows:readonly (readonly string[])[];
 readonly bandTitles?:readonly string[];
 readonly bandIcons?:readonly string[];
 readonly exampleIllustration?:string;
}

/** Project illustration parts over the public Library figure/surface/connector APIs.
 * The authored Design chooses reading groups. Browser layout, vector headings,
 * font loading, XYFlow routing, Rough surfaces and export remain upstream. */
export const composeObjects:FigureComposer=context=>{
 if(!context.model||!context.design)throw new Error('Illustrated objects require a bound model and reader Design');
 const p=context.presentation as ObjectPresentation;
 if(!p.objectRows?.length)throw new Error('Illustrated reading groups must be declared by the source view');
 const positions=new Map<string,{row:number;column:number}>(),parts:string[]=[];
 const rows=p.objectRows.map((row,r)=>{
  const cells=row.map((id,column)=>{
   if(positions.has(id))throw new Error('Repeated illustrated object: '+id);
   positions.set(id,{row:r,column});
   const node=context.model!.subjects.find(node=>node.id===id);
   if(!node||node.parent||node.fields?.length||node.methods?.length||node.columns?.length)throw new Error('Choose a suitable notation for the captured object: '+id);
   const icon=p.icons[id],picture=p.illustrations?.[id];
   if(!icon)throw new Error('A functional icon is required: '+id);
   if(!Object.hasOwn(componentVocabulary,icon))throw new Error('Object function requires a canonical component glyph: '+icon);
   const lines=(node.label??node.id).split('\n');
   const observations=context.evidence.filter(item=>item.state!=='supported'&&item.subjectRefs.includes(id));
   lines.push(...observations.map(item=>item.state+' · '+item.sourceRef));
   const captionY=picture?198:38;
   const height=captionY+52+Math.max(0,lines.length-2)*42;
   const title=lines[0]!,detail=lines.slice(1);
   const pictureBox=picture&&(Object.hasOwn(componentVocabulary,picture)?'0 0 24 24':illustrationNames.some(name=>name===picture)?'0 0 220 155':undefined);
   if(picture&&!pictureBox)throw new Error('Brand marks cannot become invented explanatory objects: '+picture);
   const picturePart=picture?'<svg class="'+(Object.hasOwn(componentVocabulary,picture)?'object-symbol':'object-picture')+'" x="40" y="0" width="220" height="155" viewBox="'+pictureBox+'">'+context.glyph(picture)+'</svg>':'';
   const functionPart='<svg x="5" y="'+(captionY-24)+'" width="32" height="32" viewBox="0 0 24 24">'+context.glyph(icon)+'</svg>';
   const label='<text class="scene-title" x="46" y="'+captionY+'">'+context.text(title)+'</text>'+detail.map((line,index)=>'<text class="scene-detail" x="5" y="'+(captionY+38+index*42)+'">'+context.text(line)+'</text>').join('');
   return '<svg data-vector-surface data-node="'+context.text(id)+'" data-scene-node="'+context.text(id)+'" data-illustrated-object role="img" aria-label="'+context.text(lines.join('. '))+'" viewBox="0 0 300 '+height+'" width="300" height="'+height+'">'+picturePart+functionPart+label+'</svg>';
  });
  if(!cells.length)throw new Error('Empty authored reading group');
  const title=p.bandTitles?.[r],glyph=p.bandIcons?.[r];
  const chapter=title?composeHeading(context,{role:'answer',text:title,glyph}):undefined;
  if(chapter)parts.push(chapter.css);
  return '<section class="object-chapter">'+(chapter?chapter.markup:'')+'<section class="object-row" style="grid-template-columns:repeat('+cells.length+',minmax(0,1fr))">'+cells.join('')+'</section></section>';
 });
 if(positions.size!==context.model.subjects.length)throw new Error('Illustration omits captured model subjects');
 const edges=context.model.relations.map(edge=>{
  const from=positions.get(edge.src),to=positions.get(edge.dst);
  if(!from||!to)throw new Error('Illustration omits a relation endpoint');
  if(edge.src===edge.dst)throw new Error('Choose a dedicated notation for a self-relation');
  const source=from.row===to.row?(from.column<to.column?'right':'left'):(from.row<to.row?'bottom':'top');
  const target=source==='right'?'left':source==='left'?'right':source==='bottom'?'top':'bottom';
  return '<path data-scene-edge="'+context.text(edge.id)+'" data-source-id="'+context.text(edge.src)+'" data-target-id="'+context.text(edge.dst)+'" data-from="'+context.text(edge.src)+'" data-to="'+context.text(edge.dst)+'" data-source-position="'+source+'" data-target-position="'+target+'"/>';
 });
 const heading=[composeHeading(context,{role:'title',text:context.view.title}),...context.questions.map(question=>composeHeading(context,{role:'question',text:question.text,questionRef:question.ref}))];
 const narrative=context.design.message.replaceAll('\\n','\n').split('\n').map(text=>composeHeading(context,{role:'note',text}));
 const example=p.exampleIllustration;
 if(example&&!illustrationNames.some(name=>name===example))throw new Error('The example must use an explicitly declared conceptual illustration');
 const examplePart=example?'<svg data-vector-surface data-example-actor width="160" height="113" viewBox="0 0 220 155">'+context.glyph(example)+'</svg>':'';
 parts.push(...heading.map(p=>p.css),...narrative.map(p=>p.css));
 parts.push('.story-message>section{flex:1;min-width:0}.story-message>[data-example-actor]{flex:none}');
 return {markup:'<main><header>'+heading.map(p=>p.markup).join('')+'</header><section class="story-message">'+examplePart+'<section>'+narrative.map(p=>p.markup).join('')+'</section></section><section data-region="objects" class="object-board"><svg class="story-connectors" data-vector-surface data-connections width="100%" height="100%">'+edges.join('')+'</svg>'+rows.join('')+'</section></main>',
  css:parts.join('\n')+'[data-figure]{padding:var(--gutter)}header{margin-bottom:16px}.story-message{display:flex;align-items:center;gap:24px;margin-bottom:28px}.object-board{position:relative;isolation:isolate;display:grid;gap:78px;padding:20px 8px}.object-chapter>svg{margin-bottom:20px}.object-row{display:grid;justify-items:center;gap:32px}.object-row>[data-illustrated-object]{display:block;max-width:100%;height:auto;overflow:visible}.story-connectors{position:absolute;inset:0;pointer-events:none;z-index:-1}.story-connectors>path{fill:none;stroke:var(--accent);stroke-width:2}.object-symbol path,.object-symbol rect,.object-symbol circle,.object-symbol line,.object-symbol polyline,.object-symbol polygon{vector-effect:non-scaling-stroke;stroke-width:2.8}.scene-title{font-size:26px;font-weight:700;fill:var(--ink)}.scene-detail{font-size:26px;font-weight:400;fill:var(--muted)}'};
};
