// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import {test,expect} from 'bun:test';
import fc from 'fast-check';
import {readingGraph,readingLines} from '../src/reading';
import type {DiagramSpec} from '@deterministic-engineering/render';

test('property: reading wraps preserve all source characters and Unicode scalars',()=>{
 fc.assert(fc.property(fc.array(fc.constantFrom('a',' ',':','\n','\\n','→','𝛼','😀','界'),{maxLength:400}),fc.integer({min:1,max:60}),(pieces,width)=>{
  const source=pieces.join(''),lines=readingLines(source,width);
  expect(lines.join('')).toBe(source.replaceAll('\\n','\n').replaceAll('\n',''));
  expect(lines.every(line=>Array.from(line).length<=width)).toBe(true);
  expect(lines.every(line=>!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(line))).toBe(true);
 }),{numRuns:300,seed:293});
});

test('property: reading projection retains every scope, subject, edge and source record',()=>{
 fc.assert(fc.property(fc.integer({min:1,max:35}),count=>{
  const graph:DiagramSpec['graph']={id:'root',children:[{id:'scope',children:Array.from({length:count},(_,i)=>({id:'n'+i}))}],edges:Array.from({length:count},(_,i)=>({id:'e'+i,sources:['n'+i],targets:['n'+((i+1)%count)]}))};
  const original=structuredClone(graph),result=readingGraph({graph});
  expect(result.graph.children!.map(node=>node.id)).toEqual(['scope',...Array.from({length:count},(_,i)=>'n'+i)]);
  expect(result.graph.edges).toEqual(original.edges);
  expect(graph).toEqual(original);
  expect(result.graph.layoutOptions?.['org.eclipse.elk.layered.layering.coffmanGraham.layerBound']).toBe('1');
 }),{numRuns:100,seed:293});
});

test('declared core column views keep their own graph presentation',()=>{
 const graph:DiagramSpec['graph']={id:'core',children:[{id:'a'},{id:'b'}],layoutOptions:{'elk.partitioning.activate':'true'}};
 const specification={graph};expect(readingGraph(specification)).toBe(specification);
});
