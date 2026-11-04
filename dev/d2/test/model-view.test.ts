// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import {test,expect} from 'bun:test';
import {fileURLToPath} from 'node:url';
import {compileFigureSource,composeFigure,composeModelView} from '@deterministic-engineering/render';
import {collectCatalog} from '../src/source/catalog';
import {capturedViews} from '../src/source/models';
import {iconPacks} from '@deterministic-engineering/render/icons';
import {themes} from '../themes';
const catalog=collectCatalog(fileURLToPath(new URL('../../../',import.meta.url)));
const source='docs/architecture/diagrams/00a-readme-overview.d2';
const sources={...catalog.fs,...catalog.documents};
const views=capturedViews(catalog.modelCapture);
const resources={themeLayers:themes,sysmlViews:views,iconPacks:{...iconPacks,weaver:Object.fromEntries(['go','rust','kubernetes'].map(name=>[name,{svg:catalog.fs['docs/architecture/diagrams/assets/'+name+'.svg']!,label:name}]))}};
const input=await compileFigureSource(sources,source,resources);
const sdkCapture=views['WeaverViews::architecture']!;

test('public Library binds SDK SysML identity, ownership and ordered endpoints',()=>{
 expect(input.model!.subjects.map(node=>node.id)).toEqual(sdkCapture.rendering.nodes.map(node=>node.id));
 expect(input.model!.relations.map(edge=>[edge.src,edge.dst])).toEqual(sdkCapture.rendering.edges.map(edge=>[edge.from,edge.to]));
 expect(input.modelSource?.modelHash).toBe(sdkCapture.modelHash);
 expect(input.sources[input.references.sdkCapture!]).toBe(input.modelTrace?.capturedRenderingJSON);
 expect(composeFigure(input,composeModelView).drawing.mode).toBe('sketch');
});

test('altered capture bytes cannot bind to the Go source commitment',async()=>{
 const changed=structuredClone(views);changed['WeaverViews::architecture']!.rendering.nodes[0]!.name+=' replacement';
 await expect(compileFigureSource(sources,source,{...resources,sysmlViews:changed})).rejects.toThrow('source bytes');
});

test('missing captured views and unsupported source ports refuse instead of switching engines',async()=>{
 await expect(compileFigureSource(sources,source,{...resources,sysmlViews:undefined})).rejects.toThrow('binding mismatch');
 const changed=structuredClone(views),selected=changed['WeaverViews::architecture']!;
 selected.rendering.edges[0]!.fromPort='unowned-port';
 const documents={...sources,[input.references.sdkCapture!]:JSON.stringify(selected)};
 await expect(compileFigureSource(documents,source,{...resources,sysmlViews:changed})).rejects.toThrow('port does not belong');
});
