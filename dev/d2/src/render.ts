import {cpus} from 'node:os';
import {fileURLToPath} from 'node:url';
import {mkdir,writeFile,access} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
import path from 'node:path';
import {chromium} from 'playwright';
import {compileFigureSource,composeFigure,composeModelView,selectFigureVariant} from '@deterministic-engineering/render';
import {iconPacks} from "@deterministic-engineering/render/icons";
import {exportFigure} from '@deterministic-engineering/render/export';
import {collectCatalog} from './source/catalog';
import {capturedViews} from './source/models';
import {themes} from '../themes';
import {composeSequence} from './sequence';

const root=fileURLToPath(new URL('../../../',import.meta.url));
const catalog=collectCatalog(root);
const {values}=parseArgs({args:process.argv.slice(2),options:{view:{type:'string',multiple:true}}});
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
    const input=await compileFigureSource({...catalog.fs,...catalog.documents},view.source,resources,{layout:'elk'});
    if(input.layout!=='model-view'&&!(input.layout==='sequence-view'&&input.view.kind==='sequence'))throw new Error('Unmigrated declaration: '+input.layout);
    if(input.modelSource&&!Object.hasOwn(catalog.modelCapture?.mapped??{},view.source))throw new Error('Missing authoritative mapped source');
    const result=await exportFigure(composeFigure(input,input.layout==='sequence-view'?composeSequence:composeModelView),browser);
    const svg=result.svg[0];if(!svg)throw new Error('Library exported no standalone SVG');
    const stem=path.join(root,view.source.slice(0,-3)),cache=path.join(root,'.cache/d2/images',view.source.slice(0,-3));
    await mkdir(path.dirname(cache),{recursive:true});
    await writeFile(stem+'.svg',svg);await writeFile(cache+'.png',result.png);await writeFile(cache+'.html',result.html);await writeFile(cache+'.json',JSON.stringify(result.receipt,null,2));
    if(await access(stem+'.png').then(()=>true,()=>false))await writeFile(stem+'.png',result.png);
    for(const variant of input.variants??[]){
     const exported=await exportFigure(composeFigure(selectFigureVariant(input,variant.name),composeModelView),browser);
     await writeFile(stem+'-'+variant.name+'.png',exported.png);await writeFile(cache+'-'+variant.name+'.html',exported.html);
    }
    images.push({source:view.source,theme:view.kind,layout:input.layout,sourceSHA256:view.sha256,svgSHA256:hash(svg),pngSHA256:hash(result.png),nodes:input.model?.subjects.length??0,edges:input.model?.relations.length??0,libraryInputSHA256:result.receipt.inputSHA256});
    console.log('[library] '+view.source);
   }catch(error:unknown){errors.push(view.source+': '+String(error));console.error(errors.at(-1));}
  }
 }));
}finally{await browser.close();process.off('SIGINT',stop);process.off('SIGTERM',stop);}
if(cancelled)errors.push('Cancelled after active library exports drained');
if(JSON.stringify(collectCatalog(root))!==JSON.stringify(catalog))errors.push('Captured inputs changed');
if(images.length!==selected.length)errors.push('Incomplete library export');
images.sort((a,b)=>a.source.localeCompare(b.source));
await mkdir(path.join(root,'.cache/d2'),{recursive:true});
await writeFile(path.join(root,'.cache/d2/typescript-render.json'),JSON.stringify({status:errors.length?'FAIL':'PASS',modelCaptureSHA256:catalog.modelCapture?.sha256,hostCPUs:cpus().length,workers:count,engine:'@deterministic-engineering/render',images,errors},null,2));
if(errors.length)throw new Error('Library rendering failed; see cache receipt');
console.log(`PASS: ${images.length} library-driven images, ${count} host lanes`);
