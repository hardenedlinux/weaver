#!/usr/bin/env python3
"""Focused configurable routine -> routing refinement; no Gateway implementation."""
from pathlib import Path
import hashlib,json,os,re,subprocess,time,sys
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'dev/proofs/evidence/routine-routing-config'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 records=[]
 def run(label,args,limit,env=None):
  inputs={p:sha(ROOT/p) for p in args if p.endswith(('.py','.qnt','.lean','.cjs')) and (ROOT/p).is_file()};t=time.monotonic()
  with (OUT/(label+'.log')).open('w') as log:
   try:code=subprocess.run(args,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=limit).returncode
   except subprocess.TimeoutExpired:code=124
  r=dict(label=label,args=args,exit=code,seconds=round(time.monotonic()-t,3),watchdogSeconds=limit,sourceSha256=inputs);records.append(r);(OUT/'commands.json').write_text(json.dumps(records,indent=2)+'\n');print(label,code,flush=True)
  assert all(sha(ROOT/p)==h for p,h in inputs.items())
  if code:raise SystemExit(code)
  return r
 wanted=['LogicalMessageAuthority','SharedMessageBudget','FiniteDomainMigration','GatewayHeadCAS','BrokerConsumptionQueue','LogicalRangeRecovery','LlmRouting'];parents=json.loads((ROOT/'dev/proofs/evidence/llm-subject-authority/reused-lean-receipts.json').read_text());reuse=[next(r for r in parents if r['label']==name) for name in wanted]
 for r in reuse:
  assert r['exit']==0
  for p,h in r['sourceSha256'].items():assert sha(ROOT/p)==h
  assert Path(r['args'][-2]).is_file()
  log=next(p for p in (ROOT/'dev/proofs/evidence').glob('*/'+r['label']+'.log'));assert 'sorryAx' not in log.read_text() and 'error:' not in log.read_text()
 (OUT/'reused-lean-receipts.json').write_text(json.dumps(reuse,indent=2)+'\n')
 compiled=Path(reuse[-1]['args'][-2]).parent
 if '--reuse-current' in sys.argv:
  r=json.loads((OUT/'lean-command.json').read_text());assert r['exit']==0 and sha(Path(r['args'][-2]))==r['compiledSha256']
  for p,h in r['sourceSha256'].items():assert sha(ROOT/p)==h
  records.append(dict(**r,label='RoutineRoutingConfig'))
 else:
  r=run('RoutineRoutingConfig',['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/'RoutineRoutingConfig.olean'),'dev/proofs/lean/RoutineRoutingConfig.lean'],20,dict(os.environ,LEAN_PATH=str(compiled)));r['compiledSha256']=sha(Path(r['args'][-2]));(OUT/'lean-command.json').write_text(json.dumps(r,indent=2)+'\n')
 text=(OUT/'RoutineRoutingConfig.log').read_text();assert 'error:' not in text and 'sorryAx' not in text;assert len(re.findall(r"^'Weaver.RoutineRoutingConfig\.",text,re.M))==24
 run('prepare-bundle',['python3','dev/proofs/prepare_routine_config.py'],20)
 run('parse-parent',['quint','parse','dev/proofs/quint/LlmRouting.qnt','--out',str((OUT/'parent-parsed.json').relative_to(ROOT))],20)
 run('parse-raw-leaf',['node',str((OUT/'parse-raw-leaf.cjs').relative_to(ROOT))],20)
 run('parse-bundle',['quint','parse',str((OUT/'bundle/RoutineRoutingConfig.qnt').relative_to(ROOT)),'--out',str((OUT/'bundle-parsed.json').relative_to(ROOT))],20)
 if '--reuse-current' not in sys.argv:run('official-api',['python3','dev/proofs/check_routine_config_api.py'],400)
 invocation=json.loads((OUT/'api-invocation.json').read_text());assert invocation['exit']==0 and invocation['expectedControls']==32
 for p,h in invocation['inputs'].items():assert sha(ROOT/p)==h
 api=json.loads((OUT/'api-commands.json').read_text());assert len(api)==13 and all(r['exit']==0 for r in api) and sum(len(r.get('passed',[])) for r in api)==32
 assert all(r['typedIrUnchanged'] for r in api if r['label'].startswith('api-controls-'))
 run('verify-bundle',['python3',str((OUT/'check-bundle.py').relative_to(ROOT))],20);records.extend(api)
 for label,helper in [('source-check','check-source-review.py'),('examples','check-examples.py'),('counterexamples','check-counterexamples.py')]:run(label,['python3',str((OUT/helper).relative_to(ROOT))],20)
 (OUT/'commands.json').write_text(json.dumps(records,indent=2)+'\n')
 print('PASS: 24 Lean declarations, 32 Quint controls, 16 finite examples, seven source-checked Lean ancestors')
if __name__=='__main__':main()
