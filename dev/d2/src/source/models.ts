import {createHash} from 'node:crypto';
export interface ModelCapture {
 readonly modelHash:string;
 readonly sources:Readonly<Record<string,string>>;
 readonly views:Readonly<Record<string,unknown>>;
 readonly sha256:string;
}
const object=(value:unknown):value is Record<string,unknown>=>Boolean(value)&&typeof value==='object'&&!Array.isArray(value);
const hash=(value:string)=>createHash('sha256').update(value).digest('hex');

/** Transport/cohort validation only. The Library owns SDK model interpretation. */
export function readModelCapture(raw:string,expected:string,documents:Readonly<Record<string,string>>):ModelCapture {
 if(!/^[a-f0-9]{64}$/.test(expected)||hash(raw)!==expected)throw new Error('SDK capture differs from the Go owner receipt');
 const value:unknown=JSON.parse(raw);
 if(!object(value)||typeof value.modelHash!=='string'||!value.modelHash.trim()||!object(value.sources)||!object(value.views))throw new Error('Invalid SDK capture envelope');
 const modelSources=Object.entries(documents).filter(([name])=>name.endsWith('.sysml'));
 const sources:Record<string,string>={};
 if(Object.keys(value.sources).length!==modelSources.length)throw new Error('SDK source cohort differs');
 for(const [name,text]of modelSources){const digest=value.sources[name];if(typeof digest!=='string'||digest!==hash(text))throw new Error('SDK source changed: '+name);sources[name]=digest;}
 return {modelHash:value.modelHash,sources,views:value.views,sha256:expected};
}
