import type {FigureInput} from '@deterministic-engineering/render';
export const viewKinds=['system','routing','flow','sequence','state','data','assurance'] as const;
export type ViewKind=typeof viewKinds[number];
export function isViewKind(value:string):value is ViewKind{return viewKinds.some(kind=>kind===value);}
export interface ViewEntry{id:string;source:string;title:string;kind:ViewKind;sha256:string;}
export interface SourceCatalog{views:ViewEntry[];fs:Record<string,string>;documents:Record<string,string>;}
export interface SourceNode{id:string;label:string;type:string;parent?:string;}
export interface SourceEdge{id:string;source:string;target:string;label:string;sourceArrow?:boolean;targetArrow?:boolean;}
export interface Scene{view:ViewEntry;figure:FigureInput;nodes:SourceNode[];edges:SourceEdge[];svg:string;}
