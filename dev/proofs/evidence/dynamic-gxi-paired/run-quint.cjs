// Execute the installed official pipeline once, then independent fresh evaluators.
const fs=require('node:fs'),crypto=require('node:crypto');
const base='/opt/homebrew/Cellar/quint/0.33.0/libexec/lib/node_modules/@informalsystems/quint/dist/src/';
const cli=require(base+'cliCommands.js');
const out='proofs/evidence/dynamic-gxi-paired';
const encode=x=>JSON.stringify(x,(_,v)=>typeof v==='bigint'?v.toString():v instanceof Map?{map:[...v]}:v instanceof Set?{set:[...v]}:v);
const hash=x=>crypto.createHash('sha256').update(typeof x==='string'?x:encode(x)).digest('hex');
const start=(label,limit)=>process.stdout.write('@@START '+JSON.stringify({label,limit})+'\n');
const done=(label,value)=>process.stdout.write('@@DONE '+JSON.stringify({label,...value})+'\n');
const unwrap=x=>{if(x.isLeft())throw Error(x.value.msg||'official pipeline failed');return x.value;};
(async()=>{
 const input='proofs/qunit/DynamicPairedEvidence.qnt';
 const args={input,main:'DynamicPairedEvidence',backend:'typescript',maxSamples:1,verbosity:2,seed:293n,outItf:out+'/itf/{test}-{seq}.itf.json'};
 start('api-parse',20);
 const loaded=unwrap(await cli.load(args));const parsed=unwrap(await cli.parse(loaded));
 done('api-parse',{modules:parsed.modules.length,sourceSha256:hash(fs.readFileSync(input,'utf8'))});
 start('api-typecheck',55);
 const typed=unwrap(await cli.typecheck(parsed));
 const fingerprint=()=>hash({modules:typed.modules,table:typed.table,definitions:typed.resolver.collector.definitionsByModule});
 const ir=fingerprint();
 const groups=JSON.parse(fs.readFileSync(out+'/api-groups.json','utf8'));
 fs.writeFileSync(out+'/typed-stage-summary.json',encode({input,sourceSha256:hash(fs.readFileSync(input,'utf8')),typedIrDigest:ir,modules:typed.modules.map(m=>m.name),groups,cliCommandsSha256:hash(fs.readFileSync(base+'cliCommands.js','utf8')),evaluatorSha256:hash(fs.readFileSync(base+'runtime/impl/evaluator.js','utf8')),qualification:'Official full type/effect analysis reused without mutation; runTests creates a fresh Evaluator and RNG for each group.'})+'\n');
 done('api-typecheck',{typedIrDigest:ir});
 for(let n=0;n<groups.length;n++){
  const label='api-controls-'+n;start(label,20);
  const group=groups[n],stage={...typed,args:{...args,match:'^('+group.join('|')+')$'}};
  const result=unwrap(await cli.runTests(stage));
  if(result.failed.length||result.ignored.length||result.passed.length!==group.length||!group.every(t=>result.passed.includes(t)))throw Error('control coverage mismatch');
  if(fingerprint()!==ir)throw Error('official typed IR mutated');
  done(label,{passed:result.passed,failed:result.failed,ignored:result.ignored,typedIrUnchanged:true});
 }
})().catch(e=>{console.error(e.stack);process.exitCode=1;});
