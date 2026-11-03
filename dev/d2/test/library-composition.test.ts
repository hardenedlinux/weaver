// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import {test,expect} from 'bun:test';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';
import {compileFigureSource,composeFigure,composeModelView} from '@deterministic-engineering/render';
import {exportFigure} from '@deterministic-engineering/render/export';
import {iconPacks} from '@deterministic-engineering/render/icons';
import {collectCatalog} from '../src/source/catalog';
import {capturedViews} from '../src/source/models';
import {themes} from '../themes';

// Preserve the complete original two-source acceptance boundary inside one
// standard five-second test; no prewarming or outside-hook compilation.
test('two real source captures export and release all owned compiler/browser resources',async()=>{
 const catalog=collectCatalog(fileURLToPath(new URL('../../../',import.meta.url)));
 const resources={themeLayers:themes,sysmlViews:capturedViews(catalog.modelCapture),iconPacks:{...iconPacks,weaver:Object.fromEntries(['go','rust','kubernetes'].map(name=>[name,{svg:catalog.fs['docs/architecture/diagrams/assets/'+name+'.svg']!,label:name}]))}};
 const browser=await chromium.launch();
 try{
  const outcomes=await Promise.allSettled(['12-execution-correspondence.d2','01-system-boundaries.d2'].map(async suffix=>{
   const view=catalog.views.find(view=>view.source.endsWith('/'+suffix));if(!view)throw new Error('Missing original source capture');
   const input=await compileFigureSource({...catalog.fs,...catalog.documents},view.source,resources,{layout:'elk'});
   const image=await exportFigure(composeFigure(input,composeModelView),browser);
   expect(image.svg[0]).toContain(view.source);
   expect(image.svg[0]).toContain('data-scene-node=');
   expect(image.receipt.observation.subjects.length).toBe(input.model!.subjects.length);
   expect(image.receipt.observation.relations.length).toBe(input.model!.relations.length);
  }));
  for(const outcome of outcomes)if(outcome.status==='rejected')throw outcome.reason;
 }finally{await browser.close();}
});
