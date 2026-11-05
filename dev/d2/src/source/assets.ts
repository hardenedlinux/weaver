// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import type {IconPack} from '@deterministic-engineering/render/icons';

export const brandNames = Object.freeze(['go','rust','kubernetes'] as const);
export const illustrationNames = Object.freeze([
 'task-contract','route-choice','budget-ledger',
 'permission-check','bounded-write','model-provider','unknown-hold','model-catalog','agent-request',
] as const);
export const weaverIconNames = Object.freeze([...brandNames,...illustrationNames]);

/** Captured project vocabulary; drawing, measurement and export stay upstream. */
export function weaverIcons(sources:Readonly<Record<string,string>>):IconPack {
 return Object.fromEntries(weaverIconNames.map(name=>{
  const path='docs/architecture/diagrams/assets/'+name+'.svg',svg=sources[path];
  if(!svg)throw new Error('Missing captured illustration: '+path);
  return [name,{svg,label:name.replaceAll('-',' ')}];
 }));
}
