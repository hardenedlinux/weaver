// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import {composeDiagram,composeHeading,modelDiagram,type FigureComposer,type FigureInput,type DiagramNodeComposer,type DiagramSpec} from '@deterministic-engineering/render';

/** Project reading constraints. The Library owns measurement, ELK, drawing,
 * fonts, surfaces, connectors and image export. Captured model data is intact. */
export const readingProfile=Object.freeze({width:1120,lineCharacters:40});
export function readingFigure(input:FigureInput):FigureInput {
 return input.layout==='model-view'?{...input,width:Math.min(input.width,readingProfile.width)}:input;
}
/** Soft line breaks retain every character, including spaces and long tokens. */
export function readingLines(text:string,limit:number=readingProfile.lineCharacters):string[] {
 if(!Number.isInteger(limit)||limit<1)throw new Error('Invalid reading line width');
 const lines:string[]=[];
 for(const source of text.replaceAll('\\n','\n').split('\n')){
  let line:string[]=[];
  for(const token of source.match(/\S+\s*|\s+/gu)??[]){
   let rest=Array.from(token);
   if(line.length+rest.length>limit&&line.length){lines.push(line.join(''));line=[];}
   while(rest.length>limit){lines.push(rest.slice(0,limit).join(''));rest=rest.slice(limit);}
   line.push(...rest);
  }
  lines.push(line.join(''));
 }
 return lines;
}
const readingNode:DiagramNodeComposer=(node,context)=>{
 const {model,evidence,text,theme}=context;
 const source=[node.label??node.id,...(node.columns??[]).map(column=>[column.name.label,column.type.label,...(column.constraint??[])].filter(Boolean).join(' · ')),...(node.fields??[]).map(field=>`${field.visibility} ${field.name}: ${field.type}`),...(node.methods??[]).map(method=>`${method.visibility} ${method.name}: ${method.return}`)].join('\n').replaceAll('\\n','\n').split('\n');
 if(node.parent)source.push('Owner scope: '+node.parent);
 if(model?.subjects.some(subject=>subject.parent===node.id))source.push('Scope definition');
 const observations=evidence.filter(item=>item.state!=='supported'&&(item.subjectRefs.includes(node.id)||item.relationRefs.some(id=>model?.relations.some(relation=>relation.id===id&&(relation.src===node.id||relation.dst===node.id)))));
 const lines=source.flatMap((line,index)=>readingLines(line).map(value=>({value,title:index===0})));
 lines.push(...observations.flatMap(item=>readingLines(item.state+' · '+item.sourceRef).map(value=>({value,title:false}))));
 return `<text class="scene-node-text" xml:space="preserve">${lines.map((line,index)=>`<tspan data-text-line class="${line.title?'scene-title':'scene-detail'}" x="0" dy="${index?theme.typography.lineHeight:'0'}">${text(line.value)}</tspan>`).join('')}</text>`;
};
/** An ownership-caption projection retains every source subject and relation.
 * Compound scope identities remain visible as scope cards and owner captions;
 * this view deliberately does not claim spatial containment. Captured model
 * parent identities remain intact. The Library still owns all graph geometry. */
export function readingGraph(specification:DiagramSpec):DiagramSpec {
 const graph=structuredClone(specification.graph);
 const compound=graph.children?.some(node=>node.children);
 if(!compound&&graph.layoutOptions?.['elk.partitioning.activate']==='true')return specification;
 const subjects:NonNullable<typeof graph.children>=[];
 const collect=(nodes:typeof graph.children)=>nodes?.forEach(node=>{
  const {children,...subject}=node; subjects.push(subject);
  collect(node.children);
 });
 collect(graph.children);
 graph.children=subjects;
 graph.layoutOptions={...graph.layoutOptions,
  'org.eclipse.elk.separateConnectedComponents':'false',
  'org.eclipse.elk.layered.nodePlacement.strategy':'SIMPLE',
  'org.eclipse.elk.layered.layering.strategy':'COFFMAN_GRAHAM',
  'org.eclipse.elk.layered.layering.coffmanGraham.layerBound':'1'};
 return {...specification,graph};
}
export const composeReadingView:FigureComposer=context=>{
 if(!context.model)throw new Error('Reading view needs the captured model');
 const specification=readingGraph(modelDiagram(context.model,context.presentation));
 const scene=composeDiagram(context,{...specification,edgeLabels:false},readingNode);
 const relations=specification.edgeLabels===false?[]:context.model.relations.filter(edge=>edge.label?.trim());
 const legend=relations.flatMap(edge=>readingLines(`${edge.src} → ${edge.dst}: ${edge.label}`)).filter(line=>line.trim()).map(line=>composeHeading(context,{role:'note',text:line}));
 const headings=[composeHeading(context,{role:'title',text:context.view.title}),...context.questions.map(question=>composeHeading(context,{role:'question',text:question.text,questionRef:question.ref}))];
 return {markup:`<main><header>${headings.map(heading=>heading.markup).join('')}</header><section data-region="model">${scene.markup}</section>${legend.length?`<section data-region="relations">${legend.map(line=>line.markup).join('')}</section>`:''}</main>`,css:scene.css+[...headings,...legend].map(heading=>heading.css).join('\n')+'[data-figure]{padding:var(--gutter)}header{margin-bottom:var(--gap)}'};
};
