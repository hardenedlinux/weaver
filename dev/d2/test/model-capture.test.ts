import {test,expect} from 'bun:test';
import {createHash} from 'node:crypto';
import fc from 'fast-check';
import {readModelCapture} from '../src/source/models';
const hash=(value:string)=>createHash('sha256').update(value).digest('hex');
test('property: image jobs accept only the Go-owned capture and exact source cohort',()=>{
 fc.assert(fc.property(fc.array(fc.string({maxLength:80}),{minLength:1,maxLength:8}),texts=>{
  const documents=Object.fromEntries(texts.map((text,index)=>['models/m'+index+'.sysml',text]));
  const raw=JSON.stringify({modelHash:'sdk-model',sources:Object.fromEntries(Object.entries(documents).map(([name,text])=>[name,hash(text)])),views:{view:{}}});
  const digest=hash(raw),capture=readModelCapture(raw,digest,documents);
  expect(capture.modelHash).toBe('sdk-model');
  expect(capture.sha256).toBe(digest);
  expect(()=>readModelCapture(raw+' ',digest,documents)).toThrow('Go owner receipt');
  expect(()=>readModelCapture(raw,digest,{...documents,'models/m0.sysml':texts[0]+';'})).toThrow('SDK source changed');
  expect(()=>readModelCapture(raw,digest,{...documents,'models/new.sysml':'package New {}'})).toThrow('cohort differs');
 }),{numRuns:100,seed:293});
});
test('malformed capture metadata cannot stand in for an SDK result',()=>{
 for(const value of [[],null,{}, {modelHash:'',sources:{},views:{}},{modelHash:'m',sources:{},views:[]}]){
  const raw=JSON.stringify(value);
  expect(()=>readModelCapture(raw,hash(raw),{})).toThrow('Invalid SDK capture envelope');
 }
});
