// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

import type {ModelCapture} from './models';
export const viewKinds=['system','routing','flow','sequence','state','data','assurance'] as const;
export type ViewKind=typeof viewKinds[number];
export function isViewKind(value:string):value is ViewKind{return viewKinds.some(kind=>kind===value);}
export interface ViewEntry{id:string;source:string;title:string;kind:ViewKind;sha256:string;}
export interface SourceCatalog{views:ViewEntry[];fs:Record<string,string>;documents:Record<string,string>;modelCapture?:ModelCapture;}
