import {gatewayComposition} from './compositions/gateway';
import {composeFigure,type ComposedFigure,type FigureInput} from '@deterministic-engineering/render';
import {questionMap} from './compositions/question-map';
import type {Scene} from './source/types';

/** Weaver extension: a question-specific execution/proof composition, never a graph engine. */
export function composeProjectFigure(scene:Scene,variant?:NonNullable<FigureInput['variants']>[number]):ComposedFigure{
 let input=variant?{...scene.figure,theme:variant.theme,layout:variant.layout??scene.figure.layout,icons:{...scene.figure.icons,...variant.icons}}:scene.figure;
 const ids=new Set(scene.nodes.map(n=>n.id));
 if(input.model?.subjects.some(n=>!ids.has(n.id))||input.model?.subjects.length!==ids.size)throw new Error('Figure replaced the captured node inventory');
 const owner=(id:string)=>ids.has(id)?id:[...ids].filter(n=>id.startsWith(n+'.')).sort((a,b)=>b.length-a.length)[0]??id;
 if(input.model?.relations.length!==scene.edges.length||input.model.relations.some(edge=>!scene.edges.some(e=>e.id===edge.id&&e.source===owner(edge.src)&&e.target===owner(edge.dst)&&e.label===edge.label)))throw new Error('Figure replaced the captured relationship inventory');
 if(input.layout==='question-map')return composeFigure(input,questionMap);
 if(input.layout==='gateway-responsibility-map'||input.layout==='gateway-relationship-matrix')return composeFigure(input,context=>gatewayComposition(context,scene,input.layout==='gateway-relationship-matrix'));
 if(input.layout==='d2'){
  const dimensions=scene.svg.match(/viewBox="0 0 ([\d.]+) ([\d.]+)"/);
  if(!dimensions)throw new Error('D2 has no finite viewport');
  const width=Math.ceil(Number(dimensions[1]));
  input={...input,width:Math.min(4096,Math.max(input.width,width+64))};
  return composeFigure(input,({question,text,copy,icon})=>({markup:`<main><h1 data-heading>${icon('question')}${text(question(input.view.question.ref).text)}</h1><section data-question="${text(input.view.question.ref)}" data-region="diagram" class="d2-view">${scene.svg.replace(/<\?xml[^>]*>/,'')}</section></main>`,css:`main{padding:32px}h1{display:flex;gap:16px;align-items:center;font-size:26px;margin-bottom:24px}.d2-view{width:${Math.min(width,input.width-64)}px;max-width:100%}.d2-view>svg{width:100%;height:auto}[data-summary]{margin-top:24px;padding:16px;font-size:15px;line-height:1.5}` }));
 }
 if(input.layout!=='execution-proof-correspondence')throw new Error('Unsupported Weaver composition: '+input.layout);
 const p=input.presentation;
 if(!p||typeof p!=='object'||!('columns' in p)||!Array.isArray(p.columns)||!('icons' in p)||!Array.isArray(p.icons))throw new Error('Correspondence columns and icons must be declared');
 const columns=p.columns,icons=p.icons;
 if(columns.length!==3||icons.length!==3||new Set(columns).size!==columns.length||columns.some(id=>typeof id!=='string'||!ids.has(id))||icons.some(name=>typeof name!=='string'))throw new Error('Invalid correspondence declaration');
 const groups=columns.map(id=>scene.nodes.find(n=>n.id===id)!);
 const leaves=scene.nodes.filter(n=>n.parent);
 if(leaves.some(n=>!columns.includes(n.parent)))throw new Error('Correspondence omitted a declared owner');
 return composeFigure(input,({question,text,copy,icon})=>({markup:`<main><header><span data-badge>${icon('question')} WEAVER / DESIGN QUESTION</span><h1 data-heading>${text(question(input.view.question.ref).text)}</h1><p data-summary>${text(copy('takeaway'))}</p></header><section data-question="${text(input.view.question.ref)}" data-region="diagram" class="correspondence"><svg data-connections>${scene.edges.map(e=>`<path data-from="${text(e.source)}" data-to="${text(e.target)}" data-source-edge="${text(e.id)}"><title>${text(e.label)}</title></path>`).join('')}</svg>${groups.map((group,index)=>`<section class="owner" data-panel data-boundary data-node="${text(group.id)}"><h2>${icon(icons[index])}${text(group.label)}</h2>${leaves.filter(n=>n.parent===group.id).map(n=>{const [title,...detail]=n.label.replaceAll('\\n','\n').split('\n');return `<article data-node="${text(n.id)}" data-surface><h3>${text(title??n.id)}</h3><p>${text(detail.join(' · '))}</p></article>`;}).join('')}</section>`).join('')}</section></main>`,css:`main{padding:32px}header{margin-bottom:30px}header>[data-badge]{display:inline-flex;align-items:center;gap:10px;font-size:13px;color:var(--accent)}h1{font-size:30px;line-height:1.25;margin:14px 0 20px}[data-summary]{padding:16px;font-size:18px;line-height:1.5}.correspondence{position:relative;display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:80px}.owner{padding:16px;border:1px solid var(--border);border-radius:var(--radius);background:var(--tint)}h2{display:flex;align-items:center;gap:12px;font-size:17px;min-height:64px}article{position:relative;box-sizing:border-box;min-height:148px;margin:0 0 40px;padding:18px;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius)}h3{font-size:19px;line-height:1.3;margin:0 0 14px}article p{font-size:17px;line-height:1.45;color:var(--muted)}[data-connections]{position:absolute;inset:0;width:100%;height:100%;overflow:visible;pointer-events:none;z-index:4}[data-connections] path{stroke:var(--accent);stroke-width:1.4;fill:none}footer{margin-top:24px}footer p{font-size:14px;line-height:1.5;margin:10px 0;color:var(--muted)}` }));
}
