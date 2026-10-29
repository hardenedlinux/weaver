#!/usr/bin/env python3
"""Verify incarnation issuance, bootstrap possession and protected activation."""
from pathlib import Path
import hashlib,json,os,re,subprocess,time,sys
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'proofs/evidence/llm-incarnation-issuance';PRIOR=ROOT/'proofs/evidence/llm-caller-custody'
def main():
 OUT.mkdir(exist_ok=True);records=[]
 if '--resume-controls' in sys.argv:
  previous=json.loads((OUT/'commands.json').read_text())
  records=[r for r in previous if r['label'] in ['LlmIncarnationIssuance','tests','counterexamples']]
  assert len(records)==3 and all(r['exit']==0 for r in records)
  for row in records:
   for path,digest in row['sourceSha256'].items():assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==digest
 old=json.loads((PRIOR/'commands.json').read_text());ancestors=[r for r in old if r['label'].startswith(('Llm','Logical','Shared','Finite','Gateway','Broker'))]
 assert len(ancestors)==30
 for r in ancestors:
  assert r['exit']==0
  for p,h in r['sourceSha256'].items():assert hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h,(r['label'],p)
  assert Path(r['args'][-2]).is_file()
  assert 'sorryAx' not in (PRIOR/(r['label']+'.log')).read_text() and 'error:' not in (PRIOR/(r['label']+'.log')).read_text()
 (OUT/'reused-lean-receipts.json').write_text(json.dumps(ancestors,indent=2)+'\n')
 compiled=Path(ancestors[-1]['args'][-2]).parent
 def run(label,args,limit,env=None):
  digest={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in args if p.endswith(('.py','.qnt','.lean')) and (ROOT/p).is_file()};start=time.monotonic()
  with (OUT/(label+'.log')).open('w') as log:
   try:code=subprocess.run(args,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=limit).returncode
   except subprocess.TimeoutExpired:code=124
  assert all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in digest.items())
  records.append(dict(label=label,args=args,sourceSha256=digest,exit=code,seconds=round(time.monotonic()-start,3),watchdogSeconds=limit))
  (OUT/'commands.json').write_text(json.dumps(records,indent=2)+'\n');print(label,code,flush=True)
  if code:raise SystemExit(code)
 if not any(r['label']=='LlmIncarnationIssuance' for r in records):run('LlmIncarnationIssuance',['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/'LlmIncarnationIssuance.olean'),'proofs/lean/LlmIncarnationIssuance.lean'],20,dict(os.environ,LEAN_PATH=str(compiled)))
 text=(OUT/'LlmIncarnationIssuance.log').read_text();assert 'sorryAx' not in text and 'error:' not in text
 assert len(re.findall(r"^'Weaver.LlmIncarnationIssuance\.",text,re.M))==23
 run('prepare-closure',['python3','proofs/prepare_llm_issuance_closure.py'],20)
 source='proofs/evidence/llm-incarnation-issuance/quint-core/LlmIncarnationIssuance.qnt'
 tests=re.findall(r'^  run (\w+Test)=',(ROOT/source).read_text(),re.M);assert len(tests)==31
 # The official CLI test and run routes invoke typecheck before execution.
 if not any(r['label']=='tests' for r in records):run('tests',['quint','test',source,'--backend','typescript','--max-samples','1','--match','^('+'|'.join(tests)+')$'],55)
 (OUT/'itf').mkdir(exist_ok=True)
 if not any(r['label']=='counterexamples' for r in records):run('counterexamples',['quint','test',source,'--backend','typescript','--max-samples','1','--match','IssuanceCounterexampleTest$','--out-itf','proofs/evidence/llm-incarnation-issuance/itf/{test}-{seq}.itf.json'],55)
 simulation='proofs/evidence/llm-incarnation-issuance/simulation-core/LlmIncarnationIssuance.qnt'
 run('parse-simulation',['quint','parse',simulation,'--out','proofs/evidence/llm-incarnation-issuance/simulation-parsed.json'],20)
 for init in ['boot','issued','proven','ready','activated','competing','moved','revoked']:
  run(init,['quint','run',simulation,'--backend','typescript','--init',init,'--step','step','--invariant','invariant','--max-samples','10','--max-steps','30','--seed','293','--verbosity','1'],30)
 parent='proofs/evidence/llm-caller-custody/quint-core/LlmCallerCustody.qnt';tests=re.findall(r'^  run (\w+Test)=',(ROOT/parent).read_text(),re.M);assert len(tests)==27
 run('caller-regression',['quint','test',parent,'--backend','typescript','--max-samples','1','--match','^('+'|'.join(tests)+')$'],55)
if __name__=='__main__':main()
