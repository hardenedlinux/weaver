const fs=require('node:fs');
const base='/opt/homebrew/Cellar/quint/0.33.0/libexec/lib/node_modules/@informalsystems/quint/dist/src/';
const {parsePhase1fromText}=require(base+'parsing/quintParserFrontend.js');
const {newIdGenerator}=require(base+'idGenerator.js');
const source='proofs/qunit/RoutineRoutingConfig.qnt';
const result=parsePhase1fromText(newIdGenerator(),fs.readFileSync(source,'utf8'),source);
if(result.errors.length)throw Error(JSON.stringify(result.errors));
fs.writeFileSync('proofs/evidence/routine-routing-config/raw-leaf-parsed.json',JSON.stringify({modules:result.modules},(_,v)=>typeof v==='bigint'?Number(v):v));
process.stdout.write('PASS: official parser phase one accepts raw current leaf\n');
