#!/usr/bin/env python3
"""Verify incarnation issuance, bootstrap possession and protected activation."""
from pathlib import Path
import hashlib,json,os,re,subprocess,time,sys
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'dev/proofs/evidence/llm-bootstrap-invitation';PRIOR=ROOT/'dev/proofs/evidence/llm-incarnation-issuance'
def main():
 OUT.mkdir(exist_ok=True);records=[]
 if '--resume-bundle' in sys.argv:
  records=[r for r in json.loads((OUT/'commands.json').read_text()) if r['label']=='LlmBootstrapInvitation']
  assert len(records)==1 and records[0]['exit']==0
  for p,h in records[0]['sourceSha256'].items():assert hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h
 ancestors=json.loads((PRIOR/'reused-lean-receipts.json').read_text())+[r for r in json.loads((PRIOR/'commands.json').read_text()) if r['label']=='LlmIncarnationIssuance']
 assert len(ancestors)==31
 for r in ancestors:
  assert r['exit']==0
  for p,h in r['sourceSha256'].items():assert hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h,(r['label'],p)
  assert Path(r['args'][-2]).is_file()
  log=PRIOR/(r['label']+'.log')
  if not log.exists():log=ROOT/'dev/proofs/evidence/llm-caller-custody'/(r['label']+'.log')
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
 if not any(r['label']=='LlmBootstrapInvitation' for r in records):run('LlmBootstrapInvitation',['elan','run','leanprover/lean4:v4.34.1','lean','-o',str(compiled/'LlmBootstrapInvitation.olean'),'dev/proofs/lean/LlmBootstrapInvitation.lean'],20,dict(os.environ,LEAN_PATH=str(compiled)))
 text=(OUT/'LlmBootstrapInvitation.log').read_text();assert 'sorryAx' not in text and 'error:' not in text
 assert len(re.findall(r"^'Weaver.LlmBootstrapInvitation\.",text,re.M))==19
 run('verify-bundle',['python3','dev/proofs/evidence/llm-bootstrap-invitation/check-bundle.py'],20)
 shards=json.loads((OUT/'bundle-control-shards.json').read_text())
 (OUT/'itf').mkdir(exist_ok=True)
 for n,row in enumerate(shards):
  if '--resume-bundle' in sys.argv and n==0:
   old=json.loads((OUT/'bundle-controls-0-command.json').read_text());assert old['exit']==0
   assert hashlib.sha256((ROOT/row['source']).read_bytes()).hexdigest()==row['sha256']
   records.append(dict(label='bundle-controls-0',**old,sourceSha256={row['source']:row['sha256']}));continue
  run('bundle-controls-'+str(n),['quint','test',row['source'],'--main','LlmBootstrapInvitation','--backend','typescript','--max-samples','1','--match','^('+'|'.join(row['tests'])+')$','--out-itf','dev/proofs/evidence/llm-bootstrap-invitation/itf/{test}-{seq}.itf.json'],55)

if __name__=='__main__':main()
