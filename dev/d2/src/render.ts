// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import {cpus} from 'node:os';
import {fileURLToPath} from 'node:url';
import {mkdir,writeFile,access,readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
import path from 'node:path';
import {chromium} from 'playwright';
import {compileFigureSource,composeFigure,selectFigureVariant} from '@deterministic-engineering/render';
import {iconPacks} from "@deterministic-engineering/render/icons";
import {exportFigure} from '@deterministic-engineering/render/export';
import {collectCatalog} from './source/catalog';
import {capturedViews} from './source/models';
import {themes} from '../themes';
import {composeSequence} from './sequence';
import {readingFigure,composeReadingView} from './reading';

const root=fileURLToPath(new URL('../../../',import.meta.url));
const licensing=await readFile(path.join(root,'LICENSE'),'utf8');
const tags=['SPDX-FileCopyrightText:','SPDX-License-Identifier:'].map(tag=>{
 const line=licensing.split('\n').find(line=>line.startsWith(tag+' '));
 if(!line||line.includes('--'))throw new Error('Invalid repository SPDX notice: '+tag);return line;
}).join('\n');
const svgNotice='<!--\n'+tags+'\nSPDX-FileComment: Weaver-authored diagram; embedded third-party fonts and marks retain their own terms.\n-->\n';
const {values}=parseArgs({args:process.argv.slice(2),options:{view:{type:'string',multiple:true}}});
const catalog=collectCatalog(root,values.view);
const selected=catalog.views.filter(view=>!values.view||values.view.includes(view.source));
if(!selected.length||values.view&&selected.length!==new Set(values.view).size)throw new Error('Unknown requested view');
const hash=(bytes:string|Uint8Array)=>createHash('sha256').update(bytes).digest('hex');
const count=Math.min(cpus().length,selected.length);
const images:{source:string;theme:string;layout:string;sourceSHA256:string;svgSHA256:string;pngSHA256:string;nodes:number;edges:number;libraryInputSHA256:string}[]=[];
const errors:string[]=[];
const resources={themeLayers:themes,sysmlViews:capturedViews(catalog.modelCapture),iconPacks:{...iconPacks,weaver:Object.fromEntries(['go','rust','kubernetes'].map(name=>[name,{svg:catalog.fs['docs/architecture/diagrams/assets/'+name+'.svg']!,label:name}]))}};
const browser=await chromium.launch();
let cursor=0,cancelled=false;
const stop=()=>{cancelled=true;};process.on('SIGINT',stop);process.on('SIGTERM',stop);
try{
 await Promise.all(Array.from({length:count},async()=>{
  while(!cancelled){const view=selected[cursor++];if(!view)return;
   try{
    const input=readingFigure(await compileFigureSource({...catalog.fs,...catalog.documents},view.source,resources,{layout:'elk'}));
    if(input.layout!=='model-view'&&!(input.layout==='sequence-view'&&input.view.kind==='sequence'))throw new Error('Unmigrated declaration: '+input.layout);
    if(input.modelSource&&!Object.hasOwn(catalog.modelCapture?.mapped??{},view.source))throw new Error('Missing authoritative mapped source');
    const result=await exportFigure(composeFigure(input,input.layout==='sequence-view'?composeSequence:composeReadingView),browser);
    const exportedSVG=result.svg[0];if(!exportedSVG)throw new Error('Library exported no standalone SVG');
    const declaration=exportedSVG.startsWith('<?xml')?exportedSVG.indexOf('?>')+2:0;
    const svg=exportedSVG.slice(0,declaration)+svgNotice+exportedSVG.slice(declaration);
    const stem=path.join(root,view.source.slice(0,-3)),cache=path.join(root,'.cache/d2/images',view.source.slice(0,-3));
    await mkdir(path.dirname(cache),{recursive:true});
    await writeFile(stem+'.svg',svg);await writeFile(cache+'.png',result.png);await writeFile(cache+'.html',result.html);await writeFile(cache+'.json',JSON.stringify(result.receipt,null,2));
    if(await access(stem+'.png').then(()=>true,()=>false))await writeFile(stem+'.png',result.png);
    for(const variant of input.variants??[]){
     const exported=await exportFigure(composeFigure(readingFigure(selectFigureVariant(input,variant.name)),composeReadingView),browser);
     await writeFile(stem+'-'+variant.name+'.png',exported.png);await writeFile(cache+'-'+variant.name+'.html',exported.html);
    }
    images.push({source:view.source,theme:view.kind,layout:input.layout,sourceSHA256:view.sha256,svgSHA256:hash(svg),pngSHA256:hash(result.png),nodes:input.model?.subjects.length??0,edges:input.model?.relations.length??0,libraryInputSHA256:result.receipt.inputSHA256});
    console.log('[library] '+view.source);
   }catch(error:unknown){errors.push(view.source+': '+String(error));console.error(errors.at(-1));}
  }
 }));
}finally{await browser.close();process.off('SIGINT',stop);process.off('SIGTERM',stop);}
if(cancelled)errors.push('Cancelled after active library exports drained');
if(JSON.stringify(collectCatalog(root,values.view))!==JSON.stringify(catalog))errors.push('Captured inputs changed');
if(images.length!==selected.length)errors.push('Incomplete library export');
images.sort((a,b)=>a.source.localeCompare(b.source));
await mkdir(path.join(root,'.cache/d2'),{recursive:true});
await writeFile(path.join(root,'.cache/d2/typescript-render.json'),JSON.stringify({status:errors.length?'FAIL':'PASS',selection:values.view,modelCaptureSHA256:catalog.modelCapture?.sha256,hostCPUs:cpus().length,workers:count,engine:'@deterministic-engineering/render',images,errors},null,2));
if(errors.length)throw new Error('Library rendering failed; see cache receipt');
console.log(`PASS: ${images.length} library-driven images, ${count} host lanes`);
