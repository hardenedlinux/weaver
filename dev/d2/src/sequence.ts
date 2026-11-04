// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import {composeHeading,type FigureComposer} from '@deterministic-engineering/render';
import {sequenceModel,textLines} from './sequence-model';

/** Project notation over captured messages; the Library owns theme, fonts and export. */
export const composeSequence:FigureComposer=context=>{
 const model=sequenceModel(context.model,context.presentation);
 const width=1548,gap=width/model.actors.length,x=(id:string)=>gap*(model.actors.findIndex(actor=>actor.id===id)+0.5);
 const escape=context.text;
 const text=(lines:readonly string[],atX:number,atY:number,anchor='middle',actionLines=0)=>
  lines.map((line,index)=>`<text data-line="${index}"${index<actionLines?' data-action="true"':''} x="${atX}" y="${atY+index*50}" text-anchor="${anchor}">${escape(line)}</text>`).join('');
 const headerHeight=64+Math.max(...model.actors.map(actor=>textLines(actor.label??actor.id,gap-30).length))*50;
 let y=headerHeight+24;
 const messages=model.messages.map((edge,index)=>{
  const start=x(edge.src),end=x(edge.dst),self=edge.src===edge.dst;
  const last=self&&start+gap>width;
  const labelSpace=self?Math.min(gap*1.65,last?start-60:width-start-60):Math.min(width-110,Math.max(gap*1.65,Math.abs(end-start)-30));
  const lines=textLines(edge.label??'',labelSpace);
  const actionLines=textLines((edge.label??'').replaceAll('\\n','\n').split('\n')[0]!,labelSpace).length;
  const labelX=self?start+(last?-30:30):(start+end)/2,top=y;
  y+=lines.length*50+49;
  const lineY=y-24;
  const path=self?`M ${start} ${lineY-16} h 64 v 16 h -64`:`M ${start} ${lineY} H ${end}`;
  const left=edge.srcArrow&&edge.srcArrow!=='none'?' marker-start="url(#sequence-start)"':'';
  const right=edge.dstArrow&&edge.dstArrow!=='none'?' marker-end="url(#sequence-end)"':'';
  const labelWidth=Math.max(...lines.map(line=>line.length))*20+18;
  const labelLeft=labelX-(self?(last?labelWidth:0):labelWidth/2);
  return `<g class="sequence-message" data-scene-edge="${escape(edge.id)}" data-sequence-index="${index}" data-source-id="${escape(edge.src)}" data-target-id="${escape(edge.dst)}"><text class="sequence-index" x="8" y="${top+24}">${String(index+1).padStart(2,'0')}</text><rect class="sequence-label" x="${labelLeft}" y="${top-8}" width="${labelWidth}" height="${lines.length*50+12}"/>${text(lines,labelX,top+24,self?(last?'end':'start'):'middle',actionLines)}<path d="${path}"${left}${right}/></g>`;
 });
 const end=y;
 const actors=model.actors.map(actor=>`<g class="sequence-actor" data-scene-node="${escape(actor.id)}"><rect x="${x(actor.id)-gap/2+18}" y="8" width="${gap-36}" height="${headerHeight-12}" rx="10"/>${text(textLines(actor.label??actor.id,gap-54),x(actor.id),55)}</g>`);
 const lifelines=model.lifelines.map(edge=>`<g data-scene-edge="${escape(edge.id)}" data-sequence-lifeline="${escape(edge.src)}" data-source-id="${escape(edge.src)}" data-target-id="${escape(edge.dst)}"><path class="sequence-lifeline" d="M ${x(edge.src)} ${headerHeight} V ${end}"/></g>`);
 const notes=model.notes.map(({subject,owner})=>{
  const lines=textLines(subject.label??'',width-100),top=y+22;
  y=top+108+lines.length*50;
  return `<g data-scene-node="${escape(subject.id)}" data-note-owner="${escape(owner.id)}"><rect class="sequence-note" x="18" y="${top}" width="${width-36}" height="${y-top}" rx="10"/><text class="sequence-note-title" x="48" y="${top+42}">Safety rule</text>${text(lines,48,top+97,'start')}</g>`;
 });
 const heading=[composeHeading(context,{role:'title',text:context.view.title}),...context.questions.map(question=>composeHeading(context,{role:'question',text:question.text,questionRef:question.ref}))];
 const svg=`<svg xmlns="http://www.w3.org/2000/svg" data-vector-surface="sequence" viewBox="0 0 ${width} ${y+24}" width="${width}" height="${y+24}"><defs><marker id="sequence-end" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="9" markerHeight="9" orient="auto"><path d="M 1 1 L 9 5 L 1 9 Z"/></marker><marker id="sequence-start" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="9" markerHeight="9" orient="auto"><path d="M 9 1 L 1 5 L 9 9 Z"/></marker></defs>${lifelines.join('')}${actors.join('')}${messages.join('')}${notes.join('')}</svg>`;
 return {markup:`<main><header>${heading.map(item=>item.markup).join('')}</header><section data-region="model">${svg}</section></main>`,css:heading.map(item=>item.css).join('\n')+`
 [data-figure]{padding:var(--gutter)}header{margin-bottom:24px}[data-vector-surface="sequence"]{display:block;width:100%;height:auto;font-family:inherit}
 [data-vector-surface="sequence"] text{font-size:36px;fill:var(--ink)}[data-vector-surface="sequence"] rect{fill:var(--surface);stroke:var(--accent);stroke-width:1.5}
 [data-vector-surface="sequence"] path{fill:none;stroke:var(--accent);stroke-width:2}[data-vector-surface="sequence"] marker path{fill:var(--accent)}
 [data-vector-surface="sequence"] .sequence-lifeline{stroke:var(--border);stroke-dasharray:5 10}
 [data-vector-surface="sequence"] .sequence-index{fill:var(--muted);font-size:24px;font-weight:700}
 [data-vector-surface="sequence"] .sequence-actor rect{fill:var(--ink);stroke:none}
 [data-vector-surface="sequence"] .sequence-actor text{fill:var(--surface);font-weight:700}
 [data-vector-surface="sequence"] .sequence-message [data-action]{font-weight:700}
 [data-vector-surface="sequence"] .sequence-note{fill:var(--tint);stroke:none}
 [data-vector-surface="sequence"] .sequence-note-title{font-size:28px;font-weight:700;fill:var(--accent)}
 [data-vector-surface="sequence"] .sequence-label{fill:var(--background);stroke:none}
`.trim()};
};
