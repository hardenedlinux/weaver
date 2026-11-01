import {test,expect,beforeAll,afterAll,describe} from 'bun:test';
import {fileURLToPath} from 'node:url';
import {collectCatalog} from '../src/source/catalog';
import {CompilationOwner} from '../src/compiler';
import {composeProjectFigure} from '../src/figures';
import type {Scene} from '../src/source/types';
let owner:CompilationOwner|undefined,scene:Scene|undefined,gateway:Scene|undefined;
function captured():Scene{if(!scene)throw new Error('Missing captured source');return scene;}
beforeAll(async()=>{
 const catalog=collectCatalog(fileURLToPath(new URL('../../../',import.meta.url)));
 owner=new CompilationOwner(catalog);
 scene=await owner.compile(catalog.views.findIndex(v=>v.source.endsWith('/12-execution-correspondence.d2')));
});
afterAll(async()=>{await owner?.close();});
test('actual D2 Question and declared hand-drawn style drive the library',()=>{
 const input=captured(),figure=composeProjectFigure(input);
 expect(figure.html).toContain(input.figure.view.question.text);
 expect(figure.drawing.mode).toBe('sketch');
 expect(figure.fonts.some(font=>font.family==='Kalam')).toBe(true);
 expect(figure.html).not.toContain('<footer>');
});
test('domain extension rejects lost nodes and relationships',()=>{
 const input=captured();
 expect(()=>composeProjectFigure({...input,nodes:input.nodes.slice(1)})).toThrow('node inventory');
 expect(()=>composeProjectFigure({...input,edges:input.edges.slice(1)})).toThrow('relationship inventory');
});
test('declared node-editor variant reuses the library theme',()=>{
 const input=captured(),variant=input.figure.variants?.find(v=>v.name==='node-editor');
 if(!variant)throw new Error('Source has no declared node-editor variant');
 const figure=composeProjectFigure(input,variant);
 expect(figure.drawing.mode).toBe('precise');
 expect(figure.html).toContain('[data-node]:before');
});
describe('gateway responsibility composition',()=>{
 beforeAll(async()=>{
  const catalog=collectCatalog(fileURLToPath(new URL('../../../',import.meta.url)));
  gateway=await owner!.compile(catalog.views.findIndex(v=>v.source.endsWith('/01-system-boundaries.d2')));
 });
test('responsibility view shows source-bound handoffs and rejects reversed contracts',()=>{
 if(!gateway)throw new Error('Missing captured gateway');
 const figure=composeProjectFigure(gateway);
 for(const label of ['Admitted closure','Admitted publication','Source guards'])expect(figure.html).toContain(label);
 expect(figure.html).toContain('min-height:104px');
 const changed={...gateway,edges:gateway.edges.map(edge=>edge.source==='semantic.composition'&&edge.target==='cloud.distribution'?{...edge,targetArrow:false}:edge)};
 expect(()=>composeProjectFigure(changed)).toThrow('Missing declared handoff');
});
test('theme variants preserve captured technology logos alongside library icon packs',()=>{
 if(!gateway)throw new Error('Missing gateway capture');
 for(const variant of gateway.figure.variants??[]){
  const figure=composeProjectFigure(gateway,variant);
  expect(figure.html).toContain('cloud.brand');
  expect(figure.html).toContain('runtime.brand');
 }
});
});
