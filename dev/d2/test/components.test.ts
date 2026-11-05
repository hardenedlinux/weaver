// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import {expect,test} from 'bun:test';
import fc from 'fast-check';
import {readFileSync} from 'node:fs';
import {componentAssetPaths,componentIcons,componentVocabulary} from '../src/source/components';
import {brandNames,illustrationNames} from '../src/source/assets';
import {composeIconPacks,iconPacks} from '@deterministic-engineering/render/icons';

const root=new URL('../../../',import.meta.url);
const sources=Object.fromEntries(componentAssetPaths.map(path=>[path,readFileSync(new URL(path,root),'utf8')]));
const roles=Object.keys(componentVocabulary) as (keyof typeof componentVocabulary)[];

test('routing, identity, authorization and observation have distinct functional symbols',()=>{
 expect(componentVocabulary.routing.file).toBe('route');
 expect(componentVocabulary.routing.file as string).not.toBe('router');
 expect(componentVocabulary.telemetry.file).toBe('activity');
 expect(new Set(roles.map(role=>componentVocabulary[role].file)).size).toBe(roles.length);
 expect(roles.filter(role=>([...brandNames,...illustrationNames] as string[]).includes(role))).toEqual([]);
 const combined=composeIconPacks(['engineering','components'],{...iconPacks,components:componentIcons(sources)});
 for(const role of roles)expect(combined[role]!.svg).toBe(sources['docs/architecture/diagrams/assets/components/'+componentVocabulary[role].file+'.svg']!);
});

test('property: every declared component keeps its captured vector and license; missing assets fail closed',()=>{
 fc.assert(fc.property(fc.shuffledSubarray(roles,{minLength:1,maxLength:roles.length}),selected=>{
  const changed={...sources};
  for(const role of selected){
   const asset=componentVocabulary[role],path='docs/architecture/diagrams/assets/components/'+asset.file+'.svg';
   expect(asset.source.endsWith('/icons/'+asset.file+'.svg')).toBe(true);
   expect(sources[path]!).toContain('viewBox="0 0 24 24"');
   expect(readFileSync(new URL(path+'.license',root),'utf8')).toContain('SPDX-License-Identifier:');
   delete changed[path];
  }
  expect(()=>componentIcons(changed)).toThrow('Missing canonical component icon:');
 }),{numRuns:100,seed:293});
});
