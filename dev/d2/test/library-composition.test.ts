// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import {test,expect} from 'bun:test';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';
import {compileFigureSources,composeFigure,composeModelView} from '@deterministic-engineering/render';
import {exportFigure} from '@deterministic-engineering/render/export';
import {componentIcons} from '../src/source/components';
import {weaverIcons} from '../src/source/assets';
import {iconPacks} from '@deterministic-engineering/render/icons';
import {collectCatalog} from '../src/source/catalog';
import {capturedViews} from '../src/source/models';
import {themes} from '../themes';

// Preserve the complete original two-source acceptance boundary inside one
// standard five-second test; no prewarming or outside-hook compilation.
test('two real source captures export and release all owned compiler/browser resources',async()=>{
 const started=performance.now();
 const trace=(phase:string,source?:string)=>{
  if(process.env.WEAVER_VECTOR_TIMING==='1')console.error(JSON.stringify({phase,source,elapsed:Math.round(performance.now()-started)}));
 };
 const catalog=collectCatalog(fileURLToPath(new URL('../../../',import.meta.url)));
 const resources={themeLayers:themes,sysmlViews:capturedViews(catalog.modelCapture),iconPacks:{...iconPacks,weaver:weaverIcons(catalog.fs),components:componentIcons(catalog.fs)}};
 const browser=await chromium.launch();
 trace('browser-ready');
 try{
  const sources=['12-execution-correspondence.d2','01-system-boundaries.d2'].map(suffix=>{
   const view=catalog.views.find(view=>view.source.endsWith('/'+suffix));if(!view)throw new Error('Missing original source capture');
   return view.source;
  });
  const captures=await compileFigureSources({...catalog.fs,...catalog.documents},sources,resources,{layout:'dagre'});
  trace('compiler-batch-joined');
  const outcomes=await Promise.allSettled(captures.map(async input=>{
   const image=await exportFigure(composeFigure(input,composeModelView),browser);
   trace('export-complete',input.view.source);
   expect(image.svg[0]).toContain(input.view.source);
   expect(image.svg[0]).toContain('data-scene-node=');
   expect(image.receipt.observation.subjects.length).toBe(input.model!.subjects.length);
   expect(image.receipt.observation.relations.length).toBe(input.model!.relations.length);
  }));
  for(const outcome of outcomes)if(outcome.status==='rejected')throw outcome.reason;
 }finally{await browser.close();trace('browser-closed');}
});
