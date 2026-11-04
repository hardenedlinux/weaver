// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

import type {FigureInput} from '@deterministic-engineering/render';
import {composePresentationTheme} from '@deterministic-engineering/render/presentation-theme';
import type {ReaderDesign} from './models';
import {themes} from '../../themes';

/** Transport source-authored preferences to the public Library, retaining the
 * complete original graph. No node-index grid, coordinate or font-size repair. */
export function applyReaderDesign(input:FigureInput,design:ReaderDesign|undefined):FigureInput {
 if(input.layout==='sequence-view')return input;
 if(!design||!design.audience?.trim()||!design.medium?.trim()||!design.message?.trim()||!Number.isInteger(design.width)||design.width<600||design.width>1600||!Number.isInteger(design.textColumns)||design.textColumns<8||design.textColumns>120)throw new Error('Missing or invalid captured reader Design');
 if(!input.model)throw new Error('Reader Design needs a captured model');
 const p=input.presentation as {graph?:{layoutOptions?:Readonly<Record<string,string>>};options?:Readonly<Record<string,string>>};
 const sourceOwned=!!input.design;
 const options=sourceOwned?p.options:{...p.options,...design.options};
 const presentation={...p,textColumns:design.textColumns,options,...(p.graph?{graph:{...p.graph,layoutOptions:sourceOwned?p.graph.layoutOptions:{...p.graph.layoutOptions,...design.options}}}:{})};
 return {...input,width:sourceOwned?input.width:design.width,theme:sourceOwned?input.theme:composePresentationTheme(design.themes,themes),presentation,
  design:input.design??{audience:design.audience,medium:design.medium,message:design.message,questionRefs:input.questions.map(q=>q.ref),requiredSubjects:input.model.subjects.map(node=>node.id),requiredRelations:input.model.relations.map(edge=>edge.id),focalSubjects:[]}};
}
