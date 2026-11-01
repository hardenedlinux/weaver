import {cpus} from 'node:os';
import {fileURLToPath} from 'node:url';
import {mkdir,writeFile,access} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
import path from 'node:path';
import {chromium} from 'playwright';
import {exportFigure} from '@deterministic-engineering/render/export';
import {collectCatalog} from './source/catalog';
import {CompilationOwner} from './compiler';
import {composeProjectFigure} from './figures';
import {bindSceneSVG} from './source/d2-svg';
const root=fileURLToPath(new URL('../../../',import.meta.url));
const catalog=collectCatalog(root);
const {values}=parseArgs({args:process.argv.slice(2),options:{view:{type:'string',multiple:true}}});
const indexes=catalog.views.flatMap((view,index)=>!values.view||values.view.includes(view.source)?[index]:[]);
if(!indexes.length||values.view&&indexes.length!==new Set(values.view).size)throw new Error('Unknown requested view');
const hash=(bytes:string|Uint8Array)=>createHash('sha256').update(bytes).digest('hex');
const compiler=new CompilationOwner(catalog),browser=await chromium.launch();
const count=Math.min(cpus().length,indexes.length);
const images:{source:string;theme:string;sourceSHA256:string;svgSHA256:string;pngSHA256:string;nodes:number;edges:number;libraryInputSHA256:string}[]=[];
const errors:string[]=[];
let cursor=0,cancelled=false;
const stop=()=>{cancelled=true;};process.on('SIGINT',stop);process.on('SIGTERM',stop);
try{
 await Promise.all(Array.from({length:count},async()=>{
  while(!cancelled){const index=indexes[cursor++];if(index===undefined)return;
   try{
    const scene=await compiler.compile(index),figure=composeProjectFigure(scene);
    const result=await exportFigure(figure,browser);
    const svg=scene.figure.layout?.startsWith('readme-')?bindSceneSVG(scene,result.svg[0]??''):scene.svg;
    const stem=path.join(root,scene.view.source.slice(0,-3)),cache=path.join(root,'.cache/d2/images',scene.view.source.slice(0,-3));
    await mkdir(path.dirname(cache),{recursive:true});
    await writeFile(stem+'.svg',svg);await writeFile(cache+'.png',result.png);await writeFile(cache+'.html',result.html);await writeFile(cache+'.json',JSON.stringify(result.receipt,null,2));
    if(scene.figure.layout!=='native-d2'||await access(stem+'.png').then(()=>true,()=>false))await writeFile(stem+'.png',result.png);
    for(const variant of scene.figure.variants??[]){
     const image=await exportFigure(composeProjectFigure(scene,variant),browser);
     await writeFile(stem+'-'+variant.name+'.png',image.png);
     await writeFile(cache+'-'+variant.name+'.html',image.html);
    }
    images.push({source:scene.view.source,theme:scene.view.kind,sourceSHA256:scene.view.sha256,svgSHA256:hash(svg),pngSHA256:hash(result.png),nodes:scene.nodes.length,edges:scene.edges.length,libraryInputSHA256:result.receipt.inputSHA256});
    console.log('[library] '+scene.view.source);
   }catch(error:unknown){errors.push(catalog.views[index]!.source+': '+String(error));console.error(errors.at(-1));}
  }
 }));
}finally{await compiler.close();await browser.close();process.off('SIGINT',stop);process.off('SIGTERM',stop);}
if(cancelled)errors.push('Cancelled after active library exports drained');
if(JSON.stringify(collectCatalog(root))!==JSON.stringify(catalog))errors.push('Captured inputs changed');
if(images.length!==indexes.length)errors.push('Incomplete library export');
images.sort((a,b)=>a.source.localeCompare(b.source));
await mkdir(path.join(root,'.cache/d2'),{recursive:true});
await writeFile(path.join(root,'.cache/d2/typescript-render.json'),JSON.stringify({status:errors.length?'FAIL':'PASS',hostCPUs:cpus().length,workers:count,engine:'@deterministic-engineering/render',images,errors},null,2));
if(errors.length)throw new Error('Library rendering failed; see cache receipt');
console.log(`PASS: ${images.length} library-driven images, ${count} host lanes, no HTTP service`);
