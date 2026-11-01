import type {FigureComposer,FigureContext} from '@deterministic-engineering/render';
import type {Scene,SourceNode} from '../source/types';
type Composition=ReturnType<FigureComposer>;
export function gatewayComposition(context:FigureContext,scene:Scene,matrix:boolean):Composition{
 const {text,icon,copy,question}=context;
 const node=(id:string)=>{const found=scene.nodes.find(n=>n.id===id);if(!found)throw new Error('Missing gateway subject: '+id);return found;};
 const label=(n:SourceNode)=>n.label.replaceAll('\\n','\n').split('\n');
 const title=(id:string)=>id==='runtime'?copy('runtime-title'):label(node(id))[0]??id;
 const item=(n:SourceNode)=>{const [name,...detail]=label(n);return `<div data-node="${text(n.id)}" data-surface class="subject"><strong>${text(name??n.id)}</strong>${detail.length?`<small>${text(detail.join(' · '))}</small>`:''}</div>`;};
 const children=(id:string)=>scene.nodes.filter(n=>n.parent===id&&n.type!=='image'&&n.type!=='text');
 const brands=(id:string)=>scene.nodes.filter(n=>n.parent===id&&n.type==='image').map(n=>`<span data-source-node="${text(n.id)}" class="brand">${icon(n.id)}</span>`).join('');
 const panel=(id:string,glyph:string)=>`<section data-panel data-source-node="${text(id)}" class="owner ${text(id)}"><h2>${icon(glyph)}${text(title(id))}${brands(id)}</h2>${children(id).map(item).join('')}</section>`;
 const header=`<header><span data-badge>${icon('question')} WEAVER / ARCHITECTURE QUESTION</span><h1 data-heading>${text(question(scene.figure.view.question.ref).text)}</h1><p data-summary>${text(copy('takeaway'))}</p></header>`;
 const roots=['semantic','cloud','runtime','baseline','assurance','upstream'];roots.forEach(node);
 let content:string;
 if(matrix){
  const rootOf=(id:string)=>roots.find(root=>id===root||id.startsWith(root+'.'))??(()=>{throw new Error('Unscoped relationship: '+id);})();
  const entries=scene.edges.flatMap(edge=>{
   const first={from:rootOf(edge.source),to:rootOf(edge.target),label:edge.label};
   if(edge.sourceArrow&&!edge.targetArrow)return [{...first,from:first.to,to:first.from}];
   return edge.sourceArrow&&edge.targetArrow&&first.from!==first.to?[first,{...first,from:first.to,to:first.from}]:[first];
  });
  const axes=roots.filter(root=>entries.some(e=>e.from===root||e.to===root));
  content=`<section data-question="${text(scene.figure.view.question.ref)}" data-region="diagram" class="matrix"><table><thead><tr><th>Declared source ↓ / target →</th>${axes.map(id=>`<th>${text(copy('matrix.'+id))}</th>`).join('')}</tr></thead><tbody>${axes.map(from=>`<tr><th>${text(copy('matrix.'+from))}</th>${axes.map(to=>`<td>${entries.filter(e=>e.from===from&&e.to===to).map(e=>`<span>${text(e.label)}</span>`).join('')||'—'}</td>`).join('')}</tr>`).join('')}</tbody></table><div class="constraints">${panel('baseline','decision')}</div></section>`;
 }else{
  const roles=[
   {id:'semantic',brand:'library',items:[['semantic.evidence','document'],['semantic.composition','model'],['semantic.source','capture']]},
   {id:'cloud',brand:'cloud.brand',items:[['cloud.discovery','model'],['cloud.identity','capture'],['cloud.distribution','selection']]},
   {id:'runtime',brand:'runtime.brand',items:[['runtime.authority','decision'],['runtime.ledger','evidence'],['runtime.broker','capture']]},
  ];
  const role=(entry:typeof roles[number])=>{
   node(entry.id);entry.items.forEach(([id])=>node(id!));
   return `<section class="role" data-panel data-surface data-node="${text(entry.id)}"><div class="role-heading"><span class="role-brand">${icon(entry.brand)}</span><div><h2>${text(copy('role.'+entry.id+'.title'))}</h2><p>${text(copy('role.'+entry.id+'.subtitle'))}${entry.id==='cloud'?`<span class="kube">${icon('cloud.kube')}</span>`:''}</p></div></div><ul>${entry.items.map(([id,glyph])=>`<li data-source-node="${text(id!)}">${icon(glyph!)}<div><strong>${text(copy('short.'+id))}</strong><small>${text(copy('detail.'+id))}</small></div></li>`).join('')}</ul></section>`;
  };
  const contracts=[
   {from:'semantic.composition',to:'cloud.distribution',owners:'Scheme → Go'},
   {from:'cloud.distribution',to:'runtime.coordinator',owners:'Go → Rust'},
   {from:'runtime.coordinator',to:'semantic.source',owners:'Rust ↔ Scheme'},
  ].map(contract=>{
   const edge=scene.edges.find(edge=>edge.source===contract.from&&edge.target===contract.to);
   if(!edge||!edge.targetArrow||Boolean(edge.sourceArrow)!==contract.owners.includes('↔'))throw new Error('Missing declared handoff: '+contract.owners);
   return `<div data-source-edge="${text(edge.id)}"><strong>${text(contract.owners)}</strong><span>${text(edge.label)}</span></div>`;
  }).join('');
  content=`<section data-question="${text(scene.figure.view.question.ref)}" data-region="diagram"><div class="roles">${roles.map(role).join('')}</div><div class="handoffs">${contracts}</div><div class="trust-band" data-summary><span class="trust-label">${icon('decision')}${text(copy('trust-title'))}</span>${[['baseline.policy','document'],['baseline.identity','capture'],['baseline.recovery','pending']].map(([id,glyph])=>`<span data-source-node="${text(id!)}">${icon(glyph!)}${text(copy('short.'+id))}</span>`).join('')}</div></section>`;

 }
 return {markup:`<main>${header}${content}</main>`,css:`main{padding:32px}header{margin-bottom:20px}[data-badge],h2{display:flex;align-items:center;gap:12px}[data-badge]{font-size:13px;color:var(--accent)}h1{font-size:30px;line-height:1.3;margin:12px 0}[data-summary]{padding:10px 0 16px;font-size:19px;line-height:1.45}.roles{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:32px}.role{padding:24px;border:1px solid var(--border);border-radius:var(--radius);background:var(--surface)}.role-heading{min-height:104px;box-sizing:border-box;display:flex;align-items:center;gap:20px;padding-bottom:20px;border-bottom:1px solid var(--border)}.role-heading h2{font-size:32px;min-height:0;margin:0 0 6px;color:var(--ink)}.role-heading p{display:flex;gap:10px;align-items:center;font-size:19px;color:var(--muted)}.kube .icon{width:28px;height:28px}.role-brand .icon{width:58px;height:58px}.role ul{list-style:none;padding:0;margin:20px 0 0}.role li{display:flex;gap:18px;align-items:flex-start;margin:0 0 20px}.role li>.icon{width:30px;height:30px;color:var(--accent)}.role li strong{display:block;font-size:22px;font-weight:600;line-height:1.3}.role li small{display:block;margin-top:7px;font-size:17px;line-height:1.4;color:var(--muted)}.handoffs{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:32px;margin-top:20px}.handoffs>div{display:flex;align-items:center;gap:16px;padding:12px 18px;border-left:3px solid var(--accent);background:var(--tint);font-size:18px;line-height:1.4}.handoffs strong{white-space:nowrap;color:var(--accent)}.trust-band{display:flex;gap:30px;align-items:center;flex-wrap:wrap;padding:20px 26px;margin-top:28px;background:var(--tint);border-radius:var(--radius)}.trust-band>span{display:flex;align-items:center;gap:12px;font-size:17px}.trust-label{font-weight:600;color:var(--accent)}.scope{margin-top:20px;font-size:15px;color:var(--muted)}.architecture{display:grid;grid-template-columns:3fr 1.2fr;gap:24px}.control{display:grid;grid-template-columns:1fr 1fr;gap:24px}.owner{padding:22px;border:1px solid var(--border);border-radius:var(--radius);background:var(--surface)}h2{font-size:18px;min-height:48px;margin-bottom:18px;color:var(--accent)}.subject{padding:16px 18px;margin-bottom:12px;border:1px solid var(--border);border-radius:var(--radius);background:var(--tint)}.subject strong{display:block;font-size:20px;line-height:1.3}.subject small{display:block;margin-top:8px;font-size:16px;line-height:1.45;color:var(--muted)}.brand{margin-left:auto;display:inline-flex}.brand+.brand{margin-left:0}.brand .icon{width:34px;height:34px}.runtime{grid-column:1/-1;background:var(--tint)}.runtime-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px 30px}.assurance{grid-column:1/-1;display:grid;grid-template-columns:1fr 1fr;gap:16px 32px}.assurance h2{grid-column:1/-1;margin:0}.baseline{background:var(--secondaryTint)}footer{margin-top:24px}footer p{font-size:13px;line-height:1.5;margin:10px 0;color:var(--muted)}.matrix table{width:100%;table-layout:fixed;border-collapse:collapse}.matrix th,.matrix td{padding:16px 12px;border:1px solid var(--border);vertical-align:top;font-size:15px;line-height:1.45}.matrix th{background:var(--tint);font-size:16px}.matrix td span{display:block;margin-bottom:10px}.constraints{margin-top:20px}.constraints .owner{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px}.constraints h2{grid-column:1/-1}.legend{margin-top:18px;font-size:15px;color:var(--muted)}`};
}
