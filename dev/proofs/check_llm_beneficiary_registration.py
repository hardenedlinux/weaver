#!/usr/bin/env python3
"""Verify first beneficiary binding, authoritative invitation publication and original account composition."""
from pathlib import Path
import hashlib,json,os,re,subprocess,time,sys
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'dev/proofs/evidence/llm-beneficiary-registration';PRIOR=ROOT/'dev/proofs/evidence/llm-bootstrap-invitation'
def main():
 OUT.mkdir(exist_ok=True);records=[]
 ancestors=json.loads((PRIOR/'reused-lean-receipts.json').read_text())+[r for r in json.loads((PRIOR/'commands.json').read_text()) if r['label']=='LlmBootstrapInvitation']
 assert len(ancestors)==32
 for r in ancestors:
  assert r['exit']==0
  for p,h in r['sourceSha256'].items():assert hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h,(r['label'],p)
  assert Path(r['args'][-2]).is_file()
  log=next(ROOT/'dev/proofs/evidence'/folder/(r['label']+'.log') for folder in ['llm-bootstrap-invitation','llm-incarnation-issuance','llm-caller-custody'] if (ROOT/'dev/proofs/evidence'/folder/(r['label']+'.log')).exists())
  assert 'sorryAx' not in log.read_text() and 'error:' not in log.read_text()
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
 if not any(r['label']=='LlmBeneficiaryRegistration' for r in records):run('LlmBeneficiaryRegistration',['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/'LlmBeneficiaryRegistration.olean'),'dev/proofs/lean/LlmBeneficiaryRegistration.lean'],20,dict(os.environ,LEAN_PATH=str(compiled)))
 text=(OUT/'LlmBeneficiaryRegistration.log').read_text();assert 'sorryAx' not in text and 'error:' not in text
 assert len(re.findall(r"^'Weaver.LlmBeneficiaryRegistration\.",text,re.M))==29
 run('verify-bundle',['python3','dev/proofs/evidence/llm-beneficiary-registration/check-bundle.py'],20)
 if '--reuse-api' not in sys.argv:
  run('official-api',['python3','dev/proofs/check_beneficiary_api.py'],600)
 invocation=json.loads((OUT/'api-invocation.json').read_text());assert invocation['exit']==0 and invocation['expectedControls']==32
 for path,digest in invocation['inputs'].items():assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==digest
 api=json.loads((OUT/'api-commands.json').read_text());assert len(api)==13 and all(r['exit']==0 for r in api)
 assert sum(len(r.get('passed',[])) for r in api)==32
 assert all(r['typedIrUnchanged'] for r in api if r['label'].startswith('api-controls-'))
 for row in api:
  records.append(dict(**row,reusedCurrentInvocation=True))
 (OUT/'commands.json').write_text(json.dumps(records,indent=2)+'\n')
 print('PASS: fresh Lean leaf, source-checked ancestors and 32 actual current official Quint controls',flush=True)

if __name__=='__main__':main()
