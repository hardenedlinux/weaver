import {test,expect} from 'bun:test';
import fc from 'fast-check';
import {bindD2SVG,bindSceneSVG} from '../src/source/d2-svg';
const escaped=(s:string)=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&#34;').replaceAll("'",'&#39;');
const group=(id:string)=>`<g class="${Buffer.from(escaped(id)).toString('base64')}"></g>`;
function fixture(a:string,b:string):Parameters<typeof bindD2SVG>[0]{
 const id=`(${a} -> ${b})[0]`;
 return {view:{id:'view',source:'docs/view.d2',title:'Captured view',kind:'flow',sha256:'a'.repeat(64)},nodes:[{id:a,label:a,type:'rectangle'},{id:b,label:b,type:'rectangle'}],edges:[{id,source:a,target:b,label:'Bound relationship'}],svg:`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 480">${group(a)}${group(b)}${group(id)}</svg>`};
}
test('property: real D2 group bindings retain source identities and endpoints',()=>{
 const id=fc.array(fc.constantFrom('a','b','é','中','<','>','"','&'),{minLength:1,maxLength:8}).map(xs=>xs.join(''));
 fc.assert(fc.property(fc.uniqueArray(id,{minLength:2,maxLength:2}),([a,b])=>{
  const scene=fixture(a!,b!),svg=bindD2SVG(scene,{});
  expect(svg).toContain(`data-source-node="${escaped(a!)}"`);
  expect(svg).toContain(`data-source-from="${escaped(a!)}" data-source-to="${escaped(b!)}"`);
  expect(()=>bindD2SVG({...scene,svg:scene.svg.replace(group(a!), '')},{})).toThrow();
  expect(()=>bindD2SVG({...scene,svg:scene.svg.replace('</svg>',group(a!)+'</svg>')},{})).toThrow();
 }),{numRuns:100,seed:293});
});
test('captured assets are bundled and uncaptured URLs refuse',()=>{
 const scene=fixture('a','b');scene.svg=scene.svg.replace('</svg>','<image href="assets/go.svg"/></svg>');
 expect(bindD2SVG(scene,{'docs/assets/go.svg':'<svg/>'})).toContain('data:image/svg+xml;base64,');
 expect(()=>bindD2SVG(scene,{})).toThrow('Uncaptured');
});
test('property: measured Library groups preserve exact identities and reject omissions',()=>{
 const id=fc.array(fc.constantFrom('a','é','中','<','>','"',"'",'&'),{minLength:1,maxLength:8}).map(xs=>xs.join(''));
 fc.assert(fc.property(fc.uniqueArray(id,{minLength:2,maxLength:2}),([a,b])=>{
  const scene=fixture(a!,b!),edge=scene.edges[0]!;
  const encode=(value:string)=>escaped(value).replaceAll('&#34;','&quot;');
  const first=`<g data-scene-node="${encode(a!)}"></g>`;
  const svg=`<svg xmlns="http://www.w3.org/2000/svg">${first}<g data-scene-node="${encode(b!)}"></g><g data-scene-edge="${encode(edge.id)}"><path d="M0 0L20 20"/></g></svg>`;
  expect(bindSceneSVG(scene,svg)).toContain(`data-source-from="${escaped(a!)}" data-source-to="${escaped(b!)}"`);
  expect(()=>bindSceneSVG(scene,svg.replace(first,''))).toThrow('omitted identity');
  expect(()=>bindSceneSVG(scene,svg.replace('</svg>',first+'</svg>'))).toThrow('repeated');
 }),{numRuns:100,seed:293});
});
