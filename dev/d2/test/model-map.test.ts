import {test,expect,beforeAll,afterAll} from 'bun:test';
import fc from 'fast-check';
import {fileURLToPath} from 'node:url';
import {partitionWords} from '../src/compositions/model-map';
import {collectCatalog} from '../src/source/catalog';
import {CompilationOwner} from '../src/compiler';
import {composeProjectFigure} from '../src/figures';
import type {Scene} from '../src/source/types';

const partition=fc.array(fc.constantFrom('original','claim','budget','history','owner','fence','Policy','digest'),{minLength:1,maxLength:30}).chain(words=>fc.subarray(Array.from({length:words.length-1},(_,i)=>i+1)).map(cuts=>({words,cuts:[...cuts,words.length]})));
test('property: source-authored breaks preserve every captured word exactly once',()=>{
 fc.assert(fc.property(partition,({words,cuts})=>{
  expect(partitionWords(words.join(' '),cuts).join(' ')).toBe(words.join(' '));
  expect(()=>partitionWords(words.join(' '),[0,...cuts])).toThrow();
  expect(()=>partitionWords(words.join(' '),[...cuts.slice(0,-1),words.length-1])).toThrow();
 }),{numRuns:100,seed:293});
});
let owner:CompilationOwner,scene:Scene;
beforeAll(async()=>{
 const catalog=collectCatalog(fileURLToPath(new URL('../../../',import.meta.url)));
 owner=new CompilationOwner(catalog);
 scene=await owner.compile(catalog.views.findIndex(v=>v.source.endsWith('/59.44-cloud-rpc-arrow-boundaries.d2')));
});
afterAll(async()=>{await owner?.close();});
test('actual D2 model uses Library scenes and retained relation captions',()=>{
 const result=composeProjectFigure(scene);
 expect(scene.svg).toBe('');expect(scene.figure.modelTrace).toBeUndefined();
 expect(result.html).toContain('data-scene');expect(result.html).not.toContain('data-d2-version');
 for(const edge of scene.edges)expect(result.html).toContain('data-relation-caption="'+edge.id.replaceAll('&','&amp;').replaceAll('"','&quot;').replaceAll('<','&lt;').replaceAll('>','&gt;')+'"');
});
test('caption partitions cannot omit source words or subjects',()=>{
 const bad=structuredClone(scene),p=bad.figure.presentation as {captions:Record<string,{title:number[];detail:number[]}>};
 delete p.captions.go;
 expect(()=>composeProjectFigure(bad)).toThrow('complete captured inventory');
 const changed=structuredClone(scene),q=changed.figure.presentation as {captions:Record<string,{title:number[];detail:number[]}>};
 q.captions.go!.title=[1];
 expect(()=>composeProjectFigure(changed)).toThrow('cover the captured wording');
});
test('source identities cannot be retained while their wording or arrows change',()=>{
 const wrong=structuredClone(scene),model=wrong.figure.model!;
 wrong.figure={...wrong.figure,model:{...model,subjects:model.subjects.map(node=>node.id==='go'?{...node,label:'Another owner'}:node)}};
 expect(()=>composeProjectFigure(wrong)).toThrow('captured subject wording');
 const reversed=structuredClone(scene),m=reversed.figure.model!;
 reversed.figure={...reversed.figure,model:{...m,relations:m.relations.map((edge,i)=>i===0?{...edge,dstArrow:'none'}:edge)}};
 expect(()=>composeProjectFigure(reversed)).toThrow('arrowhead notation');
});
test('connected subjects cannot disappear into annotation layout',()=>{
 const bad=structuredClone(scene),p=bad.figure.presentation as {annotations:Record<string,string>};p.annotations.go='constraint';
 expect(()=>composeProjectFigure(bad)).toThrow('Annotation cannot hide');
});
test('source paragraphs and typed member notation cannot silently disappear',()=>{
 const merged=structuredClone(scene),p=merged.figure.presentation as {captions:Record<string,{title:number[];detail:number[]}>};
 const cuts=p.captions.go!.detail;p.captions.go!.detail=[cuts.at(-1)!];
 expect(()=>composeProjectFigure(merged)).toThrow('captured paragraph boundary');
 const typed=structuredClone(scene),model=typed.figure.model!;
 typed.nodes=typed.nodes.map(node=>node.id==='go'?{...node,type:'class'}:node);
 typed.figure={...typed.figure,model:{...model,subjects:model.subjects.map(node=>node.id==='go'?{...node,type:'class'}:node)}};
 expect(()=>composeProjectFigure(typed)).toThrow('Typed member notation');
});

test.each(['59.63-mrr-admission-contract.d2','59.66-bounded-writer-reuse.d2','59.44-cloud-rpc-arrow-boundaries.d2','59.66-bounded-writer-reuse.d2'])('reclaimable scope preserves captured source %s across recycle',async suffix=>{
 const catalog=collectCatalog(fileURLToPath(new URL('../../../',import.meta.url)));
  const index=catalog.views.findIndex(view=>view.source.endsWith('/'+suffix));
  const captured=await owner.compile(index);
  expect(captured.view.source).toBe(catalog.views[index]!.source);
  expect(captured.nodes.length).toBeGreaterThan(0);
 expect(owner.observedPeakRSSBytes).toBeGreaterThan(0);
});
