import {test,expect} from 'bun:test';
import fc from 'fast-check';
import {fileURLToPath} from 'node:url';
import {compileFigureSource} from '@deterministic-engineering/render';
import {renderedViewFromJson} from '@openmbee/opensysml';
import {collectCatalog} from '../src/source/catalog';
import {bindModelView} from '../src/source/model-view';
import {compileLibraryView} from '../src/source/library-view';
import {composeProjectFigure} from '../src/figures';
import {themes} from '../themes';
const catalog=collectCatalog(fileURLToPath(new URL('../../../',import.meta.url)));
const source='docs/architecture/diagrams/00a-readme-overview.d2';
const entry=catalog.views.find(view=>view.source===source)!;
const input=await compileFigureSource({...catalog.fs,...catalog.documents},source,{themeLayers:themes});
const captured=catalog.modelCapture;
if(!captured)throw new Error('Run model-view tests through the Go-owned SDK capture entrypoint');

test('published Library projects the actual SDK model without a D2 topology copy',async()=>{
 const scene=await compileLibraryView(catalog,entry),native=renderedViewFromJson(captured.views['WeaverViews::architecture']);
 expect(scene.nodes.map(node=>node.id)).toEqual(native.nodes.map(node=>node.id));
 expect(scene.edges.map(edge=>[edge.source,edge.target])).toEqual(native.edges.map(edge=>[edge.from,edge.to]));
 const html=composeProjectFigure(scene).html;
 expect(html).toContain('data-scene');expect(html).not.toContain('data-d2-version');
 expect(scene.figure.modelTrace?.modelHash).toBe(captured.modelHash);
 expect(scene.figure.sources[scene.figure.references.sdkCapture!]).toBe(scene.figure.modelTrace?.capturedRenderingJSON);
});

test('missing, duplicate or renamed native subjects cannot silently rebind captions',()=>{
 fc.assert(fc.property(fc.integer({min:0,max:9}),index=>{
  const changed=structuredClone(captured),native=changed.views['WeaverViews::architecture'] as {nodes:{name:string}[]};
  native.nodes[index]!.name+=' changed';
  expect(()=>bindModelView(input,changed)).toThrow('caption selector');
 }),{numRuns:100,seed:293});
 expect(()=>bindModelView(input,undefined)).toThrow('Go-owned SDK');
});

test('undeclared port ownership is refused by the public projection',()=>{
 const changed=structuredClone(captured),native=changed.views['WeaverViews::architecture'] as {edges:{fromPort:string}[]};
 native.edges[0]!.fromPort='unknown-port';
 expect(()=>bindModelView(input,changed)).toThrow('port does not belong');
});

test('container display projection cannot hide a model relationship',async()=>{
 const scene=await compileLibraryView(catalog,entry),model=scene.figure.model!;
 const root=model.subjects.find(node=>!node.parent)!,leaf=model.subjects.find(node=>node.parent===root.id)!;
 const figure={...scene.figure,model:{...model,relations:[...model.relations,{id:'incident-root',src:root.id,dst:leaf.id,label:'bound',srcArrow:'none' as const,dstArrow:'none' as const}]}};
 expect(()=>composeProjectFigure({...scene,figure,edges:[...scene.edges,{id:'incident-root',source:root.id,target:leaf.id,label:'bound'}]})).toThrow('incident relation');
});
