// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import {beforeAll,describe,expect,test} from 'bun:test';
import fc from 'fast-check';
import {fileURLToPath} from 'node:url';
import {compileFigureSource,type FigureInput} from '@deterministic-engineering/render';
import {sequenceModel} from '../src/sequence-model';
import {composeSequence} from '../src/sequence';
import {composeFigure} from '@deterministic-engineering/render';
import {collectCatalog} from '../src/source/catalog';
import {themes} from '../themes';
import {readFile} from 'node:fs/promises';
import {chromium} from 'playwright';

const names=['02-admission-sequence','04-consume-timeout','09-claim-wins-race','10-commit-dispatch-sequence'];
const inputs:FigureInput[]=[];
beforeAll(async()=>{
 const catalog=collectCatalog(fileURLToPath(new URL('../../../',import.meta.url)));
 const sources={...catalog.fs,...catalog.documents};
 const outcomes=await Promise.allSettled(names.map(name=>compileFigureSource(sources,`docs/architecture/diagrams/${name}.d2`,{themeLayers:themes},{layout:'elk'})));
 for(const outcome of outcomes){if(outcome.status==='rejected')throw outcome.reason;inputs.push(outcome.value);}
});

describe('source-bound ordered sequence notation',()=>{
 test('standalone vectors keep text readable and inside the image at GitHub width',async()=>{
  const browser=await chromium.launch();
  const root=fileURLToPath(new URL('../../../',import.meta.url));
  try{
   const results=await Promise.allSettled(names.map(async name=>{
    const page=await browser.newPage();
    try{
     const svg=await readFile(`${root}docs/architecture/diagrams/${name}.svg`,'utf8');
     await page.setContent('<style>body{margin:0}body>svg{width:830px;height:auto}</style>'+svg);
     await page.evaluate(()=>document.fonts.ready);
     const issues=await page.evaluate(()=>{
      const root=document.querySelector('body>svg')!.getBoundingClientRect(),issues:string[]=[];
      for(const text of document.querySelectorAll<SVGTextElement>('svg text')){
       const box=text.getBoundingClientRect();
       if(box.left<root.left-1||box.right>root.right+1||box.top<root.top-1||box.bottom>root.bottom+1)issues.push('Clipped: '+text.textContent);
      }
      for(const text of document.querySelectorAll<SVGTextElement>('[data-vector-surface=sequence] text:not(.sequence-index):not(.sequence-note-title)')){
       const matrix=text.getScreenCTM()!,size=parseFloat(getComputedStyle(text).fontSize)*Math.hypot(matrix.a,matrix.b);
       if(size<18)issues.push('Small: '+text.textContent);
      }
      for(const message of document.querySelectorAll('.sequence-message')){
       const lines=[...message.querySelectorAll('text[data-line]')].map(text=>text.getBoundingClientRect());
       for(let index=1;index<lines.length;index++)if(lines[index]!.top<lines[index-1]!.bottom)issues.push('Overlapping message lines');
      }
      return issues;
     });
     expect(issues).toEqual([]);
    }finally{await page.close();}
   }));
   for(const result of results)if(result.status==='rejected')throw result.reason;
  }finally{await browser.close();}
 });
 test('every captured message, lifeline, self-call and constraint is retained',()=>{
  for(const [index,input] of inputs.entries()){
   const selected=sequenceModel(input.model,input.presentation);
   expect(selected.messages.length).toBe([17,11,15,16][index]!);
   expect(selected.actors.length).toBe([5,4,5,5][index]!);
   expect(selected.messages.length+selected.lifelines.length).toBe(input.model!.relations.length);
   expect(selected.actors.length+selected.notes.length).toBe(input.model!.subjects.length);
   expect(selected.messages.some(message=>message.src===message.dst)).toBe(true);
   expect(selected.notes.length).toBeGreaterThan(0);
   const html=composeFigure(input,composeSequence).html;
   const ordinals=Array.from(html.matchAll(/data-sequence-index="(\d+)"/g),match=>Number(match[1]));
   expect(ordinals).toEqual(selected.messages.map((_,index)=>index));
   expect(html).not.toContain('foreignObject');
  }
 });
 test('dropping or duplicating any source message refuses',()=>{
  for(const input of inputs){
   const selected=sequenceModel(input.model,input.presentation);
   fc.assert(fc.property(fc.integer({min:0,max:selected.messages.length-1}),index=>{
    const declaration=input.presentation as {messages:string[]};
    const missing={...declaration,messages:declaration.messages.filter((_,position)=>position!==index)};
    expect(()=>sequenceModel(input.model,missing)).toThrow();
    expect(()=>sequenceModel(input.model,{...declaration,messages:[...declaration.messages,declaration.messages[index]]})).toThrow();
   }));
  }
 });
 test('source order, participant identity and constraint ownership cannot be replaced',()=>{
  for(const input of inputs){
   const declaration=input.presentation as {messages:string[];actors:string[];notes:Record<string,string>};
   const swapped=[...declaration.messages];[swapped[0],swapped[1]]=[swapped[1]!,swapped[0]!];
   expect(()=>sequenceModel(input.model,{...declaration,messages:swapped})).toThrow('source message order');
   expect(()=>sequenceModel(input.model,{...declaration,actors:declaration.actors.slice(1)})).toThrow();
   expect(()=>sequenceModel(input.model,{...declaration,notes:{}})).toThrow('Unaccounted');
   expect(()=>sequenceModel(input.model,{...declaration,notes:{[Object.keys(declaration.notes)[0]!]: 'unregistered-owner'}})).toThrow();
  }
 });
});
